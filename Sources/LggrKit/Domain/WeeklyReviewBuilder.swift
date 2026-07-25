import Foundation

/// Everything a week's review is computed from.
///
/// Passed in whole rather than fetched, because the builder has no store, no clock and no calendar of
/// its own. A caller assembles the week — from the file store today, from SwiftData later, from a
/// fixture in a test — and the arithmetic is identical in all three.
public struct WeeklyReviewInput: Hashable, Sendable {

    /// The week under review. Membership is half-open: `start <= timestamp < end`, so a record
    /// stamped at exactly midnight on Monday belongs to one week rather than to two.
    public var week: DateInterval
    public var sessions: [FocusSession]
    public var accomplishments: [Accomplishment]
    public var interruptions: [Interruption]
    /// The reconstructed timeline. Supplies observed application time and the per-day context-switch
    /// count; it is a different measurement from session time and the review keeps the two apart.
    public var episodes: [Episode]
    public var outcomes: WeeklyOutcomeSet
    /// Resolved by the caller, which is the only thing that holds projects.
    public var projectNames: [UUID: String]
    /// Bundle identifier to category. Absent means `.unknown` — a refusal to guess, not a bucket.
    public var appCategories: [String: AppCategory]
    /// Decides day boundaries and weekday names. Injected so a week is seven days across a
    /// daylight-saving transition and starts on the day the user's region says it does.
    public var calendar: Calendar

    public init(
        week: DateInterval,
        sessions: [FocusSession] = [],
        accomplishments: [Accomplishment] = [],
        interruptions: [Interruption] = [],
        episodes: [Episode] = [],
        outcomes: WeeklyOutcomeSet? = nil,
        projectNames: [UUID: String] = [:],
        appCategories: [String: AppCategory] = SegmentationWeights.default.categories,
        calendar: Calendar = .current
    ) {
        self.week = week
        self.sessions = sessions
        self.accomplishments = accomplishments
        self.interruptions = interruptions
        self.episodes = episodes
        self.outcomes = outcomes ?? WeeklyOutcomeSet(weekStart: week.start)
        self.projectNames = projectNames
        self.appCategories = appCategories
        self.calendar = calendar
    }
}

/// One week, answered.
///
/// Every field maps onto a question §9 asks. Two measurements run through it and they are
/// deliberately never added together:
///
/// - **Session time** — `trackedDuration`, and everything derived from projects, work types and the
///   planned/reactive split. This is time the user declared.
/// - **Observed time** — `observedDuration` and the category breakdown. This is time applications
///   were in front of the user, whether or not a session was running.
///
/// They measure different things and will not match. Presenting a single blended total would produce
/// a number that is true of neither.
///
/// There is no total for time spent outside a session, and there will not be one: that is the number
/// that grows when the user fails to comply with the app, which `INTELLIGENCE.md` §3.4 removed.
/// §9's "what work remained invisible?" is answered by `supportDuration` — review, unblocking and
/// incident work, which is invisible to everyone else rather than to Lggr.
public struct WeeklyReview: Hashable, Sendable {

    // MARK: - Breakdowns

    public struct ProjectTime: Identifiable, Hashable, Sendable {
        /// `nil` for sessions filed under no project.
        public let projectID: UUID?
        public let name: String
        public let duration: TimeInterval
        public let sessionCount: Int

        public var id: String { projectID?.uuidString ?? "unfiled" }

        public init(projectID: UUID?, name: String, duration: TimeInterval, sessionCount: Int) {
            self.projectID = projectID
            self.name = name
            self.duration = duration
            self.sessionCount = sessionCount
        }
    }

    public struct WorkTypeTime: Identifiable, Hashable, Sendable {
        public let workType: WorkType
        public let duration: TimeInterval

        public var id: String { workType.rawValue }

        public init(workType: WorkType, duration: TimeInterval) {
            self.workType = workType
            self.duration = duration
        }
    }

    public struct CategoryTime: Identifiable, Hashable, Sendable {
        public let category: AppCategory
        public let duration: TimeInterval

        public var id: String { category.rawValue }

        public init(category: AppCategory, duration: TimeInterval) {
            self.category = category
            self.duration = duration
        }
    }

    public struct InterruptionSourceCount: Identifiable, Hashable, Sendable {
        public let source: InterruptionSource
        public let count: Int

