import AppKit
import SwiftUI
import LggrKit

// "What happened?" — the session-completion review. See docs/_design/04-screens.md § 5.3.
//
// This sheet appears the moment a work session ends, which is the moment a person has the least
// patience for a form. Everything here is shaped by that:
//
//   • **One required field.** The five statuses. Everything else is pre-filled or optional.
//   • **Two keystrokes to done.** A digit picks the status, `⌘⏎` saves.
//   • **Nothing is lost by leaving.** `Esc` and `Not now` keep the session `.awaitingReview` rather
//     than discarding it; the menu bar grows a `questionmark.circle` and Today grows a Review button.
//
// **Phase 2 shows only the statistics that exist.** § 5.3's wireframe has a line reading
// "52m active · 47m focused · 5m idle · 6 switches · 1 int." and a row of per-application times.
// Focused time, idle time, switches and applications all come from activity tracking, which is Phase
// 3. They are absent here — not zeroed, not redacted, not "—". A number the app cannot measure is not
// a placeholder, it is a false statement about the user's day.

/// The answers the sheet collects, in the shape `SessionManager.submitReview` accepts.
public struct SessionReview: Hashable, Sendable {

    public var status: SessionResultStatus
    /// The summary text, with the tangible result folded in when the user supplied one.
    public var summary: String
    public var blocker: String?
    public var nextStep: String?

    public init(
        status: SessionResultStatus,
        summary: String,
        blocker: String? = nil,
        nextStep: String? = nil
    ) {
        self.status = status
        self.summary = summary
        self.blocker = blocker
        self.nextStep = nextStep
    }
}

/// The completion review sheet, 520pt wide.
///
/// Presentational: it reads no environment and touches no store, so the gallery can render it against
/// `PreviewFixtures` and a caller can drive it from a menu bar popover, a notification action or a
/// Review button on an old session without any of them agreeing on anything.
///
/// ```swift
/// SessionReviewSheet(
///     session: session,
///     project: project,
///     suggestedSummary: sessionManager.suggestedSummary(for: session),
///     regenerate: { sessionManager.suggestedSummary(for: session) },
///     onSave: { review in Task { await sessionManager.submitReview(…) } },
///     onLogAccomplishment: { review, draft in … },
///     onNotNow: { Task { await sessionManager.discardReview() } }
/// )
/// ```
public struct SessionReviewSheet: View {

    /// `⌘⏎` — "Save Review" in the contextual Session menu item of § 7.2.
    public static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    private enum Field: Hashable {
        case status
        case tangibleResult
        case blocker
        case nextStep
    }

    private let session: FocusSession
    private let project: Project?
    private let suggestedSummary: String
    private let regenerate: (() -> String)?
    private let saveFailed: Bool
    private let onSave: (SessionReview) -> Void
    private let onLogAccomplishment: (SessionReview, Accomplishment) -> Void
    private let onNotNow: () -> Void

    @State private var status: SessionResultStatus?
    @State private var summary: String
    @State private var tangibleResult: String = ""
    @State private var blocker: String = ""
    @State private var nextStep: String = ""
    @State private var showsOptionalFields = false
    @State private var showsSaveFailure = false
    @FocusState private var focus: Field?

