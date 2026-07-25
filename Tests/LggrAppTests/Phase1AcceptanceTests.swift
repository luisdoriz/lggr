import AppKit
import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

/// The Phase 1 acceptance criteria from `docs/_design/INTELLIGENCE.md` §4, asserted against the
/// capture layer rather than read off it.
///
/// Criteria 1–4 are properties of `ActivityLaunchRecovery` and `ActivitySampler`, which live in the
/// executable target. The fixture days in `LggrKitTests` prove the *builder* half of each — that a
/// `.appNotRunning` gap of a hundred minutes renders as a hundred minutes nobody observed — but they
/// supply the gap by hand. These tests prove the other half: that the recovery actually produces
/// that gap, with that reason, at that instant.
///
/// Everything here is driven by a `FixedClock` and by notifications posted into the same centre the
/// sampler observes, so no test depends on the machine's real state.

// MARK: - Helpers

private let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)  // 2024-01-15 00:00 UTC

private func at(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
    dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
}

private func nextDay(_ hour: Int, _ minute: Int) -> Date {
    at(hour, minute).addingTimeInterval(24 * 3600)
}

private func minutes(_ count: Double) -> TimeInterval { count * 60 }

private func interval(
    _ bundle: String,
    _ name: String,
    from start: Date,
    seconds: TimeInterval
) -> ActivityInterval {
    ActivityInterval(
        bundleIdentifier: bundle,
        displayName: name,
        start: start,
        end: start.addingTimeInterval(seconds),
        monotonicDuration: seconds
    )
}

// MARK: - Criterion 1

@Suite("Phase 1 acceptance — criterion 1: a force quit is a gap, not a block")
struct Criterion1Tests {

    /// "Force-quit Lggr for 90 minutes; the timeline shows a `.appNotRunning` gap of exactly that
    /// span, not 90 minutes in the last app."
    @Test("Ninety minutes of absence becomes a .appNotRunning gap of exactly ninety minutes")
    func absenceBecomesAGapOfExactlyThatSpan() throws {
        let lastBeat = at(14, 30)
        let relaunch = at(16, 0)

        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: lastBeat,
            lastRecordedEnd: lastBeat,
            launchedAt: relaunch
        )

        let gap = try #require(outcome.gap)
        #expect(gap.reason == .appNotRunning)
        #expect(gap.start == lastBeat)
        #expect(gap.end == relaunch)
        #expect(gap.duration == minutes(90))
        #expect(outcome.closeOpenIntervalsAt == lastBeat)
    }

    /// The other half of the same sentence: the ninety minutes must not be credited to the
    /// application that happened to be frontmost when the process died.
    @Test("The ninety minutes are not credited to the last application")
    func theAbsenceIsNotCreditedToTheLastApplication() throws {
        let lastBeat = at(14, 30)
        let relaunch = at(16, 0)

        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: lastBeat,
            lastRecordedEnd: lastBeat,
            launchedAt: relaunch
        )
        let recovered = try #require(outcome.gap)

        let timeline = EpisodeBuilder.build(
            intervals: [
                interval("com.apple.dt.Xcode", "Xcode", from: at(13, 0), seconds: minutes(90)),
                interval("com.google.Chrome", "Chrome", from: relaunch, seconds: minutes(30)),
            ],
            absences: [recovered]
        )

        #expect(timeline.gaps(for: .appNotRunning).count == 1)
        #expect(timeline.gapDuration(for: .appNotRunning) == minutes(90))
        // Nothing was smeared into the silence.
        #expect(timeline.gaps(for: .unexplained).isEmpty)
        #expect(timeline.episodes.contains { $0.end == lastBeat })
        #expect(timeline.episodes.allSatisfy { $0.wallClockSpan <= minutes(90) })
        // 90 minutes of Xcode plus 30 of Chrome. Not 210.
        #expect(timeline.episodes.reduce(0) { $0 + $1.activeDuration } == minutes(120))
    }

    /// The mechanism has to be capable of *not* firing, or it proves nothing. An ordinary
    /// quit-and-relaunch inside the absence threshold leaves no gap at all.
    @Test("An ordinary relaunch inside the absence threshold produces no gap")
    func shortRelaunchProducesNoGap() {
        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: at(14, 30),
            lastRecordedEnd: at(14, 30),
            launchedAt: at(14, 30, second: 45)
        )
        #expect(outcome == .nothingToDo)
    }
}

