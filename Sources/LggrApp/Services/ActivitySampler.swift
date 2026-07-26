import AppKit
import Foundation
import LggrKit

/// What the menu bar glyph has to say, at a glance.
///
/// The price of ambient capture, paid up front: if the app is always watching, the user must be able
/// to see that without opening anything, and stop it in one click. Per `INTELLIGENCE.md` §2, "a
/// subtle filled variant" does not count — these are distinct glyphs.
public enum ActivityTrackingState: Equatable, Sendable {
    /// Recording. An interval is open, or the frontmost application is excluded.
    case tracking
    /// The user turned tracking off. Nothing is recorded and nothing will be until they say so.
    case paused
    /// The system took capture away: the screen locked, the machine slept, another user signed in.
    case suspended(IdleMonitor.Suspension)

    public var isRecording: Bool { self == .tracking }

    /// Facts about the record, never about the person.
    public var displayName: String {
        switch self {
        case .tracking: "Tracking activity"
        case .paused: "Tracking paused"
        case .suspended(.screenLocked): "Screen locked"
        case .suspended(.systemSleep): "Asleep"
        case .suspended(.displayOff): "Display off"
        case .suspended(.fastUserSwitched): "Another user is signed in"
        case .suspended(.trackingPaused): "Tracking paused"
        case .suspended(.notStarted): "Not tracking"
        }
    }

    /// Three distinct glyphs, not three weights of one.
    public var symbolName: String {
        switch self {
        case .tracking: "record.circle"
        case .paused: "hand.raised"
        case .suspended: "moon.zzz"
        }
    }
}

/// One day's worth of newly captured evidence, ready for the day file.
///
/// The sampler buffers in memory and hands over batches; it never writes. Everything in here is
/// keyed by `id` and every batch is an **upsert**: the interval that is still open is republished on
/// every flush with its end moved forward, so a process that dies between flushes still leaves a day
/// file whose last interval ends at the last flush — which is the same instant as the last heartbeat.
public struct ActivityFlush: Sendable {
    /// Local midnight of the day these belong to. The day file is named from this.
    public let dayStart: Date
    public let intervals: [ActivityInterval]
    public let gaps: [Gap]

    /// How hard this batch should be pushed to the disk.
    ///
    /// `.deviceSynced` only at the boundaries where capture is about to stop — sleep, lock, another
    /// user taking the console, terminate — because those are the moments after which there may be
    /// no second chance. Everywhere else an ordinary buffered write is the honest trade:
    /// `F_FULLFSYNC` on every append would be a physical disk sync for a few hundred bytes of
    /// ambient telemetry, and the worst case it buys against is losing the last few seconds of which
    /// application was frontmost — which the timeline already renders as an absence rather than as
    /// time credited to the wrong application.
    public let durability: FileDurability

    public init(
        dayStart: Date,
        intervals: [ActivityInterval],
        gaps: [Gap],
        durability: FileDurability = .buffered
    ) {
        self.dayStart = dayStart
        self.intervals = intervals
        self.gaps = gaps
        self.durability = durability
    }

    /// The day file this batch belongs in.
    ///
    /// `ActivityLog.append(intervals:gaps:to:)` merges by `id`, which is exactly the contract the
    /// republished open interval relies on: the same interval arrives on every flush with a later
    /// end and replaces its earlier self rather than accumulating.
    public func dayKey(in calendar: Calendar = .autoupdatingCurrent) -> ActivityDayKey? {
        ActivityDayKey(date: dayStart, in: calendar)
    }
}

/// Receives batches to persist. One await per batch, applied in order.
public typealias ActivityFlushHandler = @MainActor @Sendable ([ActivityFlush]) async -> Void

