import Foundation

/// One sentence about the week, and the evidence it rests on.
///
/// The register is fixed and narrow: a statement of something Lggr measured, with the numbers in it.
/// "Interruptions from messages were recorded in 42% of deep-work sessions" is an observation.
/// "You were distracted" is a verdict, and this type has no way to express one — there is no
/// severity, no sentiment, no rating and no recommendation field, because a field that exists gets
/// filled in.
public struct WeeklyObservation: Identifiable, Hashable, Sendable {

    /// What the sentence is about. Also the identity: each kind is generated at most once, so a week
    /// cannot produce four variations on the same point.
    ///
    /// Declaration order is the order observations are presented in. It is editorial, chosen once,
    /// and deliberately not a ranking — nothing in the data decides which sentence comes first.
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case plannedSplit
        case primaryOutcomeShare
        case supportWork
        case timeOfDay
        case interruptionSource
        case deepWorkInterruption
        case contextSwitchPeak

        public var id: String { rawValue }
    }

    public let kind: Kind
    /// The sentence, as shown.
    public let text: String
    /// What had to be true of the data for the sentence to be written at all. Shown next to the
    /// observation so a claim can be argued with rather than merely believed.
    public let evidence: String

    public var id: String { kind.rawValue }

    public init(kind: Kind, text: String, evidence: String) {
        self.kind = kind
        self.text = text
        self.evidence = evidence
    }
}

/// The minimum evidence each observation needs before it is allowed to exist.
///
/// These are the most important numbers in this file. A week with three sessions cannot support a
/// claim about when your longest sessions happen, and a generator that emits one anyway is not
/// slightly wrong — it has invented a pattern out of noise and attached the user's name to it. Every
/// threshold below is a refusal, and a sparse week producing no observations at all is the correct
/// result rather than a gap to be filled.
///
/// They are settable so a test can drive a generator at a fixture size, not so the app can lower the
/// bar at runtime.
public struct EvidenceThresholds: Hashable, Sendable {

    /// Below this many finished sessions, the week is not a description of how time was spent.
    public var minimumFinishedSessions: Int
    public var minimumTrackedDuration: TimeInterval

    // Time of day
    public var minimumSessionsForTimeOfDay: Int
    /// How many of the longest sessions have to agree before "your longest sessions" means anything.
    public var minimumLongSessions: Int
    /// The longest sessions must fall on at least this many separate days, so one long Monday cannot
    /// become a claim about the week.
    public var minimumDaysForTimeOfDay: Int
    /// A boundary later than this makes the sentence vacuous: nearly every session starts before
    /// 17:00, so saying so states only that the user works during the day.
    public var latestTimeOfDayBoundaryHour: Int

    // Outcomes
    /// A share-of-time figure for an outcome measures how diligently sessions were linked to it until
    /// enough of them are. Below this, 18% is a fact about data entry.
    public var minimumSessionsLinkedToOutcome: Int

    // Support work
    public var minimumSupportDuration: TimeInterval
    public var minimumSupportSessions: Int

    // Interruptions
    public var minimumInterruptions: Int
    /// The leading source must carry at least this share, and beat the runner-up outright.
    public var leadingSourceShare: Double
    public var minimumDeepWorkSessions: Int
    public var minimumInterruptedDeepWorkSessions: Int

    // Context switches
    public var minimumActiveDaysForSwitches: Int
    /// Below a certain volume, a "peak day" is one meeting more than usual.
    public var minimumAverageContextSwitches: Double
    public var contextSwitchPeakMultiple: Double

