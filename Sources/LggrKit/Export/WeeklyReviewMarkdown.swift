import Foundation

/// The weekly review, as Markdown.
///
/// The structure is `SPEC.md`'s Export section: a primary outcome with its session count, hours and
/// accomplishment counts, then time allocation as percentages, then accomplishments, then
/// observations. The additional sections answer the rest of §9's questions — planned versus reactive,
/// sessions completed and interrupted, context switches per day, support work, interruption sources —
/// in that reading order, so the document opens with what was achieved and ends with what to look at.
///
/// ## The document this produces is the product
///
/// It is pasted into a 1:1, a promotion packet, a standup note, and read by someone who cannot check
/// it. Three consequences:
///
/// - **Nothing here is derived from an observed application.** Time allocation is by project and by
///   work type, both of which come from session records — fields the user filled in. Time by
///   application category, which `SPEC.md` §9 asks for, stays on the weekly review *screen* and out of
///   the exported file. The screen can be corrected; a pasted document cannot, and an aggregate
///   category share is the one number in the review that carries a contribution from whatever was
///   frontmost — including, if a stale interval survives a newly added exclusion, from an application
///   the user has said must not be recorded. Leaving the section out makes this exporter structurally
///   incapable of carrying it, rather than careful about it.
/// - **No per-person evidence.** Support work reads `5h 12m across 4 sessions`; who was unblocked is
///   an aggregate count. `INTELLIGENCE.md` §3.7 cut the shareable per-person document on purpose, and
///   this is where it would otherwise reappear.
/// - **No verdict.** Every number here is a measurement, and the observations come from
///   `InsightGenerator`, which will not write a sentence its evidence thresholds do not support. There
///   is no score, no grade, no target and no comparison — `INTELLIGENCE.md` §3.4.
public enum WeeklyReviewMarkdown {

    public struct Options: Sendable {
        /// How many rows a time-allocation list shows before the tail is folded into *Other*. A
        /// twenty-line breakdown of a week is data, not a summary.
        public var allocationLimit: Int
        /// `nil` lists every accomplishment of the week.
        public var accomplishmentLimit: Int?
        /// `nil` includes every observation the evidence supports.
        public var observationLimit: Int?
        public var includeDayTable: Bool

        public init(
            allocationLimit: Int = 6,
            accomplishmentLimit: Int? = nil,
            observationLimit: Int? = nil,
            includeDayTable: Bool = true
        ) {
            self.allocationLimit = max(1, allocationLimit)
            self.accomplishmentLimit = accomplishmentLimit
            self.observationLimit = observationLimit
            self.includeDayTable = includeDayTable
        }
    }

    /// - Parameter observations: injected so a caller can render the same sentences the review sheet
    ///   showed. `nil` generates them, which is deterministic — `InsightGenerator` is a pure function
    ///   of the review.
    public static func render(
        _ review: WeeklyReview,
        observations: [WeeklyObservation]? = nil,
        formatter: ExportFormatter = ExportFormatter(),
        options: Options = Options()
    ) -> String {
        var document = MarkdownDocument()
        document.heading("Weekly Work Review", level: 1)
        document.paragraph(formatter.dateRange(review.week))

        guard !review.isEmpty else {
            document.paragraph(
                "No sessions, accomplishments or tracked activity were recorded for this week."
            )
            return document.rendered()
        }

        primaryOutcome(&document, review)
        otherOutcomes(&document, review)
        allocation(&document, review, options)
        plannedVersusReactive(&document, review)
        sessions(&document, review)
        days(&document, review, formatter, options)
        supportWork(&document, review)
        interruptions(&document, review)
        accomplishments(&document, review, options)
        observationSection(&document, review, observations, options)

        return document.rendered()
    }

    // MARK: - Primary outcome

