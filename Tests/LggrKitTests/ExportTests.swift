import Foundation
import Testing

@testable import LggrKit

/// A rendered document always ends with exactly one newline, which a Swift multiline literal does not
/// carry. Adding it here rather than in each fixture keeps the fixtures readable and keeps the
/// "exactly one trailing newline" rule asserted by every exact-output test rather than by one.
private func document(_ body: String) -> String { body + "\n" }

/// The bullet texts under a heading, without their "- ".
private func bullets(after heading: String, in document: String) -> [String] {
    let lines = document.components(separatedBy: "\n")
    guard let index = lines.firstIndex(of: heading) else { return [] }
    var result: [String] = []
    for line in lines[(index + 1)...] {
        if line.hasPrefix("- ") {
            result.append(String(line.dropFirst(2)))
            continue
        }
        if result.isEmpty, line.isEmpty { continue }
        break
    }
    return result
}

/// The integer before the first `%` in each item.
private func percentages(_ items: [String]) -> [Int] {
    items.compactMap { item in
        guard let marker = item.range(of: "%") else { return nil }
        let digits = item[..<marker.lowerBound].reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits))
    }
}

// MARK: - Text

@Suite("Markdown text")
struct MarkdownTextTests {

    @Test("structural characters are escaped so user text cannot restructure a document")
    func escapesStructuralCharacters() {
        let rendered = MarkdownText.inline("Ship *the* `thing` | [now](x) <b>")
        #expect(rendered == "Ship \\*the\\* \\`thing\\` \\| \\[now\\](x) \\<b\\>")
    }

    @Test("newlines and runs of whitespace collapse to single spaces")
    func flattensWhitespace() {
        #expect(MarkdownText.inline("  first\n\n\tsecond   third \n") == "first second third")
    }

    /// A bullet's content is a block container of its own, so `- ## Shipped` really does produce a
    /// heading inside the list item. Both places have to be escaped; the middle of a line must not be.
    @Test("a marker that would open a block is escaped wherever the text begins one")
    func escapesLeaders() {
        var document = MarkdownDocument()
        document.paragraph(MarkdownText.inline("- not a bullet"))
        document.list([
            MarkdownText.inline("## not a heading"),
            MarkdownText.inline("well-known trade-offs"),
        ])
        #expect(
            document.rendered()
                == "\\- not a bullet\n\n- \\## not a heading\n- well-known trade-offs\n"
        )
    }

    @Test("an ordered-list leader is escaped, a date is not")
    func escapesOrderedListLeader() {
        var document = MarkdownDocument()
        document.paragraph("1. first")
        document.paragraph("2024-01-15 to 2024-01-21")
        #expect(document.rendered() == "\\1. first\n\n2024-01-15 to 2024-01-21\n")
    }

    /// A marker only means something with a break after it. Escaping on the first character alone puts
    /// a visible backslash into prose, which is the defect this escaping exists to avoid.
    @Test("prose that merely starts with a digit, a hash or a hyphen keeps its first character")
    func doesNotEscapeOrdinaryProse() {
        var document = MarkdownDocument()
        document.list(["5.1 hours invested", "#1 priority", "-fix the thing", "10) of 12"])
        #expect(
            document.rendered()
                == "- 5.1 hours invested\n- #1 priority\n- -fix the thing\n- \\10) of 12\n"
        )
    }

    @Test("seven hashes are not a heading and are left alone")
    func sevenHashesAreNotAHeading() {
        var document = MarkdownDocument()
        document.paragraph("####### seven")
        document.paragraph("###### six")
        #expect(document.rendered() == "####### seven\n\n\\###### six\n")
    }

    @Test("text that is only whitespace renders as nothing rather than as an empty bullet")
    func dropsEmptyText() {
        #expect(MarkdownText.inline("   \n  ").isEmpty)
        #expect(MarkdownText.optional("   ") == nil)
        #expect(MarkdownText.optional(nil) == nil)

        var document = MarkdownDocument()
        document.section("Accomplishments", items: ["", "   "])
        #expect(document.rendered().isEmpty)
    }

    @Test("an empty document is empty, not a lone newline")
    func emptyDocumentIsEmpty() {
        #expect(MarkdownDocument().rendered().isEmpty)
    }

    @Test("blocks are separated by exactly one blank line")
    func blockSpacing() {
        var document = MarkdownDocument()
        document.heading("Title", level: 1)
        document.paragraph("Body")
        document.list(["one", "two"])
        #expect(document.rendered() == "# Title\n\nBody\n\n- one\n- two\n")
    }
}

// MARK: - Percentages

@Suite("Percentage allocation")
struct PercentageAllocationTests {

    @Test("percentages add up to 100")
    func sumsToOneHundred() {
        let shares = PercentageAllocation.percentages(of: [
            exportMinutes(31), exportMinutes(22), exportMinutes(19), exportMinutes(14),
            exportMinutes(9), exportMinutes(5),
        ])
        #expect(shares.reduce(0, +) == 100)
    }

