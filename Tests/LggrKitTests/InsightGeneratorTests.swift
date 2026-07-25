import Foundation
import Testing

@testable import LggrKit

// The subject of this file is silence as much as speech.
//
// Half of these tests assert that no observation was produced. That is not a coverage gap being
// papered over: an observation generated from evidence that cannot support it is a pattern the app
// invented and then attributed to the user, which is worse than saying nothing at all. Every
// generator declares a floor, and every floor has a test standing on the wrong side of it.

private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 00:00:00 UTC — a Monday.
private let weekStart = Date(timeIntervalSinceReferenceDate: 726_969_600)
private let week = DateInterval(start: weekStart, end: weekStart.addingTimeInterval(7 * 86_400))

private let testCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = 2
    return calendar
}()

/// `day` 0 is Monday.
private func at(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    weekStart.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3600 + minute * 60))
}

private func session(
    id: UUID = UUID(),
    start: Date,
    minutes length: Double,
    workType: WorkType = .deepWork,
    outcomeID: UUID? = nil,
    isReactive: Bool? = nil
) -> FocusSession {
    FocusSession(
        id: id,
        weeklyOutcomeID: outcomeID,
        intendedOutcome: "Work",
        workType: workType,
        startedAt: start,
        endedAt: start.addingTimeInterval(minutes(length)),
        resultStatus: .completed,
        isReactive: isReactive
    )
}

private func episode(start: Date, minutes length: Double) -> Episode {
    let duration = minutes(length)
    return Episode(
        start: start,
        end: start.addingTimeInterval(duration),
        apps: [
            Episode.AppShare(
                bundleIdentifier: "com.apple.dt.Xcode",
                displayName: "Xcode",
                duration: duration,
                visitCount: 1
            )
        ],
        label: "Xcode",
        labelConfidence: .appRoster
    )
}

private func interruption(
    at timestamp: Date,
    source: InterruptionSource = .message,
    sessionID: UUID? = nil
) -> Interruption {
    Interruption(
        focusSessionID: sessionID,
        description: "Review the blocked PR",
        source: source,
        timestamp: timestamp
    )
}

private func review(
    sessions: [FocusSession] = [],
    accomplishments: [Accomplishment] = [],
    interruptions: [Interruption] = [],
    episodes: [Episode] = [],
    outcomes: WeeklyOutcomeSet? = nil
) -> WeeklyReview {
    WeeklyReviewBuilder.build(
        WeeklyReviewInput(
            week: week,
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions,
            episodes: episodes,
            outcomes: outcomes,
            calendar: testCalendar
        )
    )
}

private func observation(
    _ kind: WeeklyObservation.Kind,
    in review: WeeklyReview,
    thresholds: EvidenceThresholds = EvidenceThresholds()
) -> WeeklyObservation? {
    InsightGenerator.observations(for: review, thresholds: thresholds)
        .first { $0.kind == kind }
}

/// Eight one-hour deep-work sessions across four days, three of them marked reactive.
private func ordinaryWeekSessions() -> [FocusSession] {
    (0..<8).map { index in
        session(
            start: at(day: index % 4, 9 + index / 4 * 3),
            minutes: 60,
            isReactive: index < 3
        )
    }
}

@Suite("Insight generation")
struct InsightGeneratorTests {

    // MARK: - Silence

    @Test("A week with no records produces no observations")
    func emptyWeekIsSilent() {
        #expect(InsightGenerator.observations(for: review()).isEmpty)
    }

