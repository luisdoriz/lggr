import AppKit
import LggrKit
import SwiftUI

// Settings ▸ Shortcuts. See docs/_design/04-screens.md § 4.7 and § 7.1.
//
// This pane was deliberately absent until now, and the reason it was absent is written into
// `SettingsView`: it would have configured a hot key that nothing registered. It exists because that
// is no longer true — `AppEnvironment.applyShortcuts()` registers exactly what this pane writes, and
// writes it the moment the user records it.
//
// The one design rule here that is not cosmetic: **a shortcut that failed to register says so, on its
// own row.** `RegisterEventHotKey` refuses a combination another application already holds, and there
// is no way to know that in advance — so the pane cannot prevent the collision, only report it. § 4.7
// names this exact case ("⌘⇧Space is already taken by another app. Pick a different combination.") and
// the alternative is a user pressing a dead key and concluding the app is broken.
//
// The honest caveat, recorded here because it cannot be fixed: a handful of combinations the *system*
// reserves register successfully and then never fire. macOS exposes no API that reports it. Those we
// cannot surface, and the pane does not pretend otherwise.

/// The Shortcuts tab: five rows, each an action, its keys, and a way to change them.
@MainActor
public struct ShortcutSettingsView: View {

    @Bindable private var preferences: AppPreferences

    /// The live registrations, for the failure under a row.
    ///
    /// Optional because the gallery and the snapshot renderer draw this pane with no composition root.
    /// Its state is read inside `body`, which is what keeps the failure lines live: `apply(_:)` runs
    /// as a result of a write here, and the row that caused it updates in the same frame.
    private let service: GlobalShortcutService?

    /// Which row is listening for keys. At most one — recording installs a key monitor, and two of
    /// them competing for the same keystroke is not a state worth being able to reach.
    @State private var recording: GlobalShortcutAction?

    /// Why the last recording was refused, and for which row. Cleared by the next attempt.
    @State private var rejection: Rejection?

    private struct Rejection: Equatable {
        let action: GlobalShortcutAction
        let message: String
    }

    public init(preferences: AppPreferences, service: GlobalShortcutService? = nil) {
        self.preferences = preferences
        self.service = service
    }

    public var body: some View {
        SettingsForm {
            Section("Global shortcuts") {
                ForEach(GlobalShortcutAction.allCases, id: \.self) { action in
                    row(for: action)
                }
            }

            Section {
                Text(
                    "These work from any application. Lggr asks for no permissions to use them, and "
                        + "never reads what you type anywhere else."
                )
                .font(Type.caption)
                .foregroundStyle(Ink.support)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Layout.reviewSheetWidth)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shortcuts")
    }

    // MARK: - One row

    private func row(for action: GlobalShortcutAction) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            LabeledContent {
                HStack(spacing: Space.s) {
                    ShortcutRecorder(
                        action: action,
                        shortcut: preferences.shortcuts.shortcut(for: action),
                        isRecording: recording == action,
                        onStartRecording: { startRecording(action) },
                        onStopRecording: stopRecording,
                        onRecord: { record($0, for: action) },
                        onUnusableKey: { refuseUnusableKey(for: action) }
                    )

                    Button("Use default") { reset(action) }
                        .buttonStyle(.borderless)
                        .font(Type.secondary)
                        .disabled(!preferences.shortcuts.isCustom(action))
                        .help("Restore \(action.defaultShortcut.displayString)")
                        .accessibilityLabel("Use the default shortcut for \(action.title)")

                    Button("Turn off") { disable(action) }
                        .buttonStyle(.borderless)
                        .font(Type.secondary)
                        .disabled(preferences.shortcuts.isDisabled(action))
                        .help("Remove this shortcut. The action stays available in the menus.")
                        .accessibilityLabel("Turn off the shortcut for \(action.title)")
                }
            } label: {
                Text(action.title)
                    .font(Type.body)
            }

            if let note = note(for: action) {
                Text(note)
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("\(action.title): \(note)")
            }
        }
    }

    /// The one line under a row, in priority order.
    ///
    /// Only ever one. Three of these can be true at once — a rejected recording, a registration macOS
    /// refused, and an action switched off — and stacking them would bury the sentence that describes
    /// what the user just did under two that describe what they did earlier.
    private func note(for action: GlobalShortcutAction) -> String? {
        if let rejection, rejection.action == action { return rejection.message }
        if recording == action { return "Press the keys you want. Esc cancels." }
        // The service's own words. `Failure.message` is the copy § 4.7 specifies, and it always ends
        // in what to do about it.
        if let failure = service?.failure(for: action) { return failure.message }
        if preferences.shortcuts.isDisabled(action) {
            return "Off. \(action.title) is still available in the menus and the menu bar."
        }
        return nil
    }

    // MARK: - Recording

    private func startRecording(_ action: GlobalShortcutAction) {
        rejection = nil
        recording = action
    }

    private func stopRecording() {
        recording = nil
    }

    /// Accepts a recorded combination, or refuses it and says why.
    ///
    /// Two refusals happen here rather than at registration time, because both are knowable now and
    /// both have a better answer than "macOS declined":
    ///
    ///   * **Another Lggr action owns it.** Named, so the user knows which row to change. The service
    ///     would otherwise register the first of the two and report the second as a duplicate, which
    ///     is the same fact arriving later and from further away.
    ///   * **No `⌘`, `⌃` or `⌥`.** A global hot key on a bare letter swallows that letter in every
    ///     application on the machine. That is not a shortcut, it is a broken keyboard.
    private func record(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) {
        recording = nil

        guard shortcut.isValidGlobalCombination else {
            rejection = Rejection(
                action: action,
                message: "\(shortcut.displayString) needs ⌘, ⌃ or ⌥ to work from other applications."
            )
            return
        }

        if let owner = preferences.shortcuts.owner(of: shortcut, excluding: action) {
            rejection = Rejection(
                action: action,
                message:
                    "\(shortcut.displayString) is already used for \"\(owner.title)\". "
                    + "Pick a different combination."
            )
            return
        }

        rejection = nil
        var updated = preferences.shortcuts
        updated.set(shortcut, for: action)
        preferences.shortcuts = updated
    }

    /// The recorder could not name the key that was pressed, so nothing is stored.
    private func refuseUnusableKey(for action: GlobalShortcutAction) {
        recording = nil
        rejection = Rejection(
            action: action,
            message: "Lggr can't use that key as a global shortcut. Pick a different combination."
        )
    }

    private func reset(_ action: GlobalShortcutAction) {
        rejection = nil
        recording = nil
        var updated = preferences.shortcuts
        updated.reset(action)
        preferences.shortcuts = updated
    }

    private func disable(_ action: GlobalShortcutAction) {
        rejection = nil
        recording = nil
        var updated = preferences.shortcuts
        updated.disable(action)
        preferences.shortcuts = updated
    }
}

