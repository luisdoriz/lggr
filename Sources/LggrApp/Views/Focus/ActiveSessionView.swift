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
// type and the two buttons are `Type.secondary` or smaller and sit at the edges. There is no metric
// row, no badge, no status pill and no second colour.
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

    /// - Parameters:
    ///   - session: The running or paused session.
    ///   - project: Already resolved by the caller — a view never looks a project up for itself.
    ///   - now: Reads the observable instant. Passed straight through to `TimerDisplay`, which is the
    ///     only view in this card that calls it, so nothing else here redraws once a second.
    ///   - onTogglePause: `SessionManager.togglePause`.
    ///   - onFinish: `SessionManager.finishSession`.
    public init(
        session: FocusSession,
        project: Project?,
        now: @escaping () -> Date,
        onTogglePause: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        self.session = session
        self.project = project
        self.now = now
        self.onTogglePause = onTogglePause
        self.onFinish = onFinish
    }

    public var body: some View {
        Card(padding: Space.xl) {
            VStack(alignment: .leading, spacing: 0) {
                metaLine
                outcomeLine

                TimerDisplay(session: session, now: now)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.hero)

                SessionControls(
                    isPaused: session.isPaused,
                    onTogglePause: onTogglePause,
                    onFinish: onFinish
                )
            }
        }
        .contextMenu { cardContextMenu }
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
