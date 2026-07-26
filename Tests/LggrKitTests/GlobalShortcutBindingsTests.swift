import Foundation
import Testing

@testable import LggrKit

/// Five configurable hot keys, one stored value, and three states per action — default, custom, off.
///
/// Everything here is a property the user cannot check by looking. If "off" cannot be told apart from
/// "never set", switching a shortcut off silently restores it on the next launch. If a custom value
/// equal to the default is stored as custom, *Use default* stays enabled forever and does nothing. If
/// the round trip drops the disabled set, a shortcut the user removed comes back. Each of those is a
/// setting that does not do what it says, which is the failure this feature exists to end — so each of
/// them is a test.
@Suite("Global shortcut bindings")
struct GlobalShortcutBindingsTests {

    // MARK: - Defaults

    @Test("Out of the box every action resolves to its own default")
    func defaultsResolveToDefaults() {
        let bindings = GlobalShortcutBindings.default
        for action in GlobalShortcutAction.allCases {
            #expect(bindings.shortcut(for: action) == action.defaultShortcut)
            #expect(!bindings.isCustom(action))
            #expect(!bindings.isDisabled(action))
        }
    }

    @Test("Every action is registered by default, and no two of them share a combination")
    func defaultsRegisterAllFiveDistinctly() {
        let resolved = GlobalShortcutBindings.default.resolved
        #expect(resolved.count == GlobalShortcutAction.allCases.count)
        #expect(Set(resolved.values).count == GlobalShortcutAction.allCases.count)
    }

