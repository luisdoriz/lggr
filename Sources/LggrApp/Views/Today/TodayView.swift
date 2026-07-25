import LggrKit
import SwiftUI

// Today — the default screen and the app's face. See docs/_design/04-screens.md § 4.1.
//
// What this screen is, and is not:
//
//   * It is the day, read top to bottom: what you are doing now, what you finished, what you
//     delivered. Three things, in that order, separated by `Space.xxl` of air.
//   * It is **not** a dashboard. There is exactly one card on it — the active session — and that is
//     because a card means "this container has its own primary action" (see `Card`). Everything else
//     is a headed list on the bare canvas.
//
// Two sections from § 4.1 are deliberately absent rather than rendered empty: "Working toward"
// (needs `WeeklyOutcome`, `[P5]`) and "Time allocation" (needs the category classification of a
// later phase). Showing them as zeros would tell the user they did nothing today, which is exactly
// the shaming tone the design direction forbids. A section arrives when its data does — which is
// also why "Day" is an optional parameter here and renders only once there is a day to draw.
//
// **This view never reads `SessionManager.now`.** The 1 Hz tick belongs to the timer inside the
// session card, and Observation only invalidates the view that performed the read (SPIKE-menubar.md).
// Reading `now` here would repaint the whole screen once a second to change nothing.

/// What Today can do. Every one of these is wired by the host; the view itself owns no behaviour.
///
/// The two `delete` handlers are optional because deletion is not part of the `SessionManager`
/// contract in Phase 2. When a handler is absent the menu item is absent too — a menu that offers an
/// action it cannot perform is worse than one that does not offer it.
public struct TodayActions {
    public var startSession: () -> Void
    public var addAccomplishment: () -> Void
    public var reviewSession: (FocusSession) -> Void
    public var logAccomplishment: (FocusSession) -> Void
    public var editAccomplishment: (Accomplishment) -> Void
    /// Opens the interruption inbox. Processing happens there, not here: Today's job is to say that
    /// something is waiting, in one line, and then get out of the way.
    public var reviewInbox: () -> Void
    public var deleteSession: ((FocusSession) -> Void)?
    public var deleteAccomplishment: ((Accomplishment) -> Void)?

    public init(
        startSession: @escaping () -> Void = {},
        addAccomplishment: @escaping () -> Void = {},
        reviewSession: @escaping (FocusSession) -> Void = { _ in },
        logAccomplishment: @escaping (FocusSession) -> Void = { _ in },
        editAccomplishment: @escaping (Accomplishment) -> Void = { _ in },
        reviewInbox: @escaping () -> Void = {},
        deleteSession: ((FocusSession) -> Void)? = nil,
        deleteAccomplishment: ((Accomplishment) -> Void)? = nil
    ) {
        self.startSession = startSession
        self.addAccomplishment = addAccomplishment
        self.reviewSession = reviewSession
        self.logAccomplishment = logAccomplishment
        self.editAccomplishment = editAccomplishment
        self.reviewInbox = reviewInbox
        self.deleteSession = deleteSession
        self.deleteAccomplishment = deleteAccomplishment
    }
}

/// `⌘N` and `⌘⇧A` are also real menu commands (`04-screens.md` § 7.1), so these registrations are
/// duplicates that perform the identical action — which is exactly why they are safe. They exist so
/// the hint renders on the button and the shortcut works with the menu bar hidden.
///
/// File scope rather than a `static let` on `TodayView`: static stored properties are not permitted
/// in a generic type.
/// How much of a growing list Today is willing to show.
///
/// File scope for the same reason `TodayShortcut` is: static stored properties are not permitted in a
/// generic type.
private enum TodayLimits {
    /// Three interruptions at most. This is the last section of the screen, and a list that can grow
    /// without limit at the bottom of the day would turn Today into a queue.
    static let interruptionPreview = 3
}

private enum TodayShortcut {
    static let startFocus = KeyboardShortcut("n", modifiers: .command)
    static let addAccomplishment = KeyboardShortcut("a", modifiers: [.command, .shift])
}

