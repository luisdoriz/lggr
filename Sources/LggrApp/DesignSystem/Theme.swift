import SwiftUI

// Design tokens: spacing, corner radii and the fixed dimensions the layout is built from.
// See docs/_design/04-screens.md § 2.2 and § 2.3. These names are final; every other file in
// LggrApp composes from them and no call site ever writes a raw number.

/// The complete spacing scale. 4pt base, eight steps, and that is all of them.
///
/// If a layout wants 18pt it wants 16 or 20 and the designer was guessing.
public enum Space {
    /// 2 — symbol-to-text inside a badge.
    public static let xxs: CGFloat = 2
    /// 4 — menu bar symbol → digits.
    public static let xs: CGFloat = 4
    /// 8 — icon → label; chip padding.
    public static let s: CGFloat = 8
    /// 12 — between sibling cards; list row vertical padding; popover interior.
    public static let m: CGFloat = 12
    /// 16 — card interior padding; form row spacing.
    public static let l: CGFloat = 16
    /// 24 — detail column inset; sheet interior padding.
    public static let xl: CGFloat = 24
    /// 32 — between two major sections on a screen.
    public static let xxl: CGFloat = 32
    /// 48 — above/below the hero timer; empty-state breathing room.
    public static let hero: CGFloat = 48
}

/// The complete corner radius scale.
///
/// Always paired with `.continuous`; see `Theme.shape(_:)`. The default `.circular` style is never
/// used — continuous corners are what every native macOS surface uses and the difference is visible
/// at 10pt.
public enum Radius {
    /// 6 — duration segments, source chips, project badges, popover row hover fills.
    public static let chip: CGFloat = 6
    /// 10 — cards, list rows with a hover fill, text fields.
    public static let card: CGFloat = 10
    /// 14 — a sheet's inner panels, the popover's session block.
    public static let panel: CGFloat = 14
}

/// Fixed dimensions that appear in more than one file, or that the design document states exactly.
///
/// Everything here is a number `04-screens.md` gives explicitly. Nothing may be invented at a call
/// site: if a new fixed size is needed, it is added here first.
public enum Layout {
    // Scenes
    /// Default main-window size (04-screens.md § 1.1).
    public static let windowDefaultSize = CGSize(width: 1_040, height: 720)
    /// Sidebar column width bounds (04-screens.md § 1.1).
    public static let sidebarMinWidth: CGFloat = 180
    public static let sidebarIdealWidth: CGFloat = 220
    public static let sidebarMaxWidth: CGFloat = 280
    /// The detail column never narrows past this (04-screens.md § 1.1).
    public static let detailMinWidth: CGFloat = 640
    /// The onboarding window (04-screens.md § 5.5).
    public static let onboardingSize = CGSize(width: 640, height: 460)

    // Panels
    /// The menu bar popover, `.menuBarExtraStyle(.window)` (04-screens.md § 5.1).
    public static let popoverWidth: CGFloat = 320
    /// The start panel presented as a sheet on the main window (04-screens.md § 5.2).
    public static let startPanelSheetWidth: CGFloat = 460
    /// The session review sheet (04-screens.md § 5.3).
    public static let reviewSheetWidth: CGFloat = 520
    /// The interruption capture sheet (04-screens.md § 5.4).
    public static let captureSheetWidth: CGFloat = 420
    /// The project editor sheet (04-screens.md § 4.5).
    public static let projectEditorWidth: CGFloat = 420
    /// The sheet that corrects a finished session's times.
    ///
    /// The one width here that `04-screens.md` does not state, because the screen it belongs to
    /// post-dates the document. It takes the start panel's 460 rather than a fourth number: the two
    /// are the same shape of form — a couple of labelled controls with a derived line underneath —
    /// and a date-and-time picker needs every one of those points to sit on one line.
    public static let sessionEditWidth: CGFloat = 460
    /// The rule editor sheet (04-screens.md § 4.6). Wider than the project editor because a rule is
    /// a sentence with two halves, and both halves have to fit on one line to be read as one.
    public static let ruleEditorWidth: CGFloat = 480
    /// The correction sheet that offers a rule (04-screens.md § 4.6). Compact: one question, one
    /// sentence of consequence, two buttons.
    public static let ruleOfferWidth: CGFloat = 420

    // Rows and glyph metrics
    /// Symbols sit in a fixed-width column so labels align even though the glyphs differ.
    public static let symbolColumnWidth: CGFloat = 18
    /// Popover row height (04-screens.md § 5.1).
    public static let popoverRowHeight: CGFloat = 28
    /// Leading inset for a list row separator when the row has a leading icon (04-screens.md § 2.7).
    public static let separatorInsetWithIcon: CGFloat = 44

    // History chrome
    /// The search field on the two history screens (04-screens.md § 4.2, § 4.3).
    public static let searchFieldWidth: CGFloat = 220
    /// The date-range label between the two step chevrons. Fixed so the chevrons do not shuffle
    /// sideways as the label goes from "May 2026" to "September 2026".
    public static let historyRangeLabelWidth: CGFloat = 132

    // Component metrics
    /// The project colour dot before a project name (04-screens.md § 2.5).
    public static let projectDotSize: CGFloat = 8
    /// A colour swatch in the project editor's picker.
    public static let projectSwatchSize: CGFloat = 28
    /// The full-height leading bar on a day-timeline block.
    public static let timelineBarWidth: CGFloat = 3
    /// The stacked category allocation bar.
    public static let allocationBarHeight: CGFloat = 6
    /// The popover's linear progress capsule.
    public static let progressCapsuleHeight: CGFloat = 4
    /// The empty state's single SF Symbol (04-screens.md § 3.1).
    public static let emptyStateSymbolSize: CGFloat = 28
    /// The empty state's text column never grows past this (04-screens.md § 3.1).
    public static let emptyStateMaxTextWidth: CGFloat = 340
    /// Hairline weight. One value, everywhere.
    public static let hairline: CGFloat = 1
}

/// Shape helpers, so a fill and its stroke are always drawn on the *same* rectangle. Drawing them on
/// two separately-constructed shapes is what blurs a hairline by half a pixel.
public enum Theme {
    public static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    /// `Radius.chip` rectangle — segments, chips, hover fills on popover rows.
    public static var chipShape: RoundedRectangle { shape(Radius.chip) }
    /// `Radius.card` rectangle — cards, hoverable list rows, text fields.
    public static var cardShape: RoundedRectangle { shape(Radius.card) }
    /// `Radius.panel` rectangle — inner panels inside a sheet or the popover.
    public static var panelShape: RoundedRectangle { shape(Radius.panel) }
}