    /// - Parameters:
    ///   - session: The finished session being reviewed.
    ///   - project: Already resolved by the caller.
    ///   - suggestedSummary: `SessionManager.suggestedSummary(for:)`, used to pre-fill the field.
    ///   - regenerate: Recomputes the suggestion for `⌘R`. When `nil`, `⌘R` restores
    ///     `suggestedSummary`, which is still the useful thing to do.
    ///   - saveFailed: Raises the § 5.3 alert. This is the one place in the app that gets an alert
    ///     rather than a banner, because the user's typed summary is what is at risk.
    ///   - onSave: The primary action.
    ///   - onLogAccomplishment: Receives the same review plus a pre-filled `Accomplishment` the host
    ///     can either save directly or open in the accomplishment editor. Both records are the user's
    ///     intent, so the review is handed over too and is never dropped on the way.
    ///   - onNotNow: Dismisses without discarding. The session stays `.awaitingReview`.
    public init(
        session: FocusSession,
        project: Project?,
        suggestedSummary: String,
        regenerate: (() -> String)? = nil,
        saveFailed: Bool = false,
        onSave: @escaping (SessionReview) -> Void,
        onLogAccomplishment: @escaping (SessionReview, Accomplishment) -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.session = session
        self.project = project
        self.suggestedSummary = suggestedSummary
        self.regenerate = regenerate
        self.saveFailed = saveFailed
        self.onSave = onSave
        self.onLogAccomplishment = onLogAccomplishment
        self.onNotNow = onNotNow
        self._summary = State(initialValue: suggestedSummary)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            ResultStatusPicker(selection: $status)
                .focused($focus, equals: Field.status)

            statistics

            SummaryEditor(text: $summary, onRegenerate: regenerateSummary)

            optionalFields

            Divider()

            actions
        }
        .padding(Space.xl)
        .frame(width: Layout.reviewSheetWidth)
        .defaultFocus($focus, Field.status)
        .onChange(of: status) { _, newValue in follow(up: newValue) }
        .onChange(of: saveFailed, initial: true) { _, failed in showsSaveFailure = failed }
        .alert("Couldn't save this session.", isPresented: $showsSaveFailure) {
            Button("Copy summary", action: copySummary)
            Button("Try again", action: save)
        } message: {
            Text("Try again, or copy the summary so you don't lose it.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What happened")
    }

    // MARK: - Header

