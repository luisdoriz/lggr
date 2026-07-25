import SwiftUI

// The seven rooms of the application. See docs/_design/04-screens.md § 1.2.
//
// One flat list, no `Section` headers: seven items do not need headings. The order below is the
// order on screen *and* the order of `⌘1`–`⌘7`, which is why `shortcutNumber` is derived from
// `allCases` rather than written out — a reordering can never leave the numbers behind.

/// A room in the main window's sidebar.
///
/// `rawValue` is persisted by `AppModel` under `com.lggr.sidebar.section`, so these strings are a
/// storage format: renaming a case would silently reset a user's selection to Today.
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case today
    case sessions
    case accomplishments
    case weeklyReview
    case projects
    case rules
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: "Today"
        case .sessions: "Focus Sessions"
        case .accomplishments: "Accomplishments"
        case .weeklyReview: "Weekly Review"
        case .projects: "Projects"
        case .rules: "Rules"
        case .settings: "Settings"
        }
    }

    /// All seven exist in SF Symbols 4 and render on macOS 14.
    ///
    /// **They stay in their outline variant, always.** `.symbolVariant(.fill)` on the selected row is
    /// the obvious Apple move, but `timer` and `slider.horizontal.3` have no filled variant, so
    /// selection would change the shape of five rows and not two. Selection is carried entirely by
    /// the system highlight. That is a constraint, not a preference.
    public var symbolName: String {
        switch self {
        case .today: Icon.emptyToday
        case .sessions: Icon.emptySessions
        case .accomplishments: Icon.emptyDone
        case .weeklyReview: Icon.emptyWeek
        case .projects: Icon.emptyProjects
        case .rules: Icon.emptyRules
        case .settings: "gearshape"
        }
    }

    /// `⌘1` … `⌘7`, in declaration order.
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// The digit `⌘1`–`⌘7` presses.
    ///
    /// Written as literals rather than built from `shortcutNumber` because `KeyEquivalent` takes a
    /// `Character`, and deriving one from an interpolated string means reaching into `String.first`
    /// and deciding what to do when it is `nil`. There is no sensible answer to that question, so the
    /// question is not asked.
    public var shortcutKey: KeyEquivalent {
        switch self {
        case .today: "1"
        case .sessions: "2"
        case .accomplishments: "3"
        case .weeklyReview: "4"
        case .projects: "5"
        case .rules: "6"
        case .settings: "7"
        }
    }

    public var shortcut: KeyboardShortcut {
        KeyboardShortcut(shortcutKey, modifiers: .command)
    }
}
