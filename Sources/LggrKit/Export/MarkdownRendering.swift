import Foundation

// Everything the four exporters share.
//
// An export is the one artefact of this app that leaves the machine. It gets pasted into a 1:1
// document, a promotion packet, a standup note — read by someone who will never see the app and
// cannot check it against the timeline. Three properties follow from that, and every type in this
// file exists to hold one of them:
//
// 1. **Deterministic.** No clock, no locale, no dictionary iteration order, no `DateFormatter`. The
//    same week renders to the same bytes on any machine, which is what makes an exact-output test
//    possible at all.
// 2. **Structurally safe.** Text the user typed cannot become a heading, a table row, a link or a
//    code fence in the document it lands in.
// 3. **Arithmetically honest.** Percentages that are shown side by side add up to 100, because a
//    reader will add them.

// MARK: - Text

/// Text on its way into a Markdown document.
public enum MarkdownText {

    /// Characters that change a document's structure rather than its words.
    ///
    /// `<` and `>` are here because Markdown passes raw HTML through: an outcome titled
    /// `<img src=x onerror=...>` would otherwise become a tag in whatever renders the export.
    private static let structural: Set<Character> = ["\\", "`", "*", "_", "[", "]", "|", "<", ">"]

    /// Everything the user typed passes through here before it reaches a line of Markdown.
    ///
    /// A weekly outcome is free text with a text field's manners: it can hold a newline, a pipe, a
    /// backtick, a leading hyphen. Left alone, one of those turns a list item into a table, a heading
    /// or a fenced block, and the document a person pastes into a performance review is malformed in a
    /// way they will not notice until someone else reads it.
    ///
    /// Characters that only mean something at the start of a line are *not* escaped here. Where a
    /// string begins a line is a fact about the document, not about the string, so `MarkdownDocument`
    /// decides it — which is what keeps a hyphenated phrase in the middle of a bullet free of stray
    /// backslashes while a leading `##` at the front of one still gets escaped.
    public static func inline(_ text: String) -> String {
        let flat = flattened(text)
        guard !flat.isEmpty else { return "" }
        var escaped = ""
        escaped.reserveCapacity(flat.count + 4)
        for character in flat {
            if structural.contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }

    /// `nil` for text that is absent or holds nothing but whitespace, so a caller can drop the line
    /// rather than print an empty one.
    public static func optional(_ text: String?) -> String? {
        guard let text else { return nil }
        let rendered = inline(text)
        return rendered.isEmpty ? nil : rendered
    }

    /// One line, with runs of whitespace collapsed to single spaces and the ends trimmed.
    ///
    /// Newlines are the important case: a block-level construct in Markdown is defined by what starts
    /// a line, so flattening is what stops the second line of a description from being parsed as
    /// anything at all.
    public static func flattened(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.unicodeScalars.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let isBreak =
                CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            if isBreak {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Escapes a character that only means something at the start of a line.
    ///
    /// Applied by `MarkdownDocument` to text that genuinely begins a line, and only there: a
    /// mid-sentence hyphen stays a hyphen.
    /// Every marker below needs a space or the end of the line after it to mean anything, and the check
    /// enforces that rather than escaping on the first character alone. The difference is not
    /// pedantry: `5.1 hours invested` and `#1 priority` are ordinary prose that a looser rule turns
    /// into `\5.1 hours invested`, and a visible backslash in a document somebody is about to paste
    /// into a promotion packet is a defect of exactly the kind this file exists to prevent.
    static func escapingLeader(_ text: String) -> String {
        guard let first = text.first else { return text }

        func opensABlock(after offset: Int) -> Bool {
            guard offset < text.count else { return true }
            let character = text[text.index(text.startIndex, offsetBy: offset)]
            return character == " " || character == "\t"
        }

        // ATX heading: one to six hashes, then a break.
        if first == "#" {
            let hashes = text.prefix { $0 == "#" }.count
            if hashes <= 6, opensABlock(after: hashes) { return "\\" + text }
        }

        // Bullet list. A leading `*` normally arrives already escaped by `inline`; it is covered here
        // for callers passing literal text.
        if first == "-" || first == "+" || first == "*", opensABlock(after: 1) {
            return "\\" + text
        }

        // Ordered list: digits, then "." or ")", then a break. A date like 2024-01-15 has neither.
        let digits = text.prefix { $0.isNumber }.count
        if digits > 0, digits < text.count {
            let marker = text[text.index(text.startIndex, offsetBy: digits)]
            if marker == "." || marker == ")", opensABlock(after: digits + 1) {
                return "\\" + text
            }
        }
        return text
    }
}

// MARK: - Document

/// A Markdown document assembled block by block.
///
/// The reason this is a type rather than string concatenation at each call site: whitespace between
/// blocks is the single easiest thing to get subtly wrong, and "no stray whitespace" is a
/// requirement of the artefact. Blocks are joined by exactly one blank line and the document ends
/// with exactly one newline, once, here — so no exporter can drift.
///
/// Empty content is dropped rather than rendered as an empty heading or a bullet with nothing after
/// it. A section with no items does not appear at all, which is why a quiet day produces a short
/// document instead of a scaffold of empty headings.
public struct MarkdownDocument: Sendable {

    /// A bullet, optionally with its own indented bullets underneath.
    public struct ListItem: Sendable, Hashable {
        public var text: String
        public var children: [String]

        public init(_ text: String, children: [String] = []) {
            self.text = text
            self.children = children
        }
    }

    private var blocks: [String] = []

    public init() {}

    public var isEmpty: Bool { blocks.isEmpty }

    public mutating func heading(_ text: String, level: Int = 2) {
        let flat = MarkdownText.flattened(text)
        guard !flat.isEmpty else { return }
        blocks.append(String(repeating: "#", count: min(6, max(1, level))) + " " + flat)
    }

    /// A block of prose. This is the one place where text genuinely begins a line, so it is also the
    /// one place a leading `#` or `-` has to be escaped.
    public mutating func paragraph(_ text: String) {
        let flat = MarkdownText.flattened(text)
        guard !flat.isEmpty else { return }
        blocks.append(MarkdownText.escapingLeader(flat))
    }

    /// A bullet's content is itself a block container, so `- ## Shipped it` renders a heading *inside*
    /// the list item. Line-leader escaping therefore applies here exactly as it does to a paragraph.
    public mutating func list(_ items: [ListItem]) {
        var lines: [String] = []
        for item in items {
            let text = MarkdownText.flattened(item.text)
            guard !text.isEmpty else { continue }
            lines.append("- " + MarkdownText.escapingLeader(text))
            for child in item.children {
                let childText = MarkdownText.flattened(child)
                guard !childText.isEmpty else { continue }
                lines.append("  - " + MarkdownText.escapingLeader(childText))
            }
        }
        guard !lines.isEmpty else { return }
        blocks.append(lines.joined(separator: "\n"))
    }

    public mutating func list(_ items: [String]) {
        list(items.map { ListItem($0) })
    }

    /// A heading plus its bullets, or nothing at all when there are no bullets.
    public mutating func section(_ title: String, level: Int = 2, items: [ListItem]) {
        guard items.contains(where: { !MarkdownText.flattened($0.text).isEmpty }) else { return }
        heading(title, level: level)
        list(items)
    }

    public mutating func section(_ title: String, level: Int = 2, items: [String]) {
        section(title, level: level, items: items.map { ListItem($0) })
    }

    /// Short rows only. Wide tables are the one Markdown construct that reads worse than the list it
    /// replaced, so callers keep the column count low.
    public mutating func table(headers: [String], rows: [[String]]) {
        guard !headers.isEmpty, !rows.isEmpty else { return }
        let columns = headers.map(MarkdownText.flattened)
        var lines = ["| " + columns.joined(separator: " | ") + " |"]
        lines.append("| " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows {
            let cells = columns.indices.map { index in
                index < row.count ? MarkdownText.flattened(row[index]) : ""
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        blocks.append(lines.joined(separator: "\n"))
    }

    /// The document. Empty in, empty out — not a lone newline.
    public func rendered() -> String {
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }
}

// MARK: - Percentages

/// Integer percentages for a set of durations shown together.
public enum PercentageAllocation {

    /// Percentages that sum to exactly 100 whenever any weight is positive.
    ///
    /// Rounding each share independently is what produces the familiar 99% and 101% columns, and a
    /// reader who adds up a five-line time allocation and gets 101 has found a bug in the app's
    /// arithmetic as far as they are concerned. So the shares are floored and the leftover points are
    /// handed out by largest fractional remainder — the standard apportionment method — with ties
    /// broken by position, so the result is a function of the input and nothing else.
    ///
    /// A zero or non-finite weight gets 0% and never receives a leftover point: a project with no time
    /// in it must not appear to have had 1%.
    public static func percentages(of weights: [TimeInterval]) -> [Int] {
        let positive = weights.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = positive.reduce(0, +)
        guard total > 0 else { return weights.map { _ in 0 } }

        let exact = positive.map { $0 / total * 100 }
        var result = exact.map { Int($0.rounded(.down)) }
        var leftover = 100 - result.reduce(0, +)

        let candidates = exact.indices
            .filter { positive[$0] > 0 }
            .sorted { lhs, rhs in
                let left = exact[lhs] - Double(result[lhs])
                let right = exact[rhs] - Double(result[rhs])
                return left == right ? lhs < rhs : left > right
            }
        guard !candidates.isEmpty else { return result }

        var cursor = 0
        while leftover > 0 {
            result[candidates[cursor % candidates.count]] += 1
            leftover -= 1
            cursor += 1
        }
        return result
    }
}

// MARK: - Counting accomplishments

/// How a count of accomplishments reads in a sentence.
///
/// The noun phrases live in the export layer rather than on `AccomplishmentType`, because they are
/// prose for a document rather than a label for a control, and because "5 person unblocked" is the
/// kind of thing that reaches a promotion packet and undermines everything around it.
public enum AccomplishmentPhrasing {

    public static func phrase(_ type: AccomplishmentType, count: Int) -> String {
        "\(count) \(noun(type, plural: count != 1))"
    }

    public static func noun(_ type: AccomplishmentType, plural: Bool) -> String {
        switch type {
        case .featureCompleted: plural ? "features completed" : "feature completed"
        case .pullRequestOpened: plural ? "pull requests opened" : "pull request opened"
        case .pullRequestReviewed: plural ? "pull requests reviewed" : "pull request reviewed"
        case .decisionMade: plural ? "decisions made" : "decision made"
        case .personUnblocked: plural ? "people unblocked" : "person unblocked"
        case .incidentResolved: plural ? "incidents resolved" : "incident resolved"
        case .customerIssueResolved:
            plural ? "customer issues resolved" : "customer issue resolved"
        case .documentWritten: plural ? "documents written" : "document written"
        case .riskIdentified: plural ? "risks identified" : "risk identified"
        case .workDeprioritized: plural ? "items deprioritized" : "item deprioritized"
        case .other: plural ? "other accomplishments" : "other accomplishment"
        }
    }

    /// Counts by type in `AccomplishmentType.allCases` order, types with none omitted.
    ///
    /// Declaration order rather than descending count: ordering by count would rank the kinds of work
    /// against each other, and nothing in this product ranks one kind of contribution above another.
    public static func counts(_ accomplishments: [Accomplishment]) -> [(AccomplishmentType, Int)] {
        var totals: [AccomplishmentType: Int] = [:]
        for accomplishment in accomplishments {
            totals[accomplishment.type, default: 0] += 1
        }
        return AccomplishmentType.allCases.compactMap { type in
            guard let count = totals[type], count > 0 else { return nil }
            return (type, count)
        }
    }
}

// MARK: - Dates

/// Every date, time and range string in an export.
///
/// `DateFormatter` is absent on purpose. Its output depends on the process locale, so the same week
/// exported on two machines produces different bytes, an exact-output test becomes untestable, and a
/// user on a Hebrew or Japanese locale gets a document whose date order does not match its English
/// headings. Month and weekday names here are a frozen English table for the same reason: the rest of
/// the document is English, so its dates should be too.
///
/// The calendar is used for arithmetic and for the time zone only — never for its symbols.
public struct ExportFormatter: Sendable {

    public let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Fixed to UTC. Use where a document must not vary with the machine that wrote it.
    public static let utc: ExportFormatter = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return ExportFormatter(calendar: calendar)
    }()

    private static let monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]

    /// Indexed by `Calendar`'s 1-based weekday, so index 0 is Sunday.
    private static let weekdayNames = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    private func parts(_ date: Date) -> DateComponents {
        calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .weekday],
            from: date
        )
    }

    /// `2024-01-15`. Sorts correctly as text and cannot be read as a US or European date by mistake.
    public func isoDate(_ date: Date) -> String {
        let components = parts(date)
        return String(
            format: "%04ld-%02ld-%02ld",
            components.year ?? 0,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    /// `09:04`. 24-hour, so it needs no AM/PM and no locale.
    public func time(_ date: Date) -> String {
        let components = parts(date)
        return String(format: "%02ld:%02ld", components.hour ?? 0, components.minute ?? 0)
    }

    /// `09:04–09:58`, with an en dash — the correct character for a range.
    public func timeRange(from start: Date, to end: Date) -> String {
        "\(time(start))–\(time(end))"
    }

    /// `Monday`, or an empty string if the calendar cannot say.
    public func weekdayName(_ date: Date) -> String {
        guard let weekday = parts(date).weekday, Self.weekdayNames.indices.contains(weekday - 1)
        else { return "" }
        return Self.weekdayNames[weekday - 1]
    }

    /// `Monday, 15 January 2024`.
    public func longDate(_ date: Date) -> String {
        let components = parts(date)
        let month = Self.monthNames.indices.contains((components.month ?? 1) - 1)
            ? Self.monthNames[(components.month ?? 1) - 1]
            : ""
        let day = components.day ?? 1
        let year = components.year ?? 0
        let tail = "\(day) \(month) \(year)"
        let name = weekdayName(date)
        return name.isEmpty ? tail : "\(name), \(tail)"
    }

    /// `2024-01-15 to 2024-01-21`.
    ///
    /// The end is the interval's last *day*, not its exclusive bound: a week runs to the following
    /// Monday at 00:00, and a heading that says the week ended on the 22nd is wrong by a day.
    public func dateRange(_ interval: DateInterval) -> String {
        let lastMoment = interval.end > interval.start
            ? interval.end.addingTimeInterval(-1)
            : interval.start
        let first = isoDate(interval.start)
        let last = isoDate(lastMoment)
        return first == last ? first : "\(first) to \(last)"
    }

    /// `2024-01-15T09:00:00+0000` — ISO 8601 with a numeric offset, for the CSV.
    ///
    /// The offset is included because a spreadsheet of timestamps with no zone is unreadable after a
    /// trip abroad or a daylight-saving change, both of which this data outlives.
    public func timestamp(_ date: Date) -> String {
        let components = parts(date)
        let offset = calendar.timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        return String(
            format: "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld%@%02ld%02ld",
            components.year ?? 0,
            components.month ?? 1,
            components.day ?? 1,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            sign,
            magnitude / 3600,
            (magnitude % 3600) / 60
        )
    }
}
