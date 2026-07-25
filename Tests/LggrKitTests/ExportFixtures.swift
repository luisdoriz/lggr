import Foundation

@testable import LggrKit

// The one week every export test in `ExportTests` renders.
//
// Fixed dates, fixed identifiers, a UTC calendar: a failure reproduces identically on any machine, in
// any timezone, on any day of the year, and an exact-output assertion is therefore possible at all.
// The shape deliberately echoes the worked example in `SPEC.md`'s Export section — a primary outcome
// with pull requests against it, a mix of declared and reactive work, five accomplishments — so the
// fixture output can be read against the specification rather than only against itself.

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing rather than decoration. `#expect` compares an
/// `Optional<Double>` against an integer-literal expression such as `54 * 60` by type as well as by
/// value, and reports a failure even when the two numbers are identical.
func exportMinutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 00:00:00 UTC — a Monday.
let exportWeekStart = Date(timeIntervalSinceReferenceDate: 726_969_600)
let exportWeek = DateInterval(
    start: exportWeekStart,
    end: exportWeekStart.addingTimeInterval(7 * 86_400)
)

/// UTC, Monday-first, POSIX: day boundaries are a property of the test, not of the machine.
let exportCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = 2
    return calendar
}()

let exportFormatter = ExportFormatter(calendar: exportCalendar)

/// `day` 0 is Monday.
func exportDate(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    exportWeekStart.addingTimeInterval(TimeInterval(day * 86_400 + hour * 3600 + minute * 60))
}

/// Stable identifiers, so every tie-break in every ordering is fixed too.
func exportID(_ suffix: String) -> UUID {
    UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)") ?? UUID()
}

enum ExportFixture {

    // MARK: - Identifiers

    static let ingestionProject = exportID("11")
    static let alertProject = exportID("12")

    static let primaryOutcomeID = exportID("21")
    static let secondaryOutcomeID = exportID("22")
    static let operationalOutcomeID = exportID("23")

    static let projectNames: [UUID: String] = [
        ingestionProject: "SOR engineering",
        alertProject: "Alert noise",
    ]

    static let outcomeTitles: [UUID: String] = [
        primaryOutcomeID: "Improve receipt ingestion reliability",
        secondaryOutcomeID: "Reduce alert noise",
        operationalOutcomeID: "Team support",
    ]

    // MARK: - Bundles

    /// Recorded under its own name.
    static let xcodeBundle = "com.apple.dt.Xcode"
    /// Recorded under its own name.
    static let slackBundle = "com.tinyspeck.slackmacgap"
    /// On the user's private list. Its time may appear; its identity may not.
    static let journalBundle = "com.example.privatejournal"
    static let journalName = "Private Journal"
    /// On the user's excluded list. Nothing about it may appear at all.
    static let bankingBundle = "com.example.banking"
    static let bankingName = "Banking Vault"

    static let appCategories: [String: AppCategory] = [
        xcodeBundle: .development,
        slackBundle: .communication,
    ]

    /// The privacy settings the export tests hand to the daily summary.
    static let redactor = PrivacyRedactor(
        excludedApplications: [bankingBundle],
        privateApplications: [journalBundle]
    )

    // MARK: - Outcomes

    static let outcomes = WeeklyOutcomeSet(
        weekStart: exportWeekStart,
        outcomes: [
            WeeklyOutcome(
                id: primaryOutcomeID,
                title: "Improve receipt ingestion reliability",
                priority: .primary,
                status: .inProgress,
                progress: 0.6,
                weekStartDate: exportWeekStart,
                projectIDs: [ingestionProject]
            ),
            WeeklyOutcome(
                id: secondaryOutcomeID,
                title: "Reduce alert noise",
                priority: .secondary,
                status: .blocked,
                progress: 0.25,
                weekStartDate: exportWeekStart,
                projectIDs: [alertProject]
            ),
            WeeklyOutcome(
                id: operationalOutcomeID,
                title: "Team support",
                priority: .operational,
                status: .achieved,
                weekStartDate: exportWeekStart
            ),
        ]
    )

    // MARK: - Sessions

    static func session(
        _ suffix: String,
        day: Int,
        hour: Int,
        minute: Int = 0,
        length: Double,
        outcome: String,
        workType: WorkType = .deepWork,
        projectID: UUID? = nil,
        weeklyOutcomeID: UUID? = nil,
        status: SessionResultStatus? = .completed,
        tangibleResult: String? = nil,
        blocker: String? = nil,
        nextStep: String? = nil,
        summary: String? = nil,
        interruptionCount: Int = 0,
        finished: Bool = true
    ) -> FocusSession {
        let start = exportDate(day: day, hour, minute)
        return FocusSession(
            id: exportID(suffix),
            projectID: projectID,
            weeklyOutcomeID: weeklyOutcomeID,
            intendedOutcome: outcome,
            workType: workType,
            plannedDuration: exportMinutes(length),
            startedAt: start,
            endedAt: finished ? start.addingTimeInterval(exportMinutes(length)) : nil,
            resultStatus: finished ? status : nil,
            resultSummary: summary,
            tangibleResult: tangibleResult,
            blocker: blocker,
            nextStep: nextStep,
            interruptionCount: interruptionCount
        )
    }

