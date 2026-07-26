import Foundation
import LggrKit
import SwiftUI

// What the five global hot keys actually do. See docs/_design/04-screens.md § 7.1 and SPEC.md
// § "Keyboard experience".
//
// This file is the answer to the one question `GlobalShortcutService` deliberately does not ask:
// having claimed a system-wide combination, what happens when it is pressed? The service refuses to
// register an action with no handler at all (`FailureReason.noHandler`), and `install(into:)` below
// installs one for **every** case of `GlobalShortcutAction`, so a hot key that appears in Settings
// cannot be a hot key that does nothing. That pairing is the whole point: a configurable shortcut
// bound to nothing is the defect this feature exists to end.
//
// Two rules shape everything here.
//
// 1. **Only as much interface as the action needs.** Three of the five open the panel, because they
//    collect something. Pause/resume and a remembered quick session collect nothing, so they act
//    immediately and confirm in a strip that goes away by itself. A window opened to do something
//    instantaneous is worse than no shortcut.
// 2. **Nothing here activates Lggr.** Everything goes through `QuickPanelHost`, whose entire reason
//    for existing is that the user stays in the application they were already in. Press, act, back to
//    work.

/// The five global hot-key actions, wired to `SessionManager`, the inbox and the quick panel.
///
/// Not `@Observable`: nothing observes it. It is a coordinator — it reads live state at the moment a
/// key is pressed and hands work to the objects that own it.
@MainActor
public final class QuickActions {

    // MARK: - Collaborators

    private let sessionManager: SessionManager
    private let panel: QuickPanelHost
    private let preferences: AppPreferences
    private let clock: any DateProviding

    /// Where a captured interruption is written. `nil` in a host with no composition root — the
    /// gallery, the snapshot renderer — where the capture panel still draws and reports a failed save
    /// rather than pretending to have written something, exactly as it does in the popover.
    private let inbox: InboxModel?

    /// Which action's panel is on screen, so pressing the same hot key again closes it.
    ///
    /// A hot key that only ever opens is half a control: the user's hand is already on the keys, and
    /// `Esc` is a different reach. `nil` while a confirmation strip is up — that is not a panel the
    /// user is meant to dismiss.
    private var presentedAction: GlobalShortcutAction?

    /// Bumped by every presentation, so a confirmation that has timed out cannot close a panel opened
    /// after it. Without this, `⌃⇧L` followed quickly by `⌘⇧Space` would close the start panel a
    /// second and a half later for no reason the user could explain.
    private var presentationGeneration = 0

    /// How long a confirmation stays up.
    ///
    /// Long enough to read four words, short enough that it is gone before the user's attention comes
    /// back to it. It is dismissible the same way everything else is, and it steals no focus, so being
    /// wrong about this by half a second costs nothing.
    private static let confirmationDuration: Duration = .milliseconds(1_600)

    public init(
        sessionManager: SessionManager,
        panel: QuickPanelHost,
        preferences: AppPreferences,
        clock: any DateProviding,
        inbox: InboxModel? = nil
    ) {
        self.sessionManager = sessionManager
        self.panel = panel
        self.preferences = preferences
        self.clock = clock
        self.inbox = inbox
    }

    // MARK: - Wiring

    /// Installs a handler for every action, and therefore for every hot key Settings can show.
    ///
    /// Written over `allCases` rather than as five calls on purpose: adding a sixth action to
    /// `GlobalShortcutAction` then fails to compile in `perform(_:)` — which is a compiler error
    /// instead of a shortcut the user can configure and press to no effect.
    public func install(into service: GlobalShortcutService) {
        for action in GlobalShortcutAction.allCases {
            service.setHandler(for: action) { [weak self] in
                self?.perform(action)
            }
        }
    }

    /// Runs one action. Also the seam a menu item or a test drives it through.
    public func perform(_ action: GlobalShortcutAction) {
        switch action {
        case .startSession: presentStartPanel()
        case .quickSession: startQuickSession()
        case .captureInterruption: presentInterruptionCapture()
        case .addAccomplishment: presentAccomplishmentEditor()
        case .pauseResume: togglePause()
        }
    }

    // MARK: - Start a session

    /// The full start panel, from anywhere, with no window and no activation.
    ///
    /// The same `StartSessionForm` the main window and the popover use, with the same defaults, the
    /// same `⌘⏎`, the same `⌘⌥⏎` and the same focus chain — one panel, a third host.
    public func presentStartPanel() {
        guard !toggledOff(.startSession) else { return }

        present(.startSession, width: Layout.startPanelSheetWidth) { [weak self] in
            StartSessionForm(
                presentation: .sheet,
                context: self?.startContext() ?? .empty,
                onStart: { [weak self] request in
                    self?.start(request)
                    self?.panel.dismiss()
                },
                onDismiss: { [weak self] in self?.panel.dismiss() }
            )
        }
    }