/// The ambient record of which application was in front of the user, and of the time that was not
/// spent in front of one.
///
/// **This runs continuously from launch. It is not scoped to a focus session.** That inversion is
/// the whole of Phase 1: a focus session becomes a label applied to a span of the record rather than
/// a container for it, which is the only arrangement under which the app can show you the morning
/// you forgot to press start.
///
/// ## What it records
///
/// `bundleIdentifier` and `displayName`, and **nothing else about the application**. There is no
/// window title here, there is no field on `ActivityInterval` to put one in, and Phase 1 requests
/// **zero permissions** — no Accessibility, no Automation, no EventKit. Every signal below comes
/// from `NSWorkspace`, `DistributedNotificationCenter` or CoreGraphics session state, all of which
/// are readable by any process without a TCC grant. If this file ever reaches for `AXUIElement`, it
/// has left Phase 1.
///
/// ## How it stays honest
///
/// Each transition — an activation, a lock, a sleep, a user switch — closes the interval that was
/// open and either opens the next one or opens a typed `Gap`. Nothing is ever smeared across an
/// absence, because an absence is a value with a reason attached. The gap reasons are already
/// modelled, including `.unexplained`, which exists so that time the app cannot account for stays
/// visible as time the app cannot account for instead of quietly extending a neighbouring block.
///
/// Three specific failures are guarded rather than assumed away:
///
/// - **Fast user switching manufactures activity.** `NSWorkspace` keeps reporting a background
///   session's frontmost application, and the other user's typing zeroes this user's idle timer.
///   Capture stops outright between `sessionDidResignActive` and `sessionDidBecomeActive`; criterion
///   4 requires *zero* intervals for that span, and the single `isRecording` guard is what gives it.
/// - **A clock step is not the passage of time.** Every duration is a difference of
///   `ContinuousClock` instants. `start` and `end` are wall-clock, for placement and bucketing only.
///   When the two disagree by more than a couple of seconds the interval is **dropped**, not
///   recorded, and its span becomes `.unexplained`: an inflated run is a confidently wrong block,
///   which is the one failure this design exists to avoid.
/// - **Time nobody witnessed.** App Nap, an unannounced sleep and a suspended process all look
///   identical from in here: the flush stops happening and then resumes much later with an interval
///   that appears to have run the whole time. Anything longer than a few flush periods since the
///   last flush closes the open interval at the last flush and marks the remainder `.unexplained`.
///
/// ## Why it buffers
///
/// Activity does not go in `store.json`; that store rewrites its whole document on every save, and
/// an interval per app switch would be hundreds of full-document rewrites a day. Instead the sampler
/// holds intervals in memory and hands them over on **events**: an app-switch burst settling, a
/// buffer that has grown past its threshold, a sleep, a lock, another user taking the console, a
/// terminate. Never once per activation, and — since the write path was rebuilt — never merely
/// because sixty seconds have passed.
///
/// The heartbeat still beats once a minute, because forty bytes once a minute is what makes a crash
/// recoverable, and this type still listens to it. What it does on a beat is *witness*, not write:
/// it renews the evidence that the process was alive so that `guardAgainstUnwitnessedTime` can tell
/// a quiet minute from a minute the machine spent asleep. A tick is not an event, and a write per
/// tick was 1,440 full rewrites of a 145 KB file a day.
///
/// What that costs, stated plainly: a hard kill now loses the open interval back to the last event
/// rather than back to the last minute. In practice the two are close together. Either the user is
/// interacting, in which case switching applications produces a burst flush within seconds, or they
/// have stopped, in which case the idle monitor cuts the interval — and flushes — within the idle
/// threshold. The uncovered case is uninterrupted work in a single application for a long stretch,
/// and even there the loss reaches the timeline as an `.appNotRunning` gap measured from the last
/// heartbeat, which is time nobody claims rather than time claimed wrongly.
@MainActor
@Observable
public final class ActivitySampler {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Seconds without input after which the user is treated as away.
        public var idleThreshold: TimeInterval
        /// Bundle identifiers never recorded at all; their time becomes an `.excludedApplication`
        /// gap, which is visible as an absence rather than silently missing.
        public var excludedApplications: Set<String>
        /// Bundle identifiers whose *time* is recorded and whose *identity* is not. The interval is
        /// kept so the day still adds up; the bundle id and name are replaced before anything is
        /// handed over, so no writer downstream can leak what it never received.
        public var privateApplications: Set<String>
        /// How long an app-switch burst must be quiet before it is flushed.
        public var burstQuietPeriod: TimeInterval