    public init(
        minimumFinishedSessions: Int = 6,
        minimumTrackedDuration: TimeInterval = 3 * 3600,
        minimumSessionsForTimeOfDay: Int = 8,
        minimumLongSessions: Int = 3,
        minimumDaysForTimeOfDay: Int = 2,
        latestTimeOfDayBoundaryHour: Int = 13,
        minimumSessionsLinkedToOutcome: Int = 3,
        minimumSupportDuration: TimeInterval = 3600,
        minimumSupportSessions: Int = 3,
        minimumInterruptions: Int = 6,
        leadingSourceShare: Double = 0.4,
        minimumDeepWorkSessions: Int = 5,
        minimumInterruptedDeepWorkSessions: Int = 3,
        minimumActiveDaysForSwitches: Int = 4,
        minimumAverageContextSwitches: Double = 8,
        contextSwitchPeakMultiple: Double = 1.75
    ) {
        self.minimumFinishedSessions = minimumFinishedSessions
        self.minimumTrackedDuration = minimumTrackedDuration
        self.minimumSessionsForTimeOfDay = minimumSessionsForTimeOfDay
        self.minimumLongSessions = minimumLongSessions
        self.minimumDaysForTimeOfDay = minimumDaysForTimeOfDay
        self.latestTimeOfDayBoundaryHour = latestTimeOfDayBoundaryHour
        self.minimumSessionsLinkedToOutcome = minimumSessionsLinkedToOutcome
        self.minimumSupportDuration = minimumSupportDuration
        self.minimumSupportSessions = minimumSupportSessions
        self.minimumInterruptions = minimumInterruptions
        self.leadingSourceShare = leadingSourceShare
        self.minimumDeepWorkSessions = minimumDeepWorkSessions
        self.minimumInterruptedDeepWorkSessions = minimumInterruptedDeepWorkSessions
        self.minimumActiveDaysForSwitches = minimumActiveDaysForSwitches
        self.minimumAverageContextSwitches = minimumAverageContextSwitches
        self.contextSwitchPeakMultiple = contextSwitchPeakMultiple
    }
}

/// Writes the week's observations.
///
/// Pure: a function of a `WeeklyReview` and a set of thresholds. No clock, no store, no randomness,
/// so the same week produces the same sentences every time it is opened.
///
/// Three rules hold for every generator here, and a new one that cannot satisfy all three does not
/// belong in this file:
///
/// 1. **Evidence.** Each generator states the minimum data it needs and returns `nil` below it.
///    Silence is a supported outcome.
/// 2. **Neutrality.** The sentence reports what was measured. No adverb that grades it — no *only*,
///    no *just*, no *still*. No comparison to anyone else, no streak, no target, no score.
/// 3. **Specificity.** Every sentence carries the numbers it is derived from, so the user can check
///    it against their own memory of the week and disagree.
public enum InsightGenerator {

    /// The week's observations, in `WeeklyObservation.Kind` declaration order.
    ///
    /// - Parameter limit: caps how many are returned. `nil` returns all that the evidence supports.
    public static func observations(
        for review: WeeklyReview,
        thresholds: EvidenceThresholds = EvidenceThresholds(),
        limit: Int? = nil
    ) -> [WeeklyObservation] {
        let generated: [WeeklyObservation] = WeeklyObservation.Kind.allCases.compactMap { kind in
            switch kind {
            case .plannedSplit: plannedSplit(review, thresholds)
            case .primaryOutcomeShare: primaryOutcomeShare(review, thresholds)
            case .supportWork: supportWork(review, thresholds)
            case .timeOfDay: timeOfDay(review, thresholds)
            case .interruptionSource: interruptionSource(review, thresholds)
            case .deepWorkInterruption: deepWorkInterruption(review, thresholds)
            case .contextSwitchPeak: contextSwitchPeak(review, thresholds)
            }
        }
        guard let limit else { return generated }
        return limit > 0 ? Array(generated.prefix(limit)) : []
    }

    // MARK: - Planned versus reactive

    private static func plannedSplit(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        let split = review.plannedVsReactive
        guard split.sessionCount >= thresholds.minimumFinishedSessions,
            split.trackedDuration >= thresholds.minimumTrackedDuration,
            let reactiveShare = split.reactiveShare
        else { return nil }

        return WeeklyObservation(
            kind: .plannedSplit,
            text:
                "Work that arrived rather than being chosen accounted for "
                + "\(percent(reactiveShare))% of tracked time, across "
                + "\(split.reactiveSessionCount) of \(split.sessionCount) sessions.",
            evidence:
                "\(split.sessionCount) finished sessions, "
                + "\(DurationFormatting.compact(split.trackedDuration)) tracked."
        )
    }

    // MARK: - Primary outcome

