import Foundation

/// Everything a day's export is rendered from.
///
/// Assembled by the caller, exactly like `WeeklyReviewInput`: the exporter has no store, no clock and
/// no calendar of its own, so a day exported from the file store, from SwiftData or from a fixture
/// renders identically.
public struct DailySummaryInput: Sendable {

    /// The day. Membership is half-open — `start <= timestamp < end` — so a session begun at midnight
    /// belongs to one day rather than to two (`DECISIONS.md` D2).
    public var day: DateInterval
    public var sessions: [FocusSession]
    public var accomplishments: [Accomplishment]
    /// Counted by source only. The description is the user's note about who interrupted them, and
    /// `INTELLIGENCE.md` §3.7 keeps evidence about other people inside the app.
    public var interruptions: [Interruption]
    /// The reconstructed day. Optional because a day before ambient capture existed has none, and an
    /// absent timeline is different from an empty one.
    public var timeline: DayTimeline?
    /// Resolved by the caller, which is the only thing that holds projects.
    public var projectNames: [UUID: String]

    public init(
        day: DateInterval,
        sessions: [FocusSession] = [],
        accomplishments: [Accomplishment] = [],
        interruptions: [Interruption] = [],
        timeline: DayTimeline? = nil,
        projectNames: [UUID: String] = [:]
    ) {
        self.day = day
        self.sessions = sessions
        self.accomplishments = accomplishments
        self.interruptions = interruptions
        self.timeline = timeline
        self.projectNames = projectNames
    }
}

/// The daily summary, as Markdown.
///
/// ## The only exporter that can name an application
///
/// The weekly review reports application time by *category*, the accomplishment log holds text the
/// user typed, and the CSV holds session fields. None of the three can name a program. This one can,
/// because a timeline row without its applications is not worth pasting anywhere — so the whole
/// privacy surface of the export feature is this file, and it takes a `PrivacyRedactor` for it.
///
/// Three rules, all enforced below rather than promised:
///
/// - **No bundle identifiers, ever.** `com.tinyspeck.slackmacgap` says nothing to a reader that
///   *Slack* does not, and `lggr.private` in a document that reaches a manager is a debug artefact.
/// - **An excluded application is not in the document at all** — not its name, and not its time.
///   Excluded means there was no record, and the export honours that even if a stale interval from
///   before the exclusion is handed to it.
/// - **A private application is *Private activity*.** Its time is real and stays visible, because a
///   two-hour hole nobody can explain makes the whole day untrustworthy. Its identity is gone.
///
/// ## What is deliberately absent
///
/// No longest unbroken stretch, no count or total of undeclared time, no fragmentation figure.
/// `INTELLIGENCE.md` §3.4 removed each of those from the product for the same reason: a daily maximum
/// is a high score, and a total that grows when you forget to press start is a scold. The timeline
/// lists the blocks and stops there.
public enum DailySummaryMarkdown {

    public struct Options: Sendable {
        /// Tangible result, blocker and next step as indented bullets under their session. The reason
        /// a standup note is worth pasting.
        public var includeSessionDetail: Bool
        public var includeTimeline: Bool
        /// Gaps shorter than this are not listed. A two-minute pause is not a thing that happened to
        /// somebody's day, and a timeline that reports it buries the ones that were.
        public var timelineGapFloor: TimeInterval

        public init(
            includeSessionDetail: Bool = true,
            includeTimeline: Bool = true,
            timelineGapFloor: TimeInterval = 5 * 60
        ) {
            self.includeSessionDetail = includeSessionDetail
            self.includeTimeline = includeTimeline
            self.timelineGapFloor = max(0, timelineGapFloor)
        }
    }

