import AppKit
import Foundation
import LggrKit
import UniformTypeIdentifiers

// Getting a document out of Lggr. See docs/_design/SPEC.md § Export and 04-screens.md § 7.1.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THIS FILE RENDERS NOTHING
//
//  Every character of every export is produced by `LggrKit/Export/` — `DailySummaryMarkdown`,
//  `WeeklyReviewMarkdown`, `AccomplishmentLogMarkdown`, `SessionsCSVExporter` — which are pure
//  functions over value types and are covered by `ExportTests`. This file reads the records those
//  functions need, hands them over, and puts the result on the clipboard or on disk.
//
//  That split is the whole design. A second renderer living up here would be a document that
//  disagreed with the one the tests assert, and the exports are the artefact people paste into a
//  performance review — the one place in the app where being subtly wrong is expensive.
//
//  TWO FAILURES ARE ANSWERED EXPLICITLY, because both are ordinary rather than exotic:
//
//    • **A cancelled panel writes nothing and says nothing.** Cancelling is an instruction, not a
//      fault, and an app that reports it is an app that argues with you.
//    • **A location that cannot be written is reported in a sentence**, with the file name in it, and
//      the main window is opened so the sentence has somewhere to appear. Never a silent no-op, and
//      never a crash: a read-only volume, a full disk and a folder that vanished between the panel
//      and the write are all reachable from a save panel.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// MARK: - What a document is

/// The two shapes an export takes.
public enum ExportFormat: Hashable, Sendable {
    case markdown
    /// RFC 4180 CSV, for someone who wants to do their own arithmetic.
    case commaSeparatedValues

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .commaSeparatedValues: "csv"
        }
    }

    /// `nil` only if the system cannot resolve the type, in which case the panel simply does not
    /// constrain the extension. Stated rather than force-unwrapped.
    public var contentType: UTType? {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .commaSeparatedValues: .commaSeparatedText
        }
    }
}

/// A finished document, ready to be copied or written. Rendered before either destination is chosen,
/// so the clipboard and the file can never disagree.
public struct ExportDocument: Hashable, Sendable {
    public let text: String
    /// What the save panel offers, extension included.
    public let fileName: String
    public let format: ExportFormat

    public init(text: String, fileName: String, format: ExportFormat) {
        self.text = text
        self.fileName = fileName
        self.format = format
    }
}

/// The four exports `SPEC.md` asks for, and no fifth.
public enum ExportKind: String, CaseIterable, Identifiable, Sendable {
    case dailySummary
    case weeklyReview
    case accomplishmentLog
    case focusSessions

    public var id: String { rawValue }

    /// The title of the menu item that writes a file. The ellipsis is the macOS convention for "this
    /// opens something", and a save panel is something.
    public var saveTitle: String {
        switch self {
        case .dailySummary: "Daily Summary…"
        case .weeklyReview: "Weekly Review…"
        case .accomplishmentLog: "Accomplishment Log…"
        case .focusSessions: "Focus Sessions as CSV…"
        }
    }

    /// The title of the menu item that copies. No ellipsis: it happens at once.
    public var copyTitle: String {
        switch self {
        case .dailySummary: "Copy Daily Summary"
        case .weeklyReview: "Copy Weekly Review"
        case .accomplishmentLog: "Copy Accomplishment Log"
        case .focusSessions: "Copy Focus Sessions as CSV"
        }
    }

    public var format: ExportFormat {
        self == .focusSessions ? .commaSeparatedValues : .markdown
    }

    /// What the save panel says above the file name, so the user knows what they are about to keep.
    var panelMessage: String {
        switch self {
        case .dailySummary: "Today's sessions, accomplishments and timeline, as Markdown."
        case .weeklyReview: "This week's review, as Markdown."
        case .accomplishmentLog: "Everything you have logged, as Markdown."
        case .focusSessions: "Every focus session, as CSV."
        }
    }
}

// MARK: - The service

/// Reads the records an export needs, renders it through `LggrKit`, and puts it somewhere.
///
/// Everything it depends on arrives as a collaborator or a closure, so a test or the gallery can
/// build one against an in-memory store with no sampler, no window and no clipboard.
@MainActor
@Observable
public final class ExportService {

    /// A whole history. `nil` is not accepted by `LggrStore`, which takes an interval, and this is
    /// what "export everything" means in that vocabulary.
    private static let everything = DateInterval(start: .distantPast, end: .distantFuture)

    /// Set when a document could not be read or a file could not be written, as one sentence about
    /// the record rather than about the user. Surfaced by the host's error banner
    /// (`04-screens.md` § 3.3), never as an alert.
    public private(set) var failure: String?

