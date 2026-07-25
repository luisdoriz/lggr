import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

// The two history screens' state: `HistoryWindow`, `SessionsModel` and `AccomplishmentsModel`.
// See docs/_design/04-screens.md § 4.2 and § 4.3, and SPEC.md § 10.
//
// Everything here runs against a UTC Gregorian calendar with Monday as the first weekday, and a
// `FixedClock`, so no assertion depends on the machine's region or on what time the suite is run.
// Absolute headings ("January 2024") are asserted structurally rather than by string, because they go
// through `Date.FormatStyle` and are therefore localised — the relative ones ("Today", "This week")
// are the app's own copy and are asserted exactly.

// MARK: - Fixtures

/// 2024-01-15 00:00:00 UTC, which is a Monday.
private let mondayJan15 = Date(timeIntervalSinceReferenceDate: 726_969_600)

private var utcMonday: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    calendar.firstWeekday = 2
    return calendar
}

/// `mondayJan15` shifted by whole UTC days. Exact, because UTC has no daylight saving.
private func day(_ offset: Int, hour: Int = 12, minute: Int = 0) -> Date {
    mondayJan15.addingTimeInterval(TimeInterval(offset * 86_400 + hour * 3_600 + minute * 60))
}

private func session(
    _ index: Int,
    outcome: String,
    start: Date,
    minutes: Double = 50,
    projectID: UUID? = nil,
    status: SessionResultStatus? = .completed,
    summary: String? = nil,
    finished: Bool = true
) -> FocusSession {
    FocusSession(
        id: PreviewFixtures.fixtureID(500 + index),
        projectID: projectID,
        intendedOutcome: outcome,
        startedAt: start,
        endedAt: finished ? start.addingTimeInterval(minutes * 60) : nil,
        resultStatus: finished ? status : nil,
        resultSummary: summary
    )
}

private func entry(
    _ index: Int,
    title: String,
    at timestamp: Date,
    type: AccomplishmentType = .other,
    projectID: UUID? = nil,
    details: String? = nil,
    sessionID: UUID? = nil
) -> Accomplishment {
    Accomplishment(
        id: PreviewFixtures.fixtureID(600 + index),
        projectID: projectID,
        focusSessionID: sessionID,
        type: type,
        title: title,
        details: details,
        timestamp: timestamp
    )
}

// MARK: - The window

@Suite("HistoryWindow — the range a history screen is showing")
struct HistoryWindowTests {

    private let calendar = utcMonday

    @Test("A month window is the calendar month containing the anchor")
    func monthIsTheCalendarMonth() throws {
        let window = HistoryWindow(span: .month, anchor: day(0))
        let interval = try #require(window.interval(in: calendar))

        #expect(calendar.component(.month, from: interval.start) == 1)
        #expect(calendar.component(.day, from: interval.start) == 1)
        // Half-open: January's end is 1 February, which is also February's start.
        #expect(calendar.component(.month, from: interval.end) == 2)
        #expect(calendar.component(.day, from: interval.end) == 1)
    }

    @Test("A quarter window is the anchor's month plus the two before it")
    func quarterIsThreeRollingMonths() throws {
        let window = HistoryWindow(span: .quarter, anchor: day(0))
        let interval = try #require(window.interval(in: calendar))

        #expect(calendar.component(.year, from: interval.start) == 2023)
        #expect(calendar.component(.month, from: interval.start) == 11)
        #expect(calendar.component(.year, from: interval.end) == 2024)
        #expect(calendar.component(.month, from: interval.end) == 2)
    }

    @Test("A year window is the calendar year containing the anchor")
    func yearIsTheCalendarYear() throws {
        let window = HistoryWindow(span: .year, anchor: day(0))
        let interval = try #require(window.interval(in: calendar))

        #expect(calendar.component(.year, from: interval.start) == 2024)
        #expect(calendar.component(.month, from: interval.start) == 1)
        #expect(calendar.component(.year, from: interval.end) == 2025)
    }

