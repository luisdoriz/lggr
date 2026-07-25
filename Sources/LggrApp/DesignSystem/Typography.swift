import SwiftUI

// The type ramp. See docs/_design/04-screens.md § 2.1.
//
// Every entry derives from a macOS text style so it scales wherever the system scales, with exactly
// one hard-coded size in the whole application — the hero timer, which goes through `@ScaledMetric`
// via `.heroTimerFont()` below.
//
// Rules this file exists to enforce:
//   • `.rounded` is used for numerals under a clock only. Everything else is the system face.
//   • `.monospacedDigit()` is mandatory on every number that changes over time. It is what stops the
//     menu bar and the hero timer from jittering horizontally once per second.
//   • Weight never creates a fifth hierarchy level. Four levels — hero / title / row / body — plus
//     `.secondary` foreground for everything demoted.
//   • No letter-spacing, no all-caps, no small-caps.

/// The application's type ramp. There is no font in `LggrApp` that is not one of these.
public enum `Type` {
    // MARK: Hero

    /// The base point size of the hero timer, before Dynamic Type scaling.
    /// The only hard-coded size in the application.
    public static let heroTimerBaseSize: CGFloat = 72

    /// The one dominant number: the active session timer in the main window. Nowhere else.
    ///
    /// Prefer the `.heroTimerFont()` modifier, which supplies the `@ScaledMetric` size for you.
    public static func timerHero(size: CGFloat = heroTimerBaseSize) -> Font {
        .system(size: size, weight: .medium, design: .rounded).monospacedDigit()
    }

    // MARK: Titles

    /// The detail column header — "Today", "Weekly Review". One per screen.
    public static let screenTitle: Font = .largeTitle.weight(.semibold)

    /// The intended outcome: the second-most important text in the app. Never truncates.
    public static let outcome: Font = .title2.weight(.medium)

    /// The timer inside the menu bar popover and the review sheet header.
    public static let timerCompact: Font = .title.weight(.medium).monospacedDigit()

    /// "Accomplishments", "Time allocation", "Day".
    public static let sectionTitle: Font = .title3.weight(.semibold)

    /// The number in a `MetricTile`.
    public static let metricValue: Font = .title2.weight(.medium).monospacedDigit()

    // MARK: Body

    /// Session titles, project names, accomplishment titles, rule descriptions, empty-state titles.
    public static let rowTitle: Font = .headline

    /// Body copy, summary editor, form field contents, the empty state's one explanatory line.
    public static let body: Font = .body

    /// Metadata: project name, time ranges, application lists, metric captions.
    public static let secondary: Font = .subheadline

    /// Timeline axis labels, keyboard hints, "built-in rule" tags.
    /// Nothing a user *must* read is set at this size.
    public static let caption: Font = .caption

    // MARK: Special purpose

    /// The menu bar label only. Never used inside a window.
    ///
    /// 12pt regular rounded is visually the same weight as the system clock a few pixels to its
    /// right, which is most of what makes the label subtle.
    public static let menuBarTimer: Font =
        .system(size: 12, weight: .regular, design: .rounded).monospacedDigit()

    /// The Markdown export preview.
    public static let mono: Font = .system(.body, design: .monospaced)
}

// MARK: - The hero timer's scaled size

/// Applies `Type.timerHero` at a Dynamic Type-scaled size.
///
/// The size lives in a `ViewModifier` rather than in `Type` because `@ScaledMetric` only resolves
/// inside a view's environment. This is the single place the 72pt base size is scaled.
private struct HeroTimerFontModifier: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = Type.heroTimerBaseSize

    func body(content: Content) -> some View {
        content.font(Type.timerHero(size: size))
    }
}

extension View {
    /// The hero timer's font, scaled with Dynamic Type. Use this rather than `Type.timerHero()`.
    public func heroTimerFont() -> some View {
        modifier(HeroTimerFontModifier())
    }
}