// MARK: - Criterion 2

@Suite("Phase 1 acceptance — criterion 2: a night is one sleep gap")
struct Criterion2Tests {

    /// "Close the lid at 18:00, open at 09:00; one sleep gap. Not a fifteen-hour Xcode block. Not a
    /// `.appNotRunning` gap mislabelling a night the app slept normally."
    @Test("A lid closed at 18:00 and opened at 09:00 recovers as one sleep gap, not a crash")
    func overnightSleepIsOneSleepGap() throws {
        let lidClosed = at(18, 0)
        let lidOpened = nextDay(9, 0)

        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: lidClosed,
            lastRecordedEnd: lidClosed,
            unresolvedSleepSince: lidClosed,
            launchedAt: lidOpened
        )

        let gap = try #require(outcome.gap)
        #expect(gap.reason == .systemSleep)
        #expect(gap.reason != .appNotRunning)
        #expect(gap.start == lidClosed)
        #expect(gap.end == lidOpened)
        #expect(gap.duration == minutes(900))
    }

    /// The precedence is only meaningful if the same launch, without the recorded sleep, reports a
    /// crash. Otherwise the sleep branch is unfalsifiable.
    @Test("The same absence with no recorded sleep is a crash, so the precedence is doing work")
    func withoutARecordedSleepTheSameAbsenceIsACrash() throws {
        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: at(18, 0),
            lastRecordedEnd: at(18, 0),
            unresolvedSleepSince: nil,
            launchedAt: nextDay(9, 0)
        )
        let gap = try #require(outcome.gap)
        #expect(gap.reason == .appNotRunning)
    }

    /// Through the builder: fifteen hours of silence is a night, not a block, and the crash marker
    /// does not also appear over it.
    @Test("The night renders as one sleep gap and no fifteen-hour block")
    func theNightRendersAsOneSleepGap() throws {
        let lidClosed = at(18, 0)
        let lidOpened = nextDay(9, 0)

        let recovered = try #require(
            ActivityLaunchRecovery.plan(
                lastHeartbeat: lidClosed,
                lastRecordedEnd: lidClosed,
                unresolvedSleepSince: lidClosed,
                launchedAt: lidOpened
            ).gap
        )

        let timeline = EpisodeBuilder.build(
            intervals: [
                interval("com.apple.dt.Xcode", "Xcode", from: at(16, 30), seconds: minutes(90)),
                interval("com.apple.dt.Xcode", "Xcode", from: lidOpened, seconds: minutes(60)),
            ],
            absences: [recovered]
        )

        #expect(timeline.gaps(for: .systemSleep).count == 1)
        #expect(timeline.gapDuration(for: .systemSleep) == minutes(900))
        #expect(timeline.gaps(for: .appNotRunning).isEmpty)
        #expect(timeline.gaps(for: .unexplained).isEmpty)
        #expect(timeline.episodes.count == 2)
        #expect(timeline.episodes.allSatisfy { $0.wallClockSpan <= minutes(90) })
    }

    /// The geometry that actually happens every night: the last heartbeat lands before `willSleep`
    /// and the first one after waking lands after `didWake`, so a heartbeat gap *contains* the sleep.
    /// A containment test in the wrong direction reports the night as fifteen hours of "Lggr was not
    /// running"; the subtraction in `resolvedAbsences` is what stops it.
    @Test("A heartbeat gap wrapped around the sleep still leaves the sleep as the long gap")
    func aHeartbeatGapAroundTheSleepDoesNotBecomeTheNight() {
        let timeline = EpisodeBuilder.build(
            intervals: [
                interval("com.apple.dt.Xcode", "Xcode", from: at(16, 30), seconds: minutes(89)),
                interval("com.apple.dt.Xcode", "Xcode", from: nextDay(9, 1), seconds: minutes(60)),
            ],
            absences: [
                Gap(reason: .appNotRunning, start: at(17, 59), end: nextDay(9, 1)),
                Gap(reason: .systemSleep, start: at(18, 0), end: nextDay(9, 0)),
            ]
        )

        #expect(timeline.gaps(for: .systemSleep).count == 1)
        #expect(timeline.gapDuration(for: .systemSleep) == minutes(900))
        // Whatever is left of the heartbeat gap is a minute either side, never the night.
        #expect(timeline.gaps(for: .appNotRunning).allSatisfy { $0.duration <= minutes(1) })
        #expect(timeline.episodes.allSatisfy { $0.wallClockSpan <= minutes(90) })
    }
}

