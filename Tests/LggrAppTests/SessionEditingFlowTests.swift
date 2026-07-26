import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

// The four things a user can now do to a session that is already recorded — discard it, delete it,
// correct its times, and move its target — asserted through `SessionManager`, which is the only object
// in the app that talks to the store.
//
// `FocusSession.reschedule(start:end:at:)` is covered exhaustively by `SessionEditingTests`; nothing
// here re-tests the arithmetic. What is tested here is the half the domain cannot see: that the
// interface is updated before the disk, that a discarded session leaves *nothing* behind, that a
// refusal is visible rather than silent, and that adjusting a target does not label a session as
// hand-edited.

// MARK: - Fixtures

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing, not decoration — see the note on the twin of this
/// helper in `SessionClockTests`. `#expect` compares an `Optional<Double>` against an integer-literal
/// expression such as `40 * 60` by type as well as by value, so that comparison fails even when the
/// numbers are identical.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 09:00:00 UTC. The same instant `SessionClockTests` and `SessionEditingTests` use, so a
/// failure in any of the three reads against the same wall clock.
private let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

private func at(_ offset: Double) -> Date { nineAM.addingTimeInterval(minutes(offset)) }

private let outcome = "Finish the receipt deduplication PR"

/// A scratch preferences suite, so a test can never overwrite the real user's remembered project.
private var scratchDefaults: UserDefaults {
    UserDefaults(suiteName: "com.lggr.tests.sessionediting") ?? .standard
}

@MainActor
private func makeManager(
    store: InMemoryStore,
    clock: FixedClock
) -> SessionManager {
    SessionManager(store: store, clock: clock, defaults: scratchDefaults)
}

/// Starts a session, runs it for `ran` minutes and finishes it, leaving it awaiting review.
///
/// Driven through the manager rather than assembled as a value: the point of these tests is the path
/// the app actually takes, including the `pauseCounts` bookkeeping and the writes along the way.
@MainActor
private func runSession(
    _ manager: SessionManager,
    clock: FixedClock,
    planned: TimeInterval? = minutes(50),
    ran: Double = 45,
    pausedFrom: Double? = nil,
    pausedUntil: Double? = nil
) async {
    await manager.startSession(
        projectID: nil,
        intendedOutcome: outcome,
        workType: .deepWork,
        plannedDuration: planned
    )

    if let pausedFrom, let pausedUntil {
        clock.advance(by: minutes(pausedFrom))
        manager.togglePause()
        clock.advance(by: minutes(pausedUntil - pausedFrom))
        manager.togglePause()
        clock.advance(by: minutes(ran - pausedUntil))
    } else {
        clock.advance(by: minutes(ran))
    }

    await manager.finishSession()
}

// MARK: - Discarding

@Suite("Discarding the active session")
@MainActor
struct DiscardActiveSessionTests {

    @Test("A discarded session leaves nothing on screen and nothing on disk")
    func discardLeavesNothingBehind() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await manager.startSession(
            projectID: nil,
            intendedOutcome: outcome,
            workType: .deepWork,
            plannedDuration: minutes(50)
        )
        #expect(store.sessions.count == 1)
        clock.advance(by: minutes(3))

        let discarded = await manager.discardActiveSession()

        #expect(discarded)
        #expect(manager.activeSession == nil)
        // The whole point: no review is offered for work the user has just said did not happen.
        #expect(manager.pendingReview == nil)
        #expect(manager.todaySessions.isEmpty)
        #expect(store.sessions.isEmpty)
        #expect(manager.lastError == nil)
    }

    @Test("Discarding with nothing running reports that it did nothing, and does nothing")
    func discardWithoutSession() async {
        let store = InMemoryStore()
        let manager = makeManager(store: store, clock: FixedClock(nineAM))

        let discarded = await manager.discardActiveSession()

        #expect(!discarded)
        #expect(manager.activeSession == nil)
        #expect(store.sessions.isEmpty)
        #expect(manager.lastError == nil)
    }

    @Test("Discarding one session does not take away another session's unanswered review")
    func discardKeepsSomebodyElsesReview() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await runSession(manager, clock: clock, ran: 45)
        let reviewable = try #require(manager.pendingReview?.id)

        await manager.startSession(
            projectID: nil,
            intendedOutcome: "Reply to the incident thread",
            workType: .communication,
            plannedDuration: minutes(25)
        )
        let mistake = try #require(manager.activeSession?.id)

        _ = await manager.discardActiveSession()

        #expect(manager.pendingReview?.id == reviewable)
        #expect(store.sessions.contains { $0.id == reviewable })
        #expect(!store.sessions.contains { $0.id == mistake })
    }
}

// MARK: - Deleting

@Suite("Deleting a session")
@MainActor
struct DeleteSessionTests {