    /// `⌃⇧L`: a session, now, with no fields at all.
    ///
    /// The user named this one. It starts with the remembered project, the work type they were last
    /// using and their default duration, and the panel shows a confirmation rather than a form — one
    /// keystroke, already tracking.
    ///
    /// It falls back to the full panel in the two cases where starting immediately would mean
    /// inventing something:
    ///
    ///   * **Nothing is remembered yet.** No `lastProjectID` that still names an active project, or no
    ///     usable default duration, means the only session we could start is an arbitrary one. A first
    ///     press on a fresh install therefore opens the panel — which is also how the app learns what
    ///     to remember for the next press.
    ///   * **A session is already running.** `SessionManager.startSession` finishes what is running
    ///     before it starts anything, and finishing an hour of work as the silent side effect of one
    ///     keystroke is not a thing a hot key may do. The panel makes it the user's decision, and
    ///     `Esc` costs them nothing.
    public func startQuickSession() {
        guard !toggledOff(.quickSession) else { return }

        guard sessionManager.activeSession == nil else {
            presentStartPanel()
            return
        }
        guard let projectID = rememberedProjectID(), let duration = rememberedDuration() else {
            presentStartPanel()
            return
        }

        let context = startContext()
        start(
            StartSessionRequest(
                projectID: projectID,
                intendedOutcome: "",
                workType: context.lastWorkType,
                plannedDuration: duration
            )
        )

        // No outcome, deliberately: a quick session that needs a sentence is not quick, and the active
        // views already show "Add an outcome" in its place. Nothing is lost — the session records the
        // same times as any other.
        confirm(
            symbol: Icon.startSession,
            title: "Focus session started",
            detail: [
                sessionManager.projectName(for: projectID),
                DurationFormatting.compact(duration),
                context.lastWorkType.displayName,
            ]
            .compactMap { $0 }
            .joined(separator: " · ")
        )
    }

    /// Starts a session from a panel's request. Fire-and-forget: the interface has already moved on,
    /// and `SessionManager` reports any failure through `lastError`.
    public func start(_ request: StartSessionRequest) {
        Task { [sessionManager] in
            await sessionManager.startSession(
                projectID: request.projectID,
                intendedOutcome: request.intendedOutcome,
                workType: request.workType,
                plannedDuration: request.plannedDuration
            )
        }
    }

    /// The start panel's context, with the user's chosen default duration folded in.
    ///
    /// `StartSessionContext.live` reads `SessionManager.preferences`, which is loaded once at launch;
    /// `AppPreferences` is the value the user can change while the app is running, so it wins here.
    public func startContext() -> StartSessionContext {
        var context = StartSessionContext.live(sessionManager)
        context.defaultDuration = preferences.defaultSessionDuration
        return context
    }

    // MARK: - Capture an interruption

    /// "What came up?" — one line, saved to the inbox, and the session carries on.
    ///
    /// Nothing here touches the running session. `InboxModel.capture` increments its interruption
    /// count *after* the write lands and changes nothing else: it does not pause it, finish it, or move
    /// a single date. That is the entire promise of the feature (`04-screens.md` § 5.4), and it is the
    /// reason this can be a global hot key at all.
    public func presentInterruptionCapture() {
        guard !toggledOff(.captureInterruption) else { return }

        present(.captureInterruption, width: Layout.captureSheetWidth) { [weak self] in
            InterruptionCaptureSheet(
                presentation: .sheet,
                // The panel closes only once the note is on disk. On a failed write it stays open with
                // the sentence intact, which is the one thing that must never be retyped.
                onSave: { note, source in
                    guard let inbox = self?.inbox else { return false }
                    let saved = await inbox.capture(note, source: source)
                    if saved { self?.panel.dismiss() }
                    return saved
                },
                onCancel: { [weak self] in self?.panel.dismiss() }
            )
        }
    }

    // MARK: - Add an accomplishment

