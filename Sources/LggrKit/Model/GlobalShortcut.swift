import Foundation

// The whole of the global hot-key vocabulary, in Foundation only.
//
// This file is deliberately the *only* place that knows how a hot key is spelled, stored, displayed
// and turned into numbers. `GlobalShortcutService` in `LggrApp` is a thin shell around
// `RegisterEventHotKey` that reads `virtualKeyCode` and `modifiers.carbonMask` from here — because
// AppKit-bound code cannot be unit-tested on this machine, and a table of key codes that nothing
// checks is a table that is wrong.

/// A global hot key, stored without AppKit.
///
/// `LggrKit` must not import AppKit, so the modifiers live as an `OptionSet` over `Int` and the key
/// as a lowercase token. `LggrApp` maps both onto Carbon's `RegisterEventHotKey` (and onto
/// `KeyEquivalent` for the menu bar) at the edge. Keeping the raw values explicit means a stored
/// shortcut survives any Swift-level rename.
///
/// Two invariants hold for every instance, including one that came off disk:
///
/// 1. `key` is lowercased. `⌃⇧L` and `⌃⇧l` are the same hot key, and a conflict check that missed
///    that would let two actions claim one combination.
/// 2. `modifiers` contains only the four flags this type declares. An unknown bit written by a
///    future version is dropped rather than left to silently change what the combination means.
public struct GlobalShortcut: Codable, Hashable, Sendable {