    public static func render(
        _ input: DailySummaryInput,
        formatter: ExportFormatter = ExportFormatter(),
        redactor: PrivacyRedactor = .permissive,
        options: Options = Options()
    ) -> String {
        let sessions = input.sessions
            .filter { StoreOrdering.contains($0.startedAt, in: input.day) }
            .sorted(by: earliestFirst)
        let accomplishments = input.accomplishments
            .filter { StoreOrdering.contains($0.timestamp, in: input.day) }
            .sorted(by: earliestFirst)
        let interruptions = input.interruptions
            .filter { StoreOrdering.contains($0.timestamp, in: input.day) }

        var document = MarkdownDocument()
        document.heading("Daily summary — \(formatter.longDate(input.day.start))", level: 1)

        let split = PlannedVsReactive(sessions: sessions)
        let timelineRows = options.includeTimeline
            ? timeline(input.timeline, formatter: formatter, redactor: redactor, options: options)
            : []

        if sessions.isEmpty, accomplishments.isEmpty, interruptions.isEmpty, timelineRows.isEmpty {
            document.paragraph("No sessions, accomplishments or tracked activity were recorded.")
            return document.rendered()
        }

        document.section("Summary", items: summary(sessions: sessions, split: split))
        document.section(
            "Focus sessions",
            items: sessionRows(
                sessions,
                projectNames: input.projectNames,
                formatter: formatter,
                options: options
            )
        )
        document.section("Time allocation", items: allocation(split))
        document.section(
            "Accomplishments",
            items: accomplishments.compactMap { MarkdownText.optional($0.title) }
        )
        document.section("Interruptions", items: interruptionRows(interruptions))
        document.section("Timeline", items: timelineRows)

        return document.rendered()
    }

    // MARK: - Ordering

    // Ascending, unlike the store's newest-first: a day is read forwards, and a summary whose first
    // line is the last thing that happened cannot be pasted into a standup note.
    private static func earliestFirst(_ lhs: FocusSession, _ rhs: FocusSession) -> Bool {
        lhs.startedAt == rhs.startedAt
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.startedAt < rhs.startedAt
    }

    private static func earliestFirst(_ lhs: Accomplishment, _ rhs: Accomplishment) -> Bool {
        lhs.timestamp == rhs.timestamp
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.timestamp < rhs.timestamp
    }

    // MARK: - Sections

    private static func summary(
        sessions: [FocusSession],
        split: PlannedVsReactive
    ) -> [String] {
        guard !sessions.isEmpty else { return [] }
        var items: [String] = []

        let finished = split.sessionCount
        let sessionWord = sessions.count == 1 ? "focus session" : "focus sessions"
        items.append(
            finished == sessions.count
                ? "\(sessions.count) \(sessionWord)"
                : "\(sessions.count) \(sessionWord), \(finished) finished"
        )

        guard split.trackedDuration > 0 else { return items }
        items.append("\(DurationFormatting.compact(split.trackedDuration)) tracked")
        // A split is only worth a line when there was something to split. A day of entirely planned
        // work does not need to be told it did no reactive work, and vice versa.
        if split.plannedDuration > 0, split.reactiveDuration > 0 {
            items.append(
                "\(DurationFormatting.compact(split.plannedDuration)) planned, "
                    + "\(DurationFormatting.compact(split.reactiveDuration)) arrived"
            )
        }
        return items
    }

    private static func sessionRows(
        _ sessions: [FocusSession],
        projectNames: [UUID: String],
        formatter: ExportFormatter,
        options: Options
    ) -> [MarkdownDocument.ListItem] {
        sessions.map { session in
            var fields: [String] = []

            if let endedAt = session.endedAt {
                fields.append(formatter.timeRange(from: session.startedAt, to: endedAt))
            } else {
                fields.append(formatter.time(session.startedAt))
            }
            if let outcome = MarkdownText.optional(session.intendedOutcome) {
                fields.append(outcome)
            }
            if let projectID = session.projectID,
                let name = MarkdownText.optional(projectNames[projectID]) {
                fields.append(name)
            }
            fields.append(session.workType.displayName)
            if let duration = session.effectiveDuration {
                fields.append(DurationFormatting.compact(duration))
            }
            if let status = session.resultStatus {
                fields.append(status.displayName)
            } else if !session.isFinished {
                fields.append("In progress")
            }

            var children: [String] = []
            if options.includeSessionDetail {
                if let result = MarkdownText.optional(session.tangibleResult) {
                    children.append("Result: \(result)")
                }
                if let blocker = MarkdownText.optional(session.blocker) {
                    children.append("Blocker: \(blocker)")
                }
                if let next = MarkdownText.optional(session.nextStep) {
                    children.append("Next: \(next)")
                }
            }

            return MarkdownDocument.ListItem(fields.joined(separator: " · "), children: children)
        }
    }

