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

    // MARK: Notifications
    //
    // `SPEC.md` § Notifications names four kinds and `03-data-model.md` § 2.8 declares three of them
    // here — with two of the three defaulting to `true`. **They default to `false` instead, and the
    // deviation is the whole point.** macOS grants one notification authorisation for the whole app,
    // Lggr requests it only when a user switches one of these on, and a switch that ships already on
    // while nothing has ever been authorised is a setting that reads as enabled and does nothing.
    // Off is the only default under which every one of these is true the moment the user sees it.
    //
    // Each is independent, because the failure mode is shared: one notification the user did not
    // want costs the authorisation, and the useful ones die with it in System Settings where Lggr
    // cannot ask again.

    /// Post a notification when a session reaches its planned duration.
    public var notifyOnSessionCompleted: Bool

    /// Post a notification halfway through a planned session.
    public var notifyAtHalfway: Bool

    /// Offer to trim the session when input has been absent long enough to matter.
    public var notifyOnLongIdle: Bool

    /// Offer the end-of-day review of blocks that were never declared.
    ///
    /// `ProactivePrompts` is its scheduler, so this is a live switch with a row in Settings ▸ Alerts.
    ///
    /// **It does not fire on a schedule, and the distinction is the whole design.**
    /// `endOfDayReviewHour` is permission to *look at the record*, not a cause to send anything: the
    /// notification is posted only when `UnlabelledWork.report(for:)` finds blocks worth labelling,
    /// and a day with none sends nothing at all — no summary, no congratulation. A banner that
    /// arrived because the clock reached a number would be the re-engagement mechanism this app does
    /// not have.
    public var notifyOnEndOfDayReview: Bool

    /// Offer, once, to label a long stretch of work with no session running.
    ///
    /// The only notification in Lggr that interrupts work in progress, which is why it is off by
    /// default like all the others and why it can be switched off from the banner itself. Bounded by
    /// `promptHours`, silent while a session runs, while tracking is paused and while the screen is
    /// locked, and asked at most once per stretch of work — see
    /// `UnlabelledWork.liveOffer(in:now:conditions:policy:)`, where each of those is a named case.
    public var notifyOnUnlabelledBlock: Bool

    /// The hours in which Lggr may offer to label something.
    ///
    /// A prompt at 23:40 is an intrusion however useful its content, and Lggr cannot know a person's
    /// day. So the window is the user's, it bounds both prompts, and the default is a *narrowing*
    /// guess: nine to six means a seven-o'clock starter gets silence rather than a badly timed offer,
    /// which is the direction the error is allowed to run in.
    public var promptHours: PromptHours

    /// Local hour at which the end-of-day review is allowed to look at the day. 0–23.
    ///
    /// Not "the hour the notification arrives": see `notifyOnEndOfDayReview`.
    public var endOfDayReviewHour: Int
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
        notifyOnSessionCompleted: Bool = false,
        notifyAtHalfway: Bool = false,
        notifyOnLongIdle: Bool = false,
        notifyOnEndOfDayReview: Bool = false,
        notifyOnUnlabelledBlock: Bool = false,
        promptHours: PromptHours = .default,
        endOfDayReviewHour: Int = 18,
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
        self.notifyOnSessionCompleted = notifyOnSessionCompleted
        self.notifyAtHalfway = notifyAtHalfway
        self.notifyOnLongIdle = notifyOnLongIdle
        self.notifyOnEndOfDayReview = notifyOnEndOfDayReview
        self.notifyOnUnlabelledBlock = notifyOnUnlabelledBlock
        self.promptHours = promptHours
        self.endOfDayReviewHour = min(23, max(0, endOfDayReviewHour))
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
        case notifyOnSessionCompleted
        case notifyAtHalfway
        case notifyOnLongIdle
        case notifyOnEndOfDayReview
        case notifyOnUnlabelledBlock
        case promptHours
        case endOfDayReviewHour
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
            // A preferences file written before notifications existed carries none of these keys,
            // and the fallback is off — so upgrading Lggr never turns a notification on for
            // somebody who has not asked for one.
            notifyOnSessionCompleted: try container.decodeIfPresent(
                Bool.self, forKey: .notifyOnSessionCompleted) ?? fallback.notifyOnSessionCompleted,
            notifyAtHalfway: try container.decodeIfPresent(
                Bool.self, forKey: .notifyAtHalfway) ?? fallback.notifyAtHalfway,
            notifyOnLongIdle: try container.decodeIfPresent(
                Bool.self, forKey: .notifyOnLongIdle) ?? fallback.notifyOnLongIdle,
            notifyOnEndOfDayReview: try container.decodeIfPresent(
                Bool.self, forKey: .notifyOnEndOfDayReview) ?? fallback.notifyOnEndOfDayReview,
            notifyOnUnlabelledBlock: try container.decodeIfPresent(
                Bool.self, forKey: .notifyOnUnlabelledBlock) ?? fallback.notifyOnUnlabelledBlock,
            promptHours: try container.decodeIfPresent(PromptHours.self, forKey: .promptHours)
                ?? fallback.promptHours,
            endOfDayReviewHour: try container.decodeIfPresent(
                Int.self, forKey: .endOfDayReviewHour) ?? fallback.endOfDayReviewHour,
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
        try container.encode(notifyOnSessionCompleted, forKey: .notifyOnSessionCompleted)
        try container.encode(notifyAtHalfway, forKey: .notifyAtHalfway)
        try container.encode(notifyOnLongIdle, forKey: .notifyOnLongIdle)
        try container.encode(notifyOnEndOfDayReview, forKey: .notifyOnEndOfDayReview)
        try container.encode(notifyOnUnlabelledBlock, forKey: .notifyOnUnlabelledBlock)
        try container.encode(promptHours, forKey: .promptHours)
        try container.encode(endOfDayReviewHour, forKey: .endOfDayReviewHour)
        try container.encodeIfPresent(lastProjectID, forKey: .lastProjectID)
        try container.encode(recentOutcomes, forKey: .recentOutcomes)
    }
}
