import AppKit
import SwiftUI
import LggrKit

// The menu bar popover. See docs/_design/04-screens.md § 5.1.
//
// `.menuBarExtraStyle(.window)`, fixed 320pt, `Space.m` of interior padding, height fits content.
// It is a real view, not an `NSMenu`: rows have hover fills, a progress capsule and a primary
// button, none of which a menu can draw.
//
// This file also owns the two pieces both popover states share — the row, and the identifier the
// arrow keys move between — so `MenuBarIdleView` and `MenuBarActiveView` cannot drift apart.

/// The one place that decides what the popover is showing.
///
/// Three states, in priority order: the inline start panel, a running session, and the idle menu.
/// The idle menu is also the empty state — the popover never says "no session running".
@MainActor
public struct MenuBarContentView: View {

    @Environment(\.sessionManager) private var sessionManager
    @Environment(\.appModel) private var appModel
    /// The composition root, for the two things the popover needs that are not session state: the
    /// interruption inbox and the tracking switch. Optional because the gallery and the snapshot
    /// renderer draw this view with no environment at all.
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    /// The start panel, rendered *inside* the popover.
    ///
    /// A `.menuBarExtraStyle(.window)` popover cannot present a `.sheet`, so starting a session from
    /// the menu bar replaces the popover's contents rather than opening a window (§ 5.2, § 1.3).
    /// The scene injects `StartSessionForm` here; when nothing is injected the Start row falls back
    /// to presenting the panel as a sheet on the main window, so it is never a dead control.
    private let inlineStartPanel: (() -> AnyView)?

    public init(inlineStartPanel: (() -> AnyView)? = nil) {
        self.inlineStartPanel = inlineStartPanel
    }

    public var body: some View {
        // Read here, in this view's own body, so the popover ticks for the same reason the label
        // does (SPIKE-menubar.md). Everything below this line is a plain value: the two child views
        // take injectable state and can be rendered without a store.
        let now = sessionManager?.now ?? Date()
        let session = sessionManager?.activeSession
        let pendingReview = sessionManager?.pendingReview
        let projects = sessionManager?.projects ?? []
        let todaySessions = sessionManager?.todaySessions ?? []
        let hasStoreError = sessionManager?.lastError != nil
        let mode = appModel?.popover ?? .menu

        return VStack(alignment: .leading, spacing: 0) {
            if mode == .startSession, let inlineStartPanel {
                inlineStartPanel()
            } else if mode == .captureInterruption {
                capturePanel
            } else if let session, !session.isFinished {
                MenuBarActiveView(
                    session: session,
                    project: projects.first { $0.id == session.projectID },
                    now: now,
                    actions: activeActions,
                    tracking: trackingControls
                )
            } else {
                MenuBarIdleView(
                    pendingReview: pendingReview,
                    unlabelledBlock: unlabelledBlock,
                    footer: MenuBarTodayFooter(
                        sessions: todaySessions,
                        isUnavailable: hasStoreError && todaySessions.isEmpty
                    ),
                    inboxCount: environment?.inbox.pendingCount ?? 0,
                    actions: idleActions,
                    tracking: trackingControls
                )
            }

            escapeCatcher
        }
        .padding(Space.m)
        .frame(width: Layout.popoverWidth)
        // Leaving the popover mid-flow must not be how the user finds the start panel next time.
        .onDisappear { appModel?.resetPopover() }
    }

    // MARK: - Interruption capture

    /// "What came up?", inline, in place of the menu.
    ///
    /// This is the case interruption capture exists for: the session is running, the window is
    /// closed, and one line has to be written down without any of that changing. The popover keeps
    /// its 320pt; the panel supplies no frame and no padding of its own in this presentation.
    ///
    /// With no composition root — the gallery, the snapshot renderer — the panel still draws and
    /// reports a failed save rather than pretending to have written something.
    @ViewBuilder private var capturePanel: some View {
        InterruptionCaptureSheet(
            presentation: .popover,
            onSave: { note, source in
                guard let inbox = environment?.inbox else { return false }
                let saved = await inbox.capture(note, source: source)
                // Back to the menu, not out of the popover: the user pressed a menu bar item and
                // is one glance from the timer they were watching.
                if saved { appModel?.resetPopover() }
                return saved
            },
            onCancel: { appModel?.resetPopover() }
        )
    }