    /// The accomplishment editor, blank, from anywhere.
    public func presentAccomplishmentEditor() {
        guard !toggledOff(.addAccomplishment) else { return }

        present(.addAccomplishment, width: Layout.startPanelSheetWidth) { [weak self] in
            AccomplishmentEditor(
                // Blank, and with no project pre-filled — the same seed the main window uses for a
                // manual entry. Guessing a project for something the user has not described yet would
                // be a field they have to check rather than one they can skip.
                accomplishment: Accomplishment(title: "", timestamp: self?.clock.now ?? Date()),
                projects: self?.sessionManager.projects ?? [],
                onSave: { [weak self] accomplishment in
                    guard let self else { return }
                    Task { [sessionManager = self.sessionManager] in
                        await sessionManager.addAccomplishment(accomplishment)
                    }
                    self.panel.dismiss()
                },
                onCancel: { [weak self] in self?.panel.dismiss() }
            )
        }
    }

    // MARK: - Pause and resume

    /// Toggles the running session, with no panel to interact with at all.
    ///
    /// Pausing is instantaneous, so opening something to do it would be the shortcut getting in the
    /// way of itself. What appears instead is a strip that states what happened and the time it
    /// happened at, and then leaves — the confirmation a keystroke with no visible target needs in
    /// order not to feel like it did nothing.
    public func togglePause() {
        guard !toggledOff(.pauseResume) else { return }

        guard let session = sessionManager.activeSession else {
            // Said plainly rather than silently ignored. A hot key that does nothing and says nothing
            // is indistinguishable from one that failed to register.
            confirm(
                symbol: Icon.MenuBar.idle,
                title: "No session to pause",
                detail: "Nothing is being tracked right now."
            )
            return
        }

        sessionManager.togglePause()
        let toggled = sessionManager.activeSession ?? session
        confirm(
            symbol: toggled.isPaused ? Icon.pause : Icon.resume,
            title: toggled.isPaused ? "Session paused" : "Session resumed",
            detail: MenuBarLabelState.spokenTimeValue(for: toggled, at: sessionManager.now)
        )
    }

    // MARK: - What the app remembers

    /// The remembered project, but only while it still exists and is still active.
    ///
    /// A session labelled with a project the user deleted would be worse than one with no project at
    /// all, so this returns `nil` and the caller opens the panel instead of guessing.
    private func rememberedProjectID() -> UUID? {
        guard let remembered = sessionManager.preferences.lastProjectID else { return nil }
        guard sessionManager.projects.contains(where: { $0.id == remembered && $0.isActive })
        else { return nil }
        return remembered
    }

    /// The user's default duration, or `nil` when it could not start a session on its own.
    private func rememberedDuration() -> TimeInterval? {
        let duration = preferences.defaultSessionDuration
        guard duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    // MARK: - Presenting

    /// Whether this press should be read as "close what you just opened".
    ///
    /// - Returns: `true` when the panel already up belongs to this action, having dismissed it. Every
    ///   action guards on it, so each hot key is its own toggle and none of them can stack a second
    ///   panel on the first.
    private func toggledOff(_ action: GlobalShortcutAction) -> Bool {
        guard panel.isPresented, presentedAction == action else { return false }
        panel.dismiss()
        return true
    }

    private func present<Content: View>(
        _ action: GlobalShortcutAction,
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        presentationGeneration += 1
        presentedAction = action
        panel.present(
            width: width,
            takesKeyboardFocus: true,
            onDismiss: { [weak self] in self?.presentedAction = nil },
            content: content
        )
    }

    /// Shows a confirmation strip and takes it away again.
    ///
    /// `takesKeyboardFocus: false` is the important argument: this panel has nothing to type into, so
    /// it is ordered in front without becoming key at all. The user's own text field keeps the caret
    /// it had, which is what makes a hot key pressed mid-sentence harmless.
    private func confirm(symbol: String, title: String, detail: String?) {
        presentationGeneration += 1
        presentedAction = nil
        let generation = presentationGeneration

        panel.present(width: Layout.popoverWidth, takesKeyboardFocus: false) {
            QuickConfirmationView(symbol: symbol, title: title, detail: detail)
        }

        Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationDuration)
            guard let self, self.presentationGeneration == generation else { return }
            self.panel.dismiss()
        }
    }
}

// MARK: - The confirmation strip

/// One line that says what just happened.
///
/// A strip rather than a notification, and there is no *Undo*: everything it reports is either
/// reversible by pressing the same key again (pause, resume) or already visible in the menu bar,
/// where the timer starts counting the moment a session begins. It draws no controls at all, because
/// it does not take keyboard focus and a button nobody can reach with the keyboard is not a button.
@MainActor
private struct QuickConfirmationView: View {

    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .imageScale(.large)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Type.caption)
                        .foregroundStyle(Ink.support)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.canvas)
        // One announcement for one fact, in the order it reads on screen.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(title). \($0)" } ?? title)
    }
}