    @Test("three equal thirds are apportioned rather than each rounded to 33")
    func equalThirds() {
        let shares = PercentageAllocation.percentages(of: [60, 60, 60])
        #expect(shares == [34, 33, 33])
        #expect(shares.reduce(0, +) == 100)
    }

    @Test("a single duration is the whole of it")
    func singleWeight() {
        #expect(PercentageAllocation.percentages(of: [42]) == [100])
    }

    @Test("a zero duration gets 0% and never collects a rounding point")
    func zeroWeightsStayZero() {
        let shares = PercentageAllocation.percentages(of: [60, 60, 60, 0, 0])
        #expect(shares == [34, 33, 33, 0, 0])
    }

    @Test("no duration at all yields no percentages rather than a division by zero")
    func noWeights() {
        #expect(PercentageAllocation.percentages(of: [0, 0]) == [0, 0])
        #expect(PercentageAllocation.percentages(of: []) == [])
    }

    @Test("a non-finite duration is treated as none")
    func nonFiniteWeights() {
        let shares = PercentageAllocation.percentages(of: [.nan, .infinity, 60])
        #expect(shares == [0, 0, 100])
    }

    @Test("seven ninths of an hour still sum to 100")
    func sevenWaySplit() {
        let shares = PercentageAllocation.percentages(of: Array(repeating: 60, count: 7))
        #expect(shares.reduce(0, +) == 100)
        #expect(shares == [15, 15, 14, 14, 14, 14, 14])
    }
}

// MARK: - Formatter

@Suite("Export formatter")
struct ExportFormatterTests {

    @Test("dates and times are ISO and 24-hour, with no locale anywhere in them")
    func fixedFormats() {
        let date = exportDate(day: 0, 9, 4)
        #expect(exportFormatter.isoDate(date) == "2024-01-15")
        #expect(exportFormatter.time(date) == "09:04")
        #expect(exportFormatter.weekdayName(date) == "Monday")
        #expect(exportFormatter.longDate(date) == "Monday, 15 January 2024")
        #expect(
            exportFormatter.timeRange(from: date, to: exportDate(day: 0, 9, 58)) == "09:04–09:58"
        )
    }

    @Test("month and weekday names do not follow the calendar's locale")
    func namesAreFrozen() {
        var french = Calendar(identifier: .gregorian)
        french.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        french.locale = Locale(identifier: "fr_FR")
        let formatter = ExportFormatter(calendar: french)
        #expect(formatter.longDate(exportWeekStart) == "Monday, 15 January 2024")
    }

    @Test("a range names the last day of the interval, not its exclusive bound")
    func rangeUsesLastDay() {
        #expect(exportFormatter.dateRange(exportWeek) == "2024-01-15 to 2024-01-21")
        #expect(exportFormatter.dateRange(ExportFixture.monday) == "2024-01-15")
    }

    @Test("a CSV timestamp carries its offset")
    func timestampCarriesOffset() {
        #expect(exportFormatter.timestamp(exportDate(day: 0, 9)) == "2024-01-15T09:00:00+0000")

        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .gmt
        #expect(
            ExportFormatter(calendar: berlin).timestamp(exportDate(day: 0, 9))
                == "2024-01-15T10:00:00+0100"
        )
    }
}

// MARK: - Weekly review

@Suite("Weekly review Markdown")
struct WeeklyReviewMarkdownTests {

