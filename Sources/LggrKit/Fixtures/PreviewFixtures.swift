import Foundation

/// Deterministic sample data for previews, the development gallery and tests.
///
/// Every date is derived from one fixed reference instant and every identifier is generated from a
/// fixed byte pattern, so a snapshot taken today matches one taken next month and a failing test
/// reproduces identically on any machine.
///
/// `#Preview` cannot compile with Command Line Tools (see `docs/_design/CONSTRAINTS.md`), so this is
/// a plain data provider that views take by injection rather than a preview macro.
///
/// This data is for previews and development only. It must never be written into a real store: it
/// carries fixed identifiers that would collide with, and masquerade as, the user's own records.
public enum PreviewFixtures {

    // MARK: - Time

    /// 2024-01-15 00:00:00 UTC. All fixture times are offsets from this instant.
    public static let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

    /// The instant previews should treat as "now": mid-afternoon, with a session in flight.
    public static let now = time(16, 25)

    /// The day the fixtures describe, for `loadSessions(in:)` and `loadAccomplishments(in:)`.
    public static let dayInterval = DateInterval(start: dayStart, duration: 24 * 60 * 60)

    public static func time(_ hour: Int, _ minute: Int) -> Date {
        dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
    }

    // MARK: - Identifiers

    /// A stable UUID per fixture index, built from a fixed byte pattern rather than parsed from a
    /// string, so no optional needs unwrapping and no value is ever random.
    public static func fixtureID(_ index: Int) -> UUID {
        UUID(
            uuid: (
                0x16, 0x66, 0x72, 0x21, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00,
                UInt8(truncatingIfNeeded: index >> 8), UInt8(truncatingIfNeeded: index)
            ))
    }

    // MARK: - Projects

    public static let receiptIngestionID = fixtureID(1)
    public static let teamLeadershipID = fixtureID(2)
    public static let platformMigrationID = fixtureID(3)
    public static let quarterlyPlanningID = fixtureID(4)

    public static let projects: [Project] = [
        Project(
            id: receiptIngestionID,
            name: "Receipt ingestion",
            colorID: "blue",
            iconID: "cube",
            createdAt: dayStart.addingTimeInterval(-30 * 24 * 60 * 60),
            updatedAt: time(9, 50)
        ),
        Project(
            id: teamLeadershipID,
            name: "Team leadership",
            colorID: "purple",
            iconID: "person.2",
            createdAt: dayStart.addingTimeInterval(-90 * 24 * 60 * 60),
            updatedAt: time(14, 30)
        ),
        Project(
            id: platformMigrationID,
            name: "Platform migration",
            colorID: "teal",
            iconID: "server.rack",
            createdAt: dayStart.addingTimeInterval(-14 * 24 * 60 * 60),
            updatedAt: time(10, 40)
        ),
        Project(
            id: quarterlyPlanningID,
            name: "Quarterly planning",
            colorID: "orange",
            iconID: "map",
            isActive: false,
            createdAt: dayStart.addingTimeInterval(-120 * 24 * 60 * 60),
            updatedAt: time(15, 40)
        ),
    ]

    public static func projectName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    // MARK: - Sessions

    /// Started 15 minutes ago against a 50 minute plan, so the ring is part way round.
    public static let runningSession = FocusSession(
        id: fixtureID(10),
        projectID: receiptIngestionID,
        intendedOutcome: "Split the dedup pass out of the ingest job",
        workType: .deepWork,
        plannedDuration: 50 * 60,
        startedAt: time(16, 10)
    )

    /// The same shape as `runningSession` but paused five minutes ago. The two are alternatives for
    /// a preview, never both live at once.
    public static let pausedSession = FocusSession(
        id: fixtureID(11),
        projectID: platformMigrationID,
        intendedOutcome: "Reconcile the connection pool settings",
        workType: .codeReview,
        plannedDuration: 50 * 60,
        startedAt: time(16, 10),
        pauseStartedAt: time(16, 20)
    )