    @Test("A deleted session leaves both today's list and the store")
    func deleteRemovesTheRecord() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await runSession(manager, clock: clock, ran: 45)
        let id = try #require(manager.pendingReview?.id)
        await manager.submitReview(status: .completed, summary: "", blocker: nil, nextStep: nil)
        #expect(manager.todaySessions.count == 1)

        await manager.deleteSession(id: id)

        #expect(manager.todaySessions.isEmpty)
        #expect(store.sessions.isEmpty)
        #expect(manager.lastError == nil)
    }

    @Test("Deleting the session in flight clears it and stops the clock")
    func deleteStopsARunningSession() async throws {
        let store = InMemoryStore()
        let manager = makeManager(store: store, clock: FixedClock(nineAM))

        await manager.startSession(
            projectID: nil,
            intendedOutcome: outcome,
            workType: .deepWork,
            plannedDuration: minutes(50)
        )
        let id = try #require(manager.activeSession?.id)

        await manager.deleteSession(id: id)

        #expect(manager.activeSession == nil)
        #expect(manager.pendingReview == nil)
        #expect(store.sessions.isEmpty)
    }

    @Test("Deleting the same session twice is not a failure")
    func deleteIsIdempotent() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await runSession(manager, clock: clock, ran: 45)
        let id = try #require(manager.pendingReview?.id)

        await manager.deleteSession(id: id)
        await manager.deleteSession(id: id)

        #expect(store.sessions.isEmpty)
        // D1: a delete of something already gone achieved exactly what the caller asked for.
        #expect(manager.lastError == nil)
    }
}

// MARK: - Correcting the times

@Suite("Correcting a session's recorded times")
@MainActor
struct RescheduleSessionTests {

    @Test("A correction is written, stamped, and reported back")
    func correctionIsWrittenAndStamped() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await runSession(manager, clock: clock, ran: 45)
        let recorded = try #require(manager.pendingReview)
        #expect(recorded.editedAt == nil)

        // The user corrects it a minute later; the stamp is that instant, not the session's.
        clock.advance(by: minutes(1))
        let stamp = clock.now

        let result = try #require(
            await manager.reschedule(session: recorded, start: nineAM, end: at(20))
        )

        #expect(result.corrected.startedAt == nineAM)
        #expect(result.corrected.endedAt == at(20))
        #expect(result.corrected.effectiveDuration == minutes(20))
        #expect(result.corrected.editedAt == stamp)
        #expect(result.corrected.wasEdited)
        #expect(store.sessions.first?.endedAt == at(20))
        #expect(store.sessions.first?.editedAt == stamp)
        #expect(manager.pendingReview?.endedAt == at(20))
        #expect(manager.lastError == nil)
    }

    @Test("Shrinking a session below its recorded pauses reduces them, and says so")
    func correctionReportsWhatItHadToGiveUp() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        // 09:00–09:45 with five minutes paused: forty minutes of active time.
        await runSession(manager, clock: clock, ran: 45, pausedFrom: 10, pausedUntil: 15)
        let recorded = try #require(manager.pendingReview)
        #expect(recorded.effectiveDuration == minutes(40))

        let result = try #require(
            await manager.reschedule(session: recorded, start: nineAM, end: at(3))
        )

        #expect(result.report.reducesPausedDuration)
        #expect(result.report.previousPausedDuration == minutes(5))
        #expect(result.report.pausedDuration == minutes(3))
        #expect(result.report.pausedDurationReduction == minutes(2))
        // No elapsed time appears out of nowhere: the span is three minutes and all of it was paused.
        #expect(result.corrected.pausedDuration == minutes(3))
        #expect(result.corrected.effectiveDuration == minutes(0))
    }

    @Test("A correction that pulls the end before the start clamps, and never inverts the session")
    func invertedRangeIsClampedAndReported() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await runSession(manager, clock: clock, ran: 45)
        let recorded = try #require(manager.pendingReview)

        let result = try #require(
            await manager.reschedule(session: recorded, start: at(30), end: at(10))
        )

        #expect(result.report.endClampedToStart)
        #expect(result.corrected.startedAt == at(30))
        #expect(result.corrected.endedAt == at(30))
        #expect(result.corrected.effectiveDuration == minutes(0))
        let endedAt = try #require(result.corrected.endedAt)
        #expect(endedAt >= result.corrected.startedAt)
    }

    @Test("A running session is refused rather than given an invented end")
    func runningSessionIsRefused() async throws {
        let store = InMemoryStore()
        let manager = makeManager(store: store, clock: FixedClock(nineAM))

        await manager.startSession(
            projectID: nil,
            intendedOutcome: outcome,
            workType: .deepWork,
            plannedDuration: minutes(50)
        )
        let active = try #require(manager.activeSession)

        if let accepted = await manager.reschedule(session: active, start: nineAM, end: at(20)) {
            Issue.record("A running session was rescheduled to end at \(accepted.corrected.endedAt as Any).")
        }

        #expect(manager.activeSession?.endedAt == nil)
        #expect(manager.activeSession?.editedAt == nil)
        // Refused visibly. A silent no-op would leave the user believing the correction landed.
        #expect(manager.lastError != nil)
    }

    @Test("A session corrected onto another day leaves today's list")
    func correctionCanMoveASessionOutOfToday() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = makeManager(store: store, clock: clock)

        await runSession(manager, clock: clock, ran: 45)
        let recorded = try #require(manager.pendingReview)
        await manager.submitReview(
            status: .completed,
            summary: "",
            blocker: nil,
            nextStep: nil
        )
        #expect(manager.todaySessions.count == 1)

        let threeDaysBack = nineAM.addingTimeInterval(-3 * 24 * 60 * 60)
        _ = await manager.reschedule(
            session: recorded,
            start: threeDaysBack,
            end: threeDaysBack.addingTimeInterval(minutes(40))
        )

        #expect(manager.todaySessions.isEmpty)
        #expect(store.sessions.first?.startedAt == threeDaysBack)
    }
}

