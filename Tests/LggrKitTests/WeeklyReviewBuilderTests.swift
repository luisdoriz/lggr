import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing rather than decoration. `#expect` compares an
/// `Optional<Double>` against an integer-literal expression such as `54 * 60` by type as well as by
/// value, and reports a failure even when the two numbers are identical. Routing every duration
/// through this helper keeps both sides of every comparison `Double`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }
private func hours(_ count: Double) -> TimeInterval { count * 3600 }

/// 2024-01-15 00:00:00 UTC — a Monday. Fixed so a failure reproduces identically on any machine, in
/// any timezone, on any day of the year.
private let weekStart = Date(timeIntervalSinceReferenceDate: 726_969_600)
private let week = DateInterval(start: weekStart, end: weekStart.addingTimeInterval(7 * 86_400))

/// UTC, Monday-first, POSIX locale: weekday names and day boundaries are then properties of the test
/// rather than of the machine running it.
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

private enum Bundle {
    static let xcode = "com.apple.dt.Xcode"
    static let slack = "com.tinyspeck.slackmacgap"
    static let unknown = "com.example.mystery"
}

private let testCategories: [String: AppCategory] = [
    Bundle.xcode: .development,
    Bundle.slack: .communication,
]

private func session(
    id: UUID = UUID(),
    start: Date,
    minutes length: Double,
    workType: WorkType = .deepWork,
    projectID: UUID? = nil,
    outcomeID: UUID? = nil,
    isReactive: Bool? = nil,
    status: SessionResultStatus? = .completed,
    finished: Bool = true
) -> FocusSession {
    FocusSession(
        id: id,
        projectID: projectID,
        weeklyOutcomeID: outcomeID,
        intendedOutcome: "Work",
        workType: workType,
        startedAt: start,
        endedAt: finished ? start.addingTimeInterval(minutes(length)) : nil,
        resultStatus: finished ? status : nil,
        isReactive: isReactive
    )
}

private func episode(
    start: Date,
    minutes length: Double,
    bundle: String = Bundle.xcode,
    sessionID: UUID? = nil
) -> Episode {
    let duration = minutes(length)
    return Episode(
        start: start,
        end: start.addingTimeInterval(duration),
        apps: [
            Episode.AppShare(
                bundleIdentifier: bundle,
                displayName: bundle,
                duration: duration,
                visitCount: 1
            )
        ],
        label: bundle,
        labelConfidence: .appRoster,
        sessionID: sessionID
    )
}

