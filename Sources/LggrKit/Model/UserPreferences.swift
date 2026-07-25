import Foundation

/// A global hot key, stored without AppKit.
///
/// `LggrKit` must not import AppKit, so the modifiers live as an `OptionSet` over `Int` and the key
/// as a lowercase token. `LggrApp` maps both onto `NSEvent.ModifierFlags` / `KeyEquivalent` at the
/// edge. Keeping the raw values explicit means a stored shortcut survives any Swift-level rename.
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

        // Written as a bare integer rather than as an object with a `rawValue` field. Spelled out
        // instead of left to inference, because which of the two an option set gets is a detail of
        // conformance resolution, and this value lives in a file on the user's disk.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.init(rawValue: try container.decode(Int.self))
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        /// Modifier glyphs in the order macOS writes them.
        public var displayString: String {
            var glyphs = ""
            if contains(.control) { glyphs += "⌃" }
            if contains(.option) { glyphs += "⌥" }
            if contains(.shift) { glyphs += "⇧" }
            if contains(.command) { glyphs += "⌘" }
            return glyphs
        }
    }

    /// A lowercase key token: a single character such as `"l"`, or a named key such as `"space"`.
    public var key: String
    public var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    public static let toggleSession = GlobalShortcut(key: "space", modifiers: [.command, .shift])

    public var keyDisplayName: String {
        switch key {
        case "space": "Space"
        case "return": "Return"
        case "tab": "Tab"
        case "escape": "Escape"
        default: key.uppercased()
        }
    }

    /// What the settings window shows, for example `⇧⌘Space`.
    public var displayString: String {
        modifiers.displayString + keyDisplayName
    }
}

/// Everything the user can change, in one Codable value.
///
/// Decoding tolerates missing keys so a preferences file written by an older build still loads: an
/// absent field falls back to its default rather than failing the whole read and losing every other
/// setting the user chose.
public struct UserPreferences: Codable, Hashable, Sendable {

    /// Pre-selected duration in the start panel when the work type has no stronger opinion.
    public var defaultSessionDuration: TimeInterval
    public var globalShortcut: GlobalShortcut
    /// Whether window titles may be read.
    ///
    /// **Nothing reads this yet, and it defaults to `false`.** No capture path supplies a title, so
    /// the toggle governs a capability the app does not currently have. It stays because the spec
    /// names the field and Phase 4 turns it on, but it must default to off: a privacy switch that
    /// ships enabled, is wired to nothing, and describes reading window titles is the one default
    /// where being wrong is not recoverable by a later fix.
    public var trackWindowTitles: Bool
    /// Idle time after which the user is treated as away from the machine.
    public var idleThreshold: TimeInterval
    /// Bundle identifiers never recorded at all.
    public var excludedApplications: [String]
    /// Bundle identifiers recorded as a category only, never by name or window title.
    public var privateApplications: [String]
    public var dataRetentionDays: Int
    public var launchAtLogin: Bool
    public var showTimerInMenuBar: Bool
    /// The project the start panel pre-selects, so the common case needs no interaction.
    public var lastProjectID: UUID?
    /// Recently used intended outcomes, most recent first, offered as suggestions.
    public private(set) var recentOutcomes: [String]

    /// How many suggestions are kept. Small on purpose: a suggestion list longer than a glance is
    /// slower than typing.
    public static let maxRecentOutcomes = 10

    public init(
        defaultSessionDuration: TimeInterval = 50 * 60,
        globalShortcut: GlobalShortcut = .toggleSession,
        trackWindowTitles: Bool = false,
        idleThreshold: TimeInterval = 3 * 60,
        excludedApplications: [String] = [],
        privateApplications: [String] = [],
        dataRetentionDays: Int = 90,
        launchAtLogin: Bool = false,
        showTimerInMenuBar: Bool = true,
        lastProjectID: UUID? = nil,
        recentOutcomes: [String] = []
    ) {
        self.defaultSessionDuration = max(0, defaultSessionDuration)
        self.globalShortcut = globalShortcut
        self.trackWindowTitles = trackWindowTitles
        self.idleThreshold = max(0, idleThreshold)
        self.excludedApplications = excludedApplications
        self.privateApplications = privateApplications
        self.dataRetentionDays = max(1, dataRetentionDays)
        self.launchAtLogin = launchAtLogin
        self.showTimerInMenuBar = showTimerInMenuBar
        self.lastProjectID = lastProjectID
        self.recentOutcomes = Self.normalized(recentOutcomes)
    }

    public static let `default` = UserPreferences()

    // MARK: - Recent outcomes

    /// Records an outcome the user actually started a session with.
    ///
    /// Most recent first, deduplicated case-insensitively so re-running yesterday's outcome promotes
    /// the existing entry instead of adding a near-duplicate, and capped at `maxRecentOutcomes`.
    /// Blank input is ignored rather than stored as an empty suggestion.
    public mutating func recordOutcome(_ outcome: String) {
        let trimmed = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = recentOutcomes.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        recentOutcomes = Array(updated.prefix(Self.maxRecentOutcomes))
    }

    public mutating func clearRecentOutcomes() {
        recentOutcomes = []
    }

    private static func normalized(_ outcomes: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for outcome in outcomes {
            let trimmed = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
            if result.count == maxRecentOutcomes { break }
        }
        return result
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case defaultSessionDuration
        case globalShortcut
        case trackWindowTitles
        case idleThreshold
        case excludedApplications
        case privateApplications
        case dataRetentionDays
        case launchAtLogin
        case showTimerInMenuBar
        case lastProjectID
        case recentOutcomes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = UserPreferences()
        self.init(
            defaultSessionDuration: try container.decodeIfPresent(
                TimeInterval.self, forKey: .defaultSessionDuration)
                ?? fallback.defaultSessionDuration,
            globalShortcut: try container.decodeIfPresent(
                GlobalShortcut.self, forKey: .globalShortcut) ?? fallback.globalShortcut,
            trackWindowTitles: try container.decodeIfPresent(
                Bool.self, forKey: .trackWindowTitles) ?? fallback.trackWindowTitles,
            idleThreshold: try container.decodeIfPresent(
                TimeInterval.self, forKey: .idleThreshold) ?? fallback.idleThreshold,
            excludedApplications: try container.decodeIfPresent(
                [String].self, forKey: .excludedApplications) ?? fallback.excludedApplications,
            privateApplications: try container.decodeIfPresent(
                [String].self, forKey: .privateApplications) ?? fallback.privateApplications,
            dataRetentionDays: try container.decodeIfPresent(
                Int.self, forKey: .dataRetentionDays) ?? fallback.dataRetentionDays,
            launchAtLogin: try container.decodeIfPresent(
                Bool.self, forKey: .launchAtLogin) ?? fallback.launchAtLogin,
            showTimerInMenuBar: try container.decodeIfPresent(
                Bool.self, forKey: .showTimerInMenuBar) ?? fallback.showTimerInMenuBar,
            lastProjectID: try container.decodeIfPresent(UUID.self, forKey: .lastProjectID),
            recentOutcomes: try container.decodeIfPresent([String].self, forKey: .recentOutcomes)
                ?? []
        )
    }
}