    @Test("A sparse week produces no observations, and that is the correct answer")
    func sparseWeekIsSilent() {
        let primaryID = UUID()
        let outcomes = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                WeeklyOutcome(
                    id: primaryID,
                    title: "Receipt ingestion",
                    priority: .primary,
                    weekStartDate: weekStart
                )
            ]
        )
        let result = review(
            sessions: [
                session(start: at(day: 0, 9), minutes: 40),
                session(start: at(day: 1, 10), minutes: 40),
                session(start: at(day: 2, 14), minutes: 40),
            ],
            accomplishments: [
                Accomplishment(type: .featureCompleted, title: "Shipped it", timestamp: at(day: 2, 17))
            ],
            episodes: [
                episode(start: at(day: 0, 9), minutes: 40),
                episode(start: at(day: 0, 10), minutes: 20),
            ],
            outcomes: outcomes
        )

        #expect(InsightGenerator.observations(for: result).isEmpty)
    }

    // MARK: - Planned versus reactive

    @Test("The planned split states the share and the sessions behind it")
    func plannedSplit() {
        let result = review(sessions: ordinaryWeekSessions())
        let observed = observation(.plannedSplit, in: result)

        #expect(
            observed?.text
                == "Work that arrived rather than being chosen accounted for 38% of tracked time, "
                    + "across 3 of 8 sessions."
        )
        #expect(observed?.evidence == "8 finished sessions, 8h tracked.")
    }

    @Test("The planned split is silent below the session floor")
    func plannedSplitNeedsEnoughSessions() {
        let result = review(sessions: (0..<5).map { index in
            session(start: at(day: index, 9), minutes: 60, isReactive: index < 2)
        })

        #expect(observation(.plannedSplit, in: result) == nil)
    }

    @Test("The planned split is silent when too little time was tracked")
    func plannedSplitNeedsEnoughTime() {
        let result = review(sessions: (0..<8).map { index in
            session(start: at(day: index % 4, 9 + index / 4), minutes: 10, isReactive: index < 3)
        })

        #expect(result.finishedSessionCount == 8)
        #expect(observation(.plannedSplit, in: result) == nil)
    }

    // MARK: - Primary outcome

    @Test("The primary outcome's share of tracked time is stated without an adverb")
    func primaryOutcomeShare() {
        let primaryID = UUID()
        let outcomes = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                WeeklyOutcome(
                    id: primaryID,
                    title: "Receipt ingestion",
                    priority: .primary,
                    weekStartDate: weekStart
                )
            ]
        )
        var sessions = (0..<3).map { index in
            session(start: at(day: index, 9), minutes: 36, outcomeID: primaryID)
        }
        sessions += (0..<6).map { index in
            session(start: at(day: index % 5, 13), minutes: 82)
        }

        let observed = observation(.primaryOutcomeShare, in: review(sessions: sessions, outcomes: outcomes))

        #expect(
            observed?.text
                == "The primary weekly outcome received 18% of tracked time, across 3 sessions."
        )
        #expect(observed?.evidence == "3 of 9 finished sessions carried a weekly outcome.")
    }

    @Test("An outcome share is silent until enough sessions were linked to mean anything")
    func primaryOutcomeShareNeedsLinkedSessions() {
        let primaryID = UUID()
        let outcomes = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                WeeklyOutcome(
                    id: primaryID,
                    title: "Receipt ingestion",
                    priority: .primary,
                    weekStartDate: weekStart
                )
            ]
        )
        var sessions = [session(start: at(day: 0, 9), minutes: 60, outcomeID: primaryID)]
        sessions += (0..<8).map { index in
            session(start: at(day: index % 5, 13), minutes: 60)
        }

        let result = review(sessions: sessions, outcomes: outcomes)

        #expect(result.sessionsLinkedToOutcome == 1)
        #expect(observation(.primaryOutcomeShare, in: result) == nil)
    }

    @Test("An outcome share is silent when there is no primary outcome")
    func primaryOutcomeShareNeedsAPrimary() {
        let result = review(sessions: ordinaryWeekSessions())

        #expect(observation(.primaryOutcomeShare, in: result) == nil)
    }

    // MARK: - Support work

    @Test("Support work is reported as a duration, with no reference to who was helped")
    func supportWork() {
        let result = review(sessions: (0..<3).map { index in
            session(start: at(day: index, 9), minutes: 30, workType: .codeReview)
        })
        let observed = observation(.supportWork, in: result)

        #expect(
            observed?.text
                == "Code review, management and incident work accounted for 1.5 hours "
                    + "across 3 sessions."
        )
    }

    @Test("Support work is silent below an hour")
    func supportWorkNeedsAnHour() {
        let result = review(sessions: (0..<3).map { index in
            session(start: at(day: index, 9), minutes: 15, workType: .codeReview)
        })

        #expect(observation(.supportWork, in: result) == nil)
    }

    // MARK: - Time of day

    /// Three long mornings and five short afternoons.
    private func timeOfDayWeek() -> [FocusSession] {
        [
            session(start: at(day: 0, 9, 0), minutes: 90),
            session(start: at(day: 1, 10, 15), minutes: 80),
            session(start: at(day: 2, 8, 45), minutes: 70),
        ]
            + (0..<5).map { index in
                session(start: at(day: index, 14, 0), minutes: 30)
            }
    }

    @Test("The boundary in the sentence is derived from the sessions, never chosen")
    func timeOfDayBoundaryComesFromTheData() {
        let observed = observation(.timeOfDay, in: review(sessions: timeOfDayWeek()))

        #expect(observed?.text == "Your 3 longest sessions all started before 10:30.")
        #expect(
            observed?.evidence
                == "The longest 3 of 8 finished sessions, spread across 3 days."
        )
    }

    @Test("A time-of-day claim is silent below eight finished sessions")
    func timeOfDayNeedsEnoughSessions() {
        let sessions = Array(timeOfDayWeek().prefix(6))
        #expect(observation(.timeOfDay, in: review(sessions: sessions)) == nil)
    }

    @Test("A time-of-day claim is silent when the longest sessions all fell on one day")
    func timeOfDayNeedsMoreThanOneDay() {
        let sessions =
            [
                session(start: at(day: 0, 9, 0), minutes: 90),
                session(start: at(day: 0, 10, 15), minutes: 80),
                session(start: at(day: 0, 8, 45), minutes: 70),
            ]
            + (0..<5).map { index in
                session(start: at(day: index, 14, 0), minutes: 30)
            }

        #expect(observation(.timeOfDay, in: review(sessions: sessions)) == nil)
    }

    @Test("A time-of-day claim is silent when every session started early")
    func timeOfDayNeedsSomethingLater() {
        let sessions =
            (0..<3).map { index in
                session(start: at(day: index, 9, 0), minutes: 90)
            }
            + (0..<5).map { index in
                session(start: at(day: index, 8, 0), minutes: 30)
            }

        #expect(observation(.timeOfDay, in: review(sessions: sessions)) == nil)
    }

    @Test("A boundary late in the day would say nothing, so nothing is said")
    func timeOfDayRefusesAVacuousBoundary() {
        let sessions =
            (0..<3).map { index in
                session(start: at(day: index, 16, 0), minutes: 90)
            }
            + (0..<5).map { index in
                session(start: at(day: index, 18, 0), minutes: 30)
            }

        #expect(observation(.timeOfDay, in: review(sessions: sessions)) == nil)
    }

    // MARK: - Interruptions

    @Test("The leading interruption source is stated as a count of the total")
    func interruptionSource() {
        let interruptions =
            (0..<5).map { index in
                interruption(at: at(day: index % 5, 10), source: .message)
            }
            + [
                interruption(at: at(day: 0, 11), source: .email),
                interruption(at: at(day: 1, 11), source: .email),
                interruption(at: at(day: 2, 11), source: .person),
            ]

        let observed = observation(.interruptionSource, in: review(interruptions: interruptions))

        #expect(observed?.text == "5 of 8 captured interruptions came from messages.")
        #expect(observed?.evidence == "8 interruptions captured across 3 sources.")
    }

    @Test("A tied leading source produces no claim about which source led")
    func interruptionSourceNeedsAClearLeader() {
        let interruptions =
            (0..<3).map { index in interruption(at: at(day: index, 10), source: .message) }
            + (0..<3).map { index in interruption(at: at(day: index, 11), source: .email) }

        #expect(observation(.interruptionSource, in: review(interruptions: interruptions)) == nil)
    }

    @Test("Five interruptions are not enough to name a source")
    func interruptionSourceNeedsEnoughInterruptions() {
        let interruptions = (0..<5).map { index in
            interruption(at: at(day: index, 10), source: .message)
        }

        #expect(observation(.interruptionSource, in: review(interruptions: interruptions)) == nil)
    }

    @Test("Deep-work interruptions are counted per session, not per note")
    func deepWorkInterruptionCountsSessions() {
        let sessions = (0..<7).map { index in
            session(start: at(day: index % 5, 9 + index / 5), minutes: 60)
        }
        let interruptions = [
            interruption(at: at(day: 0, 9, 10), sessionID: sessions[0].id),
            // A second note against the same session is the same interrupted session.
            interruption(at: at(day: 0, 9, 20), sessionID: sessions[0].id),
            interruption(at: at(day: 1, 9, 10), sessionID: sessions[1].id),
            interruption(at: at(day: 2, 9, 10), sessionID: sessions[2].id),
            interruption(at: at(day: 3, 9, 10), source: .email, sessionID: sessions[3].id),
        ]

        let observed = observation(
            .deepWorkInterruption,
            in: review(sessions: sessions, interruptions: interruptions)
        )

        #expect(
            observed?.text
                == "Interruptions from messages were recorded in 43% of deep-work sessions "
                    + "(3 of 7)."
        )
        #expect(
            observed?.evidence
                == "7 finished deep-work sessions, 3 with an interruption from messages."
        )
    }

    @Test("Two interrupted sessions out of seven are not enough to describe the week")
    func deepWorkInterruptionNeedsThreeSessions() {
        let sessions = (0..<7).map { index in
            session(start: at(day: index % 5, 9 + index / 5), minutes: 60)
        }
        let interruptions = [
            interruption(at: at(day: 0, 9, 10), sessionID: sessions[0].id),
            interruption(at: at(day: 1, 9, 10), sessionID: sessions[1].id),
        ]

        #expect(
            observation(
                .deepWorkInterruption,
                in: review(sessions: sessions, interruptions: interruptions)
            ) == nil
        )
    }

    @Test("Four deep-work sessions cannot support a percentage")
    func deepWorkInterruptionNeedsEnoughSessions() {
        let sessions = (0..<4).map { index in session(start: at(day: index, 9), minutes: 60) }
        let interruptions = sessions.prefix(3).enumerated().map { index, session in
            interruption(at: at(day: index, 9, 10), sessionID: session.id)
        }

        #expect(
            observation(
                .deepWorkInterruption,
                in: review(sessions: sessions, interruptions: Array(interruptions))
            ) == nil
        )
    }

    // MARK: - Context switches

    @Test("A peak day is named alongside the average it is being compared against")
    func contextSwitchPeak() {
        var episodes: [Episode] = (0..<21).map { index in
            episode(start: at(day: 0, 8).addingTimeInterval(TimeInterval(index * 1800)), minutes: 25)
        }
        for day in 1..<4 {
            episodes += (0..<6).map { index in
                episode(
                    start: at(day: day, 9).addingTimeInterval(TimeInterval(index * 3600)),
                    minutes: 50
                )
            }
        }

        let result = review(episodes: episodes)
        let observed = observation(.contextSwitchPeak, in: result)

        #expect(result.activeDays.count == 4)
        #expect(observed?.text == "Monday had 20 context switches; the daily average was 9.")
        #expect(observed?.evidence == "4 days with recorded activity.")
    }

    @Test("Three active days cannot establish a weekly average")
    func contextSwitchPeakNeedsFourDays() {
        var episodes: [Episode] = (0..<21).map { index in
            episode(start: at(day: 0, 8).addingTimeInterval(TimeInterval(index * 1800)), minutes: 25)
        }
        for day in 1..<3 {
            episodes += (0..<6).map { index in
                episode(
                    start: at(day: day, 9).addingTimeInterval(TimeInterval(index * 3600)),
                    minutes: 50
                )
            }
        }

        #expect(observation(.contextSwitchPeak, in: review(episodes: episodes)) == nil)
    }

    @Test("An evenly spread week has no peak day to name")
    func contextSwitchPeakNeedsAPeak() {
        var episodes: [Episode] = []
        for day in 0..<4 {
            episodes += (0..<12).map { index in
                episode(
                    start: at(day: day, 8).addingTimeInterval(TimeInterval(index * 1800)),
                    minutes: 25
                )
            }
        }

        #expect(observation(.contextSwitchPeak, in: review(episodes: episodes)) == nil)
    }

    // MARK: - The set as a whole

    @Test("Observations are unique per kind and come back in declaration order")
    func observationsAreOrderedAndUnique() {
        let result = review(
            sessions: ordinaryWeekSessions(),
            interruptions: (0..<6).map { index in
                interruption(at: at(day: index % 5, 10), source: .message)
            }
        )
        let observations = InsightGenerator.observations(for: result)
        let kinds = observations.map(\.kind)

        #expect(Set(observations.map(\.id)).count == observations.count)
        #expect(kinds == WeeklyObservation.Kind.allCases.filter(kinds.contains))
    }

    @Test("The limit caps the list without changing what qualifies")
    func limitCapsTheList() {
        let result = review(
            sessions: ordinaryWeekSessions(),
            interruptions: (0..<6).map { index in
                interruption(at: at(day: index % 5, 10), source: .message)
            }
        )

        #expect(InsightGenerator.observations(for: result, limit: 1).count == 1)
        #expect(InsightGenerator.observations(for: result, limit: 0).isEmpty)
        #expect(
            InsightGenerator.observations(for: result, limit: 99).count
                == InsightGenerator.observations(for: result).count
        )
    }

    /// The tone rule, enforced rather than reviewed.
    ///
    /// Every banned word turns a measurement into a verdict, a target, or a comparison with someone
    /// else. A generator that reaches for one of them fails here rather than in front of the user.
    @Test("No generated sentence grades, compares or recommends")
    func observationsCarryNoVerdict() {
        let sessionsForOutcome = UUID()
        let outcomes = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                WeeklyOutcome(
                    id: sessionsForOutcome,
                    title: "Receipt ingestion",
                    priority: .primary,
                    weekStartDate: weekStart
                )
            ]
        )
        var sessions = (0..<3).map { index in
            session(start: at(day: index, 9), minutes: 90, outcomeID: sessionsForOutcome)
        }
        sessions += (0..<3).map { index in
            session(start: at(day: index, 13), minutes: 45, workType: .codeReview)
        }
        sessions += (0..<3).map { index in
            session(start: at(day: index, 15), minutes: 40, isReactive: true)
        }

        let observations = InsightGenerator.observations(
            for: review(
                sessions: sessions,
                interruptions: (0..<7).map { index in
                    interruption(at: at(day: index % 5, 16), source: .message)
                },
                outcomes: outcomes
            )
        )

        let banned = [
            "only", "just", "should", "must", "try to", "avoid", "too much", "too many",
            "distract", "waste", "poor", "better", "worse", "best", "worst", "fail",
            "streak", "score", "productive", "unproductive", "goal", "target", "average user",
        ]

        #expect(!observations.isEmpty)
        for observation in observations {
            let text = observation.text.lowercased()
            for word in banned {
                #expect(!text.contains(word), "\(observation.kind.rawValue): \(observation.text)")
            }
        }
    }
}