/// The Today screen.
///
/// The active session block is injected as a `@ViewBuilder` slot rather than constructed here. Today
/// decides *whether* a session is in flight and *where* its card sits; what a running timer looks
/// like belongs to the focus views. That also means this screen renders, in full, against fixtures
/// with no store, no clock and no timer — which is how it is reviewed on a machine with no `#Preview`.
public struct TodayView<SessionCard: View>: View {

    private let today: Date
    private let hasActiveSession: Bool
    private let sessions: [FocusSession]
    private let accomplishments: [Accomplishment]
    private let projects: [Project]
    private let timeline: DayTimeline?
    private let interruptions: [Interruption]
    private let actions: TodayActions
    private let sessionCard: SessionCard

    public init(
        today: Date,
        hasActiveSession: Bool,
        sessions: [FocusSession],
        accomplishments: [Accomplishment],
        projects: [Project],
        timeline: DayTimeline? = nil,
        interruptions: [Interruption] = [],
        actions: TodayActions = TodayActions(),
        @ViewBuilder sessionCard: () -> SessionCard
    ) {
        self.today = today
        self.hasActiveSession = hasActiveSession
        self.sessions = sessions
        self.accomplishments = accomplishments
        self.projects = projects
        self.timeline = timeline
        self.interruptions = interruptions
        self.actions = actions
        self.sessionCard = sessionCard()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)

            if isDayEmpty {
                // The first thing a new user ever sees. It gets the whole canvas, and the one next
                // step is right there in it.
                emptyDay
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today")
    }

    // MARK: - Chrome

