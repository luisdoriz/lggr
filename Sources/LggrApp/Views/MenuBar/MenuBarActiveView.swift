import SwiftUI
import LggrKit

// The popover with a session running. See docs/_design/04-screens.md § 5.1, § 6.4 and § 10.4.
//
// Hierarchy, in the order the design document sets it: 1. the timer. 2. the intended outcome.
// 3. Finish. 4. project and work type. 5. everything else.
//
// Everything this view draws is passed in. It holds no store, no manager and no clock, so the
// snapshot gallery can render running, paused, overtime and open-ended side by side from
// `PreviewFixtures` with no live state at all.

@MainActor
public struct MenuBarActiveView: View {

    /// The five things the running popover can do.
    ///
    /// `captureInterruption` is optional for the same reason it is in the idle menu: the feature has
    /// not arrived, and a dimmed row that explains itself is more honest than a missing one.
    ///
    /// `discard` is optional on a different principle. It is the one irreversible action here, so a
    /// host that cannot actually discard anything gets **no row at all** rather than a dimmed one:
    /// "throw this away" is not a promise to make and then explain away on hover.
    public struct Actions {
        public var togglePause: () -> Void
        public var finish: () -> Void
        public var captureInterruption: (() -> Void)?
        /// Called only after the popover's own confirmation has been answered.
        public var discard: (() -> Void)?
        public var openApp: () -> Void

        // Spelled out rather than synthesised: the memberwise initialiser of a public struct is
        // internal, which cannot be referenced from the public default argument below.
        public init(
            togglePause: @escaping () -> Void = {},
            finish: @escaping () -> Void = {},
            captureInterruption: (() -> Void)? = nil,
            discard: (() -> Void)? = nil,
            openApp: @escaping () -> Void = {}
        ) {
            self.togglePause = togglePause
            self.finish = finish
            self.captureInterruption = captureInterruption
            self.discard = discard
            self.openApp = openApp
        }
    }

    private let session: FocusSession
    private let project: Project?
    private let now: Date
    private let actions: Actions
    private let tracking: TrackingControls?

    @FocusState private var focus: MenuBarRowID?

    /// Raised by the Discard row, and answered by the two rows that replace it.
    ///
    /// A pair of rows rather than an `.alert`: this popover lives in a window SwiftUI owns privately
    /// and dismisses itself the moment it stops being key, so an alert raised from inside it would be
    /// asking the window that hosts it to go away. The words are the ones the Today card's alert uses,
    /// the confirm is the only red thing on screen, and the keyboard lands on *Keep* — every property
    /// § 3.3 asks a destructive confirmation for, in the one shape this host can actually draw.
    @State private var isConfirmingDiscard = false