    @ObservationIgnored private let store: any LggrStore
    @ObservationIgnored private let activityLog: (any ActivityLog)?
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let windows: CalendarWindows

    /// The projects, for resolving names. A closure rather than an array because they change while
    /// the app runs and an export must use the ones that exist at the moment it is asked for.
    @ObservationIgnored private let projects: () -> [Project]

    /// The reconstructed day, if one has been loaded. Only used when it is the day being exported —
    /// see `dailySummary()`, which refuses a timeline for a different day rather than dating it
    /// wrongly.
    @ObservationIgnored private let timeline: () -> DayTimeline?

    /// The privacy lists, as the redactor the daily export needs. A closure for the same reason
    /// `projects` is: a list edited a second ago governs the document written now.
    @ObservationIgnored private let redactor: () -> PrivacyRedactor

    /// Brings a window forward so `failure` has somewhere to be read. Absent in a headless host, in
    /// which case the sentence is still published and simply has no reader.
    @ObservationIgnored public var showMainWindow: (@MainActor () -> Void)?

    public init(
        store: any LggrStore,
        activityLog: (any ActivityLog)? = nil,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        projects: @escaping () -> [Project] = { [] },
        timeline: @escaping () -> DayTimeline? = { nil },
        redactor: @escaping () -> PrivacyRedactor = { .permissive },
        showMainWindow: (@MainActor () -> Void)? = nil
    ) {
        self.store = store
        self.activityLog = activityLog
        self.clock = clock
        self.calendar = calendar
        self.windows = CalendarWindows(calendar: calendar)
        self.projects = projects
        self.timeline = timeline
        self.redactor = redactor
        self.showMainWindow = showMainWindow
    }

    // MARK: - Destinations

    /// Renders the document and puts it on the clipboard.
    ///
    /// The destination people actually use: the next thing that happens to a weekly review is being
    /// pasted into a one-to-one document, and a round trip through the Finder for that is three
    /// steps too many. Silent on success — the paste is the confirmation, and Lggr has no toast.
    public func copy(_ kind: ExportKind) async {
        guard let document = await document(for: kind) else { return }
        copy(document)
    }

    public func copy(_ document: ExportDocument) {
        Pasteboard.copy(document.text)
        failure = nil
    }

    /// Renders the document and offers to save it.
    public func save(_ kind: ExportKind) async {
        guard let document = await document(for: kind) else { return }
        save(document, message: kind.panelMessage)
    }

    /// Writes a document a screen already holds — Weekly Review's *Export Review…*, which exports
    /// the week on screen rather than the week the calendar is in.
    ///
    /// `runModal()` rather than `.fileExporter`: the exporter needs a `FileDocument` and a `Binding`
    /// on a view, and this is called from a menu command that may have no view behind it at all.
    public func save(_ document: ExportDocument, message: String? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.fileName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.prompt = "Export"
        if let message { panel.message = message }
        if let type = document.format.contentType {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            // Cancelled. Nothing is written and nothing is said: the user asked for it to stop, and
            // an app that reports that is an app that argues.
            return
        }

        do {
            try Data(document.text.utf8).write(to: url, options: .atomic)
            failure = nil
        } catch {
            // A read-only volume, a full disk, a folder removed between the panel and the write. All
            // reachable, none of them the user's mistake, and none of them worth losing the document
            // over — the clipboard route is still there and the record is untouched.
            report("Lggr could not write \(url.lastPathComponent). \(Self.sentence(for: error))")
        }
    }

    public func clearFailure() {
        failure = nil
    }

    // MARK: - Assembling a document

    /// The document, or `nil` with `failure` set.
    public func document(for kind: ExportKind) async -> ExportDocument? {
        switch kind {
        case .dailySummary: await dailySummary()
        case .weeklyReview: await weeklyReview()
        case .accomplishmentLog: await accomplishmentLog()
        case .focusSessions: await focusSessionsCSV()
        }
    }

    /// Today, as the standup note it is meant to become.
    private func dailySummary() async -> ExportDocument? {
        let now = clock.now
        let day = windows.day(containing: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 24 * 60 * 60)

        do {
            let sessions = try await store.loadSessions(in: day)
            let accomplishments = try await store.loadAccomplishments(in: day)
            let interruptions = try await store.loadInterruptions(in: day)

            // Only the day already reconstructed, and only if it is *this* day. A timeline built for
            // yesterday, folded into today's heading, would be a document stating times that never
            // happened — worse than a document with no timeline in it.
            let reconstructed = timeline().flatMap { $0.dayStart == day.start ? $0 : nil }

            let text = DailySummaryMarkdown.render(
                DailySummaryInput(
                    day: day,
                    sessions: sessions,
                    accomplishments: accomplishments,
                    interruptions: interruptions,
                    timeline: reconstructed,
                    projectNames: projectNames()
                ),
                formatter: formatter,
                redactor: redactor()
            )
            failure = nil
            return ExportDocument(
                text: text,
                fileName: "Daily Summary \(formatter.isoDate(day.start)).md",
                format: .markdown
            )
        } catch {
            report("Lggr could not read today. \(Self.sentence(for: error))")
            return nil
        }
    }

