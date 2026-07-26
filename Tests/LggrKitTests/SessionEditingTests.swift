import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing, not decoration — see the note on the twin of this
/// helper in `SessionClockTests`. `#expect` compares an `Optional<Double>` against an integer-literal
/// expression such as `40 * 60` by type as well as by value, so that comparison fails even when the
/// numbers are identical.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// Editing is where the timing model is most exposed: the user is handing it dates chosen by hand,
/// which means inverted ranges, zero-length spans and spans too short to hold the pauses already
/// recorded inside them. Every one of those has to leave the session in a state `SessionClock` still
/// considers valid, and any change to real data has to be reported rather than absorbed.
@Suite("Session editing")
struct SessionEditingTests {

    /// 2024-01-15 09:00:00 UTC. Same instant as `SessionClockTests`, so failures in the two suites
    /// read against the same wall clock.
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

    /// 09:00–09:45 with a single five-minute pause: 40 minutes of active time.
    private func finishedSession() -> FocusSession {
        var session = session()
        session.pause(at: at(10))
        session.resume(at: at(15))
        session.finish(at: at(45), status: .madeProgress)
        return session
    }

    // MARK: - Provenance

    @Test("A session records no edit until one is made")
    func unEditedSessionCarriesNoStamp() {
        let session = finishedSession()

        #expect(session.editedAt == nil)
        #expect(!session.wasEdited)
    }

    @Test("A reschedule corrects both times and stamps when the user did it")
    func rescheduleCorrectsTimesAndStamps() {
        var session = finishedSession()

        let result = session.reschedule(start: at(5), end: at(35), at: at(90))

        #expect(session.startedAt == at(5))
        #expect(session.endedAt == at(35))
        #expect(session.editedAt == at(90))
        #expect(session.wasEdited)
        // A 30-minute span still holds the five minutes of pause, so nothing was taken away.
        #expect(session.pausedDuration == minutes(5))
        #expect(session.effectiveDuration == minutes(25))
        #expect(result?.reducesPausedDuration == false)
        #expect(result?.pausedDurationReduction == 0.0)
        #expect(result?.effectiveDuration == minutes(25))
    }

    /// The case the whole feature exists for: the stop button was never pressed.
    @Test("The forgotten-stop case: four recorded hours corrected back to fifty minutes")
    func forgottenStopIsCorrectable() {
        var session = session()
        session.finish(at: at(240), status: .completed)
        #expect(session.effectiveDuration == minutes(240))

        session.reschedule(start: Self.nineAM, end: at(50), at: at(300))

        #expect(session.effectiveDuration == minutes(50))
        #expect(session.remaining(at: at(300)) == 0.0)
        #expect(session.overrun(at: at(300)) == 0.0)
        // Answering the completion sheet is not undone by fixing the clock.
        #expect(session.resultStatus == .completed)
        #expect(session.state == .completed)
    }

    // MARK: - Decision B: shrinking below the recorded pauses

    @Test("Shrinking a session below its paused time reduces the pause and reports it")
    func shrinkingBelowPausedTimeIsReported() {
        var session = finishedSession()
        #expect(session.pausedDuration == minutes(5))

        // Three minutes cannot contain a five-minute pause.
        let result = session.reschedule(start: Self.nineAM, end: at(3), at: at(90))

        #expect(result?.reducesPausedDuration == true)
        #expect(result?.previousPausedDuration == minutes(5))
        #expect(result?.pausedDuration == minutes(3))
        #expect(result?.pausedDurationReduction == minutes(2))
        #expect(session.pausedDuration == minutes(3))
        // The two minutes of pause the span cannot hold do not reappear as focus time.
        #expect(session.effectiveDuration == 0.0)
    }

    @Test("The dry run reports the reduction without applying anything")
    func dryRunDoesNotMutate() {
        let session = finishedSession()

        let preview = session.rescheduleResult(start: Self.nineAM, end: at(3))

        #expect(preview?.reducesPausedDuration == true)
        #expect(preview?.pausedDurationReduction == minutes(2))
        // Nothing moved: the sheet can warn first and save second.
        #expect(session.endedAt == at(45))
        #expect(session.pausedDuration == minutes(5))
        #expect(session.editedAt == nil)
    }

