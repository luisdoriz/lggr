import SwiftUI

// Every SF Symbol name used by LggrApp, in one place. See docs/_design/04-screens.md § 2.10.
//
// Domain symbols are NOT re-declared here. `WorkType.symbolName`, `SessionResultStatus.symbolName`,
// `AccomplishmentType.symbolName` and `SessionState.symbolName` come from LggrKit and are used
// verbatim; duplicating them here would create a second source of truth that silently drifts.
//
// Two rendering rules go with this file:
//   • Symbols in body text use `.imageScale(.medium)` and inherit `.foregroundStyle`.
//   • Symbols never get a coloured circular background. There are no icon chips in Lggr.
//
// Every name below exists in SF Symbols 4 and renders on macOS 14.

/// The application's SF Symbol vocabulary.
public enum Icon {
    // MARK: Session actions
    public static let startSession = "play.circle"
    public static let quickTimer = "bolt"
    public static let pause = "pause.fill"
    public static let resume = "play.fill"
    public static let finish = "checkmark"
    public static let interruption = "bell.badge"
    public static let addAccomplishment = "plus.circle"

    // MARK: Screen actions
    public static let export = "square.and.arrow.up"
    public static let regenerate = "arrow.clockwise"
    public static let more = "ellipsis.circle"
    public static let search = "magnifyingglass"
    public static let previousWeek = "chevron.left"
    public static let nextWeek = "chevron.right"
    public static let inbox = "tray"
    public static let privacy = "hand.raised"
    public static let accessibility = "accessibility"
    /// The Shortcuts tab in Settings.
    public static let shortcuts = "keyboard"

    // MARK: Empty states
    public static let emptyToday = "sun.max"
    public static let emptySessions = "timer"
    public static let emptyDone = "checkmark.seal"
    public static let emptyWeek = "chart.bar.xaxis"
    public static let emptyProjects = "folder"
    public static let emptyRules = "slider.horizontal.3"

    // MARK: Status
    public static let error = "exclamationmark.triangle"

    // MARK: Row and menu affordances
    /// Dismisses the error banner; also the trailing remove control on an application list row.
    public static let dismiss = "xmark"
    public static let add = "plus"
    public static let remove = "minus"
    public static let edit = "pencil"
    public static let copy = "doc.on.doc"
    public static let duplicate = "plus.square.on.square"
    public static let delete = "trash"
    public static let showInFinder = "folder"
    public static let disclosureClosed = "chevron.right"
    public static let disclosureOpen = "chevron.down"
    public static let dragHandle = "line.3.horizontal"
    public static let selected = "checkmark"
    public static let submenu = "chevron.right"
}

// MARK: - Menu bar label states

extension Icon {
    /// The symbols the menu bar label can show. See `04-screens.md` § 6.1.
    ///
    /// `idle` and `running` are deliberately the same glyph: the *presence of digits* is the state
    /// change, not a different shape. That is most of what keeps the label subtle. A completed,
    /// reviewed session returns the label to `idle` — a permanent checkmark would be a reward, and
    /// rewards are gamification.
    public enum MenuBar {
        public static let idle = "timer"
        public static let running = "timer"
        public static let paused = "pause.circle"
        public static let awaitingReview = "questionmark.circle"
    }
}