    /// A full day, chronological. Varied work types and every result status, including one session
    /// still awaiting its review so the completion sheet has something to open.
    public static let finishedSessions: [FocusSession] = [
        FocusSession(
            id: fixtureID(20),
            projectID: receiptIngestionID,
            intendedOutcome: "Ship the receipt deduplication PR",
            workType: .deepWork,
            plannedDuration: 50 * 60,
            startedAt: time(9, 0),
            endedAt: time(9, 50),
            resultStatus: .completed,
            resultSummary:
                "Deep work on Receipt ingestion for 50 minutes. Completed Ship the receipt deduplication PR."
        ),
        FocusSession(
            id: fixtureID(21),
            projectID: platformMigrationID,
            intendedOutcome: "Review the ingest retry PR",
            workType: .codeReview,
            plannedDuration: 30 * 60,
            startedAt: time(10, 5),
            endedAt: time(10, 40),
            pausedDuration: 5 * 60,
            resultStatus: .madeProgress,
            resultSummary: "Left two comments on the retry budget; the rest reads fine."
        ),
        FocusSession(
            id: fixtureID(22),
            intendedOutcome: "Clear the support inbox",
            workType: .communication,
            plannedDuration: 25 * 60,
            startedAt: time(11, 0),
            endedAt: time(11, 20),
            resultStatus: .interrupted,
            interruptionCount: 2
        ),
        FocusSession(
            id: fixtureID(23),
            projectID: teamLeadershipID,
            intendedOutcome: "Draft the quarter's staffing plan",
            workType: .management,
            startedAt: time(13, 30),
            endedAt: time(14, 30),
            resultStatus: .blocked,
            resultSummary: "Cannot size the on-call rotation without the hiring decision.",
            blocker: "Waiting on the headcount confirmation",
            nextStep: "Ask Priya for the approved headcount on Thursday"
        ),
        FocusSession(
            id: fixtureID(24),
            projectID: quarterlyPlanningID,
            intendedOutcome: "Rewrite the Q2 objectives",
            workType: .planning,
            plannedDuration: 50 * 60,
            startedAt: time(15, 0),
            endedAt: time(15, 40),
            pausedDuration: 4 * 60,
            resultStatus: .reprioritized
        ),
        // Finished but not yet reviewed: `state` is `.awaitingReview`.
        FocusSession(
            id: fixtureID(25),
            intendedOutcome: "File the expense reports",
            workType: .administrative,
            plannedDuration: 25 * 60,
            startedAt: time(15, 50),
            endedAt: time(16, 5)
        ),
    ]

    /// The day's finished work plus the session currently running.
    public static let sessions: [FocusSession] = finishedSessions + [runningSession]

    // MARK: - Accomplishments

    public static let accomplishments: [Accomplishment] = [
        Accomplishment(
            id: fixtureID(30),
            projectID: receiptIngestionID,
            focusSessionID: fixtureID(20),
            type: .featureCompleted,
            title: "Receipt deduplication shipped",
            details: "Duplicate receipts are collapsed on ingest instead of at report time.",
            timestamp: time(9, 50)
        ),
        Accomplishment(
            id: fixtureID(31),
            projectID: platformMigrationID,
            focusSessionID: fixtureID(21),
            type: .pullRequestReviewed,
            title: "Reviewed the ingest retry PR",
            timestamp: time(10, 40)
        ),
        Accomplishment(
            id: fixtureID(32),
            type: .decisionMade,
            title: "Chose the ledger's storage engine",
            details: "Postgres over DynamoDB: the reporting queries are relational.",
            timestamp: time(12, 10)
        ),
        Accomplishment(
            id: fixtureID(33),
            projectID: teamLeadershipID,
            focusSessionID: fixtureID(23),
            type: .personUnblocked,
            title: "Unblocked Dana on the schema change",
            timestamp: time(14, 30)
        ),
        Accomplishment(
            id: fixtureID(34),
            projectID: quarterlyPlanningID,
            type: .workDeprioritized,
            title: "Dropped the CSV importer from this cycle",
            details: "Two customers asked; neither has started using the API yet.",
            timestamp: time(15, 40)
        ),
        Accomplishment(
            id: fixtureID(35),
            type: .documentWritten,
            title: "Wrote the migration rollback plan",
            timestamp: time(16, 0)
        ),
    ]

    // MARK: - The reconstructed day