        public var id: String { source.rawValue }

        public init(source: InterruptionSource, count: Int) {
            self.source = source
            self.count = count
        }
    }

    /// One day of the week, whether or not anything happened on it. Empty days are kept so a caller
    /// can render seven columns without inventing the missing ones.
    public struct Day: Identifiable, Hashable, Sendable {
        public let start: Date
        public let trackedDuration: TimeInterval
        public let sessionCount: Int
        public let episodeCount: Int
        /// Moves from one block of work to the next. Glances that returned within seconds were folded
        /// into their block by the segmenter and are not counted here.
        public let contextSwitches: Int
        public let interruptionCount: Int

        public var id: Date { start }

        public var isActive: Bool { sessionCount > 0 || episodeCount > 0 }

        public init(
            start: Date,
            trackedDuration: TimeInterval,
            sessionCount: Int,
            episodeCount: Int,
            contextSwitches: Int,
            interruptionCount: Int
        ) {
            self.start = start
            self.trackedDuration = trackedDuration
            self.sessionCount = sessionCount
            self.episodeCount = episodeCount
            self.contextSwitches = contextSwitches
            self.interruptionCount = interruptionCount
        }
    }

    /// What a weekly outcome actually received.
    ///
    /// `selfReportedProgress` is the user's own number and `trackedDuration` is Lggr's. They are
    /// reported side by side and never reconciled: time spent is not progress made, and a rule that
    /// turned one into the other would be inventing the thing the user is best placed to know.
    public struct OutcomeProgress: Identifiable, Hashable, Sendable {
        public let outcomeID: UUID
        public let title: String
        public let priority: OutcomePriority
        public let status: OutcomeStatus
        public let selfReportedProgress: Double
        public let sessionCount: Int
        public let trackedDuration: TimeInterval
        /// Share of the week's session time, or `nil` when no time was tracked at all.
        public let shareOfTrackedTime: Double?
        public let accomplishmentCount: Int

        public var id: UUID { outcomeID }

        public init(
            outcomeID: UUID,
            title: String,
            priority: OutcomePriority,
            status: OutcomeStatus,
            selfReportedProgress: Double,
            sessionCount: Int,
            trackedDuration: TimeInterval,
            shareOfTrackedTime: Double?,
            accomplishmentCount: Int
        ) {
            self.outcomeID = outcomeID
            self.title = title
            self.priority = priority
            self.status = status
            self.selfReportedProgress = selfReportedProgress
            self.sessionCount = sessionCount
            self.trackedDuration = trackedDuration
            self.shareOfTrackedTime = shareOfTrackedTime
            self.accomplishmentCount = accomplishmentCount
        }
    }

    // MARK: - Stored

    public let week: DateInterval
    public let calendar: Calendar

    /// The week's records, filtered and ordered newest first. Kept so observations are a pure
    /// function of the review rather than of the review plus the input that produced it.
    public let sessions: [FocusSession]
    public let accomplishments: [Accomplishment]
    public let interruptions: [Interruption]
    /// Ascending by start.
    public let episodes: [Episode]
    public let outcomes: WeeklyOutcomeSet

    public let plannedVsReactive: PlannedVsReactive
    public let timeByProject: [ProjectTime]
    public let timeByWorkType: [WorkTypeTime]
    public let timeByCategory: [CategoryTime]
    public let days: [Day]
    public let outcomeProgress: [OutcomeProgress]
    public let interruptionSources: [InterruptionSourceCount]

    public let sessionsCompleted: Int
    public let sessionsInterrupted: Int
    /// Finished sessions carrying a weekly outcome. Below a handful of these, a share-of-time claim
    /// about an outcome describes how diligently sessions were linked, not where the week went.
    public let sessionsLinkedToOutcome: Int
    /// Sessions that had at least one interruption captured against them.
    public let sessionsWithCapturedInterruption: Int

    /// Review, unblocking and incident work: the part of the week that leaves no trace anywhere else.
    public let supportDuration: TimeInterval
    public let supportSessionCount: Int
    /// Observed application time across the week's episodes. Not session time.
    public let observedDuration: TimeInterval

    public static let unfiledProjectName = "No project"
    static let unnamedProjectName = "Unnamed project"