private func accomplishment(
    at timestamp: Date,
    type: AccomplishmentType = .other,
    title: String = "Did a thing",
    outcomeID: UUID? = nil,
    sessionID: UUID? = nil
) -> Accomplishment {
    Accomplishment(
        weeklyOutcomeID: outcomeID,
        focusSessionID: sessionID,
        type: type,
        title: title,
        timestamp: timestamp
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
    outcomes: WeeklyOutcomeSet? = nil,
    projectNames: [UUID: String] = [:]
) -> WeeklyReview {
    WeeklyReviewBuilder.build(
        WeeklyReviewInput(
            week: week,
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions,
            episodes: episodes,
            outcomes: outcomes,
            projectNames: projectNames,
            appCategories: testCategories,
            calendar: testCalendar
        )
    )
}

private func outcome(
    id: UUID = UUID(),
    title: String,
    priority: OutcomePriority,
    progress: Double = 0,
    status: OutcomeStatus = .inProgress,
    createdAt: Date = weekStart
) -> WeeklyOutcome {
    WeeklyOutcome(
        id: id,
        title: title,
        priority: priority,
        status: status,
        progress: progress,
        weekStartDate: weekStart,
        createdAt: createdAt
    )
}

// MARK: - Outcome shape

@Suite("Weekly outcome shape")
struct WeeklyOutcomeSetTests {

    @Test("One primary and two secondary outcomes are seated")
    func seatsTheShape() {
        let set = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                outcome(title: "Primary", priority: .primary, createdAt: weekStart),
                outcome(
                    title: "Second",
                    priority: .secondary,
                    createdAt: weekStart.addingTimeInterval(60)
                ),
                outcome(
                    title: "Third",
                    priority: .secondary,
                    createdAt: weekStart.addingTimeInterval(120)
                ),
            ]
        )

        #expect(set.primary?.title == "Primary")
        #expect(set.secondary.map(\.title) == ["Second", "Third"])
        #expect(set.unseated.isEmpty)
        #expect(set.canAddSecondary == false)
        #expect(set.remainingSecondarySlots == 0)
        #expect(set.focus.count == 3)
    }

    @Test("A fourth outcome is surfaced rather than dropped")
    func keepsUnseatedOutcomes() {
        let set = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: (0..<4).map { index in
                outcome(
                    title: "Outcome \(index)",
                    priority: index == 0 ? .primary : .secondary,
                    createdAt: weekStart.addingTimeInterval(TimeInterval(index))
                )
            }
        )

        #expect(set.secondary.count == 2)
        #expect(set.unseated.map(\.title) == ["Outcome 3"])
        #expect(set.hasUnseated)
        #expect(set.all.count == 4)
    }

    @Test("A second declared primary competes for a secondary seat instead of being discarded")
    func secondPrimaryIsDemotedNotDropped() {
        let set = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                outcome(title: "First", priority: .primary, createdAt: weekStart),
                outcome(
                    title: "Also primary",
                    priority: .primary,
                    createdAt: weekStart.addingTimeInterval(60)
                ),
            ]
        )

        #expect(set.primary?.title == "First")
        #expect(set.secondary.map(\.title) == ["Also primary"])
        #expect(set.unseated.isEmpty)
    }

    @Test("Operational responsibilities are not capped")
    func operationalIsUncapped() {
        let set = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: (0..<5).map { index in
                outcome(
                    title: "Op \(index)",
                    priority: .operational,
                    createdAt: weekStart.addingTimeInterval(TimeInterval(index))
                )
            }
        )

        #expect(set.operational.count == 5)
        #expect(set.unseated.isEmpty)
        #expect(set.hasPrimary == false)
        #expect(set.focus.isEmpty)
    }

    @Test("Seating does not depend on the order the outcomes arrive in")
    func seatingIsOrderIndependent() {
        let declared = (0..<4).map { index in
            outcome(
                title: "Outcome \(index)",
                priority: index == 0 ? .primary : .secondary,
                createdAt: weekStart.addingTimeInterval(TimeInterval(index))
            )
        }

        let forward = WeeklyOutcomeSet(weekStart: weekStart, outcomes: declared)
        let reversed = WeeklyOutcomeSet(weekStart: weekStart, outcomes: declared.reversed())

        #expect(forward == reversed)
    }

    @Test("Progress is clamped, and a stored NaN resolves to zero")
    func progressIsClamped() {
        #expect(outcome(title: "High", priority: .primary, progress: 1.4).progress == 1)
        #expect(outcome(title: "Low", priority: .primary, progress: -0.2).progress == 0)
        #expect(outcome(title: "NaN", priority: .primary, progress: .nan).progress == 0)
        #expect(outcome(title: "Half", priority: .primary, progress: 0.5).progressPercent == 50)
    }

    @Test("Lookup finds an outcome in any seat")
    func lookupCoversEverySeat() {
        let unseatedID = UUID()
        let set = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                outcome(title: "Primary", priority: .primary, createdAt: weekStart),
                outcome(
                    title: "A",
                    priority: .secondary,
                    createdAt: weekStart.addingTimeInterval(1)
                ),
                outcome(
                    title: "B",
                    priority: .secondary,
                    createdAt: weekStart.addingTimeInterval(2)
                ),
                outcome(
                    id: unseatedID,
                    title: "C",
                    priority: .secondary,
                    createdAt: weekStart.addingTimeInterval(3)
                ),
            ]
        )

        #expect(set.outcome(id: unseatedID)?.title == "C")
        #expect(set.contains(id: UUID()) == false)
    }
}

// MARK: - Interruptions

@Suite("Interruption")
struct InterruptionTests {

    @Test("Converting records the project and the status together")
    func convertingIsConsistent() {
        let projectID = UUID()
        var captured = interruption(at: at(day: 0, 10))
        captured.convert(toProjectID: projectID)

        #expect(captured.status == .converted)
        #expect(captured.convertedProjectID == projectID)
        #expect(captured.isPending == false)
    }

    @Test("Dismissing clears any project the interruption had been converted into")
    func dismissingClearsTheProject() {
        var captured = interruption(at: at(day: 0, 10))
        captured.convert(toProjectID: UUID())
        captured.dismiss()

        #expect(captured.status == .dismissed)
        #expect(captured.convertedProjectID == nil)
    }

