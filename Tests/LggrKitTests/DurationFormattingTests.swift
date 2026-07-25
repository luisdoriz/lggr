import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes. The explicit `Double` return keeps both sides of an
/// `#expect` comparison the same type — see the note in `SessionClockTests`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

private func hours(_ count: Double) -> TimeInterval { count * 3600 }

/// Duration strings are the most visible surface in the app and the easiest to let drift: the same
/// forty-five minutes has to read as "45:00", "45m" and "45 minutes" without any of the three ever
/// disagreeing about how long the session was. These tests pin all three formats, plus the boundary
/// values that historically break duration code — exactly an hour, exactly 59 seconds, past a day,
/// zero, and negative.
@Suite("Duration formatting")
struct DurationFormattingTests {

    // MARK: - Timer clock

    @Test("Under an hour the clock is M:SS with padded seconds")
    func timerClockBelowAnHour() {
        #expect(DurationFormatting.timerClock(0) == "0:00")
        #expect(DurationFormatting.timerClock(9) == "0:09")
        #expect(DurationFormatting.timerClock(59) == "0:59")
        #expect(DurationFormatting.timerClock(60) == "1:00")
        #expect(DurationFormatting.timerClock(134) == "2:14")
        #expect(DurationFormatting.timerClock(minutes(50)) == "50:00")
        #expect(DurationFormatting.timerClock(3_599) == "59:59")
    }

    @Test("At exactly one hour the clock gains an hours field")
    func timerClockAtOneHour() {
        #expect(DurationFormatting.timerClock(3_600) == "1:00:00")
        #expect(DurationFormatting.timerClock(3_661) == "1:01:01")
        #expect(DurationFormatting.timerClock(hours(1) + minutes(12)) == "1:12:00")
    }

    @Test("Past a day the hours field simply keeps counting")
    func timerClockBeyondADay() {
        #expect(DurationFormatting.timerClock(hours(24)) == "24:00:00")
        #expect(DurationFormatting.timerClock(hours(25) + 30) == "25:00:30")
        #expect(DurationFormatting.timerClock(hours(100)) == "100:00:00")
    }

    @Test("Sub-second remainders truncate rather than round the clock forward")
    func timerClockTruncates() {
        #expect(DurationFormatting.timerClock(59.9) == "0:59")
        #expect(DurationFormatting.timerClock(3_599.999) == "59:59")
    }

    @Test("Negative and non-finite durations clamp to zero instead of trapping")
    func timerClockClampsBadInput() {
        #expect(DurationFormatting.timerClock(-1) == "0:00")
        #expect(DurationFormatting.timerClock(minutes(-50)) == "0:00")
        #expect(DurationFormatting.timerClock(.nan) == "0:00")
        #expect(DurationFormatting.timerClock(.infinity) != "")
    }

