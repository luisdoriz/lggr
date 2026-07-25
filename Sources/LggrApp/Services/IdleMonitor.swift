import CoreGraphics
import Foundation
import LggrKit

/// What the window server will tell us about the login session, without being asked for a
/// permission.
///
/// Two facts live here rather than in `IdleMonitor` alone because `ActivitySampler` needs the same
/// answers for different reasons: the monitor uses them to decide whether an idle reading can be
/// trusted, and the sampler uses them to decide whether an interval may be reopened at all.
///
/// `CGSessionCopyCurrentDictionary` is the documented way to ask which login session owns the
/// console. `NSWorkspace` has no equivalent — and, per `INTELLIGENCE.md` §3.8,
/// `NSWorkspace.screensDidLockNotification` does not exist at all, so this dictionary is also the
/// cross-check against the undocumented lock notifications the sampler listens to.
public enum SystemSessionState {

    /// Key names are string literals rather than the `kCGSession…` constants: those are `CFSTR`
    /// macros, which Swift does not import.
    private static let onConsoleKey = "kCGSSessionOnConsoleKey"
    private static let screenLockedKey = "CGSSessionScreenIsLocked"

    /// This login session currently owns the display.
    ///
    /// False during fast user switching, which is the case that matters: `NSWorkspace` keeps
    /// reporting a *background* session's frontmost application, and the other user's typing zeroes
    /// this user's idle timer. Both together would manufacture an hour of confident, invented work.
    public static var isOnConsole: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            // No dictionary is not evidence of being switched away, and treating it as such would
            // stop capture outright on a machine that is behaving perfectly well.
            return true
        }
        guard let onConsole = session[onConsoleKey] as? NSNumber else { return true }
        return onConsole.boolValue
    }

    /// The screen is locked, according to the window server rather than to a notification.
    public static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        guard let locked = session[screenLockedKey] as? NSNumber else { return false }
        return locked.boolValue
    }

    /// The main display is asleep.
    ///
    /// The gate on reopening an interval after `didWake`. Power Nap wakes the machine with the lid
    /// shut; an interval reopened on `didWake` alone would record the small hours as work.
    public static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Something outside the idle timer agrees that the user is not there.
    public static var corroboratesAbsence: Bool {
        isDisplayAsleep || isScreenLocked || !isOnConsole
    }

    /// All three answers, read together.
    ///
    /// Taken as one value because the three are read as one decision, and because it gives the
    /// sampler something injectable. Reading the globals directly made the capture layer depend on
    /// the state of the actual machine, so a test that ran while the developer's screen happened to
    /// be locked watched the sampler correctly suspend itself and reported that as a failure.
    public struct Snapshot: Equatable, Sendable {
        public var isOnConsole: Bool
        public var isScreenLocked: Bool
        public var isDisplayAsleep: Bool

        public init(
            isOnConsole: Bool = true,
            isScreenLocked: Bool = false,
            isDisplayAsleep: Bool = false
        ) {
            self.isOnConsole = isOnConsole
            self.isScreenLocked = isScreenLocked
            self.isDisplayAsleep = isDisplayAsleep
        }

        /// A machine with the user present and the screen on — the state a test means by "normal".
        public static let active = Snapshot()

        public var corroboratesAbsence: Bool {
            isDisplayAsleep || isScreenLocked || !isOnConsole
        }
    }

    public static var snapshot: Snapshot {
        Snapshot(
            isOnConsole: isOnConsole,
            isScreenLocked: isScreenLocked,
            isDisplayAsleep: isDisplayAsleep
        )
    }
}