// MARK: - Adjusting the target

@Suite("Adjusting the running session's target")
@MainActor
struct AdjustPlannedDurationTests {

    private func started(
        planned: TimeInterval?,
        clock: FixedClock,
        store: InMemoryStore
    ) async -> SessionManager {
        let manager = makeManager(store: store, clock: clock)
        await manager.startSession(
            projectID: nil,
            intendedOutcome: outcome,
            workType: .deepWork,
            plannedDuration: planned
        )
        return manager
    }

    @Test("Ten minutes on and ten minutes off move the target and nothing else")
    func stepsMoveOnlyTheTarget() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = await started(planned: minutes(50), clock: clock, store: store)
        let before = try #require(manager.activeSession)

        manager.adjustPlannedDuration(by: minutes(10))
        #expect(manager.activeSession?.plannedDuration == minutes(60))

        manager.adjustPlannedDuration(by: -minutes(10))
        #expect(manager.activeSession?.plannedDuration == minutes(50))

        let after = try #require(manager.activeSession)
        #expect(after.startedAt == before.startedAt)
        #expect(after.pausedDuration == before.pausedDuration)
        #expect(after.endedAt == nil)
        #expect(after.isRunning)
        // A target is intent, not evidence. Revising it must never label the times as hand-entered.
        #expect(after.editedAt == nil)
    }

    @Test("On an open-ended session, ten minutes more means ten minutes from where you are")
    func stepOnAnOpenEndedSession() async throws {
        let store = InMemoryStore()
        let clock = FixedClock(nineAM)
        let manager = await started(planned: nil, clock: clock, store: store)
        clock.advance(by: minutes(12))

        manager.adjustPlannedDuration(by: minutes(10))

        #expect(manager.activeSession?.plannedDuration == minutes(22))
        #expect(manager.activeSession?.isOpenEnded == false)
    }

    @Test("A target can be set outright, and cleared back to open-ended")
    func targetCanBeSetAndCleared() async throws {
        let store = InMemoryStore()
        let manager = await started(
            planned: minutes(50),
            clock: FixedClock(nineAM),
            store: store
        )

        manager.adjustPlannedDuration(to: minutes(90))
        #expect(manager.activeSession?.plannedDuration == minutes(90))

        manager.adjustPlannedDuration(to: nil)
        #expect(manager.activeSession?.plannedDuration == nil)
        #expect(manager.activeSession?.isOpenEnded == true)
        #expect(manager.activeSession?.editedAt == nil)
    }

    @Test("Taking more off the target than it holds floors it at zero rather than inverting it")
    func targetNeverGoesNegative() async throws {
        let store = InMemoryStore()
        let manager = await started(
            planned: minutes(50),
            clock: FixedClock(nineAM),
            store: store
        )

        manager.adjustPlannedDuration(by: -minutes(90))

        #expect(manager.activeSession?.plannedDuration == minutes(0))
        #expect(manager.activeSession?.isOpenEnded == false)
    }

    @Test("With nothing running, adjusting the target does nothing at all")
    func adjustWithoutSession() async {
        let store = InMemoryStore()
        let manager = makeManager(store: store, clock: FixedClock(nineAM))

        manager.adjustPlannedDuration(by: minutes(10))
        manager.adjustPlannedDuration(to: minutes(25))

        #expect(manager.activeSession == nil)
        #expect(store.sessions.isEmpty)
        #expect(manager.lastError == nil)
    }
}