    public struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)

        /// Every flag this type understands. Anything outside it is discarded on the way in.
        public static let all: Modifiers = [.command, .shift, .option, .control]

        // Written as a bare integer rather than as an object with a `rawValue` field. Spelled out
        // instead of left to inference, because which of the two an option set gets is a detail of
        // conformance resolution, and this value lives in a file on the user's disk.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: try container.decode(Int.self) & Modifiers.all.rawValue)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// Modifier glyphs in the order macOS writes them: `⌃⌥⇧⌘`.
        ///
        /// The order is not cosmetic. Every menu, every key-combination field and every screenshot in
        /// the system writes control, option, shift, command in that sequence; a shortcut rendered
        /// `⇧⌃L` reads as a bug even to someone who could not say why.
        public var displayString: String {
            var glyphs = ""
            for (glyph, flag) in Modifiers.glyphOrder where contains(flag) {
                glyphs.append(glyph)
            }
            return glyphs
        }

        /// The `RegisterEventHotKey` modifier mask.
        ///
        /// The four constants are HIToolbox's `controlKey`, `optionKey`, `shiftKey` and `cmdKey`.
        /// They are written as literals because `LggrKit` imports Foundation only; they are fixed
        /// parts of the Carbon ABI and have not moved in twenty years.
        public var carbonMask: UInt32 {
            var mask: UInt32 = 0
            if contains(.control) { mask |= 0x1000 }  // controlKey
            if contains(.option) { mask |= 0x0800 }  // optionKey
            if contains(.shift) { mask |= 0x0200 }  // shiftKey
            if contains(.command) { mask |= 0x0100 }  // cmdKey
            return mask
        }

        /// Glyph ↔ flag, in display order. One array serves both writing and parsing, so the two can
        /// never disagree about what `⌥` means.
        static let glyphOrder: [(Character, Modifiers)] = [
            ("⌃", .control),
            ("⌥", .option),
            ("⇧", .shift),
            ("⌘", .command),
        ]
    }

    /// A lowercase key token: a single character such as `"l"` or `","`, or a named key such as
    /// `"space"`.
    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers.intersection(.all)
    }

    // MARK: - Display

    public var keyDisplayName: String {
        if let named = Self.namedKeys.first(where: { $0.token == key }) {
            return named.display
        }
        // Letters uppercase, digits and punctuation are already themselves.
        return key.uppercased()
    }

    /// What a person reads, for example `⌃⇧L` or `⌘⇧Space`.
    public var displayString: String {
        modifiers.displayString + keyDisplayName
    }

    // MARK: - Parsing

    /// Reads back what `displayString` writes.
    ///
    /// Modifier glyphs may arrive in any order — a value hand-edited in the preferences file, or one
    /// copied out of another app's documentation, should still load — but the remainder must name a
    /// key this type can actually register. `nil` rather than a best guess: a shortcut we cannot map
    /// has to fail where it is read, not bind nothing later.
    public init?(displayString: String) {
        var modifiers = Modifiers()
        var remainder = Substring(displayString)

        while let first = remainder.first,
            let match = Modifiers.glyphOrder.first(where: { $0.0 == first })
        {
            // A glyph written twice is the same request as writing it once, so it is not an error.
            modifiers.insert(match.1)
            remainder = remainder.dropFirst()
        }

        let token = Self.normalizedToken(String(remainder))
        guard !token.isEmpty, Self.virtualKeyCode(forToken: token) != nil else { return nil }
        self.init(key: token, modifiers: modifiers)
    }

    /// Folds a display name back to its stored token: `"Page Up"` → `"pageup"`, `"←"` → `"left"`,
    /// `"L"` → `"l"`.
    private static func normalizedToken(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let squashed = trimmed.lowercased().filter { !$0.isWhitespace }
        if namedKeys.contains(where: { $0.token == squashed }) { return squashed }
        if let named = namedKeys.first(where: {
            $0.display.lowercased().filter({ !$0.isWhitespace }) == squashed
        }) {
            return named.token
        }
        return trimmed.lowercased()
    }

    // MARK: - Registration facts

    /// The virtual key code `RegisterEventHotKey` wants, or `nil` when this key cannot be registered.
    ///
    /// **These are physical key positions, not characters.** `kVK_ANSI_L` is "the key that sits where
    /// L sits on an ANSI keyboard", so on a layout where that position produces a different letter
    /// the hot key follows the *position*. That is how every hot-key API on macOS behaves, including
    /// the ones in System Settings, and a hardcoded table is therefore the correct implementation —
    /// but it is layout-dependent by construction, and this comment is the record of that.
    ///
    /// A `nil` here must make registration fail loudly. Silently binding nothing is the failure this
    /// whole feature exists to avoid.
    public var virtualKeyCode: UInt32? {
        Self.virtualKeyCode(forToken: key)
    }

    static func virtualKeyCode(forToken token: String) -> UInt32? {
        if let named = namedKeys.first(where: { $0.token == token }) { return named.code }
        return characterKeys[token]
    }

    /// The shortcut for a key the user physically pressed, or `nil` for a key this build cannot
    /// register.
    ///
    /// This is the recorder's whole translation step. It is here, rather than in the view, for the
    /// reason the rest of this file exists: the tables are the part that can be wrong, and the tables
    /// are tested. `nil` rather than a guess — a recorder that accepted `F13` and then bound nothing
    /// would be the original defect wearing a new hat.
    ///
    /// The code is a key *position*, so this is the exact inverse of `virtualKeyCode`, layout
    /// dependence and all.
    public init?(virtualKeyCode: UInt32, modifiers: Modifiers) {
        guard let token = Self.token(forVirtualKeyCode: virtualKeyCode) else { return nil }
        self.init(key: token, modifiers: modifiers)
    }

    /// The stored token for a virtual key code. Every code in both tables is distinct, so there is
    /// exactly one answer or none.
    static func token(forVirtualKeyCode code: UInt32) -> String? {
        if let named = namedKeys.first(where: { $0.code == code }) { return named.token }
        return characterKeys.first(where: { $0.value == code })?.key
    }

    /// Whether this combination is safe to register system-wide.
    ///
    /// At least one of `⌘`, `⌃` or `⌥` is required. `⇧L` registered globally would swallow every
    /// capital L the user types in any application, and a shortcut with no modifier at all would
    /// swallow the letter itself — neither is a hot key, both are a broken keyboard.
    public var isValidGlobalCombination: Bool {
        guard virtualKeyCode != nil else { return false }
        return !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    // MARK: - Conflicts

    /// Whether two shortcuts are the same combination.
    ///
    /// Plain equality — both values are normalised in `init` and on decode, so `⌃⇧L` and `⌃⇧l` are
    /// already the same value. It has a name of its own because that is what the call sites mean, and
    /// because a reader checking conflict logic should find something to read.
    public func conflicts(with other: GlobalShortcut) -> Bool {
        self == other
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case key
        case modifiers
    }

    /// Hand-written so the two invariants in this type's documentation survive a round trip.
    ///
    /// The synthesised decoder would assign `key` verbatim, so a preferences file containing `"L"`
    /// would decode to a value that is not equal to the same shortcut built in code — and every
    /// conflict check downstream would quietly disagree with itself.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            modifiers: try container.decode(Modifiers.self, forKey: .modifiers)
        )
    }

    // MARK: - Key tables

    /// A key with a name rather than a character: its stored token, how it reads on screen, and its
    /// virtual key code.
    struct NamedKey: Sendable {
        let token: String
        let display: String
        let code: UInt32
    }

    /// Named keys. Codes are HIToolbox's `kVK_*` values, named in the trailing comments.
    static let namedKeys: [NamedKey] = [
        NamedKey(token: "space", display: "Space", code: 49),  // kVK_Space
        NamedKey(token: "return", display: "Return", code: 36),  // kVK_Return
        NamedKey(token: "tab", display: "Tab", code: 48),  // kVK_Tab
        NamedKey(token: "escape", display: "Escape", code: 53),  // kVK_Escape
        NamedKey(token: "delete", display: "Delete", code: 51),  // kVK_Delete
        NamedKey(token: "forwarddelete", display: "Forward Delete", code: 117),  // kVK_ForwardDelete
        NamedKey(token: "home", display: "Home", code: 115),  // kVK_Home
        NamedKey(token: "end", display: "End", code: 119),  // kVK_End
        NamedKey(token: "pageup", display: "Page Up", code: 116),  // kVK_PageUp
        NamedKey(token: "pagedown", display: "Page Down", code: 121),  // kVK_PageDown
        NamedKey(token: "left", display: "←", code: 123),  // kVK_LeftArrow
        NamedKey(token: "right", display: "→", code: 124),  // kVK_RightArrow
        NamedKey(token: "down", display: "↓", code: 125),  // kVK_DownArrow
        NamedKey(token: "up", display: "↑", code: 126),  // kVK_UpArrow
        NamedKey(token: "f1", display: "F1", code: 122),  // kVK_F1
        NamedKey(token: "f2", display: "F2", code: 120),  // kVK_F2
        NamedKey(token: "f3", display: "F3", code: 99),  // kVK_F3
        NamedKey(token: "f4", display: "F4", code: 118),  // kVK_F4
        NamedKey(token: "f5", display: "F5", code: 96),  // kVK_F5
        NamedKey(token: "f6", display: "F6", code: 97),  // kVK_F6
        NamedKey(token: "f7", display: "F7", code: 98),  // kVK_F7
        NamedKey(token: "f8", display: "F8", code: 100),  // kVK_F8
        NamedKey(token: "f9", display: "F9", code: 101),  // kVK_F9
        NamedKey(token: "f10", display: "F10", code: 109),  // kVK_F10
        NamedKey(token: "f11", display: "F11", code: 103),  // kVK_F11
        NamedKey(token: "f12", display: "F12", code: 111),  // kVK_F12
    ]

    /// Single-character keys, keyed by their stored token. Codes are HIToolbox's `kVK_ANSI_*` values.
    ///
    /// Not derived from the character — there is no arithmetic relationship between a letter and its
    /// key code, as the ordering below makes plain. It is a physical keyboard, written down.
    static let characterKeys: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46,
        "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44,
        ".": 47, "`": 50,
    ]
}