    @Test("Returning to the inbox undoes a conversion")
    func returningToInbox() {
        var captured = interruption(at: at(day: 0, 10))
        captured.convert(toProjectID: UUID())
        captured.returnToInbox()

        #expect(captured.status == .inbox)
        #expect(captured.convertedProjectID == nil)
        #expect(captured.isPending)
    }

    @Test("A whitespace-only note has no text worth saving")
    func normalizedDescription() {
        #expect(Interruption(description: "   \n ").normalizedDescription == nil)
        #expect(Interruption(description: "  Ask Omar  ").normalizedDescription == "Ask Omar")
    }

    @Test("An interruption captured outside a session is not evidence about one")
    func sessionAssociationIsOptional() {
        #expect(interruption(at: at(day: 0, 10)).interruptedASession == false)
        #expect(interruption(at: at(day: 0, 10), sessionID: UUID()).interruptedASession)
    }
}

// MARK: - The review

@Suite("Weekly review")
struct WeeklyReviewBuilderTests {

    @Test("A week with nothing in it reports nothing rather than zero-shaped guesses")
    func emptyWeek() {
        let result = review()

        #expect(result.isEmpty)
        #expect(result.trackedDuration == 0)
        #expect(result.plannedVsReactive.plannedShare == nil)
        #expect(result.share(of: minutes(30)) == nil)
        #expect(result.observedShare(of: minutes(30)) == nil)
        #expect(result.averageContextSwitchesPerActiveDay == nil)
        #expect(result.days.count == 7)
        #expect(result.activeDays.isEmpty)
        #expect(result.primaryOutcomeProgress == nil)
    }

    @Test("Week membership is half-open, so the last instant belongs to the next week")
    func membershipIsHalfOpen() {
        let result = review(sessions: [
            session(start: week.start, minutes: 30),
            session(start: week.end, minutes: 30),
            session(start: week.start.addingTimeInterval(-1), minutes: 30),
        ])

        #expect(result.sessionCount == 1)
        #expect(result.trackedDuration == minutes(30))
    }

    @Test("Midnight belongs to exactly one day, so the days add up to the week")
    func midnightBelongsToOneDay() {
        let result = review(sessions: [
            session(start: at(day: 0, 23, 30), minutes: 20),
            session(start: at(day: 1, 0), minutes: 20),
        ])

        #expect(result.days[0].sessionCount == 1)
        #expect(result.days[1].sessionCount == 1)
        #expect(result.days.reduce(0) { $0 + $1.trackedDuration } == result.trackedDuration)
    }

    @Test("A running session is counted but contributes no duration")
    func runningSessionsContributeNoDuration() {
        let result = review(sessions: [
            session(start: at(day: 0, 9), minutes: 60),
            session(start: at(day: 0, 11), minutes: 60, finished: false),
        ])

        #expect(result.sessionCount == 2)
        #expect(result.finishedSessionCount == 1)
        #expect(result.plannedVsReactive.unfinishedSessionCount == 1)
        #expect(result.trackedDuration == minutes(60))
    }

