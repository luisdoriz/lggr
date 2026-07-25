import Foundation

/// How much the idle reading behind an interval can be trusted.
///
/// Idle is forgeable. Any process can zero `CGEventSource.secondsSinceLastEventType`, and several
/// do so in ordinary use — Screen Sharing, mouse jigglers, Karabiner, Zoom remote control. Idle is
/// therefore an annotation carried alongside an interval and never the thing that decides whether a
/// run was unbroken; frontmost-app continuity decides that.
public enum IdleConfidence: String, Codable, CaseIterable, Sendable, Hashable {
    /// Corroborated by something outside the idle timer: the display was asleep, or the console
    /// session was not on screen, over the same span.
    case high
    /// The idle timer alone said so.
    case low

    public var displayName: String {
        switch self {
        case .high: "Idle"
        case .low: "Possibly idle"
        }
    }
}

/// One continuous stretch with a single application in front of the user.
///
/// This is evidence, not product. The thing a person reads is an `Episode`, built from hundreds of
/// these. An interval ends when the frontmost application changes, when the idle state changes, or
/// when sampling stops.
///
/// **There is no `windowTitle` field, and there will not be one.** Titles are read in one function,
/// matched against grammars, reduced to typed evidence and released; they never reach this type and
/// are never written to disk. A later phase adds a derived category and extracted identifier tokens,
/// never a title. See `docs/_design/INTELLIGENCE.md` §3.3.
public struct ActivityInterval: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let bundleIdentifier: String
    /// The application's own name, for display. Stored alongside the bundle id so a timeline built
    /// months later still renders when the application has been uninstalled or renamed.
    public let displayName: String
    /// Wall clock, for placing the interval on a timeline and bucketing it into an hour of the day.
    /// **Never for measuring it** — see `monotonicDuration`.
    public let start: Date
    /// Wall clock. Clamped at construction so it can never precede `start`.
    public let end: Date
    /// The length of this interval as measured by a clock that cannot be stepped.
    ///
    /// `end - start` is not that clock. An NTP correction, a daylight-saving transition or a user
    /// dragging the system clock forward would all inflate a run measured that way, and an inflated
    /// run becomes a confidently wrong block — the one failure the design is arranged to avoid.
    /// Every duration in the pipeline is a sum of these.
    public let monotonicDuration: TimeInterval
    /// The user was not generating input for this whole stretch. The application was still frontmost.
    public let isIdle: Bool
    public let idleConfidence: IdleConfidence
    /// Minutes east of UTC in effect at capture, so an hour-of-day bucket survives travel and DST.
    /// A day with no timezone recorded cannot support any circadian claim at all.
    public let tzOffsetMinutes: Int

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        start: Date,
        end: Date,
        monotonicDuration: TimeInterval,
        isIdle: Bool = false,
        idleConfidence: IdleConfidence = .low,
        tzOffsetMinutes: Int = 0
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.start = start
        self.end = max(start, end)
        self.monotonicDuration = monotonicDuration.isFinite ? max(0, monotonicDuration) : 0
        self.isIdle = isIdle
        self.idleConfidence = idleConfidence
        self.tzOffsetMinutes = tzOffsetMinutes
    }

    // MARK: - Derived

    public var isActive: Bool { !isIdle }

    /// Where the interval sits on the timeline. Position only; ask `monotonicDuration` for length.
    public var dateInterval: DateInterval { DateInterval(start: start, end: end) }

    /// What the wall clock claims this interval lasted. Present so it can be compared against the
    /// monotonic measurement, not so it can be summed.
    public var wallClockDuration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// How far the two clocks disagree. A large value means the system clock moved during capture.
    public var clockDisagreement: TimeInterval { abs(wallClockDuration - monotonicDuration) }

    /// Both clocks tell the same story to within `tolerance`.
    ///
    /// An interval that fails this has been stretched or squashed by something other than the passage
    /// of time, and the honest response is to drop it rather than to place it.
    public func clocksAgree(within tolerance: TimeInterval = 2) -> Bool {
        clockDisagreement <= max(0, tolerance)
    }
}