    @Test("The dry run and the mutation agree on every number")
    func dryRunMatchesApplied() {
        var session = finishedSession()
        let preview = session.rescheduleResult(start: at(20), end: at(22))
        let applied = session.reschedule(start: at(20), end: at(22), at: at(90))

        #expect(preview == applied)
    }

    @Test("Shrinking to zero length empties the pause and the duration, never inverting either")
    func shrinkToZeroLength() {
        var session = finishedSession()

        let result = session.reschedule(start: at(30), end: at(30), at: at(90))

        #expect(session.startedAt == at(30))
        #expect(session.endedAt == at(30))
        #expect(session.pausedDuration == 0.0)
        #expect(session.effectiveDuration == 0.0)
        #expect(result?.pausedDurationReduction == minutes(5))
        #expect(result?.span == 0.0)
        #expect(session.wallClockInterval?.duration == 0.0)
    }

    @Test("An end before the start clamps up to the start, exactly as finishing does")
    func endBeforeStartClamps() {
        var session = finishedSession()

        let result = session.reschedule(start: at(30), end: at(10), at: at(90))

        #expect(result?.endClampedToStart == true)
        #expect(session.endedAt == at(30))
        #expect(session.startedAt == at(30))
        #expect(session.effectiveDuration == 0.0)
        // Read at any instant, before or after, the session is still non-negative.
        #expect(session.elapsed(at: at(-500)) == 0.0)
        #expect(session.elapsed(at: at(5_000)) == 0.0)
        #expect(session.totalPausedDuration(at: at(5_000)) == 0.0)
    }

    @Test("A far-future end grows the span and leaves the recorded pauses alone")
    func growingASessionKeepsPauses() {
        var session = finishedSession()

        let result = session.reschedule(start: Self.nineAM, end: at(120), at: at(200))

        #expect(result?.reducesPausedDuration == false)
        #expect(session.pausedDuration == minutes(5))
        #expect(session.effectiveDuration == minutes(115))
    }

    @Test("Shifting a session wholesale preserves its duration and its pauses")
    func shiftingPreservesDuration() {
        var session = finishedSession()
        let before = session.effectiveDuration

        session.reschedule(start: at(600), end: at(645), at: at(700))

        #expect(session.effectiveDuration == before)
        #expect(session.pausedDuration == minutes(5))
    }

    // MARK: - Multiple pauses

    /// The worked example from `SessionClockTests`, then edited: 09:00–10:00 with 15 minutes across
    /// two pauses, 45 minutes active.
    @Test("Editing a session with multiple closed pauses keeps the accumulated total")
    func multipleClosedPausesSurviveAnEdit() {
        var session = session()
        session.pause(at: at(10))
        session.resume(at: at(15))
        session.pause(at: at(40))
        session.resume(at: at(50))
        session.finish(at: at(60), status: .madeProgress)
        #expect(session.pausedDuration == minutes(15))

        // A 40-minute span still holds 15 minutes of pause.
        let result = session.reschedule(start: Self.nineAM, end: at(40), at: at(90))

        #expect(result?.reducesPausedDuration == false)
        #expect(session.pausedDuration == minutes(15))
        #expect(session.effectiveDuration == minutes(25))
    }

    @Test("Multiple pauses are reduced as one total when the new span cannot hold them")
    func multipleClosedPausesReducedTogether() {
        var session = session()
        session.pause(at: at(10))
        session.resume(at: at(15))
        session.pause(at: at(40))
        session.resume(at: at(50))
        session.finish(at: at(60), status: .madeProgress)

        let result = session.reschedule(start: Self.nineAM, end: at(10), at: at(90))

        #expect(result?.previousPausedDuration == minutes(15))
        #expect(result?.pausedDuration == minutes(10))
        #expect(result?.pausedDurationReduction == minutes(5))
        #expect(session.effectiveDuration == 0.0)
    }

