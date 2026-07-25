import Foundation
import LggrKit

// The state behind Accomplishments (`⌘3`) — the "Done" log. See docs/_design/04-screens.md § 4.3 and
// SPEC.md § 10.
//
// The spec sets one acceptance test for this screen and it is a behavioural one: *"The user should be
// able to open the app on Friday and immediately see evidence of what they delivered."* Everything
// here serves that sentence.
//
//   * **Grouped by week, newest first.** Friday afternoon means "this week", so the first group is
//     always the one the user came for, and it is headed `This week` rather than a date they have to
//     decode.
//   * **Read a window at a time**, for the same reason `SessionsModel` does: the log is the one list
//     in Lggr that is never pruned, so it is the one that would get slowest.
//   * **Nothing is inferred.** Every line in the log was typed by a person
//     (`INTELLIGENCE.md` § 3.6 killed generated accomplishments outright), and nothing in this file
//     invents, ranks or scores an entry. It groups, filters and formats.
//
// The Markdown export is `AccomplishmentLogMarkdown` from `LggrKit`, unchanged: this model assembles
// its input and hands over the result. There is no second renderer, because an export the screen
// disagreed with would be worse than no export.

/// The state behind `AccomplishmentsLogView`.
@MainActor
@Observable
public final class AccomplishmentsModel {

    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// One week of the window, with the heading the screen prints above it.
    public struct Week: Identifiable, Equatable, Sendable {
        public let start: Date
        /// "This week" · "Last week" · "Week of 14 July".
        public let heading: String
        /// Newest first inside the week, which is how § 4.3 orders a group.
        public let accomplishments: [Accomplishment]

        public var id: Date { start }

        public init(start: Date, heading: String, accomplishments: [Accomplishment]) {
            self.start = start
            self.heading = heading
            self.accomplishments = accomplishments
        }
    }

    // MARK: - Published state

    public private(set) var phase: Phase = .idle

    public private(set) var window: HistoryWindow

    /// Every accomplishment stamped inside the window, newest first.
    public private(set) var accomplishments: [Accomplishment] = []

    /// Matches the title and the details — the two fields the user wrote.
    public var searchText: String = ""

    /// `nil` is "All types".
    public var typeFilter: AccomplishmentType?

    /// `nil` is "All projects".
    public var projectFilter: UUID?

    // MARK: - Collaborators

    @ObservationIgnored private let store: any LggrStore
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let windows: CalendarWindows

    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var reloadRequested = false

    public init(
        store: any LggrStore,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        span: HistoryWindow.Span = .month
    ) {
        self.store = store
        self.clock = clock
        self.calendar = calendar
        self.windows = CalendarWindows(calendar: calendar)
        self.window = HistoryWindow(span: span, anchor: clock.now)
    }

    // MARK: - Derived

    public var windowDisplay: HistoryWindow.Display {
        window.display(now: clock.now, in: calendar)
    }

    /// Whether the window holds anything before the filters narrow it. Separates "nothing logged yet"
    /// from "nothing in June" — two facts that deserve two different sentences.
    public var hasEntriesInWindow: Bool { !accomplishments.isEmpty }

    public var isFiltering: Bool {
        !normalizedSearch.isEmpty || typeFilter != nil || projectFilter != nil
    }

    public var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The window after search, type and project filters, newest first.
    public var filteredAccomplishments: [Accomplishment] {
        let query = normalizedSearch
        return accomplishments.filter { entry in
            if let typeFilter, entry.type != typeFilter { return false }
            if let projectFilter, entry.projectID != projectFilter { return false }
            guard !query.isEmpty else { return true }
            return Self.matches(entry, query: query)
        }
    }

    /// The filtered window, grouped by week, newest week first.
    public var weeks: [Week] {
        Self.group(filteredAccomplishments, in: windows, now: clock.now)
    }

    /// The types present in the window, in `AccomplishmentType` declaration order.
    ///
    /// The filter menu offers only these. Eleven rows of which nine can never match is a menu that
    /// makes the user do the app's work; declaration order rather than descending count, because
    /// ranking the kinds would rank the work.
    public var availableTypes: [AccomplishmentType] {
        let present = Set(accomplishments.map(\.type))
        return AccomplishmentType.allCases.filter { present.contains($0) }
    }

    /// The projects present in the window, so the project filter offers only what can match.
    public func availableProjects(from projects: [Project]) -> [Project] {
        let present = Set(accomplishments.compactMap(\.projectID))
        return projects.filter { present.contains($0.id) }
    }

    public func clearFilters() {
        searchText = ""
        typeFilter = nil
        projectFilter = nil
    }

    // MARK: - Window navigation

    public func step(_ steps: Int) async {
        if steps > 0, !window.canStepForward(now: clock.now, in: calendar) { return }
        window = window.stepped(by: steps, in: calendar)
        await load()
    }

    public func setSpan(_ span: HistoryWindow.Span) async {
        guard span != window.span else { return }
        window = window.withSpan(span)
        await load()
    }