    /// The current week.
    ///
    /// Built by `WeeklyModel`, which is the same object the screen uses, so the exported document is
    /// the screen's document by construction rather than by agreement. A week on screen is exported
    /// through `save(_:message:)` instead, from `WeeklyReviewView`'s own menu — this path is what
    /// `File ▸ Export` reaches when no window is open.
    private func weeklyReview() async -> ExportDocument? {
        let model = WeeklyModel(
            store: store,
            activityLog: activityLog,
            clock: clock,
            calendar: calendar
        )
        await model.load()

        if case .failed(let message) = model.phase {
            report(message)
            return nil
        }

        failure = nil
        return ExportDocument(
            text: model.markdown,
            fileName: "Weekly Review \(formatter.isoDate(model.review.week.start)).md",
            format: .markdown
        )
    }

    /// Everything the user has logged, from the first entry to the last.
    ///
    /// `interval` is left `nil` deliberately: the renderer's subtitle would otherwise state a range
    /// running from the distant past, and this document covers whatever exists rather than a window
    /// somebody chose. The Accomplishments screen exports its *filtered, windowed* view separately —
    /// see `AccomplishmentsModel.markdown(projects:grouping:)`.
    private func accomplishmentLog() async -> ExportDocument? {
        do {
            let accomplishments = try await store.loadAccomplishments(in: Self.everything)
            let titles = try await outcomeTitles()
            let text = AccomplishmentLogMarkdown.render(
                AccomplishmentLogInput(
                    accomplishments: accomplishments,
                    projectNames: projectNames(),
                    outcomeTitles: titles
                ),
                formatter: formatter
            )
            failure = nil
            return ExportDocument(
                text: text,
                fileName: "Accomplishment Log.md",
                format: .markdown
            )
        } catch {
            report("Lggr could not read your accomplishments. \(Self.sentence(for: error))")
            return nil
        }
    }

    /// Every session, raw.
    private func focusSessionsCSV() async -> ExportDocument? {
        do {
            let sessions = try await store.loadSessions(in: Self.everything)
            let titles = try await outcomeTitles()
            let text = SessionsCSVExporter.render(
                SessionsCSVInput(
                    sessions: sessions,
                    projectNames: projectNames(),
                    outcomeTitles: titles
                ),
                formatter: formatter
            )
            failure = nil
            return ExportDocument(
                text: text,
                fileName: "Focus Sessions.csv",
                format: .commaSeparatedValues
            )
        } catch {
            report("Lggr could not read your focus sessions. \(Self.sentence(for: error))")
            return nil
        }
    }

    // MARK: - Lookups

    /// The local calendar, so a day boundary in the document is the user's day boundary.
    private var formatter: ExportFormatter {
        ExportFormatter(calendar: calendar)
    }

    private func projectNames() -> [UUID: String] {
        var names: [UUID: String] = [:]
        for project in projects() { names[project.id] = project.name }
        return names
    }

    private func outcomeTitles() async throws -> [UUID: String] {
        var titles: [UUID: String] = [:]
        for outcome in try await store.loadWeeklyOutcomes(in: Self.everything) {
            titles[outcome.id] = outcome.title
        }
        return titles
    }

    // MARK: - Failure

    /// Publishes the sentence and makes sure there is somewhere to read it.
    ///
    /// An export can be asked for from the menu bar with every window closed, and a failure nobody
    /// can see is the same thing as failing silently.
    private func report(_ message: String) {
        failure = message
        showMainWindow?()
    }

    /// A sentence, never a code.
    ///
    /// `StoreError` is a plain `Error` rather than a `LocalizedError`, so `localizedDescription`
    /// would render "The operation couldn't be completed" and throw away the message the store wrote
    /// for exactly this moment. The associated value is unwrapped instead.
    private static func sentence(for error: any Error) -> String {
        switch error {
        case StoreError.invalidData(let message), StoreError.persistenceFailure(let message):
            return message
        case StoreError.notFound:
            return "Lggr could not find those records."
        default:
            return error.localizedDescription
        }
    }
}