    static let sessions: [FocusSession] = [
        session(
            "31",
            day: 0,
            hour: 9,
            length: 60,
            outcome: "Deduplicate receipt rows",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID,
            tangibleResult: "Deduplication query rewritten",
            nextStep: "Backfill the affected month",
            interruptionCount: 1
        ),
        session(
            "32",
            day: 0,
            hour: 10,
            minute: 30,
            length: 50,
            outcome: "Add the ingestion regression test",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID
        ),
        session(
            "33",
            day: 1,
            hour: 9,
            length: 60,
            outcome: "Trace the duplicate commission rows",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID,
            status: .madeProgress
        ),
        session(
            "34",
            day: 1,
            hour: 14,
            length: 45,
            outcome: "Review the ingestion PR",
            workType: .codeReview,
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID
        ),
        session(
            "35",
            day: 2,
            hour: 9,
            length: 90,
            outcome: "Rework the retry path",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID,
            status: .interrupted,
            blocker: "Waiting on the vendor sandbox",
            interruptionCount: 2
        ),
        session(
            "36",
            day: 2,
            hour: 13,
            length: 60,
            outcome: "Review two blocking pull requests",
            workType: .codeReview,
            status: .completed
        ),
        session(
            "37",
            day: 3,
            hour: 9,
            length: 30,
            outcome: "Answer the ingestion questions",
            workType: .communication
        ),
        session(
            "38",
            day: 3,
            hour: 11,
            length: 60,
            outcome: "Page volume from the alerting rules",
            workType: .incident,
            projectID: alertProject,
            weeklyOutcomeID: secondaryOutcomeID
        ),
        session(
            "39",
            day: 4,
            hour: 9,
            length: 45,
            outcome: "Draft the alerting thresholds",
            workType: .planning,
            projectID: alertProject,
            weeklyOutcomeID: secondaryOutcomeID,
            status: .madeProgress
        ),
        session(
            "3a",
            day: 4,
            hour: 15,
            length: 30,
            outcome: "Ingestion design review",
            workType: .meeting
        ),
    ]

    // MARK: - Accomplishments

    static func accomplishment(
        _ suffix: String,
        day: Int,
        hour: Int,
        type: AccomplishmentType,
        title: String,
        details: String? = nil,
        projectID: UUID? = nil,
        weeklyOutcomeID: UUID? = nil,
        focusSessionID: UUID? = nil
    ) -> Accomplishment {
        Accomplishment(
            id: exportID(suffix),
            projectID: projectID,
            weeklyOutcomeID: weeklyOutcomeID,
            focusSessionID: focusSessionID,
            type: type,
            title: title,
            details: details,
            timestamp: exportDate(day: day, hour)
        )
    }

    static let accomplishments: [Accomplishment] = [
        accomplishment(
            "41",
            day: 0,
            hour: 12,
            type: .pullRequestOpened,
            title: "Opened the receipt deduplication PR",
            details: "Splits the ingestion writer from the reconciliation pass.",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID
        ),
        accomplishment(
            "42",
            day: 1,
            hour: 15,
            type: .incidentResolved,
            title: "Resolved duplicate commission ingestion",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID
        ),
        accomplishment(
            "43",
            day: 2,
            hour: 14,
            type: .pullRequestReviewed,
            title: "Reviewed three blocking pull requests",
            focusSessionID: exportID("36")
        ),
        accomplishment(
            "44",
            day: 3,
            hour: 12,
            type: .personUnblocked,
            title: "Unblocked two engineers"
        ),
        accomplishment(
            "45",
            day: 4,
            hour: 10,
            type: .documentWritten,
            title: "Documented the new ingestion architecture",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID
        ),
        accomplishment(
            "46",
            day: 0,
            hour: 17,
            type: .pullRequestOpened,
            title: "Opened the retry backoff PR",
            projectID: ingestionProject,
            weeklyOutcomeID: primaryOutcomeID
        ),
    ]

    // MARK: - Interruptions

    static func interruption(
        _ suffix: String,
        day: Int,
        hour: Int,
        source: InterruptionSource,
        description: String,
        sessionID: UUID? = nil
    ) -> Interruption {
        Interruption(
            id: exportID(suffix),
            focusSessionID: sessionID,
            description: description,
            source: source,
            timestamp: exportDate(day: day, hour),
            status: .inbox
        )
    }