    @Test("A month steps by one month, a quarter by three, a year by one year")
    func eachSpanStepsByItsOwnStride() throws {
        let month = HistoryWindow(span: .month, anchor: day(0)).stepped(by: -1, in: calendar)
        #expect(calendar.component(.year, from: month.anchor) == 2023)
        #expect(calendar.component(.month, from: month.anchor) == 12)

        let quarter = HistoryWindow(span: .quarter, anchor: day(0)).stepped(by: -1, in: calendar)
        #expect(calendar.component(.year, from: quarter.anchor) == 2023)
        #expect(calendar.component(.month, from: quarter.anchor) == 10)

        let year = HistoryWindow(span: .year, anchor: day(0)).stepped(by: -1, in: calendar)
        #expect(calendar.component(.year, from: year.anchor) == 2023)
    }

    @Test("Stepping is reversible: back then forward is where you started")
    func steppingIsReversible() {
        for span in HistoryWindow.Span.allCases {
            let start = HistoryWindow(span: span, anchor: day(0))
            let roundTrip = start.stepped(by: -3, in: calendar).stepped(by: 3, in: calendar)
            #expect(roundTrip.interval(in: calendar) == start.interval(in: calendar))
        }
    }

    @Test("Forward is available only while the whole window is already in the past")
    func forwardStopsAtThePresent() {
        let now = day(0)

        // January, read in January: "now" is inside the window, so forward is the future.
        #expect(HistoryWindow(span: .month, anchor: now).canStepForward(now: now, in: calendar) == false)
        // December, read in January: the window ended before now, so forward is history.
        let december = HistoryWindow(span: .month, anchor: now).stepped(by: -1, in: calendar)
        #expect(december.canStepForward(now: now, in: calendar))
    }

    @Test("A window contains its own instants and not the boundary that belongs to the next one")
    func containsIsHalfOpen() throws {
        let window = HistoryWindow(span: .month, anchor: day(0))
        let interval = try #require(window.interval(in: calendar))

        #expect(window.contains(interval.start, in: calendar))
        #expect(window.contains(day(0), in: calendar))
        // A record stamped exactly on the end belongs to February, or a per-month breakdown would
        // count it twice.
        #expect(window.contains(interval.end, in: calendar) == false)
    }

    @Test("The three spans title themselves differently, and a cross-year quarter names both years")
    func titlesDistinguishTheSpans() {
        let anchor = day(0)
        let month = HistoryWindow(span: .month, anchor: anchor).title(in: calendar)
        let quarter = HistoryWindow(span: .quarter, anchor: anchor).title(in: calendar)
        let year = HistoryWindow(span: .year, anchor: anchor).title(in: calendar)

        #expect(!month.isEmpty)
        #expect(month != quarter)
        #expect(quarter != year)
        #expect(year.contains("2024"))
        // November 2023 to January 2024 spans a new year, so both are printed.
        #expect(quarter.contains("2023"))
        #expect(quarter.contains("2024"))
    }

    @Test("A display carries everything a header needs and nothing it has to compute")
    func displayDescribesTheWindow() {
        let now = day(0)
        let current = HistoryWindow(span: .month, anchor: now).display(now: now, in: calendar)
        #expect(current.isCurrent)
        #expect(current.canStepForward == false)
        #expect(current.span == .month)
        #expect(current.title == HistoryWindow(span: .month, anchor: now).title(in: calendar))

        let past = HistoryWindow(span: .month, anchor: now)
            .stepped(by: -2, in: calendar)
            .display(now: now, in: calendar)
        #expect(past.isCurrent == false)
        #expect(past.canStepForward)
    }
}

// MARK: - Sessions

@Suite("SessionsModel — the Focus Sessions history")
@MainActor
struct SessionsModelTests {

    private let calendar = utcMonday

