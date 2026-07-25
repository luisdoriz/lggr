import SwiftUI
import LggrKit

// The menu bar's tracking indicator, and the one-click switch that turns it off.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE PRICE OF AMBIENT TRACKING, PAID UP FRONT
//
//  Lggr keeps a record of which application is in front of you whether or not you pressed start.
//  `INTELLIGENCE.md` § 2 sets the terms that make that acceptable, and both halves live in this
//  file: the state must be visible at a glance without opening anything, and stopping it must take
//  one click and no navigation. Neither is a Settings toggle. A switch buried two panes deep is not
//  a switch, it is a disclosure.
//
//  THE OTHER HALF: this glyph sits in the user's menu bar every waking hour, beside their clock and
//  their battery. It is therefore held to the strictest restraint in the application:
//
//    • **No colour. Ever.** Not orange, not red, not the accent. `Palette` allows exactly two
//      meaningful colours in Lggr and neither of them belongs to a state the user cannot fix and
//      did not cause.
//    • **No motion.** No pulse, no fade, no `.repeatForever` — none of which exists anywhere in
//      LggrApp (`Motion`) and none of which starts here. A recording indicator that breathes is a
//      nag with a nice font.
//    • **No badge, no dot, no count.** There is nothing here that grows.
//    • **Three distinct glyphs, not three weights of one.** Per § 2's own review, "a subtle filled
//      variant" is not perceptible in a 16pt menu bar item. The glyphs come from
//      `ActivityTrackingState.symbolName`, which is the settled vocabulary.
//
//  The one weight difference that is allowed: the state the *user* chose is drawn a step stronger
//  than the two they did not. Pausing is a decision, and a decision the app then hides is a decision
//  the app has quietly overruled.
// ─────────────────────────────────────────────────────────────────────────────────────────────

extension ActivityTrackingState {

    /// The user turned tracking off, however the state was arrived at.
    ///
    /// `ActivitySampler.updateState` publishes `.paused` while the sampler also carries
    /// `.trackingPaused` in its suspension set, so the second spelling should never reach a view.
    /// Matching both is a one-line guard against a control that says "Pause tracking" while tracking
    /// is already paused.
    var isPausedByUser: Bool {
        self == .paused || self == .suspended(.trackingPaused)
    }

    /// What the control that changes this state should be called. Verbs, not adjectives.
    var switchTitle: String {
        isPausedByUser ? "Resume tracking" : "Pause tracking"
    }
}

// MARK: - The glyph

/// The tracking state, as one symbol.
///
/// Built to sit inside the `MenuBarExtra` label alongside the session timer, and reused at the head
/// of the popover row and the Settings section so all three can never disagree about what a state
/// looks like.
///
/// `TrackingControls.currentState` is read **inside this view's own body**. That is deliberate and
/// load-bearing: Observation invalidates the view that performed the read and nothing else, so a
/// parent that resolves the state and hands a plain value down would leave this view with no tracked
/// dependency and the glyph would freeze on whatever it said at launch. `SPIKE-menubar.md`
/// documents the same trap for the timer digits.
@MainActor
public struct TrackingStateGlyph: View {

    /// How much of the label the glyph is allowed to occupy.
    public enum Size {
        /// Inside the menu bar label, next to the session symbol.
        case menuBar
        /// In a popover row or a Settings row, where it sits in the 18pt symbol column.
        case row
    }

    private let controls: TrackingControls?
    private let fixedState: ActivityTrackingState?
    private let size: Size

    /// The live glyph.
    public init(controls: TrackingControls, size: Size = .menuBar) {
        self.controls = controls
        self.fixedState = nil
        self.size = size
    }

    /// A frozen state, for the light/dark gallery and the headless snapshot renderer.
    ///
    /// **Never use this in the menu bar scene.** A pre-computed state means this view reads nothing
    /// observable, so nothing invalidates it and the glyph stops telling the truth.
    public init(state: ActivityTrackingState, size: Size = .menuBar) {
        self.controls = nil
        self.fixedState = state
        self.size = size
    }

    public var body: some View {
        // THE READ. Here, in this view's own body. See the note above.
        let state = fixedState ?? controls?.currentState() ?? .suspended(.notStarted)

        return Image(systemName: state.symbolName)
            .imageScale(size == .menuBar ? .small : .medium)
            .foregroundStyle(Self.style(for: state))
            .frame(
                width: size == .row ? Layout.symbolColumnWidth : nil,
                alignment: .center
            )
            .accessibilityLabel("Activity tracking")
            .accessibilityValue(state.displayName)
    }

    /// One weight for everything, and one step up for the single state the user chose themselves.
    ///
    /// No colour appears in either branch, and none may be added. `.secondary` is a shade quieter
    /// than the system items either side of it, which is most of what makes an always-present icon
    /// bearable; `.primary` on paused is what stops "I turned it off" from being invisible.
    private static func style(for state: ActivityTrackingState) -> HierarchicalShapeStyle {
        state.isPausedByUser ? .primary : .secondary
    }
}