// MARK: - Criterion 3

@Suite("Phase 1 acceptance — criterion 3: an open interval closes at the last heartbeat")
struct Criterion3Tests {

    /// "Pull the power cord mid-session; on relaunch the open interval is closed at last heartbeat."
    @Test("The open interval is closed at the last heartbeat, not at relaunch")
    func openIntervalClosesAtTheLastHeartbeat() throws {
        let lastBeat = at(14, 30)
        let relaunch = at(16, 10)

        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: lastBeat,
            lastRecordedEnd: lastBeat,
            launchedAt: relaunch
        )

        #expect(outcome.closeOpenIntervalsAt == lastBeat)
        #expect(outcome.closeOpenIntervalsAt != relaunch)
        let gap = try #require(outcome.gap)
        #expect(gap.start == lastBeat)
        #expect(gap.duration == minutes(100))
    }

    /// A power loss leaves the last flush *after* the last beat as often as not. Under-claiming is
    /// the acceptable failure direction, so the beat still wins.
    @Test("A flush that landed after the last beat does not move the close forward")
    func aLaterFlushDoesNotMoveTheClose() {
        let outcome = ActivityLaunchRecovery.plan(
            lastHeartbeat: at(14, 30),
            lastRecordedEnd: at(14, 30, second: 47),
            launchedAt: at(16, 10)
        )
        #expect(outcome.closeOpenIntervalsAt == at(14, 30))
    }

    /// And the gap it produces is measured from the beat, so the timeline closes the block there.
    @Test("The block before the crash ends at the heartbeat")
    func theBlockEndsAtTheHeartbeat() throws {
        let lastBeat = at(14, 30)
        let relaunch = at(16, 10)
        let recovered = try #require(
            ActivityLaunchRecovery.plan(
                lastHeartbeat: lastBeat,
                lastRecordedEnd: lastBeat,
                launchedAt: relaunch
            ).gap
        )

        let timeline = EpisodeBuilder.build(
            intervals: [
                interval("com.apple.dt.Xcode", "Xcode", from: at(12, 50), seconds: minutes(100)),
                interval("com.apple.dt.Xcode", "Xcode", from: relaunch, seconds: minutes(70)),
            ],
            absences: [recovered]
        )

        #expect(timeline.episodes.contains { $0.end == lastBeat })
        #expect(timeline.gapDuration(for: .appNotRunning) == minutes(100))
    }
}

// MARK: - Criterion 4

/// Every sampler here gets its **own** `NotificationCenter`, and that is what provides the isolation.
///
/// It used to rely on `.serialized` instead, on the reasoning that two samplers observing the
/// process-global `NSWorkspace.shared.notificationCenter` would receive each other's notifications.
/// The reasoning was right and the mechanism was wrong: `.serialized` orders tests *within* a suite
/// and does nothing about sibling suites running in parallel. The result was a suite that failed
/// roughly two runs in three — a sampler in another suite suspending itself on a notification posted
/// here. An injected centre removes the shared dependency rather than trying to schedule around it.
/// `.serialized` is kept because these tests drive main-queue delivery, not for isolation.
@Suite("Phase 1 acceptance — criterion 4: nothing is recorded for another user's hour", .serialized)
@MainActor
struct Criterion4Tests {

