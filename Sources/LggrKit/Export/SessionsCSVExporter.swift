import Foundation

/// RFC 4180 field and row encoding.
///
/// This is the part of the export feature most likely to be got wrong quietly. An intended outcome is
/// free text a user typed into a text field, and the three characters that break CSV — a comma, a
/// double quote, a newline — are all characters people type. A row that loses its shape does not throw:
/// it opens in a spreadsheet with the columns shifted by one from that row down, and whoever reads it
/// believes the numbers.
public enum CSVEscaping {

    /// Characters that force a field to be quoted.
    ///
    /// Leading and trailing spaces are included because some readers strip unquoted whitespace, and a
    /// summary that was written with a trailing space should come back with one.
    private static func needsQuoting(_ value: String) -> Bool {
        if value.contains(",") || value.contains("\"") || value.contains("\n")
            || value.contains("\r") {
            return true
        }
        return value.hasPrefix(" ") || value.hasSuffix(" ")
    }

    /// One field, quoted and escaped if it has to be.
    ///
    /// A newline inside a quoted field is left as a newline: RFC 4180 allows it, every spreadsheet
    /// reads it, and rewriting the user's paragraph into one line would be an exporter editing their
    /// words to make its own job easier.
    ///
    /// - Parameter neutralizeFormulaPrefix: prefixes a leading `=`, `+`, `@`, tab or carriage return
    ///   with an apostrophe, which spreadsheets consume as *treat this cell as text*. A CSV export is
    ///   the file most likely to be mailed onwards, and a cell beginning `=` is executed on open. A
    ///   leading `-` is deliberately **not** covered: it opens a great many ordinary sentences, and
    ///   corrupting all of those to defend against the few that are arithmetic is the worse trade.
    public static func field(_ value: String, neutralizeFormulaPrefix: Bool = true) -> String {
        var body = value
        if neutralizeFormulaPrefix, let first = body.first,
            first == "=" || first == "+" || first == "@" || first == "\t" || first == "\r" {
            body = "'" + body
        }
        guard needsQuoting(body) else { return body }
        return "\"" + body.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func row(
        _ fields: [String],
        neutralizeFormulaPrefixes: Bool = true
    ) -> String {
        fields
            .map { field($0, neutralizeFormulaPrefix: neutralizeFormulaPrefixes) }
            .joined(separator: ",")
    }
}

/// Everything the sessions CSV is rendered from.
public struct SessionsCSVInput: Sendable {

    /// `nil` exports exactly what was handed in.
    public var interval: DateInterval?
    public var sessions: [FocusSession]
    public var projectNames: [UUID: String]
    public var outcomeTitles: [UUID: String]

    public init(
        interval: DateInterval? = nil,
        sessions: [FocusSession] = [],
        projectNames: [UUID: String] = [:],
        outcomeTitles: [UUID: String] = [:]
    ) {
        self.interval = interval
        self.sessions = sessions
        self.projectNames = projectNames
        self.outcomeTitles = outcomeTitles
    }
}

/// Raw focus sessions as CSV — the export for someone who wants to do their own arithmetic.
///
/// ## What is in it, and what cannot be
///
/// A session row is the session: its times, its project, its type, its result, and the four free-text
/// fields the user wrote. There is no application column, no category column and no bundle identifier,
/// because a session record does not hold any — so this file cannot leak a private application, an
/// excluded one, or a window title, no matter what is on the timeline beside it.
///
/// The session identifier *is* included. This is the raw export; a row that cannot be joined back to
/// anything is not raw, and a UUID is not sensitive.
///
/// ## Choices worth stating
///
/// - **CRLF line endings**, per RFC 4180. It is what Excel expects, and it makes a lone `\n` inside a
///   quoted field unambiguously part of the field rather than possibly the end of the row.
/// - **Durations in minutes, one decimal place**, formatted without a locale so the separator is a
///   period on a machine that writes `1,4`. A running session's duration is **empty**, not zero: it has
///   not finished, and a zero would be a measurement that never happened.
/// - **Chronological order**, oldest first, unlike the newest-first order the app displays. A
///   spreadsheet is read downwards and charted left to right.
public enum SessionsCSVExporter {

    public struct Options: Sendable {
        public var includeHeader: Bool
        public var neutralizeFormulaPrefixes: Bool
        public var lineTerminator: String

        public init(
            includeHeader: Bool = true,
            neutralizeFormulaPrefixes: Bool = true,
            lineTerminator: String = "\r\n"
        ) {
            self.includeHeader = includeHeader
            self.neutralizeFormulaPrefixes = neutralizeFormulaPrefixes
            self.lineTerminator = lineTerminator
        }
    }

    public static let columns: [String] = [
        "Started",
        "Ended",
        "Duration (minutes)",
        "Paused (minutes)",
        "Project",
        "Weekly outcome",
        "Work type",
        "Origin",
        "Result",
        "Intended outcome",
        "Summary",
        "Tangible result",
        "Blocker",
        "Next step",
        "Interruptions",
        "Session ID",
    ]

    public static func render(
        _ input: SessionsCSVInput,
        formatter: ExportFormatter = ExportFormatter(),
        options: Options = Options()
    ) -> String {
        let sessions = input.sessions
            .filter { session in
                guard let interval = input.interval else { return true }
                return StoreOrdering.contains(session.startedAt, in: interval)
            }
            .sorted(by: earliestFirst)

        var lines: [String] = []
        if options.includeHeader {
            lines.append(
                CSVEscaping.row(columns, neutralizeFormulaPrefixes: false)
            )
        }
        for session in sessions {
            lines.append(
                CSVEscaping.row(
                    fields(for: session, input: input, formatter: formatter),
                    neutralizeFormulaPrefixes: options.neutralizeFormulaPrefixes
                )
            )
        }

        guard !lines.isEmpty else { return "" }
        return lines.joined(separator: options.lineTerminator) + options.lineTerminator
    }

    // MARK: - Rows

    private static func fields(
        for session: FocusSession,
        input: SessionsCSVInput,
        formatter: ExportFormatter
    ) -> [String] {
        [
            formatter.timestamp(session.startedAt),
            session.endedAt.map(formatter.timestamp) ?? "",
            session.effectiveDuration.map(minutes) ?? "",
            minutes(session.pausedDuration),
            session.projectID.flatMap { input.projectNames[$0] } ?? "",
            session.weeklyOutcomeID.flatMap { input.outcomeTitles[$0] } ?? "",
            session.workType.displayName,
            PlannedVsReactive.origin(of: session).displayName,
            session.resultStatus?.displayName ?? "",
            session.intendedOutcome,
            session.resultSummary ?? "",
            session.tangibleResult ?? "",
            session.blocker ?? "",
            session.nextStep ?? "",
            "\(session.interruptionCount)",
            session.id.uuidString,
        ]
    }

    /// Ascending, so the file reads the way a spreadsheet is scrolled.
    private static func earliestFirst(_ lhs: FocusSession, _ rhs: FocusSession) -> Bool {
        lhs.startedAt == rhs.startedAt
            ? lhs.id.uuidString < rhs.id.uuidString
            : lhs.startedAt < rhs.startedAt
    }

    /// `String(format:)` with no locale is POSIX, so the decimal separator stays a period.
    private static func minutes(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "" }
        return String(format: "%.1f", max(0, duration) / 60)
    }
}