    private static func primaryOutcome(_ document: inout MarkdownDocument, _ review: WeeklyReview) {
        guard let progress = review.primaryOutcomeProgress,
            let title = MarkdownText.optional(progress.title)
        else { return }

        document.heading("Primary outcome")
        document.paragraph(title)

        var items: [String] = []
        if progress.sessionCount > 0 {
            items.append(
                "\(progress.sessionCount) focus "
                    + "\(progress.sessionCount == 1 ? "session" : "sessions")"
            )
        }
        if progress.trackedDuration > 0 {
            items.append("\(DurationFormatting.prose(progress.trackedDuration)) invested")
        }
        if let share = progress.shareOfTrackedTime {
            items.append("\(percent(share))% of tracked time")
        }
        let linked = review.accomplishments.filter { $0.weeklyOutcomeID == progress.outcomeID }
        for (type, count) in AccomplishmentPhrasing.counts(linked) {
            items.append(AccomplishmentPhrasing.phrase(type, count: count))
        }
        items.append("Status: \(progress.status.displayName)")
        document.list(items)
    }

    /// Secondary and operational outcomes, in the order `WeeklyOutcomeSet` seats them.
    private static func otherOutcomes(_ document: inout MarkdownDocument, _ review: WeeklyReview) {
        let primaryID = review.outcomes.primary?.id
        let items = review.outcomeProgress
            .filter { $0.outcomeID != primaryID }
            .compactMap { progress -> String? in
                guard let title = MarkdownText.optional(progress.title) else { return nil }
                var fields = [title, progress.priority.displayName, progress.status.displayName]
                if progress.sessionCount > 0 {
                    fields.append(
                        "\(progress.sessionCount) "
                            + "\(progress.sessionCount == 1 ? "session" : "sessions")"
                    )
                }
                if progress.trackedDuration > 0 {
                    fields.append(DurationFormatting.compact(progress.trackedDuration))
                }
                return fields.joined(separator: " · ")
            }
        document.section("Other outcomes", items: items)
    }

    // MARK: - Time allocation

    private static func allocation(
        _ document: inout MarkdownDocument,
        _ review: WeeklyReview,
        _ options: Options
    ) {
        let projects = rows(
            review.timeByProject.map { Slice(name: MarkdownText.inline($0.name), duration: $0.duration) },
            limit: options.allocationLimit
        )
        let workTypes = rows(
            review.timeByWorkType.map {
                Slice(name: $0.workType.displayName, duration: $0.duration)
            },
            limit: options.allocationLimit
        )
        guard !projects.isEmpty || !workTypes.isEmpty else { return }

        document.heading("Time allocation")
        document.section("By project", level: 3, items: projects)
        document.section("By work type", level: 3, items: workTypes)
    }

    /// One line of a time-allocation list, before it knows its percentage.
    private struct Slice {
        let name: String
        let duration: TimeInterval
    }

    /// `Billing: 45% (4h 30m)`, longest first, everything past `limit` summed into *Other*.
    ///
    /// The percentages are apportioned across the whole set before the tail is folded, so the visible
    /// rows still add up to 100 and *Other* is the true remainder rather than a rounding scrap.
    private static func rows(_ entries: [Slice], limit: Int) -> [String] {
        let present = entries.filter { $0.duration > 0 && !$0.name.isEmpty }
        guard !present.isEmpty else { return [] }

        let shares = PercentageAllocation.percentages(of: present.map(\.duration))
        var items = present.indices.prefix(limit).map { index in
            "\(present[index].name): \(shares[index])% "
                + "(\(DurationFormatting.compact(present[index].duration)))"
        }

        let tail = present.indices.dropFirst(limit)
        if !tail.isEmpty {
            let share = tail.reduce(0) { $0 + shares[$1] }
            let duration = tail.reduce(0.0) { $0 + present[$1].duration }
            items.append("Other: \(share)% (\(DurationFormatting.compact(duration)))")
        }
        return items
    }

    // MARK: - Planned versus reactive

    private static func plannedVersusReactive(
        _ document: inout MarkdownDocument,
        _ review: WeeklyReview
    ) {
        let split = review.plannedVsReactive
        guard split.trackedDuration > 0 else { return }

        let origins = WorkOrigin.allCases.map { (origin: $0, duration: split.duration(for: $0)) }
        let shares = PercentageAllocation.percentages(of: origins.map(\.duration))
        let items = origins.indices.compactMap { index -> String? in
            let origin = origins[index]
            guard origin.duration > 0 else { return nil }
            let count = split.sessionCount(for: origin.origin)
            return "\(origin.origin.displayName): \(shares[index])% "
                + "(\(DurationFormatting.compact(origin.duration)), "
                + "\(count) \(count == 1 ? "session" : "sessions"))"
        }
        document.section("Planned versus reactive", items: items)
    }