    public func goToLatest() async {
        let latest = HistoryWindow(span: window.span, anchor: clock.now)
        guard latest != window else { return }
        window = latest
        await load()
    }

    // MARK: - Loading

    public func load() async {
        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        repeat {
            reloadRequested = false
            await read()
        } while reloadRequested
    }

    public func reload() async {
        await load()
    }

    /// Re-reads only when the window contains the present, so an entry logged today does not move a
    /// screen that is showing March.
    public func reloadIfCurrent() async {
        guard window.contains(clock.now, in: calendar) else { return }
        await load()
    }

    private func read() async {
        guard let interval = window.interval(in: calendar) else {
            phase = .failed("Lggr could not work out which dates to show.")
            return
        }

        if phase != .ready { phase = .loading }

        do {
            accomplishments = try await store.loadAccomplishments(in: interval)
            phase = .ready
        } catch {
            phase = .failed("Couldn't load your log. Your work is still on disk.")
        }
    }

    /// Folds an entry saved elsewhere into whatever this model is showing.
    public func apply(_ accomplishment: Accomplishment) {
        if let index = accomplishments.firstIndex(where: { $0.id == accomplishment.id }) {
            accomplishments[index] = accomplishment
        } else if window.contains(accomplishment.timestamp, in: calendar) {
            accomplishments.append(accomplishment)
        }
        accomplishments.sort { $0.timestamp > $1.timestamp }
    }

    public func remove(id: UUID) {
        accomplishments.removeAll { $0.id == id }
    }

    // MARK: - Export

    /// The log as Markdown, exactly as it appears on screen.
    ///
    /// Filtered rather than whole: the user narrowed the list on purpose, and an export that quietly
    /// widened it again would be the document disagreeing with the screen that produced it. The
    /// window travels with it as the interval, so the heading states which stretch of time the
    /// document covers.
    public func markdown(
        projects: [Project],
        grouping: AccomplishmentLogMarkdown.Grouping = .day
    ) -> String {
        var names: [UUID: String] = [:]
        for project in projects { names[project.id] = project.name }

        return AccomplishmentLogMarkdown.render(
            AccomplishmentLogInput(
                interval: window.interval(in: calendar),
                accomplishments: filteredAccomplishments,
                projectNames: names
            ),
            formatter: ExportFormatter(calendar: calendar),
            options: AccomplishmentLogMarkdown.Options(grouping: grouping)
        )
    }

    /// A file name a save panel can offer: `Accomplishments-July 2026.md`.
    public var suggestedExportFileName: String {
        "Accomplishments-\(window.title(in: calendar)).md"
    }

    // MARK: - Matching

    /// The two fields the user typed. Not the type's display name: it has its own filter, and a
    /// search that matched it would make "review" return every reviewed pull request.
    nonisolated static func matches(_ accomplishment: Accomplishment, query: String) -> Bool {
        let haystack = [accomplishment.title, accomplishment.details ?? ""]
        return haystack.contains { field in
            field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - Grouping

    /// Groups by the calendar's own week, honouring `firstWeekday`, newest week first.
    ///
    /// A week is asked for through `CalendarWindows` rather than computed, because a week starts on
    /// Monday or Sunday depending on where the user lives and can straddle a month or a year. An
    /// entry the calendar cannot place is grouped by its own day rather than dropped: a log that
    /// silently loses a line is worse than one with an odd heading.
    nonisolated static func group(
        _ accomplishments: [Accomplishment],
        in windows: CalendarWindows,
        now: Date
    ) -> [Week] {
        var order: [Date] = []
        var buckets: [Date: [Accomplishment]] = [:]

        for entry in accomplishments.sorted(by: { $0.timestamp > $1.timestamp }) {
            let start = windows.startOfWeek(for: entry.timestamp)
                ?? windows.startOfDay(for: entry.timestamp)
            if buckets[start] == nil { order.append(start) }
            buckets[start, default: []].append(entry)
        }

        return order.map { start in
            Week(
                start: start,
                heading: weekHeading(for: start, now: now, in: windows),
                accomplishments: buckets[start] ?? []
            )
        }
    }

    /// "This week" · "Last week" · "Week of 14 July" — § 4.3's headings, plus the relative pair that
    /// makes the Friday read instant.
    ///
    /// The absolute form gains a year only when the week is in a different one to the present, for the
    /// same reason `SessionsModel.dayHeading(for:now:in:)` does.
    nonisolated static func weekHeading(for start: Date, now: Date, in windows: CalendarWindows) -> String {
        let calendar = windows.calendar
        if let thisWeek = windows.startOfWeek(for: now) {
            if calendar.isDate(start, inSameDayAs: thisWeek) { return "This week" }
            if let lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek),
                calendar.isDate(start, inSameDayAs: lastWeek) {
                return "Last week"
            }
        }

        let base = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        let sameYear =
            calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let style = sameYear ? base.day().month(.wide) : base.day().month(.wide).year()
        return "Week of \(start.formatted(style))"
    }
}
