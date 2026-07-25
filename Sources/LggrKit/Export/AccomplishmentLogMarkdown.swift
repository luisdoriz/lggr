import Foundation

/// Everything the accomplishment log is rendered from.
public struct AccomplishmentLogInput: Sendable {

    /// The window the log covers, used for the subtitle and for filtering. `nil` renders exactly what
    /// was handed in, which is what "export everything" means.
    public var interval: DateInterval?
    public var accomplishments: [Accomplishment]
    public var projectNames: [UUID: String]
    public var outcomeTitles: [UUID: String]

    public init(
        interval: DateInterval? = nil,
        accomplishments: [Accomplishment] = [],
        projectNames: [UUID: String] = [:],
        outcomeTitles: [UUID: String] = [:]
    ) {
        self.interval = interval
        self.accomplishments = accomplishments
        self.projectNames = projectNames
        self.outcomeTitles = outcomeTitles
    }
}

/// The accomplishment log, as Markdown.
///
/// `SPEC.md` §10: *"The user should be able to open the app on Friday and immediately see evidence of
/// what they delivered."* This is the exportable form of that, and the one export written for an
/// audience of one — the person who has to argue for themselves in a review cycle and cannot remember
/// March.
///
/// Every line in it was typed by the user. Nothing here is inferred: `INTELLIGENCE.md` §3.6 killed
/// generated accomplishments outright, because a fabricated line in a performance-review artefact
/// costs credibility that cannot be recovered and the user will not know it happened. So this file
/// groups, counts and formats. It never asserts.
public enum AccomplishmentLogMarkdown {

    /// How the entries are grouped under headings.
    public enum Grouping: String, Sendable, CaseIterable, Identifiable {
        /// By day, most recent first. The log as a log.
        case day
        /// By kind of accomplishment, in `AccomplishmentType`'s declaration order.
        case type
        /// By project, alphabetically, with unfiled entries last.
        case project

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .day: "Day"
            case .type: "Type"
            case .project: "Project"
            }
        }
    }

    public struct Options: Sendable {
        public var grouping: Grouping
        /// The user's own longer note under each entry, as an indented bullet.
        public var includeDetails: Bool
        /// The counts by kind at the top of the document.
        public var includeSummary: Bool

        public init(
            grouping: Grouping = .day,
            includeDetails: Bool = true,
            includeSummary: Bool = true
        ) {
            self.grouping = grouping
            self.includeDetails = includeDetails
            self.includeSummary = includeSummary
        }
    }

    public static func render(
        _ input: AccomplishmentLogInput,
        formatter: ExportFormatter = ExportFormatter(),
        options: Options = Options()
    ) -> String {
        let entries = input.accomplishments
            .filter { accomplishment in
                guard let interval = input.interval else { return true }
                return StoreOrdering.contains(accomplishment.timestamp, in: interval)
            }
            .sorted(by: StoreOrdering.newestFirst)

        var document = MarkdownDocument()
        document.heading("Accomplishment log", level: 1)
        if let interval = input.interval {
            document.paragraph(formatter.dateRange(interval))
        }

        guard !entries.isEmpty else {
            document.paragraph("No accomplishments were recorded.")
            return document.rendered()
        }

        if options.includeSummary {
            var items = [
                "\(entries.count) \(entries.count == 1 ? "accomplishment" : "accomplishments")"
            ]
            items += AccomplishmentPhrasing.counts(entries).map {
                AccomplishmentPhrasing.phrase($0.0, count: $0.1)
            }
            document.list(items)
        }

        for group in groups(entries, grouping: options.grouping, input: input, formatter: formatter) {
            document.heading(group.heading)
            document.list(
                group.entries.map {
                    item($0, grouping: options.grouping, input: input, formatter: formatter, options: options)
                }
            )
        }

        return document.rendered()
    }

    // MARK: - Grouping

    private struct Group {
        let heading: String
        let entries: [Accomplishment]
    }

    private static func groups(
        _ entries: [Accomplishment],
        grouping: Grouping,
        input: AccomplishmentLogInput,
        formatter: ExportFormatter
    ) -> [Group] {
        switch grouping {
        case .day:
            // Keyed by the rendered date rather than by a truncated `Date`, so the grouping uses the
            // same day boundary the heading claims — the formatter's calendar, not the machine's.
            var order: [String] = []
            var buckets: [String: [Accomplishment]] = [:]
            for entry in entries {
                let key = formatter.isoDate(entry.timestamp)
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(entry)
            }
            return order.compactMap { key in
                guard let bucket = buckets[key], let first = bucket.first else { return nil }
                return Group(heading: formatter.longDate(first.timestamp), entries: bucket)
            }

        case .type:
            // Declaration order, not descending count: ranking the kinds would rank the work.
            return AccomplishmentType.allCases.compactMap { type in
                let bucket = entries.filter { $0.type == type }
                guard !bucket.isEmpty else { return nil }
                return Group(heading: type.displayName, entries: bucket)
            }

        case .project:
            var buckets: [UUID?: [Accomplishment]] = [:]
            for entry in entries {
                buckets[entry.projectID, default: []].append(entry)
            }
            let projectIDs: [UUID] = buckets.keys.compactMap { $0 }
            var named: [(id: UUID, name: String)] = projectIDs.map { id in
                (id: id, name: projectName(id, input: input))
            }
            named.sort { lhs, rhs in
                lhs.name == rhs.name
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.name < rhs.name
            }
            var result: [Group] = named.compactMap { entry in
                guard let bucket = buckets[entry.id] else { return nil }
                return Group(heading: entry.name, entries: bucket)
            }
            if let unfiled = buckets[nil] {
                result.append(
                    Group(heading: WeeklyReview.unfiledProjectName, entries: unfiled)
                )
            }
            return result
        }
    }

    private static func projectName(_ id: UUID, input: AccomplishmentLogInput) -> String {
        MarkdownText.optional(input.projectNames[id]) ?? "Unnamed project"
    }

    // MARK: - Entries

    /// The fields that are not already the heading. A day heading needs the kind; a type heading needs
    /// the date; neither needs to repeat itself.
    private static func item(
        _ accomplishment: Accomplishment,
        grouping: Grouping,
        input: AccomplishmentLogInput,
        formatter: ExportFormatter,
        options: Options
    ) -> MarkdownDocument.ListItem {
        var fields: [String] = []
        if grouping != .day {
            fields.append(formatter.isoDate(accomplishment.timestamp))
        }
        fields.append(MarkdownText.optional(accomplishment.title) ?? "Untitled")
        if grouping != .type {
            fields.append(accomplishment.type.displayName)
        }
        if grouping != .project, let projectID = accomplishment.projectID {
            fields.append(projectName(projectID, input: input))
        }
        if let outcomeID = accomplishment.weeklyOutcomeID,
            let title = MarkdownText.optional(input.outcomeTitles[outcomeID]) {
            fields.append(title)
        }

        var children: [String] = []
        if options.includeDetails, let details = MarkdownText.optional(accomplishment.details) {
            children.append(details)
        }
        return MarkdownDocument.ListItem(fields.joined(separator: " · "), children: children)
    }
}
