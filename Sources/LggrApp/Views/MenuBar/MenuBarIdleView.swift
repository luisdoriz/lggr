import SwiftUI
import LggrKit

// The popover with nothing running. See docs/_design/04-screens.md § 5.1 and § 10.2.
//
// This view *is* the empty state. It never says "no session running" — there is nothing to report
// and a great deal to offer, so it offers it.

/// The one async value in the popover: what today amounts to so far.
///
/// A value type rather than a view so the three cases — data, nothing yet, store unavailable — are
/// decided in one place and can be exercised without a store. There is no spinner: a spinner in a
/// 320pt popover is noise, and this line is the only thing here that waits on disk.
public struct MenuBarTodayFooter: Equatable, Sendable {

    public let sessionCount: Int
    public let focusedDuration: TimeInterval
    /// The last store read failed. Nothing else in the popover depends on the store, so this is the
    /// only thing that changes.
    public let isUnavailable: Bool

    public init(sessionCount: Int, focusedDuration: TimeInterval, isUnavailable: Bool = false) {
        self.sessionCount = max(0, sessionCount)
        self.focusedDuration = max(0, focusedDuration)
        self.isUnavailable = isUnavailable
    }

    /// Built from today's finished sessions.
    ///
    /// `effectiveDuration` is `nil` while a session is still running, which is exactly right: a
    /// total that changes once a second is not a total.
    public init(sessions: [FocusSession], isUnavailable: Bool = false) {
        self.init(
            sessionCount: sessions.count,
            focusedDuration: sessions.compactMap(\.effectiveDuration).reduce(0, +),
            isUnavailable: isUnavailable
        )
    }

    /// `Today · 3h 40m focused · 2 sessions`
    public var text: String {
        if isUnavailable { return "Today's totals are unavailable" }
        guard sessionCount > 0 else { return "Nothing tracked yet today" }
        let noun = sessionCount == 1 ? "session" : "sessions"
        return "Today · \(DurationFormatting.compact(focusedDuration)) focused · \(sessionCount) \(noun)"
    }

    /// The same fact without the interpuncts, which VoiceOver reads aloud as "dot".
    public var spokenText: String {
        if isUnavailable { return "Today's totals are unavailable" }
        guard sessionCount > 0 else { return "Nothing tracked yet today" }
        let noun = sessionCount == 1 ? "session" : "sessions"
        let focused = MenuBarLabelState.spokenDuration(focusedDuration)
        return "Today, \(focused) focused, \(sessionCount) \(noun)"
    }
}

/// A block of the day nobody has declared anything over, as the popover offers it.
///
/// `INTELLIGENCE.md` §4 Phase 2 asks for the block in the popover with one keystroke on it, and this
/// is the whole of what reaches a 28pt row inside 320pt: **the range and the measured time.** The
/// application roster is deliberately not in it. It would truncate at this width, and it is one click
/// away on the timeline the sheet opens over — whereas *when* and *how long* is what tells the user
/// which stretch of their morning is being talked about, which is the thing they have to recognise
/// before they can name it.
///
/// A value type rather than a view so the sentence is decided once and can be asserted without a
/// popover, and so the row renders from a fixture with no sampler and no store.
public struct UnlabelledBlockOffer: Equatable, Sendable {

    /// `Label 9:04–9:58 · 41m`
    public let title: String
    /// The same fact without the interpuncts or the en dash, which VoiceOver reads as "dot" and as a
    /// pause.
    public let spokenLabel: String

    public init(title: String, spokenLabel: String) {
        self.title = title
        self.spokenLabel = spokenLabel
    }

    /// Built from the block itself. The duration is the time measured in an application, never the
    /// wall-clock span — the same figure the timeline row shows, so the popover and Today cannot
    /// disagree about how long a block was.
    public init(episode: Episode) {
        let duration = DurationFormatting.compact(episode.activeDuration)
        self.init(
            title: "Label \(TimelineClock.range(from: episode.start, to: episode.end)) · \(duration)",
            spokenLabel: "Label the block from "
                + "\(TimelineClock.spokenRange(from: episode.start, to: episode.end)), \(duration)"
        )
    }
}