    // MARK: - Derived

    /// Declared session time. The denominator for projects, work types and the planned/reactive split.
    public var trackedDuration: TimeInterval { plannedVsReactive.trackedDuration }

    public var sessionCount: Int { sessions.count }

    public var finishedSessionCount: Int { plannedVsReactive.sessionCount }

    public var deepWorkSessions: [FocusSession] {
        sessions.filter { $0.workType == .deepWork && $0.effectiveDuration != nil }
    }

    public var finishedSessions: [FocusSession] {
        sessions.filter { $0.effectiveDuration != nil }
    }

    public var activeDays: [Day] { days.filter(\.isActive) }

    public var contextSwitchTotal: Int { days.reduce(0) { $0 + $1.contextSwitches } }

    /// `nil` when no day in the week saw any activity, so a caller cannot divide by an empty week.
    public var averageContextSwitchesPerActiveDay: Double? {
        let active = activeDays
        guard !active.isEmpty else { return nil }
        return Double(contextSwitchTotal) / Double(active.count)
    }

    public var interruptionCount: Int { interruptions.count }

    public var primaryOutcomeProgress: OutcomeProgress? {
        guard let primary = outcomes.primary else { return nil }
        return outcomeProgress.first { $0.outcomeID == primary.id }
    }

    public var supportAccomplishments: [Accomplishment] {
        accomplishments.filter(\.type.isSupportWork)
    }

    /// Aggregate only. Per-person evidence stays inside the app and never reaches an export —
    /// `INTELLIGENCE.md` §3.7.
    public var peopleUnblockedCount: Int {
        accomplishments.reduce(0) { $0 + ($1.type == .personUnblocked ? 1 : 0) }
    }

    public var isEmpty: Bool {
        sessions.isEmpty && accomplishments.isEmpty && interruptions.isEmpty && episodes.isEmpty
    }

    /// Share of declared session time, or `nil` when none was tracked.
    public func share(of duration: TimeInterval) -> Double? {
        plannedVsReactive.share(of: duration)
    }

    /// Share of observed application time, or `nil` when nothing was observed.
    public func observedShare(of duration: TimeInterval) -> Double? {
        guard observedDuration > 0 else { return nil }
        return min(1, max(0, duration / observedDuration))
    }

    /// The accomplishments a weekly summary leads with.
    ///
    /// Ordered by what the user tied them to, not by a judgment about which mattered: everything
    /// linked to the primary outcome first, then anything linked to any outcome, then the rest, each
    /// group newest first. No accomplishment type outranks another.
    public func mainAccomplishments(limit: Int = 5) -> [Accomplishment] {
        guard limit > 0 else { return [] }
        let primaryID = outcomes.primary?.id
        let outcomeIDs = Set(outcomes.all.map(\.id))

        func tier(_ accomplishment: Accomplishment) -> Int {
            guard let outcomeID = accomplishment.weeklyOutcomeID else { return 2 }
            if let primaryID, outcomeID == primaryID { return 0 }
            return outcomeIDs.contains(outcomeID) ? 1 : 2
        }

        let ranked = accomplishments.enumerated().sorted { lhs, rhs in
            let left = tier(lhs.element)
            let right = tier(rhs.element)
            // `accomplishments` is already newest first with ties broken by id, so the original index
            // is the whole tiebreak and the sort stays total without re-deriving that order.
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        return ranked.prefix(limit).map(\.element)
    }
}

/// Turns a week of records into the review §9 describes.
///
/// Pure and total: same input, same output, no clock read anywhere. "Now" is not a parameter because
/// a review is of a bounded window — a session that has not ended contributes no duration whatever
/// the time is.
public enum WeeklyReviewBuilder {