// MARK: - The recorder

/// The field that listens for a key combination.
///
/// A button, not a text field: there is nothing to type and nothing to edit. Pressing it starts
/// listening, pressing `Esc` — or clicking it again — stops.
///
/// **The listening is a *local* monitor.** `NSEvent.addLocalMonitorForEvents` sees only events already
/// delivered to Lggr, which is why it needs no permission of any kind; a global monitor would see
/// every keystroke on the machine and would require Accessibility, and this app requests nothing.
/// While a recording is in progress the monitor swallows the event by returning `nil`, so `⌘Q` records
/// as a shortcut instead of quitting the app the user is configuring.
@MainActor
private struct ShortcutRecorder: View {

    let action: GlobalShortcutAction
    /// `nil` when the action is switched off.
    let shortcut: GlobalShortcut?
    let isRecording: Bool
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onRecord: (GlobalShortcut) -> Void
    /// A key with no virtual key code in this build. Reported rather than substituted: recording one
    /// combination and storing another is worse than refusing.
    let onUnusableKey: () -> Void

    /// Removed on the way out of every path — a monitor that outlived the pane would keep swallowing
    /// keystrokes in a window that is no longer asking for any.
    /// `Any?` because that is what `addLocalMonitorForEvents` returns — an opaque token whose only
    /// use is handing it back to `removeMonitor`.
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(label)
                .font(Type.body)
                .monospacedDigit()
                .frame(minWidth: Layout.shortcutFieldWidth)
        }
        .buttonStyle(.bordered)
        .help(helpText)
        .accessibilityLabel("Shortcut for \(action.title)")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Activate, then press the keys you want.")
        .onChange(of: isRecording) { _, isRecording in
            if isRecording { install() } else { remove() }
        }
        .onDisappear(perform: remove)
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return shortcut?.displayString ?? "Off"
    }

    private var helpText: String {
        if isRecording { return "Press a combination, or Esc to cancel" }
        return "Record a new shortcut for \(action.title)"
    }

    /// The glyphs are not spoken usefully — `⌃⇧L` reads as punctuation — so VoiceOver gets the words.
    private var spokenValue: String {
        guard let shortcut else { return "Off" }
        var parts: [String] = []
        if shortcut.modifiers.contains(.control) { parts.append("Control") }
        if shortcut.modifiers.contains(.option) { parts.append("Option") }
        if shortcut.modifiers.contains(.shift) { parts.append("Shift") }
        if shortcut.modifiers.contains(.command) { parts.append("Command") }
        parts.append(shortcut.keyDisplayName)
        return parts.joined(separator: " ")
    }

    private func toggle() {
        if isRecording {
            onStopRecording()
        } else {
            onStartRecording()
        }
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event -> NSEvent? in
            MainActor.assumeIsolated { handle(event) }
            // Swallowed: while recording, a key combination is data, not a command.
            return nil
        }
    }

    private func remove() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    private func handle(_ event: NSEvent) {
        // Esc alone cancels. Esc *with* a modifier is a legitimate combination, so it is recorded like
        // any other — cancelling on it would make one perfectly good shortcut unreachable.
        let modifiers = Self.modifiers(from: event.modifierFlags)
        if event.keyCode == Self.escapeKeyCode, modifiers.isEmpty {
            onStopRecording()
            return
        }

        // A key this build has no code for is refused by `init?`, and the row then says so rather than
        // storing a combination that could never be registered.
        guard
            let recorded = GlobalShortcut(
                virtualKeyCode: UInt32(event.keyCode),
                modifiers: modifiers
            )
        else {
            onUnusableKey()
            return
        }
        onRecord(recorded)
    }

    /// `kVK_Escape`. Written as the number for the reason `GlobalShortcut`'s tables are: this file
    /// imports AppKit but the key codes are Carbon's, and one constant is not worth an import.
    private static let escapeKeyCode: UInt16 = 53

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> GlobalShortcut.Modifiers {
        var modifiers = GlobalShortcut.Modifiers()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