    /// Time by work type, as percentages that add up.
    private static func allocation(_ split: PlannedVsReactive) -> [String] {
        var entries: [(workType: WorkType, duration: TimeInterval)] = []
        for workType in WorkType.allCases {
            let duration = split.duration(for: workType)
            guard duration > 0 else { continue }
            entries.append((workType: workType, duration: duration))
        }
        entries.sort { lhs, rhs in
            lhs.duration == rhs.duration
                ? lhs.workType.rawValue < rhs.workType.rawValue
                : lhs.duration > rhs.duration
        }
        guard !entries.isEmpty else { return [] }

        let durations: [TimeInterval] = entries.map { $0.duration }
        let shares = PercentageAllocation.percentages(of: durations)
        return entries.indices.map { index in
            let name = entries[index].workType.displayName
            let length = DurationFormatting.compact(entries[index].duration)
            return "\(name): \(shares[index])% (\(length))"
        }
    }

    /// Counts by source. No descriptions: the note the user typed is usually about a named colleague.
    private static func interruptionRows(_ interruptions: [Interruption]) -> [String] {
        guard !interruptions.isEmpty else { return [] }
        var counts: [InterruptionSource: Int] = [:]
        for interruption in interruptions {
            counts[interruption.source, default: 0] += 1
        }
        return InterruptionSource.allCases.compactMap { source in
            guard let count = counts[source], count > 0 else { return nil }
            return "\(source.displayName): \(count)"
        }
    }

    // MARK: - Timeline

    private static func timeline(
        _ timeline: DayTimeline?,
        formatter: ExportFormatter,
        redactor: PrivacyRedactor,
        options: Options
    ) -> [String] {
        guard let timeline else { return [] }
        return timeline.entries.compactMap { entry in
            switch entry {
            case .episode(let episode):
                return row(for: episode, formatter: formatter, redactor: redactor)
            case .gap(let gap):
                guard gap.duration >= options.timelineGapFloor, gap.duration > 0 else { return nil }
                return "\(formatter.timeRange(from: gap.start, to: gap.end)) · "
                    + "\(gap.reason.displayName) · \(DurationFormatting.compact(gap.duration))"
            }
        }
    }

    /// `nil` when nothing in the block may be described — every application in it is excluded, so as
    /// far as this document is concerned the block did not happen.
    private static func row(
        for episode: Episode,
        formatter: ExportFormatter,
        redactor: PrivacyRedactor
    ) -> String? {
        let visible = episode.apps.filter {
            redactor.disposition(for: $0.bundleIdentifier) != .excluded
        }
        let duration = visible.reduce(0) { $0 + $1.duration }
        guard !visible.isEmpty, duration > 0 else { return nil }

        var fields = [formatter.timeRange(from: episode.start, to: episode.end)]

        // The stored label is used only when the user wrote it. Every other label was derived from
        // evidence this document is not allowed to repeat — an application roster that may include an
        // excluded app, or, once the title probe exists, an identifier read out of a window title.
        if episode.labelConfidence.isUserAuthored,
            let label = MarkdownText.optional(episode.label) {
            fields.append(label)
        }
        if let roster = roster(visible, redactor: redactor) {
            fields.append(roster)
        }
        fields.append(DurationFormatting.compact(duration))
        return fields.joined(separator: " · ")
    }

    /// Display names only, private applications collapsed to one *Private activity*, at most three
    /// names with the rest counted.
    private static func roster(
        _ apps: [Episode.AppShare],
        redactor: PrivacyRedactor
    ) -> String? {
        var names: [String] = []
        for app in apps {
            let name =
                redactor.disposition(for: app.bundleIdentifier) == .redacted
                ? PrivacyRedactor.privateDisplayName
                : MarkdownText.flattened(app.displayName)
            guard !name.isEmpty, !names.contains(name) else { continue }
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3)
        let hidden = names.count - shown.count
        let joined = shown.map { MarkdownText.inline($0) }.joined(separator: ", ")
        return hidden > 0 ? "\(joined) +\(hidden) more" : joined
    }
}