/// Whether the user is at the machine — and how much that answer is worth.
///
/// **This type never decides whether a run was unbroken.** Idle is forgeable: a single synthetic
/// `mouseMoved` from any process zeroes both `.combinedSessionState` and `.hidSystemState`, and
/// several things people run all day do exactly that — Screen Sharing, mouse jigglers, Karabiner,
/// Zoom remote control. Frontmost-application continuity defines a run; this is an annotation
/// carried alongside it, with an `IdleConfidence` that says whether anything corroborated it.
///
/// ## Why the shape below is the shape
///
/// Acceptance criterion 8 — Lggr must not appear in Activity Monitor's "Apps Using Significant
/// Energy" over an eight-hour battery day — is a Phase 1 gate, and polling is the only thing in
/// Phase 1 that can fail it. Three decisions carry that gate and none of them is stylistic:
///
/// 1. **Exactly one timer.** Not one for the threshold and another for the backoff; not one per
///    observed application. The whole capture subsystem runs on two timers — this one and the
///    60-second heartbeat — and nothing may add a third.
/// 2. **A leeway of at least three seconds.** Leeway is what lets the kernel coalesce our wake-up
///    with one it was already making. A 15-second timer with no leeway is 240 dedicated wake-ups an
///    hour; the same timer with 3 seconds of slack is close to free, and an idle threshold measured
///    in minutes cannot tell the difference.
/// 3. **No timer at all when nothing can change.** While the screen is locked, the machine is
///    asleep, or another user is on the console, the answer cannot move and polling for it is pure
///    battery drain. Suspension here *cancels* the source rather than calling `suspend()` on it:
///    an unbalanced `resume()` is a crash on deallocation, and a lock/unlock cycle is exactly the
///    kind of event that arrives twice.
///
/// Backing off from 15 s to 60 s once already idle follows from the same reasoning: the interesting
/// transition is active → idle, which we want to catch promptly because it ends an interval. The
/// reverse transition is corrected by backdating, so noticing it a minute late costs nothing.
@MainActor
public final class IdleMonitor {

    /// A reason polling is standing down. A set of these, not a boolean: the lid can close while the
    /// screen is already locked, and unlocking must not restart polling on a sleeping machine.
    public enum Suspension: String, CaseIterable, Sendable, Hashable {
        case screenLocked
        case systemSleep
        case displayOff
        case fastUserSwitched
        case trackingPaused
        case notStarted
    }

    /// The current answer, and the instant it started being the answer.
    public struct Reading: Equatable, Sendable {
        public var isIdle: Bool
        public var confidence: IdleConfidence
        /// When the idle stretch began, backdated from the idle timer and clamped. `nil` while
        /// active.
        public var since: Date?

        public init(isIdle: Bool = false, confidence: IdleConfidence = .low, since: Date? = nil) {
            self.isIdle = isIdle
            self.confidence = confidence
            self.since = since
        }
    }

    // MARK: - Cadence

    /// Poll period while the user is present.
    public static let activeInterval: TimeInterval = 15
    /// Poll period once already idle. Nothing is lost by noticing the return a minute late.
    public static let idleInterval: TimeInterval = 60
    /// The slack the kernel is allowed in order to coalesce our wake-up with another.
    public static let leeway: TimeInterval = 3

    // MARK: - State

    public private(set) var reading = Reading()
    public private(set) var suspensions: Set<Suspension> = [.notStarted]

    /// True when the single timer is installed and firing.
    public var isPolling: Bool { timer != nil }

    private var timer: (any DispatchSourceTimer)?
    private var scheduledInterval: TimeInterval?
    private var threshold: TimeInterval
    private var hasStarted = false

    /// Idle stretches may never be backdated past this instant.
    ///
    /// On wake, `secondsSinceLastEventType` includes the whole time the machine was asleep, so
    /// `now − seconds` lands *before* `willSleep` fired and the idle stretch would overlap the sleep
    /// gap already recorded for the same span. Clamping to the last resume is the documented
    /// precedence (`INTELLIGENCE.md` §3.8) and it is the reason two mechanisms never claim the same
    /// minutes.
    private var backdateFloor: Date = .distantPast

    private var onChange: ((Reading) -> Void)?

    private let clock: any DateProviding
    /// Seams. Real implementations by default; a test or a gallery can drive either one.
    private let secondsSinceLastInput: @Sendable () -> TimeInterval
    private let corroboratesAbsence: @Sendable () -> Bool

    public init(
        threshold: TimeInterval = 3 * 60,
        clock: any DateProviding = SystemClock(),
        secondsSinceLastInput: @escaping @Sendable () -> TimeInterval = IdleMonitor.systemIdleSeconds,
        corroboratesAbsence: @escaping @Sendable () -> Bool = { SystemSessionState.corroboratesAbsence }
    ) {
        self.threshold = max(0, threshold)
        self.clock = clock
        self.secondsSinceLastInput = secondsSinceLastInput
        self.corroboratesAbsence = corroboratesAbsence
    }