    /// The structure `SPEC.md`'s Export section specifies, byte for byte.
    @Test("the week renders exactly")
    func exactOutput() {
        let expected = document(
            """
            # Weekly Work Review

            2024-01-15 to 2024-01-21

            ## Primary outcome

            Improve receipt ingestion reliability

            - 5 focus sessions
            - 5.1 hours invested
            - 58% of tracked time
            - 2 pull requests opened
            - 1 incident resolved
            - 1 document written
            - Status: In progress

            ## Other outcomes

            - Reduce alert noise · Secondary · Blocked · 2 sessions · 1h 45m
            - Team support · Operational · Achieved

            ## Time allocation

            ### By project

            - SOR engineering: 57% (5h 5m)
            - No project: 23% (2h)
            - Alert noise: 20% (1h 45m)

            ### By work type

            - Deep work: 49% (4h 20m)
            - Code review: 20% (1h 45m)
            - Incident: 11% (1h)
            - Planning: 8% (45m)
            - Communication: 6% (30m)
            - Meeting: 6% (30m)

            ## Planned versus reactive

            - Committed: 66% (5h 50m, 6 sessions)
            - Chosen: 11% (1h, 1 session)
            - Arrived: 23% (2h, 3 sessions)

            ## Focus sessions

            - 10 finished sessions
            - 8h 50m tracked
            - 7 reported as completed
            - 1 reported as interrupted
            - 2 recorded an interruption while running

            ## By day

            | Day | Tracked | Sessions | Context switches |
            | --- | --- | --- | --- |
            | Monday | 1h 50m | 2 | 4 |
            | Tuesday | 1h 45m | 2 | 0 |
            | Wednesday | 2h 30m | 2 | 0 |
            | Thursday | 1h 30m | 2 | 0 |
            | Friday | 1h 15m | 2 | 0 |

            ## Support work

            - 2h 45m across 3 sessions of code review, management and incident work
            - 1 person unblocked
            - 1 pull request reviewed

            ## Interruption sources

            - Message: 3
            - Incident: 1
            - Person: 1

            ## Accomplishments

            - Documented the new ingestion architecture
            - Resolved duplicate commission ingestion
            - Opened the retry backoff PR
            - Opened the receipt deduplication PR
            - Unblocked two engineers
            - Reviewed three blocking pull requests

            ## Observations

            - Work that arrived rather than being chosen accounted for 23% of tracked time, across 3 of 10 sessions.
            - The primary weekly outcome received 58% of tracked time, across 5 sessions.
            - Code review, management and incident work accounted for 2.8 hours across 3 sessions.
            - Your 3 longest sessions all started before 09:30.
            """
        )
        #expect(
            WeeklyReviewMarkdown.render(ExportFixture.review, formatter: exportFormatter) == expected
        )
    }

    @Test("the primary outcome carries its session count, hours, pull requests and status")
    func primaryOutcomeSection() {
        let rendered = WeeklyReviewMarkdown.render(
            ExportFixture.review,
            formatter: exportFormatter
        )
        // The bullets sit under the outcome's own title, which is the paragraph after the heading.
        let items = bullets(after: "Improve receipt ingestion reliability", in: rendered)
        #expect(items.contains("5 focus sessions"))
        #expect(items.contains("5.1 hours invested"))
        #expect(items.contains("2 pull requests opened"))
        #expect(items.contains("Status: In progress"))
    }

    @Test("a week with no primary outcome omits the section rather than heading an empty one")
    func withoutPrimaryOutcome() {
        var input = ExportFixture.weeklyInput
        input.outcomes = WeeklyOutcomeSet(weekStart: exportWeekStart)
        let rendered = WeeklyReviewMarkdown.render(
            WeeklyReviewBuilder.build(input),
            formatter: exportFormatter
        )
        #expect(!rendered.contains("## Primary outcome"))
        #expect(!rendered.contains("## Other outcomes"))
        #expect(rendered.contains("## Time allocation"))
    }

    @Test("every time-allocation list adds up to 100%")
    func allocationsSumToOneHundred() {
        let rendered = WeeklyReviewMarkdown.render(
            ExportFixture.review,
            formatter: exportFormatter
        )
        for heading in ["### By project", "### By work type"] {
            let shares = percentages(bullets(after: heading, in: rendered))
            #expect(!shares.isEmpty)
            #expect(shares.reduce(0, +) == 100)
        }
    }

    @Test("a limited allocation folds its tail into Other and still adds up to 100%")
    func allocationLimitFoldsIntoOther() {
        let rendered = WeeklyReviewMarkdown.render(
            ExportFixture.review,
            formatter: exportFormatter,
            options: .init(allocationLimit: 2)
        )
        let items = bullets(after: "### By work type", in: rendered)
        #expect(items.count == 3)
        #expect(items[2].hasPrefix("Other: "))
        #expect(percentages(items).reduce(0, +) == 100)
    }

    @Test("observations are the generator's sentences, rendered verbatim")
    func observationsComeFromTheGenerator() {
        let review = ExportFixture.review
        let rendered = WeeklyReviewMarkdown.render(review, formatter: exportFormatter)
        let expected = InsightGenerator.observations(for: review).map(\.text)
        #expect(!expected.isEmpty)
        #expect(bullets(after: "## Observations", in: rendered) == expected)
    }

    @Test("supplied observations replace the generated ones")
    func suppliedObservations() {
        let rendered = WeeklyReviewMarkdown.render(
            ExportFixture.review,
            observations: [
                WeeklyObservation(kind: .plannedSplit, text: "A measured fact.", evidence: "x")
            ],
            formatter: exportFormatter
        )
        #expect(bullets(after: "## Observations", in: rendered) == ["A measured fact."])
    }

    @Test("Markdown in an outcome title cannot restructure the review")
    func hostileOutcomeTitle() {
        var input = ExportFixture.weeklyInput
        input.outcomes = WeeklyOutcomeSet(
            weekStart: exportWeekStart,
            outcomes: [
                WeeklyOutcome(
                    id: ExportFixture.primaryOutcomeID,
                    title: "## Shipped everything\n| a | b |",
                    priority: .primary,
                    status: .achieved,
                    weekStartDate: exportWeekStart
                )
            ]
        )
        let rendered = WeeklyReviewMarkdown.render(
            WeeklyReviewBuilder.build(input),
            formatter: exportFormatter
        )
        #expect(rendered.contains("\n\\## Shipped everything \\| a \\| b \\|\n"))
        let headings = rendered.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(!headings.contains("## Shipped everything"))
    }

    @Test("an empty week says so once, and neutrally")
    func emptyWeek() {
        let review = WeeklyReviewBuilder.build(
            WeeklyReviewInput(week: exportWeek, calendar: exportCalendar)
        )
        let rendered = WeeklyReviewMarkdown.render(review, formatter: exportFormatter)
        #expect(
            rendered == document(
                """
                # Weekly Work Review

                2024-01-15 to 2024-01-21

                No sessions, accomplishments or tracked activity were recorded for this week.
                """
            )
        )
    }

    @Test("the same week renders to the same bytes twice")
    func deterministic() {
        let review = ExportFixture.review
        let first = WeeklyReviewMarkdown.render(review, formatter: exportFormatter)
        let second = WeeklyReviewMarkdown.render(
            WeeklyReviewBuilder.build(ExportFixture.weeklyInput),
            formatter: exportFormatter
        )
        #expect(first == second)
    }

    @Test("no stray whitespace anywhere in the document")
    func noStrayWhitespace() {
        let rendered = WeeklyReviewMarkdown.render(
            ExportFixture.review,
            formatter: exportFormatter
        )
        #expect(rendered.hasSuffix("\n"))
        #expect(!rendered.hasSuffix("\n\n"))
        #expect(!rendered.contains("\n\n\n"))
        #expect(!rendered.contains(" \n"))
        #expect(!rendered.contains("\t"))
        #expect(!rendered.contains("- \n"))
    }
}