    @Test("A pause left open on a finished record is folded in, not silently discarded")
    func openPauseOnFinishedRecordIsFoldedIn() {
        // The shape `SessionClockTests.corruptOpenPauseOnFinishedSession` describes: force-quit
        // mid-pause. Twenty of the thirty minutes were paused.
        var session = session()
        session.pauseStartedAt = at(10)
        session.endedAt = at(30)
        #expect(session.elapsed(at: at(30)) == minutes(10))

        let result = session.reschedule(start: Self.nineAM, end: at(30), at: at(90))

        #expect(result?.closedAnOpenPause == true)
        #expect(result?.previousPausedDuration == minutes(20))
        #expect(session.pauseStartedAt == nil)
        #expect(session.pausedDuration == minutes(20))
        // The ten observed active minutes are still ten, not thirty.
        #expect(session.effectiveDuration == minutes(10))
    }

    // MARK: - Unfinished sessions are refused

    @Test("Rescheduling a running session changes nothing and says so")
    func rescheduleRefusesRunningSession() {
        var session = session()

        let result = session.reschedule(start: at(5), end: at(35), at: at(90))

        #expect(result == nil)
        #expect(session.rescheduleResult(start: at(5), end: at(35)) == nil)
        #expect(session.startedAt == Self.nineAM)
        #expect(session.endedAt == nil)
        #expect(session.editedAt == nil)
        #expect(session.isRunning)
    }

    @Test("Rescheduling a paused session changes nothing, leaving the open pause intact")
    func rescheduleRefusesPausedSession() {
        var session = session()
        session.pause(at: at(10))

        let result = session.reschedule(start: at(5), end: at(35), at: at(90))

        #expect(result == nil)
        #expect(session.pauseStartedAt == at(10))
        #expect(session.editedAt == nil)
        #expect(session.isPaused)
        // The pause arithmetic still works afterwards.
        session.resume(at: at(20))
        #expect(session.pausedDuration == minutes(10))
    }

    // MARK: - The stamp itself

    @Test("Editing a session that was never reviewed leaves it awaiting review")
    func editingAnUnreviewedSession() {
        var session = session()
        session.finish(at: at(45))
        #expect(session.state == .awaitingReview)

        session.reschedule(start: Self.nineAM, end: at(30), at: at(90))

        #expect(session.resultStatus == nil)
        #expect(session.state == .awaitingReview)
        #expect(session.wasEdited)
        #expect(session.effectiveDuration == minutes(30))
    }

    @Test("A second edit moves the stamp to the later edit")
    func editedAtRecordsTheLatestEdit() {
        var session = finishedSession()

        session.reschedule(start: Self.nineAM, end: at(40), at: at(90))
        #expect(session.editedAt == at(90))

        session.reschedule(start: Self.nineAM, end: at(35), at: at(300))
        #expect(session.editedAt == at(300))
        #expect(session.effectiveDuration == minutes(30))
    }

    @Test("An edit that changes nothing leaves the session identical apart from the stamp")
    func noOpEditOnlyStamps() {
        let original = finishedSession()
        var edited = original

        let result = edited.reschedule(start: at(0), end: at(45), at: at(90))

        #expect(result?.changesNothing == true)
        #expect(result?.reducesPausedDuration == false)

        var expected = original
        expected.editedAt = at(90)
        #expect(edited == expected)
        #expect(edited.hashValue == expected.hashValue)
    }

    @Test("An edit that does change the times does not report itself as a no-op")
    func realEditIsNotANoOp() {
        let session = finishedSession()

        #expect(session.rescheduleResult(start: at(0), end: at(44))?.changesNothing == false)
        #expect(session.rescheduleResult(start: at(1), end: at(45))?.changesNothing == false)
    }

    // MARK: - Adjusting the target

    @Test("Raising the target on a running session extends what remains")
    func raisingTheTargetWhileRunning() {
        var session = session()
        #expect(session.remaining(at: at(10)) == minutes(40))

        session.adjustPlannedDuration(to: minutes(90))

        #expect(session.remaining(at: at(10)) == minutes(80))
        #expect(session.overrun(at: at(10)) == 0.0)
        #expect(session.progress(at: at(45)) == 0.5)
        // No recorded time moved, so this is not a hand-edited time.
        #expect(session.editedAt == nil)
        #expect(!session.wasEdited)
    }

