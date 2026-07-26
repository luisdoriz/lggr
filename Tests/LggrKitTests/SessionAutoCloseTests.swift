import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing rather than decoration, for the reason its twin in
/// `SessionEditingTests` gives: `#expect` compares an `Optional<Double>` against an integer-literal
/// expression by type as well as by value, so `40 * 60` fails against an identical `Double`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }
private func hours(_ count: Double) -> TimeInterval { count * 3600 }

/// Closing a session the user forgot to close is the one place in Lggr where the app writes over a
/// number nobody is watching, so every case is pinned here rather than left to the wiring.
///
/// The suite is organised around the one rule the file exists to keep: **the session ends at the last
/// thing anybody witnessed, never at the moment the app noticed.** Each section is a different
/// witness, and the last two sections are the two ways this feature could do harm — closing a session
/// the user said they were coming back to, and moving an end later than it was.
@Suite("Session auto-close")
struct SessionAutoCloseTests {

    /// 2024-01-15 09:00:00 UTC, the same instant `SessionClockTests` and `SessionEditingTests` use, so
    /// a failure in any of the three reads against the same wall clock.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func at(_ offsetMinutes: Double) -> Date {
        Self.nineAM.addingTimeInterval(offsetMinutes * 60)
    }

    /// A running session that started at 09:00 with a 50-minute target.
    private func running(
        planned: TimeInterval? = minutes(50),
        startedAt: Date? = nil
    ) -> FocusSession {
        FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            plannedDuration: planned,
            startedAt: startedAt ?? Self.nineAM
        )
    }

    private func input(
        session: FocusSession,
        lastInputAt: Date? = nil,
        absence: SessionAutoClose.Absence? = nil,
        endOfDay: Date? = nil,
        idleThreshold: TimeInterval = minutes(3),
        now: Date,
        policy: SessionAutoClose.Policy = .default
    ) -> SessionAutoClose.Input {
        SessionAutoClose.Input(
            session: session,
            lastInputAt: lastInputAt,
            absence: absence,
            endOfDay: endOfDay,
            idleThreshold: idleThreshold,
            now: now,
            policy: policy
        )
    }

    // MARK: - The lunch case

    @Test("Idle far beyond the threshold closes the session at the last input, not at now")
    func idleClosesAtLastActivity() {
        // Worked until 12:04, asked at 15:16 — the three hours in between are lunch and an afternoon
        // away from the desk, and the old behaviour recorded every minute of them.
        let session = running(planned: nil)
        let lastInput = self.at(184)
        let now = self.at(376)

        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: lastInput, now: now)
        )

        #expect(decision?.closeAt == lastInput)
        #expect(decision?.reason == .idle)
        #expect(decision?.uncountedDuration == minutes(192))
    }

    @Test("A session with input a moment ago is left alone")
    func activeSessionIsUntouched() {
        let session = running(planned: nil)
        let now = self.at(45)
        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: now.addingTimeInterval(-12), now: now)
        )
        #expect(decision == nil)
    }

    @Test("An open-ended session with the user working is left alone — that is the intended use")
    func openEndedSessionIsNotClosedForBeingOpenEnded() {
        let session = running(planned: nil)
        let now = self.at(600)
        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: now.addingTimeInterval(-30), now: now)
        )
        #expect(decision == nil)
    }

    @Test("Silence past the idle threshold but inside the allowance annotates rather than closes")
    func idleThresholdAloneDoesNotClose() {
        // Four minutes of silence with a three-minute threshold makes the timeline idle. It does not
        // end a session: a phone call taken at the desk is not the end of the work.
        let session = running(planned: nil)
        let now = self.at(60)
        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: now.addingTimeInterval(-minutes(4)), now: now)
        )
        #expect(decision == nil)
    }

    @Test("The allowance is two idle thresholds, and never less than fifteen minutes")
    func allowanceIsDerivedFromTheUsersOwnThreshold() {
        let policy = SessionAutoClose.Policy.default
        // A one-minute threshold does not end a session after two minutes of reading.
        #expect(policy.idleAllowance(for: minutes(1)) == minutes(15))
        #expect(policy.idleAllowance(for: minutes(3)) == minutes(15))
        // Past the floor it tracks the user's own setting.
        #expect(policy.idleAllowance(for: minutes(20)) == minutes(40))
        // A nonsense threshold cannot produce a nonsense allowance.
        #expect(policy.idleAllowance(for: -5) == minutes(15))
        #expect(policy.idleAllowance(for: .infinity) == minutes(15))
    }

    @Test("A long threshold defers the close rather than the floor overriding it")
    func longThresholdDefersTheClose() {
        let session = running(planned: nil)
        let now = self.at(120)
        // 30-minute threshold ⇒ a 60-minute allowance. Twenty minutes of silence is not enough.
        let twentyMinutes = input(
            session: session,
            lastInputAt: now.addingTimeInterval(-minutes(20)),
            idleThreshold: minutes(30),
            now: now
        )
        #expect(SessionAutoClose.decide(twentyMinutes) == nil)

        let seventyMinutes = input(
            session: session,
            lastInputAt: now.addingTimeInterval(-minutes(70)),
            idleThreshold: minutes(30),
            now: now
        )
        #expect(SessionAutoClose.decide(seventyMinutes)?.reason == .idle)
    }

    @Test("No idle reading at all produces no decision")
    func missingIdleReadingIsNotAnAbsenceOfInput() {
        // A missing signal must never be the reason a session ends. `nil` is "no reading", not "no
        // input since the beginning of time".
        let session = running(planned: nil)
        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: nil, now: self.at(600))
        )
        #expect(decision == nil)
    }

    // MARK: - The machine slept, or Lggr was not running

    @Test("A sleep closes the session at the instant the machine slept")
    func sleepClosesAtSleepInstant() {
        // Lid closed at 18:04, opened at 09:12 the next morning. The session must record the
        // afternoon, not the night.
        let session = running(planned: nil)
        let slept = self.at(544)
        let now = self.at(1_452)

        let decision = SessionAutoClose.decide(
            input(
                session: session,
                absence: SessionAutoClose.Absence(lastWitnessedAt: slept, kind: .machineAsleep),
                now: now
            )
        )

        #expect(decision?.closeAt == slept)
        #expect(decision?.reason == .machineAsleep)
    }

    @Test("An absence at launch closes the session at the last heartbeat")
    func appNotRunningClosesAtLastHeartbeat() {
        // The instant handed over is `ActivityLaunchRecovery.Outcome.closeOpenIntervalsAt`, so the
        // session's end and the timeline's `.appNotRunning` gap begin at the same moment. Two
        // independent answers to "when did Lggr stop" is how the record contradicts itself.
        let session = running(planned: nil)
        let lastBeat = self.at(330)
        let relaunch = self.at(430)

        let decision = SessionAutoClose.decide(
            input(
                session: session,
                absence: SessionAutoClose.Absence(
                    lastWitnessedAt: lastBeat, kind: .appNotRunning),
                now: relaunch
            )
        )

        #expect(decision?.closeAt == lastBeat)
        #expect(decision?.reason == .appNotRunning)
        #expect(decision?.uncountedDuration == minutes(100))
    }

    @Test("An absence dated at or after now is not an absence")
    func absenceInTheFutureIsIgnored() {
        let session = running(planned: nil)
        let now = self.at(100)
        let decision = SessionAutoClose.decide(
            input(
                session: session,
                absence: SessionAutoClose.Absence(lastWitnessedAt: now, kind: .appNotRunning),
                now: now
            )
        )
        #expect(decision == nil)
    }

    @Test("An absence with idle silence over the same span closes once, at the earlier witness")
    func sleepAndIdleDoNotBothClaimTheSpan() {
        // The ordinary overnight case: the machine slept at 18:04 and the idle timer, which does not
        // advance while asleep, also reports silence since then. Two witnesses, one close.
        let session = running(planned: nil)
        let slept = self.at(544)
        let now = self.at(1_452)

        let decision = SessionAutoClose.decide(
            input(
                session: session,
                lastInputAt: slept.addingTimeInterval(-30),
                absence: SessionAutoClose.Absence(lastWitnessedAt: slept, kind: .machineAsleep),
                now: now
            )
        )

        // The idle reading is thirty seconds earlier, so it wins — under-claiming is the acceptable
        // failure direction, and the alternative credits half a minute nobody witnessed.
        #expect(decision?.closeAt == slept.addingTimeInterval(-30))
        #expect(decision?.reason == .idle)
    }

    // MARK: - The day boundary

    @Test("A session still open when its day ends is closed at the boundary")
    func dayBoundaryClosesAtEndOfDay() {
        // A session cannot span two days without becoming a fiction: every screen in the app groups
        // by day, and a block that appears in both is in neither honestly.
        let startedAt = Self.nineAM.addingTimeInterval(hours(13))  // 22:00
        let session = running(planned: nil, startedAt: startedAt)
        let endOfDay = Self.nineAM.addingTimeInterval(hours(15))  // 00:00
        let now = Self.nineAM.addingTimeInterval(hours(15.5))

        let decision = SessionAutoClose.decide(
            input(session: session, endOfDay: endOfDay, now: now)
        )

        #expect(decision?.closeAt == endOfDay)
        #expect(decision?.reason == .dayBoundary)
    }

    @Test("The boundary does not fire before it is reached")
    func dayBoundaryDoesNotFireEarly() {
        let session = running(planned: nil)
        let endOfDay = Self.nineAM.addingTimeInterval(hours(15))
        let decision = SessionAutoClose.decide(
            input(session: session, endOfDay: endOfDay, now: self.at(200))
        )
        #expect(decision == nil)
    }

    @Test("A last input earlier than the boundary wins over the boundary")
    func earliestWitnessWinsAcrossRules() {
        // The case the ordering exists for. Started 22:00, stopped 23:10, asked at 09:00. Midnight
        // would record fifty minutes of a night nobody was awake for.
        let startedAt = Self.nineAM.addingTimeInterval(hours(13))
        let session = running(planned: nil, startedAt: startedAt)
        let lastInput = Self.nineAM.addingTimeInterval(hours(14) + minutes(10))
        let endOfDay = Self.nineAM.addingTimeInterval(hours(15))
        let now = Self.nineAM.addingTimeInterval(hours(24))

        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: lastInput, endOfDay: endOfDay, now: now)
        )

        #expect(decision?.closeAt == lastInput)
        #expect(decision?.reason == .idle)
    }

    @Test("A boundary before the session started is not a boundary for it")
    func boundaryBeforeStartIsIgnored() {
        let session = running(planned: nil)
        let decision = SessionAutoClose.decide(
            input(
                session: session,
                endOfDay: Self.nineAM.addingTimeInterval(-hours(1)),
                now: self.at(60)
            )
        )
        #expect(decision == nil)
    }

    // MARK: - What must never be closed

    @Test("A deliberately paused session is never auto-closed, however long the pause")
    func pausedSessionIsNeverClosed() {
        // Pausing is the user saying "I am coming back". Overriding an explicit instruction would
        // make the app an opinion rather than evidence.
        var session = running(planned: nil)
        session.pause(at: self.at(40))
        let now = self.at(900)

        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: self.at(40), now: now)
        )
        #expect(decision == nil)
    }

    @Test("A paused session is not closed by a sleep either")
    func pausedSessionSurvivesSleep() {
        var session = running(planned: nil)
        session.pause(at: self.at(40))
        let decision = SessionAutoClose.decide(
            input(
                session: session,
                absence: SessionAutoClose.Absence(
                    lastWitnessedAt: self.at(50), kind: .machineAsleep),
                now: self.at(1_000)
            )
        )
        #expect(decision == nil)
    }

    @Test("A paused session is not closed by the day boundary either")
    func pausedSessionSurvivesTheDayBoundary() {
        let startedAt = Self.nineAM.addingTimeInterval(hours(13))
        var session = running(planned: nil, startedAt: startedAt)
        session.pause(at: startedAt.addingTimeInterval(minutes(10)))
        let decision = SessionAutoClose.decide(
            input(
                session: session,
                endOfDay: Self.nineAM.addingTimeInterval(hours(15)),
                now: Self.nineAM.addingTimeInterval(hours(20))
            )
        )
        #expect(decision == nil)
    }

    @Test("A finished session produces no decision")
    func finishedSessionIsNotReclosed() {
        var session = running(planned: nil)
        session.finish(at: self.at(50))
        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: self.at(50), now: self.at(900))
        )
        #expect(decision == nil)
    }

    @Test("A clock that has moved backwards ends nothing")
    func backwardsClockProducesNoDecision() {
        let session = running(planned: nil)
        let decision = SessionAutoClose.decide(
            input(
                session: session,
                lastInputAt: Self.nineAM.addingTimeInterval(-hours(2)),
                now: Self.nineAM.addingTimeInterval(-60)
            )
        )
        #expect(decision == nil)
    }

    // MARK: - It can only ever shorten

    @Test("A witness earlier than the session's start clamps to the start, never before it")
    func witnessBeforeStartClampsToStart() {
        // A session started and immediately abandoned records nothing. Zero is honest; the hours the
        // alternative writes are not.
        let session = running(planned: nil)
        let decision = SessionAutoClose.decide(
            input(
                session: session,
                lastInputAt: Self.nineAM.addingTimeInterval(-hours(3)),
                now: self.at(600)
            )
        )
        #expect(decision?.closeAt == Self.nineAM)
        #expect(decision?.uncountedDuration == minutes(600))
    }

    @Test("No decision can move an end later than the instant it was made")
    func decisionNeverClaimsTimeAfterNow() {
        let session = running(planned: nil)
        let now = self.at(600)
        for candidate in [self.at(700), self.at(1_000), now] {
            let decision = SessionAutoClose.decide(
                input(
                    session: session,
                    absence: SessionAutoClose.Absence(
                        lastWitnessedAt: candidate, kind: .appNotRunning),
                    now: now
                )
            )
            // Either refused outright, or clamped to at most now — never later.
            #expect(decision == nil || (decision?.closeAt ?? now) <= now)
        }
    }

    @Test("uncountedDuration is the size of the error being avoided")
    func uncountedDurationIsTheSpanNotRecorded() {
        let session = running(planned: nil)
        let decision = SessionAutoClose.decide(
            input(session: session, lastInputAt: self.at(70), now: self.at(250))
        )
        #expect(decision?.uncountedDuration == minutes(180))
    }

    // MARK: - Applying it

    @Test("Applying a decision ends the session at the decided instant")
    func applyEndsAtDecidedInstant() {
        var session = running(planned: nil)
        let decision = SessionAutoClose.Decision(
            closeAt: self.at(184),
            reason: .idle,
            uncountedDuration: minutes(192)
        )

        // Assigned first: `#expect` captures its operands immutably, so a mutating call cannot be
        // written inside the macro.
        let applied = session.applyAutoClose(decision, at: self.at(376))
        #expect(applied)
        #expect(session.endedAt == self.at(184))
        #expect(session.effectiveDuration == minutes(184))
        #expect(session.isFinished)
    }

    @Test("Applying stamps autoClosedAt and the reason, and leaves editedAt alone")
    func applyStampsItsOwnProvenance() {
        // The sibling, not the same field. `editedAt` means the user typed the number; this means the
        // app chose it and can name the witness. Folding the two together would have the app claim
        // the user's authorship for its own arithmetic.
        var session = running(planned: nil)
        let decidedAt = self.at(376)
        let decision = SessionAutoClose.Decision(
            closeAt: self.at(184), reason: .idle, uncountedDuration: minutes(192))

        session.applyAutoClose(decision, at: decidedAt)

        #expect(session.autoClosedAt == decidedAt)
        #expect(session.autoCloseReason == .idle)
        #expect(session.wasAutoClosed)
        #expect(session.editedAt == nil)
        #expect(!session.wasEdited)
    }

    @Test("Applying to an already finished session changes nothing and reports it")
    func applyIsRefusedOnAFinishedSession() {
        var session = running(planned: nil)
        session.finish(at: self.at(50))
        let decision = SessionAutoClose.Decision(
            closeAt: self.at(10), reason: .idle, uncountedDuration: minutes(40))

        let applied = session.applyAutoClose(decision, at: self.at(60))
        #expect(applied == false)
        #expect(session.endedAt == self.at(50))
        #expect(session.autoClosedAt == nil)
        #expect(session.autoCloseReason == nil)
    }

    @Test("A user correction after an automatic close is recorded as both facts")
    func autoCloseAndHandEditCoexist() {
        var session = running(planned: nil)
        session.applyAutoClose(
            SessionAutoClose.Decision(
                closeAt: self.at(184), reason: .appNotRunning, uncountedDuration: minutes(100)),
            at: self.at(284)
        )
        session.reschedule(start: Self.nineAM, end: self.at(190), at: self.at(300))

        #expect(session.wasAutoClosed)
        #expect(session.wasEdited)
        #expect(session.autoCloseReason == .appNotRunning)
        #expect(session.endedAt == self.at(190))
    }

    @Test("A closed session survives a round trip through Codable with its provenance")
    func provenanceIsPersisted() throws {
        var session = running(planned: nil)
        session.applyAutoClose(
            SessionAutoClose.Decision(
                closeAt: self.at(184), reason: .machineAsleep, uncountedDuration: hours(11)),
            at: self.at(844)
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(FocusSession.self, from: data)

        #expect(decoded.autoClosedAt == session.autoClosedAt)
        #expect(decoded.autoCloseReason == .machineAsleep)
        #expect(decoded.endedAt == session.endedAt)
    }

    @Test("A session written before this feature existed decodes with no auto-close provenance")
    func olderRecordsDecodeWithoutProvenance() throws {
        // The stored file has no `autoClosedAt` key at all. It must read as "nobody adjusted this",
        // never as an adjustment with no witness.
        let json = """
            {
              "id": "\(UUID().uuidString)",
              "intendedOutcome": "Finish the receipt deduplication PR",
              "workType": "deepWork",
              "startedAt": 727083600,
              "pausedDuration": 0,
              "isReactive": false,
              "interruptionCount": 0
            }
            """
        let session = try JSONDecoder().decode(FocusSession.self, from: Data(json.utf8))
        #expect(session.autoClosedAt == nil)
        #expect(session.autoCloseReason == nil)
        #expect(!session.wasAutoClosed)
    }

    @Test("A reason without an instant beside it is refused at construction")
    func reasonWithoutInstantIsDropped() {
        // Neither half of the provenance stands alone: an instant with no reason is a number nobody
        // can check, and a reason with no instant is a claim with no provenance.
        let session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            startedAt: Self.nineAM,
            autoClosedAt: nil,
            autoCloseReason: .idle
        )
        #expect(session.autoCloseReason == nil)
    }

    // MARK: - What it says

    @Test("The sentence names the instant and the witness, and never the user")
    func sentenceStatesTheWitness() {
        let decision = SessionAutoClose.Decision(
            closeAt: self.at(184), reason: .idle, uncountedDuration: minutes(192))
        #expect(decision.sentence(closedAtText: "12:04") == "Ended at 12:04, the last input Lggr recorded.")
    }

    @Test("No reason's copy contains a word that reads as a verdict")
    func copyAvoidsTheBannedWords() {
        // `INTELLIGENCE.md` §3.4's copy law, as a test over the catalogue rather than a convention.
        // "forgot" is added: the whole feature exists because forgetting is expected, and a sentence
        // whose subject is the user's memory is the one thing it must not say.
        let banned = [
            "only", "just", "wasted", "lost", "failed", "distracted", "should", "forgot", "you were",
        ]
        for reason in SessionAutoCloseReason.allCases {
            let strings = [reason.recordNote, reason.displayName]
            for text in strings {
                for word in banned {
                    #expect(
                        !text.lowercased().contains(word),
                        "\(reason) copy contains a banned word: \(word) — \(text)"
                    )
                }
            }
        }
    }

    @Test("Every reason has a distinct glyph, a note and a label")
    func everyReasonIsRenderable() {
        var glyphs = Set<String>()
        for reason in SessionAutoCloseReason.allCases {
            #expect(!reason.recordNote.isEmpty)
            #expect(!reason.displayName.isEmpty)
            #expect(!reason.symbolName.isEmpty)
            glyphs.insert(reason.symbolName)
        }
        #expect(glyphs.count == SessionAutoCloseReason.allCases.count)
    }

    @Test("A negative uncounted duration is not representable")
    func decisionClampsItsOwnDuration() {
        let decision = SessionAutoClose.Decision(
            closeAt: Self.nineAM, reason: .idle, uncountedDuration: -60)
        #expect(decision.uncountedDuration == 0)
    }

    @Test("A policy built from nonsense is still a usable policy")
    func policyClampsItsConstants() {
        let policy = SessionAutoClose.Policy(idleFactor: .nan, minimumIdle: -1)
        #expect(policy.idleFactor == 1)
        #expect(policy.minimumIdle == 0)
        // With no floor and a factor of one the allowance is the threshold itself, which is the
        // documented degenerate case rather than an unbounded one.
        #expect(policy.idleAllowance(for: minutes(5)) == minutes(5))
    }
}
