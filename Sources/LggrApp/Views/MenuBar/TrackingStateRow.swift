import SwiftUI
import LggrKit

// The tracking state, and the switch, in the menu bar popover.
// See docs/_design/04-screens.md § 5.1, INTELLIGENCE.md § 2.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  AN APP THAT RECORDS YOU MUST SAY SO WHERE YOU CAN ALWAYS SEE IT
//
//  Ambient capture runs from launch, whether or not a window is ever opened. `INTELLIGENCE.md` § 2
//  sets two conditions on that, and this row is the second one: the state must be visible without
//  opening anything, and stopping it must take **one click and no navigation**. A pause that lives
//  in Settings is not a switch, it is a disclosure — which is why this row exists and why the
//  privacy pane's toggle is not sufficient on its own.
//
//  Restraint, because this sits in the user's menu bar all day:
//
//    • **No colour.** Not orange, not red, not the accent. The glyph carries the state and the
//      weight carries whose decision it was (`TrackingStateGlyph`).
//    • **No motion, no badge, no dot, no count.** Nothing here pulses and nothing here grows. A
//      recording indicator that breathes is a nag with a nice font.
//    • **The verb, then the fact.** The title is what pressing it does; the trailing caption is what
//      is true right now. The user is never guessing which way the switch is thrown.
//    • **It stays pressable while the system has capture suspended** — asleep, screen locked,
//      another account on the console. Pausing then is a real intention ("do not start again when I
//      come back"), and a control that goes dead because the screen happened to lock is a control
//      people learn not to trust.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// **Pause tracking** / **Resume tracking**, as one popover row.
///
/// Built here rather than through `MenuBarRow` because that row is keyed to `MenuBarRowID`, whose
/// cases are the session actions; giving this one a session row's identity would put it in the
/// popover's arrow-key chain between "Quick Timer" and "Add Accomplishment", where it does not
/// belong. It matches that row's anatomy exactly — 28pt tall, `Radius.chip` hover fill, an 18pt
/// symbol column, a right-aligned `Type.caption` trailing element.
///
/// `TrackingControls.currentState` is read **inside this view's own body**, and that is
/// load-bearing: Observation invalidates the view that performed the read and nothing else, so a
/// parent that resolved the state and handed a plain value down would leave this row frozen on
/// whatever it said when the popover opened. `SPIKE-menubar.md` documents the same trap for the
/// timer digits.
@MainActor
public struct TrackingStateRow: View {

    private let controls: TrackingControls
    private let shortcut: KeyboardShortcut?

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    public init(controls: TrackingControls, shortcut: KeyboardShortcut? = nil) {
        self.controls = controls
        self.shortcut = shortcut
    }

    public var body: some View {
        // THE READ. Here, in the view that draws it.
        let state = controls.currentState()

        return Button {
            controls.setPaused(!state.isPausedByUser)
        } label: {
            HStack(spacing: Space.s) {
                TrackingStateGlyph(state: state, size: .row)
                    .accessibilityHidden(true)

                Text(state.switchTitle)
                    .font(Type.body)
                    .lineLimit(1)

                Spacer(minLength: Space.s)

                // "Tracking activity" / "Tracking paused" is Lggr's own statement about whether it is
                // recording the person reading it, and at `.tertiary` it was the faintest thing in the
                // popover in both appearances. It stays a caption; it stops being a whisper.
                Text(state.displayName)
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .lineLimit(1)

                if let shortcut {
                    ShortcutHint(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .frame(height: Layout.popoverRowHeight)
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: Theme.chipShape)
            .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
        // The row draws its own highlight; two rings on one control is noise.
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .lggrAnimation(Motion.tap, value: isFocused)
        .lggrKeyboardShortcut(shortcut)
        // "Pause tracking", value "Tracking activity" — the verb and the fact, in that order, which
        // is the order VoiceOver reads a control and its value.
        .accessibilityLabel(state.switchTitle)
        .accessibilityValue(state.displayName)
    }

    private var background: Color {
        if isFocused { return Surface.selected }
        if isHovering { return Surface.hover }
        return .clear
    }
}