    public static func build(_ input: WeeklyReviewInput) -> WeeklyReview {
        let week = input.week

        let sessions = input.sessions
            .filter { StoreOrdering.contains($0.startedAt, in: week) }
            .sorted(by: StoreOrdering.newestFirst)
        let accomplishments = input.accomplishments
            .filter { StoreOrdering.contains($0.timestamp, in: week) }
            .sorted(by: StoreOrdering.newestFirst)
        let interruptions = input.interruptions
            .filter { StoreOrdering.contains($0.timestamp, in: week) }
            .sorted(by: newestFirst)
        let episodes = input.episodes
            .filter { StoreOrdering.contains($0.start, in: week) }
            .sorted(by: earliestFirst)

        let plannedVsReactive = PlannedVsReactive(sessions: sessions)
        let sessionIDs = Set(sessions.map(\.id))
        let support = support(sessions: sessions, accomplishments: accomplishments)

        return WeeklyReview(
            week: week,
            calendar: input.calendar,
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions,
            episodes: episodes,
            outcomes: input.outcomes,
            plannedVsReactive: plannedVsReactive,
            timeByProject: timeByProject(sessions: sessions, names: input.projectNames),
            timeByWorkType: timeByWorkType(plannedVsReactive),
            timeByCategory: timeByCategory(episodes: episodes, categories: input.appCategories),
            days: days(
                week: week,
                calendar: input.calendar,
                sessions: sessions,
                episodes: episodes,
                interruptions: interruptions
            ),
            outcomeProgress: outcomeProgress(
                outcomes: input.outcomes,
                sessions: sessions,
                accomplishments: accomplishments,
                trackedDuration: plannedVsReactive.trackedDuration
            ),
            interruptionSources: interruptionSources(interruptions),
            sessionsCompleted: sessions.reduce(0) {
                $0 + (($1.resultStatus?.countsAsCompleted ?? false) ? 1 : 0)
            },
            sessionsInterrupted: sessions.reduce(0) {
                $0 + (($1.resultStatus?.countsAsInterrupted ?? false) ? 1 : 0)
            },
            sessionsLinkedToOutcome: sessions.reduce(0) {
                $0 + (($1.weeklyOutcomeID != nil && $1.effectiveDuration != nil) ? 1 : 0)
            },
            sessionsWithCapturedInterruption: Set(
                interruptions.compactMap(\.focusSessionID).filter(sessionIDs.contains)
            ).count,
            supportDuration: support.duration,
            supportSessionCount: support.count,
            observedDuration: episodes.reduce(0) { $0 + $1.activeDuration }
        )
    }

    // MARK: - Ordering

    private static func newestFirst(_ lhs: Interruption, _ rhs: Interruption) -> Bool {
        lhs.timestamp == rhs.timestamp
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.timestamp > rhs.timestamp
    }

    private static func earliestFirst(_ lhs: Episode, _ rhs: Episode) -> Bool {
        lhs.start == rhs.start ? lhs.id.uuidString < rhs.id.uuidString : lhs.start < rhs.start
    }

    // MARK: - Breakdowns

    private static func timeByProject(
        sessions: [FocusSession],
        names: [UUID: String]
    ) -> [WeeklyReview.ProjectTime] {
        var durations: [UUID?: TimeInterval] = [:]
        var counts: [UUID?: Int] = [:]

        for session in sessions {
            guard let duration = session.effectiveDuration else { continue }
            durations[session.projectID, default: 0] += duration
            counts[session.projectID, default: 0] += 1
        }

        return durations.map { projectID, duration in
            let name =
                projectID
                .map { names[$0] ?? WeeklyReview.unnamedProjectName }
                ?? WeeklyReview.unfiledProjectName
            return WeeklyReview.ProjectTime(
                projectID: projectID,
                name: name,
                duration: duration,
                sessionCount: counts[projectID] ?? 0
            )
        }
        .sorted { lhs, rhs in
            lhs.duration == rhs.duration
                ? (lhs.name == rhs.name ? lhs.id < rhs.id : lhs.name < rhs.name)
                : lhs.duration > rhs.duration
        }
    }

    private static func timeByWorkType(
        _ plannedVsReactive: PlannedVsReactive
    ) -> [WeeklyReview.WorkTypeTime] {
        plannedVsReactive.durationByWorkType
            .map { WeeklyReview.WorkTypeTime(workType: $0.key, duration: $0.value) }
            .sorted { lhs, rhs in
                lhs.duration == rhs.duration
                    ? lhs.workType.rawValue < rhs.workType.rawValue
                    : lhs.duration > rhs.duration
            }
    }

