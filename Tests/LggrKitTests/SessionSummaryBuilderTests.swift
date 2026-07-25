import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return keeps both sides of every `#expect` comparison `Double`, which an
/// integer literal expression such as `45 * 60` does not.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// The suggested summary is the one piece of writing Lggr does on the user's behalf, so its tone is
/// part of its contract: factual, flat, and identical every time it is asked. These tests pin the
/// exact sentences rather than substrings, because a summary that drifts is a summary the user stops
/// trusting enough to leave unedited.
@Suite("Session summary builder")
struct SessionSummaryBuilderTests {

    private func summary(
        outcome: String = "the receipt deduplication PR",
        project: String? = "Receipt ingestion",
        workType: WorkType = .deepWork,
        active: TimeInterval = minutes(45),
        pauseCount: Int = 0,
        paused: TimeInterval = 0,
        status: SessionResultStatus? = nil
    ) -> String {
        SessionSummaryBuilder.summary(
            intendedOutcome: outcome,
            projectName: project,
            workType: workType,
            activeDuration: active,
            pauseCount: pauseCount,
            pausedDuration: paused,
            resultStatus: status
        )
    }

    // MARK: - Result statuses

    @Test("The worked example from the design document")
    func designDocumentExample() {
        #expect(
            summary(status: .madeProgress)
                == "Deep work on Receipt ingestion for 45 minutes. "
                    + "Made progress on the receipt deduplication PR."
        )
    }

    @Test("Every result status gets its own plain phrasing")
    func everyResultStatusHasAPhrase() {
        let lead = "Deep work on Receipt ingestion for 45 minutes. "

        #expect(
            summary(status: .completed) == lead + "Completed the receipt deduplication PR.")
        #expect(
            summary(status: .madeProgress) == lead + "Made progress on the receipt deduplication PR."
        )
        #expect(summary(status: .blocked) == lead + "Blocked on the receipt deduplication PR.")
        #expect(
            summary(status: .interrupted)
                == lead + "Interrupted while working on the receipt deduplication PR."
        )
        #expect(
            summary(status: .reprioritized)
                == lead + "Set the receipt deduplication PR aside for other work."
        )
    }

    @Test("A session whose result has not been answered still describes what was worked on")
    func unansweredResult() {
        #expect(
            summary(status: nil)
                == "Deep work on Receipt ingestion for 45 minutes. "
                    + "Worked on the receipt deduplication PR."
        )
    }

    @Test("A blocked session reads exactly as calmly as a completed one")
    func toneIsUniform() {
        for status in SessionResultStatus.allCases {
            let text = summary(status: status)
            #expect(!text.contains("!"))
            #expect(!text.contains("great"))
            #expect(!text.contains("Nice"))
            #expect(text.hasSuffix("."))
        }
    }

    @Test("No result status produces an exclamation mark, including the unanswered case")
    func neverExclaims() {
        var texts = SessionResultStatus.allCases.map { summary(status: $0) }
        texts.append(summary(status: nil))
        texts.append(summary(outcome: "", status: .completed))
        texts.append(summary(project: nil, active: 5, pauseCount: 3, paused: minutes(90)))

        for text in texts {
            #expect(!text.contains("!"))
        }
    }

    // MARK: - Projects

    @Test("A session with no project names only the work type")
    func sessionWithoutProject() {
        #expect(
            summary(
                outcome: "the support inbox",
                project: nil,
                workType: .communication,
                active: minutes(25),
                status: .interrupted
            )
                == "Communication for 25 minutes. Interrupted while working on the support inbox."
        )
    }

    @Test("A whitespace-only project name is treated as no project at all")
    func blankProjectName() {
        #expect(summary(project: "   ", status: .completed).hasPrefix("Deep work for 45 minutes."))
    }

    @Test("The work type is always named, whichever it is")
    func workTypeIsNamed() {
        for workType in WorkType.allCases {
            #expect(summary(workType: workType).hasPrefix(workType.displayName))
        }
    }

    // MARK: - Durations

    @Test("A very short session says so rather than rounding down to zero minutes")
    func veryShortSession() {
        #expect(
            summary(project: nil, active: 25, status: .interrupted)
                == "Deep work for under a minute. "
                    + "Interrupted while working on the receipt deduplication PR."
        )
    }

    @Test("Durations are written in words and pluralized correctly")
    func durationPhrasing() {
        #expect(summary(project: nil, active: minutes(1)).hasPrefix("Deep work for 1 minute."))
        #expect(summary(project: nil, active: minutes(59)).hasPrefix("Deep work for 59 minutes."))
        #expect(summary(project: nil, active: minutes(60)).hasPrefix("Deep work for 1 hour."))
        #expect(
            summary(project: nil, active: minutes(95)).hasPrefix("Deep work for 1 hour 35 minutes.")
        )
        #expect(summary(project: nil, active: minutes(120)).hasPrefix("Deep work for 2 hours."))
        #expect(
            summary(project: nil, active: minutes(185)).hasPrefix("Deep work for 3 hours 5 minutes.")
        )
    }

    @Test("A negative duration cannot produce a negative sentence")
    func negativeDuration() {
        #expect(summary(project: nil, active: -600).hasPrefix("Deep work for under a minute."))
    }

    // MARK: - Pauses

    @Test("Pauses are reported by count and total time")
    func pausesAreReported() {
        #expect(
            summary(pauseCount: 2, paused: minutes(15), status: .madeProgress)
                == "Deep work on Receipt ingestion for 45 minutes, paused twice for 15 minutes. "
                    + "Made progress on the receipt deduplication PR."
        )
        #expect(
            summary(pauseCount: 1, paused: minutes(5))
                .hasPrefix("Deep work on Receipt ingestion for 45 minutes, paused once for 5 minutes.")
        )
        #expect(
            summary(pauseCount: 4, paused: minutes(70))
                .hasPrefix(
                    "Deep work on Receipt ingestion for 45 minutes, paused 4 times for 1 hour 10 minutes."
                )
        )
    }

    @Test("A pause too short to round to a minute is counted but not timed")
    func momentaryPause() {
        #expect(
            summary(pauseCount: 1, paused: 20)
                .hasPrefix("Deep work on Receipt ingestion for 45 minutes, paused once.")
        )
    }

    @Test("A session with no pauses says nothing about pausing")
    func noPauses() {
        #expect(!summary(status: .completed).contains("paused"))
    }

    // MARK: - Intended outcome handling

    @Test("A period the user typed at the end of the outcome is not left mid-sentence")
    func trailingPeriodIsStripped() {
        #expect(
            summary(outcome: "Ship the receipt deduplication PR.", status: .completed)
                == "Deep work on Receipt ingestion for 45 minutes. "
                    + "Completed Ship the receipt deduplication PR."
        )
    }

    @Test("Surrounding whitespace in the outcome never reaches the sentence")
    func outcomeIsTrimmed() {
        #expect(
            summary(outcome: "  Ship it  ", status: .completed)
                == "Deep work on Receipt ingestion for 45 minutes. Completed Ship it."
        )
    }

    @Test("A blank outcome falls back to reporting the result alone")
    func blankOutcomeWithStatus() {
        #expect(
            summary(outcome: "   ", active: minutes(30), status: .madeProgress)
                == "Deep work on Receipt ingestion for 30 minutes. Made progress."
        )
    }

    @Test("A blank outcome and no result yields a single sentence")
    func blankOutcomeWithoutStatus() {
        #expect(
            summary(outcome: "", active: minutes(30))
                == "Deep work on Receipt ingestion for 30 minutes."
        )
    }

    // MARK: - Determinism

    @Test("Repeated calls with the same input produce byte-identical output")
    func repeatedCallsAreStable() {
        let first = summary(pauseCount: 2, paused: minutes(15), status: .blocked)
        for _ in 0..<50 {
            #expect(summary(pauseCount: 2, paused: minutes(15), status: .blocked) == first)
        }
    }

    // MARK: - Whole sessions

    /// 2024-01-15 09:00:00 UTC.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func at(_ offset: Double) -> Date {
        Self.nineAM.addingTimeInterval(offset * 60)
    }

    private func finishedSession(
        planned: TimeInterval?,
        status: SessionResultStatus = .madeProgress
    ) -> FocusSession {
        var session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            workType: .deepWork,
            plannedDuration: planned,
            startedAt: Self.nineAM
        )
        session.finish(at: at(45), status: status)
        return session
    }

    @Test("A finished session summarizes from its own recorded duration")
    func summaryForFinishedSession() {
        let session = finishedSession(planned: minutes(50))

        #expect(
            SessionSummaryBuilder.summary(for: session, projectName: "Receipt ingestion", at: at(90))
                == "Deep work on Receipt ingestion for 45 minutes. "
                    + "Made progress on Finish the receipt deduplication PR."
        )
    }

    @Test("An open-ended session reads identically to a planned one of the same length")
    func openEndedMatchesPlanned() {
        let planned = finishedSession(planned: minutes(50))
        let openEnded = finishedSession(planned: nil)

        #expect(
            SessionSummaryBuilder.summary(for: planned, projectName: "Receipt ingestion", at: at(90))
                == SessionSummaryBuilder.summary(
                    for: openEnded, projectName: "Receipt ingestion", at: at(90))
        )
    }

    @Test("Running past the plan is reported as time worked, never as a verdict")
    func overrunIsNotJudged() {
        var session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            plannedDuration: minutes(25),
            startedAt: Self.nineAM
        )
        session.finish(at: at(40), status: .completed)

        let text = SessionSummaryBuilder.summary(for: session, projectName: nil, at: at(40))
        #expect(text == "Deep work for 40 minutes. Completed Finish the receipt deduplication PR.")
        #expect(!text.contains("over"))
    }

    @Test("A session still running summarizes from the time worked so far")
    func summaryForRunningSession() {
        let session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            plannedDuration: minutes(50),
            startedAt: Self.nineAM
        )

        #expect(
            SessionSummaryBuilder.summary(for: session, projectName: nil, at: at(20))
                == "Deep work for 20 minutes. Worked on Finish the receipt deduplication PR."
        )
    }

    @Test("A session's own pause time reaches the summary when the pause count is known")
    func summaryForPausedSession() {
        var session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            plannedDuration: minutes(50),
            startedAt: Self.nineAM
        )
        session.pause(at: at(10))
        session.resume(at: at(20))
        session.finish(at: at(55), status: .blocked)

        #expect(
            SessionSummaryBuilder.summary(
                for: session, projectName: "Receipt ingestion", pauseCount: 1, at: at(55))
                == "Deep work on Receipt ingestion for 45 minutes, paused once for 10 minutes. "
                    + "Blocked on Finish the receipt deduplication PR."
        )
    }
}