    private static func primaryOutcomeShare(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        guard let progress = review.primaryOutcomeProgress,
            let share = progress.shareOfTrackedTime,
            review.trackedDuration >= thresholds.minimumTrackedDuration,
            review.sessionsLinkedToOutcome >= thresholds.minimumSessionsLinkedToOutcome
        else { return nil }

        return WeeklyObservation(
            kind: .primaryOutcomeShare,
            text:
                "The primary weekly outcome received \(percent(share))% of tracked time, "
                + "across \(progress.sessionCount) "
                + "\(progress.sessionCount == 1 ? "session" : "sessions").",
            evidence:
                "\(review.sessionsLinkedToOutcome) of \(review.finishedSessionCount) finished "
                + "sessions carried a weekly outcome."
        )
    }

    // MARK: - Support work

    private static func supportWork(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        guard review.supportDuration >= thresholds.minimumSupportDuration,
            review.supportSessionCount >= thresholds.minimumSupportSessions
        else { return nil }

        return WeeklyObservation(
            kind: .supportWork,
            text:
                "Code review, management and incident work accounted for "
                + "\(DurationFormatting.prose(review.supportDuration)) across "
                + "\(review.supportSessionCount) sessions.",
            evidence:
                "Sessions typed as code review, management or incident, plus sessions that recorded "
                + "a review, unblock or incident resolution."
        )
    }

    // MARK: - Time of day

    /// "Your 5 longest sessions all started before 11:30."
    ///
    /// The boundary is derived from the data rather than chosen: it is the first half-hour mark after
    /// the latest of those sessions began, so the sentence is true by construction. Four separate
    /// guards stand in front of it, and the last one is the one that matters — at least one session
    /// outside the group must have started at or after the boundary. Without it the sentence is true
    /// of a week where everything started before 11:30, where it says nothing about length at all.
    private static func timeOfDay(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        let finished = review.finishedSessions
        guard finished.count >= thresholds.minimumSessionsForTimeOfDay else { return nil }

        let byLength = finished.sorted { lhs, rhs in
            let left = lhs.effectiveDuration ?? 0
            let right = rhs.effectiveDuration ?? 0
            return left == right ? lhs.id.uuidString < rhs.id.uuidString : left > right
        }
        let quartile = max(thresholds.minimumLongSessions, finished.count / 4)
        let longest = Array(byLength.prefix(quartile))
        guard longest.count >= thresholds.minimumLongSessions else { return nil }

        let calendar = review.calendar
        let distinctDays = Set(longest.map { calendar.startOfDay(for: $0.startedAt) })
        guard distinctDays.count >= thresholds.minimumDaysForTimeOfDay else { return nil }

        var latestMinuteOfDay = -1
        for session in longest {
            let components = calendar.dateComponents([.hour, .minute], from: session.startedAt)
            guard let hour = components.hour, let minute = components.minute else { return nil }
            latestMinuteOfDay = max(latestMinuteOfDay, hour * 60 + minute)
        }
        guard latestMinuteOfDay >= 0 else { return nil }

        let boundaryMinuteOfDay = nextHalfHour(after: latestMinuteOfDay)
        guard boundaryMinuteOfDay / 60 <= thresholds.latestTimeOfDayBoundaryHour else { return nil }

        let longestIDs = Set(longest.map(\.id))
        let hasLaterShortSession = finished.contains { session in
            guard !longestIDs.contains(session.id) else { return false }
            let components = calendar.dateComponents([.hour, .minute], from: session.startedAt)
            guard let hour = components.hour, let minute = components.minute else { return false }
            return hour * 60 + minute >= boundaryMinuteOfDay
        }
        guard hasLaterShortSession else { return nil }

        return WeeklyObservation(
            kind: .timeOfDay,
            text:
                "Your \(longest.count) longest sessions all started before "
                + "\(clockText(boundaryMinuteOfDay)).",
            evidence:
                "The longest \(longest.count) of \(finished.count) finished sessions, spread across "
                + "\(distinctDays.count) days."
        )
    }

    // MARK: - Interruptions

    private static func interruptionSource(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        let total = review.interruptionCount
        guard total >= thresholds.minimumInterruptions,
            let leader = review.interruptionSources.first
        else { return nil }

        let runnerUp = review.interruptionSources.dropFirst().first?.count ?? 0
        guard leader.count > runnerUp,
            Double(leader.count) / Double(total) >= thresholds.leadingSourceShare
        else { return nil }

        return WeeklyObservation(
            kind: .interruptionSource,
            text:
                "\(leader.count) of \(total) captured interruptions came from "
                + "\(leader.source.sentencePhrase).",
            evidence:
                "\(total) interruptions captured across "
                + "\(review.interruptionSources.count) sources."
        )
    }