    /// The tracking switch, or the honest absence of one.
    ///
    /// `nil` when there is no composition root, which removes the row rather than drawing a switch
    /// that cannot switch anything. `TrackingControls` is passed down as a value of closures on
    /// purpose: the state is read inside the row's own body, which is what keeps it live (§ 6.3).
    private var trackingControls: TrackingControls? {
        environment?.capture.privacy.controls
    }

    // MARK: - The block nobody declared

    /// The most recent block of today nobody has declared anything over, if there is one.
    ///
    /// Read from `TimelineModel.shared` for the reason `AppEnvironment` reads it the same way: ambient
    /// capture runs from launch whether or not a window is open, so the object holding the day cannot
    /// belong to a view's lifetime — and the popover is the surface most likely to be the only one
    /// open. Gated on the composition root so the gallery and the snapshot renderer, which have no
    /// route to present the sheet, show no row rather than an inert one.
    ///
    /// Read in this view's own body, like everything else here, so the row appears and disappears as
    /// the day is rebuilt.
    private var unlabelledBlock: UnlabelledBlockOffer? {
        guard environment != nil else { return nil }
        return TimelineModel.shared.latestUnlabelledEpisode.map(UnlabelledBlockOffer.init(episode:))
    }

    // MARK: - Escape

    /// `Esc` dismisses the popover (§ 5.1). A zero-sized button is how a keyboard shortcut gets
    /// registered without drawing anything; it is hidden from VoiceOver because the popover already
    /// closes on Escape as far as a screen reader is concerned.
    private var escapeCatcher: some View {
        Button("Close") { dismissPopover() }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// AppKit, deliberately, and this is the only place in the menu bar views that reaches for it.
    ///
    /// A `.menuBarExtraStyle(.window)` popover lives in a window SwiftUI owns privately; there is no
    /// `DismissAction` that reaches it and no binding the scene exposes. Closing the key window is
    /// the only thing that dismisses it. The guard is what makes that safe: the main scene is a
    /// `.titled` window, so an untitled key window can only be this popover.
    private func dismissPopover() {
        appModel?.resetPopover()
        guard let window = NSApp.keyWindow, !window.styleMask.contains(.titled) else { return }
        window.close()
    }

    /// Closes the popover *first*, then opens the window. In the other order the main window would
    /// be key by the time we looked, the guard above would (correctly) refuse to close anything, and
    /// the popover would be left hanging over the window it just opened.
    private func leavingPopover(_ perform: @escaping @MainActor () -> Void) {
        dismissPopover()
        perform()
    }

    // MARK: - Idle actions

    private var idleActions: MenuBarIdleView.Actions {
        MenuBarIdleView.Actions(
            startSession: { openStartPanel() },
            quickTimer: { minutes in startQuickTimer(minutes: minutes) },
            reviewLastSession: {
                // The popover cannot host the review sheet, so this is the one row that must open
                // the window. It is the user's choice to press it — nothing forces the window open
                // when a session ends (§ 1.3).
                leavingPopover { appModel?.presentReview() }
            },
            // Like the review row, and for the same reason: the popover cannot host a sheet, so this
            // is one of the few rows that opens the window. It is worth it here — the sheet is a
            // statement about a block on the timeline, and the timeline is the evidence the user needs
            // in front of them to make it. `nil` when there is no such block, which removes the row.
            labelLastBlock: unlabelledBlock == nil
                ? nil
                : {
                    guard
                        let episode = TimelineModel.shared.latestUnlabelledEpisode
                    else { return }
                    leavingPopover { appModel?.presentBlockLabel(episodeID: episode.id) }
                },
            addAccomplishment: {
                leavingPopover { appModel?.presentAccomplishmentEditor() }
            },
            // Inline, never as a window: the popover replaces its own contents with the capture
            // field. `nil` only when there is no composition root to write into, in which case the
            // row is dimmed and says why rather than disappearing.
            captureInterruption: environment == nil
                ? nil
                : { appModel?.presentCapture(inPopover: true) },
            openInbox: {
                leavingPopover { appModel?.presentInbox() }
            },
            openToday: {
                leavingPopover { appModel?.select(.today) }
            },
            openWeeklyReview: {
                leavingPopover { appModel?.select(.weeklyReview) }
            }
        )
    }

    // MARK: - Active actions

    private var activeActions: MenuBarActiveView.Actions {
        MenuBarActiveView.Actions(
            togglePause: { sessionManager?.togglePause() },
            finish: { finishSession() },
            // The session keeps running. Capture replaces the popover's body and hands it back
            // afterwards; nothing about the session moves (`04-screens.md` § 5.4).
            captureInterruption: environment == nil
                ? nil
                : { appModel?.presentCapture(inPopover: true) },
            // Confirmed inside the popover before this is reached. `nil` with no manager to discard
            // through, which removes the row rather than offering an irreversible action that would
            // do nothing.
            discard: sessionManager == nil ? nil : { discardSession() },
            openApp: {
                leavingPopover { appModel?.select(.today) }
            }
        )
    }

    // MARK: - Behaviour

    private func openStartPanel() {
        guard let appModel else { return }
        if inlineStartPanel != nil {
            appModel.presentStartPanel(inPopover: true)
        } else {
            leavingPopover { appModel.presentStartPanel(inPopover: false) }
        }
    }

    /// Quick Timer: start now, ask nothing. Last project, last work type, no outcome.
    ///
    /// A quick timer that needs a form is not quick, so the outcome is left empty and the active
    /// view shows "Add an outcome" in its place. Nothing is lost — the session records the same
    /// times as any other.
    private func startQuickTimer(minutes: Int) {
        guard let manager = sessionManager else { return }

        // The remembered project may have been deleted since; falling back to no project is better
        // than starting a session labelled with something that no longer exists.
        let remembered = manager.preferences.lastProjectID
        let projectID = manager.projects.contains { $0.id == remembered } ? remembered : nil
        let workType = manager.todaySessions.first?.workType ?? .deepWork

        Task {
            await manager.startSession(
                projectID: projectID,
                intendedOutcome: "",
                workType: workType,
                plannedDuration: TimeInterval(minutes) * 60
            )
        }
    }

    /// Discarding does not open a window either, and it does not hand the session to the review flow:
    /// `SessionManager.discardActiveSession()` removes the record outright, which is what the
    /// confirmation promised. The popover swaps to the idle menu because there is no longer a session —
    /// that is the confirmation.
    private func discardSession() {
        guard let manager = sessionManager else { return }
        Task { await manager.discardActiveSession() }
    }

    /// Finishing does not open a window. The popover swaps to the idle menu with `Review last
    /// session` on top and the menu bar symbol becomes `questionmark.circle` — that is the
    /// confirmation, and the review is one click away whenever the user wants it (§ 1.3).
    private func finishSession() {
        guard let manager = sessionManager else { return }
        Task { await manager.finishSession() }
    }
}

// MARK: - Rows

/// Which popover row the keyboard is on.
///
/// One flat enum shared by both states so `↑`/`↓` can walk a plain array, and so the two views
/// cannot invent conflicting focus vocabularies.
enum MenuBarRowID: Hashable {
    case reviewLastSession
    case startSession
    /// Label the most recent block nobody declared anything over. Present only while there is one.
    case labelLastBlock
    /// One per inline duration segment — a quick timer that needs a submenu is not quick.
    case quickTimer(minutes: Int)
    case addAccomplishment
    case captureInterruption
    /// The interruption inbox. Present only while there is something in it.
    case openInbox
    case openToday
    case openWeeklyReview
    case pause
    case finish
    /// Throw the running session away. Raises a confirmation in place of itself.
    case discardSession
    /// The safe half of that confirmation, and where the keyboard lands while it is up.
    case keepSession
    case openApp
}

/// One 28pt row: a symbol in an 18pt column, a title, and a right-aligned shortcut hint.
///
/// Hover and keyboard highlight are deliberately different fills (`Surface.hover` vs
/// `Surface.selected`) so the mouse and the keyboard never contradict each other on screen.
///
/// A row with a `disabledReason` is dimmed and explains itself on hover rather than disappearing.
/// A feature that is coming is more honest as a quiet, labelled row than as a hole in the menu.
@MainActor
struct MenuBarRow: View {