/// The six entry actions, in the order `SPEC.md` § 1 requires them.
@MainActor
public struct MenuBarIdleView: View {

    /// What each row does. Every one is a real destination.
    ///
    /// `captureInterruption` is optional so a host with nothing to write into — the gallery, the
    /// snapshot renderer — renders the row dimmed with its reason on hover rather than removing it.
    /// The popover keeps the same shape from build to build and never hides a promised shortcut.
    public struct Actions {
        public var startSession: () -> Void
        public var quickTimer: (Int) -> Void
        public var reviewLastSession: () -> Void
        /// Labels the most recent block nobody declared anything over. Absent when there is no such
        /// block, or no host that can present the sheet — which removes the row rather than dimming
        /// it, because a block that does not exist has no explanation worth a line of the menu.
        public var labelLastBlock: (() -> Void)?
        public var addAccomplishment: () -> Void
        public var captureInterruption: (() -> Void)?
        public var openInbox: () -> Void
        public var openToday: () -> Void
        public var openWeeklyReview: () -> Void

        // Spelled out rather than synthesised: the memberwise initialiser of a public struct is
        // internal, which cannot be referenced from the public default argument below.
        public init(
            startSession: @escaping () -> Void = {},
            quickTimer: @escaping (Int) -> Void = { _ in },
            reviewLastSession: @escaping () -> Void = {},
            labelLastBlock: (() -> Void)? = nil,
            addAccomplishment: @escaping () -> Void = {},
            captureInterruption: (() -> Void)? = nil,
            openInbox: @escaping () -> Void = {},
            openToday: @escaping () -> Void = {},
            openWeeklyReview: @escaping () -> Void = {}
        ) {
            self.startSession = startSession
            self.quickTimer = quickTimer
            self.reviewLastSession = reviewLastSession
            self.labelLastBlock = labelLastBlock
            self.addAccomplishment = addAccomplishment
            self.captureInterruption = captureInterruption
            self.openInbox = openInbox
            self.openToday = openToday
            self.openWeeklyReview = openWeeklyReview
        }
    }

    /// The two durations the quick timer offers. Two, not four: the point is that neither of them
    /// requires a decision.
    public static let quickTimerMinutes = [25, 50]

    /// `⌘⇧L` — one keystroke on the most recent block nobody declared anything over.
    ///
    /// In the `⌘⇧` family the popover already uses for its own rows (`⌘⇧Space`, `⌘⇧A`, `⌘⇧I`) rather
    /// than a global hot key: this is not a fifth thing to configure, it is a row of a menu that is
    /// already open, and `GlobalShortcutAction` deliberately stays at five.
    public static let labelBlockShortcut = KeyboardShortcut("l", modifiers: [.command, .shift])

    private let pendingReview: FocusSession?
    private let unlabelledBlock: UnlabelledBlockOffer?
    private let footer: MenuBarTodayFooter
    private let inboxCount: Int
    private let actions: Actions
    private let tracking: TrackingControls?

    @FocusState private var focus: MenuBarRowID?

    public init(
        pendingReview: FocusSession? = nil,
        unlabelledBlock: UnlabelledBlockOffer? = nil,
        footer: MenuBarTodayFooter,
        inboxCount: Int = 0,
        actions: Actions = Actions(),
        tracking: TrackingControls? = nil
    ) {
        self.pendingReview = pendingReview
        self.unlabelledBlock = unlabelledBlock
        self.footer = footer
        self.inboxCount = max(0, inboxCount)
        self.actions = actions
        self.tracking = tracking
    }