    /// The question is chrome; the sentence being judged is the content. Hence `Type.sectionTitle`
    /// above `Type.outcome` — the smaller line is the one that repeats on every session.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("What happened?")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            Text(session.intendedOutcome)
                .font(Type.outcome)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            HStack(spacing: Space.s) {
                ProjectBadge(project: project)

                separator

                Text(session.workType.displayName)

                separator

                Text(timeRange)
            }
            .font(Type.secondary)
            .foregroundStyle(.secondary)
            .padding(.top, Space.xxs)
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// "9:00 – 9:52", in the user's own time format.
    private var timeRange: String {
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        guard let endedAt = session.endedAt else { return start }
        return start + " – " + endedAt.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Statistics

    /// Everything Phase 2 can honestly say about the session: how long it ran, and how much of that
    /// was a pause. Pause time is omitted entirely when there was none — "0m paused" is a fact nobody
    /// needs and a word the eye has to skip.
    private var statistics: some View {
        Text(statisticsText)
            .font(Type.secondary)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Session length")
            .accessibilityValue(statisticsText)
    }

    private var statisticsText: String {
        var parts = ["\(DurationFormatting.compact(activeDuration)) active"]
        if pausedDuration >= 60 {
            parts.append("\(DurationFormatting.compact(pausedDuration)) paused")
        }
        return parts.joined(separator: " · ")
    }

    private var activeDuration: TimeInterval {
        session.effectiveDuration ?? session.elapsed(at: session.endedAt ?? session.startedAt)
    }

    private var pausedDuration: TimeInterval {
        session.totalPausedDuration(at: session.endedAt ?? session.startedAt)
    }

    // MARK: - Optional fields

    /// Collapsed until asked for, or until the chosen status makes one of them the obvious next
    /// question. Three text fields on screen before the user has answered the one required question
    /// is a form, and this sheet is not a form.
    private var optionalFields: some View {
        DisclosureGroup(isExpanded: $showsOptionalFields) {
            VStack(alignment: .leading, spacing: Space.m) {
                field(
                    "Tangible result",
                    prompt: "What exists now that didn't before?",
                    text: $tangibleResult,
                    focus: .tangibleResult
                )
                field(
                    "Blocker",
                    prompt: "What's in the way?",
                    text: $blocker,
                    focus: .blocker
                )
                field(
                    "Next step",
                    prompt: "What's the next concrete step?",
                    text: $nextStep,
                    focus: .nextStep
                )
            }
            .padding(.top, Space.m)
        } label: {
            Text("Add result, blocker or next step")
                .font(Type.secondary)
                .foregroundStyle(.secondary)
        }
        .lggrAnimation(Motion.reveal, value: showsOptionalFields)
    }

    private func field(
        _ label: String,
        prompt: String,
        text: Binding<String>,
        focus field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label)
                .font(Type.caption)
                .foregroundStyle(.secondary)

            TextField(label, text: text, prompt: Text(prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(Type.body)
                .lineLimit(1...3)
                .padding(Space.s)
                .background(Surface.sunken, in: Theme.chipShape)
                .overlay(Theme.chipShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
                .focused($focus, equals: field)
        }
    }

    /// A status that did not land is a useful question, not a warning. The disclosure opens and the
    /// relevant field takes focus — no colour change, no icon, no "are you sure".
    private func follow(up status: SessionResultStatus?) {
        guard let status, status.needsFollowUp else { return }
        showsOptionalFields = true
        focus = status == .blocked ? .blocker : .nextStep
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Space.m) {
            Button("Not now", action: onNotNow)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Leave this session unreviewed. Nothing is lost.")

            Spacer(minLength: Space.m)

            Button("Log accomplishment", action: logAccomplishment)
                .buttonStyle(.bordered)
                .disabled(review == nil)
                .help("Save this review and record what you delivered")

            Button("Save", action: save)
                .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                .keyboardShortcut(Self.saveShortcut)
                .disabled(review == nil)
        }
    }

    // MARK: - Assembling the answer

    /// `nil` until a status is chosen, which is also what disables both save buttons. One source of
    /// truth for "is this answerable yet" rather than a separate `isValid`.
    private var review: SessionReview? {
        guard let status else { return nil }
        return SessionReview(
            status: status,
            summary: composedSummary,
            blocker: Self.trimmedOrNil(blocker),
            nextStep: Self.trimmedOrNil(nextStep)
        )
    }

    /// The tangible result is appended to the summary rather than stored on its own.
    ///
    /// `FocusSession` has `resultSummary`, `blocker` and `nextStep` and no fourth field, so the honest
    /// options are to keep the user's sentence inside the summary or to throw it away. It is kept,
    /// on its own line, exactly as typed.
    private var composedSummary: String {
        let base = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = Self.trimmedOrNil(tangibleResult) else { return base }
        return base.isEmpty ? result : base + "\n\n" + result
    }

    private func save() {
        guard let review else { return }
        onSave(review)
    }

    private func logAccomplishment() {
        guard let review else { return }
        onLogAccomplishment(review, accomplishmentDraft())
    }

    /// A draft, not a record: the host is expected to open it in the accomplishment editor so the
    /// user can correct the guessed type before anything is written.
    private func accomplishmentDraft() -> Accomplishment {
        Accomplishment(
            projectID: session.projectID,
            focusSessionID: session.id,
            type: Self.accomplishmentType(for: session.workType),
            title: Self.trimmedOrNil(tangibleResult) ?? session.intendedOutcome,
            timestamp: session.endedAt ?? session.startedAt
        )
    }

    /// § 5.3 guesses the type from the session's dominant activity category, which needs Phase 3.
    /// Until then the work type is the only evidence available, and only four of the eight map onto
    /// something specific enough to be worth pre-selecting. The rest open on `Other`, which is a
    /// smaller correction than a confidently wrong guess.
    private static func accomplishmentType(for workType: WorkType) -> AccomplishmentType {
        switch workType {
        case .codeReview: .pullRequestReviewed
        case .incident: .incidentResolved
        case .planning: .decisionMade
        case .deepWork: .featureCompleted
        case .management, .communication, .meeting, .administrative: .other
        }
    }

    private func regenerateSummary() {
        summary = regenerate?() ?? suggestedSummary
    }

    /// The alert's escape hatch: if the write keeps failing, the words the user typed are still
    /// theirs to keep. `NSPasteboard` is the only route to the clipboard from an alert button.
    private func copySummary() {
        let text = composedSummary
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