    @Test("The defaults are not stored, so a later build may improve one")
    func defaultsAreNotWrittenDown() throws {
        let data = try JSONEncoder().encode(GlobalShortcutBindings.default)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("startSession"))
        #expect(!json.contains("space"))
    }

    // MARK: - Recording

    @Test("A recorded combination replaces the default and is marked as custom")
    func recordingSetsACustomShortcut() {
        var bindings = GlobalShortcutBindings.default
        let recorded = GlobalShortcut(key: "j", modifiers: [.control, .option])
        bindings.set(recorded, for: .quickSession)

        #expect(bindings.shortcut(for: .quickSession) == recorded)
        #expect(bindings.isCustom(.quickSession))
        // And nothing else moved.
        #expect(bindings.shortcut(for: .startSession) == GlobalShortcutAction.startSession.defaultShortcut)
        #expect(!bindings.isCustom(.startSession))
    }

    @Test("Recording the default back is not a customisation")
    func recordingTheDefaultIsNotCustom() {
        var bindings = GlobalShortcutBindings.default
        bindings.set(GlobalShortcut(key: "l", modifiers: [.control, .shift]), for: .quickSession)
        #expect(!bindings.isCustom(.quickSession))
        #expect(bindings.shortcut(for: .quickSession) == GlobalShortcutAction.quickSession.defaultShortcut)
    }

    @Test("Case is not a customisation either")
    func recordingIsCaseInsensitive() {
        var bindings = GlobalShortcutBindings.default
        bindings.set(GlobalShortcut(key: "L", modifiers: [.control, .shift]), for: .quickSession)
        #expect(!bindings.isCustom(.quickSession))
    }

    @Test("Reset puts an action back exactly as Lggr ships it")
    func resetRestoresTheDefault() {
        var bindings = GlobalShortcutBindings.default
        bindings.set(GlobalShortcut(key: "j", modifiers: [.command]), for: .pauseResume)
        bindings.disable(.pauseResume)
        bindings.reset(.pauseResume)

        #expect(bindings.shortcut(for: .pauseResume) == GlobalShortcutAction.pauseResume.defaultShortcut)
        #expect(!bindings.isCustom(.pauseResume))
        #expect(!bindings.isDisabled(.pauseResume))
    }

    // MARK: - Switching one off

    @Test("A disabled action has no shortcut and registers nothing")
    func disabledActionRegistersNothing() {
        var bindings = GlobalShortcutBindings.default
        bindings.disable(.addAccomplishment)

        #expect(bindings.shortcut(for: .addAccomplishment) == nil)
        #expect(bindings.isDisabled(.addAccomplishment))
        #expect(bindings.resolved[.addAccomplishment] == nil)
        #expect(bindings.resolved.count == GlobalShortcutAction.allCases.count - 1)
    }

    @Test("Off is a decision, and it is not the same value as never having been set")
    func disabledIsDistinctFromDefault() {
        var bindings = GlobalShortcutBindings.default
        bindings.disable(.addAccomplishment)
        #expect(bindings != GlobalShortcutBindings.default)
        #expect(bindings.isCustom(.addAccomplishment))
    }

    @Test("Switching an action off keeps the combination it would use when switched back on")
    func disablingKeepsTheRecordedCombination() {
        var bindings = GlobalShortcutBindings.default
        let recorded = GlobalShortcut(key: "k", modifiers: [.command, .option])
        bindings.set(recorded, for: .captureInterruption)
        bindings.disable(.captureInterruption)

        #expect(bindings.shortcut(for: .captureInterruption) == nil)
        #expect(bindings.editedShortcut(for: .captureInterruption) == recorded)

        bindings.set(recorded, for: .captureInterruption)
        #expect(bindings.shortcut(for: .captureInterruption) == recorded)
    }

    // MARK: - Conflicts

    @Test("A combination another action already holds is attributed to that action")
    func conflictNamesTheOwningAction() {
        let bindings = GlobalShortcutBindings.default
        let quick = GlobalShortcutAction.quickSession.defaultShortcut
        #expect(bindings.owner(of: quick, excluding: .startSession) == .quickSession)
    }

    @Test("An action does not conflict with itself")
    func anActionIsNotItsOwnConflict() {
        let bindings = GlobalShortcutBindings.default
        let quick = GlobalShortcutAction.quickSession.defaultShortcut
        #expect(bindings.owner(of: quick, excluding: .quickSession) == nil)
    }

    @Test("A combination nothing holds has no owner")
    func unclaimedCombinationHasNoOwner() {
        let bindings = GlobalShortcutBindings.default
        let unused = GlobalShortcut(key: "9", modifiers: [.control, .option, .shift])
        #expect(bindings.owner(of: unused, excluding: .startSession) == nil)
    }

    @Test("A disabled action cannot own a combination")
    func disabledActionOwnsNothing() {
        var bindings = GlobalShortcutBindings.default
        bindings.disable(.quickSession)
        let quick = GlobalShortcutAction.quickSession.defaultShortcut
        #expect(bindings.owner(of: quick, excluding: .startSession) == nil)
    }

    @Test("Conflict detection ignores the case a shortcut was recorded in")
    func conflictIsCaseInsensitive() {
        let bindings = GlobalShortcutBindings.default
        let shouted = GlobalShortcut(key: "L", modifiers: [.control, .shift])
        #expect(bindings.owner(of: shouted, excluding: .startSession) == .quickSession)
    }

    // MARK: - Round trip

    @Test("Custom shortcuts and switched-off actions both survive a round trip")
    func roundTripKeepsEverything() throws {
        var bindings = GlobalShortcutBindings.default
        bindings.set(GlobalShortcut(key: "j", modifiers: [.control, .option]), for: .quickSession)
        bindings.disable(.pauseResume)

        let data = try JSONEncoder().encode(bindings)
        let decoded = try JSONDecoder().decode(GlobalShortcutBindings.self, from: data)

        #expect(decoded == bindings)
        #expect(decoded.shortcut(for: .quickSession)?.displayString == "⌃⌥J")
        #expect(decoded.shortcut(for: .pauseResume) == nil)
    }

    @Test("Actions are written under their own names, not as a positional array")
    func encodesWithActionNamesAsKeys() throws {
        var bindings = GlobalShortcutBindings.default
        bindings.set(GlobalShortcut(key: "j", modifiers: [.command]), for: .quickSession)

        let data = try JSONEncoder().encode(bindings)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("quickSession"))
    }

    @Test("An action name this build does not know is dropped, not fatal")
    func unknownActionTokenIsDropped() throws {
        let json = Data(
            #"{"custom":{"telepathy":{"key":"t","modifiers":8}},"disabled":["telepathy"]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(GlobalShortcutBindings.self, from: json)
        #expect(decoded == .default)
    }

    @Test("An empty object decodes to the defaults rather than to nothing at all")
    func emptyObjectDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(
            GlobalShortcutBindings.self, from: Data("{}".utf8))
        #expect(decoded == .default)
        #expect(decoded.resolved.count == GlobalShortcutAction.allCases.count)
    }

    // MARK: - Recording from a key press

    @Test("Every default round-trips through the key code the recorder reads")
    func keyCodesRoundTripThroughTheRecorder() throws {
        for action in GlobalShortcutAction.allCases {
            let original = action.defaultShortcut
            let code = try #require(original.virtualKeyCode)
            let recorded = try #require(
                GlobalShortcut(virtualKeyCode: code, modifiers: original.modifiers))
            #expect(recorded == original)
        }
    }

    @Test("A key this build has no code for is refused rather than guessed at")
    func unmappableKeyCodeIsRefused() {
        // 0x50 is a numeric keypad key; the tables cover no keypad positions.
        #expect(GlobalShortcut(virtualKeyCode: 0x50, modifiers: [.command]) == nil)
    }

    @Test(
        "The recorder reads the same physical positions the registrar writes",
        arguments: [
            (UInt32(37), "L"),
            (UInt32(49), "Space"),
            (UInt32(0), "A"),
            (UInt32(126), "↑"),
            (UInt32(122), "F1"),
        ]
    )
    func recordedKeysReadBackCorrectly(pair: (UInt32, String)) throws {
        let recorded = try #require(GlobalShortcut(virtualKeyCode: pair.0, modifiers: [.control]))
        #expect(recorded.keyDisplayName == pair.1)
    }

    // MARK: - The field that used to do nothing

    @Test("Writing globalShortcut changes the hot key that is actually registered")
    func globalShortcutWritesThroughToTheBindings() {
        var preferences = UserPreferences()
        let recorded = GlobalShortcut(key: "j", modifiers: [.control, .option])
        preferences.globalShortcut = recorded

        #expect(preferences.shortcuts.shortcut(for: .startSession) == recorded)
        #expect(preferences.shortcuts.resolved[.startSession] == recorded)
        #expect(preferences.globalShortcut == recorded)
    }

    @Test("A preferences file from a build that only knew globalShortcut still binds it")
    func legacyGlobalShortcutBecomesTheStartSessionBinding() throws {
        let json = Data(#"{"globalShortcut":{"key":"j","modifiers":9}}"#.utf8)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: json)

        #expect(decoded.shortcuts.shortcut(for: .startSession)?.displayString == "⌃⌘J")
        #expect(decoded.shortcuts.isCustom(.startSession))
        // The other four are untouched by a file that never mentioned them.
        #expect(decoded.shortcuts.shortcut(for: .quickSession)?.displayString == "⌃⇧L")
    }

    @Test("The legacy field is still written, so downgrading keeps the start-session hot key")
    func legacyGlobalShortcutIsStillWritten() throws {
        var preferences = UserPreferences()
        preferences.globalShortcut = GlobalShortcut(key: "j", modifiers: [.control, .option])

        let data = try JSONEncoder().encode(preferences)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("globalShortcut"))
        #expect(json.contains("shortcuts"))
    }

    @Test("A start-session hot key switched off is not resurrected by the legacy field")
    func disablingStartSessionSurvivesTheLegacyMirror() throws {
        var preferences = UserPreferences()
        var bindings = preferences.shortcuts
        bindings.disable(.startSession)
        preferences.shortcuts = bindings

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

        #expect(decoded.shortcuts.isDisabled(.startSession))
        #expect(decoded.shortcuts.shortcut(for: .startSession) == nil)
        #expect(decoded.shortcuts.resolved[.startSession] == nil)
    }

    @Test("All five shortcuts survive being stored in preferences together")
    func allFiveSurviveAPreferencesRoundTrip() throws {
        var preferences = UserPreferences()
        var bindings = preferences.shortcuts
        bindings.set(GlobalShortcut(key: "1", modifiers: [.control, .option]), for: .startSession)
        bindings.set(GlobalShortcut(key: "2", modifiers: [.control, .option]), for: .quickSession)
        bindings.set(
            GlobalShortcut(key: "3", modifiers: [.control, .option]), for: .captureInterruption)
        bindings.set(
            GlobalShortcut(key: "4", modifiers: [.control, .option]), for: .addAccomplishment)
        bindings.disable(.pauseResume)
        preferences.shortcuts = bindings

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)

        #expect(decoded.shortcuts == bindings)
        #expect(decoded.shortcuts.resolved.count == 4)
        #expect(decoded.globalShortcut.displayString == "⌃⌥1")
        // Everything else in the blob is still there.
        #expect(decoded.defaultSessionDuration == preferences.defaultSessionDuration)
    }

    @Test("Nothing in a preferences round trip loses the rest of the settings")
    func roundTripPreservesUnrelatedSettings() throws {
        var preferences = UserPreferences(
            defaultSessionDuration: 25 * 60,
            dataRetentionDays: 30,
            showTimerInMenuBar: false,
            lastProjectID: UUID()
        )
        preferences.recordOutcome("Ship the recorder")
        preferences.globalShortcut = GlobalShortcut(key: "u", modifiers: [.command, .control])

        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
        #expect(decoded == preferences)
    }
}
