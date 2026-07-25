import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing, not decoration. `#expect` compares an
/// `Optional<Double>` against an integer-literal expression such as `40 * 60` by type as well as by
/// value, so that comparison reports a failure even when the numbers are identical. Routing every
/// duration through this helper keeps both sides of the comparison `Double`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// Session timing is the most bug-prone arithmetic in the app: it has to survive pauses, multiple
/// pause cycles, a machine that sleeps, a relaunch, and a clock that moves backwards. These tests
/// drive it entirely from injected dates, so hours of behaviour run in microseconds.
@Suite("Session clock")
struct SessionClockTests {

    /// 2024-01-15 09:00:00 UTC. Fixed so a failure reproduces identically on any machine.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func at(_ minutes: Double) -> Date {
        Self.nineAM.addingTimeInterval(minutes * 60)
    }

    private func session(
        planned: TimeInterval? = 50 * 60,
        workType: WorkType = .deepWork
    ) -> FocusSession {
        FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            workType: workType,
            plannedDuration: planned,
            startedAt: Self.nineAM
        )
    }

    // MARK: - Running

    @Test("A new session is running, at zero, with the full plan remaining")
    func newSessionStartsAtZero() {
        let session = session()

        #expect(session.state == .running)
        #expect(session.isRunning)
        #expect(!session.isPaused)
        #expect(!session.isFinished)
        #expect(session.elapsed(at: Self.nineAM) == 0)
        #expect(session.remaining(at: Self.nineAM) == minutes(50))
        #expect(session.effectiveDuration == nil)
    }

    @Test("Elapsed tracks wall clock while running")
    func elapsedTracksWallClock() {
        let session = session()

        #expect(session.elapsed(at: at(10)) == 600)
        #expect(session.remaining(at: at(10)) == minutes(40))
        #expect(session.progress(at: at(25)) == 0.5)
    }

    // MARK: - Pause and resume

    @Test("Elapsed is frozen for the whole time a session is paused")
    func pauseFreezesElapsed() {
        var session = session()
        session.pause(at: at(10))

        #expect(session.state == .paused)
        #expect(session.isPaused)
        // Five minutes of wall clock pass; the session clock does not move.
        #expect(session.elapsed(at: at(10)) == 600)
        #expect(session.elapsed(at: at(13)) == 600)
        #expect(session.elapsed(at: at(15)) == 600)
        #expect(session.remaining(at: at(15)) == minutes(40))
    }

    @Test("Resuming folds the pause into pausedDuration and the clock moves again")
    func resumeAccumulates() {
        var session = session()
        session.pause(at: at(10))
        session.resume(at: at(15))

        #expect(session.pausedDuration == 300)
        #expect(session.pauseStartedAt == nil)
        #expect(session.isRunning)
        #expect(session.elapsed(at: at(15)) == 600)
        // Ten more minutes of work on top of the ten before the pause.
        #expect(session.elapsed(at: at(25)) == 1200)
    }

    /// The worked example from the design document, checked end to end.
    ///
    /// 09:00 start, pause 09:10–09:15 (5 min), pause 09:40–09:50 (10 min), finish 10:00.
    /// Raw span 60 min − 15 min paused = 45 min active, 5 min left on a 50 min plan.
    @Test("Multiple pause cycles accumulate additively")
    func multiplePauseCycles() {
        var session = session()

        session.pause(at: at(10))
        session.resume(at: at(15))
        #expect(session.pausedDuration == 300)
        #expect(session.elapsed(at: at(40)) == minutes(35))

        session.pause(at: at(40))
        session.resume(at: at(50))
        #expect(session.pausedDuration == 900)

        session.finish(at: at(60), status: .madeProgress)

        #expect(session.effectiveDuration == minutes(45))
        #expect(session.remaining(at: at(60)) == minutes(5))
        #expect(session.totalPausedDuration(at: at(60)) == 900)
    }

    @Test("Finishing while paused closes the pause at the finish instant")
    func finishWhilePaused() {
        var session = session()
        session.pause(at: at(20))
        session.finish(at: at(30), status: .blocked)

        #expect(session.pauseStartedAt == nil)
        #expect(session.pausedDuration == 600)
        #expect(session.effectiveDuration == minutes(20))
        #expect(session.resultStatus == .blocked)
    }

    @Test("Toggling alternates pause and resume")
    func togglePause() {
        var session = session()

        session.togglePause(at: at(10))
        #expect(session.isPaused)

        session.togglePause(at: at(15))
        #expect(session.isRunning)
        #expect(session.pausedDuration == 300)
    }

    // MARK: - Idempotency

    @Test("Pausing twice keeps a single open interval")
    func doublePauseIsNoOp() {
        var session = session()
        session.pause(at: at(10))
        session.pause(at: at(12))

        #expect(session.pauseStartedAt == at(10))
        session.resume(at: at(20))
        #expect(session.pausedDuration == 600)
    }

    @Test("Resuming without a pause does nothing")
    func resumeWithoutPauseIsNoOp() {
        var session = session()
        session.resume(at: at(10))

        #expect(session.pausedDuration == 0)
        #expect(session.isRunning)
    }

    @Test("Finishing twice never moves endedAt")
    func doubleFinishIsNoOp() {
        var session = session()
        session.finish(at: at(30), status: .completed)
        session.finish(at: at(45), status: .blocked)

        #expect(session.endedAt == at(30))
        #expect(session.resultStatus == .completed)
        #expect(session.effectiveDuration == minutes(30))
    }

    @Test("A finished session cannot be paused")
    func pauseAfterFinishIsNoOp() {
        var session = session()
        session.finish(at: at(30))
        session.pause(at: at(35))

        #expect(session.pauseStartedAt == nil)
        #expect(session.effectiveDuration == minutes(30))
    }

    @Test("A finished session reports the same elapsed at any later instant")
    func finishedSessionIsStable() {
        var session = session()
        session.finish(at: at(30), status: .completed)

        #expect(session.elapsed(at: at(30)) == minutes(30))
        #expect(session.elapsed(at: at(120)) == minutes(30))
        #expect(session.elapsed(at: at(10_000)) == minutes(30))
    }

    // MARK: - Clock hostility

    @Test("A backwards clock shortens rather than inverts a duration")
    func backwardsClockDuringResume() {
        var session = session()
        session.pause(at: at(20))
        // The clock jumps back behind the moment the pause opened.
        session.resume(at: at(10))

        #expect(session.pausedDuration == 0)
        #expect(session.isRunning)
        #expect(session.elapsed(at: at(30)) >= 0)
    }

    @Test("Finishing before the start clamps to a zero-length session")
    func finishBeforeStart() {
        var session = session()
        session.finish(at: at(-30), status: .interrupted)

        #expect(session.endedAt == Self.nineAM)
        #expect(session.effectiveDuration == 0.0)
    }

    @Test("Reading elapsed at an instant before the start yields zero, never a negative")
    func elapsedBeforeStart() {
        let session = session()
        #expect(session.elapsed(at: at(-5)) == 0)
    }

    @Test("A pause left open on a finished session is closed at endedAt, not at now")
    func corruptOpenPauseOnFinishedSession() {
        // Simulates a record force-quit mid-pause and reloaded later.
        var session = session()
        session.pauseStartedAt = at(10)
        session.endedAt = at(30)

        // Twenty minutes of the thirty were paused, regardless of how much later this is read.
        #expect(session.elapsed(at: at(30)) == minutes(10))
        #expect(session.elapsed(at: at(5_000)) == minutes(10))
    }

    // MARK: - Machine sleep

    @Test("Sleeping mid-session grows elapsed, because the session clock is wall clock")
    func machineSleepCountsAsElapsed() {
        let session = session(planned: nil)
        // The machine slept for half an hour; nobody pressed pause.
        #expect(session.elapsed(at: at(30)) == minutes(30))
        // Focused time is aggregated from activity events instead, and that difference is exactly
        // what the completion sheet reports as idle.
    }

    // MARK: - Open-ended sessions

    @Test("Open-ended sessions count up with no target")
    func openEndedSession() {
        let session = session(planned: nil)

        #expect(session.isOpenEnded)
        #expect(session.remaining(at: at(90)) == nil)
        #expect(session.progress(at: at(90)) == nil)
        #expect(session.overrun(at: at(90)) == 0)
        #expect(session.elapsed(at: at(90)) == minutes(90))
    }

    @Test("A zero-length plan does not divide by zero")
    func zeroLengthPlan() {
        let session = session(planned: 0)
        #expect(session.progress(at: at(10)) == nil)
        #expect(session.remaining(at: at(10)) == 0.0)
    }

    // MARK: - Overrun

    @Test("Running past the plan reports overrun and clamps remaining at zero")
    func overrunAfterPlannedDuration() {
        let session = session(planned: 25 * 60)

        #expect(session.remaining(at: at(30)) == 0.0)
        #expect(session.overrun(at: at(30)) == minutes(5))
        #expect(session.progress(at: at(30)) == 1.0)
    }

    // MARK: - State machine

    @Test("A finished session awaits review until the result is answered")
    func awaitingReviewState() {
        var session = session()
        session.finish(at: at(30))

        #expect(session.state == .awaitingReview)

        session.resultStatus = .completed
        #expect(session.state == .completed)
    }

    // MARK: - Defaults and persistence

    @Test("isReactive is seeded from the work type but stays overridable")
    func reactiveDefaults() {
        #expect(FocusSession(intendedOutcome: "x", workType: .deepWork).isReactive == false)
        #expect(FocusSession(intendedOutcome: "x", workType: .incident).isReactive == true)
        #expect(
            FocusSession(intendedOutcome: "x", workType: .incident, isReactive: false)
                .isReactive == false
        )
    }

    @Test("Negative stored values are clamped at construction")
    func negativeValuesClamped() {
        let session = FocusSession(
            intendedOutcome: "x",
            pausedDuration: -500,
            interruptionCount: -3
        )
        #expect(session.pausedDuration == 0)
        #expect(session.interruptionCount == 0)
    }

    @Test("A session survives a Codable round trip unchanged")
    func codableRoundTrip() throws {
        var original = session()
        original.pause(at: at(10))
        original.resume(at: at(15))
        original.finish(at: at(50), status: .madeProgress)
        original.resultSummary = "Split the dedup pass out of the ingest job."

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(FocusSession.self, from: encoder.encode(original))

        #expect(decoded == original)
        #expect(decoded.effectiveDuration == minutes(45))
    }

    @Test("A session paused at quit resumes correctly after a relaunch")
    func restoredPausedSession() throws {
        var original = session()
        original.pause(at: at(10))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var restored = try decoder.decode(FocusSession.self, from: encoder.encode(original))

        #expect(restored.isPaused)
        // The app was closed for an hour. The pause absorbed all of it.
        #expect(restored.elapsed(at: at(70)) == 600)

        restored.resume(at: at(70))
        #expect(restored.pausedDuration == minutes(60))
        #expect(restored.elapsed(at: at(80)) == minutes(20))
    }
}