    private func model(
        sessions: [FocusSession],
        accomplishments: [Accomplishment] = [],
        interruptions: [Interruption] = [],
        now: Date = day(0)
    ) -> (SessionsModel, InMemoryStore) {
        let store = InMemoryStore(
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions
        )
        let model = SessionsModel(
            store: store,
            clock: FixedClock(now),
            calendar: calendar
        )
        return (model, store)
    }

    // MARK: Windowing

    @Test("A load reads the window and nothing outside it")
    func loadReadsOnlyTheWindow() async {
        let (model, _) = model(sessions: [
            session(1, outcome: "In January", start: day(0)),
            session(2, outcome: "Also January", start: day(-10)),
            session(3, outcome: "December", start: day(-20)),
        ])

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.sessions.count == 2)
        #expect(model.sessions.map(\.intendedOutcome).contains("December") == false)
    }

    @Test("A session that is still running is not in the history")
    func aRunningSessionIsNotHistory() async {
        let (model, _) = model(sessions: [
            session(1, outcome: "Finished", start: day(0, hour: 9)),
            session(2, outcome: "Still going", start: day(0, hour: 11), finished: false),
        ])

        await model.load()

        #expect(model.sessions.count == 1)
        #expect(model.sessions.first?.intendedOutcome == "Finished")
    }

    @Test("Stepping back loads the earlier range; stepping forward past today does nothing")
    func steppingLoadsTheNewRange() async {
        let (model, _) = model(sessions: [
            session(1, outcome: "January", start: day(0)),
            session(2, outcome: "December", start: day(-20)),
        ])

        await model.load()
        #expect(model.sessions.map(\.intendedOutcome) == ["January"])

        await model.step(-1)
        #expect(model.sessions.map(\.intendedOutcome) == ["December"])
        #expect(model.windowDisplay.isCurrent == false)

        await model.step(1)
        #expect(model.sessions.map(\.intendedOutcome) == ["January"])

        // Already at the present. Forward is refused rather than clamped, so the disabled control and
        // the method agree about what is possible.
        let before = model.window
        await model.step(1)
        #expect(model.window == before)
    }

    @Test("Widening the span reaches records the narrower one could not")
    func spanChangeWidensTheRange() async {
        let (model, _) = model(sessions: [
            session(1, outcome: "January", start: day(0)),
            session(2, outcome: "November", start: day(-70)),
        ])

        await model.load()
        #expect(model.sessions.count == 1)

        await model.setSpan(.quarter)
        #expect(model.window.span == .quarter)
        #expect(model.sessions.count == 2)
    }

    @Test("Go to latest returns to the range containing today")
    func goToLatestReturnsToNow() async {
        let (model, _) = model(sessions: [session(1, outcome: "January", start: day(0))])

        await model.load()
        await model.step(-4)
        #expect(model.windowDisplay.isCurrent == false)

        await model.goToLatest()
        #expect(model.windowDisplay.isCurrent)
        #expect(model.sessions.count == 1)
    }

    @Test("A range that is not the current one is not disturbed by something happening today")
    func reloadIfCurrentLeavesThePastAlone() async {
        let (model, store) = model(sessions: [session(1, outcome: "December", start: day(-20))])

        await model.load()
        await model.step(-1)
        #expect(model.sessions.count == 1)

        try? await store.saveSession(session(9, outcome: "Today", start: day(0)))
        await model.reloadIfCurrent()
        // Still December, still one row: the screen the user is reading did not move.
        #expect(model.sessions.map(\.intendedOutcome) == ["December"])

        await model.reload()
        #expect(model.sessions.map(\.intendedOutcome) == ["December"])
    }

    @Test("A store failure keeps the rows already on screen and says so about the record")
    func aFailureKeepsWhatIsOnScreen() async {
        let (model, store) = model(sessions: [session(1, outcome: "January", start: day(0))])

        await model.load()
        #expect(model.sessions.count == 1)

        store.failureToInject = .persistenceFailure("disk")
        await model.reload()

        #expect(model.sessions.count == 1)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failed phase")
            return
        }
        // A sentence about the record, not a verdict on the person keeping it.
        #expect(message.contains("still on disk"))
    }

    // MARK: Grouping

    @Test("Days are newest first, sessions are newest first inside a day")
    func groupingIsNewestFirst() {
        let sessions = [
            session(1, outcome: "Yesterday morning", start: day(-1, hour: 9)),
            session(2, outcome: "Today morning", start: day(0, hour: 9)),
            session(3, outcome: "Today afternoon", start: day(0, hour: 15)),
        ]

        let days = SessionsModel.group(sessions, in: calendar, now: day(0, hour: 18))

        #expect(days.count == 2)
        #expect(days.first?.sessions.map(\.intendedOutcome) == ["Today afternoon", "Today morning"])
        #expect(days.last?.sessions.map(\.intendedOutcome) == ["Yesterday morning"])
    }

    @Test("Day headings read Today, Yesterday, then the date")
    func dayHeadingsUseTheRelativeFormsFirst() {
        let now = day(0, hour: 18)

        #expect(SessionsModel.dayHeading(for: day(0), now: now, in: calendar) == "Today")
        #expect(SessionsModel.dayHeading(for: day(-1), now: now, in: calendar) == "Yesterday")

        let older = SessionsModel.dayHeading(for: day(-4), now: now, in: calendar)
        #expect(older != "Today")
        #expect(older != "Yesterday")
        #expect(!older.isEmpty)
        // No year inside the same year — the header above already says which.
        #expect(older.contains("2024") == false)
    }

    @Test("A day in another year keeps its year, so a January window read in February is unambiguous")
    func aDayInAnotherYearKeepsItsYear() {
        let heading = SessionsModel.dayHeading(for: day(-40), now: day(0), in: calendar)
        #expect(heading.contains("2023"))
    }

    // MARK: Filtering

    @Test("Search matches the outcome, the summary and the tangible result — and nothing else")
    func searchCoversTheUsersOwnWords() {
        var withResult = session(1, outcome: "Ship the parser", start: day(0))
        withResult.tangibleResult = "A merged pull request"

        #expect(SessionsModel.matches(withResult, query: "parser"))
        #expect(SessionsModel.matches(withResult, query: "PARSER"))
        #expect(SessionsModel.matches(withResult, query: "merged pull"))

        let summarised = session(
            2,
            outcome: "Clear the inbox",
            start: day(0),
            summary: "Answered the ingestion thread"
        )
        #expect(SessionsModel.matches(summarised, query: "ingestion"))
        // The work type has its own filter; a search that matched it would make "deep" return every
        // deep-work session whether or not the user ever wrote the word.
        #expect(SessionsModel.matches(summarised, query: "deep work") == false)
    }

    @Test("Search and the project filter narrow the range, and clearing them restores it")
    func filtersNarrowAndClear() async {
        let projectID = PreviewFixtures.receiptIngestionID
        let (model, _) = model(sessions: [
            session(1, outcome: "Ship the parser", start: day(0, hour: 9), projectID: projectID),
            session(2, outcome: "Clear the inbox", start: day(0, hour: 11)),
        ])

        await model.load()
        #expect(model.filteredSessions.count == 2)
        #expect(model.isFiltering == false)

        model.searchText = "parser"
        #expect(model.isFiltering)
        #expect(model.filteredSessions.map(\.intendedOutcome) == ["Ship the parser"])

        model.searchText = "   "
        // Whitespace is not a query.
        #expect(model.isFiltering == false)
        #expect(model.filteredSessions.count == 2)

        model.projectFilter = projectID
        #expect(model.filteredSessions.map(\.intendedOutcome) == ["Ship the parser"])

        model.clearFilters()
        #expect(model.isFiltering == false)
        #expect(model.filteredSessions.count == 2)
    }

    @Test("Unreviewed sessions are identified so the screen can offer them")
    func unreviewedSessionsAreIdentified() async {
        let (model, _) = model(sessions: [
            session(1, outcome: "Reviewed", start: day(0, hour: 9)),
            session(2, outcome: "Never answered", start: day(0, hour: 11), status: nil),
        ])

        await model.load()

        #expect(model.unreviewedSessions.map(\.intendedOutcome) == ["Never answered"])
    }

    // MARK: Detail

    @Test("Opening a session gathers its interruptions and its accomplishments")
    func detailGathersWhatTheSessionRecorded() async {
        let subject = session(1, outcome: "Ship the parser", start: day(0, hour: 9))
        let other = session(2, outcome: "Something else", start: day(0, hour: 14))

        let (model, _) = model(
            sessions: [subject, other],
            accomplishments: [
                entry(1, title: "Opened the parser PR", at: day(0, hour: 10), sessionID: subject.id),
                entry(2, title: "Unrelated", at: day(0, hour: 15), sessionID: other.id),
                entry(3, title: "Filed by hand", at: day(0, hour: 16)),
            ],
            interruptions: [
                Interruption(
                    id: PreviewFixtures.fixtureID(700),
                    focusSessionID: subject.id,
                    description: "Omar's blocked PR",
                    source: .person,
                    timestamp: day(0, hour: 9, minute: 20)
                ),
                Interruption(
                    id: PreviewFixtures.fixtureID(701),
                    description: "Captured outside a session",
                    timestamp: day(0, hour: 17)
                ),
            ]
        )

        await model.load()
        await model.openDetail(subject)

        let detail = model.detail
        #expect(detail?.session.id == subject.id)
        #expect(detail?.accomplishments.map(\.title) == ["Opened the parser PR"])
        #expect(detail?.interruptions.map(\.description) == ["Omar's blocked PR"])
        // No activity log was injected, so the timeline section has nothing and is therefore absent
        // rather than empty.
        #expect(detail?.episodes.isEmpty == true)
        #expect(model.detailPhase == .ready)
    }

    @Test("An accomplishment filed the next morning still belongs to the session it came from")
    func detailReachesIntoTheFollowingDay() async {
        let subject = session(1, outcome: "Ship the parser", start: day(0, hour: 22))
        let (model, _) = model(
            sessions: [subject],
            accomplishments: [
                entry(1, title: "Logged over coffee", at: day(1, hour: 8), sessionID: subject.id)
            ]
        )

        await model.load()
        await model.openDetail(subject)

        #expect(model.detail?.accomplishments.map(\.title) == ["Logged over coffee"])
    }

    @Test("A pushed route resolves a session the loaded range no longer holds")
    func detailResolvesBeyondTheLoadedRange() async {
        let old = session(1, outcome: "Last November", start: day(-70))
        let (model, _) = model(sessions: [old, session(2, outcome: "January", start: day(0))])

        await model.load()
        #expect(model.sessions.count == 1)

        await model.openDetail(sessionID: old.id)

        #expect(model.detail?.session.id == old.id)
        #expect(model.detailPhase == .ready)
    }

    @Test("A route for a session that is gone says so rather than showing an empty screen")
    func detailReportsAMissingSession() async {
        let (model, _) = model(sessions: [session(1, outcome: "January", start: day(0))])

        await model.load()
        await model.openDetail(sessionID: PreviewFixtures.fixtureID(9_999))

        #expect(model.detail == nil)
        guard case .failed(let message) = model.detailPhase else {
            Issue.record("expected a failed detail phase")
            return
        }
        #expect(message.contains("no longer in your history"))
    }

    @Test("An edit made elsewhere lands in both the list and the open detail")
    func applyUpdatesTheListAndTheDetail() async {
        let subject = session(1, outcome: "Ship the parser", start: day(0, hour: 9))
        let (model, _) = model(sessions: [subject])

        await model.load()
        await model.openDetail(subject)

        var edited = subject
        edited.resultSummary = "Merged after two rounds of review"
        edited.tangibleResult = "PR #412"
        model.apply(edited)

        #expect(model.sessions.first?.resultSummary == "Merged after two rounds of review")
        #expect(model.detail?.session.tangibleResult == "PR #412")
    }

    @Test("Closing the detail forgets it, so a stale session cannot be shown by the next push")
    func closingTheDetailForgetsIt() async {
        let subject = session(1, outcome: "Ship the parser", start: day(0))
        let (model, _) = model(sessions: [subject])

        await model.load()
        await model.openDetail(subject)
        #expect(model.detail != nil)

        model.closeDetail()
        #expect(model.detail == nil)
        #expect(model.detailPhase == .idle)
    }
}

