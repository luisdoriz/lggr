import SwiftUI

// The keyboard map, as real menu commands. See docs/_design/04-screens.md § 7.
//
// Menu commands rather than view-level `.keyboardShortcut`s, for three reasons § 7.2 spells out:
// they work from any window, they survive the main window being closed (`LSUIElement` is `false`, so
// the application menu bar exists with zero windows open), and they are discoverable — a Mac app's
// shortcuts belong in its menus, not in a `?` overlay.
//
// **Every item here works with no window open.** `AppModel.select(_:)` and `AppModel.present(_:)`
// both open the main window first, because a section or a sheet is useless without one. The items
// that do *not* open a window are the ones for which opening one would be an interruption rather
// than a service: pausing, and an export that succeeds. An export that fails opens the window, which
// is the only place its sentence can be read (`ExportService.report`).
//
// Three things are deliberately absent:
//
//   • **`⌘,`** — the `Settings` scene installs it into the application menu itself, and it already
//     works with every window closed. Declaring a second one would give macOS two items claiming the
//     same key equivalent, and the one that lost would be a menu item that does nothing.
//   • **`Space` (Pause / Resume)** — § 7.1 scopes it to the focused session card, and
//     `SessionControls.pauseShortcut` is where it lives. A menu key equivalent is application-wide,
//     so registering `Space` here would swallow the space bar in every text field in the app. The
//     menu item exists without a shortcut; the card keeps the key.
//   • **`⌘⇧E`** — § 7.1 gives it to "export the current screen", and `WeeklyReviewView` already
//     registers it on its own primary button, which *prints the combination on itself*. A menu key
//     equivalent takes precedence over a view's, so declaring one here would leave a button on screen
//     advertising a shortcut that no longer reaches it. The export submenu below is the same four
//     documents, named, from anywhere.
//
// **`Esc`** needs no declaration: each sheet installs `.cancelAction` on its own Cancel, and the
// popover has an explicit catcher (`MenuBarContentView.escapeCatcher`). A single application-wide
// `Esc` would close the wrong thing exactly as often as the right one.

/// Every command in the application.
///
/// Takes the composition root by hand rather than reading the environment: `Commands` are built
/// alongside a scene, not inside one, and the environment a scene installs is not visible here.
@MainActor
public struct AppCommands: Commands {

    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    private var appModel: AppModel { environment.appModel }
    private var manager: SessionManager { environment.sessionManager }
    private var exportService: ExportService { environment.exportService }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(newItemTitle) { newItem() }
                .keyboardShortcut("n", modifiers: .command)

            Button("New Project") { appModel.presentProjectEditor() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Add Accomplishment") { appModel.presentAccomplishmentEditor() }
                .keyboardShortcut("a", modifiers: [.command, .shift])

            Divider()

            exportMenu
        }

        CommandMenu("Session") {
            Button(primaryActionTitle) { finish() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isFinishAvailable)

            Button(pauseTitle) { manager.togglePause() }
                .disabled(manager.activeSession == nil)

            Button("Review Last Session") { appModel.presentReview() }
                .disabled(manager.pendingReview == nil)

            Divider()

            // Always available, session or not (§ 7.1). A capture with nothing running is saved with
            // no `focusSessionID` and still lands in the inbox, so there is no state in which this
            // item is the wrong thing to press.
            Button("Capture Interruption") { appModel.presentCapture(inPopover: false) }
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Button(inboxTitle) { appModel.presentInbox() }
        }

        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(SidebarSection.allCases) { section in
                Button(section.title) { appModel.select(section) }
                    .keyboardShortcut(section.shortcutKey, modifiers: .command)
            }
        }
    }

    // MARK: - File

    /// `⌘N` is New Project while Projects is the selected section (§ 7.1). `ProjectsView` registers
    /// the same combination on its own `+` button; both call the same handler, so whichever the
    /// system routes it to does the same thing.
    private var newItemTitle: String {
        appModel.section == .projects ? "New Project" : "New Focus Session"
    }

    private func newItem() {
        if appModel.section == .projects {
            appModel.presentProjectEditor()
        } else {
            appModel.presentStartPanel(inPopover: false)
        }
    }

    // MARK: - Export

    /// The four documents `SPEC.md`'s Export section asks for, each to a file and — for the three
    /// Markdown ones — to the clipboard.
    ///
    /// Copy is offered first in spirit and second in the list because saving is the item people look
    /// for and copying is the one they use: a weekly review's next stop is a one-to-one document, and
    /// a round trip through the Finder for that is three steps too many.
    ///
    /// The CSV has no copy item. It exists to be opened by a spreadsheet, and pasting several hundred
    /// quoted CRLF rows into a text field is not a thing anybody wants.
    private var exportMenu: some View {
        Menu("Export") {
            ForEach(ExportKind.allCases) { kind in
                Button(kind.saveTitle) { export(kind) }
            }

            Divider()

            ForEach(ExportKind.allCases.filter { $0.format == .markdown }) { kind in
                Button(kind.copyTitle) { copyExport(kind) }
            }
        }
    }

    /// Fire-and-forget, like every other command here: the save panel is modal, the write is small,
    /// and `ExportService` reports any failure through the error banner rather than a return value.
    private func export(_ kind: ExportKind) {
        Task { await exportService.save(kind) }
    }

    private func copyExport(_ kind: ExportKind) {
        Task { await exportService.copy(kind) }
    }

    // MARK: - Session

    /// One item, one shortcut, three titles — § 7.1's answer to "⌘Return: Start or confirm" without
    /// three colliding shortcuts.
    ///
    /// While a panel is up the item **retitles but stays disabled**, so the key equivalent falls
    /// through to the panel's own primary button, which is the only thing that knows what the user
    /// has typed. The menu still shows the user which action `⌘⏎` is currently bound to.
    private var primaryActionTitle: String {
        guard let sheet = appModel.sheet else { return "Finish Session" }
        switch sheet {
        case .startSession:
            return "Start Focus"
        case .sessionReview:
            return "Save Review"
        case .addAccomplishment, .projectEditor, .captureInterruption,
            .interruptionAccomplishment:
            // Each carries its own Save; the title stays on the action the menu would perform once
            // the panel closes.
            return "Finish Session"
        }
    }

    private var isFinishAvailable: Bool {
        appModel.sheet == nil && manager.activeSession != nil
    }

    /// Finishes, then asks "What happened?" — § 5.3's "triggered by Finish".
    ///
    /// The review is presented from here rather than from an observer on `pendingReview`, because
    /// `bootstrap()` also sets that property: a session left unanswered when Lggr last stopped is
    /// restored at launch, and a sheet that opened by itself over an empty Today would be the app
    /// interrogating somebody who has just arrived. Finishing is a request; launching is not.
    private func finish() {
        Task {
            await manager.finishSession()
            guard manager.pendingReview != nil else { return }
            appModel.presentReview()
        }
    }

    private var pauseTitle: String {
        manager.activeSession?.isPaused == true ? "Resume Session" : "Pause Session"
    }

    /// `Interruption Inbox` on its own, or with the number waiting.
    ///
    /// The count is in the *title* rather than as a badge, and it disappears at zero. A permanent
    /// number beside a menu item is the beginning of a thing that grows when the user is busy, and
    /// nothing in Lggr grows (`INTELLIGENCE.md` § 3.4).
    private var inboxTitle: String {
        let waiting = environment.inbox.pendingCount
        return waiting > 0 ? "Interruption Inbox (\(waiting))" : "Interruption Inbox"
    }
}
