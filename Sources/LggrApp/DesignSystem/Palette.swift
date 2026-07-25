import AppKit
import SwiftUI
import LggrKit

// Semantic colour roles. See docs/_design/04-screens.md § 2.4 – § 2.9.
//
// `Lggr.app` is assembled by hand by Scripts/make-app.sh, so there is no asset catalog and no
// `Color("CardBackground")`. Every adaptive colour is therefore constructed in code.
//
// The rule that keeps this correct in both appearances: prefer a *system semantic* colour
// (`.windowBackgroundColor`, `.controlBackgroundColor`, `.separatorColor`, `Color.primary`,
// `Color.accentColor`) over a literal. A system colour is already right in light mode, dark mode,
// increased contrast and under vibrancy. Hand-mixed greys are not.
//
// Exactly three colours in this file are hand-made — `Surface.raised`, `Surface.hover` and
// `Stroke.card` — and all three are built through `NSColor.lggrDynamic`, which resolves against the
// drawing appearance and so also handles Increase Contrast without an observer or a redraw.

// AppKit is used here (rather than pure SwiftUI) for one reason only: `NSColor(name:dynamicProvider:)`
// is the only way to declare a light/dark colour pair without an asset catalog, which we do not have.

extension NSColor {
    /// A colour that resolves against the appearance it is drawn in.
    ///
    /// The high-contrast variants are optional; when omitted the standard variant is reused. Because
    /// the choice happens inside the provider, Increase Contrast is honoured at draw time — there is
    /// nothing to observe and nothing to invalidate.
    static func lggrDynamic(
        light: NSColor,
        dark: NSColor,
        highContrastLight: NSColor? = nil,
        highContrastDark: NSColor? = nil
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .aqua,
                .darkAqua,
                .accessibilityHighContrastAqua,
                .accessibilityHighContrastDarkAqua,
            ])
            switch match {
            case .darkAqua:
                return dark
            case .accessibilityHighContrastAqua:
                return highContrastLight ?? light
            case .accessibilityHighContrastDarkAqua:
                return highContrastDark ?? dark
            default:
                return light
            }
        }
    }

    /// A neutral overlay in the direction of the foreground — the AppKit spelling of
    /// `Color.primary.opacity(_:)`, expressed so it can carry an Increase Contrast variant.
    fileprivate static func lggrPrimaryOverlay(_ alpha: CGFloat, highContrast: CGFloat) -> NSColor {
        lggrDynamic(
            light: NSColor(white: 0.0, alpha: alpha),
            dark: NSColor(white: 1.0, alpha: alpha),
            highContrastLight: NSColor(white: 0.0, alpha: highContrast),
            highContrastDark: NSColor(white: 1.0, alpha: highContrast)
        )
    }
}

/// Background roles. Space before lines, lines before boxes, boxes before colour — so most of the
/// application sits directly on `canvas` and uses none of the rest.
public enum Surface {
    /// The detail column background. The sidebar's background is left to the system.
    public static let canvas = Color(nsColor: .windowBackgroundColor)

    /// A raised card sitting on `canvas`. Slightly lighter than the canvas in both modes.
    ///
    /// In dark mode this is a 5.5% white overlay, not white: a white card on a dark canvas is a
    /// flashlight, and it must never be brighter than the text around it.
    public static let raised = Color(nsColor: .lggrDynamic(
        light: .white,
        dark: NSColor(white: 1.0, alpha: 0.055),
        highContrastLight: .white,
        highContrastDark: NSColor(white: 1.0, alpha: 0.085)
    ))

    /// A recessed well: text fields, the summary editor.
    public static let sunken = Color(nsColor: .controlBackgroundColor)

    /// Row hover. `Color.primary.opacity(0.06)`, made Increase Contrast-aware.
    public static let hover = Color(nsColor: .lggrPrimaryOverlay(0.06, highContrast: 0.12))

    /// Row pressed — hover at roughly 1.5×.
    public static let pressed = Color(nsColor: .lggrPrimaryOverlay(0.09, highContrast: 0.18))

    /// A selected but non-focused row, and the keyboard-highlighted row in any list.
    ///
    /// Deliberately different from `hover` so the mouse and the keyboard never contradict each other
    /// on screen. The *focused* row uses the system selection colour, not this.
    public static let selected = Color.accentColor.opacity(0.14)
}