    /// Lets the notification centre's main-queue delivery actually happen.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// "Fast-user-switch away for an hour; zero intervals recorded for that hour."
    @Test("An hour switched away records zero intervals")
    func switchedAwayRecordsNothing() async throws {
        let clock = FixedClock(at(10, 0))
        let heartbeatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lggr-test-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: heartbeatURL) }

        let recorded = Recorder()
        let center = NotificationCenter()
        let sampler = ActivitySampler(
            clock: clock,
            heartbeat: ActivityHeartbeat(fileURL: heartbeatURL, clock: clock),
            // A monitor that never reports idle, so nothing else can cut an interval.
            idleMonitor: IdleMonitor(
                threshold: 0,
                clock: clock,
                secondsSinceLastInput: { 0 },
                corroboratesAbsence: { false }
            ),
            workspaceCenter: center,
            distributedCenter: NotificationCenter(),
            // A normal machine: user present, screen on. Without this the suite reads the
            // developer's real console state and fails whenever their screen is locked.
            sessionState: { .active },
            onFlush: { batches in recorded.append(batches) }
        )

        sampler.start()
        await settle()

        // The other user takes the console.
        center.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        await settle()
        #expect(sampler.state == .suspended(.fastUserSwitched))

        let switchedAwayAt = clock.now
        recorded.reset()

        // An hour passes. The other user works: `NSWorkspace` keeps reporting a frontmost
        // application and every activation notification arrives exactly as it would in a foreground
        // session.
        for step in 1...12 {
            clock.advance(by: minutes(5))
            center.post(
                name: NSWorkspace.didActivateApplicationNotification,
                object: nil
            )
            if step % 4 == 0 {
                center.post(
                    name: NSWorkspace.activeSpaceDidChangeNotification,
                    object: nil
                )
            }
            await settle()
        }
        let cameBackAt = clock.now

        await sampler.flushNow()
        await settle()

        let intervals = recorded.intervals
        let touching = intervals.filter { $0.end > switchedAwayAt && $0.start < cameBackAt }
        #expect(
            touching.isEmpty,
            Comment(
                rawValue:
                    "expected zero intervals across the switched-away hour, got "
                    + touching.map { "\($0.bundleIdentifier) \($0.start)–\($0.end)" }.joined(
                        separator: ", ")
            )
        )
        // The hour is not silently missing either: it is a typed absence, and it is the *only*
        // thing covering that span — not an `.unexplained` gap standing in for a dropped interval.
        let switched = recorded.gaps.filter { $0.reason == .fastUserSwitched }
        #expect(!switched.isEmpty)
        #expect(switched.contains { $0.start <= switchedAwayAt && $0.end >= cameBackAt })
        let otherCover = recorded.gaps.filter {
            $0.reason != .fastUserSwitched && $0.end > switchedAwayAt && $0.start < cameBackAt
        }
        #expect(otherCover.isEmpty)

        await sampler.stop()
    }

    /// The control for the test above.
    ///
    /// It has to record on the same rig, or "zero intervals" proves only that the harness is inert.
    /// The clock advances by one second rather than by an hour: every duration the sampler records
    /// is monotonic, and a fixed clock that jumps an hour while `ContinuousClock` does not is a
    /// clock step by the sampler's own definition — it would drop the interval for exactly the
    /// reason `clocksAgree()` exists, and the control would fail for a reason that has nothing to do
    /// with fast user switching.
    @Test("The same rig, unswitched, does record an interval")
    func theRigCanRecord() async throws {
        let clock = FixedClock(at(10, 0))
        let heartbeatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lggr-test-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: heartbeatURL) }

        let recorded = Recorder()
        let center = NotificationCenter()
        let sampler = ActivitySampler(
            clock: clock,
            heartbeat: ActivityHeartbeat(fileURL: heartbeatURL, clock: clock),
            idleMonitor: IdleMonitor(
                threshold: 0,
                clock: clock,
                secondsSinceLastInput: { 0 },
                corroboratesAbsence: { false }
            ),
            workspaceCenter: center,
            distributedCenter: NotificationCenter(),
            // A normal machine: user present, screen on. Without this the suite reads the
            // developer's real console state and fails whenever their screen is locked.
            sessionState: { .active },
            onFlush: { batches in recorded.append(batches) }
        )

        sampler.start()
        await settle()
        // Only meaningful when the test host is itself on the console, which it is under
        // `swift test`; if it were not, the criterion-4 test would be vacuous.
        try #require(sampler.state == .tracking)

        let began = clock.now
        recorded.reset()
        clock.advance(by: 1)
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        await settle()
        await sampler.flushNow()
        await settle()

        let covering = recorded.intervals.filter { $0.end > began }
        #expect(!covering.isEmpty)
        #expect(recorded.gaps.allSatisfy { $0.reason != .fastUserSwitched })

        await sampler.stop()
    }

    /// And the switch, on the same one-second geometry, records nothing where the control recorded
    /// something. This is the pair that makes criterion 4 an experiment rather than an assertion.
    @Test("The same second, switched away, records no interval at all")
    func theSameSecondSwitchedAwayRecordsNothing() async throws {
        let clock = FixedClock(at(10, 0))
        let heartbeatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lggr-test-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: heartbeatURL) }

        let recorded = Recorder()
        let center = NotificationCenter()
        let sampler = ActivitySampler(
            clock: clock,
            heartbeat: ActivityHeartbeat(fileURL: heartbeatURL, clock: clock),
            idleMonitor: IdleMonitor(
                threshold: 0,
                clock: clock,
                secondsSinceLastInput: { 0 },
                corroboratesAbsence: { false }
            ),
            workspaceCenter: center,
            distributedCenter: NotificationCenter(),
            // A normal machine: user present, screen on. Without this the suite reads the
            // developer's real console state and fails whenever their screen is locked.
            sessionState: { .active },
            onFlush: { batches in recorded.append(batches) }
        )

        sampler.start()
        await settle()
        try #require(sampler.state == .tracking)

        center.post(
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        await settle()
        try #require(sampler.state == .suspended(.fastUserSwitched))

        let began = clock.now
        recorded.reset()
        clock.advance(by: 1)
        center.post(
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        await settle()
        await sampler.flushNow()
        await settle()

        #expect(recorded.intervals.filter { $0.end > began }.isEmpty)

        await sampler.stop()
    }
}