    @Test("Time by project resolves names and files the rest under No project")
    func timeByProject() {
        let known = UUID()
        let missing = UUID()
        let result = review(
            sessions: [
                session(start: at(day: 0, 9), minutes: 90, projectID: known),
                session(start: at(day: 1, 9), minutes: 30, projectID: missing),
                session(start: at(day: 2, 9), minutes: 60),
            ],
            projectNames: [known: "Receipt ingestion"]
        )

        #expect(
            result.timeByProject.map(\.name) == [
                "Receipt ingestion", "No project", "Unnamed project",
            ]
        )
        #expect(result.timeByProject.first?.duration == minutes(90))
        #expect(result.timeByProject.first?.sessionCount == 1)
    }

    @Test("Time by work type comes from finished sessions, ordered by duration")
    func timeByWorkType() {
        let result = review(sessions: [
            session(start: at(day: 0, 9), minutes: 90, workType: .deepWork),
            session(start: at(day: 0, 13), minutes: 45, workType: .codeReview),
            session(start: at(day: 1, 9), minutes: 45, workType: .deepWork),
        ])

        #expect(result.timeByWorkType.map(\.workType) == [.deepWork, .codeReview])
        #expect(result.timeByWorkType.first?.duration == minutes(135))
    }

    @Test("Time by category comes from observed episodes, not from sessions")
    func timeByCategory() {
        let result = review(
            sessions: [session(start: at(day: 0, 9), minutes: 60)],
            episodes: [
                episode(start: at(day: 0, 9), minutes: 50, bundle: Bundle.xcode),
                episode(start: at(day: 0, 10), minutes: 20, bundle: Bundle.slack),
                episode(start: at(day: 0, 11), minutes: 10, bundle: Bundle.unknown),
            ]
        )

        #expect(result.timeByCategory.map(\.category) == [.development, .communication, .unknown])
        #expect(result.observedDuration == minutes(80))
        // Session time and observed time measure different things and are never blended.
        #expect(result.trackedDuration == minutes(60))
    }

    @Test("Context switches are the moves between blocks, so one unbroken block is none")
    func contextSwitchesAreMovesBetweenBlocks() {
        let quiet = review(episodes: [episode(start: at(day: 0, 9), minutes: 120)])
        #expect(quiet.days[0].contextSwitches == 0)
        #expect(quiet.contextSwitchTotal == 0)

        let busy = review(
            episodes: (0..<4).map { index in
                episode(start: at(day: 0, 9 + index), minutes: 30)
            }
        )
        #expect(busy.days[0].episodeCount == 4)
        #expect(busy.days[0].contextSwitches == 3)
        #expect(busy.contextSwitchTotal == 3)
        #expect(busy.averageContextSwitchesPerActiveDay == Double(3))
    }

    @Test("Result status drives the completed and interrupted counts")
    func sessionOutcomes() {
        let result = review(sessions: [
            session(start: at(day: 0, 9), minutes: 30, status: .completed),
            session(start: at(day: 0, 10), minutes: 30, status: .interrupted),
            session(start: at(day: 0, 11), minutes: 30, status: .blocked),
            session(start: at(day: 0, 12), minutes: 30, status: nil),
        ])

        #expect(result.sessionsCompleted == 1)
        #expect(result.sessionsInterrupted == 1)
        #expect(result.finishedSessionCount == 4)
    }

    @Test("Planned versus reactive follows the explicit flag, then the outcome link")
    func plannedVersusReactive() {
        let outcomeID = UUID()
        let result = review(sessions: [
            session(start: at(day: 0, 9), minutes: 60, outcomeID: outcomeID),
            session(start: at(day: 0, 11), minutes: 60),
            session(start: at(day: 0, 13), minutes: 60, workType: .incident),
        ])
        let split = result.plannedVsReactive

        #expect(split.committedDuration == minutes(60))
        #expect(split.chosenDuration == minutes(60))
        #expect(split.reactiveDuration == minutes(60))
        #expect(split.plannedDuration == minutes(120))
        #expect(split.reactiveShare == 1.0 / 3.0)
        #expect(PlannedVsReactive.origin(of: result.sessions[0]) == .arrived)
    }

    @Test("A user who marks deep work reactive is believed, and the disagreement is counted")
    func explicitFlagOverridesTheWorkTypeDefault() {
        let result = review(sessions: [
            session(start: at(day: 0, 9), minutes: 60, workType: .deepWork, isReactive: true),
            session(start: at(day: 0, 11), minutes: 60, workType: .incident, isReactive: false),
        ])
        let split = result.plannedVsReactive

        #expect(split.reactiveDuration == minutes(60))
        #expect(split.plannedDuration == minutes(60))
        #expect(split.overriddenSessionCount == 2)
    }

    @Test("Outcome progress reports tracked time and the user's own number side by side")
    func outcomeProgress() {
        let primaryID = UUID()
        let outcomes = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                outcome(id: primaryID, title: "Receipt ingestion", priority: .primary, progress: 0.6)
            ]
        )
        let result = review(
            sessions: [
                session(start: at(day: 0, 9), minutes: 36, outcomeID: primaryID),
                session(start: at(day: 1, 9), minutes: 36, outcomeID: primaryID),
                session(start: at(day: 2, 9), minutes: 108),
            ],
            accomplishments: [accomplishment(at: at(day: 1, 17), outcomeID: primaryID)],
            outcomes: outcomes
        )
        let progress = result.primaryOutcomeProgress

        #expect(progress?.sessionCount == 2)
        #expect(progress?.trackedDuration == minutes(72))
        #expect(progress?.shareOfTrackedTime == 0.4)
        #expect(progress?.selfReportedProgress == 0.6)
        #expect(progress?.accomplishmentCount == 1)
        #expect(result.sessionsLinkedToOutcome == 2)
    }

    @Test("Interruption sources are ranked, with ties broken so the order never moves")
    func interruptionSources() {
        let result = review(interruptions: [
            interruption(at: at(day: 0, 10), source: .message),
            interruption(at: at(day: 0, 11), source: .message),
            interruption(at: at(day: 0, 12), source: .email),
            interruption(at: at(day: 1, 10), source: .email),
            interruption(at: at(day: 1, 11), source: .person),
        ])

        #expect(result.interruptionSources.map(\.source) == [.email, .message, .person])
        #expect(result.interruptionCount == 5)
        #expect(result.days[0].interruptionCount == 3)
    }

    @Test("A session counted as support work is counted once, however it qualified")
    func supportWorkIsCountedOnce() {
        let reviewSessionID = UUID()
        let result = review(
            sessions: [
                session(
                    id: reviewSessionID,
                    start: at(day: 0, 9),
                    minutes: 45,
                    workType: .codeReview
                ),
                session(start: at(day: 0, 11), minutes: 30, workType: .deepWork),
            ],
            accomplishments: [
                accomplishment(
                    at: at(day: 0, 10),
                    type: .pullRequestReviewed,
                    sessionID: reviewSessionID
                )
            ]
        )

        #expect(result.supportSessionCount == 1)
        #expect(result.supportDuration == minutes(45))
        #expect(result.supportAccomplishments.count == 1)
    }

    @Test("Deep work that produced an unblock counts as support work")
    func supportWorkIncludesSessionsThatUnblockedSomeone() {
        let sessionID = UUID()
        let result = review(
            sessions: [
                session(id: sessionID, start: at(day: 0, 9), minutes: 40, workType: .deepWork)
            ],
            accomplishments: [
                accomplishment(at: at(day: 0, 10), type: .personUnblocked, sessionID: sessionID)
            ]
        )

        #expect(result.supportDuration == minutes(40))
        #expect(result.peopleUnblockedCount == 1)
    }

    @Test("Main accomplishments lead with the primary outcome, then any outcome, then the rest")
    func mainAccomplishmentsOrdering() {
        let primaryID = UUID()
        let secondaryID = UUID()
        let outcomes = WeeklyOutcomeSet(
            weekStart: weekStart,
            outcomes: [
                outcome(id: primaryID, title: "Primary", priority: .primary, createdAt: weekStart),
                outcome(
                    id: secondaryID,
                    title: "Secondary",
                    priority: .secondary,
                    createdAt: weekStart.addingTimeInterval(60)
                ),
            ]
        )
        let result = review(
            accomplishments: [
                accomplishment(at: at(day: 4, 17), title: "Unlinked, newest"),
                accomplishment(at: at(day: 3, 17), title: "Secondary linked", outcomeID: secondaryID),
                accomplishment(at: at(day: 2, 17), title: "Primary linked", outcomeID: primaryID),
                accomplishment(at: at(day: 1, 17), title: "Unlinked, oldest"),
            ],
            outcomes: outcomes
        )

        #expect(
            result.mainAccomplishments(limit: 3).map(\.title) == [
                "Primary linked", "Secondary linked", "Unlinked, newest",
            ]
        )
        #expect(result.mainAccomplishments(limit: 0).isEmpty)
    }

    @Test("Every day of the week is present, including the ones with nothing on them")
    func daysCoverTheWholeWeek() {
        let result = review(sessions: [session(start: at(day: 2, 9), minutes: 60)])

        #expect(result.days.count == 7)
        #expect(result.days.map(\.start) == (0..<7).map { at(day: $0, 0) })
        #expect(result.activeDays.count == 1)
        #expect(result.days[2].isActive)
        #expect(result.days[0].isActive == false)
    }

    @Test("The same input always produces the same review")
    func buildIsDeterministic() {
        let sessions = (0..<6).map { index in
            session(start: at(day: index % 5, 9 + index), minutes: 30, projectID: nil)
        }
        let input = WeeklyReviewInput(
            week: week,
            sessions: sessions,
            episodes: (0..<4).map { episode(start: at(day: 0, 9 + $0), minutes: 30) },
            appCategories: testCategories,
            calendar: testCalendar
        )

        #expect(WeeklyReviewBuilder.build(input) == WeeklyReviewBuilder.build(input))
    }
}