    /// "Interruptions from messages were recorded in 43% of deep-work sessions (3 of 7)."
    ///
    /// Counted per session rather than per interruption: four notes captured during one afternoon are
    /// one interrupted session, and counting them as four would let a single bad hour describe a week.
    private static func deepWorkInterruption(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        let deepWork = review.deepWorkSessions
        guard deepWork.count >= thresholds.minimumDeepWorkSessions else { return nil }

        let deepWorkIDs = Set(deepWork.map(\.id))
        var sessionsBySource: [InterruptionSource: Set<UUID>] = [:]
        for interruption in review.interruptions {
            guard let sessionID = interruption.focusSessionID,
                deepWorkIDs.contains(sessionID)
            else { continue }
            sessionsBySource[interruption.source, default: []].insert(sessionID)
        }

        var ranked: [(source: InterruptionSource, count: Int)] = []
        for (source, sessionIDs) in sessionsBySource {
            ranked.append((source: source, count: sessionIDs.count))
        }
        ranked.sort { lhs, rhs in
            lhs.count == rhs.count
                ? lhs.source.rawValue < rhs.source.rawValue
                : lhs.count > rhs.count
        }
        guard let leader = ranked.first,
            leader.count >= thresholds.minimumInterruptedDeepWorkSessions,
            leader.count > (ranked.dropFirst().first?.count ?? 0)
        else { return nil }

        let share = Double(leader.count) / Double(deepWork.count)
        return WeeklyObservation(
            kind: .deepWorkInterruption,
            text:
                "Interruptions from \(leader.source.sentencePhrase) were recorded in "
                + "\(percent(share))% of deep-work sessions (\(leader.count) of \(deepWork.count)).",
            evidence:
                "\(deepWork.count) finished deep-work sessions, "
                + "\(leader.count) with an interruption from \(leader.source.sentencePhrase)."
        )
    }

    // MARK: - Context switches

    private static func contextSwitchPeak(
        _ review: WeeklyReview,
        _ thresholds: EvidenceThresholds
    ) -> WeeklyObservation? {
        let active = review.activeDays
        guard active.count >= thresholds.minimumActiveDaysForSwitches,
            let average = review.averageContextSwitchesPerActiveDay,
            average >= thresholds.minimumAverageContextSwitches
        else { return nil }

        let ranked = active.sorted { lhs, rhs in
            lhs.contextSwitches == rhs.contextSwitches
                ? lhs.start < rhs.start
                : lhs.contextSwitches > rhs.contextSwitches
        }
        guard let peak = ranked.first,
            peak.contextSwitches > (ranked.dropFirst().first?.contextSwitches ?? 0),
            Double(peak.contextSwitches) >= average * thresholds.contextSwitchPeakMultiple,
            let name = weekdayName(for: peak.start, in: review.calendar)
        else { return nil }

        return WeeklyObservation(
            kind: .contextSwitchPeak,
            text:
                "\(name) had \(peak.contextSwitches) context switches; the daily average was "
                + "\(Int(average.rounded())).",
            evidence: "\(active.count) days with recorded activity."
        )
    }

    // MARK: - Formatting

    private static func percent(_ share: Double) -> Int {
        guard share.isFinite else { return 0 }
        return Int((min(1, max(0, share)) * 100).rounded())
    }

    /// The first :00 or :30 strictly after `minuteOfDay`, so "before" is true of every session in the
    /// group including one that began exactly on the hour.
    private static func nextHalfHour(after minuteOfDay: Int) -> Int {
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60
        return minute < 30 ? hour * 60 + 30 : (hour + 1) * 60
    }

    /// 24-hour, zero-padded, formatted without a locale so the sentence does not change shape between
    /// two machines looking at the same week.
    private static func clockText(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", (minuteOfDay / 60) % 24, minuteOfDay % 60)
    }

    private static func weekdayName(for date: Date, in calendar: Calendar) -> String? {
        guard let weekday = calendar.dateComponents([.weekday], from: date).weekday else {
            return nil
        }
        let symbols = calendar.weekdaySymbols
        let index = weekday - 1
        guard symbols.indices.contains(index) else { return nil }
        return symbols[index]
    }
}