/// Line roles. Reach for space first, a `Divider()` second, and one of these only after that.
public enum Stroke {
    /// Structural separators. Always the system value; never a hand-mixed grey.
    public static let separator = Color(nsColor: .separatorColor)

    /// The hairline around a card. Steps up under Increase Contrast.
    public static let card = Color(nsColor: .lggrDynamic(
        light: NSColor(white: 0.0, alpha: 0.07),
        dark: NSColor(white: 1.0, alpha: 0.10),
        highContrastLight: NSColor(white: 0.0, alpha: 0.22),
        highContrastDark: NSColor(white: 1.0, alpha: 0.28)
    ))

    /// The 0.5pt inner stroke on every project dot and swatch.
    ///
    /// One line in one place is what stops a yellow dot from vanishing on a white canvas.
    public static let projectDot = Color.primary.opacity(0.15)

    /// Width of the project dot's inner stroke.
    public static let projectDotWidth: CGFloat = 0.5
}

/// Foreground roles for text.
///
/// `04-screens.md` § 2.4 permits `.primary`, `.secondary` and `.tertiary` for text and reserves
/// `.quaternary` for shapes. **`.tertiary` did not survive being looked at**, which is what the
/// snapshot gallery is for: `tertiaryLabelColor` is a 25% overlay, so it composites to roughly
/// `#BFBFBF` on the light canvas and `#5B5B5B` on the dark one — about 1.9:1 and 2.3:1 against their
/// backgrounds. At `Type.caption`'s 10pt that is not quiet, it is absent, and it was absent in *both*
/// appearances rather than one, which is why reading the two images side by side did not catch it and
/// measuring the composite did.
///
/// So the smallest explanatory text in the app resolves through here instead. Two things still belong
/// at `.tertiary` and keep saying so at the call site: punctuation between metadata (the `·`), and
/// shapes — an empty progress track, a dashed seat border, a hover-revealed chevron.
public enum Ink {
    /// Provenance, evidence, axis labels, keyboard hints — everything set at `Type.caption`.
    ///
    /// It is `.secondary` (about 4.6:1 light, 4.9:1 dark) and not a fourth level of hierarchy: § 2.1
    /// allows four, and this is the foreground of the fourth, not a fifth.
    public static let support: HierarchicalShapeStyle = .secondary
}

/// The two non-project colours that carry meaning, and the project colour map.
///
/// Colour means "which project", or it means nothing. These two are the entire exception list.
public enum Palette {
    /// Overtime digits and the "at risk" outcome status glyph. Nothing else.
    ///
    /// Never a fill, never a background, never on more than ~20 characters at a time.
    public static let attention = Color(nsColor: .systemOrange)

    /// The confirm button of a destructive alert. There is no other red in Lggr — not on blocked
    /// sessions, not on distraction time, not on missed outcomes.
    public static let destructive = Color(nsColor: .systemRed)
}

// MARK: - Project colours

extension Palette {
    /// Maps a `Project.colorID` token to a colour.
    ///
    /// The map is to *system* colours, so the whole palette is already correct in light mode, dark
    /// mode and under Increase Contrast. An unrecognised token — a project created by a future
    /// version with a larger palette — falls back to the default rather than failing.
    public static func project(_ colorID: String) -> Color {
        switch colorID {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "graphite": return Color(nsColor: .systemGray)
        default: return .blue
        }
    }

    /// The colour of a project, or the neutral used for "No project".
    public static func project(_ project: Project?) -> Color {
        guard let project else { return Color(nsColor: .systemGray) }
        return Self.project(project.colorID)
    }

    /// The spoken name of a colour token, for VoiceOver on the editor's swatch picker.
    ///
    /// Unknown tokens speak their own token, which is still more useful than silence.
    public static func projectColorName(_ colorID: String) -> String {
        switch colorID {
        case "blue": return "Blue"
        case "purple": return "Purple"
        case "pink": return "Pink"
        case "red": return "Red"
        case "orange": return "Orange"
        case "yellow": return "Yellow"
        case "green": return "Green"
        case "teal": return "Teal"
        case "graphite": return "Graphite"
        default: return colorID.capitalized
        }
    }
}