// MARK: - Daily summary

@Suite("Daily summary Markdown")
struct DailySummaryMarkdownTests {

    @Test("the day renders exactly")
    func exactOutput() {
        let expected = document(
            """
            # Daily summary — Monday, 15 January 2024

            ## Summary

            - 2 focus sessions
            - 1h 50m tracked

            ## Focus sessions

            - 09:00–10:00 · Deduplicate receipt rows · SOR engineering · Deep work · 1h · Completed
              - Result: Deduplication query rewritten
              - Next: Backfill the affected month
            - 10:30–11:20 · Add the ingestion regression test · SOR engineering · Deep work · 50m · Completed

            ## Time allocation

            - Deep work: 100% (1h 50m)

            ## Accomplishments

            - Opened the receipt deduplication PR
            - Opened the retry backoff PR

            ## Interruptions

            - Message: 1

            ## Timeline

            - 09:00–10:00 · Deduplicate receipt rows · Xcode, Slack · 58m
            - 10:00–11:00 · Idle · 1h
            - 11:00–11:45 · Xcode · 40m
            - 13:00–14:00 · Lggr was not running · 1h
            - 14:00–14:30 · Slack · 25m
            - 15:00–15:20 · Private activity · 18m
            """
        )
        #expect(
            DailySummaryMarkdown.render(
                ExportFixture.dailyInput,
                formatter: exportFormatter,
                redactor: ExportFixture.redactor
            ) == expected
        )
    }

    @Test("a day with nothing on it says so once, and neutrally")
    func emptyDay() {
        let rendered = DailySummaryMarkdown.render(
            DailySummaryInput(day: ExportFixture.monday),
            formatter: exportFormatter
        )
        #expect(
            rendered == document(
                """
                # Daily summary — Monday, 15 January 2024

                No sessions, accomplishments or tracked activity were recorded.
                """
            )
        )
    }

    @Test("a running session shows its start and no duration, because it has none yet")
    func unfinishedSession() {
        let input = DailySummaryInput(
            day: ExportFixture.monday,
            sessions: [
                ExportFixture.session(
                    "81",
                    day: 0,
                    hour: 16,
                    length: 50,
                    outcome: "Rework the retry path",
                    finished: false
                )
            ]
        )
        let items = bullets(
            after: "## Focus sessions",
            in: DailySummaryMarkdown.render(input, formatter: exportFormatter)
        )
        #expect(items == ["16:00 · Rework the retry path · Deep work · In progress"])
    }

    @Test("session detail can be left out for a shorter note")
    func detailIsOptional() {
        let rendered = DailySummaryMarkdown.render(
            ExportFixture.dailyInput,
            formatter: exportFormatter,
            redactor: ExportFixture.redactor,
            options: .init(includeSessionDetail: false, includeTimeline: false)
        )
        #expect(!rendered.contains("Result: Deduplication query rewritten"))
        #expect(!rendered.contains("## Timeline"))
    }

    @Test("time allocation adds up to 100%")
    func allocationSumsToOneHundred() {
        var input = ExportFixture.dailyInput
        input.sessions = ExportFixture.sessions
        input.day = DateInterval(
            start: exportWeekStart,
            end: exportWeekStart.addingTimeInterval(7 * 86_400)
        )
        let rendered = DailySummaryMarkdown.render(input, formatter: exportFormatter)
        let shares = percentages(bullets(after: "## Time allocation", in: rendered))
        #expect(shares.count == 6)
        #expect(shares.reduce(0, +) == 100)
    }

    @Test("a gap shorter than the floor is not a line in the timeline")
    func shortGapsAreOmitted() {
        let rendered = DailySummaryMarkdown.render(
            ExportFixture.dailyInput,
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(!rendered.contains("12:00–12:02"))
        #expect(rendered.contains("10:00–11:00 · Idle · 1h"))
    }

    @Test("a block named by the user keeps its name; a block named from apps does not")
    func onlyUserAuthoredLabelsAreQuoted() {
        let rendered = DailySummaryMarkdown.render(
            ExportFixture.dailyInput,
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        let items = bullets(after: "## Timeline", in: rendered)
        #expect(items.contains("09:00–10:00 · Deduplicate receipt rows · Xcode, Slack · 58m"))
        #expect(items.contains("11:00–11:45 · Xcode · 40m"))
    }

    @Test("no stray whitespace anywhere in the document")
    func noStrayWhitespace() {
        let rendered = DailySummaryMarkdown.render(
            ExportFixture.dailyInput,
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(rendered.hasSuffix("\n"))
        #expect(!rendered.hasSuffix("\n\n"))
        #expect(!rendered.contains("\n\n\n"))
        #expect(!rendered.contains(" \n"))
        #expect(!rendered.contains("\t"))
    }
}

// MARK: - Accomplishment log

@Suite("Accomplishment log Markdown")
struct AccomplishmentLogMarkdownTests {

    @Test("the log renders exactly, grouped by day")
    func exactOutput() {
        let expected = document(
            """
            # Accomplishment log

            2024-01-15 to 2024-01-21

            - 6 accomplishments
            - 2 pull requests opened
            - 1 pull request reviewed
            - 1 person unblocked
            - 1 incident resolved
            - 1 document written

            ## Friday, 19 January 2024

            - Documented the new ingestion architecture · Document written · SOR engineering · Improve receipt ingestion reliability

            ## Thursday, 18 January 2024

            - Unblocked two engineers · Person unblocked

            ## Wednesday, 17 January 2024

            - Reviewed three blocking pull requests · Pull request reviewed

            ## Tuesday, 16 January 2024

            - Resolved duplicate commission ingestion · Incident resolved · SOR engineering · Improve receipt ingestion reliability

            ## Monday, 15 January 2024

            - Opened the retry backoff PR · Pull request opened · SOR engineering · Improve receipt ingestion reliability
            - Opened the receipt deduplication PR · Pull request opened · SOR engineering · Improve receipt ingestion reliability
              - Splits the ingestion writer from the reconciliation pass.
            """
        )
        #expect(
            AccomplishmentLogMarkdown.render(ExportFixture.logInput, formatter: exportFormatter)
                == expected
        )
    }

    @Test("grouping by type follows the declaration order, not the count")
    func groupedByType() {
        let rendered = AccomplishmentLogMarkdown.render(
            ExportFixture.logInput,
            formatter: exportFormatter,
            options: .init(grouping: .type, includeDetails: false, includeSummary: false)
        )
        let headings = rendered.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(
            headings == [
                "## Pull request opened",
                "## Pull request reviewed",
                "## Person unblocked",
                "## Incident resolved",
                "## Document written",
            ]
        )
    }

    @Test("grouping by project sorts by name and puts unfiled work last")
    func groupedByProject() {
        let rendered = AccomplishmentLogMarkdown.render(
            ExportFixture.logInput,
            formatter: exportFormatter,
            options: .init(grouping: .project, includeSummary: false)
        )
        let headings = rendered.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }
        #expect(headings == ["## SOR engineering", "## No project"])
    }

    @Test("the user's own note renders as an indented bullet, and can be left out")
    func detailsAreOptional() {
        let withDetails = AccomplishmentLogMarkdown.render(
            ExportFixture.logInput,
            formatter: exportFormatter
        )
        #expect(
            withDetails.contains(
                "\n  - Splits the ingestion writer from the reconciliation pass."
            )
        )

        let without = AccomplishmentLogMarkdown.render(
            ExportFixture.logInput,
            formatter: exportFormatter,
            options: .init(includeDetails: false)
        )
        #expect(!without.contains("Splits the ingestion writer"))
    }

    @Test("Markdown in a title cannot add a heading, a table or a bullet to the document")
    func titlesCannotRestructureTheDocument() {
        let hostile = ExportFixture.accomplishment(
            "91",
            day: 0,
            hour: 8,
            type: .other,
            title: "## Promoted\n\n| a | b |\n- extra bullet",
            details: "line one\nline two"
        )
        let rendered = AccomplishmentLogMarkdown.render(
            AccomplishmentLogInput(interval: exportWeek, accomplishments: [hostile]),
            formatter: exportFormatter,
            options: .init(includeSummary: false)
        )
        #expect(
            rendered == document(
                """
                # Accomplishment log

                2024-01-15 to 2024-01-21

                ## Monday, 15 January 2024

                - \\## Promoted \\| a \\| b \\| - extra bullet · Other
                  - line one line two
                """
            )
        )
    }

    @Test("an empty log says so once, and neutrally")
    func emptyLog() {
        let rendered = AccomplishmentLogMarkdown.render(
            AccomplishmentLogInput(interval: exportWeek),
            formatter: exportFormatter
        )
        #expect(
            rendered == document(
                """
                # Accomplishment log

                2024-01-15 to 2024-01-21

                No accomplishments were recorded.
                """
            )
        )
    }

    @Test("an accomplishment outside the window is not in the log")
    func filtersToTheWindow() {
        let outside = ExportFixture.accomplishment(
            "92",
            day: 9,
            hour: 10,
            type: .other,
            title: "Next week's work"
        )
        var input = ExportFixture.logInput
        input.accomplishments.append(outside)
        let rendered = AccomplishmentLogMarkdown.render(input, formatter: exportFormatter)
        #expect(!rendered.contains("Next week's work"))
        #expect(rendered.contains("- 6 accomplishments"))
    }
}