    /// Renders immediately and is never gated on data (`04-screens.md` § 3.2).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Text("Today")
                .font(Type.screenTitle)
                .foregroundStyle(.primary)
            Spacer(minLength: Space.m)
            Text(today.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(Type.secondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - The day

    private var content: some View {
        // `ScrollingSection`, not `ScrollView`: identical in the app, and the difference is what
        // makes this screen visible to `LggrApp --snapshot`. See `ScrollingSection`.
        ScrollingSection {
            VStack(alignment: .leading, spacing: Space.xxl) {
                sessionBlock
                if !sessions.isEmpty { sessionsSection }
                accomplishmentsSection
                daySection
                interruptionsSection
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One place, one button, and it retitles: the card owns **Finish** while a session runs, and
    /// this owns **Start Focus** while none does (`04-screens.md` § 4.1).
    @ViewBuilder private var sessionBlock: some View {
        if hasActiveSession {
            sessionCard
        } else {
            Button("Start Focus", action: actions.startSession)
                .buttonStyle(.lggrPrimary(shortcut: TodayShortcut.startFocus))
                .keyboardShortcut(TodayShortcut.startFocus)
        }
    }

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Focus sessions", count: sessions.count)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(orderedSessions) { session in
                    SessionRow(
                        session: session,
                        project: project(for: session.projectID),
                        onReview: { actions.reviewSession(session) },
                        onAddAccomplishment: { actions.logAccomplishment(session) },
                        onDelete: deleteAction(for: session)
                    )
                }
            }
        }
    }

    private var accomplishmentsSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(
                "Accomplishments",
                actionTitle: "Add",
                shortcut: TodayShortcut.addAccomplishment,
                action: actions.addAccomplishment
            )

            if accomplishments.isEmpty {
                // No shortcut hint on this button: `⌘⇧A` is already registered by the section header
                // a few points above it, and registering the same combination twice in one view tree
                // makes which one fires undefined.
                EmptyStateView(
                    symbol: Icon.emptyDone,
                    title: "No accomplishments logged today.",
                    message: "Add one when something ships, or let a finished session suggest it.",
                    actionTitle: "Add",
                    action: actions.addAccomplishment
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(orderedAccomplishments) { accomplishment in
                        AccomplishmentRow(
                            accomplishment: accomplishment,
                            project: project(for: accomplishment.projectID),
                            onEdit: { actions.editAccomplishment(accomplishment) },
                            onDelete: deleteAction(for: accomplishment)
                        )
                    }
                }
            }
        }
    }

    /// The reconstructed day, last on the screen and last in § 4.1's hierarchy.
    ///
    /// It renders only when there is a day to render. An empty strip under a heading would say
    /// "Lggr watched all morning and found nothing", which is a claim about the record that is
    /// almost always false — the usual reason for an empty timeline is that capture has not run yet.
    @ViewBuilder private var daySection: some View {
        if let timeline, !timeline.isEmpty {
            DayTimelineStrip(timeline: timeline)
        }
    }

    /// The interruption inbox: last on the screen, last in § 4.1's hierarchy, and absent when it is
    /// empty.
    ///
    /// An empty inbox is good news and does not need a paragraph about it — nor a heading with a zero
    /// beside it, which is how a count becomes a scold. Processing lives in the inbox itself; this is
    /// two or three lines of evidence and one way in.
    @ViewBuilder private var interruptionsSection: some View {
        if !interruptions.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(
                    "Interruptions",
                    count: interruptions.count,
                    actionTitle: "Review",
                    action: actions.reviewInbox
                )

                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(previewedInterruptions) { interruption in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                            Text(interruption.description)
                                .font(Type.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Spacer(minLength: Space.m)

                            Text(
                                interruption.timestamp
                                    .formatted(date: .omitted, time: .shortened)
                            )
                            .font(Type.secondary)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }

                    if interruptions.count > TodayLimits.interruptionPreview {
                        Text("\(interruptions.count - TodayLimits.interruptionPreview) more in the inbox.")
                            .font(Type.caption)
                            .foregroundStyle(Ink.support)
                    }
                }
            }
        }
    }

    private var previewedInterruptions: [Interruption] {
        Array(
            interruptions
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(TodayLimits.interruptionPreview)
        )
    }

    private var emptyDay: some View {
        EmptyStateView(
            symbol: Icon.emptyToday,
            title: "Nothing tracked yet today.",
            message: "Start a session and this fills itself in.",
            actionTitle: "Start Focus",
            shortcut: TodayShortcut.startFocus,
            action: actions.startSession
        )
    }

    // MARK: - Derived

    /// The reconstructed day counts. This is the whole point of ambient capture: a morning nobody
    /// declared is still a morning, and a screen that says "Nothing tracked yet today" over nine
    /// recorded blocks would be the app calling its own evidence nothing.
    private var isDayEmpty: Bool {
        !hasActiveSession && sessions.isEmpty && accomplishments.isEmpty
            && (timeline?.isEmpty ?? true) && interruptions.isEmpty
    }

    /// Both lists read oldest first, so the screen reads as the day did — top to bottom.
    ///
    /// `SessionManager` hands both collections over newest first, which is the right order for a
    /// history screen and the wrong one for a day.
    private var orderedSessions: [FocusSession] {
        sessions.sorted { $0.startedAt < $1.startedAt }
    }

    private var orderedAccomplishments: [Accomplishment] {
        accomplishments.sorted { $0.timestamp < $1.timestamp }
    }

    private func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    // Written as methods rather than inline `Optional.map` so the closure-returning-a-closure type is
    // spelled out once instead of inferred at four call sites.
    private func deleteAction(for session: FocusSession) -> (() -> Void)? {
        guard let handler = actions.deleteSession else { return nil }
        return { handler(session) }
    }

    private func deleteAction(for accomplishment: Accomplishment) -> (() -> Void)? {
        guard let handler = actions.deleteAccomplishment else { return nil }
        return { handler(accomplishment) }
    }
}

// MARK: - No session card

extension TodayView where SessionCard == EmptyView {
    /// Today with no active-session card — the idle screen, and the shape the gallery renders.
    public init(
        today: Date,
        sessions: [FocusSession] = [],
        accomplishments: [Accomplishment] = [],
        projects: [Project] = [],
        timeline: DayTimeline? = nil,
        interruptions: [Interruption] = [],
        actions: TodayActions = TodayActions()
    ) {
        self.init(
            today: today,
            hasActiveSession: false,
            sessions: sessions,
            accomplishments: accomplishments,
            projects: projects,
            timeline: timeline,
            interruptions: interruptions,
            actions: actions
        ) {
            EmptyView()
        }
    }
}