    /// A day of ambient capture, matching the fixture sessions above where they overlap and running
    /// well outside them where they do not.
    ///
    /// It is deliberately a *mixed* day rather than a tidy one, because the timeline strip's whole
    /// job is to be honest about what it does and does not know, and a fixture that only exercises
    /// the pretty case reviews nothing:
    ///
    ///   * a morning worked before any session was ever started — the case the feature exists for;
    ///   * blocks that borrow a session's own sentence, and blocks named only from the applications
    ///     that were in front, so the two renderings can be compared side by side;
    ///   * five kinds of absence, including one Lggr cannot account for at all.
    ///
    /// The five-second Slack visits are there to be *collapsed*: they return to the application they
    /// interrupted, so the builder counts them as interjections rather than cutting a block in two.
    public static let dayIntervals: [ActivityInterval] = {
        let xcode = ("com.apple.dt.Xcode", "Xcode")
        let terminal = ("com.apple.Terminal", "Terminal")
        let simulator = ("com.apple.iphonesimulator", "Simulator")
        let slack = ("com.tinyspeck.slackmacgap", "Slack")
        let mail = ("com.apple.mail", "Mail")
        let chrome = ("com.google.Chrome", "Google Chrome")
        let zoom = ("us.zoom.xos", "Zoom")
        let notes = ("com.apple.Notes", "Notes")

        var intervals: [ActivityInterval] = []
        var cursor = dayStart

        func record(_ app: (String, String), seconds: TimeInterval) {
            let end = cursor.addingTimeInterval(seconds)
            intervals.append(
                ActivityInterval(
                    id: fixtureID(100 + intervals.count),
                    bundleIdentifier: app.0,
                    displayName: app.1,
                    start: cursor,
                    end: end,
                    monotonicDuration: seconds
                )
            )
            cursor = end
        }

        /// Fills a stretch by cycling a dwell pattern, which is what a worked hour actually looks
        /// like: a few dozen activations with a median well under two minutes. A fixture made of
        /// twenty-minute single-application runs is not a gentler version of a day, it is a
        /// different one, and it would exercise none of the collapsing the strip depends on.
        func work(_ pattern: [((String, String), TimeInterval)], from start: Date, to end: Date) {
            cursor = start
            var index = 0
            while cursor < end {
                let (app, seconds) = pattern[index % pattern.count]
                record(app, seconds: min(seconds, end.timeIntervalSince(cursor)))
                index += 1
            }
        }

        // 08:12–08:58. Worked before the first session of the day was ever started: the morning this
        // whole feature exists to show. The five-second Slack visits return to the application they
        // interrupted, so the builder collapses them into interjections rather than cutting here.
        work(
            [(xcode, 190), (terminal, 55), (xcode, 145), (slack, 5), (terminal, 40)],
            from: time(8, 12),
            to: time(8, 58)
        )

        // 09:00–09:50, inside "Ship the receipt deduplication PR".
        work(
            [(xcode, 230), (terminal, 50), (simulator, 40), (xcode, 175), (slack, 5), (xcode, 95)],
            from: time(9, 0),
            to: time(9, 50)
        )

        // 10:05–10:40, inside "Review the ingest retry PR".
        work([(chrome, 200), (slack, 55), (chrome, 130)], from: time(10, 5), to: time(10, 40))

        // 10:40–11:00. Between two sessions, and declared by neither.
        work([(slack, 95), (mail, 130), (chrome, 85)], from: time(10, 40), to: time(11, 0))

        // 11:00–11:20, inside "Clear the support inbox".
        work([(mail, 150), (slack, 70), (chrome, 60)], from: time(11, 0), to: time(11, 20))

        // 12:48–13:25, after an hour and a half in which Lggr was not running at all.
        work([(chrome, 210), (slack, 65), (zoom, 130), (chrome, 90)], from: time(12, 48), to: time(13, 25))

        // 13:30–14:30, inside "Draft the quarter's staffing plan".
        work([(zoom, 420), (chrome, 80), (slack, 45)], from: time(13, 30), to: time(14, 30))

        // 15:00–15:40, inside "Rewrite the Q2 objectives".
        work([(notes, 260), (chrome, 110), (notes, 175)], from: time(15, 0), to: time(15, 40))

        // 15:50–16:05, inside "File the expense reports".
        work([(chrome, 145), (mail, 95)], from: time(15, 50), to: time(16, 5))

        // 16:05 up to "now": undeclared again, and still going.
        work(
            [(xcode, 165), (chrome, 70), (xcode, 110), (slack, 5), (xcode, 85)],
            from: time(16, 5),
            to: now
        )

        return intervals
    }()

    /// The absences the sampler observed on the fixture day. Everything else on the timeline that
    /// cannot be accounted for is derived, not recorded — which is exactly why it says so.
    public static let dayAbsences: [Gap] = [
        Gap(id: fixtureID(200), reason: .idle, start: time(8, 58), end: time(9, 4)),
        Gap(id: fixtureID(201), reason: .idle, start: time(9, 50), end: time(10, 5)),
        Gap(id: fixtureID(202), reason: .appNotRunning, start: time(11, 22), end: time(12, 48)),
        Gap(id: fixtureID(203), reason: .screenLocked, start: time(14, 30), end: time(15, 0)),
    ]

    /// The fixture day, rebuilt by the shipped pipeline rather than hand-written.
    ///
    /// Asking `EpisodeBuilder` for it is the point: a hand-written `DayTimeline` would let a preview
    /// show block names and confidences the real builder would never produce, and the timeline strip
    /// would then be reviewed against a day that cannot happen.
    public static let dayTimeline: DayTimeline = EpisodeBuilder.build(
        intervals: dayIntervals,
        absences: dayAbsences,
        sessions: finishedSessions,
        dayStart: dayStart
    )

    // MARK: - Preferences

    public static let preferences = UserPreferences(
        lastProjectID: receiptIngestionID,
        recentOutcomes: [
            "Split the dedup pass out of the ingest job",
            "Review the ingest retry PR",
            "Draft the quarter's staffing plan",
            "Clear the support inbox",
        ]
    )
}
