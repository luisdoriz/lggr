import Foundation
import Testing

@testable import LggrKit

/// A global hot key is the one part of this app whose correctness the user cannot verify by looking.
/// If the glyph order is wrong the app looks broken; if the key code is wrong the wrong key fires; if
/// the Codable round trip drops a modifier the shortcut silently becomes something else after a
/// relaunch — and every one of those is a shortcut that is configurable but does not work, which is
/// the exact defect this feature was written to end.
///
/// `GlobalShortcutService` cannot be unit-tested on this machine, so everything it relies on is
/// tested here instead: the display string, the parse, the round trip, the conflict notion, the key
/// tables and the defaults.
@Suite("Global shortcut")
struct GlobalShortcutTests {

    // MARK: - Modifier glyph order

    @Test("Modifier glyphs are written in the conventional macOS order ⌃⌥⇧⌘")
    func glyphOrderIsConventional() {
        #expect(GlobalShortcut.Modifiers.all.displayString == "⌃⌥⇧⌘")
    }

    @Test("Glyph order does not follow the order the flags were written in")
    func glyphOrderIgnoresInsertionOrder() {
        let written: GlobalShortcut.Modifiers = [.command, .shift, .option, .control]
        let reversed: GlobalShortcut.Modifiers = [.control, .option, .shift, .command]
        #expect(written.displayString == "⌃⌥⇧⌘")
        #expect(reversed.displayString == "⌃⌥⇧⌘")
    }

    @Test(
        "Every modifier pair reads in order",
        arguments: [
            (GlobalShortcut.Modifiers([.control, .shift]), "⌃⇧"),
            (GlobalShortcut.Modifiers([.command, .shift]), "⇧⌘"),
            (GlobalShortcut.Modifiers([.command, .option]), "⌥⌘"),
            (GlobalShortcut.Modifiers([.control, .command]), "⌃⌘"),
            (GlobalShortcut.Modifiers([.option, .shift]), "⌥⇧"),
            (GlobalShortcut.Modifiers([.control, .option]), "⌃⌥"),
            (GlobalShortcut.Modifiers([.command, .option, .shift]), "⌥⇧⌘"),
            (GlobalShortcut.Modifiers([.control, .shift, .command]), "⌃⇧⌘"),
        ]
    )
    func pairsReadInOrder(pair: (GlobalShortcut.Modifiers, String)) {
        #expect(pair.0.displayString == pair.1)
    }

    @Test("No modifiers produces no glyphs")
    func noModifiersNoGlyphs() {
        #expect(GlobalShortcut.Modifiers().displayString == "")
    }

    // MARK: - Display strings

    @Test("The five defaults read the way the design doc writes them")
    func defaultsReadCorrectly() {
        #expect(GlobalShortcutAction.startSession.defaultShortcut.displayString == "⇧⌘Space")
        #expect(GlobalShortcutAction.quickSession.defaultShortcut.displayString == "⌃⇧L")
        #expect(GlobalShortcutAction.captureInterruption.defaultShortcut.displayString == "⇧⌘I")
        #expect(GlobalShortcutAction.addAccomplishment.defaultShortcut.displayString == "⇧⌘A")
        #expect(GlobalShortcutAction.pauseResume.defaultShortcut.displayString == "⌃⇧P")
    }

    @Test("A letter is displayed uppercase however it was stored")
    func lettersDisplayUppercase() {
        #expect(GlobalShortcut(key: "L", modifiers: [.control, .shift]).displayString == "⌃⇧L")
        #expect(GlobalShortcut(key: "l", modifiers: [.control, .shift]).displayString == "⌃⇧L")
    }

    @Test(
        "Named keys have names rather than tokens",
        arguments: [
            ("space", "Space"), ("return", "Return"), ("tab", "Tab"), ("escape", "Escape"),
            ("delete", "Delete"), ("pageup", "Page Up"), ("pagedown", "Page Down"),
            ("home", "Home"), ("end", "End"), ("forwarddelete", "Forward Delete"),
            ("left", "←"), ("right", "→"), ("up", "↑"), ("down", "↓"),
            ("f1", "F1"), ("f12", "F12"),
        ]
    )
    func namedKeysDisplayNames(pair: (String, String)) {
        let shortcut = GlobalShortcut(key: pair.0, modifiers: [.command])
        #expect(shortcut.keyDisplayName == pair.1)
        #expect(shortcut.displayString == "⌘" + pair.1)
    }