    public init(
        session: FocusSession,
        project: Project? = nil,
        now: Date,
        actions: Actions = Actions(),
        tracking: TrackingControls? = nil
    ) {
        self.session = session
        self.project = project
        self.now = now
        self.actions = actions
        self.tracking = tracking
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The one card in the popover: a container with its own primary action, which is what a
            // card means in Lggr. Everything below it is a plain row on the bare surface.
            Card(padding: Space.l) {
                VStack(alignment: .leading, spacing: Space.m) {
                    header
                    outcome
                    timer
                    if let progress = session.progress(at: now) {
                        progressCapsule(progress)
                    }
                    controls
                }
            }

            MenuBarDivider()

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

            discardRows

            MenuBarRow(
                id: .openApp,
                symbol: SidebarSection.today.symbolName,
                title: "Open Lggr",
                shortcut: KeyboardShortcut("1", modifiers: .command),
                focus: $focus,
                action: actions.openApp
            )

            // Ambient capture runs alongside the session, and pausing it does **not** pause the
            // session — two different records, two different switches, and this one says which it is
            // in its trailing caption. Below the session's own controls because the session is what
            // the user opened the popover for.
            if let tracking {
                MenuBarDivider()
                TrackingStateRow(controls: tracking)
            }
        }
        .defaultFocus($focus, MenuBarRowID.finish)
        .onMoveCommand { direction in move(direction) }
        // A session that ended, was discarded elsewhere, or was replaced takes its question with it.
        .onChange(of: session.id) { _, _ in isConfirmingDiscard = false }
    }

    // MARK: - Discard

    /// One row, or the confirmation that replaces it.
    ///
    /// Until now the only way out of a session started by mistake was on the main window's Today card,
    /// which a menu bar app spends most of its life without. `Finish` was the alternative, and it
    /// records the mistake.
    @ViewBuilder private var discardRows: some View {
        if let discard = actions.discard {
            if isConfirmingDiscard {
                Text("This session will not be recorded. The time it has run won't appear in Today, in your history or in the weekly review.")
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.s)
                    .padding(.top, Space.xs)

                MenuBarRow(
                    id: .keepSession,
                    symbol: Icon.MenuBar.running,
                    title: "Keep Session",
                    focus: $focus,
                    action: { isConfirmingDiscard = false }
                )

                MenuBarRow(
                    id: .discardSession,
                    symbol: Icon.delete,
                    title: "Discard Session",
                    isDestructive: true,
                    focus: $focus,
                    action: {
                        isConfirmingDiscard = false
                        discard()
                    }
                )
            } else {
                MenuBarRow(
                    id: .discardSession,
                    symbol: Icon.delete,
                    title: "Discard Session",
                    focus: $focus,
                    action: {
                        isConfirmingDiscard = true
                        // The safe half, for the same reason `Cancel` is the default button of an
                        // alert: a confirmation whose destructive half is one Return away has not
                        // confirmed anything.
                        focus = .keepSession
                    }
                )
            }
        }
    }

    // MARK: - Header

    /// `● SOR engineering · Deep work`. Quiet metadata: it is fourth in the hierarchy and dressed
    /// like it. The dot is always followed by the project's name, so colour is never the only
    /// carrier of "which project".
    private var header: some View {
        HStack(spacing: Space.xs) {
            ProjectBadge(project: project, variant: .compact)

            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(session.workType.displayName)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Outcome

    /// The intended outcome — second in the hierarchy, and the reason the session exists.
    ///
    /// `Type.rowTitle` rather than `Type.outcome`: the 17pt ramp entry belongs to the main window's
    /// active session, where it is the largest text after the hero timer. At 320pt wide, with the
    /// compact timer directly beneath it, it would compete with the number instead of introducing it.
    ///
    /// A quick timer starts with no outcome. That reads as a placeholder rather than as a control:
    /// there is nothing here that can edit it, and a button that opens something else while claiming
    /// to add an outcome would be a lie. The outcome is editable where the session lives, in Today.
    @ViewBuilder private var outcome: some View {
        if session.intendedOutcome.isEmpty {
            Text("Add an outcome")
                .font(Type.rowTitle)
                .foregroundStyle(.tertiary)
        } else {
            Text(session.intendedOutcome)
                .font(Type.rowTitle)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Timer

    /// The dominant element: `32:41` over `remaining`.
    ///
    /// One accessibility element for both lines, because "32:41" followed by "remaining" is two
    /// announcements for one fact. VoiceOver hears "23 minutes remaining" (§ 6.4).
    private var timer: some View {
        VStack(spacing: Space.xxs) {
            Text(verbatim: MenuBarLabelState.timeText(for: session, at: now))
                .font(Type.timerCompact)
                .foregroundStyle(digitStyle)

            Text(caption)
                .font(Type.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.isPaused ? "Focus session paused" : "Focus session running")
        .accessibilityValue(MenuBarLabelState.spokenTimeValue(for: session, at: now))
    }

    /// `remaining` · `elapsed` · `paused` · `past 50 minutes`.
    ///
    /// Paused outranks overtime: a session that ran long and was then paused is, to the person
    /// looking at it, paused.
    private var caption: String {
        if session.isPaused { return "paused" }
        if session.overrun(at: now) > 0, let planned = session.plannedDuration {
            return "past " + DurationFormatting.prose(planned)
        }
        return session.isOpenEnded ? "elapsed" : "remaining"
    }

    private var digitStyle: AnyShapeStyle {
        if session.isPaused { return AnyShapeStyle(.secondary) }
        if session.overrun(at: now) > 0 { return AnyShapeStyle(Palette.attention) }
        return AnyShapeStyle(.primary)
    }

    /// A 4pt capsule, and only for a session that has a plan to measure against. An open-ended
    /// session has no denominator, and a bar that is always empty is a bar that means nothing.
    private func progressCapsule(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Surface.hover)
                Capsule(style: .continuous)
                    .fill(fillStyle)
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: Layout.progressCapsuleHeight)
        // Linear over exactly one second, so a second looks like a second. Reduce Motion turns this
        // into a discrete step rather than a slower slide — see `Motion.resolved`.
        .lggrAnimation(Motion.ring, value: progress)
        // The timer above already says how far through the session is, in words.
        .accessibilityHidden(true)
    }

    private var fillStyle: AnyShapeStyle {
        if session.isPaused { return AnyShapeStyle(.secondary) }
        if session.overrun(at: now) > 0 { return AnyShapeStyle(Palette.attention) }
        return AnyShapeStyle(Color.accentColor)
    }

    // MARK: - Controls

    /// `[ Pause ]  [ Finish ⌘⏎ ]`. Finish is the primary action of a running session and is the only
    /// prominent control in the popover.
    private var controls: some View {
        // The `maxWidth` goes on each *label*, not on the button. A button style draws its fill
        // around the label it is handed, so stretching the button from the outside would centre a
        // content-sized pill in an empty half instead of filling it.
        HStack(spacing: Space.s) {
            Button(action: actions.togglePause) {
                Text(session.isPaused ? "Resume" : "Pause")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .focused($focus, equals: .pause)
            .accessibilityLabel(session.isPaused ? "Resume session" : "Pause session")

            Button(action: actions.finish) {
                Text("Finish")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.lggrPrimary(shortcut: .defaultAction))
            .keyboardShortcut(.defaultAction)
            .focused($focus, equals: .finish)
            .accessibilityLabel("Finish session")
        }
    }

    // MARK: - Keyboard

    private var orderedRows: [MenuBarRowID] {
        var rows: [MenuBarRowID] = [.pause, .finish]
        if actions.captureInterruption != nil { rows.append(.captureInterruption) }
        if actions.discard != nil {
            rows.append(contentsOf: isConfirmingDiscard ? [.keepSession, .discardSession] : [.discardSession])
        }
        rows.append(.openApp)
        return rows
    }

    private func move(_ direction: MoveCommandDirection) {
        let rows = orderedRows
        guard let current = focus, let index = rows.firstIndex(of: current) else {
            focus = .finish
            return
        }
        switch direction {
        case .up, .left:
            focus = rows[max(0, index - 1)]
        case .down, .right:
            focus = rows[min(rows.count - 1, index + 1)]
        @unknown default:
            break
        }
    }
}