// MARK: - Accomplishments

@Suite("AccomplishmentsModel — the Done log")
@MainActor
struct AccomplishmentsModelTests {

    private let calendar = utcMonday
    private var windows: CalendarWindows { CalendarWindows(calendar: utcMonday) }

    private func model(
        _ accomplishments: [Accomplishment],
        now: Date = day(0)
    ) -> (AccomplishmentsModel, InMemoryStore) {
        let store = InMemoryStore(accomplishments: accomplishments)
        let model = AccomplishmentsModel(
            store: store,
            clock: FixedClock(now),
            calendar: calendar
        )
        return (model, store)
    }

    // MARK: Grouping

    @Test("Weeks are newest first, entries are newest first inside a week")
    func groupingIsNewestFirst() {
        let entries = [
            entry(1, title: "Last week's decision", at: day(-7, hour: 10)),
            entry(2, title: "Monday's PR", at: day(0, hour: 9)),
            entry(3, title: "Wednesday's document", at: day(2, hour: 16)),
        ]

        let weeks = AccomplishmentsModel.group(entries, in: windows, now: day(4))

        #expect(weeks.count == 2)
        #expect(weeks.first?.accomplishments.map(\.title) == ["Wednesday's document", "Monday's PR"])
        #expect(weeks.last?.accomplishments.map(\.title) == ["Last week's decision"])
    }

