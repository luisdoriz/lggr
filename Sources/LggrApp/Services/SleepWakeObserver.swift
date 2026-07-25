import AppKit
import Foundation

/// Keeps the displayed clock honest across a lid close.
///
/// AppKit is used here because there is no SwiftUI equivalent: sleep and wake are `NSWorkspace`
/// notifications and nothing else reports them.
///
/// **This observer never adjusts stored data.** Durations are pure functions of `startedAt`,
/// `endedAt` and the pause bookkeeping (`SessionClock`), so a machine that slept for an hour already
/// has the correct elapsed time the moment it wakes. What it does *not* have is a redraw: the
/// `TickTimer` was suspended along with the rest of the process, and the last number the user saw is
/// an hour old. So the two jobs here are exactly:
///
/// - on sleep, stand the heartbeat down, because a timer that fires into a sleeping display is a
///   wake-up nobody asked for;
/// - on wake, re-read the clock once and re-arm the heartbeat, so the first frame after the lid
///   opens is already right.
@MainActor
final class SleepWakeObserver {

    private var tokens: [any NSObjectProtocol] = []

    /// Begins observing, replacing any observation already in place.
    ///
    /// Block-based observation with retained tokens is used rather than an `AsyncSequence`: nothing
    /// from the `Notification` is read, so there is no non-`Sendable` value to keep on the main
    /// actor, and the token pair makes the teardown explicit.
    func start(
        onSleep: @escaping @Sendable @MainActor () -> Void,
        onWake: @escaping @Sendable @MainActor () -> Void
    ) {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        tokens = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                // `queue: .main` guarantees main-thread delivery.
                MainActor.assumeIsolated { onSleep() }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated { onWake() }
            },
        ]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for token in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
    }
}
