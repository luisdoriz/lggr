import AppKit
import SwiftUI
import LggrKit

// The active session card. See docs/_design/04-screens.md § 4.1.
//
// This is the *only* card on Today (see `Card`'s own documentation for why), and everything about its
// composition follows from one sentence in § 4.1: the intended outcome and the timer are the top of
// the visual hierarchy, and every other thing on the screen is quieter than this by design.
//
// So: the outcome is `Type.outcome` and never truncates; the timer is the hero; the project, the work
// type, the plan line and the buttons are `Type.secondary` or smaller and sit at the edges. There is
// no metric row, no badge, no status pill and no second colour.
//
// The plan line — `Plan 50m  −10  +10  Set target ▾` — is the one row added since § 4.1 was written,
// and it earns its place by fixing something the screen could not do: a session whose target turns
// out to be wrong had to be finished and restarted, which broke the record in order to correct the
// intent. It is deliberately the quietest thing in the card. See `planLine`.
//
// **Phase 3 belongs in Phase 3.** The live activity strip ("Xcode · 4 switches · 1 interruption"),
// the context-switch count and the session timeline are all shown in § 4.1's wireframe and are all
// absent here on purpose. There is no placeholder and no greyed-out row for them: a stub that says
// "no activity recorded" when the app is not capable of recording activity is a lie with a spinner.

/// The card shown on Today while a session is running or paused.
///
/// Takes everything it renders as a plain value or a closure — it reads no environment and touches no
/// store — so the development gallery can render it against `PreviewFixtures` with no live
/// `SessionManager` at all:
///
/// ```swift
/// ActiveSessionView(
///     session: PreviewFixtures.runningSession,
///     project: PreviewFixtures.projects.first,
///     now: { PreviewFixtures.now },
///     onTogglePause: {},
///     onFinish: {}
/// )
/// ```
public struct ActiveSessionView: View {

    private let session: FocusSession
    private let project: Project?
    private let now: () -> Date
    private let onTogglePause: () -> Void
    private let onFinish: () -> Void
    private let onAdjustPlan: ((TimeInterval) -> Void)?
    private let onSetPlan: ((TimeInterval?) -> Void)?
    private let onDiscard: (() -> Void)?

    /// Raised by `Discard`, from the button and from the context menu alike, so the confirmation is
    /// written once and cannot say two different things.
    @State private var isConfirmingDiscard = false

    /// - Parameters:
    ///   - session: The running or paused session.
    ///   - project: Already resolved by the caller — a view never looks a project up for itself.
    ///   - now: Reads the observable instant. Passed straight through to `TimerDisplay`, which is the
    ///     only view in this card that calls it, so nothing else here redraws once a second.
    ///   - onTogglePause: `SessionManager.togglePause`.
    ///   - onFinish: `SessionManager.finishSession`.
    ///   - onAdjustPlan: `SessionManager.adjustPlannedDuration(by:)`, in seconds — the `+10` / `−10`
    ///     controls. The *delta* is sent rather than a computed target because working out the target
    ///     of an open-ended session needs the current instant, and reading the instant here would make
    ///     this whole card redraw once a second (see `TimerDisplay`).
    ///   - onSetPlan: `SessionManager.adjustPlannedDuration(to:)`. `nil` seconds means open-ended.
    ///   - onDiscard: asks for the discard confirmation. `nil` removes the affordance entirely.
    public init(
        session: FocusSession,
        project: Project?,
        now: @escaping () -> Date,
        onTogglePause: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onAdjustPlan: ((TimeInterval) -> Void)? = nil,
        onSetPlan: ((TimeInterval?) -> Void)? = nil,
        onDiscard: (() -> Void)? = nil
    ) {
        self.session = session
        self.project = project
        self.now = now
        self.onTogglePause = onTogglePause
        self.onFinish = onFinish
        self.onAdjustPlan = onAdjustPlan
        self.onSetPlan = onSetPlan
        self.onDiscard = onDiscard
    }