// MARK: - CSV

@Suite("Sessions CSV")
struct SessionsCSVTests {

    @Test("the header is the documented column list")
    func header() {
        let rendered = SessionsCSVExporter.render(
            SessionsCSVInput(),
            formatter: exportFormatter
        )
        #expect(
            rendered == "Started,Ended,Duration (minutes),Paused (minutes),Project,"
                + "Weekly outcome,Work type,Origin,Result,Intended outcome,Summary,"
                + "Tangible result,Blocker,Next step,Interruptions,Session ID\r\n"
        )
    }

    @Test("the week renders exactly")
    func exactOutput() {
        let expected = [
            "Started,Ended,Duration (minutes),Paused (minutes),Project,Weekly outcome,Work type,Origin,Result,Intended outcome,Summary,Tangible result,Blocker,Next step,Interruptions,Session ID",
            "2024-01-15T09:00:00+0000,2024-01-15T10:00:00+0000,60.0,0.0,SOR engineering,Improve receipt ingestion reliability,Deep work,Committed,Completed,Deduplicate receipt rows,,Deduplication query rewritten,,Backfill the affected month,1,00000000-0000-0000-0000-000000000031",
            "2024-01-15T10:30:00+0000,2024-01-15T11:20:00+0000,50.0,0.0,SOR engineering,Improve receipt ingestion reliability,Deep work,Committed,Completed,Add the ingestion regression test,,,,,0,00000000-0000-0000-0000-000000000032",
            "2024-01-16T09:00:00+0000,2024-01-16T10:00:00+0000,60.0,0.0,SOR engineering,Improve receipt ingestion reliability,Deep work,Committed,Made progress,Trace the duplicate commission rows,,,,,0,00000000-0000-0000-0000-000000000033",
            "2024-01-16T14:00:00+0000,2024-01-16T14:45:00+0000,45.0,0.0,SOR engineering,Improve receipt ingestion reliability,Code review,Committed,Completed,Review the ingestion PR,,,,,0,00000000-0000-0000-0000-000000000034",
            "2024-01-17T09:00:00+0000,2024-01-17T10:30:00+0000,90.0,0.0,SOR engineering,Improve receipt ingestion reliability,Deep work,Committed,Interrupted,Rework the retry path,,,Waiting on the vendor sandbox,,2,00000000-0000-0000-0000-000000000035",
            "2024-01-17T13:00:00+0000,2024-01-17T14:00:00+0000,60.0,0.0,,,Code review,Chosen,Completed,Review two blocking pull requests,,,,,0,00000000-0000-0000-0000-000000000036",
            "2024-01-18T09:00:00+0000,2024-01-18T09:30:00+0000,30.0,0.0,,,Communication,Arrived,Completed,Answer the ingestion questions,,,,,0,00000000-0000-0000-0000-000000000037",
            "2024-01-18T11:00:00+0000,2024-01-18T12:00:00+0000,60.0,0.0,Alert noise,Reduce alert noise,Incident,Arrived,Completed,Page volume from the alerting rules,,,,,0,00000000-0000-0000-0000-000000000038",
            "2024-01-19T09:00:00+0000,2024-01-19T09:45:00+0000,45.0,0.0,Alert noise,Reduce alert noise,Planning,Committed,Made progress,Draft the alerting thresholds,,,,,0,00000000-0000-0000-0000-000000000039",
            "2024-01-19T15:00:00+0000,2024-01-19T15:30:00+0000,30.0,0.0,,,Meeting,Arrived,Completed,Ingestion design review,,,,,0,00000000-0000-0000-0000-00000000003A",
        ].joined(separator: "\r\n") + "\r\n"
        #expect(
            SessionsCSVExporter.render(ExportFixture.csvInput, formatter: exportFormatter)
                == expected
        )
    }

    @Test("a field containing a comma is quoted")
    func quotesCommas() {
        #expect(CSVEscaping.field("Shipped ingestion, then reviewed") == "\"Shipped ingestion, then reviewed\"")
    }

    @Test("a field containing a double quote doubles it")
    func doublesQuotes() {
        #expect(CSVEscaping.field("Fixed the \"duplicate\" bug") == "\"Fixed the \"\"duplicate\"\" bug\"")
    }

    @Test("a field containing a newline is quoted and keeps the newline")
    func quotesNewlines() {
        #expect(CSVEscaping.field("first line\nsecond line") == "\"first line\nsecond line\"")
        #expect(CSVEscaping.field("carriage\rreturn") == "\"carriage\rreturn\"")
    }

    @Test("a comma, a quote and a newline together survive one round trip")
    func allThreeAtOnce() {
        let outcome = "Ship \"phase 2\", then:\nwrite the review"
        let field = CSVEscaping.field(outcome)
        #expect(field == "\"Ship \"\"phase 2\"\", then:\nwrite the review\"")
        // Unquote the way a reader does, and the user's sentence comes back unchanged.
        let inner = field.dropFirst().dropLast()
        #expect(String(inner).replacingOccurrences(of: "\"\"", with: "\"") == outcome)
    }

    @Test("all three inside a real session row keep the row parseable")
    func hostileSessionRow() {
        let session = ExportFixture.session(
            "a1",
            day: 0,
            hour: 9,
            length: 30,
            outcome: "Ship \"phase 2\", then:\nwrite the review"
        )
        let rendered = SessionsCSVExporter.render(
            SessionsCSVInput(sessions: [session]),
            formatter: exportFormatter,
            options: .init(includeHeader: false)
        )
        #expect(
            rendered == "2024-01-15T09:00:00+0000,2024-01-15T09:30:00+0000,30.0,0.0,,,"
                + "Deep work,Chosen,Completed,"
                + "\"Ship \"\"phase 2\"\", then:\nwrite the review\",,,,,0,"
                + "00000000-0000-0000-0000-0000000000A1\r\n"
        )
    }

    @Test("leading and trailing spaces are preserved by quoting")
    func preservesEdgeWhitespace() {
        #expect(CSVEscaping.field(" padded ") == "\" padded \"")
    }

    @Test("a field that would be read as a formula is neutralized, and a hyphen is left alone")
    func neutralizesFormulaPrefixes() {
        #expect(CSVEscaping.field("=1+1") == "'=1+1")
        #expect(CSVEscaping.field("+SUM(A1)") == "'+SUM(A1)")
        #expect(CSVEscaping.field("@import") == "'@import")
        #expect(CSVEscaping.field("- fix the thing") == "- fix the thing")
        #expect(CSVEscaping.field("=1+1", neutralizeFormulaPrefix: false) == "=1+1")
    }

    @Test("a running session leaves its duration empty rather than reporting zero")
    func unfinishedSessionHasNoDuration() {
        let session = ExportFixture.session(
            "a2",
            day: 0,
            hour: 9,
            length: 30,
            outcome: "Still going",
            finished: false
        )
        let rendered = SessionsCSVExporter.render(
            SessionsCSVInput(sessions: [session]),
            formatter: exportFormatter,
            options: .init(includeHeader: false)
        )
        #expect(rendered.hasPrefix("2024-01-15T09:00:00+0000,,,0.0,"))
    }

    @Test("rows are chronological, oldest first")
    func chronologicalOrder() {
        let rendered = SessionsCSVExporter.render(
            ExportFixture.csvInput,
            formatter: exportFormatter,
            options: .init(includeHeader: false)
        )
        let starts = rendered
            .components(separatedBy: "\r\n")
            .filter { !$0.isEmpty }
            .compactMap { $0.components(separatedBy: ",").first }
        #expect(starts == starts.sorted())
    }

    @Test("no sessions and no header is an empty file, not a blank line")
    func emptyFile() {
        #expect(
            SessionsCSVExporter.render(
                SessionsCSVInput(),
                formatter: exportFormatter,
                options: .init(includeHeader: false)
            ).isEmpty
        )
    }
}