// MARK: - Actions

/// What a global hot key can do.
///
/// Five actions, each with a default combination from `04-screens.md` § 7 and the user's own words:
/// press it from anywhere, act, go back to work. The raw values are the persistence keys, so they are
/// spelled out rather than derived.
public enum GlobalShortcutAction: String, CaseIterable, Codable, Hashable, Sendable {

    /// The start panel, with a project, an outcome and a duration to choose.
    case startSession

    /// A session starts immediately, with the remembered project and no panel at all. The `⌃⇧L`
    /// case: one keystroke, already tracking.
    case quickSession

    /// "What came up?" — one line, saved to the inbox, work carries on.
    case captureInterruption

    /// The accomplishment editor.
    case addAccomplishment

    /// Pauses the running session, or resumes a paused one.
    case pauseResume

    /// The row title in Settings → Shortcuts.
    public var title: String {
        switch self {
        case .startSession: "Start a focus session"
        case .quickSession: "Start a session immediately"
        case .captureInterruption: "Capture an interruption"
        case .addAccomplishment: "Add an accomplishment"
        case .pauseResume: "Pause or resume"
        }
    }

    /// The combination Lggr ships with.
    public var defaultShortcut: GlobalShortcut {
        switch self {
        case .startSession: GlobalShortcut(key: "space", modifiers: [.command, .shift])
        case .quickSession: GlobalShortcut(key: "l", modifiers: [.control, .shift])
        case .captureInterruption: GlobalShortcut(key: "i", modifiers: [.command, .shift])
        case .addAccomplishment: GlobalShortcut(key: "a", modifiers: [.command, .shift])
        case .pauseResume: GlobalShortcut(key: "p", modifiers: [.control, .shift])
        }
    }
}