    /// The descriptions name a colleague on purpose: no export may repeat one.
    static let interruptions: [Interruption] = [
        interruption(
            "51",
            day: 0,
            hour: 9,
            source: .message,
            description: "Priya asked about the commission report",
            sessionID: exportID("31")
        ),
        interruption(
            "52",
            day: 2,
            hour: 9,
            source: .message,
            description: "Marcus pinged about the vendor sandbox",
            sessionID: exportID("35")
        ),
        interruption(
            "53",
            day: 2,
            hour: 10,
            source: .person,
            description: "Dana stopped by the desk",
            sessionID: exportID("35")
        ),
        interruption(
            "54",
            day: 3,
            hour: 14,
            source: .incident,
            description: "Ingestion pager fired"
        ),
        interruption(
            "55",
            day: 4,
            hour: 11,
            source: .message,
            description: "Priya asked for the architecture doc"
        ),
    ]

    // MARK: - Episodes

    static func episode(
        _ suffix: String,
        day: Int,
        hour: Int,
        minute: Int = 0,
        length: Double,
        apps: [Episode.AppShare],
        label: String,
        confidence: LabelConfidence = .appRoster,
        sessionID: UUID? = nil
    ) -> Episode {
        let start = exportDate(day: day, hour, minute)
        return Episode(
            id: exportID(suffix),
            start: start,
            end: start.addingTimeInterval(exportMinutes(length)),
            apps: apps,
            label: label,
            labelConfidence: confidence,
            sessionID: sessionID,
            intervalCount: 12
        )
    }

    static func share(
        _ bundle: String,
        _ name: String,
        _ length: Double
    ) -> Episode.AppShare {
        Episode.AppShare(
            bundleIdentifier: bundle,
            displayName: name,
            duration: exportMinutes(length),
            visitCount: 3
        )
    }

    static let episodes: [Episode] = [
        episode(
            "61",
            day: 0,
            hour: 9,
            length: 60,
            apps: [share(xcodeBundle, "Xcode", 52), share(slackBundle, "Slack", 6)],
            label: "Deduplicate receipt rows",
            confidence: .declared,
            sessionID: exportID("31")
        ),
        episode(
            "62",
            day: 0,
            hour: 11,
            length: 45,
            apps: [share(xcodeBundle, "Xcode", 40)],
            label: "Xcode"
        ),
        episode(
            "63",
            day: 0,
            hour: 14,
            length: 30,
            apps: [share(slackBundle, "Slack", 25)],
            label: "Slack"
        ),
        // Time in a private application. The duration survives; the name must not.
        episode(
            "64",
            day: 0,
            hour: 15,
            length: 20,
            apps: [share(journalBundle, journalName, 18)],
            label: journalName
        ),
        // An excluded application. Nothing about this block may reach a document.
        episode(
            "65",
            day: 0,
            hour: 16,
            length: 25,
            apps: [share(bankingBundle, bankingName, 22)],
            label: bankingName
        ),
        episode(
            "66",
            day: 1,
            hour: 9,
            length: 60,
            apps: [share(xcodeBundle, "Xcode", 55)],
            label: "Xcode"
        ),
    ]

    static let gaps: [Gap] = [
        Gap(
            id: exportID("71"),
            reason: .idle,
            start: exportDate(day: 0, 10, 0),
            end: exportDate(day: 0, 11, 0)
        ),
        // Below the export's gap floor, so it is not a line in the timeline.
        Gap(
            id: exportID("72"),
            reason: .idle,
            start: exportDate(day: 0, 12, 0),
            end: exportDate(day: 0, 12, 2)
        ),
        Gap(
            id: exportID("73"),
            reason: .appNotRunning,
            start: exportDate(day: 0, 13, 0),
            end: exportDate(day: 0, 14, 0)
        ),
    ]

    // MARK: - Assembled inputs

    static var weeklyInput: WeeklyReviewInput {
        WeeklyReviewInput(
            week: exportWeek,
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions,
            episodes: episodes,
            outcomes: outcomes,
            projectNames: projectNames,
            appCategories: appCategories,
            calendar: exportCalendar
        )
    }

    static var review: WeeklyReview { WeeklyReviewBuilder.build(weeklyInput) }

    static var monday: DateInterval {
        DateInterval(start: exportWeekStart, end: exportWeekStart.addingTimeInterval(86_400))
    }

    static var dailyInput: DailySummaryInput {
        DailySummaryInput(
            day: monday,
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions,
            timeline: DayTimeline(
                dayStart: exportWeekStart,
                episodes: episodes.filter { $0.start < exportWeekStart.addingTimeInterval(86_400) },
                gaps: gaps,
                sealed: true
            ),
            projectNames: projectNames
        )
    }

    static var logInput: AccomplishmentLogInput {
        AccomplishmentLogInput(
            interval: exportWeek,
            accomplishments: accomplishments,
            projectNames: projectNames,
            outcomeTitles: outcomeTitles
        )
    }

    static var csvInput: SessionsCSVInput {
        SessionsCSVInput(
            interval: exportWeek,
            sessions: sessions,
            projectNames: projectNames,
            outcomeTitles: outcomeTitles
        )
    }
}
