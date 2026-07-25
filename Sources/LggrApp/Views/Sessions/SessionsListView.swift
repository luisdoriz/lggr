import AppKit
import LggrKit
import SwiftUI

// Focus Sessions (`⌘2`) — the full history. See docs/_design/04-screens.md § 4.2 and SPEC.md § 10.
//
// What this screen is: every session you have finished, grouped by day, newest first, going back as
// far as you care to walk. What you are scanning for is the sentence you wrote before you started —
// so the intended outcome is the only thing on a row set in `Type.rowTitle`, and everything else on
// it is demoted.
//
// Three decisions this file holds:
//
//   * **A range, not a page.** The header names the stretch of history on screen and steps through it
//     a month (or quarter, or year) at a time. There is no "load more", because the user's question is
//     "what did I do in July", and a growing list cannot answer it — see `HistoryWindow`.
//   * **An unreviewed session is offered, never scolded.** A session that finished without an answer
//     to "What happened?" shows `Review` where its result would be. That is the recovery path for
//     "the app quit before I answered", and it is the reason a session is never stranded.
//   * **No total anywhere.** The header carries the count of rows in the range, which is a fact about
//     the list. There is no focused-hours headline, no completion rate and no streak;
//     `INTELLIGENCE.md` § 3.4 removed every number that behaves like a score and this is exactly the
//     screen where the next one would arrive.
//
// Rows are `Button`s rather than `NavigationLink`s so the screen renders and photographs outside a
// `NavigationStack`; the host decides what "open" means and does the pushing.

/// Where a pushed session detail lives on the detail column's `NavigationPath`.
///
/// A named type rather than a bare `UUID`: the path is shared by every section, and a raw `UUID`
/// would make a future route indistinguishable from this one.
public struct SessionRoute: Hashable, Sendable {
    public let sessionID: UUID

    public init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

/// Everything this screen can do. Each one is wired by the host; the view owns no behaviour.
///
/// `review` is optional in the same spirit `TodayActions`' delete handlers are: when the host cannot
/// re-open a session for review, the control is absent rather than inert.
public struct SessionsActions {
    public var newSession: () -> Void
    public var open: (FocusSession) -> Void
    public var review: ((FocusSession) -> Void)?
    public var addAccomplishment: (FocusSession) -> Void
    public var step: (Int) -> Void
    public var setSpan: (HistoryWindow.Span) -> Void
    public var goToLatest: () -> Void
    public var clearFilters: () -> Void

    public init(
        newSession: @escaping () -> Void = {},
        open: @escaping (FocusSession) -> Void = { _ in },
        review: ((FocusSession) -> Void)? = nil,
        addAccomplishment: @escaping (FocusSession) -> Void = { _ in },
        step: @escaping (Int) -> Void = { _ in },
        setSpan: @escaping (HistoryWindow.Span) -> Void = { _ in },
        goToLatest: @escaping () -> Void = {},
        clearFilters: @escaping () -> Void = {}
    ) {
        self.newSession = newSession
        self.open = open
        self.review = review
        self.addAccomplishment = addAccomplishment
        self.step = step
        self.setSpan = setSpan
        self.goToLatest = goToLatest
        self.clearFilters = clearFilters
    }
}

/// `⌘N` is also a real menu command (`04-screens.md` § 7.1). Registering it here as well is a
/// deliberate duplicate that performs the identical action, so the hint renders on the button and the
/// shortcut still works with the menu bar hidden — the same arrangement `TodayView` and `ProjectsView`
/// use.
private enum SessionsShortcut {
    static let newSession = KeyboardShortcut("n", modifiers: .command)
}

/// The Focus Sessions history.
public struct SessionsListView: View {

    private let window: HistoryWindow.Display
    private let days: [SessionsModel.Day]
    private let projects: [Project]
    private let sessionsInWindow: Int
    private let isLoading: Bool
    private let isFiltering: Bool
    private let searchText: Binding<String>
    private let projectFilter: Binding<UUID?>
    private let actions: SessionsActions

