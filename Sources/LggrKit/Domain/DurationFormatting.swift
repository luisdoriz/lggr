import Foundation

/// Every duration string in Lggr, in one place.
///
/// The same session length is rendered in three quite different registers — a running clock in the
/// menu bar, a compact label in a list, a spelled-out phrase inside a generated sentence. Keeping
/// them as named functions on one namespace is what stops them from drifting apart as the UI grows.
///
/// `DateComponentsFormatter` is deliberately unused for the timer clock: its separators, digit
/// grouping and unit elision all vary by locale, which is fine for prose and fatal for a fixed-width
/// display that must not reflow while it ticks.
public enum DurationFormatting {

    /// Roughly 68 years. Durations beyond this are corrupt rather than long, and clamping them keeps
    /// the `Int` conversions below total.
    private static let ceiling: TimeInterval = TimeInterval(Int32.max)

    /// Negative, `NaN` and infinite inputs all collapse to zero, so a bad stored value formats as
    /// "0:00" instead of trapping.
    private static func normalized(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(duration, ceiling)
    }

    // MARK: - Timer clock

    /// The monospaced clock for the active session and the menu bar: `M:SS` below an hour,
    /// `H:MM:SS` at or above it.
    ///
    /// Seconds and minutes are zero-padded and the separators are fixed, so the string only changes
    /// width when the leading unit gains a digit. Render it with monospaced digits and reserve
    /// `timerClockTemplate(upTo:)` worth of space and the clock never jitters.
    public static func timerClock(_ duration: TimeInterval) -> String {
        let total = Int(normalized(duration).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        // `%ld` rather than `%d`: these are Swift `Int`s, which are 64-bit.
        if hours == 0 {
            return String(format: "%ld:%02ld", minutes, seconds)
        }
        return String(format: "%ld:%02ld:%02ld", hours, minutes, seconds)
    }

    /// The widest clock a session bounded by `duration` can produce, with every digit replaced by a
    /// zero. Lay this out invisibly behind the live clock to reserve a stable width.
    public static func timerClockTemplate(upTo duration: TimeInterval) -> String {
        String(timerClock(duration).map { $0.isNumber ? "0" : $0 })
    }

    // MARK: - Countdown

    /// The countdown for a session with a target, built from the two clamped values `FocusSession`
    /// exposes. Once the plan is spent the clock turns around and counts the overrun up behind a
    /// `+`, e.g. "+2:14".
    public static func countdown(remaining: TimeInterval, overrun: TimeInterval) -> String {
        let over = normalized(overrun)
        if over > 0 {
            return "+" + timerClock(over)
        }
        return timerClock(remaining)
    }

    /// Countdown from a single signed value, where negative means past the target.
    public static func countdown(signed: TimeInterval) -> String {
        guard signed.isFinite else { return timerClock(0) }
        return signed < 0 ? "+" + timerClock(-signed) : timerClock(signed)
    }

    // MARK: - Compact

    /// The label for lists and summary tiles: "50m", "1h 12m", "3h". Zero reads as "0m".
    ///
    /// Rounded to the nearest minute, so a 59-second session reads as "1m" rather than vanishing.
    /// There is no day unit: "26h" is more legible than "1d 2h" for a week of focused time.
    public static func compact(_ duration: TimeInterval) -> String {
        let totalMinutes = Int((normalized(duration) / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    // MARK: - Prose

    private static let numberWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
    ]

    private static func spelled(_ value: Int) -> String? {
        guard value >= 0, value < numberWords.count else { return nil }
        return numberWords[value]
    }

    /// The duration as it appears inside a generated sentence — "spent seven minutes in Slack",
    /// "spent 1.4 hours on Billing".
    ///
    /// Whole counts below eleven are spelled out, which is the house style for prose; anything
    /// longer than an hour that is not a whole number of hours gets one decimal place.
    public static func prose(_ duration: TimeInterval) -> String {
        let seconds = normalized(duration)
        let totalMinutes = Int((seconds / 60).rounded())

        if totalMinutes < 60 {
            let count = spelled(totalMinutes) ?? String(totalMinutes)
            return "\(count) \(totalMinutes == 1 ? "minute" : "minutes")"
        }

        let hours = ((seconds / 3600) * 10).rounded() / 10
        let whole = Int(hours.rounded())
        if hours == Double(whole), let word = spelled(whole) {
            return "\(word) \(whole == 1 ? "hour" : "hours")"
        }
        // `String(format:)` with no locale is POSIX, so the decimal separator stays a period even on
        // a machine that writes 1,4.
        return String(format: "%.1f hours", hours)
    }
}