    private let id: MenuBarRowID
    private let symbol: String
    private let title: String
    private let shortcut: KeyboardShortcut?
    /// A right-aligned fact rather than a shortcut hint — the inbox's count. Never both: a row with a
    /// number *and* a key combination on its right edge has two trailing meanings and reads as
    /// neither.
    private let trailingText: String?
    /// The accent-tinted primary row. There is at most one per popover state.
    private let isPrimary: Bool
    /// The confirm half of a destructive confirmation. `Palette.destructive` is the only red in Lggr
    /// and this is the only row that may ask for it — never a row that *raises* a confirmation, only
    /// one that completes it.
    private let isDestructive: Bool
    private let disabledReason: String?
    private let action: () -> Void

    @FocusState.Binding private var focus: MenuBarRowID?
    @State private var isHovering = false

    // Written out rather than left to the memberwise initialiser: a `private` stored property makes
    // the synthesised one private too, and this row is built from two other files.
    init(
        id: MenuBarRowID,
        symbol: String,
        title: String,
        shortcut: KeyboardShortcut? = nil,
        trailingText: String? = nil,
        isPrimary: Bool = false,
        isDestructive: Bool = false,
        disabledReason: String? = nil,
        focus: FocusState<MenuBarRowID?>.Binding,
        action: @escaping () -> Void
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.shortcut = shortcut
        self.trailingText = trailingText
        self.isPrimary = isPrimary
        self.isDestructive = isDestructive
        self.disabledReason = disabledReason
        self._focus = focus
        self.action = action
    }