    @Test("A target already behind the elapsed time floors remaining and starts overrun")
    func loweringTheTargetBelowElapsedStartsOverrun() {
        var session = session()
        #expect(session.elapsed(at: at(40)) == minutes(40))

        session.adjustPlannedDuration(to: minutes(25))

        #expect(session.remaining(at: at(40)) == 0.0)
        #expect(session.overrun(at: at(40)) == minutes(15))
        #expect(session.progress(at: at(40)) == 1.0)
    }

    @Test("Adjusting the target of a finished session leaves its recorded duration alone")
    func adjustingTheTargetOfAFinishedSession() {
        var session = finishedSession()
        let recorded = session.effectiveDuration

        session.adjustPlannedDuration(to: minutes(20))

        #expect(session.effectiveDuration == recorded)
        #expect(session.pausedDuration == minutes(5))
        #expect(session.overrun(at: at(45)) == minutes(20))
        #expect(session.editedAt == nil)
    }

    @Test("Adjusting the target while paused does not restart the clock")
    func adjustingTheTargetWhilePaused() {
        var session = session()
        session.pause(at: at(10))

        session.adjustPlannedDuration(to: minutes(20))

        #expect(session.isPaused)
        #expect(session.elapsed(at: at(30)) == minutes(10))
        #expect(session.remaining(at: at(30)) == minutes(10))
    }

    @Test("Clearing the target makes a session open-ended")
    func clearingTheTarget() {
        var session = session()

        session.adjustPlannedDuration(to: nil)

        #expect(session.isOpenEnded)
        #expect(session.remaining(at: at(90)) == nil)
        #expect(session.progress(at: at(90)) == nil)
        #expect(session.overrun(at: at(90)) == 0.0)
    }

    @Test("An open-ended session can be given a target")
    func givingAnOpenEndedSessionATarget() {
        var session = session(planned: nil)

        session.adjustPlannedDuration(to: minutes(30))

        #expect(!session.isOpenEnded)
        #expect(session.remaining(at: at(10)) == minutes(20))
    }

    @Test("A negative target clamps to zero rather than inflating overrun")
    func negativeTargetClamps() {
        var session = session()

        session.adjustPlannedDuration(to: minutes(-30))

        #expect(session.plannedDuration == 0.0)
        #expect(session.remaining(at: at(10)) == 0.0)
        // Ten minutes of work is ten minutes past a zero-minute target, not forty.
        #expect(session.overrun(at: at(10)) == minutes(10))
        #expect(session.progress(at: at(10)) == nil)
    }

    @Test("Adjusting the target repeatedly is not cumulative")
    func adjustingTheTargetIsIdempotent() {
        var session = session()

        session.adjustPlannedDuration(to: minutes(30))
        session.adjustPlannedDuration(to: minutes(30))
        session.adjustPlannedDuration(to: minutes(30))

        #expect(session.plannedDuration == minutes(30))
    }

    // MARK: - Persistence

    @Test("The edit stamp survives a Codable round trip")
    func editedAtSurvivesRoundTrip() throws {
        var original = finishedSession()
        original.reschedule(start: Self.nineAM, end: at(30), at: at(90))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(FocusSession.self, from: encoder.encode(original))

        #expect(decoded == original)
        #expect(decoded.editedAt == at(90))
        #expect(decoded.wasEdited)
        #expect(decoded.effectiveDuration == minutes(25))
    }

    @Test("An unedited session round trips with no stamp, not with a stamp of now")
    func unEditedSessionRoundTripsWithoutStamp() throws {
        let original = finishedSession()

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FocusSession.self, from: encoder.encode(original))