// MARK: - Bindings

/// One action and the combination that triggers it.
public struct GlobalShortcutBinding: Codable, Hashable, Sendable {

    public var action: GlobalShortcutAction
    public var shortcut: GlobalShortcut

    public init(action: GlobalShortcutAction, shortcut: GlobalShortcut) {
        self.action = action
        self.shortcut = shortcut
    }
}

extension GlobalShortcutBinding {

    /// The five defaults, as a set.
    ///
    /// `Set` and not an array on purpose: nothing about these is ordered, and building it from
    /// `allCases` means adding an action to the enum cannot leave a hot key undefaulted. The
    /// distinctness of the five combinations is a test, not a hope.
    public static let defaults: Set<GlobalShortcutBinding> = Set(
        GlobalShortcutAction.allCases.map {
            GlobalShortcutBinding(action: $0, shortcut: $0.defaultShortcut)
        }
    )

    /// The same defaults in the shape the service registers and Settings edits.
    public static func defaultBindings() -> [GlobalShortcutAction: GlobalShortcut] {
        var bindings: [GlobalShortcutAction: GlobalShortcut] = [:]
        for action in GlobalShortcutAction.allCases {
            bindings[action] = action.defaultShortcut
        }
        return bindings
    }
}

/// Every action's hot key, as the user has configured it.
///
/// One field could not hold five shortcuts, and a dictionary alone could not hold the third state the
/// Shortcuts pane has to be able to express. There are three, not two:
///
///   * **default** — the action is not mentioned here at all and uses `defaultShortcut`. Storing the
///     defaults would freeze them: a later build that improves one would be overridden by a value the
///     user never chose.
///   * **custom** — the user recorded something else.
///   * **disabled** — the user switched it off, and it registers nothing. Distinct from custom,
///     because "off" is a decision and `nil` in a dictionary cannot tell it apart from "never set".
///
/// A custom shortcut equal to the action's default is normalised away on the way in, so
/// `isCustom(_:)` answers what the pane needs to know — whether *Use default* has anything to undo —
/// rather than what the storage happens to contain.
///
/// Disabling keeps any custom combination rather than erasing it, so switching an action off and back
/// on does not cost the user the shortcut they chose.
public struct GlobalShortcutBindings: Codable, Hashable, Sendable {

    /// Actions the user moved off their default. Never contains a value equal to the default.
    private var custom: [GlobalShortcutAction: GlobalShortcut]

    /// Actions with no hot key at all.
    private var disabled: Set<GlobalShortcutAction>

    public init(
        custom: [GlobalShortcutAction: GlobalShortcut] = [:],
        disabled: Set<GlobalShortcutAction> = []
    ) {
        self.custom = custom.filter { $0.value != $0.key.defaultShortcut }
        self.disabled = disabled
    }

    /// What Lggr ships with: every action on its own default, nothing switched off.
    public static let `default` = GlobalShortcutBindings()

    // MARK: - Reading

    /// The combination that triggers `action`, or `nil` when the user switched it off.
    public func shortcut(for action: GlobalShortcutAction) -> GlobalShortcut? {
        guard !disabled.contains(action) else { return nil }
        return custom[action] ?? action.defaultShortcut
    }

    /// The combination shown in the row's recorder even when the action is off, so switching it back
    /// on can show what it will become instead of an empty field.
    public func editedShortcut(for action: GlobalShortcutAction) -> GlobalShortcut {
        custom[action] ?? action.defaultShortcut
    }

    public func isDisabled(_ action: GlobalShortcutAction) -> Bool {
        disabled.contains(action)
    }

    /// Whether anything about this action differs from what Lggr ships with — which is exactly when
    /// *Use default* has something to do.
    public func isCustom(_ action: GlobalShortcutAction) -> Bool {
        custom[action] != nil || disabled.contains(action)
    }