    private static func timeByCategory(
        episodes: [Episode],
        categories: [String: AppCategory]
    ) -> [WeeklyReview.CategoryTime] {
        var durations: [AppCategory: TimeInterval] = [:]
        for episode in episodes {
            for app in episode.apps {
                let category = categories[app.bundleIdentifier] ?? .unknown
                durations[category, default: 0] += app.duration
            }
        }
        return durations
            .map { WeeklyReview.CategoryTime(category: $0.key, duration: $0.value) }
            .sorted { lhs, rhs in
                lhs.duration == rhs.duration
                    ? lhs.category.rawValue < rhs.category.rawValue
                    : lhs.duration > rhs.duration
            }
    }

    private static func days(
        week: DateInterval,
        calendar: Calendar,
        sessions: [FocusSession],
        episodes: [Episode],
        interruptions: [Interruption]
    ) -> [WeeklyReview.Day] {
        CalendarWindows(calendar: calendar).daysIn(week: week).map { day in
            let daySessions = sessions.filter { StoreOrdering.contains($0.startedAt, in: day) }
            let dayEpisodes = episodes.filter { StoreOrdering.contains($0.start, in: day) }
            let dayInterruptions = interruptions.filter {
                StoreOrdering.contains($0.timestamp, in: day)
            }
            return WeeklyReview.Day(
                start: day.start,
                trackedDuration: daySessions.reduce(0) { $0 + ($1.effectiveDuration ?? 0) },
                sessionCount: daySessions.count,
                episodeCount: dayEpisodes.count,
                // Blocks are already the unit a person recognises as "a thing I was doing", so the
                // moves between them are the switches. One block is no switch, which is why an
                // otherwise-unbroken day reads as zero rather than as one.
                contextSwitches: max(0, dayEpisodes.count - 1),
                interruptionCount: dayInterruptions.count
            )
        }
    }

    private static func outcomeProgress(
        outcomes: WeeklyOutcomeSet,
        sessions: [FocusSession],
        accomplishments: [Accomplishment],
        trackedDuration: TimeInterval
    ) -> [WeeklyReview.OutcomeProgress] {
        outcomes.all.map { outcome in
            var duration: TimeInterval = 0
            var sessionCount = 0
            for session in sessions where session.weeklyOutcomeID == outcome.id {
                guard let effective = session.effectiveDuration else { continue }
                duration += effective
                sessionCount += 1
            }
            let share = trackedDuration > 0 ? min(1, max(0, duration / trackedDuration)) : nil
            return WeeklyReview.OutcomeProgress(
                outcomeID: outcome.id,
                title: outcome.title,
                priority: outcome.priority,
                status: outcome.status,
                selfReportedProgress: outcome.progress,
                sessionCount: sessionCount,
                trackedDuration: duration,
                shareOfTrackedTime: share,
                accomplishmentCount: accomplishments.reduce(0) {
                    $0 + ($1.weeklyOutcomeID == outcome.id ? 1 : 0)
                }
            )
        }
    }

    private static func interruptionSources(
        _ interruptions: [Interruption]
    ) -> [WeeklyReview.InterruptionSourceCount] {
        var counts: [InterruptionSource: Int] = [:]
        for interruption in interruptions {
            counts[interruption.source, default: 0] += 1
        }
        return counts
            .map { WeeklyReview.InterruptionSourceCount(source: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                lhs.count == rhs.count
                    ? lhs.source.rawValue < rhs.source.rawValue
                    : lhs.count > rhs.count
            }
    }

    /// Time spent on other people's work.
    ///
    /// A session qualifies through its work type, or because it produced an accomplishment of a kind
    /// that only exists on someone else's behalf. Membership is decided per session, so a code-review
    /// session that also recorded an unblock is counted once.
    private static func support(
        sessions: [FocusSession],
        accomplishments: [Accomplishment]
    ) -> (duration: TimeInterval, count: Int) {
        let supportingSessionIDs = Set(
            accomplishments.filter(\.type.isSupportWork).compactMap(\.focusSessionID)
        )
        var duration: TimeInterval = 0
        var count = 0
        for session in sessions {
            guard let effective = session.effectiveDuration else { continue }
            let isSupport =
                session.workType == .codeReview
                || session.workType == .management
                || session.workType == .incident
                || supportingSessionIDs.contains(session.id)
            guard isSupport else { continue }
            duration += effective
            count += 1
        }
        return (duration, count)
    }
}
