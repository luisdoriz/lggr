import SwiftUI

// The motion vocabulary. See docs/_design/04-screens.md § 2.8 and § 8.4.
//
// Nothing moves that the user did not move. Numbers change; the layout holds still.
//
// Three rules this file encodes:
//   • Nothing scales. Buttons change fill, not size — there is no `.scaleEffect` in LggrApp.
//   • Nothing repeats. `.repeatForever` does not appear in the codebase, which is what eliminates
//     pulsing dots, breathing rings and shimmer placeholders in one line.
//   • Reduce Motion is handled here, once, so no call site has to remember it. Always animate
//     through `.lggrAnimation(_:value:)`; never call `.animation(_:value:)` directly.

/// Five named animations. There is no sixth.
public enum Motion {
    /// Hover, press, focus ring. Must feel like the control was already there.
    public static let tap = Animation.easeOut(duration: 0.12)

    /// Cross-fades, selection moves, count changes, section collapse.
    public static let settle = Animation.easeInOut(duration: 0.22)

    /// Something appearing: a disclosure opening, a row inserting, panel content swapping.
    public static let reveal = Animation.spring(response: 0.32, dampingFraction: 0.86)

    /// The progress ring advancing one tick. Linear, so a second looks like a second.
    public static let ring = Animation.linear(duration: 1.0)

    /// Explicitly no animation. Used on the timer digits.
    public static let none: Animation? = nil

    /// What every animation collapses to under Reduce Motion: a change you can follow, not a move.
    public static let reduced = Animation.easeInOut(duration: 0.1)

    /// Resolves an animation for the current Reduce Motion setting.
    ///
    /// `ring` becomes a discrete update with no interpolation, because interpolating a progress arc
    /// is exactly the continuous movement the setting asks us not to make. Everything else becomes
    /// `reduced`.
    public static func resolved(_ animation: Animation?, reduceMotion: Bool) -> Animation? {
        guard reduceMotion else { return animation }
        guard let animation else { return nil }
        return animation == ring ? nil : reduced
    }
}

// MARK: - The one modifier every animation goes through

private struct LggrAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

private struct LggrNumericTextModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let countsDown: Bool

    func body(content: Content) -> some View {
        content.contentTransition(
            reduceMotion ? .identity : .numericText(countsDown: countsDown)
        )
    }
}

extension View {
    /// Animates a change, respecting Reduce Motion.
    ///
    /// `.lggrAnimation(.reveal, value: isExpanded)`. This is the only animation entry point in
    /// `LggrApp`, so Reduce Motion has exactly one place to be audited.
    public func lggrAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(LggrAnimationModifier(animation: animation, value: value))
    }

    /// Rolling digits for a number that counts, and `.identity` under Reduce Motion.
    ///
    /// The hero timer is the only place this belongs. The menu bar label uses no content transition
    /// at all: it redraws once per second, and a transition there is a battery cost with no benefit.
    public func lggrNumericText(countsDown: Bool = true) -> some View {
        modifier(LggrNumericTextModifier(countsDown: countsDown))
    }
}
