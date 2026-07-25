import Foundation

/// Why a session existed: because it was chosen, or because it arrived.
///
/// The split is two-way — planned or reactive — but the planned side is worth separating, because
/// "I chose this and it serves the outcome I named" and "I chose this and it serves nothing I wrote
/// down" are different facts about a week, and collapsing them hides the second one entirely.
///
/// None of the three is better than the others. A week of nothing but `committed` work would mean a
/// manager did no incident response and answered nobody, which is not a good week.
public enum WorkOrigin: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Chosen, and linked to a weekly outcome.
    case committed
    /// Chosen, with no weekly outcome behind it.
    case chosen
    /// Arrived rather than chosen.
    case arrived

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .committed: "Committed"
        case .chosen: "Chosen"
        case .arrived: "Arrived"
        }
    }

    public var isPlanned: Bool { self != .arrived }
}

/// How a week's tracked time divides into work that was chosen and work that arrived.
///
/// Three inputs, in strict precedence:
///
/// 1. `FocusSession.isReactive` decides planned versus reactive, and nothing overrides it. It is the
///    only one of the three the user can edit directly, so it is the only one entitled to the last
///    word — a deep-work session someone marked reactive really was reactive.
/// 2. `WorkType.isReactiveByDefault` is what seeded that flag when the session started. It is not
///    consulted again; it appears here only as `overriddenSessionCount`, the number of times the user
///    disagreed with the default, which is the evidence that the flag means anything at all.
/// 3. `FocusSession.weeklyOutcomeID` splits the planned side into committed and chosen.
///
/// Only finished sessions contribute duration. A running session's length is still changing, and an
/// aggregate built from a moving number is one that disagrees with itself between two reads of the
/// same screen. Running sessions are counted in `unfinishedSessionCount` rather than ignored, so a
/// caller can see that the total does not cover everything on the timeline.
///
/// Pure: it takes sessions and nothing else. No clock, no store.
public struct PlannedVsReactive: Hashable, Sendable {

    public let durationByOrigin: [WorkOrigin: TimeInterval]
    public let sessionCountByOrigin: [WorkOrigin: Int]
    /// Finished-session time by the work type the user selected when starting.
    public let durationByWorkType: [WorkType: TimeInterval]
    /// Finished sessions whose `isReactive` disagrees with their work type's default.
    public let overriddenSessionCount: Int
    /// Sessions that had not ended, and therefore contributed no duration anywhere.
    public let unfinishedSessionCount: Int

    public init(sessions: [FocusSession] = []) {
        var durationByOrigin: [WorkOrigin: TimeInterval] = [:]
        var sessionCountByOrigin: [WorkOrigin: Int] = [:]
        var durationByWorkType: [WorkType: TimeInterval] = [:]
        var overridden = 0
        var unfinished = 0

        for session in sessions {
            guard let duration = session.effectiveDuration else {
                unfinished += 1
                continue
            }
            let origin = PlannedVsReactive.origin(of: session)
            durationByOrigin[origin, default: 0] += duration
            sessionCountByOrigin[origin, default: 0] += 1
            durationByWorkType[session.workType, default: 0] += duration
            if session.isReactive != session.workType.isReactiveByDefault {
                overridden += 1
            }
        }

        self.durationByOrigin = durationByOrigin
        self.sessionCountByOrigin = sessionCountByOrigin
        self.durationByWorkType = durationByWorkType
        self.overriddenSessionCount = overridden
        self.unfinishedSessionCount = unfinished
    }

    /// Which side of the split a single session falls on.
    public static func origin(of session: FocusSession) -> WorkOrigin {
        if session.isReactive { return .arrived }
        return session.weeklyOutcomeID == nil ? .chosen : .committed
    }

    // MARK: - Durations

    public func duration(for origin: WorkOrigin) -> TimeInterval {
        durationByOrigin[origin] ?? 0
    }

    public func sessionCount(for origin: WorkOrigin) -> Int {
        sessionCountByOrigin[origin] ?? 0
    }

    public func duration(for workType: WorkType) -> TimeInterval {
        durationByWorkType[workType] ?? 0
    }

    public var committedDuration: TimeInterval { duration(for: .committed) }
    public var chosenDuration: TimeInterval { duration(for: .chosen) }
    public var plannedDuration: TimeInterval { committedDuration + chosenDuration }
    public var reactiveDuration: TimeInterval { duration(for: .arrived) }
    public var trackedDuration: TimeInterval { plannedDuration + reactiveDuration }

    // MARK: - Counts

    public var plannedSessionCount: Int {
        sessionCount(for: .committed) + sessionCount(for: .chosen)
    }

    public var reactiveSessionCount: Int { sessionCount(for: .arrived) }

    /// Finished sessions only, matching every duration on this type.
    public var sessionCount: Int { plannedSessionCount + reactiveSessionCount }

    public var isEmpty: Bool { sessionCount == 0 }

    // MARK: - Shares

    /// Fraction of tracked time, or `nil` when nothing was tracked.
    ///
    /// Optional rather than zero: a week with no sessions has no answer to "what share was planned",
    /// and returning 0% would let a caller print a sentence about a week that was never recorded.
    public func share(of duration: TimeInterval) -> Double? {
        guard trackedDuration > 0 else { return nil }
        return min(1, max(0, duration / trackedDuration))
    }

    public var plannedShare: Double? { share(of: plannedDuration) }
    public var reactiveShare: Double? { share(of: reactiveDuration) }
    public var committedShare: Double? { share(of: committedDuration) }
}
