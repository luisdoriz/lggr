import SwiftUI

// The active session's two controls. See docs/_design/04-screens.md § 4.1 and § 10.4.
//
// Two *buttons*, and there will never be a third here. `Capture` (`⌘⇧I`) arrives with interruptions in
// Phase 3 and belongs in this row when it does; nothing else does. A running session offers one
// reversible action and one final one, and a row of five buttons under a hero timer is a toolbar.
//
// `Discard` is the one addition, and it is deliberately not a button in that sense: borderless,
// `.secondary`, no fill and no border, sitting at the leading edge with the whole width of the row
// between it and Finish. It exists because until it did, the only way out of a session was to finish
// it — so a session begun by pressing the wrong thing stayed in the log for good, which is how a
// record of a day acquires entries that never happened. It destroys data, so it never acts directly:
// it asks its host to confirm, and `ActiveSessionView` owns that confirmation.

/// Pause / Resume, Discard, and Finish.
///
/// The pause button's title is derived from the session's actual state rather than from a local
/// toggle, so it can never disagree with the timer above it — the same button is driven from the menu
/// bar popover, the Space key and the Session menu, and none of those coordinate with each other.
///
/// **Finish is the screen's one primary action** (`⌘⏎`). Pause is quieter by construction: it is
/// bordered, not filled, because pausing is a detour and finishing is the point. Discard is quieter
/// still, and carries no key equivalent at all — nothing that erases work is one keystroke away.
public struct SessionControls: View {

    /// `Space`, per the keyboard map in § 7.1. It carries no modifier, so it is only ever delivered
    /// when no text field is editing — AppKit routes a bare space character to the first responder,
    /// and a focused field is always a closer responder than a button's key equivalent.
    public static let pauseShortcut = KeyboardShortcut(.space, modifiers: [])

    /// `⌘⏎` — the contextual "confirm" shortcut of § 7.2, which reads "Finish Session" here.
    public static let finishShortcut = KeyboardShortcut(.return, modifiers: .command)

    private let isPaused: Bool
    private let onTogglePause: () -> Void
    private let onFinish: () -> Void
    private let onDiscard: (() -> Void)?

    /// - Parameter onDiscard: asks the host to confirm discarding the session. `nil` removes the
    ///   control rather than disabling it — a control that cannot act is worse than an absent one.
    public init(
        isPaused: Bool,
        onTogglePause: @escaping () -> Void,
        onFinish: @escaping () -> Void,
        onDiscard: (() -> Void)? = nil
    ) {
        self.isPaused = isPaused
        self.onTogglePause = onTogglePause
        self.onFinish = onFinish
        self.onDiscard = onDiscard
    }

    public var body: some View {
        HStack(spacing: Space.m) {
            Button(action: onTogglePause) {
                HStack(spacing: Space.xs) {
                    Image(systemName: isPaused ? Icon.resume : Icon.pause)
                        .imageScale(.small)
                    Text(pauseTitle)
                    ShortcutHint(Self.pauseShortcut)
                        .foregroundStyle(.tertiary)
                }
                .font(Type.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(Self.pauseShortcut)
            .accessibilityLabel(pauseTitle)
            .help(isPaused ? "Resume this session" : "Pause this session")

            if let onDiscard {
                Button("Discard", action: onDiscard)
                    .buttonStyle(.borderless)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .help("Discard this session without recording it")
            }

            Spacer(minLength: Space.m)

            Button("Finish", action: onFinish)
                .buttonStyle(.lggrPrimary(shortcut: Self.finishShortcut))
                .keyboardShortcut(Self.finishShortcut)
                .help("Finish this session and review it")
        }
        .lggrAnimation(Motion.settle, value: isPaused)
        .accessibilityElement(children: .contain)
    }

    private var pauseTitle: String { isPaused ? "Resume" : "Pause" }
}