    @Test("The width template matches the clock it reserves space for")
    func timerClockTemplate() {
        #expect(DurationFormatting.timerClockTemplate(upTo: minutes(50)) == "00:00")
        #expect(DurationFormatting.timerClockTemplate(upTo: minutes(9)) == "0:00")
        #expect(DurationFormatting.timerClockTemplate(upTo: hours(2)) == "0:00:00")
        #expect(
            DurationFormatting.timerClockTemplate(upTo: minutes(50)).count
                == DurationFormatting.timerClock(minutes(50)).count
        )
    }

    // MARK: - Countdown

    @Test("A countdown inside the plan reads as a plain clock")
    func countdownWithinPlan() {
        #expect(DurationFormatting.countdown(remaining: minutes(40), overrun: 0) == "40:00")
        #expect(DurationFormatting.countdown(remaining: 134, overrun: 0) == "2:14")
        #expect(DurationFormatting.countdown(remaining: 0, overrun: 0) == "0:00")
    }

    @Test("Overrun turns the countdown around behind a leading plus")
    func countdownOverrun() {
        #expect(DurationFormatting.countdown(remaining: 0, overrun: 134) == "+2:14")
        #expect(DurationFormatting.countdown(remaining: 0, overrun: hours(1)) == "+1:00:00")
        // Overrun wins even if a caller passes a stale remaining alongside it.
        #expect(DurationFormatting.countdown(remaining: minutes(5), overrun: 60) == "+1:00")
    }

    @Test("The signed countdown treats negative as past the target")
    func countdownSigned() {
        #expect(DurationFormatting.countdown(signed: minutes(40)) == "40:00")
        #expect(DurationFormatting.countdown(signed: 0) == "0:00")
        #expect(DurationFormatting.countdown(signed: -134) == "+2:14")
        #expect(DurationFormatting.countdown(signed: .nan) == "0:00")
    }

    @Test("The countdown agrees with the session clock it renders")
    func countdownMatchesSessionClock() {
        let start = Date(timeIntervalSinceReferenceDate: 727_083_600)
        let session = FocusSession(
            intendedOutcome: "Draft the weekly review copy",
            plannedDuration: minutes(50),
            startedAt: start
        )
        let tenIn = start.addingTimeInterval(minutes(10))
        let past = start.addingTimeInterval(minutes(52) + 14)

        #expect(
            DurationFormatting.countdown(
                remaining: session.remaining(at: tenIn) ?? 0,
                overrun: session.overrun(at: tenIn)
            ) == "40:00"
        )
        #expect(
            DurationFormatting.countdown(
                remaining: session.remaining(at: past) ?? 0,
                overrun: session.overrun(at: past)
            ) == "+2:14"
        )
    }

    // MARK: - Compact

    @Test("Compact durations read the way a list needs them to")
    func compactDurations() {
        #expect(DurationFormatting.compact(0) == "0m")
        #expect(DurationFormatting.compact(minutes(50)) == "50m")
        #expect(DurationFormatting.compact(hours(1)) == "1h")
        #expect(DurationFormatting.compact(hours(1) + minutes(12)) == "1h 12m")
        #expect(DurationFormatting.compact(hours(3)) == "3h")
    }

    @Test("Compact rounds to the nearest minute so short work is not erased")
    func compactRounds() {
        #expect(DurationFormatting.compact(59) == "1m")
        #expect(DurationFormatting.compact(29) == "0m")
        #expect(DurationFormatting.compact(3_599) == "1h")
    }

    @Test("Compact keeps counting in hours past a day rather than inventing a day unit")
    func compactBeyondADay() {
        #expect(DurationFormatting.compact(hours(24)) == "24h")
        #expect(DurationFormatting.compact(hours(24) + minutes(30)) == "24h 30m")
        #expect(DurationFormatting.compact(hours(41) + minutes(5)) == "41h 5m")
    }

    @Test("Negative compact durations clamp to zero")
    func compactClamps() {
        #expect(DurationFormatting.compact(-1) == "0m")
        #expect(DurationFormatting.compact(hours(-3)) == "0m")
        #expect(DurationFormatting.compact(.nan) == "0m")
    }

    // MARK: - Prose

    @Test("Whole counts below eleven are spelled out")
    func proseSpellsSmallNumbers() {
        #expect(DurationFormatting.prose(minutes(7)) == "seven minutes")
        #expect(DurationFormatting.prose(minutes(1)) == "one minute")
        #expect(DurationFormatting.prose(minutes(10)) == "ten minutes")
        #expect(DurationFormatting.prose(hours(3)) == "three hours")
    }

    @Test("Eleven and above stay as numerals")
    func proseUsesNumeralsAboveTen() {
        #expect(DurationFormatting.prose(minutes(11)) == "11 minutes")
        #expect(DurationFormatting.prose(minutes(37)) == "37 minutes")
        #expect(DurationFormatting.prose(minutes(59)) == "59 minutes")
    }

    @Test("Exactly one hour reads as one hour, not sixty minutes")
    func proseAtOneHour() {
        #expect(DurationFormatting.prose(hours(1)) == "one hour")
        // A minute short of the hour still rounds into the hours register.
        #expect(DurationFormatting.prose(3_599) == "one hour")
    }

    @Test("Part hours get a single decimal place")
    func proseFractionalHours() {
        #expect(DurationFormatting.prose(minutes(84)) == "1.4 hours")
        #expect(DurationFormatting.prose(hours(2) + minutes(15)) == "2.3 hours")
        #expect(DurationFormatting.prose(hours(24) + minutes(30)) == "24.5 hours")
    }

    @Test("Long spans stay in hours, spelled out only when the count is small")
    func proseBeyondADay() {
        #expect(DurationFormatting.prose(hours(24)) == "24.0 hours")
        #expect(DurationFormatting.prose(hours(9)) == "nine hours")
    }

    @Test("Zero and negative prose durations read as zero minutes")
    func proseClamps() {
        #expect(DurationFormatting.prose(0) == "zero minutes")
        #expect(DurationFormatting.prose(-1) == "zero minutes")
        #expect(DurationFormatting.prose(minutes(-90)) == "zero minutes")
        #expect(DurationFormatting.prose(.nan) == "zero minutes")
    }

    @Test("Prose reads correctly inside the sentence it was written for")
    func proseInASentence() {
        #expect("Spent \(DurationFormatting.prose(minutes(7))) in Slack" == "Spent seven minutes in Slack")
        #expect(
            "Spent \(DurationFormatting.prose(minutes(84))) on Billing"
                == "Spent 1.4 hours on Billing"
        )
    }

    // MARK: - Agreement between formats

    @Test("All three formats describe the same duration")
    func formatsAgree() {
        let fortyFive = minutes(45)
        #expect(DurationFormatting.timerClock(fortyFive) == "45:00")
        #expect(DurationFormatting.compact(fortyFive) == "45m")
        #expect(DurationFormatting.prose(fortyFive) == "45 minutes")
    }
}