    public var body: some View {
        Card(padding: Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                metaLine
                outcomeLine

                TimerDisplay(session: session, now: now)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.hero)

                planLine

                SessionControls(
                    isPaused: session.isPaused,
                    onTogglePause: onTogglePause,
                    onFinish: onFinish,
                    onDiscard: onDiscard == nil ? nil : { isConfirmingDiscard = true }
                )
            }
        }
        .contextMenu { cardContextMenu }
        // § 3.3 reserves the alert for two things, and destructive confirmation is one of them. The
        // sentence says what will be lost, in the same words the button used, and the confirm is the
        // only red thing on the screen.
        .alert("Discard this session?", isPresented: $isConfirmingDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard Session", role: .destructive) { onDiscard?() }
        } message: {
            Text("This session will not be recorded. The time it has run won't appear in Today, in your history or in the weekly review.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Active session")
    }

    // MARK: - Header

    /// Project, then work type. Both `.secondary`: they answer "which stream of work is this", which
    /// matters, but not as much as the sentence underneath them.
    private var metaLine: some View {
        HStack(spacing: Space.s) {
            ProjectBadge(project: project)

            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Label(session.workType.displayName, systemImage: session.workType.symbolName)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
                .font(Type.secondary)
                .foregroundStyle(.secondary)

            Spacer(minLength: Space.s)
        }
    }

    /// The second most important text in the application, so it wraps to three lines and the card
    /// grows rather than truncating (`04-screens.md` § 8.3).
    ///
    /// A quick-timer session starts with no outcome; it shows the § 10.4 placeholder in `.tertiary`
    /// rather than an empty gap. Editing it in place needs a mutation the `SessionManager` contract
    /// does not offer, so the line is read-only here and the outcome is set from the start panel.
    private var outcomeLine: some View {
        Text(hasOutcome ? session.intendedOutcome : "Add an outcome")
            .font(Type.outcome)
            .foregroundStyle(hasOutcome ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.top, Space.s)
            .accessibilityLabel("Intended outcome")
            .accessibilityValue(hasOutcome ? session.intendedOutcome : "None yet")
    }

    private var hasOutcome: Bool {
        !session.intendedOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - The target, mid-session

    /// Ten minutes. The step every "just a bit longer" is actually made of, and small enough that
    /// pressing it twice is a reasonable way to ask for twenty.
    private static let planStep: TimeInterval = 10 * 60

    /// Three targets and open-ended, which is the start panel's restraint applied to a session already
    /// running (`04-screens.md` § 5.2). A menu of every multiple of five would be a settings screen.
    private static let planTargetMinutes: [Int] = [25, 50, 90]

    /// Revising the target while the session runs.
    ///
    /// **Quiet by construction, and it has to be:** the timer above is the dominant element on this
    /// screen by design. So this is one `Type.secondary` line of borderless controls with no fill and
    /// no border, left-aligned under a centred hero, carrying no keyboard shortcut of its own. Nothing
    /// in it is a peer of the digits.
    ///
    /// Changing a target moves no recorded time, which is why none of this marks the session as edited
    /// — see `FocusSession.adjustPlannedDuration(to:)`.
    @ViewBuilder private var planLine: some View {
        if onAdjustPlan != nil || onSetPlan != nil {
            HStack(spacing: Space.s) {
                Text(planText)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel("Planned duration")
                    .accessibilityValue(planValue)

                if let onAdjustPlan {
                    planButton("−10", label: "Ten minutes less") {
                        onAdjustPlan(-Self.planStep)
                    }
                    // An open-ended session has no target to take ten minutes off. `+10` still reads
                    // as "ten minutes from here" and adopts the time already spent as its base.
                    .disabled(session.isOpenEnded)

                    planButton("+10", label: "Ten minutes more") {
                        onAdjustPlan(Self.planStep)
                    }
                }

                if let onSetPlan {
                    planTargetMenu(onSetPlan)
                }

                Spacer(minLength: Space.s)
            }
            .padding(.bottom, Space.l)
            .lggrAnimation(Motion.settle, value: session.plannedDuration)
        }
    }

    private func planButton(
        _ title: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .font(Type.secondary)
            .monospacedDigit()
            .accessibilityLabel(label)
    }

    private func planTargetMenu(_ onSetPlan: @escaping (TimeInterval?) -> Void) -> some View {
        Menu {
            ForEach(Self.planTargetMinutes, id: \.self) { minutes in
                Button("\(minutes) minutes") { onSetPlan(TimeInterval(minutes) * 60) }
            }
            Divider()
            Button("Open-ended") { onSetPlan(nil) }
        } label: {
            Text("Set target")
                .font(Type.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Set a target duration")
    }

    /// `Plan 50m` or `Open-ended`. The word "plan" rather than "target" because that is the word
    /// `04-screens.md` § 10.4 already uses on the timer's own caption.
    private var planText: String {
        guard let planned = session.plannedDuration else { return "Open-ended" }
        return "Plan " + DurationFormatting.compact(planned)
    }

    private var planValue: String {
        guard let planned = session.plannedDuration else { return "Open-ended" }
        return DurationFormatting.prose(planned)
    }

    // MARK: - Context menu

    /// § 4.1 lists five items for this card. *Capture interruption* and *Change project* need Phase 3
    /// and a mutation the session contract does not expose, so the menu carries only what it can
    /// actually do. A menu item that cannot act is worse than an absent one.
    @ViewBuilder private var cardContextMenu: some View {
        Button("Copy outcome", action: copyOutcome)
            .disabled(!hasOutcome)
        Divider()
        Button(session.isPaused ? "Resume Session" : "Pause Session", action: onTogglePause)
        Button("Finish Session", action: onFinish)
        if onDiscard != nil {
            Divider()
            // Confirms through the same alert the button raises. `role: .destructive` is what colours
            // it, and it is the only red in this card.
            Button("Discard Session", role: .destructive) { isConfirmingDiscard = true }
        }
    }

    /// AppKit rather than SwiftUI: `.copyable(_:)` requires the view to hold keyboard focus and a
    /// `Transferable` payload, neither of which applies to a menu item on a card. `NSPasteboard` is
    /// the only way to put a string on the clipboard from an arbitrary action on macOS.
    private func copyOutcome() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.intendedOutcome, forType: .string)
    }
}
