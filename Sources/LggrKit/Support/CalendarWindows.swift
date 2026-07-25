import Foundation

/// Day and week boundaries, computed through an injectable `Calendar`.
///
/// Nothing in Lggr may build a day or a week by adding 86,400 seconds. A day is 23 hours twice a
/// year, a week starts on Monday or Sunday depending on the user's region, and a week can straddle a
/// month or a year. Routing every window through `Calendar` is what makes the daily and weekly
/// aggregates agree with the dates the user sees on their own screen.
///
/// Every `Calendar` computation here is optional at the source, so each one is either propagated as
/// an optional or skipped — none of them are forced.
public struct CalendarWindows: Sendable {

    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    // MARK: - Days

    /// Midnight to midnight around `date`, in the calendar's timezone. 23 or 25 hours long across a
    /// daylight-saving transition.
    public func day(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .day, for: date)
    }

    public func startOfDay(for date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    // MARK: - Weeks

    /// The week around `date`, honoring the calendar's `firstWeekday`.
    public func week(containing date: Date) -> DateInterval? {
        calendar.dateInterval(of: .weekOfYear, for: date)
    }

    public func startOfWeek(for date: Date) -> Date? {
        week(containing: date)?.start
    }

    /// Each day of `week`, in order, walked one calendar day at a time rather than by fixed offsets
    /// so a daylight-saving transition inside the week keeps the count at seven.
    public func daysIn(week: DateInterval) -> [DateInterval] {
        var days: [DateInterval] = []
        var cursor = calendar.startOfDay(for: week.start)
        // A calendar that somehow fails to advance would otherwise spin forever; a week never has
        // more than eight day-starts even under the strangest timezone rules.
        while cursor < week.end, days.count < 8 {
            guard let day = calendar.dateInterval(of: .day, for: cursor), day.end > cursor else {
                break
            }
            days.append(day)
            cursor = day.end
        }
        return days
    }

    /// Each day of the week containing `date`. Empty only when the calendar cannot resolve the week.
    public func daysIn(week date: Date) -> [DateInterval] {
        guard let interval = week(containing: date) else { return [] }
        return daysIn(week: interval)
    }
}