    @Test("A week runs Monday to Sunday under a Monday calendar, so Sunday is not a new group")
    func aWeekHonoursFirstWeekday() {
        // Monday 15th and Sunday 21st are the two ends of one week.
        let entries = [
            entry(1, title: "Monday", at: day(0, hour: 9)),
            entry(2, title: "Sunday", at: day(6, hour: 20)),
            entry(3, title: "The Monday after", at: day(7, hour: 9)),
        ]

        let weeks = AccomplishmentsModel.group(entries, in: windows, now: day(7))

        #expect(weeks.count == 2)
        #expect(weeks.last?.accomplishments.map(\.title) == ["Sunday", "Monday"])
    }

    @Test("Week headings read This week, Last week, then the week's date")
    func weekHeadingsUseTheRelativeFormsFirst() {
        let now = day(3)

        #expect(AccomplishmentsModel.weekHeading(for: day(0), now: now, in: windows) == "This week")
        #expect(AccomplishmentsModel.weekHeading(for: day(-7), now: now, in: windows) == "Last week")

        let older = AccomplishmentsModel.weekHeading(for: day(-21), now: now, in: windows)
        #expect(older.hasPrefix("Week of "))
        #expect(older.contains("2024") == false)
    }

    @Test("A week in another year keeps its year")
    func aWeekInAnotherYearKeepsItsYear() {
        let heading = AccomplishmentsModel.weekHeading(for: day(-45), now: day(0), in: windows)
        #expect(heading.hasPrefix("Week of "))
        #expect(heading.contains("2023"))
    }