    public init(
        window: HistoryWindow.Display,
        days: [SessionsModel.Day],
        projects: [Project] = [],
        sessionsInWindow: Int = 0,
        isLoading: Bool = false,
        isFiltering: Bool = false,
        searchText: Binding<String> = .constant(""),
        projectFilter: Binding<UUID?> = .constant(nil),
        actions: SessionsActions = SessionsActions()
    ) {
        self.window = window
        self.days = days
        self.projects = projects
        self.sessionsInWindow = sessionsInWindow
        self.isLoading = isLoading
        self.isFiltering = isFiltering
        self.searchText = searchText
        self.projectFilter = projectFilter
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Focus Sessions")
    }

    // MARK: - Chrome

    /// Renders immediately and is never gated on data (`04-screens.md` § 3.2). Two rows: the screen
    /// and its one primary action on top, the range and the filters underneath.
    private var chrome: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text("Focus Sessions")
                    .font(Type.screenTitle)
                    .foregroundStyle(.primary)

                Spacer(minLength: Space.m)

                // Absent when the empty state below is already offering the same action. One
                // prominent button per screen — and registering `⌘N` twice in one view tree makes
                // which one fires undefined.
                if !emptyStateOwnsPrimaryAction {
                    Button("New Focus Session", action: actions.newSession)
                        .buttonStyle(.lggrPrimary(shortcut: SessionsShortcut.newSession))
                        .keyboardShortcut(SessionsShortcut.newSession)
                }
            }