    /// What `GlobalShortcutService.apply(_:)` registers. Disabled actions are absent rather than
    /// present with a combination nothing listens for.
    public var resolved: [GlobalShortcutAction: GlobalShortcut] {
        var bindings: [GlobalShortcutAction: GlobalShortcut] = [:]
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = shortcut(for: action) else { continue }
            bindings[action] = shortcut
        }
        return bindings
    }

    // MARK: - Writing

    /// Records a combination for `action`, switching it back on if it was off.
    public mutating func set(_ shortcut: GlobalShortcut, for action: GlobalShortcutAction) {
        disabled.remove(action)
        custom[action] = shortcut == action.defaultShortcut ? nil : shortcut
    }

    /// Switches an action off. It registers nothing until it is set or reset.
    public mutating func disable(_ action: GlobalShortcutAction) {
        disabled.insert(action)
    }

    /// Puts an action back exactly as Lggr ships it — on, and on its default.
    public mutating func reset(_ action: GlobalShortcutAction) {
        disabled.remove(action)
        custom[action] = nil
    }

    // MARK: - Conflicts

    /// Which *other* Lggr action already answers `shortcut`, if any.
    ///
    /// Declaration order, so the answer is the same on every launch. This is what lets the Shortcuts
    /// pane refuse a recording and name the row that owns the keys, rather than letting the service
    /// refuse the second registration and leaving the user to work out which of the two lost.
    public func owner(
        of shortcut: GlobalShortcut,
        excluding action: GlobalShortcutAction
    ) -> GlobalShortcutAction? {
        GlobalShortcutAction.allCases.first { candidate in
            candidate != action && self.shortcut(for: candidate)?.conflicts(with: shortcut) == true
        }
    }

    // MARK: - Codable

    /// Written with the action tokens as string keys, and read back tolerantly.
    ///
    /// Hand-written for two reasons. A dictionary keyed by anything other than `String` or `Int`
    /// encodes as a flat alternating array, which is neither readable in the preferences file nor
    /// stable to reason about; and an action token written by a future version has to be *dropped*
    /// rather than fail the whole decode, because losing every shortcut over one unknown name is how
    /// a preferences file becomes a bug report.
    private enum CodingKeys: String, CodingKey {
        case custom
        case disabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedCustom =
            try container.decodeIfPresent([String: GlobalShortcut].self, forKey: .custom) ?? [:]
        let storedDisabled =
            try container.decodeIfPresent([String].self, forKey: .disabled) ?? []

        var custom: [GlobalShortcutAction: GlobalShortcut] = [:]
        for (token, shortcut) in storedCustom {
            guard let action = GlobalShortcutAction(rawValue: token) else { continue }
            custom[action] = shortcut
        }
        self.init(
            custom: custom,
            disabled: Set(storedDisabled.compactMap(GlobalShortcutAction.init(rawValue:)))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var storedCustom: [String: GlobalShortcut] = [:]
        for (action, shortcut) in custom {
            storedCustom[action.rawValue] = shortcut
        }
        try container.encode(storedCustom, forKey: .custom)
        // Declaration order rather than set order, so two identical configurations produce identical
        // files and a preferences file does not churn on every launch.
        try container.encode(
            GlobalShortcutAction.allCases.filter(disabled.contains).map(\.rawValue),
            forKey: .disabled
        )
    }
}

extension GlobalShortcut {

    /// The five default combinations, without their actions.
    public static let defaultCombinations: Set<GlobalShortcut> = Set(
        GlobalShortcutAction.allCases.map(\.defaultShortcut)
    )

    /// Every combination claimed by more than one action, and who claims it.
    ///
    /// The input is what Settings holds, so two rows *can* name the same keys — the user changed one
    /// of them. This is what lets the pane say so before the service has to refuse the second
    /// registration. Actions are returned sorted by declaration order so the message is stable.
    public static func duplicates(
        in bindings: [GlobalShortcutAction: GlobalShortcut]
    ) -> [GlobalShortcut: [GlobalShortcutAction]] {
        var claims: [GlobalShortcut: [GlobalShortcutAction]] = [:]
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = bindings[action] else { continue }
            claims[shortcut, default: []].append(action)
        }
        return claims.filter { $0.value.count > 1 }
    }
}