    /// The label row is present only when there is a block to label *and* somewhere to label it.
    ///
    /// Both halves, because either alone is a dead control: an offer with no handler does nothing, and
    /// a handler with no block would have to invent one.
    private var blockOffer: (offer: UnlabelledBlockOffer, action: () -> Void)? {
        guard let unlabelledBlock, let action = actions.labelLastBlock else { return nil }
        return (unlabelledBlock, action)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // A finished session that was never reviewed takes the top of the menu and the accent
            // tint with it. One screen, one primary action: while something is waiting to be
            // answered, answering it is the more useful next step than starting something new.
            if pendingReview != nil {
                MenuBarRow(
                    id: .reviewLastSession,
                    symbol: Icon.MenuBar.awaitingReview,
                    title: "Review last session",
                    isPrimary: true,
                    focus: $focus,
                    action: actions.reviewLastSession
                )
                Color.clear.frame(height: Space.xs)
            }

            MenuBarRow(
                id: .startSession,
                symbol: Icon.startSession,
                title: "Start Focus Session",
                shortcut: KeyboardShortcut(.space, modifiers: [.command, .shift]),
                isPrimary: pendingReview == nil,
                focus: $focus,
                action: actions.startSession
            )

            Color.clear.frame(height: Space.xs)

            // The Phase 2 gesture, one keystroke from the menu bar. Deliberately **below** Start
            // Focus Session and deliberately **not** the primary row: `INTELLIGENCE.md` §7 risk 8 is
            // that reconstruction cannibalises the product it belongs to, and the resolution is that
            // the session stays the primary action. This row is how you catch up, not how you work.
            //
            // Present only while there is a block to label, which is also why it carries no count.
            // A row that is permanently there with a number on it is the "3 undeclared blocks" badge
            // §3.4 removed — a streak counter run in reverse.
            if let blockOffer {
                MenuBarRow(
                    id: .labelLastBlock,
                    symbol: Icon.labelBlock,
                    title: blockOffer.offer.title,
                    shortcut: Self.labelBlockShortcut,
                    focus: $focus,
                    action: blockOffer.action
                )
                .accessibilityLabel(blockOffer.offer.spokenLabel)
            }

            quickTimerRow

            MenuBarRow(
                id: .addAccomplishment,
                symbol: Icon.addAccomplishment,
                title: "Add Accomplishment",
                shortcut: KeyboardShortcut("a", modifiers: [.command, .shift]),
                focus: $focus,
                action: actions.addAccomplishment
            )

            MenuBarRow(
                id: .captureInterruption,
                symbol: Icon.interruption,
                title: "Capture Interruption",
                shortcut: KeyboardShortcut("i", modifiers: [.command, .shift]),
                disabledReason: actions.captureInterruption == nil
                    ? MenuBarCopy.interruptionCaptureUnavailable
                    : nil,
                focus: $focus,
                action: actions.captureInterruption ?? {}
            )

            // Only when there is something in it. An empty inbox is good news and does not need a
            // row to say so — and a row that is permanently present with a zero on it is the
            // beginning of a badge (`INTELLIGENCE.md` § 3.4).
            if inboxCount > 0 {
                MenuBarRow(
                    id: .openInbox,
                    symbol: Icon.inbox,
                    title: "Interruptions",
                    trailingText: "\(inboxCount)",
                    focus: $focus,
                    action: actions.openInbox
                )
            }

            MenuBarDivider()

            MenuBarRow(
                id: .openToday,
                symbol: SidebarSection.today.symbolName,
                title: "Open Today",
                shortcut: KeyboardShortcut("1", modifiers: .command),
                focus: $focus,
                action: actions.openToday
            )

            MenuBarRow(
                id: .openWeeklyReview,
                symbol: SidebarSection.weeklyReview.symbolName,
                title: "Open Weekly Review",
                shortcut: KeyboardShortcut("4", modifiers: .command),
                focus: $focus,
                action: actions.openWeeklyReview
            )

            MenuBarDivider()

            // The price of ambient capture, paid where the user can always see it: what Lggr is
            // recording, and one click to stop it. Absent only when nothing is wired to switch.
            if let tracking {
                TrackingStateRow(controls: tracking)
                Color.clear.frame(height: Space.xs)
            }

            // Not a button. It is the day's total, not a way into anything.
            Text(footer.text)
                .font(Type.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, Space.s)
                .accessibilityLabel(footer.spokenText)
        }
        .defaultFocus($focus, defaultRow)
        // Arrow keys move between rows. macOS limits keyboard navigation to text fields and lists
        // unless the user changes a System Settings toggle, and we never ask them to: the popover
        // installs its own focus chain, and every row additionally carries its own shortcut, so it
        // is operable without ever moving focus at all (§ 7.2).
        .onMoveCommand { direction in move(direction) }
    }

    // MARK: - Quick timer

    /// `⚡ Quick Timer            25m   50m`
    ///
    /// The durations are inline segments rather than a submenu, and pressing one starts immediately
    /// with the last project, the last work type and no outcome. The active view then shows
    /// "Add an outcome" where the outcome would be, so nothing is silently lost.
    private var quickTimerRow: some View {
        HStack(spacing: Space.s) {
            Image(systemName: Icon.quickTimer)
                .imageScale(.medium)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            Text("Quick Timer")
                .font(Type.body)
                .lineLimit(1)

            Spacer(minLength: Space.s)

            ForEach(Self.quickTimerMinutes, id: \.self) { minutes in
                MenuBarSegment(
                    id: .quickTimer(minutes: minutes),
                    title: "\(minutes)m",
                    spokenLabel: "Quick timer, \(minutes) minutes",
                    focus: $focus,
                    action: { actions.quickTimer(minutes) }
                )
            }
        }
        .frame(height: Layout.popoverRowHeight)
        .padding(.horizontal, Space.s)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Timer")
    }

    // MARK: - Keyboard

    private var defaultRow: MenuBarRowID {
        pendingReview != nil ? .reviewLastSession : .startSession
    }

    /// Every row that can currently take focus, top to bottom. The disabled interruption row is not
    /// in the list: arrowing onto something that cannot be pressed is a dead end.
    private var orderedRows: [MenuBarRowID] {
        var rows: [MenuBarRowID] = []
        if pendingReview != nil { rows.append(.reviewLastSession) }
        rows.append(.startSession)
        if blockOffer != nil { rows.append(.labelLastBlock) }
        rows.append(contentsOf: Self.quickTimerMinutes.map { MenuBarRowID.quickTimer(minutes: $0) })
        rows.append(.addAccomplishment)
        if actions.captureInterruption != nil { rows.append(.captureInterruption) }
        if inboxCount > 0 { rows.append(.openInbox) }
        rows.append(contentsOf: [.openToday, .openWeeklyReview])
        return rows
    }

    private func move(_ direction: MoveCommandDirection) {
        let rows = orderedRows
        guard !rows.isEmpty else { return }
        guard let current = focus, let index = rows.firstIndex(of: current) else {
            focus = direction == .up ? rows.last : rows.first
            return
        }
        switch direction {
        // Stops at the ends rather than wrapping. In a nine-row menu, wrapping means the user
        // arrives somewhere they did not aim for and has to read the whole list again.
        case .up:
            focus = rows[max(0, index - 1)]
        case .down:
            focus = rows[min(rows.count - 1, index + 1)]
        // `←`/`→` belong to the quick-timer segments, which sit side by side.
        case .left:
            focus = rows[max(0, index - 1)]
        case .right:
            focus = rows[min(rows.count - 1, index + 1)]
        @unknown default:
            break
        }
    }
}

// MARK: - Segments

/// One inline duration chip. Small, quiet, and pressable with a click, `Return` or `Space`.
@MainActor
struct MenuBarSegment: View {

    private let id: MenuBarRowID
    private let title: String
    private let spokenLabel: String
    private let action: () -> Void

    @FocusState.Binding private var focus: MenuBarRowID?
    @State private var isHovering = false

    init(
        id: MenuBarRowID,
        title: String,
        spokenLabel: String,
        focus: FocusState<MenuBarRowID?>.Binding,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.spokenLabel = spokenLabel
        self._focus = focus
        self.action = action
    }

    private var isFocused: Bool { focus == id }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Type.secondary)
                .monospacedDigit()
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xxs)
                .background(background, in: Theme.chipShape)
                .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focus, equals: id)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .lggrAnimation(Motion.tap, value: isFocused)
        .accessibilityLabel(spokenLabel)
    }

    private var background: Color {
        if isFocused { return Surface.selected }
        if isHovering { return Surface.hover }
        return .clear
    }
}
