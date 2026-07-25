import Foundation

/// The application's one-hertz heartbeat.
///
/// It exists to ask the interface to redraw, and for no other reason. **It never accumulates time.**
/// Every duration Lggr shows is recomputed from the session's stored dates through `SessionClock`
/// (`02-architecture.md` § 6.2), so a dropped tick, a coalesced wake-up, a machine that slept for an
/// hour or a clock that stepped backwards are all invisible: the next tick simply reads the right
/// number.
///
/// The shape below is not a stylistic choice. It was measured (`SPIKE-menubar.md`): a `Timer`
/// constructed by hand and added to `RunLoop.main` in `.common` mode drove 32 consecutive
/// `MenuBarExtra` label redraws at 1.000 ± 0.003 s with no missed ticks. Two details are
/// load-bearing and must not be "simplified":
///
/// 1. **`.common`, not the default run-loop mode.** In the default mode a timer stops firing while a
///    menu is being tracked or a window is being resized — which is precisely when the user is
///    looking at the menu bar timer.
/// 2. **`RunLoop.main.add(_:forMode:)`, not `Timer.scheduledTimer`.** `scheduledTimer` installs the
///    timer in the default mode; there is no parameter to change that.
///
/// A `TimelineView` is not a substitute either: it schedules against the view's own update policy
/// and does not drive a `MenuBarExtra` label hosted by the system.
@MainActor
final class TickTimer {

    private var timer: Timer?

    /// True while the heartbeat is installed on the run loop.
    var isRunning: Bool { timer != nil }

    /// Starts ticking, replacing any tick already in flight.
    ///
    /// `onTick` is invoked on the main actor once a second. `tolerance` lets the system coalesce our
    /// wake-up with others it is already making, which is most of the battery story; a tenth of a
    /// second of jitter is invisible on a clock that shows seconds.
    func start(onTick: @escaping @Sendable @MainActor () -> Void) {
        stop()
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            // A timer scheduled on `RunLoop.main` fires on the main thread by definition, so this is
            // a documented invariant rather than an assumption about ordering.
            MainActor.assumeIsolated { onTick() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Removes the heartbeat. Idle Lggr does zero work per second (`04-screens.md` § 6.3).
    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
