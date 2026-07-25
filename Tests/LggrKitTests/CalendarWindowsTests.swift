import Foundation
import Testing

@testable import LggrKit

private func hours(_ count: Double) -> TimeInterval { count * 3600 }

/// Whole days as seconds. Named for the arithmetic the production code must *not* do — several of
/// these weeks are deliberately not seven times twenty-four hours long.
private func nominalDays(_ count: Double) -> TimeInterval { count * 86_400 }

/// Day and week boundaries are where "obviously correct" arithmetic quietly produces a wrong weekly
/// total twice a year. Every case here pins an explicit timezone, an explicit first weekday and a
/// known calendar date, so results are identical on any machine in any region.
@Suite("Calendar windows")
struct CalendarWindowsTests {

    /// A Gregorian calendar pinned to one zone and one first weekday.
    /// `firstWeekday` is 1 for Sunday and 2 for Monday, matching `Calendar`.
    private func makeWindows(zone: String, firstWeekday: Int = 2) throws -> CalendarWindows {
        let timeZone = try #require(TimeZone(identifier: zone))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = firstWeekday
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return CalendarWindows(calendar: calendar)
    }

    private func makeDate(
        _ windows: CalendarWindows,
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int = 12,
        minute: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try #require(windows.calendar.date(from: components))
    }