    @Test("The Friday read: the current week is the first group on the screen")
    func theCurrentWeekIsFirst() async {
        // Friday afternoon, with work from this week and from two weeks ago.
        let (model, _) = model(
            [
                entry(1, title: "Two weeks ago", at: day(-14, hour: 11)),
                entry(2, title: "Opened the dedup PR", at: day(3, hour: 11)),
                entry(3, title: "Unblocked Omar", at: day(3, hour: 14)),
            ],
            now: day(4, hour: 16)
        )

        await model.load()

        #expect(model.weeks.first?.heading == "This week")
        #expect(model.weeks.first?.accomplishments.map(\.title) == ["Unblocked Omar", "Opened the dedup PR"])
    }

    // MARK: Windowing

    @Test("A load reads the window and nothing outside it")
    func loadReadsOnlyTheWindow() async {
        let (model, _) = model([
            entry(1, title: "January", at: day(0)),
            entry(2, title: "December", at: day(-20)),
        ])

        await model.load()

        #expect(model.phase == .ready)
        #expect(model.accomplishments.map(\.title) == ["January"])
        #expect(model.hasEntriesInWindow)
    }

    @Test("Stepping back reaches an earlier range without disturbing the filters")
    func steppingKeepsTheFilters() async {
        let (model, _) = model([
            entry(1, title: "January decision", at: day(0), type: .decisionMade),
            entry(2, title: "December decision", at: day(-20), type: .decisionMade),
            entry(3, title: "December document", at: day(-21), type: .documentWritten),
        ])

        await model.load()
        model.typeFilter = .decisionMade

        await model.step(-1)

        #expect(model.typeFilter == .decisionMade)
        #expect(model.accomplishments.count == 2)
        #expect(model.filteredAccomplishments.map(\.title) == ["December decision"])
    }