@Suite("Work type defaults")
struct WorkTypeTests {

    @Test("Deep work runs long, communication runs short")
    func suggestedDurations() {
        #expect(WorkType.deepWork.suggestedDuration == minutes(50))
        #expect(WorkType.codeReview.suggestedDuration == minutes(50))
        #expect(WorkType.communication.suggestedDuration == minutes(25))
        #expect(WorkType.administrative.suggestedDuration == minutes(25))
    }

    @Test("Every work type has display text and a symbol")
    func everyCaseIsPresentable() {
        for workType in WorkType.allCases {
            #expect(!workType.displayName.isEmpty)
            #expect(!workType.symbolName.isEmpty)
            #expect(workType.id == workType.rawValue)
        }
    }

    @Test("Raw values are stable, because sessions on disk depend on them")
    func rawValuesAreStable() {
        #expect(WorkType.deepWork.rawValue == "deepWork")
        #expect(WorkType.codeReview.rawValue == "codeReview")
        #expect(SessionResultStatus.madeProgress.rawValue == "madeProgress")
    }

    @Test("Every result status has display text and a symbol")
    func everyResultStatusIsPresentable() {
        for status in SessionResultStatus.allCases {
            #expect(!status.displayName.isEmpty)
            #expect(!status.symbolName.isEmpty)
        }
        #expect(SessionResultStatus.completed.countsAsCompleted)
        #expect(SessionResultStatus.interrupted.countsAsInterrupted)
        #expect(SessionResultStatus.blocked.needsFollowUp)
        #expect(!SessionResultStatus.completed.needsFollowUp)
    }
}