        public init(
            idleThreshold: TimeInterval = 3 * 60,
            excludedApplications: Set<String> = [],
            privateApplications: Set<String> = [],
            burstQuietPeriod: TimeInterval = 2
        ) {
            self.idleThreshold = max(0, idleThreshold)
            self.excludedApplications = excludedApplications
            self.privateApplications = privateApplications
            self.burstQuietPeriod = max(0, burstQuietPeriod)
        }
    }

    /// What a private application is recorded as. A constant, not a per-app pseudonym: a stable
    /// pseudonym is still an identifier, and a timeline joined against it would reconstruct exactly
    /// what the setting exists to hide.
    public static let privateBundleIdentifier = "com.lggr.private"
    public static let privateDisplayName = "Private"

    /// Long enough since the last heartbeat that the app cannot vouch for the span in between.
    private static let unwitnessedThreshold: TimeInterval = 3 * ActivityHeartbeat.period

    /// How many buffered records force a flush regardless of what else is happening.
    ///
    /// The burst timer covers ordinary switching, but it is rescheduled on every activation, so a
    /// user who keeps switching never lets it settle and the buffer would grow without bound. This
    /// caps the loss on a hard kill at roughly this many transitions — a few tens of seconds of
    /// switching — and caps the memory the buffer can hold at a few kilobytes.
    private static let bufferFlushThreshold = 32

    // MARK: - Observable state

    /// What the menu bar renders, and the only state any view needs from this type.
    public private(set) var state: ActivityTrackingState = .suspended(.notStarted)

    /// The last instant a batch was handed to the flush handler.
    public private(set) var lastFlushedAt: Date?

    /// What the previous run left behind, decided once at `start`. The wiring layer reads
    /// `closeOpenIntervalsAt` to clamp anything the day file has open past that instant; the gap
    /// itself is published through the ordinary flush path.
    public private(set) var launchRecovery: ActivityLaunchRecovery.Outcome = .nothingToDo

    // MARK: - Collaborators

    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let idleMonitor: IdleMonitor
    @ObservationIgnored private let heartbeat: ActivityHeartbeat
    @ObservationIgnored private let onFlush: ActivityFlushHandler
    @ObservationIgnored private var configuration: Configuration

    // MARK: - Capture state

    /// The interval currently accumulating. Monotonic start alongside the wall-clock one, because
    /// only one of the two can be trusted to measure.
    private struct OpenInterval {
        let id: UUID
        let bundleIdentifier: String
        let displayName: String
        let start: Date
        let startedAt: ContinuousClock.Instant
        let tzOffsetMinutes: Int
        var isIdle: Bool
        var idleConfidence: IdleConfidence
    }

    private struct OpenGap {
        let id: UUID
        let reason: GapReason
        let start: Date
    }

    @ObservationIgnored private var openInterval: OpenInterval?
    @ObservationIgnored private var openGap: OpenGap?
    @ObservationIgnored private var pendingIntervals: [ActivityInterval] = []
    @ObservationIgnored private var pendingGaps: [Gap] = []

    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var suspensions: Set<IdleMonitor.Suspension> = [.notStarted]
    /// Set by `willSleep` and cleared once the display is genuinely back. Power Nap delivers
    /// `didWake` with the lid shut, so waking is not on its own permission to record again.
    @ObservationIgnored private var isAwaitingDisplay = false

    @ObservationIgnored private var workspaceTokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var distributedTokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var timeZoneToken: (any NSObjectProtocol)?
    @ObservationIgnored private var burstTask: Task<Void, Never>?
    /// Flush batches are chained rather than fired in parallel: two overlapping writes of the same
    /// day file would race, and the later one could be the older batch.
    @ObservationIgnored private var flushChain: Task<Void, Never>?
    @ObservationIgnored private let continuous = ContinuousClock()
    /// The last moment this process is known to have been running, on both clocks.
    ///
    /// Renewed by every heartbeat and by every flush — deliberately *not* only by flushes. Once the
    /// flush cadence stopped riding on the heartbeat, using the last flush as the last witnessed
    /// instant would have meant that reading one document for ten quiet minutes looked exactly like
    /// ten minutes of App Nap, and `guardAgainstUnwitnessedTime` would have carved an
    /// `.unexplained` gap out of ordinary work.
    @ObservationIgnored private var lastWitnessedInstant: ContinuousClock.Instant?
    @ObservationIgnored private var lastWitnessedAt: Date?

    private var calendar: Calendar { Calendar.autoupdatingCurrent }

    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    /// Reads the window server's view of the login session. Injectable because it is *ground truth
    /// about the real machine*: a test running while the developer's screen happens to be locked
    /// would otherwise watch the sampler correctly suspend itself and call that a failure.
    private let sessionState: @Sendable () -> SystemSessionState.Snapshot
    /// Which application is in front. Injectable for the same reason `sessionState` is: it is a fact
    /// about the real machine. A CI runner has no logged-in graphical session and therefore no
    /// frontmost application at all, so a test that drives the sampler and expects an interval passes
    /// on a developer's desk and fails on every runner.
    private let frontmostApplication: @MainActor () -> FrontmostApplication?

    // MARK: - Init

    /// - Parameter workspaceCenter: where workspace notifications are observed. Defaults to the real
    ///   one, which is process-global — so two samplers alive at once each receive the other's
    ///   notifications. That is fine in the app, which has exactly one, and wrong in a test suite,
    ///   where it made a second sampler suspend itself on a notification meant for the first. Passing
    ///   a private `NotificationCenter` removes the coupling instead of trying to order around it.
    public init(
        configuration: Configuration = Configuration(),
        clock: any DateProviding = SystemClock(),
        heartbeat: ActivityHeartbeat,
        idleMonitor: IdleMonitor? = nil,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
        sessionState: @escaping @Sendable () -> SystemSessionState.Snapshot = {
            SystemSessionState.snapshot
        },
        frontmostApplication: @escaping @MainActor () -> FrontmostApplication? = {
            FrontmostApplication.current
        },
        onFlush: @escaping ActivityFlushHandler
    ) {
        self.configuration = configuration
        self.clock = clock
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.sessionState = sessionState
        self.frontmostApplication = frontmostApplication
        self.heartbeat = heartbeat
        self.idleMonitor =
            idleMonitor ?? IdleMonitor(threshold: configuration.idleThreshold, clock: clock)
        self.onFlush = onFlush
    }

    // MARK: - Lifecycle

    /// Begins ambient capture, after accounting for whatever the previous run left open.
    ///
    /// - Parameters:
    ///   - lastRecordedEnd: the latest end across the stored activity files, or `nil` on a first
    ///     launch.
    ///   - unresolvedSleepSince: the start of a `.systemSleep` gap that was written and never
    ///     closed. Passing it is what keeps a lid closed overnight from being reported as a crash.
    public func start(lastRecordedEnd: Date? = nil, unresolvedSleepSince: Date? = nil) {
        stopObserving()

        let now = clock.now
        launchRecovery = ActivityLaunchRecovery.plan(
            lastHeartbeat: heartbeat.readLastBeatFromDisk(),
            lastRecordedEnd: lastRecordedEnd,
            unresolvedSleepSince: unresolvedSleepSince,
            launchedAt: now
        )
        if let gap = launchRecovery.gap {
            pendingGaps.append(gap)
        }

        observeWorkspace()
        observeSessionLock()
        observeTimeZone()

        suspensions.remove(.notStarted)
        lastWitnessedInstant = continuous.now
        lastWitnessedAt = now

        idleMonitor.setThreshold(configuration.idleThreshold)
        idleMonitor.start { [weak self] reading in self?.handleIdleChange(reading) }

        // The beat renews the evidence that this process is alive; it does not write the buffer.
        // See `observeHeartbeat`.
        heartbeat.start { [weak self] _ in self?.observeHeartbeat() }

        // Launching into a locked screen or into a background login session is ordinary — a login
        // item starts before the user has unlocked, and fast user switching survives a restart.
        // Asking the window server first is what keeps criterion 4 true from the very first line
        // rather than from the first notification.
        adoptSuspensionsFromSystem()
        guard isRecording else {
            syncGapToState(at: now)
            updateState()
            flush(reason: .launch)
            return
        }

        // `didActivateApplication` never fires for the application that was already frontmost when
        // the app launched, so the first interval has to be seeded by asking.
        refreshFromSystem(at: now)
        updateState()
        flush(reason: .launch)
    }

    /// Closes the open interval, flushes, and stands every timer down. The batch is awaited, so a
    /// terminate handler that awaits this has the bytes on disk before it replies.
    public func stop() async {
        stopObserving()
        burstTask?.cancel()
        burstTask = nil
        idleMonitor.stop()
        heartbeat.stop()
        closeInterval(at: clock.now)
        flush(reason: .terminating)
        await flushChain?.value
        suspensions.insert(.notStarted)
        updateState()
    }

    /// For `applicationShouldTerminate`. Everything buffered reaches the handler before it returns.
    public func prepareForTermination() async {
        await stop()
    }

    public func updateConfiguration(_ configuration: Configuration) {
        let previous = self.configuration
        self.configuration = configuration
        idleMonitor.setThreshold(configuration.idleThreshold)
        // An application that just became excluded, or just stopped being, changes what should be
        // recorded right now — not at the next activation, which may be an hour away.
        if previous.excludedApplications != configuration.excludedApplications
            || previous.privateApplications != configuration.privateApplications
        {
            refreshFromSystem(at: clock.now)
            flush(reason: .transition)
        }
    }

    // MARK: - Pause

    /// The popover's first row, not a Settings toggle.
    public func pause() {
        guard !isPaused else { return }
        isPaused = true
        let now = clock.now
        closeInterval(at: now)
        syncGapToState(at: now)
        idleMonitor.suspend(.trackingPaused)
        updateState()
        flush(reason: .transition)
    }

    /// Un-pausing is not on its own permission to record: the screen may have locked while tracking
    /// was off, so this goes through the same gate as a wake or an unlock.
    public func resumeTracking() {
        guard isPaused else { return }
        isPaused = false
        let now = clock.now
        idleMonitor.noteResumed(at: now)
        idleMonitor.resume(.trackingPaused)
        resumeIfPermitted(at: now)
    }

    public func togglePause() {
        isPaused ? resumeTracking() : pause()
    }

    // MARK: - Observation

    private func observeWorkspace() {
        let center = workspaceCenter

        // Nothing is read out of the `Notification`; the frontmost application is asked for
        // directly instead. That keeps a non-`Sendable` `NSRunningApplication` out of the closure
        // and, more usefully, makes launch, activation and termination the same code path — all
        // three mean "the frontmost application may now be different".
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            workspaceTokens.append(token)
        }

        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] in
            self?.handleActivation()
        }
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] in
            self?.handleActivation()
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] in
            // The frontmost application after a quit is whatever the system promoted, and it is
            // already correct by the time this arrives.
            self?.handleActivation()
        }
        // Two Xcode windows on two Spaces are not one continuous run.
        observe(NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
            self?.handleActivation()
        }

        observe(NSWorkspace.willSleepNotification) { [weak self] in
            self?.handleSuspend(.systemSleep)
        }
        observe(NSWorkspace.didWakeNotification) { [weak self] in
            self?.handleWake()
        }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.handleSuspend(.displayOff)
        }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.handleDisplayWake()
        }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.handleSuspend(.fastUserSwitched)
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.handleUserPresent(clearing: [.fastUserSwitched])
        }

        // Lggr's own UI losing focus. Cheap, and worth taking: a background app that is no longer
        // active becomes eligible for App Nap, which coalesces timers by up to a minute and can hold
        // a queued write far longer than the burst period suggests. Getting the buffer out at the
        // moment the user looks away is what keeps that from turning into lost app-switch history.
        //
        // Buffered, not synced. Resigning active is not a moment capture stops — the machine is awake
        // and the user is still working — so it does not earn a physical disk sync.
        let resignToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.flush(reason: .transition)
            }
        }
        workspaceTokens.append(resignToken)

        // The process is going away; get the buffer out. `stop()` is the ordered path, this is the
        // safety net for a quit that does not route through the delegate.
        let terminateToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.closeInterval(at: self.clock.now)
                self.flush(reason: .terminating)
            }
        }
        workspaceTokens.append(terminateToken)
    }

    /// `NSWorkspace.screensDidLockNotification` does not exist — verified twice, per
    /// `INTELLIGENCE.md` §3.8. These two distributed notifications are undocumented but stable, and
    /// the risk of relying on them is bounded by cross-checking `CGSessionCopyCurrentDictionary`
    /// through `SystemSessionState` before any interval is reopened. `screensDidSleep` is a
    /// different event and is not a substitute: a display can sleep unlocked and lock without
    /// sleeping.
    private func observeSessionLock() {
        let center = distributedCenter
        let locked = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.handleSuspend(.screenLocked)
            }
        }
        let unlocked = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                // An unlock is the strongest evidence of presence there is: somebody typed a
                // password. Whatever else the record believed about their absence is over.
                self?.handleUserPresent(clearing: [.screenLocked, .displayOff, .systemSleep])
            }
        }
        distributedTokens = [locked, unlocked]
    }

    /// A timezone change mid-day rotates the interval so each one carries the offset that was in
    /// effect while it ran. Without this, flying to Berlin renders the morning in the wrong hour
    /// buckets and a 23-minute stretch can print as `1:52–1:15`.
    private func observeTimeZone() {
        timeZoneToken = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                let now = self.clock.now
                self.closeInterval(at: now)
                self.refreshFromSystem(at: now)
                self.flush(reason: .transition)
            }
        }
    }

    private func stopObserving() {
        let workspace = workspaceCenter
        for token in workspaceTokens {
            workspace.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        workspaceTokens.removeAll()

        let distributed = distributedCenter
        for token in distributedTokens {
            distributed.removeObserver(token)
        }
        distributedTokens.removeAll()

        if let timeZoneToken {
            NotificationCenter.default.removeObserver(timeZoneToken)
        }
        timeZoneToken = nil
    }

    // MARK: - Transitions

    private var isRecording: Bool { !isPaused && suspensions.isEmpty }

    private func handleActivation() {
        guard isRecording else { return }
        refreshFromSystem(at: clock.now)
        scheduleBurstFlush()
        flushIfBufferIsFull()
    }

    /// Suspension is a hard stop. While one is in force `isRecording` is false, so every activation
    /// notification returns immediately and **no interval can be opened** — which is acceptance
    /// criterion 4 for the fast-user-switching case, and the reason it holds for the others too.
    private func handleSuspend(_ reason: IdleMonitor.Suspension) {
        let now = clock.now
        suspensions.insert(reason)
        if reason == .systemSleep {
            isAwaitingDisplay = true
            heartbeat.suspend()
        }
        idleMonitor.suspend(reason)
        closeInterval(at: now)
        syncGapToState(at: now)
        updateState()
        // A boundary: after a lid closes or a screen locks there may be no second chance to write.
        flush(reason: .suspending)
    }

    /// The user is unmistakably back: they unlocked the screen, or the display came on, or their
    /// login session returned to the console. Every reason to believe they are away is dropped, and
    /// `adoptSuspensionsFromSystem` immediately re-adds whichever ones the window server still
    /// reports — so this is a re-ask, not an assumption.
    private func handleUserPresent(clearing reasons: Set<IdleMonitor.Suspension>) {
        let now = clock.now
        isAwaitingDisplay = false
        heartbeat.resume()
        for reason in reasons {
            suspensions.remove(reason)
            idleMonitor.resume(reason)
        }
        idleMonitor.noteResumed(at: now)
        resumeIfPermitted(at: now)
    }

    /// `didWake` alone is never permission to reopen an interval.
    ///
    /// Power Nap wakes the machine with the lid shut to check mail. Two things must not happen
    /// there, and both would: an interval opened at 03:00 records the small hours as work, and —
    /// less obvious, and the reason this returns rather than falling through — dropping
    /// `.systemSleep` would let the open gap be re-labelled `.displayOff`, splitting one night into
    /// two gaps for an event the user never witnessed. Acceptance criterion 2 asks for one sleep
    /// gap, so the record stays asleep until the display is genuinely back or the screen is
    /// unlocked.
    ///
    /// The heartbeat restarts either way, so a crash after a Power Nap is still dated from a recent
    /// beat rather than from before the lid closed.
    private func handleWake() {
        heartbeat.resume()
        guard !SystemSessionState.isDisplayAsleep else { return }
        handleUserPresent(clearing: [.systemSleep])
    }

    /// `screensDidWake` clears the sleep too: the display cannot come back on a sleeping machine, so
    /// this is the wake that `didWake` could not be trusted to be.
    private func handleDisplayWake() {
        handleUserPresent(clearing: [.displayOff, .systemSleep])
    }

    /// The one gate every resume path goes through. It asks the window server rather than trusting
    /// the notification that got us here, because the notifications arrive out of order — a lock
    /// while asleep, a wake while locked — and the dictionary is the ground truth.
    private func resumeIfPermitted(at now: Date) {
        adoptSuspensionsFromSystem()

        guard isRecording else {
            // Still away, but possibly for a different reason than the one the open gap names — a
            // machine that woke into a locked screen is no longer asleep. Re-labelling as the cause
            // changes is what keeps a night from reading as one indivisible mystery.
            syncGapToState(at: now)
            updateState()
            flush(reason: .transition)
            return
        }

        isAwaitingDisplay = false
        closeGap(at: now)
        refreshFromSystem(at: now)
        flush(reason: .transition)
    }

    /// Believes the window server over the notification that got us here.
    ///
    /// The notifications arrive out of order and sometimes not at all — a lock while asleep, a wake
    /// while locked, a session that resigned before the observer was installed. The session
    /// dictionary is ground truth and costs one call.
    private func adoptSuspensionsFromSystem() {
        let state = sessionState()
        if state.isScreenLocked {
            suspensions.insert(.screenLocked)
        }
        if !state.isOnConsole {
            suspensions.insert(.fastUserSwitched)
        }
        if isAwaitingDisplay && state.isDisplayAsleep {
            suspensions.insert(.displayOff)
        }
    }

    private func handleIdleChange(_ reading: IdleMonitor.Reading) {
        guard isRecording else { return }
        let now = clock.now
        guard var open = openInterval else { return }
        guard open.isIdle != reading.isIdle else {
            // Only the confidence moved; annotate in place rather than cutting the run in two.
            open.idleConfidence = reading.confidence
            openInterval = open
            return
        }
        // Backdated to when the input actually stopped, clamped by the monitor so it can never reach
        // back past a wake or an unlock and overlap a gap already recorded for the same minutes.
        let boundary = min(max(reading.since ?? now, open.start), now)
        refreshFromSystem(at: boundary, asOf: now, forcingNewInterval: true, idle: reading)
        flush(reason: .transition)
    }

    // MARK: - Interval bookkeeping

    /// Asks the system what is in front of the user and makes the record match.
    ///
    /// - Parameters:
    ///   - start: the instant the new interval begins, which is not always now — an idle stretch is
    ///     backdated to when input actually stopped, and a run that crosses midnight is cut at
    ///     midnight.
    ///   - now: the instant this is being decided, used to place `start` on the monotonic clock.
    ///     Defaults to `start`, which is the ordinary case.
    ///   - forcingNewInterval: cut the run even though the same application is still frontmost. True
    ///     only for the transitions that are boundaries in themselves: an idle change, a midnight, a
    ///     timezone change.
    ///   - idle: the idle reading to stamp on the new interval, when the caller has a fresher one
    ///     than the monitor's published value.
    private func refreshFromSystem(
        at start: Date,
        asOf now: Date? = nil,
        forcingNewInterval: Bool = false,
        idle: IdleMonitor.Reading? = nil
    ) {
        guard isRecording else { return }
        let observed = now ?? start

        guard let application = frontmostApplication() else {
            // Nothing frontmost, or a process with no bundle identifier: the login window, a modal
            // system panel, a helper. It cannot be keyed, named later or excluded by the user, so
            // recording it would put an unfalsifiable row on the timeline. The time still has to go
            // somewhere, and `.unexplained` is where honesty puts it.
            closeInterval(at: start, asOf: observed)
            openGap(.unexplained, at: start)
            updateState()
            return
        }

        if configuration.excludedApplications.contains(application.bundleIdentifier) {
            closeInterval(at: start, asOf: observed)
            openGap(.excludedApplication, at: start)
            updateState()
            return
        }

        let isPrivate = configuration.privateApplications.contains(application.bundleIdentifier)
        let recordedBundle = isPrivate ? Self.privateBundleIdentifier : application.bundleIdentifier
        let recordedName = isPrivate ? Self.privateDisplayName : application.displayName

        if !forcingNewInterval, let open = openInterval, open.bundleIdentifier == recordedBundle {
            // Same application still in front: the run continues. An activation notification for the
            // app that is already frontmost — which `activeSpaceDidChange` produces constantly — must
            // not chop a continuous run into fragments.
            return
        }

        closeGap(at: start)
        closeInterval(at: start, asOf: observed)

        let reading = idle ?? idleMonitor.reading
        openInterval = OpenInterval(
            id: UUID(),
            bundleIdentifier: recordedBundle,
            displayName: recordedName,
            start: start,
            startedAt: monotonicInstant(for: start, asOf: observed),
            tzOffsetMinutes: Self.tzOffsetMinutes(at: start),
            isIdle: reading.isIdle,
            idleConfidence: reading.confidence
        )
        updateState()
    }

    /// Closes the open interval and buffers it — unless the two clocks disagree about how long it
    /// lasted, in which case it is dropped and its span is marked `.unexplained`.
    ///
    /// Dropping is the point. An NTP correction, a DST transition or a user dragging the system
    /// clock forward all inflate a run measured by subtracting dates, and an inflated run is a
    /// confidently wrong block. `ActivityInterval` carries both measurements precisely so the
    /// disagreement can be detected here.
    ///
    /// `asOf` is what makes a backdated close honest rather than self-defeating: the monotonic clock
    /// has run on to *now*, so closing at a point in the past means subtracting the tail that has
    /// not been claimed. Without it every backdated close — every idle transition, every midnight —
    /// would look like a clock step to the very check that exists to catch clock steps, and the
    /// interval would be thrown away.
    private func closeInterval(at end: Date, asOf now: Date? = nil) {
        guard let open = openInterval else { return }
        openInterval = nil

        let observed = now ?? end
        let elapsed = Self.seconds(open.startedAt.duration(to: continuous.now))
        let unclaimedTail = max(0, observed.timeIntervalSince(end))
        let monotonic = max(0, elapsed - unclaimedTail)

        let interval = ActivityInterval(
            id: open.id,
            bundleIdentifier: open.bundleIdentifier,
            displayName: open.displayName,
            start: open.start,
            end: end,
            monotonicDuration: monotonic,
            isIdle: open.isIdle,
            idleConfidence: open.idleConfidence,
            tzOffsetMinutes: open.tzOffsetMinutes
        )

        guard interval.clocksAgree() else {
            pendingGaps.append(
                Gap(
                    reason: .unexplained,
                    start: min(open.start, end),
                    end: max(open.start, end)
                )
            )
            return
        }

        Self.upsert(interval, into: &pendingIntervals)
        updateState()
    }

    /// Opens a gap, or **re-labels** the one already open when the cause has changed.
    ///
    /// Re-labelling is load-bearing. Locking the screen at 17:59 and closing the lid at 18:00 must
    /// not report the night as fifteen hours of "screen locked": the reason a person would name for
    /// a span is the one in force during it, so the locked gap is closed at 18:00 and a sleep gap
    /// opens. Acceptance criterion 2 asks for one sleep gap over that night, and this is where it
    /// comes from.
    private func openGap(_ reason: GapReason, at start: Date) {
        if let existing = openGap {
            guard existing.reason != reason else { return }
            closeGap(at: start)
        }
        openGap = OpenGap(id: UUID(), reason: reason, start: start)
    }

    private func closeGap(at end: Date) {
        guard let gap = openGap else { return }
        openGap = nil
        guard Self.isWorthRecording(gap.reason, from: gap.start, to: end) else { return }
        Self.upsert(
            Gap(id: gap.id, reason: gap.reason, start: gap.start, end: end),
            into: &pendingGaps
        )
    }

    /// Makes the open gap agree with why capture is stopped.
    ///
    /// Called on every suspension and on every partial resume, so a night that goes lock → sleep →
    /// wake-into-lock → unlock produces three correctly named spans rather than one span named after
    /// whichever notification happened to arrive first.
    private func syncGapToState(at now: Date) {
        if isPaused {
            openGap(.trackingPaused, at: now)
            return
        }
        guard let top = Self.priorityOrder.first(where: { suspensions.contains($0) }) else {
            return
        }
        openGap(Self.gapReason(for: top), at: now)
    }

    private static func gapReason(for suspension: IdleMonitor.Suspension) -> GapReason {
        switch suspension {
        case .screenLocked: .screenLocked
        case .systemSleep: .systemSleep
        case .displayOff: .displayOff
        case .fastUserSwitched: .fastUserSwitched
        case .trackingPaused: .trackingPaused
        case .notStarted: .unexplained
        }
    }

    /// A gap the app observed a reason for is worth writing the instant it opens, however short —
    /// a `.systemSleep` gap published at zero length is what tells the *next* launch that the
    /// machine slept rather than crashed, and there will be no chance to write it later.
    ///
    /// `.unexplained` is the exception, and has to be: the frontmost application is momentarily nil
    /// while another one launches, and recording a fifth of a second of mystery each time would bury
    /// the real absences in noise.
    private static func isWorthRecording(_ reason: GapReason, from start: Date, to end: Date) -> Bool
    {
        guard end >= start else { return false }
        // Zero length is allowed for an observed reason, and is the whole trick: a `.systemSleep`
        // gap published the instant the lid closes is what tells the next launch that the machine
        // slept rather than crashed. It is extended by upsert on wake, under the same `id`.
        guard reason == .unexplained else { return true }
        return end.timeIntervalSince(start) >= minimumUnexplainedGap
    }

    private static let minimumUnexplainedGap: TimeInterval = 2

    /// Where a wall-clock instant sits on the monotonic clock, for an interval that begins in the
    /// past.
    private func monotonicInstant(for date: Date, asOf now: Date) -> ContinuousClock.Instant {
        let backdated = max(0, now.timeIntervalSince(date))
        return continuous.now.advanced(by: .seconds(-backdated))
    }

    private func updateState() {
        let next: ActivityTrackingState
        if isPaused {
            next = .paused
        } else if let suspension = Self.priorityOrder.first(where: { suspensions.contains($0) }) {
            next = .suspended(suspension)
        } else {
            next = .tracking
        }
        if next != state { state = next }
    }

    /// Which reason to show when several are in force at once. Sleep outranks a lock, which outranks
    /// a dark display, because the outer condition is the one a person would name.
    private static let priorityOrder: [IdleMonitor.Suspension] = [
        .systemSleep, .fastUserSwitched, .screenLocked, .displayOff, .trackingPaused, .notStarted,
    ]

    // MARK: - Flushing

    private enum FlushReason {
        case launch
        case burst
        /// The buffer grew past its threshold while a burst kept being rescheduled.
        case bufferFull
        case transition
        /// Capture is stopping: sleep, lock, another user taking the console, tracking paused.
        case suspending
        case terminating

        /// Only the boundaries after which there may be no second chance are worth a device sync.
        var durability: FileDurability {
            switch self {
            case .suspending, .terminating: .deviceSynced
            case .launch, .burst, .bufferFull, .transition: .buffered
            }
        }
    }

    /// What the heartbeat does now that it no longer drives the flush cadence.
    ///
    /// Two things, neither of which touches the day file. It renews the witness marks, so a quiet
    /// minute of work is not mistaken for a minute the process spent suspended. And it runs the
    /// unwitnessed-time guard, which is the one piece of bookkeeping that genuinely has to happen on
    /// a clock — it exists precisely to notice that the clock has jumped.
    ///
    /// A flush follows only if the guard fired, which is an event: the app has just discovered a
    /// span it cannot account for, and that discovery is worth writing down.
    private func observeHeartbeat() {
        let now = clock.now
        let discoveredAbsence = guardAgainstUnwitnessedTime(at: now)
        lastWitnessedInstant = continuous.now
        lastWitnessedAt = now
        if discoveredAbsence { flush(reason: .transition) }
    }

    /// The cap that keeps a rescheduled burst from deferring a write indefinitely.
    private func flushIfBufferIsFull() {
        guard pendingIntervals.count + pendingGaps.count >= Self.bufferFlushThreshold else { return }
        burstTask?.cancel()
        burstTask = nil
        flush(reason: .bufferFull)
    }

    /// Waits for an app-switch burst to settle before writing.
    ///
    /// Alt-tabbing through five applications is one thought, not five writes. The intervals are
    /// already in memory the instant each activation arrives; only the write is deferred.
    private func scheduleBurstFlush() {
        burstTask?.cancel()
        let quiet = configuration.burstQuietPeriod
        burstTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, quiet) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush(reason: .burst)
        }
    }

    private func flush(reason: FlushReason) {
        let now = clock.now
        _ = guardAgainstUnwitnessedTime(at: now)
        rotateAcrossMidnight(at: now)

        var intervals = pendingIntervals
        var gaps = pendingGaps

        // The still-open interval and the still-open gap are published on every flush with their end
        // moved forward. Every batch is an upsert keyed by `id`, so this costs one row rather than
        // one per flush — and it is what leaves a crashed process a day file whose last interval
        // ends at the last flush, which is the same instant as the last heartbeat.
        if let provisional = provisionalInterval(at: now) {
            Self.upsert(provisional, into: &intervals)
        }
        if let gap = openGap, Self.isWorthRecording(gap.reason, from: gap.start, to: now) {
            Self.upsert(
                Gap(id: gap.id, reason: gap.reason, start: gap.start, end: now),
                into: &gaps
            )
        }

        pendingIntervals.removeAll()
        pendingGaps.removeAll()
        lastWitnessedInstant = continuous.now
        lastWitnessedAt = now
        lastFlushedAt = now

        guard !intervals.isEmpty || !gaps.isEmpty else { return }

        let batches = Self.group(
            intervals: intervals,
            gaps: gaps,
            calendar: calendar,
            durability: reason.durability
        )
        guard !batches.isEmpty else { return }

        let handler = onFlush
        let previous = flushChain
        flushChain = Task { @MainActor in
            await previous?.value
            await handler(batches)
        }
    }

    /// Hands everything buffered over and waits for it. For a terminate handler, and for tests.
    public func flushNow() async {
        flush(reason: .transition)
        await flushChain?.value
    }

    private func provisionalInterval(at now: Date) -> ActivityInterval? {
        guard let open = openInterval, now > open.start else { return nil }
        let monotonic = Self.seconds(open.startedAt.duration(to: continuous.now))
        let interval = ActivityInterval(
            id: open.id,
            bundleIdentifier: open.bundleIdentifier,
            displayName: open.displayName,
            start: open.start,
            end: now,
            monotonicDuration: monotonic,
            isIdle: open.isIdle,
            idleConfidence: open.idleConfidence,
            tzOffsetMinutes: open.tzOffsetMinutes
        )
        return interval.clocksAgree() ? interval : nil
    }

    /// Closes the open interval at local midnight and opens its successor.
    ///
    /// One file per day, so an interval may not straddle two of them. Doing it here rather than at
    /// close time keeps every interval's `id` stable across flushes — a split at flush time would
    /// mint a new id for the second half on every single flush and the day file would fill with
    /// duplicates.
    private func rotateAcrossMidnight(at now: Date) {
        guard let open = openInterval else { return }
        let dayOfStart = calendar.startOfDay(for: open.start)
        let dayOfNow = calendar.startOfDay(for: now)
        guard dayOfNow > dayOfStart else { return }
        refreshFromSystem(
            at: dayOfNow,
            asOf: now,
            forcingNewInterval: true,
            idle: IdleMonitor.Reading(isIdle: open.isIdle, confidence: open.idleConfidence)
        )
    }

    /// Time the app did not witness must not become time it recorded.
    ///
    /// App Nap, a sleep that arrived without `willSleepNotification` — power loss, a panic, a
    /// suspended process — all look the same from in here: flushes stop, and then one arrives with an
    /// interval that appears to have been running the whole time. The honest reading is that the
    /// interval is good up to the last flush and unaccounted for after it.
    /// - Returns: whether a span the app could not vouch for was actually found.
    @discardableResult
    private func guardAgainstUnwitnessedTime(at now: Date) -> Bool {
        guard let last = lastWitnessedInstant, let open = openInterval else { return false }
        let sinceWitnessed = Self.seconds(last.duration(to: continuous.now))
        guard sinceWitnessed > Self.unwitnessedThreshold else { return false }

        let lastGood = max(open.start, min(now, lastWitnessedAt ?? open.start))
        closeInterval(at: lastGood, asOf: now)
        if Self.isWorthRecording(.unexplained, from: lastGood, to: now) {
            pendingGaps.append(Gap(reason: .unexplained, start: lastGood, end: now))
        }
        refreshFromSystem(at: now)
        return true
    }

    // MARK: - Helpers

    /// Groups a batch by the local day each record starts in. An interval never straddles midnight
    /// (`rotateAcrossMidnight`); a gap may, and is filed under the day it began, which is where a
    /// person looking for last night's sleep would go to find it.
    private static func group(
        intervals: [ActivityInterval],
        gaps: [Gap],
        calendar: Calendar,
        durability: FileDurability
    ) -> [ActivityFlush] {
        var intervalsByDay: [Date: [ActivityInterval]] = [:]
        for interval in intervals {
            intervalsByDay[calendar.startOfDay(for: interval.start), default: []].append(interval)
        }
        var gapsByDay: [Date: [Gap]] = [:]
        for gap in gaps {
            gapsByDay[calendar.startOfDay(for: gap.start), default: []].append(gap)
        }

        let days = Set(intervalsByDay.keys).union(gapsByDay.keys).sorted()
        return days.map { day in
            ActivityFlush(
                dayStart: day,
                intervals: (intervalsByDay[day] ?? []).sorted { $0.start < $1.start },
                gaps: (gapsByDay[day] ?? []).sorted { $0.start < $1.start },
                durability: durability
            )
        }
    }

    private static func upsert(_ interval: ActivityInterval, into buffer: inout [ActivityInterval]) {
        if let index = buffer.firstIndex(where: { $0.id == interval.id }) {
            buffer[index] = interval
        } else {
            buffer.append(interval)
        }
    }

    private static func upsert(_ gap: Gap, into buffer: inout [Gap]) {
        if let index = buffer.firstIndex(where: { $0.id == gap.id }) {
            buffer[index] = gap
        } else {
            buffer.append(gap)
        }
    }

    private static func tzOffsetMinutes(at date: Date) -> Int {
        TimeZone.autoupdatingCurrent.secondsFromGMT(for: date) / 60
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
