import LggrKit
import SwiftUI

// The scene graph. See docs/_design/04-screens.md § 1.1 and 02-architecture.md § 5.1.
//
//   MenuBarExtra  ─ MenuBarContentView  ─ .menuBarExtraStyle(.window), 320pt
//   Window "Lggr" ─ RootWindow          ─ id: WindowID.main, default 1040 × 720
//   Settings      ─ SettingsView        ─ the same pane the sidebar's Settings row renders
//
// **`Window`, not `WindowGroup`.** There is exactly one main window: it owns the sidebar selection,
// and that selection is persisted per user, not per window. `WindowGroup` would also install a
// `New Window` item on `⌘N` — the combination § 7.1 gives to New Focus Session — so a second window
// would be one keystroke away from every attempt to start a session.

/// Scene identifiers. One so far, and it is a string a menu bar popover has to name from outside any
/// window, which is why it is not an inline literal.
public enum WindowID {
    public static let main = "main"
}

@main
@MainActor
struct LggrMain: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// The one composition root. Shared rather than `@State` because `AppDelegate` answers launch,
    /// reopen and terminate, and AppKit builds it without passing anything in.
    private let environment = AppEnvironment.shared

    init() {
        // Runs before any scene is built, so the snapshot pass never touches the real store and
        // never shows a window.
        if let directory = SnapshotMode.requestedDirectory {
            SnapshotMode.run(writingTo: directory)
        }

        // Also before any scene, and before `AppEnvironment.shared` is first touched — so a second
        // launch neither opens a window nor loads the document the running instance owns. It brings
        // the running instance to the front and exits.
        SingleInstanceGuard.installOrExit()
    }

    var body: some Scene {
        Window("Lggr", id: WindowID.main) {
            RootWindow()
                .lggrEnvironment(environment.sessionManager, environment.appModel)
                .environment(environment)
                .environment(\.clock, environment.clock)
                .modifier(MainWindowOpener(appModel: environment.appModel))
                // Idempotent, and a second chance at the one in `applicationDidFinishLaunching`.
                .task { await environment.bootstrap() }
        }
        .defaultSize(
            width: Layout.windowDefaultSize.width,
            height: Layout.windowDefaultSize.height
        )
        .commands { AppCommands(environment: environment) }

        MenuBarExtra {
            menuBarContent
        } label: {
            // `MenuBarLabel(manager:)`, never `MenuBarLabel(state:)`. The label reads the observable
            // instant inside its own body, and that is the entire reason it redraws at 1 Hz
            // (SPIKE-menubar.md). A pre-computed state would freeze the clock at the first frame.
            MenuBarLabel(manager: environment.sessionManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(environment: environment, host: .window)
                .environment(environment)
                .environment(\.clock, environment.clock)
        }
    }

    // MARK: - Menu bar

    /// The popover, with the start panel injected so it can be rendered *inline*.
    ///
    /// A `.menuBarExtraStyle(.window)` popover cannot present a sheet, so starting a session from the
    /// menu bar replaces the popover's contents rather than opening a window. That is what keeps the
    /// promise in § 1.3: starting a session never forces a window at you.
    private var menuBarContent: some View {
        MenuBarContentView(inlineStartPanel: {
            AnyView(
                StartSessionForm(
                    presentation: .popover,
                    context: environment.startSessionContext(),
                    onCreateProject: { environment.appModel.presentProjectEditor() },
                    onStart: { request in
                        environment.start(request)
                        environment.appModel.resetPopover()
                    },
                    onDismiss: { environment.appModel.resetPopover() }
                )
                // `MenuBarContentView` insets whatever it is given by `Space.m` and pins it to the
                // popover's 320pt. The panel already supplies both for the `.popover` presentation,
                // so the outer inset is cancelled instead of doubled — otherwise the panel draws
                // 24pt wider than the popover containing it.
                .padding(-Space.m)
            )
        })
        .lggrEnvironment(environment.sessionManager, environment.appModel)
        .environment(environment)
        .environment(\.clock, environment.clock)
        .modifier(MainWindowOpener(appModel: environment.appModel))
    }
}

// MARK: - Opening the main window from anywhere

/// Hands `AppModel` a way to open the main window.
///
/// `OpenWindowAction` can only be read from the SwiftUI environment, and `AppModel` — which every
/// menu command and every popover row calls into — has no environment to read. So the scenes that
/// *do* have one install the action on it. Both scenes install the same closure: the menu bar
/// popover may be the only thing on screen, and `⌘1` must still be able to open a window.
///
/// Without this, presenting a panel from the menu bar with every window closed silently does nothing.
@MainActor
private struct MainWindowOpener: ViewModifier {

    @Environment(\.openWindow) private var openWindow

    let appModel: AppModel

    func body(content: Content) -> some View {
        content.onAppear {
            appModel.openMainWindow = { openWindow(id: WindowID.main) }
        }
    }
}