// MARK: - Privacy

/// The export is the most likely thing to be shared, so it is the most dangerous place for a leak.
/// Every assertion here runs against input that *contains* the thing that must not come out.
@Suite("Export privacy")
struct ExportPrivacyTests {

    /// Every document the feature can produce, from a fixture holding a private application, an
    /// excluded one, and interruption notes naming three colleagues.
    private var allDocuments: [String] {
        [
            WeeklyReviewMarkdown.render(ExportFixture.review, formatter: exportFormatter),
            DailySummaryMarkdown.render(
                ExportFixture.dailyInput,
                formatter: exportFormatter,
                redactor: ExportFixture.redactor
            ),
            AccomplishmentLogMarkdown.render(ExportFixture.logInput, formatter: exportFormatter),
            SessionsCSVExporter.render(ExportFixture.csvInput, formatter: exportFormatter),
        ]
    }

    @Test("an excluded application is absent entirely — its name, and its time")
    func excludedApplicationIsAbsent() {
        for rendered in allDocuments {
            #expect(!rendered.contains(ExportFixture.bankingName))
            #expect(!rendered.contains(ExportFixture.bankingBundle))
            // The block was 16:00–16:25. Neither the block nor its duration may be inferable.
            #expect(!rendered.contains("16:00–16:25"))
        }
    }

