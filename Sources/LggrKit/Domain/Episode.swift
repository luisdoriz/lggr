import Foundation

/// Where an episode's name came from, which is the same thing as how far it can be trusted.
///
/// The cases are named for their evidence rather than for a tier, because a tier is not auditable and
/// a source is: every one of these can be shown to the user as the reason the block is called what it
/// is called. Ordering runs from the app roster, which claims nothing beyond what was on screen, up to
/// the user's own words, which claim everything.
public enum LabelConfidence: String, Codable, CaseIterable, Sendable, Hashable, Comparable {
    /// The applications, by descending time. Names what was in front of the user and nothing else.
    case appRoster
    /// A category shared by the applications in the block.
    case category
    /// Reserved: an identifier extracted from a window title, once the title probe has earned it.
    case identifier
    /// The intended outcome of a session this block overlaps, verbatim. The user's own sentence.
    case declared

    private var rank: Int {
        switch self {
        case .appRoster: 0
        case .category: 1
        case .identifier: 2
        case .declared: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// The name is something the user typed, so the app is quoting rather than guessing.
    public var isUserAuthored: Bool { self == .declared }
}

/// One readable block of a day: the product primitive.
///
/// A person recognises "9:04–9:50, Xcode and Terminal". Nobody recognises forty-six activations, and
/// nobody can act on them. Raw intervals are the evidence an episode is built from; the episode is
/// the thing that reaches a screen, an export, or a session.
///
/// The evidence is referenced as a span plus a count rather than as a list of interval identifiers.
/// A list would cost roughly ten megabytes a year to keep an audit trail whose underlying records
/// expire before the episode does.
public struct Episode: Identifiable, Codable, Hashable, Sendable {

    /// One application's share of an episode.
    public struct AppShare: Codable, Hashable, Sendable, Identifiable {
        public let bundleIdentifier: String
        public let displayName: String
        /// Summed from `ActivityInterval.monotonicDuration`, never from wall clock.
        public let duration: TimeInterval
        /// How many separate times this application came to the front inside the episode. A glance
        /// that was collapsed into an interjection is not a visit.
        public let visitCount: Int

        public var id: String { bundleIdentifier }

        public init(
            bundleIdentifier: String,
            displayName: String,
            duration: TimeInterval,
            visitCount: Int = 1
        ) {
            self.bundleIdentifier = bundleIdentifier
            self.displayName = displayName
            self.duration = duration.isFinite ? max(0, duration) : 0
            self.visitCount = max(0, visitCount)
        }
    }

    public let id: UUID
    public let start: Date
    public let end: Date
    /// Descending by duration. Ties are broken by bundle identifier so the order is total and the
    /// same evidence always produces the same roster.
    public let apps: [AppShare]
    /// Excursions short enough to have returned before they became a context switch — a cmd-tab to
    /// Slack and back. Counted here rather than cut into blocks, because a five-second glance is not
    /// a switch in any sense a person recognises.
    public let interjections: Int
    public let label: String
    public let labelConfidence: LabelConfidence
    /// The session this block overlaps, when it overlaps one. `nil` for time nobody declared.
    public let sessionID: UUID?
    /// How many intervals were folded into this block. With `start` and `end` this is the whole audit
    /// trail: enough to find the evidence again, not enough to be a second copy of it.
    public let intervalCount: Int

    public init(
        id: UUID = UUID(),
        start: Date,
        end: Date,
        apps: [AppShare],
        interjections: Int = 0,
        label: String,
        labelConfidence: LabelConfidence,
        sessionID: UUID? = nil,
        intervalCount: Int = 0
    ) {
        self.id = id
        self.start = start
        self.end = max(start, end)
        self.apps = apps
        self.interjections = max(0, interjections)
        self.label = label
        self.labelConfidence = labelConfidence
        self.sessionID = sessionID
        self.intervalCount = max(0, intervalCount)
    }

    // MARK: - Durations

    /// Time actually spent in an application during this block.
    ///
    /// Derived from the app shares rather than stored beside them, so the two can never disagree, and
    /// always shorter than the wall-clock span when the block contains idle time.
    public var activeDuration: TimeInterval {
        apps.reduce(0) { $0 + $1.duration }
    }

    /// Where the block sits on the timeline. Position, not length.
    public var wallClockSpan: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public var dateInterval: DateInterval { DateInterval(start: start, end: end) }

    public var dominantApp: AppShare? { apps.first }

    public var overlapsSession: Bool { sessionID != nil }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    // MARK: - Display

    /// The applications, as the timeline row shows them: "Xcode, Terminal, Simulator +2 more".
    ///
    /// Three is the cap because a fourth name stops being read. The overflow is counted rather than
    /// dropped so the row never implies the block held fewer applications than it did.
    public func appRoster(limit: Int = 3) -> String {
        guard !apps.isEmpty else { return "" }
        let shown = apps.prefix(max(1, limit))
        let names = shown.map(\.displayName).joined(separator: ", ")
        let hidden = apps.count - shown.count
        return hidden > 0 ? "\(names) +\(hidden) more" : names
    }

    public var appRosterText: String { appRoster() }

    /// The block's length as the timeline row shows it: "46m", "1h 40m".
    public var durationText: String { DurationFormatting.compact(activeDuration) }
}