            HStack(spacing: Space.m) {
                HistoryWindowBar(
                    window: window,
                    onStep: actions.step,
                    onSpanChange: actions.setSpan,
                    onGoToLatest: actions.goToLatest,
                    rowCount: sessionsInWindow > 0 ? sessionsInWindow : nil,
                    rowNoun: (singular: "session", plural: "sessions")
                )

                Spacer(minLength: Space.m)

                HistorySearchField(prompt: "Search outcomes", text: searchText)

                HistoryFilterMenu(
                    allTitle: "All projects",
                    options: projectOptions,
                    selection: projectFilter
                )
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    /// Only the projects that appear in the loaded range. A filter that can only ever return nothing
    /// is a filter that makes the user do the app's work.
    private var projectOptions: [HistoryFilterMenu<UUID>.Option] {
        let present = Set(days.flatMap(\.sessions).compactMap(\.projectID))
        return projects
            .filter { present.contains($0.id) }
            .map { project in
                HistoryFilterMenu<UUID>.Option(
                    value: project.id,
                    title: project.normalizedName ?? project.name,
                    leading: AnyView(ProjectDot(project: project))
                )
            }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if days.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        // `ScrollingSection`, not `ScrollView`: a scroll view contributes no drawing at all under
        // `ImageRenderer`, which is how every screen here is reviewed for light and dark without
        // Xcode. See `ScrollingSection`.
        ScrollingSection {
            // `spacing: 0`, with the air owned by the pieces: `Space.m` under a heading and
            // `Space.xxl` under a group. A uniform `LazyVStack` spacing applies *between a section's
            // header and its own content* as well as between sections, which pushes every day heading
            // 32pt away from the rows it names.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(days) { day in
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(day.sessions) { session in
                                SessionHistoryRow(
                                    session: session,
                                    project: project(for: session.projectID),
                                    onOpen: { actions.open(session) },
                                    onReview: reviewAction(for: session),
                                    onAddAccomplishment: { actions.addAccomplishment(session) }
                                )
                            }
                        }
                        .padding(.bottom, Space.xxl)
                    } header: {
                        dayHeader(day)
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.l)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pinned while scrolling, per § 4.2, which is what keeps "which day am I looking at" answered
    /// during a long scroll. It gets the canvas behind it so the rows do not read through it.
    private func dayHeader(_ day: SessionsModel.Day) -> some View {
        SectionHeader(day.heading, count: day.sessions.count)
            .padding(.top, Space.s)
            .padding(.bottom, Space.m)
            .background(Surface.canvas)
    }

    // MARK: - Empty states

    /// Four different facts, four different sentences. The distinction that matters is between "you
    /// have not started one yet" — where offering to start one is the whole point — and "there is
    /// nothing in June", where offering to start one would be a non-sequitur.
    /// True when the screen is showing the "nothing yet" state, whose one button is the same action
    /// the header would otherwise carry.
    private var emptyStateOwnsPrimaryAction: Bool {
        days.isEmpty && !isLoading && !isFiltering && window.isCurrent
    }

    @ViewBuilder private var emptyState: some View {
        if isLoading {
            loadingState
        } else if isFiltering {
            noMatchesState
        } else if window.isCurrent {
            EmptyStateView(
                symbol: Icon.emptySessions,
                title: "No focus sessions yet.",
                message: "Your first one takes about five seconds to start.",
                actionTitle: "New Focus Session",
                shortcut: SessionsShortcut.newSession,
                action: actions.newSession
            )
        } else {
            EmptyStateView(
                symbol: Icon.emptySessions,
                title: "Nothing in \(window.title).",
                message: "Sessions you finish are filed under the day they ran. Step to another range to look further back.",
                actionTitle: "Now",
                action: actions.goToLatest
            )
        }
    }

    private var noMatchesState: some View {
        EmptyStateView(
            symbol: Icon.search,
            title: noMatchesTitle,
            message: "Try a shorter phrase, or clear the project filter.",
            actionTitle: "Clear Filters",
            action: actions.clearFilters
        )
    }

    /// § 10.10's string, with the user's own query in it. When the query is empty the filter is the
    /// project, so the sentence says so rather than quoting nothing.
    private var noMatchesTitle: String {
        let query = searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Nothing here matches that filter." }
        return "Nothing matches \u{201C}\(query)\u{201D}."
    }

    /// § 3.2: the layout, redacted, for the first 250ms — never a spinner and never a shimmer. Three
    /// rows under two headings, which is the shape the screen is about to have.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            ForEach(0..<2, id: \.self) { group in
                VStack(alignment: .leading, spacing: Space.m) {
                    SectionHeader(group == 0 ? "Today" : "Yesterday")
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<3, id: \.self) { row in
                            SessionHistoryRow(
                                session: FocusSession(
                                    id: Self.placeholderID(group * 3 + row),
                                    intendedOutcome: "Loading this range",
                                    startedAt: Self.placeholderDate,
                                    endedAt: Self.placeholderDate,
                                    resultStatus: .completed
                                ),
                                project: nil
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    /// A fixed instant for the redacted rows. `Date()` would be re-read on every render, changing the
    /// width of a string nobody can read anyway.
    private static let placeholderDate = Date(timeIntervalSinceReferenceDate: 0)

    /// Stable identifiers for the redacted rows, so the placeholder does not reshuffle while it is on
    /// screen. Built from a fixed byte pattern rather than `UUID()`.
    private static func placeholderID(_ index: Int) -> UUID {
        UUID(
            uuid: (
                0x10, 0x66, 0x67, 0x72, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, UInt8(truncatingIfNeeded: index)
            ))
    }

    // MARK: - Derived

    private func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    /// Reviewing is offered only for a session that has no result, and only when the host can
    /// actually perform it.
    private func reviewAction(for session: FocusSession) -> (() -> Void)? {
        guard session.resultStatus == nil, let review = actions.review else { return nil }
        return { review(session) }
    }
}

// MARK: - The row

/// One finished session in the history. See `04-screens.md` § 4.2.
///
/// A history row and a Today row want the same hierarchy and different affordances: Today's
/// `SessionRow` is terminal — the session is right there — while this one opens a detail view, so the
/// whole text column is a button, a disclosure chevron fades in on hover, and the trailing controls
/// sit *outside* the button rather than nested inside it. Nesting a `Review` button and a `⋯` menu
/// inside another button is the one arrangement AppKit genuinely cannot route clicks through.
///
/// The result is rendered in `.secondary`, never in colour. A blocked session is information, not a
/// failure, and red exists in exactly one place in Lggr: the confirm button of a delete alert.
struct SessionHistoryRow: View {

    let session: FocusSession
    let project: Project?
    var onOpen: (() -> Void)?
    var onReview: (() -> Void)?
    var onAddAccomplishment: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Button {
                onOpen?()
            } label: {
                HStack(alignment: .top, spacing: Space.s) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(session.intendedOutcome)
                            .font(Type.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)

                        metadata
                    }

                    Spacer(minLength: Space.s)

                    Image(systemName: Icon.disclosureClosed)
                        .imageScale(.small)
                        .foregroundStyle(.tertiary)
                        .opacity(isHovered ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onOpen == nil)
            .accessibilityLabel(session.intendedOutcome)
            .accessibilityValue(spokenDetail)
            .accessibilityHint("Opens the session")

            trailing
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        // The hover fill bleeds `Space.s` past the text column on both sides so the text stays
        // aligned with the heading above it. A row that indents on hover is a row that moves.
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .contextMenu { actionItems }
    }

    // MARK: Metadata

    /// `● Receipt ingestion · Deep work · 9:00–9:52 · 52m`, and a quiet interruption count when there
    /// was one. Assembled as one `Text` after the badge so the whole line truncates as a unit and the
    /// interpuncts never end up orphaned on a wrap.
    private var metadata: some View {
        HStack(spacing: Space.xs) {
            ProjectBadge(project: project, variant: .compact)
            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
            Text(metadataText)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityHidden(true)
    }

    private var metadataText: String {
        var parts = [session.workType.displayName]
        if let range = timeRange { parts.append(range) }
        if let duration = session.effectiveDuration {
            parts.append(DurationFormatting.compact(duration))
        }
        if session.interruptionCount > 0 {
            parts.append(SessionHistoryRow.interruptionPhrase(session.interruptionCount))
        }
        return parts.joined(separator: " · ")
    }

    /// "1 interruption" / "3 interruptions". A count of notes the user chose to write down, not a
    /// measure of how well the session went.
    static func interruptionPhrase(_ count: Int) -> String {
        count == 1 ? "1 interruption" : "\(count) interruptions"
    }

    private var timeRange: String? {
        guard let endedAt = session.endedAt else { return nil }
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        let end = endedAt.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    // MARK: Trailing

    private var trailing: some View {
        HStack(spacing: Space.s) {
            result
            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
    }

    /// The result, or the way back to answering for it. A finished session with no answer is not shown
    /// as abandoned: it is offered.
    @ViewBuilder private var result: some View {
        if let status = session.resultStatus {
            Label(status.displayName, systemImage: status.symbolName)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .imageScale(.medium)
                .lineLimit(1)
                .fixedSize()
        } else if let onReview {
            Button("Review", action: onReview)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Answer what happened in this session")
        } else {
            // No handler, so no control. The row still says the session has no result rather than
            // implying it had one, and it says it as a fact.
            Text("Not reviewed")
                .font(Type.secondary)
                .foregroundStyle(Ink.support)
                .fixedSize()
        }
    }

    // MARK: Actions

    /// One list, rendered as both the context menu and the hover menu, so the two cannot drift.
    @ViewBuilder private var actionItems: some View {
        if let onOpen {
            Button("Open", action: onOpen)
        }
        if session.resultStatus == nil, let onReview {
            Button("Review", action: onReview)
        }
        if let onAddAccomplishment {
            Button("Add accomplishment", action: onAddAccomplishment)
        }
        Button("Copy outcome") { Pasteboard.copy(session.intendedOutcome) }
        if let summary = session.resultSummary, !summary.isEmpty {
            Button("Copy summary") { Pasteboard.copy(summary) }
        }
    }

    // MARK: VoiceOver

    private var spokenDetail: String {
        var parts: [String] = []
        if let name = project?.normalizedName { parts.append(name) }
        parts.append(session.workType.displayName)
        if let range = timeRange { parts.append(range) }
        if let duration = session.effectiveDuration {
            parts.append(DurationFormatting.compact(duration))
        }
        if session.interruptionCount > 0 {
            parts.append(SessionHistoryRow.interruptionPhrase(session.interruptionCount))
        }
        parts.append(session.resultStatus?.displayName ?? "Not reviewed")
        return parts.joined(separator: ", ")
    }
}