    private var isDisabled: Bool { disabledReason != nil }
    private var isFocused: Bool { focus == id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .imageScale(.medium)
                    .frame(width: Layout.symbolColumnWidth, alignment: .center)
                    .accessibilityHidden(true)

                Text(title)
                    .font(isPrimary ? Type.rowTitle : Type.body)
                    .lineLimit(1)

                Spacer(minLength: Space.s)

                if let trailingText {
                    Text(trailingText)
                        .font(Type.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else if let shortcut {
                    ShortcutHint(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(titleStyle)
            .frame(height: Layout.popoverRowHeight)
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: Theme.chipShape)
            .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .focusable(!isDisabled)
        .focused($focus, equals: id)
        // The row draws its own highlight, and two rings on one control is noise.
        .focusEffectDisabled()
        .onHover { isHovering = $0 && !isDisabled }
        .lggrAnimation(Motion.tap, value: isHovering)
        .lggrAnimation(Motion.tap, value: isFocused)
        .lggrKeyboardShortcut(isDisabled ? nil : shortcut)
        .modifier(RowExplanation(reason: disabledReason))
        // "Interruptions, 2" rather than two separate announcements for one row.
        .accessibilityLabel(trailingText.map { "\(title), \($0)" } ?? title)
    }

    private var titleStyle: AnyShapeStyle {
        if isDisabled { return AnyShapeStyle(.tertiary) }
        if isDestructive { return AnyShapeStyle(Palette.destructive) }
        if isPrimary { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.primary)
    }

    private var background: Color {
        if isFocused { return Surface.selected }
        if isHovering { return Surface.hover }
        return .clear
    }
}

/// Attaches the "why is this dimmed" explanation, and attaches nothing at all when there isn't one.
///
/// Written as a modifier so an available row does not carry an empty tooltip and an empty VoiceOver
/// hint, both of which are worse than silence.
private struct RowExplanation: ViewModifier {
    let reason: String?

    @ViewBuilder func body(content: Content) -> some View {
        if let reason {
            content
                .help(reason)
                .accessibilityHint(reason)
        } else {
            content
        }
    }
}

/// The popover's hairline. `Space.s` of air either side, which is the least a 28pt row can take
/// without the divider reading as part of the row above it.
@MainActor
struct MenuBarDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, Space.s)
    }
}

/// The one sentence a row shows when a feature has not arrived yet.
///
/// Kept in one place so the popover says the same thing everywhere, and phrased as a fact about the
/// app rather than an apology or a promise with a date on it.
enum MenuBarCopy {
    static let interruptionCaptureUnavailable =
        "Interruption capture arrives with activity tracking."
}
