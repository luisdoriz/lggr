import Foundation

// `GlobalShortcut` used to be declared here. It now lives in `GlobalShortcut.swift` alongside the
// actions, the defaults and the key tables the hot-key service reads — the type outgrew being a
// preamble to this file.

/// Everything the user can change, in one Codable value.
///
/// Decoding tolerates missing keys so a preferences file written by an older build still loads: an
/// absent field falls back to its default rather than failing the whole read and losing every other
/// setting the user chose.
public struct UserPreferences: Codable, Hashable, Sendable {

    /// Pre-selected duration in the start panel when the work type has no stronger opinion.
    public var defaultSessionDuration: TimeInterval

    /// Every global hot key, as the user configured it. Read at launch by `GlobalShortcutService`.
    public var shortcuts: GlobalShortcutBindings

    /// The hot key that opens the start panel.
    ///
    /// **This field used to be stored and unread — a setting that existed and did nothing.** It is now
    /// a view onto `shortcuts`, which is what registration reads, so writing it changes a hot key and
    /// reading it reports the one that is live. It stays in the type, and stays in the file, because
    /// `SPEC.md` § "Data model" names it and because a preferences file written by any earlier build
    /// carries it: decoding folds it into `shortcuts` as the start-session binding.
    ///
    /// A start-session hot key the user switched off reads as the default here — a single non-optional
    /// combination cannot express "off", which is exactly why `shortcuts` exists and why the Shortcuts
    /// pane reads that instead.
    public var globalShortcut: GlobalShortcut {
        get { shortcuts.editedShortcut(for: .startSession) }
        set { shortcuts.set(newValue, for: .startSession) }
    }

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

    /// - Parameters:
    ///   - shortcuts: every hot key at once, which is what the Shortcuts pane writes.
    ///   - globalShortcut: the start-session hot key alone, kept for the callers and the stored files
    ///     that predate `shortcuts`. It is applied *on top of* `shortcuts`, and only when `shortcuts`
    ///     has nothing to say about the start-session action — so passing both cannot silently discard
    ///     the richer of the two.
    public init(
        defaultSessionDuration: TimeInterval = 50 * 60,
        shortcuts: GlobalShortcutBindings = .default,
        globalShortcut: GlobalShortcut = GlobalShortcutAction.startSession.defaultShortcut,
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
        self.shortcuts = shortcuts
        if !shortcuts.isCustom(.startSession) {
            self.shortcuts.set(globalShortcut, for: .startSession)
        }
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
        case shortcuts
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
            shortcuts: try container.decodeIfPresent(
                GlobalShortcutBindings.self, forKey: .shortcuts) ?? .default,
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

    /// Hand-written for the same reason `init(from:)` is, plus one of its own: `globalShortcut` is a
    /// computed view onto `shortcuts` now, and the synthesised encoder writes stored properties only.
    ///
    /// It is still written to the file. A build that predates `shortcuts` reads that key and nothing
    /// else, so writing it means downgrading Lggr keeps the start-session hot key the user chose
    /// instead of silently reverting it — the same tolerance `init(from:)` extends in the other
    /// direction.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultSessionDuration, forKey: .defaultSessionDuration)
        try container.encode(shortcuts, forKey: .shortcuts)
        try container.encode(globalShortcut, forKey: .globalShortcut)
        try container.encode(trackWindowTitles, forKey: .trackWindowTitles)
        try container.encode(idleThreshold, forKey: .idleThreshold)
        try container.encode(excludedApplications, forKey: .excludedApplications)
        try container.encode(privateApplications, forKey: .privateApplications)
        try container.encode(dataRetentionDays, forKey: .dataRetentionDays)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(showTimerInMenuBar, forKey: .showTimerInMenuBar)
        try container.encodeIfPresent(lastProjectID, forKey: .lastProjectID)
        try container.encode(recentOutcomes, forKey: .recentOutcomes)
    }
}