    /// How long since any human input reached this login session.
    ///
    /// `.combinedSessionState` rather than `.hidSystemState`: the combined state also counts events
    /// posted by software, and counting them is the honest reading — a jiggler *is* generating
    /// events, and pretending otherwise would let Lggr claim a confidence the signal cannot support.
    /// The `IdleConfidence` flag is where that doubt is recorded instead.
    public nonisolated static let systemIdleSeconds: @Sendable () -> TimeInterval = {
        // `~0` is `kCGAnyInputEventType`, which has no Swift case. The fallback is unreachable in
        // practice and still costs nothing: `.mouseMoved` alone under-reports idle, which errs
        // toward "the user is here", and under-claiming is the acceptable failure direction.
        let anyInput = CGEventType(rawValue: ~0) ?? .mouseMoved
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: - Lifecycle

    /// Begins polling. Idempotent: calling it twice does not create a second timer.
    public func start(onChange: @escaping (Reading) -> Void) {
        self.onChange = onChange
        hasStarted = true
        suspensions.remove(.notStarted)
        noteResumed(at: clock.now)
        reschedule()
    }

    /// Tears the timer down for good. Safe to call more than once.
    public func stop() {
        hasStarted = false
        suspensions.insert(.notStarted)
        cancelTimer()
        if reading.isIdle {
            reading = Reading()
            onChange?(reading)
        }
    }

    /// The idle threshold, in seconds. Changing it re-evaluates immediately rather than waiting for
    /// the next tick, so a settings change is visible in the timeline at once.
    public func setThreshold(_ seconds: TimeInterval) {
        let clamped = max(0, seconds)
        guard clamped != threshold else { return }
        threshold = clamped
        if isPolling { poll() }
    }

    // MARK: - Suspension

    public func suspend(_ reason: Suspension) {
        let inserted = suspensions.insert(reason).inserted
        guard inserted else { return }
        // The stretch that is beginning belongs to the reason for suspending — a lock gap, a sleep
        // gap — not to an idle stretch. Leaving `isIdle` set would let two mechanisms claim it.
        if reading.isIdle {
            reading = Reading()
            onChange?(reading)
        }
        reschedule()
    }

    public func resume(_ reason: Suspension) {
        let removed = suspensions.remove(reason) != nil
        guard removed else { return }
        if suspensions.isEmpty {
            noteResumed(at: clock.now)
        }
        reschedule()
    }

    /// Records the instant capture became possible again, so no idle stretch can be backdated across
    /// it. Called on wake, on unlock, on switching back, and on un-pausing.
    public func noteResumed(at instant: Date) {
        backdateFloor = max(backdateFloor, instant)
    }

    // MARK: - Polling

    /// Reads the idle timer once and publishes any change. Public so the sampler can take a reading
    /// at a flush boundary without waiting for the next tick.
    @discardableResult
    public func poll() -> Reading {
        let now = clock.now
        let seconds = secondsSinceLastInput()
        let sane = seconds.isFinite ? max(0, seconds) : 0
        let isIdle = threshold > 0 && sane >= threshold
        let corroborated = corroboratesAbsence()

        let since: Date? =
            isIdle
            ? max(now.addingTimeInterval(-sane), backdateFloor)
            : nil

        let next = Reading(
            isIdle: isIdle,
            confidence: corroborated ? .high : .low,
            since: since
        )

        let stateChanged = next.isIdle != reading.isIdle || next.confidence != reading.confidence
        reading = next
        if stateChanged {
            // The poll cadence follows the state, so a transition reschedules the one timer.
            reschedule()
            onChange?(next)
        }
        return next
    }

    // MARK: - The one timer

    private func reschedule() {
        guard hasStarted, suspensions.isEmpty else {
            cancelTimer()
            return
        }
        let wanted = reading.isIdle ? Self.idleInterval : Self.activeInterval
        guard scheduledInterval != wanted || timer == nil else { return }

        cancelTimer()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + wanted,
            repeating: wanted,
            leeway: .milliseconds(Int(Self.leeway * 1000))
        )
        source.setEventHandler {
            // A source scheduled on `DispatchQueue.main` fires on the main thread by definition.
            MainActor.assumeIsolated { [weak self] in
                _ = self?.poll()
            }
        }
        source.resume()
        timer = source
        scheduledInterval = wanted
    }

    /// Cancel rather than `suspend()`.
    ///
    /// A `DispatchSourceTimer` that is deallocated while suspended traps, and the events that
    /// suspend this one — lock, sleep, user switch — are precisely the ones that arrive twice or out
    /// of order. Cancelling removes the failure mode instead of documenting it, and creating a fresh
    /// source on resume costs a few microseconds a few times a day.
    private func cancelTimer() {
        timer?.cancel()
        timer = nil
        scheduledInterval = nil
    }
}