    @Test("Digits and punctuation display as themselves")
    func punctuationDisplaysItself() {
        #expect(GlobalShortcut(key: "1", modifiers: [.command]).displayString == "⌘1")
        #expect(GlobalShortcut(key: ",", modifiers: [.command]).displayString == "⌘,")
        #expect(GlobalShortcut(key: "/", modifiers: [.command]).displayString == "⌘/")
        #expect(GlobalShortcut(key: "-", modifiers: [.command]).displayString == "⌘-")
    }

    // MARK: - Normalisation

    @Test("The key is lowercased on the way in, so case cannot split one shortcut into two")
    func keyIsNormalised() {
        #expect(GlobalShortcut(key: "L", modifiers: [.control]).key == "l")
        #expect(GlobalShortcut(key: "SPACE", modifiers: [.command]).key == "space")
        #expect(
            GlobalShortcut(key: "L", modifiers: [.control])
                == GlobalShortcut(key: "l", modifiers: [.control])
        )
    }

    @Test("Unknown modifier bits are dropped rather than kept as an invisible difference")
    func unknownModifierBitsAreDropped() {
        let contaminated = GlobalShortcut.Modifiers(rawValue: 0b1111_0011)
        let shortcut = GlobalShortcut(key: "l", modifiers: contaminated)
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(shortcut.modifiers.displayString == "⇧⌘")
    }

    // MARK: - Parsing

    @Test(
        "Every default parses back from what it displays",
        arguments: GlobalShortcutAction.allCases
    )
    func defaultsRoundTripThroughDisplay(action: GlobalShortcutAction) {
        let shortcut = action.defaultShortcut
        #expect(GlobalShortcut(displayString: shortcut.displayString) == shortcut)
    }

    @Test(
        "Every named key parses back from its display name",
        arguments: GlobalShortcut.namedKeys.map(\.token)
    )
    func namedKeysRoundTrip(token: String) {
        let shortcut = GlobalShortcut(key: token, modifiers: [.command, .option])
        #expect(GlobalShortcut(displayString: shortcut.displayString) == shortcut)
    }

    @Test(
        "Every character key parses back from its display name",
        arguments: GlobalShortcut.characterKeys.keys.sorted()
    )
    func characterKeysRoundTrip(token: String) {
        let shortcut = GlobalShortcut(key: token, modifiers: [.control])
        #expect(GlobalShortcut(displayString: shortcut.displayString) == shortcut)
    }

    @Test("Glyphs may arrive in any order, because a hand-edited file is still a file we must read")
    func parsingToleratesGlyphOrder() {
        let expected = GlobalShortcut(key: "l", modifiers: [.control, .shift, .command])
        #expect(GlobalShortcut(displayString: "⌃⇧⌘L") == expected)
        #expect(GlobalShortcut(displayString: "⌘⇧⌃L") == expected)
        #expect(GlobalShortcut(displayString: "⇧⌘⌃l") == expected)
    }

    @Test("A repeated glyph means the same thing as writing it once")
    func parsingToleratesRepeatedGlyphs() {
        #expect(
            GlobalShortcut(displayString: "⌘⌘⇧Space")
                == GlobalShortcut(key: "space", modifiers: [.command, .shift])
        )
    }

    @Test("Key names parse case-insensitively and ignore the space inside them")
    func parsingIsCaseAndSpaceInsensitive() {
        #expect(GlobalShortcut(displayString: "⌘space")?.key == "space")
        #expect(GlobalShortcut(displayString: "⌘SPACE")?.key == "space")
        #expect(GlobalShortcut(displayString: "⌘Page Up")?.key == "pageup")
        #expect(GlobalShortcut(displayString: "⌘pageup")?.key == "pageup")
    }

    @Test("A key nothing can register refuses to parse rather than parsing into a dead shortcut")
    func parsingRejectsUnmappableKeys() {
        #expect(GlobalShortcut(displayString: "⌘F13") == nil)
        #expect(GlobalShortcut(displayString: "⌘LL") == nil)
        #expect(GlobalShortcut(displayString: "⌘🙂") == nil)
        #expect(GlobalShortcut(displayString: "") == nil)
        #expect(GlobalShortcut(displayString: "⌃⇧") == nil)
        #expect(GlobalShortcut(displayString: "   ") == nil)
    }

    @Test("A bare key with no glyphs parses, and is then rejected as a global combination")
    func parsingABareKeySucceedsButIsNotValid() {
        let parsed = GlobalShortcut(displayString: "L")
        #expect(parsed?.key == "l")
        #expect(parsed?.modifiers == [])
        #expect(parsed?.isValidGlobalCombination == false)
    }

    // MARK: - Codable

    @Test("A stored shortcut survives a Codable round trip")
    func codableRoundTrip() throws {
        for action in GlobalShortcutAction.allCases {
            let data = try JSONEncoder().encode(action.defaultShortcut)
            let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: data)
            #expect(decoded == action.defaultShortcut)
        }
    }

    @Test("Modifiers encode as a bare integer, not as an object")
    func modifiersEncodeAsAnInteger() throws {
        let data = try JSONEncoder().encode(
            GlobalShortcut(key: "l", modifiers: [.control, .shift]))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"modifiers\":10"))
        #expect(!json.contains("rawValue"))
    }

    @Test("Decoding lowercases the key, so a hand-edited file cannot defeat conflict detection")
    func decodingNormalisesTheKey() throws {
        let json = Data(#"{"key":"L","modifiers":10}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: json)
        #expect(decoded.key == "l")
        #expect(decoded == GlobalShortcut(key: "l", modifiers: [.control, .shift]))
    }

    @Test("Decoding masks off modifier bits this version does not know")
    func decodingMasksUnknownBits() throws {
        let json = Data(#"{"key":"space","modifiers":259}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: json)
        #expect(decoded.modifiers == [.command, .shift])
    }

    @Test("A shortcut decoded from an older file still equals the same shortcut built in code")
    func decodedShortcutMatchesConstructed() throws {
        let json = Data(#"{"key":"space","modifiers":3}"#.utf8)
        let decoded = try JSONDecoder().decode(GlobalShortcut.self, from: json)
        #expect(decoded == GlobalShortcutAction.startSession.defaultShortcut)
    }

    @Test("A malformed shortcut throws rather than decoding into something arbitrary")
    func malformedShortcutThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GlobalShortcut.self, from: Data(#"{"key":"l"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(GlobalShortcut.self, from: Data(#"{"modifiers":3}"#.utf8))
        }
    }

    // MARK: - Virtual key codes

    @Test(
        "Letters map to their documented kVK_ANSI positions",
        arguments: [
            ("a", UInt32(0)), ("s", 1), ("l", 37), ("i", 34), ("p", 35), ("z", 6), ("m", 46),
            ("q", 12), ("b", 11), ("k", 40),
        ]
    )
    func letterKeyCodes(pair: (String, UInt32)) {
        #expect(GlobalShortcut(key: pair.0, modifiers: [.command]).virtualKeyCode == pair.1)
    }

    @Test("Digit key codes are the physical row, which is not in numeric order")
    func digitKeyCodesFollowThePhysicalRow() {
        #expect(GlobalShortcut(key: "5", modifiers: [.command]).virtualKeyCode == 23)
        #expect(GlobalShortcut(key: "6", modifiers: [.command]).virtualKeyCode == 22)
        #expect(GlobalShortcut(key: "0", modifiers: [.command]).virtualKeyCode == 29)
    }

    @Test(
        "Named keys map to their documented kVK positions",
        arguments: [
            ("space", UInt32(49)), ("return", 36), ("tab", 48), ("escape", 53), ("delete", 51),
            ("left", 123), ("right", 124), ("down", 125), ("up", 126),
            ("f1", 122), ("f5", 96), ("f12", 111), ("pageup", 116), ("home", 115),
        ]
    )
    func namedKeyCodes(pair: (String, UInt32)) {
        #expect(GlobalShortcut(key: pair.0, modifiers: [.command]).virtualKeyCode == pair.1)
    }

    @Test("Every key code in the tables is distinct, so no two shortcuts can fire each other")
    func keyCodesAreDistinct() {
        let named = GlobalShortcut.namedKeys.map(\.code)
        let characters = Array(GlobalShortcut.characterKeys.values)
        let all = named + characters
        #expect(Set(all).count == all.count)
    }

    @Test("Every key token in the tables is unique across both tables")
    func keyTokensAreUnique() {
        let named = GlobalShortcut.namedKeys.map(\.token)
        let characters = Array(GlobalShortcut.characterKeys.keys)
        #expect(Set(named).count == named.count)
        #expect(Set(named).isDisjoint(with: Set(characters)))
    }

    @Test("Every character token really is one character, and is lowercase")
    func characterTokensAreSingleLowercaseCharacters() {
        for token in GlobalShortcut.characterKeys.keys {
            #expect(token.count == 1)
            #expect(token == token.lowercased())
        }
    }

    @Test("An unmappable key has no key code, so the service can fail rather than bind nothing")
    func unmappableKeysHaveNoCode() {
        #expect(GlobalShortcut(key: "f13", modifiers: [.command]).virtualKeyCode == nil)
        #expect(GlobalShortcut(key: "", modifiers: [.command]).virtualKeyCode == nil)
        #expect(GlobalShortcut(key: "hyper", modifiers: [.command]).virtualKeyCode == nil)
        #expect(GlobalShortcut(key: "🙂", modifiers: [.command]).virtualKeyCode == nil)
    }

    // MARK: - Carbon modifier mask

    @Test("The Carbon mask uses HIToolbox's own values")
    func carbonMaskValues() {
        #expect(GlobalShortcut.Modifiers.command.carbonMask == 0x0100)
        #expect(GlobalShortcut.Modifiers.shift.carbonMask == 0x0200)
        #expect(GlobalShortcut.Modifiers.option.carbonMask == 0x0800)
        #expect(GlobalShortcut.Modifiers.control.carbonMask == 0x1000)
        #expect(GlobalShortcut.Modifiers().carbonMask == 0)
    }

    @Test("Combined modifiers OR their masks together")
    func carbonMaskCombines() {
        #expect(GlobalShortcut.Modifiers([.command, .shift]).carbonMask == 0x0300)
        #expect(GlobalShortcut.Modifiers([.control, .shift]).carbonMask == 0x1200)
        #expect(GlobalShortcut.Modifiers.all.carbonMask == 0x1B00)
    }

    // MARK: - Validity

    @Test("A combination needs ⌘, ⌃ or ⌥ — ⇧ alone would swallow every capital letter typed")
    func shiftAloneIsNotAGlobalCombination() {
        #expect(GlobalShortcut(key: "l", modifiers: [.shift]).isValidGlobalCombination == false)
        #expect(GlobalShortcut(key: "l", modifiers: []).isValidGlobalCombination == false)
    }

    @Test(
        "A combination with a real modifier is valid",
        arguments: [
            GlobalShortcut.Modifiers([.command]),
            GlobalShortcut.Modifiers([.control]),
            GlobalShortcut.Modifiers([.option]),
            GlobalShortcut.Modifiers([.command, .shift]),
            GlobalShortcut.Modifiers([.control, .shift]),
        ]
    )
    func realModifiersAreValid(modifiers: GlobalShortcut.Modifiers) {
        #expect(GlobalShortcut(key: "l", modifiers: modifiers).isValidGlobalCombination)
    }

    @Test("An unmappable key is not a valid combination however it is modified")
    func unmappableKeysAreNotValid() {
        let unmappable = GlobalShortcut(key: "f13", modifiers: [.command, .shift])
        #expect(unmappable.isValidGlobalCombination == false)
    }

    @Test("Every default is a valid global combination")
    func defaultsAreValid() {
        for action in GlobalShortcutAction.allCases {
            #expect(action.defaultShortcut.isValidGlobalCombination, "\(action) is not registerable")
        }
    }

    // MARK: - Conflicts

    @Test("Two shortcuts conflict when they are the same combination, whatever the stored case")
    func conflictDetection() {
        let a = GlobalShortcut(key: "l", modifiers: [.control, .shift])
        let b = GlobalShortcut(key: "L", modifiers: [.shift, .control])
        #expect(a.conflicts(with: b))
        #expect(b.conflicts(with: a))
    }

    @Test("A different key or a different modifier set is not a conflict")
    func nonConflicts() {
        let base = GlobalShortcut(key: "l", modifiers: [.control, .shift])
        #expect(!base.conflicts(with: GlobalShortcut(key: "k", modifiers: [.control, .shift])))
        #expect(!base.conflicts(with: GlobalShortcut(key: "l", modifiers: [.command, .shift])))
        #expect(!base.conflicts(with: GlobalShortcut(key: "l", modifiers: [.control])))
    }

    @Test("Duplicates across a whole set of bindings are found, named, and in a stable order")
    func duplicatesAcrossBindings() {
        var bindings = GlobalShortcutBinding.defaultBindings()
        bindings[.addAccomplishment] = GlobalShortcutAction.captureInterruption.defaultShortcut
        let duplicates = GlobalShortcut.duplicates(in: bindings)

        #expect(duplicates.count == 1)
        let clashing = GlobalShortcutAction.captureInterruption.defaultShortcut
        #expect(duplicates[clashing] == [.captureInterruption, .addAccomplishment])
    }

    @Test("The defaults contain no duplicates")
    func defaultsHaveNoDuplicates() {
        #expect(GlobalShortcut.duplicates(in: GlobalShortcutBinding.defaultBindings()).isEmpty)
    }

    @Test("Case differences in stored bindings still register as a duplicate")
    func duplicatesIgnoreStoredCase() {
        let bindings: [GlobalShortcutAction: GlobalShortcut] = [
            .quickSession: GlobalShortcut(key: "l", modifiers: [.control, .shift]),
            .pauseResume: GlobalShortcut(key: "L", modifiers: [.control, .shift]),
        ]
        #expect(GlobalShortcut.duplicates(in: bindings).count == 1)
    }

    // MARK: - Defaults

    @Test("There is a default for every action, as a set, with nothing missing")
    func defaultsCoverEveryAction() {
        #expect(GlobalShortcutBinding.defaults.count == GlobalShortcutAction.allCases.count)
        #expect(GlobalShortcutBinding.defaults.count == 5)
        for action in GlobalShortcutAction.allCases {
            #expect(GlobalShortcutBinding.defaults.contains(where: { $0.action == action }))
        }
    }

    @Test("The five default combinations are five distinct combinations")
    func defaultCombinationsAreDistinct() {
        #expect(GlobalShortcut.defaultCombinations.count == 5)
    }

    @Test("The dictionary form agrees with the set form")
    func dictionaryAndSetAgree() {
        let bindings = GlobalShortcutBinding.defaultBindings()
        #expect(bindings.count == 5)
        for binding in GlobalShortcutBinding.defaults {
            #expect(bindings[binding.action] == binding.shortcut)
        }
    }

    @Test("Action raw values are the stable persistence keys, not derived names")
    func actionRawValuesAreStable() {
        #expect(GlobalShortcutAction.startSession.rawValue == "startSession")
        #expect(GlobalShortcutAction.quickSession.rawValue == "quickSession")
        #expect(GlobalShortcutAction.captureInterruption.rawValue == "captureInterruption")
        #expect(GlobalShortcutAction.addAccomplishment.rawValue == "addAccomplishment")
        #expect(GlobalShortcutAction.pauseResume.rawValue == "pauseResume")
    }

    @Test("Every action has a title, and no two share one")
    func actionTitlesAreDistinct() {
        let titles = GlobalShortcutAction.allCases.map(\.title)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(Set(titles).count == titles.count)
    }

    @Test("A binding survives a Codable round trip")
    func bindingRoundTrip() throws {
        for binding in GlobalShortcutBinding.defaults {
            let data = try JSONEncoder().encode(binding)
            #expect(try JSONDecoder().decode(GlobalShortcutBinding.self, from: data) == binding)
        }
    }

    // MARK: - Preferences

    @Test("The preferences default is still ⇧⌘Space, and it is the start-session default")
    func preferencesDefaultIsStartSession() {
        #expect(UserPreferences.default.globalShortcut.displayString == "⇧⌘Space")
        #expect(
            UserPreferences.default.globalShortcut
                == GlobalShortcutAction.startSession.defaultShortcut
        )
    }

    @Test("A shortcut stored in preferences survives a round trip")
    func preferencesRoundTripKeepsTheShortcut() throws {
        var preferences = UserPreferences()
        preferences.globalShortcut = GlobalShortcut(key: "l", modifiers: [.control, .shift])
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: data)
        #expect(decoded.globalShortcut.displayString == "⌃⇧L")
        #expect(decoded.globalShortcut == preferences.globalShortcut)
    }

    @Test("Preferences written without a shortcut fall back to the default rather than failing")
    func preferencesToleratesAMissingShortcut() throws {
        let json = Data(#"{"defaultSessionDuration":3000}"#.utf8)
        let decoded = try JSONDecoder().decode(UserPreferences.self, from: json)
        #expect(decoded.globalShortcut == GlobalShortcutAction.startSession.defaultShortcut)
    }
}
