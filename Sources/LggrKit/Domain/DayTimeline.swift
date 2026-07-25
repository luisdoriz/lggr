import Foundation

/// One day, rebuilt: the blocks and the honestly marked absences between them, in order.
///
/// This is the whole output of the segmenter and the whole input to the Today timeline. It carries no
/// clock and computes nothing from "now" — a timeline is a statement about a span that has already
/// happened, and two callers reading the same one must see the same day.
public struct DayTimeline: Codable, Hashable, Sendable {

    /// A row on the timeline: something that happened, or something that did not.
    public enum Entry: Codable, Hashable, Sendable, Identifiable {
        case episode(Episode)
        case gap(Gap)

        public var id: UUID {
            switch self {
            case .episode(let episode): episode.id
            case .gap(let gap): gap.id
            }
        }

        public var start: Date {
            switch self {
            case .episode(let episode): episode.start
            case .gap(let gap): gap.start
            }
        }

        public var end: Date {
            switch self {
            case .episode(let episode): episode.end
            case .gap(let gap): gap.end
            }
        }
    }

    /// The instant the day is anchored to, for bucketing and for display. A day runs from here; it is
    /// supplied by the caller because a day boundary is a calendar question and this type has no
    /// calendar.
    public let dayStart: Date
    /// Ordered by `start`, non-overlapping.
    public let episodes: [Episode]
    /// Ordered by `start`, non-overlapping with each other and with the episodes.
    public let gaps: [Gap]
    /// The day is closed: its episodes are immutable except by an explicit user edit.
    ///
    /// A timeline that silently rewrites its own past is not evidence. Sealing happens after
    /// `sealingHourLocal` on the following day; whether that moment has passed is a question for a
    /// caller with a clock, so this type carries only the answer.
    public let sealed: Bool

    /// A day seals at 04:00 local on the day after it, not at midnight — the hours either side of
    /// midnight belong to the day whose work they are.
    public static let sealingHourLocal = 4

    public init(dayStart: Date, episodes: [Episode], gaps: [Gap], sealed: Bool = false) {
        self.dayStart = dayStart
        self.episodes = episodes.sorted { $0.start < $1.start }
        self.gaps = gaps.sorted { $0.start < $1.start }
        self.sealed = sealed
    }

    // MARK: - Ordering

    /// Episodes and gaps interleaved in the order they occurred — what a timeline view renders.
    ///
    /// An episode sorts before a gap that starts at the same instant, because the gap is what follows
    /// the block rather than what accompanies it.
    public var entries: [Entry] {
        let all = episodes.map(Entry.episode) + gaps.map(Entry.gap)
        return all.sorted { left, right in
            if left.start != right.start { return left.start < right.start }
            if case .episode = left, case .gap = right { return true }
            return false
        }
    }

    public var isEmpty: Bool { episodes.isEmpty && gaps.isEmpty }

    /// First start to last end across everything on the timeline, or `nil` for an empty day.
    public var bounds: DateInterval? {
        let starts = entries.map(\.start)
        let ends = entries.map(\.end)
        guard let first = starts.min(), let last = ends.max() else { return nil }
        return DateInterval(start: first, end: max(first, last))
    }

    // MARK: - Totals

    public var episodeCount: Int { episodes.count }

    /// Time inside a block, summed from monotonic measurements. Gaps contribute nothing.
    public var trackedDuration: TimeInterval {
        episodes.reduce(0) { $0 + $1.activeDuration }
    }

    /// Glances collapsed across the whole day.
    public var interjectionCount: Int {
        episodes.reduce(0) { $0 + $1.interjections }
    }

    public func gaps(for reason: GapReason) -> [Gap] {
        gaps.filter { $0.reason == reason }
    }

    public func gapDuration(for reason: GapReason) -> TimeInterval {
        gaps(for: reason).reduce(0) { $0 + $1.duration }
    }

    public var gapDuration: TimeInterval {
        gaps.reduce(0) { $0 + $1.duration }
    }

    /// Time on the timeline with no explanation attached to it.
    ///
    /// Surfaced as a number in its own right so that an unexplained day is visible as one rather than
    /// inferred from the absence of anything else.
    public var unexplainedDuration: TimeInterval { gapDuration(for: .unexplained) }

    public var hasUnexplainedTime: Bool { unexplainedDuration > 0 }

    // MARK: - Lookup

    public func episode(containing date: Date) -> Episode? {
        episodes.first { $0.contains(date) }
    }

    public func gap(containing date: Date) -> Gap? {
        gaps.first { $0.contains(date) }
    }

    /// Blocks that borrowed their name from a session, in timeline order.
    public var declaredEpisodes: [Episode] {
        episodes.filter(\.overlapsSession)
    }
}