/// Collects what the sampler hands over.
@MainActor
private final class Recorder {
    private(set) var intervals: [ActivityInterval] = []
    private(set) var gaps: [Gap] = []

    func append(_ batches: [ActivityFlush]) {
        for batch in batches {
            for interval in batch.intervals {
                if let index = intervals.firstIndex(where: { $0.id == interval.id }) {
                    intervals[index] = interval
                } else {
                    intervals.append(interval)
                }
            }
            for gap in batch.gaps {
                if let index = gaps.firstIndex(where: { $0.id == gap.id }) {
                    gaps[index] = gap
                } else {
                    gaps.append(gap)
                }
            }
        }
    }

    func reset() {
        intervals.removeAll()
        gaps.removeAll()
    }
}

// MARK: - The quiet failure modes

/// Checks that are not numbered criteria but are the ways Phase 1 goes wrong without anybody
/// noticing. Serialized for the same reason `Criterion4Tests` is: one shared notification centre.
@Suite("Phase 1 — the quiet failure modes", .serialized)
@MainActor
struct Phase1QuietFailureTests {

    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Redaction must happen at capture, not at display. An interval that leaves the sampler still
    /// carrying a private application's real bundle identifier has already lost: it reaches the day
    /// file, and every reader downstream is then trusted to remember to hide it.
    @Test("A private application is redacted before the interval leaves the sampler")
    func privateApplicationsAreRedactedAtCapture() async throws {
        let frontmost = try #require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        let clock = FixedClock(at(10, 0))
        let heartbeatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lggr-test-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: heartbeatURL) }

        let recorded = Recorder()
        let center = NotificationCenter()
        let sampler = ActivitySampler(
            configuration: ActivitySampler.Configuration(privateApplications: [frontmost]),
            clock: clock,
            heartbeat: ActivityHeartbeat(fileURL: heartbeatURL, clock: clock),
            idleMonitor: IdleMonitor(
                threshold: 0,
                clock: clock,
                secondsSinceLastInput: { 0 },
                corroboratesAbsence: { false }
            ),
            workspaceCenter: center,
            distributedCenter: NotificationCenter(),
            // A normal machine: user present, screen on. Without this the suite reads the
            // developer's real console state and fails whenever their screen is locked.
            sessionState: { .active },
            onFlush: { batches in recorded.append(batches) }
        )

        sampler.start()
        await settle()
        try #require(sampler.state == .tracking)

        clock.advance(by: 1)
        await sampler.flushNow()
        await settle()

        #expect(!recorded.intervals.isEmpty)
        // Not one record, anywhere in the batch, names the real application.
        #expect(recorded.intervals.allSatisfy { $0.bundleIdentifier != frontmost })
        #expect(
            recorded.intervals.allSatisfy {
                $0.bundleIdentifier == ActivitySampler.privateBundleIdentifier
                    && $0.displayName == ActivitySampler.privateDisplayName
            })
        // The time is still there: the day still adds up, it just does not say what it was.
        #expect(recorded.intervals.contains { $0.wallClockDuration > 0 })

        await sampler.stop()
    }

    /// The same rig with the application merely *excluded* records no identity either, and does not
    /// silently drop the span: it becomes a typed absence.
    @Test("An excluded application becomes a typed gap, not a silent hole")
    func excludedApplicationsBecomeGaps() async throws {
        let frontmost = try #require(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        let clock = FixedClock(at(10, 0))
        let heartbeatURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lggr-test-\(UUID().uuidString)", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: heartbeatURL) }

        let recorded = Recorder()
        let center = NotificationCenter()
        let sampler = ActivitySampler(
            configuration: ActivitySampler.Configuration(excludedApplications: [frontmost]),
            clock: clock,
            heartbeat: ActivityHeartbeat(fileURL: heartbeatURL, clock: clock),
            idleMonitor: IdleMonitor(
                threshold: 0,
                clock: clock,
                secondsSinceLastInput: { 0 },
                corroboratesAbsence: { false }
            ),
            workspaceCenter: center,
            distributedCenter: NotificationCenter(),
            // A normal machine: user present, screen on. Without this the suite reads the
            // developer's real console state and fails whenever their screen is locked.
            sessionState: { .active },
            onFlush: { batches in recorded.append(batches) }
        )

        sampler.start()
        await settle()
        clock.advance(by: 60)
        await sampler.flushNow()
        await settle()

        #expect(recorded.intervals.allSatisfy { $0.bundleIdentifier != frontmost })
        #expect(recorded.gaps.contains { $0.reason == .excludedApplication })

        await sampler.stop()
    }

    /// `ActivityInterval` is the type every capture path funnels through, and it has no field a
    /// window title could be put in. Asserted over the encoded form rather than over the source, so
    /// adding one would fail here rather than being caught by review.
    @Test("The captured interval type has no field a window title could occupy")
    func theIntervalTypeHasNoTitleField() throws {
        let encoded = try JSONEncoder().encode(
            ActivityInterval(
                bundleIdentifier: "com.apple.dt.Xcode",
                displayName: "Xcode",
                start: at(10, 0),
                end: at(10, 30),
                monotonicDuration: 1800
            )
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "id", "bundleIdentifier", "displayName", "start", "end", "monotonicDuration",
                "isIdle", "idleConfidence", "tzOffsetMinutes",
            ])
        #expect(object.keys.allSatisfy { !$0.lowercased().contains("title") })
    }
}