    @Test("a private application keeps its time and loses its identity")
    func privateApplicationIsRedacted() {
        let daily = DailySummaryMarkdown.render(
            ExportFixture.dailyInput,
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(daily.contains("15:00–15:20 · Private activity · 18m"))
        #expect(!daily.contains(ExportFixture.journalName))
        #expect(!daily.contains(ExportFixture.journalBundle))
    }

    @Test("no bundle identifier reaches any document, including the redaction sentinel")
    func noBundleIdentifiers() {
        for rendered in allDocuments {
            #expect(!rendered.contains(PrivacyRedactor.privateBundleIdentifier))
            #expect(!rendered.contains("com."))
            #expect(!rendered.contains(ExportFixture.xcodeBundle))
            #expect(!rendered.contains(ExportFixture.slackBundle))
        }
    }

    @Test("the weekly review names no application at all")
    func weeklyReviewNamesNoApplication() {
        let rendered = WeeklyReviewMarkdown.render(
            ExportFixture.review,
            formatter: exportFormatter
        )
        #expect(!rendered.contains("Xcode"))
        #expect(!rendered.contains("Slack"))
    }

    @Test("an interruption note about a named colleague never leaves the app")
    func interruptionNotesStayInTheApp() {
        for rendered in allDocuments {
            #expect(!rendered.contains("Priya"))
            #expect(!rendered.contains("Marcus"))
            #expect(!rendered.contains("Dana"))
        }
        // The aggregate is what ships instead.
        let daily = DailySummaryMarkdown.render(
            ExportFixture.dailyInput,
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(daily.contains("Message: 1"))
    }

    @Test("a window title handed to the exporter as a block label is not repeated")
    func titleDerivedLabelsAreNotQuoted() {
        // `.identifier` is the confidence a title-derived name would carry. Nothing may print it.
        let titled = ExportFixture.episode(
            "b1",
            day: 0,
            hour: 9,
            length: 30,
            apps: [ExportFixture.share(ExportFixture.xcodeBundle, "Xcode", 28)],
            label: "Kaiser Permanente — Your test results",
            confidence: .identifier
        )
        let rendered = DailySummaryMarkdown.render(
            DailySummaryInput(
                day: ExportFixture.monday,
                timeline: DayTimeline(dayStart: exportWeekStart, episodes: [titled], gaps: [])
            ),
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(!rendered.contains("Kaiser"))
        #expect(rendered.contains("09:00–09:30 · Xcode · 28m"))
    }

    @Test("a block whose every application is excluded is not a line at all")
    func fullyExcludedBlockDisappears() {
        let rendered = DailySummaryMarkdown.render(
            DailySummaryInput(
                day: ExportFixture.monday,
                timeline: DayTimeline(
                    dayStart: exportWeekStart,
                    episodes: [
                        ExportFixture.episode(
                            "b2",
                            day: 0,
                            hour: 16,
                            length: 25,
                            apps: [
                                ExportFixture.share(
                                    ExportFixture.bankingBundle,
                                    ExportFixture.bankingName,
                                    22
                                )
                            ],
                            label: ExportFixture.bankingName
                        )
                    ],
                    gaps: []
                )
            ),
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(!rendered.contains("## Timeline"))
        #expect(rendered.contains("No sessions, accomplishments or tracked activity were recorded."))
    }

    @Test("an excluded application inside a mixed block loses its name and its share")
    func partiallyExcludedBlockKeepsOnlyWhatMayBeNamed() {
        let mixed = ExportFixture.episode(
            "b3",
            day: 0,
            hour: 9,
            length: 60,
            apps: [
                ExportFixture.share(ExportFixture.xcodeBundle, "Xcode", 30),
                ExportFixture.share(
                    ExportFixture.bankingBundle,
                    ExportFixture.bankingName,
                    20
                ),
            ],
            label: "Xcode"
        )
        let rendered = DailySummaryMarkdown.render(
            DailySummaryInput(
                day: ExportFixture.monday,
                timeline: DayTimeline(dayStart: exportWeekStart, episodes: [mixed], gaps: [])
            ),
            formatter: exportFormatter,
            redactor: ExportFixture.redactor
        )
        #expect(bullets(after: "## Timeline", in: rendered) == ["09:00–10:00 · Xcode · 30m"])
    }
}
