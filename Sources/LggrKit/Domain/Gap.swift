import Foundation

/// Why the timeline has nothing to show for a stretch of the day.
///
/// A gap is the single most important honesty mechanism in the reconstruction. Time the app cannot
/// account for must be visible as time the app cannot account for; the alternative — smearing it into
/// whichever block happens to sit next to it — is how a lid closed at 18:00 becomes a fifteen-hour
/// Xcode session.
public enum GapReason: String, Codable, CaseIterable, Sendable, Hashable {
    /// An application was still frontmost, but no input arrived for long enough to stop calling it
    /// work. The only soft reason here: it is the one the app infers rather than observes.
    case idle
    /// The display went to sleep.
    case displayOff
    /// The machine slept.
    case systemSleep
    /// The screen was locked.
    case screenLocked
    /// Another account was on the console. Capture stops outright: the other user's typing would
    /// otherwise zero this user's idle timer and manufacture activity.
    case fastUserSwitched
    /// Lggr itself was not running — a quit, a crash, a lost power cord, a restart. Reconstructed on
    /// the next launch from the last heartbeat, never from the launch time.
    case appNotRunning
    /// The user turned tracking off.
    case trackingPaused
    /// The frontmost application was on the exclusion or private list, so nothing was recorded.
    case excludedApplication
    /// Time that reached the timeline with no explanation attached to it.
    ///
    /// This case exists so that an absence the app cannot account for stays an absence. Anything that
    /// cannot be explained must still be representable, or the pressure to make the timeline look
    /// tidy will quietly absorb it into a neighbouring block and invent work that did not happen.
    case unexplained

    /// This reason ends a run outright, so the segmenter may never merge across it.
    ///
    /// Idle is the exception: the application was still frontmost and the user may well have been
    /// reading, so an idle stretch interrupts a block without necessarily separating two of them.
    public var isHardBoundary: Bool { self != .idle }

    /// Time the app observed the reason for. `.unexplained` is the only false case, by construction.
    public var isExplained: Bool { self != .unexplained }

    /// Facts about the record, never about the person: no sentence here has the user as its subject.
    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .displayOff: "Display off"
        case .systemSleep: "Asleep"
        case .screenLocked: "Screen locked"
        case .fastUserSwitched: "Another user signed in"
        case .appNotRunning: "Lggr was not running"
        case .trackingPaused: "Tracking paused"
        case .excludedApplication: "Excluded application"
        case .unexplained: "Not accounted for"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: "pause.circle"
        case .displayOff: "display.trianglebadge.exclamationmark"
        case .systemSleep: "moon.zzz"
        case .screenLocked: "lock"
        case .fastUserSwitched: "person.2"
        case .appNotRunning: "bolt.slash"
        case .trackingPaused: "hand.raised"
        case .excludedApplication: "eye.slash"
        case .unexplained: "questionmark.circle"
        }
    }
}

/// A typed absence on the day timeline.
///
/// Unlike every other duration in the domain, a gap is measured on the wall clock. That is not an
/// oversight: nothing was sampled across a gap, so there is no monotonic measurement to sum, and a
/// monotonic clock does not advance while the machine is asleep — which would report the most common
/// gap in the corpus as zero seconds long. Stating the wall-clock span is the only honest option, and
/// a gap is never counted as tracked time, so a clock step cannot inflate one into work.
public struct Gap: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let reason: GapReason
    public let start: Date
    public let end: Date

    public init(id: UUID = UUID(), reason: GapReason, start: Date, end: Date) {
        self.id = id
        self.reason = reason
        self.start = start
        self.end = max(start, end)
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    public var dateInterval: DateInterval { DateInterval(start: start, end: end) }

    public var isHardBoundary: Bool { reason.isHardBoundary }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }

    /// True when `other` lies entirely inside this gap.
    ///
    /// `.systemSleep` and `.appNotRunning` collide every single night — the app is not running while
    /// the machine sleeps — and the precedence that resolves it is stated in terms of this test: a
    /// heartbeat gap fully covered by a sleep is a sleep gap.
    public func covers(_ other: Gap) -> Bool {
        other.start >= start && other.end <= end
    }

    public func overlaps(_ other: Gap) -> Bool {
        start < other.end && other.start < end
    }
}