        #expect(decoded.editedAt == nil)
        #expect(!decoded.wasEdited)
    }

    /// A document written before `editedAt` existed has to keep opening. The store rewrites the whole
    /// file on every save, so a decode failure here would not degrade one row — it would refuse the
    /// user's entire history.
    @Test("A session written before editedAt existed still decodes")
    func legacyDocumentWithoutEditedAtDecodes() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "intendedOutcome": "Split the dedup pass out of the ingest job",
            "workType": WorkType.deepWork.rawValue,
            "plannedDuration": minutes(50),
            "startedAt": Self.nineAM.timeIntervalSinceReferenceDate,
            "endedAt": at(45).timeIntervalSinceReferenceDate,
            "pausedDuration": minutes(5),
            "resultStatus": SessionResultStatus.madeProgress.rawValue,
            "isReactive": false,
            "interruptionCount": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        // `.deferredToDate`, the strategy the store uses, so this is the on-disk shape.
        let decoded = try JSONDecoder().decode(FocusSession.self, from: data)

        #expect(decoded.editedAt == nil)
        #expect(!decoded.wasEdited)
        #expect(decoded.startedAt == Self.nineAM)
        #expect(decoded.endedAt == at(45))
        #expect(decoded.effectiveDuration == minutes(40))
        #expect(decoded.state == .completed)
    }

    @Test("A legacy session can then be edited and re-encoded with its stamp")
    func legacyDocumentCanBeEdited() throws {
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "intendedOutcome": "Ship the importer",
            "workType": WorkType.deepWork.rawValue,
            "startedAt": Self.nineAM.timeIntervalSinceReferenceDate,
            "endedAt": at(240).timeIntervalSinceReferenceDate,
            "pausedDuration": 0,
            "isReactive": false,
            "interruptionCount": 0,
        ]
        var decoded = try JSONDecoder().decode(
            FocusSession.self,
            from: try JSONSerialization.data(withJSONObject: legacy)
        )

        decoded.reschedule(start: Self.nineAM, end: at(50), at: at(300))

        let reDecoded = try JSONDecoder().decode(
            FocusSession.self,
            from: try JSONEncoder().encode(decoded)
        )
        #expect(reDecoded.editedAt == at(300))
        #expect(reDecoded.effectiveDuration == minutes(50))
    }

    // MARK: - The clock's invariants after an edit

    @Test("Every transition still behaves after an edit")
    func transitionsStillWorkAfterAnEdit() {
        var session = finishedSession()
        session.reschedule(start: at(5), end: at(35), at: at(90))

        // A finished session cannot be paused, resumed or finished again — edited or not.
        session.pause(at: at(100))
        session.resume(at: at(110))
        session.finish(at: at(120), status: .blocked)

        #expect(session.pauseStartedAt == nil)
        #expect(session.endedAt == at(35))
        #expect(session.resultStatus == .madeProgress)
        #expect(session.effectiveDuration == minutes(25))
    }

    @Test("No hand-entered pair of dates can produce a negative duration")
    func noEditProducesANegativeDuration() {
        let candidates: [Double] = [-10_000, -45, -1, 0, 1, 45, 10_000]

        for start in candidates {
            for end in candidates {
                var session = finishedSession()
                session.reschedule(start: at(start), end: at(end), at: at(90))

                #expect(session.pausedDuration >= 0)
                #expect(session.endedAt.map { $0 >= session.startedAt } == true)
                #expect(session.effectiveDuration.map { $0 >= 0 } == true)
                #expect(session.elapsed(at: at(-50_000)) >= 0)
                #expect(session.elapsed(at: at(50_000)) >= 0)
                #expect(session.totalPausedDuration(at: at(50_000)) >= 0)
                #expect(session.overrun(at: at(50_000)) >= 0)
                #expect(session.remaining(at: at(50_000)).map { $0 >= 0 } == true)
            }
        }
    }

    @Test("An edited finished session still reports the same elapsed at any later instant")
    func editedSessionIsStable() {
        var session = finishedSession()
        session.reschedule(start: Self.nineAM, end: at(30), at: at(90))

        #expect(session.elapsed(at: at(30)) == minutes(25))
        #expect(session.elapsed(at: at(500)) == minutes(25))
        #expect(session.elapsed(at: at(50_000)) == minutes(25))
    }
}