    /// "2024-03-31" in the calendar's own timezone, so a failure names a date rather than an epoch.
    private func label(_ windows: CalendarWindows, _ date: Date) -> String {
        let parts = windows.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return "?" }
        return String(format: "%04ld-%02ld-%02ld", year, month, day)
    }

    // MARK: - Days

    @Test("A day runs from local midnight to local midnight")
    func ordinaryDay() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let noon = try makeDate(madrid, 2024, 3, 10)
        let expectedStart = try makeDate(madrid, 2024, 3, 10, hour: 0)
        let expectedEnd = try makeDate(madrid, 2024, 3, 11, hour: 0)

        let day = try #require(madrid.day(containing: noon))

        #expect(day.contains(noon))
        #expect(day.duration == hours(24))
        #expect(day.start == expectedStart)
        #expect(day.end == expectedEnd)
    }

    @Test("The same instant belongs to different days in different timezones")
    func dayIsTimezoneRelative() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let mexico = try makeWindows(zone: "America/Mexico_City")
        // 02:00 in Madrid on 1 July is still 30 June in Mexico City.
        let instant = try makeDate(madrid, 2024, 7, 1, hour: 2)

        let madridDay = try #require(madrid.day(containing: instant))
        let mexicoDay = try #require(mexico.day(containing: instant))

        #expect(label(madrid, madridDay.start) == "2024-07-01")
        #expect(label(mexico, mexicoDay.start) == "2024-06-30")
        #expect(madridDay.start != mexicoDay.start)
    }

    @Test("The spring-forward day is 23 hours long")
    func springForwardDay() throws {
        // Madrid moves 02:00 to 03:00 on 2024-03-31.
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let noon = try makeDate(madrid, 2024, 3, 31)
        let nextMidnight = try makeDate(madrid, 2024, 4, 1, hour: 0)

        let day = try #require(madrid.day(containing: noon))

        #expect(day.duration == hours(23))
        #expect(label(madrid, day.start) == "2024-03-31")
        #expect(day.end == nextMidnight)
    }

    @Test("The fall-back day is 25 hours long")
    func fallBackDay() throws {
        // Madrid moves 03:00 back to 02:00 on 2024-10-27.
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let noon = try makeDate(madrid, 2024, 10, 27)
        let nextMidnight = try makeDate(madrid, 2024, 10, 28, hour: 0)

        let day = try #require(madrid.day(containing: noon))

        #expect(day.duration == hours(25))
        #expect(day.end == nextMidnight)
    }

    @Test("Mexico City abolished daylight saving, so its days are always 24 hours")
    func mexicoCityHasNoTransition() throws {
        let mexico = try makeWindows(zone: "America/Mexico_City")
        let spring = try makeDate(mexico, 2024, 3, 31)
        let autumn = try makeDate(mexico, 2024, 10, 27)

        for instant in [spring, autumn] {
            let day = try #require(mexico.day(containing: instant))
            #expect(day.duration == hours(24))
        }
    }

    // MARK: - Weeks

    @Test("A Monday-first week starts on the preceding Monday")
    func mondayFirstWeek() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid", firstWeekday: 2)
        // 2024-01-31 is a Wednesday.
        let wednesday = try makeDate(madrid, 2024, 1, 31)

        let week = try #require(madrid.week(containing: wednesday))

        #expect(label(madrid, week.start) == "2024-01-29")
        #expect(label(madrid, week.end) == "2024-02-05")
        #expect(week.duration == nominalDays(7))
    }

    @Test("A Sunday-first calendar moves the same week a day earlier")
    func sundayFirstWeek() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid", firstWeekday: 1)
        let wednesday = try makeDate(madrid, 2024, 1, 31)

        let week = try #require(madrid.week(containing: wednesday))

        #expect(label(madrid, week.start) == "2024-01-28")
        #expect(label(madrid, week.end) == "2024-02-04")
    }

    @Test("startOfWeek agrees with the week interval and lands on midnight")
    func startOfWeekMatchesInterval() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let wednesday = try makeDate(madrid, 2024, 1, 31)

        let week = try #require(madrid.week(containing: wednesday))
        let start = try #require(madrid.startOfWeek(for: wednesday))

        #expect(start == week.start)
        #expect(start == madrid.startOfDay(for: start))
    }

    @Test("Every day of a week resolves to the same week start")
    func weekIsStableAcrossItsDays() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let wednesday = try makeDate(madrid, 2024, 1, 31)
        let monday = try #require(madrid.startOfWeek(for: wednesday))

        for offset in 0..<7 {
            let inside = try #require(
                madrid.calendar.date(byAdding: .day, value: offset, to: monday)
            )
            #expect(madrid.startOfWeek(for: inside) == monday)
        }
    }

    // MARK: - Week boundaries

    @Test("A week spanning a month boundary stays one week")
    func weekAcrossAMonthBoundary() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let wednesday = try makeDate(madrid, 2024, 1, 31)

        let dayIntervals = madrid.daysIn(week: wednesday)

        #expect(dayIntervals.count == 7)
        #expect(label(madrid, dayIntervals[0].start) == "2024-01-29")
        #expect(label(madrid, dayIntervals[2].start) == "2024-01-31")
        #expect(label(madrid, dayIntervals[3].start) == "2024-02-01")
        #expect(label(madrid, dayIntervals[6].start) == "2024-02-04")
    }

    @Test("A week spanning a year boundary stays one week")
    func weekAcrossAYearBoundary() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        // 2024-12-31 is a Tuesday; its week runs Mon 2024-12-30 to Sun 2025-01-05.
        let newYearsEve = try makeDate(madrid, 2024, 12, 31)

        let week = try #require(madrid.week(containing: newYearsEve))
        let dayIntervals = madrid.daysIn(week: week)

        #expect(label(madrid, week.start) == "2024-12-30")
        #expect(dayIntervals.count == 7)
        #expect(label(madrid, dayIntervals[0].start) == "2024-12-30")
        #expect(label(madrid, dayIntervals[1].start) == "2024-12-31")
        #expect(label(madrid, dayIntervals[2].start) == "2025-01-01")
        #expect(label(madrid, dayIntervals[6].start) == "2025-01-05")
    }

    @Test("A week containing a daylight-saving transition still has seven days")
    func weekAcrossADaylightSavingTransition() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let transitionDay = try makeDate(madrid, 2024, 3, 31)

        let week = try #require(madrid.week(containing: transitionDay))
        let dayIntervals = madrid.daysIn(week: week)

        #expect(label(madrid, week.start) == "2024-03-25")
        #expect(dayIntervals.count == 7)
        // Seven days, but an hour short of seven times twenty-four.
        #expect(week.duration == nominalDays(7) - hours(1))
        #expect(label(madrid, dayIntervals[6].start) == "2024-03-31")
        #expect(dayIntervals[6].duration == hours(23))
    }

    @Test("The fall-back week is an hour longer than a nominal week")
    func weekAcrossFallBack() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let transitionDay = try makeDate(madrid, 2024, 10, 27)

        let week = try #require(madrid.week(containing: transitionDay))
        let dayIntervals = madrid.daysIn(week: week)

        #expect(label(madrid, week.start) == "2024-10-21")
        #expect(dayIntervals.count == 7)
        #expect(week.duration == nominalDays(7) + hours(1))
        #expect(dayIntervals[6].duration == hours(25))
    }

    // MARK: - Day coverage

    @Test("The days of a week tile it exactly, with no gap and no overlap")
    func daysTileTheWeek() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let transitionDay = try makeDate(madrid, 2024, 3, 31)

        let week = try #require(madrid.week(containing: transitionDay))
        let dayIntervals = madrid.daysIn(week: week)

        let first = try #require(dayIntervals.first)
        let last = try #require(dayIntervals.last)
        #expect(first.start == week.start)
        #expect(last.end == week.end)

        for (earlier, later) in zip(dayIntervals, dayIntervals.dropFirst()) {
            #expect(earlier.end == later.start)
        }

        let covered = dayIntervals.reduce(TimeInterval(0)) { $0 + $1.duration }
        #expect(covered == week.duration)
    }

    @Test("Asking by a date inside the week gives the same days as asking by the interval")
    func daysInWeekByDateMatchesByInterval() throws {
        let madrid = try makeWindows(zone: "Europe/Madrid")
        let wednesday = try makeDate(madrid, 2024, 1, 31)

        let week = try #require(madrid.week(containing: wednesday))

        #expect(madrid.daysIn(week: wednesday) == madrid.daysIn(week: week))
    }

    // MARK: - Defaults

    @Test("The default calendar is the user's own and still resolves both windows")
    func defaultCalendarWorks() {
        let windows = CalendarWindows()
        let instant = Date(timeIntervalSinceReferenceDate: 727_083_600)

        #expect(windows.calendar.identifier == Calendar.current.identifier)
        #expect(windows.day(containing: instant) != nil)
        #expect(windows.week(containing: instant) != nil)
        #expect(windows.startOfWeek(for: instant) != nil)
        #expect(windows.daysIn(week: instant).count == 7)
    }
}