    @Test("A store failure keeps the log on screen and says so about the record")
    func aFailureKeepsWhatIsOnScreen() async {
        let (model, store) = model([entry(1, title: "January", at: day(0))])

        await model.load()
        store.failureToInject = .persistenceFailure("disk")
        await model.reload()

        #expect(model.accomplishments.count == 1)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected a failed phase")
            return
        }
        #expect(message.contains("still on disk"))
    }

    // MARK: Filtering

    @Test("Search matches the title and the details, and not the type's name")
    func searchCoversTheUsersOwnWords() {
        let written = entry(
            1,
            title: "Wrote the rollback plan",
            at: day(0),
            type: .documentWritten,
            details: "Covers the ingestion cutover"
        )

        #expect(AccomplishmentsModel.matches(written, query: "rollback"))
        #expect(AccomplishmentsModel.matches(written, query: "ROLLBACK"))
        #expect(AccomplishmentsModel.matches(written, query: "cutover"))
        #expect(AccomplishmentsModel.matches(written, query: "Document written") == false)
    }

    @Test("Type, project and search compose, and clearing restores the whole range")
    func filtersComposeAndClear() async {
        let projectID = PreviewFixtures.receiptIngestionID
        let (model, _) = model([
            entry(1, title: "Opened the dedup PR", at: day(0, hour: 9), type: .pullRequestOpened, projectID: projectID),
            entry(2, title: "Chose Postgres", at: day(0, hour: 11), type: .decisionMade),
            entry(3, title: "Reviewed the retry PR", at: day(0, hour: 14), type: .pullRequestReviewed, projectID: projectID),
        ])

        await model.load()
        #expect(model.filteredAccomplishments.count == 3)
        #expect(model.isFiltering == false)

        model.projectFilter = projectID
        #expect(model.filteredAccomplishments.count == 2)

        model.typeFilter = .pullRequestOpened
        #expect(model.filteredAccomplishments.map(\.title) == ["Opened the dedup PR"])

        model.searchText = "retry"
        #expect(model.filteredAccomplishments.isEmpty)

        model.clearFilters()
        #expect(model.isFiltering == false)
        #expect(model.filteredAccomplishments.count == 3)
    }

    @Test("The type filter offers only kinds present in the range, in declaration order")
    func availableTypesAreOnlyWhatCanMatch() async {
        let (model, _) = model([
            entry(1, title: "Chose Postgres", at: day(0, hour: 9), type: .decisionMade),
            entry(2, title: "Opened the dedup PR", at: day(0, hour: 11), type: .pullRequestOpened),
            entry(3, title: "Chose the queue", at: day(0, hour: 14), type: .decisionMade),
        ])

        await model.load()

        // Declaration order, not descending count: ranking the kinds would rank the work.
        #expect(model.availableTypes == [.pullRequestOpened, .decisionMade])
    }

    @Test("The project filter offers only projects present in the range")
    func availableProjectsAreOnlyWhatCanMatch() async {
        let present = PreviewFixtures.receiptIngestionID
        let (model, _) = model([
            entry(1, title: "Opened the dedup PR", at: day(0), projectID: present)
        ])

        await model.load()

        let offered = model.availableProjects(from: PreviewFixtures.projects)
        #expect(offered.map(\.id) == [present])
    }

    // MARK: Export

    @Test("The export is the shipped renderer, over exactly what is on screen")
    func exportRendersWhatIsOnScreen() async {
        let projectID = PreviewFixtures.receiptIngestionID
        let (model, _) = model([
            entry(1, title: "Opened the dedup PR", at: day(0, hour: 9), type: .pullRequestOpened, projectID: projectID),
            entry(2, title: "Chose Postgres", at: day(0, hour: 11), type: .decisionMade),
        ])

        await model.load()
        let whole = model.markdown(projects: PreviewFixtures.projects)

        // The document `AccomplishmentLogMarkdown` produces, not a second renderer's idea of it.
        #expect(whole.contains("# Accomplishment log"))
        #expect(whole.contains("Opened the dedup PR"))
        #expect(whole.contains("Chose Postgres"))
        #expect(whole.contains("Receipt ingestion"))

        // A narrowed screen exports a narrowed document: the user filtered on purpose.
        model.typeFilter = .decisionMade
        let filtered = model.markdown(projects: PreviewFixtures.projects)
        #expect(filtered.contains("Chose Postgres"))
        #expect(filtered.contains("Opened the dedup PR") == false)
    }

    @Test("The suggested file name names the range being exported")
    func exportFileNameNamesTheRange() async {
        let (model, _) = model([entry(1, title: "Opened the dedup PR", at: day(0))])

        await model.load()

        #expect(model.suggestedExportFileName.hasPrefix("Accomplishments-"))
        #expect(model.suggestedExportFileName.hasSuffix(".md"))
        #expect(model.suggestedExportFileName.contains("2024"))
    }

    // MARK: Applying changes

    @Test("An entry saved elsewhere lands in the range it belongs to, and only once")
    func applyUpsertsIntoTheRange() async {
        let (model, _) = model([entry(1, title: "Opened the dedup PR", at: day(0, hour: 9))])

        await model.load()
        #expect(model.accomplishments.count == 1)

        var edited = entry(1, title: "Opened the deduplication PR", at: day(0, hour: 9))
        model.apply(edited)
        #expect(model.accomplishments.count == 1)
        #expect(model.accomplishments.first?.title == "Opened the deduplication PR")

        model.apply(entry(2, title: "Chose Postgres", at: day(0, hour: 14)))
        #expect(model.accomplishments.count == 2)
        // Newest first is maintained without a reload.
        #expect(model.accomplishments.first?.title == "Chose Postgres")

        // An entry outside the range is not smuggled in.
        model.apply(entry(3, title: "December", at: day(-20)))
        #expect(model.accomplishments.count == 2)

        edited.title = "Untouched"
        model.remove(id: edited.id)
        #expect(model.accomplishments.map(\.title) == ["Chose Postgres"])
    }
}