    // MARK: - Sessions

    private static func sessions(_ document: inout MarkdownDocument, _ review: WeeklyReview) {
        guard review.finishedSessionCount > 0 else { return }
        var items = [
            "\(review.finishedSessionCount) finished "
                + "\(review.finishedSessionCount == 1 ? "session" : "sessions")",
            "\(DurationFormatting.compact(review.trackedDuration)) tracked",
        ]
        if review.sessionsCompleted > 0 {
            items.append("\(review.sessionsCompleted) reported as completed")
        }
        if review.sessionsInterrupted > 0 {
            items.append("\(review.sessionsInterrupted) reported as interrupted")
        }
        if review.sessionsWithCapturedInterruption > 0 {
            items.append(
                "\(review.sessionsWithCapturedInterruption) recorded an interruption while running"
            )
        }
        document.section("Focus sessions", items: items)
    }

    // MARK: - Days

    private static func days(
        _ document: inout MarkdownDocument,
        _ review: WeeklyReview,
        _ formatter: ExportFormatter,
        _ options: Options
    ) {
        guard options.includeDayTable else { return }
        let active = review.activeDays
        guard !active.isEmpty else { return }

        document.heading("By day")
        document.table(
            headers: ["Day", "Tracked", "Sessions", "Context switches"],
            rows: active.map { day in
                [
                    formatter.weekdayName(day.start),
                    DurationFormatting.compact(day.trackedDuration),
                    "\(day.sessionCount)",
                    "\(day.contextSwitches)",
                ]
            }
        )
    }

    // MARK: - Support work

    private static func supportWork(_ document: inout MarkdownDocument, _ review: WeeklyReview) {
        var items: [String] = []
        if review.supportDuration > 0, review.supportSessionCount > 0 {
            items.append(
                "\(DurationFormatting.compact(review.supportDuration)) across "
                    + "\(review.supportSessionCount) "
                    + "\(review.supportSessionCount == 1 ? "session" : "sessions") "
                    + "of code review, management and incident work"
            )
        }
        // Aggregate only. Who was unblocked stays in the app — `INTELLIGENCE.md` §3.7.
        if review.peopleUnblockedCount > 0 {
            items.append(
                AccomplishmentPhrasing.phrase(.personUnblocked, count: review.peopleUnblockedCount)
            )
        }
        let reviewed = review.accomplishments.reduce(0) {
            $0 + ($1.type == .pullRequestReviewed ? 1 : 0)
        }
        if reviewed > 0 {
            items.append(AccomplishmentPhrasing.phrase(.pullRequestReviewed, count: reviewed))
        }
        document.section("Support work", items: items)
    }

    // MARK: - Interruptions

    private static func interruptions(_ document: inout MarkdownDocument, _ review: WeeklyReview) {
        let items = review.interruptionSources.map { "\($0.source.displayName): \($0.count)" }
        document.section("Interruption sources", items: items)
    }

    // MARK: - Accomplishments

    private static func accomplishments(
        _ document: inout MarkdownDocument,
        _ review: WeeklyReview,
        _ options: Options
    ) {
        let limit = options.accomplishmentLimit ?? review.accomplishments.count
        let items = review.mainAccomplishments(limit: limit)
            .compactMap { MarkdownText.optional($0.title) }
        document.section("Accomplishments", items: items)
    }

    // MARK: - Observations

    private static func observationSection(
        _ document: inout MarkdownDocument,
        _ review: WeeklyReview,
        _ supplied: [WeeklyObservation]?,
        _ options: Options
    ) {
        let all = supplied ?? InsightGenerator.observations(for: review)
        let limited = options.observationLimit.map { Array(all.prefix(max(0, $0))) } ?? all
        document.section("Observations", items: limited.map(\.text))
    }

    // MARK: - Formatting

    private static func percent(_ share: Double) -> Int {
        guard share.isFinite else { return 0 }
        return Int((min(1, max(0, share)) * 100).rounded())
    }
}
