import AppKit
import LggrKit

// AppKit, deliberately and unavoidably. See docs/_design/SPIKE-menubar.md § "Second spike".
//
// Three questions in this file can only be answered by an `NSApplicationDelegate`; SwiftUI exposes
// no scene-level equivalent for any of them.

/// The application delegate.
///
/// It owns three answers and no state, and it reaches for `AppEnvironment.shared` because AppKit
/// instantiates this class itself — there is no initialiser seam to hand it a dependency through.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set once `applicationShouldTerminate` has asked for more time, so the reply is sent exactly
    /// once however the flush finishes.
    private var hasRepliedToTerminate = false

    /// How long the terminate-time flush is allowed to take before the app quits anyway.
    ///
    /// A local write takes milliseconds. Two seconds is generous, and a bounded wait is the point:
    /// an app that can hang on quit has traded one lost session for every future one.
    private static let flushTimeout: TimeInterval = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launch, not a scene: the user may have quit with every window closed, in which case no
        // scene body ever runs and nothing would load today's data or restore a running session.
        Task { await AppEnvironment.shared.bootstrap() }
    }

    /// **The measured requirement, not polish** (`SPIKE-menubar.md`).
    ///
    /// AppKit *asks* whether to terminate when the last window closes, and this answer is the only
    /// thing that keeps the process alive. Without it, closing the main window quits Lggr and takes
    /// a running focus session with it — which is the exact opposite of what a menu bar timer is
    /// for. `LSUIElement` is `false`, so the application menu bar and every command survive with it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no windows open brings the main window back (`04-screens.md`
    /// § 1.3). With a window already visible, AppKit's own behaviour is already right.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        AppEnvironment.shared.appModel.showMainWindow()
        return true
    }

    /// Flushes the session that is in flight *and* the ambient capture buffer before the process
    /// goes away.
    ///
    /// `SessionManager` persists after every mutation, but `togglePause` does it from a detached
    /// `Task` — so quitting in the same breath as pausing can race the write. Saving the current
    /// value again is a whole-value upsert keyed by `id`, so it is idempotent, and awaiting it
    /// guarantees the store has finished before we reply.
    ///
    /// `LggrStore` has no `flush()`; a re-save is the flush the Phase 2 protocol offers.
    ///
    /// **This can no longer answer `.terminateNow`.** The sampler buffers in memory and writes on
    /// its 60-second beat, so an immediate quit discards up to a minute of activity — and, worse,
    /// the heartbeat would outlive the last flush and the next launch would read the difference as
    /// an `.appNotRunning` gap. A quit is the one absence the app should never have to guess about.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let environment = AppEnvironment.shared
        let manager = environment.sessionManager
        let session = manager.activeSession ?? manager.pendingReview
        let store = environment.store

        Task {
            if let session {
                try? await store.saveSession(session)
            }
            await environment.capture.prepareForTermination()
            self.replyToTerminate()
        }

        // A quit that waits forever on a stuck disk is worse than a quit that loses one pause, so
        // the wait is bounded and the app leaves either way.
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.flushTimeout * 1_000_000_000))
            self.replyToTerminate()
        }

        return .terminateLater
    }

    private func replyToTerminate() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
