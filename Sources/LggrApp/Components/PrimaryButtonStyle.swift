import SwiftUI

// The one prominent action style, plus the shortcut hint it renders.
// See docs/_design/04-screens.md § 3 and § 8.1.

/// The single prominent button style in Lggr. Every screen has exactly one primary action, and this
/// is what it looks like.
///
/// Sized for the ⌘⏎ action — "Start Focus", "Save", "Finish" — and it renders its own keyboard hint
/// inline so the shortcut is discoverable without a tooltip or a cheat sheet.
///
///     Button("Start Focus", action: start)
///         .buttonStyle(.lggrPrimary(shortcut: .defaultAction))
///         .keyboardShortcut(.defaultAction)
///
/// The style cannot register the shortcut itself — that is the caller's `.keyboardShortcut`. Passing
/// the same value to both is what keeps the label and the binding honest.
///
/// Foreground is `Color.white` over the accent's own fill, which is the same treatment AppKit gives
/// a `.borderedProminent` button and carries its guaranteed contrast. Nothing here scales on press;
/// the fill changes and the geometry holds still.
public struct PrimaryButtonStyle: ButtonStyle {
    private let shortcut: KeyboardShortcut?

    public init(shortcut: KeyboardShortcut? = nil) {
        self.shortcut = shortcut
    }

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, shortcut: shortcut)
    }
}

private struct PrimaryButtonBody: View {
    // `isEnabled` is only readable from a real view, which is why the style's body is a type of its
    // own rather than an inline `HStack`.
    @Environment(\.isEnabled) private var isEnabled

    let configuration: ButtonStyle.Configuration
    let shortcut: KeyboardShortcut?

    var body: some View {
        HStack(spacing: Space.s) {
            configuration.label
                .font(Type.rowTitle)
            if let shortcut {
                ShortcutHint(shortcut)
                    .foregroundStyle(Color.white.opacity(0.7))
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
        .background(fill, in: Theme.chipShape)
        .contentShape(Theme.chipShape)
        .lggrAnimation(Motion.tap, value: configuration.isPressed)
    }

    /// Disabled is a quieter fill, never red and never an error message. Validation in Lggr is
    /// "the button is not ready yet", not "you did something wrong".
    private var fill: Color {
        guard isEnabled else { return Color.accentColor.opacity(0.35) }
        return configuration.isPressed ? Color.accentColor.opacity(0.82) : Color.accentColor
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    /// The prominent action style, with no keyboard hint.
    public static var lggrPrimary: PrimaryButtonStyle { PrimaryButtonStyle() }

    /// The prominent action style, rendering `shortcut` inline as a hint.
    public static func lggrPrimary(shortcut: KeyboardShortcut?) -> PrimaryButtonStyle {
        PrimaryButtonStyle(shortcut: shortcut)
    }
}

// MARK: - Optional shortcuts

private struct OptionalShortcutModifier: ViewModifier {
    let shortcut: KeyboardShortcut?

    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

extension View {
    /// Registers a keyboard shortcut only when there is one, so a component can take an optional
    /// shortcut without every call site writing the branch.
    public func lggrKeyboardShortcut(_ shortcut: KeyboardShortcut?) -> some View {
        modifier(OptionalShortcutModifier(shortcut: shortcut))
    }
}

// MARK: - Shortcut hints

/// A keyboard shortcut rendered as its glyphs — "⌘⏎", "⌘⇧A".
///
/// Used inline by `PrimaryButtonStyle` and right-aligned by the menu bar popover's rows. It is
/// decorative: VoiceOver already announces a control's shortcut, so this is hidden from it.
public struct ShortcutHint: View {
    private let shortcut: KeyboardShortcut

    public init(_ shortcut: KeyboardShortcut) {
        self.shortcut = shortcut
    }

    public var body: some View {
        Text(ShortcutHint.display(shortcut))
            .font(Type.caption)
            .monospacedDigit()
            .accessibilityHidden(true)
    }

    /// "⌘⇧A" for a shortcut, in the order macOS prints modifiers: ⌃⌥⇧⌘.
    public static func display(_ shortcut: KeyboardShortcut) -> String {
        var glyphs = ""
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { glyphs += "⌃" }
        if modifiers.contains(.option) { glyphs += "⌥" }
        if modifiers.contains(.shift) { glyphs += "⇧" }
        if modifiers.contains(.command) { glyphs += "⌘" }
        return glyphs + key(shortcut.key)
    }

    private static func key(_ equivalent: KeyEquivalent) -> String {
        switch equivalent.character {
        case "\r": return "⏎"
        case "\t": return "⇥"
        case " ": return "␣"
        case "\u{7F}": return "⌫"
        case "\u{1B}": return "⎋"
        case "\u{F700}": return "↑"
        case "\u{F701}": return "↓"
        case "\u{F702}": return "←"
        case "\u{F703}": return "→"
        case "\u{F728}": return "⌦"
        case "\u{F729}": return "↖"
        case "\u{F72B}": return "↘"
        case "\u{F72C}": return "⇞"
        case "\u{F72D}": return "⇟"
        default: return String(equivalent.character).uppercased()
        }
    }
}
