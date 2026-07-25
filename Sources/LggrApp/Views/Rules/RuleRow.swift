import AppKit
import LggrKit
import SwiftUI

// One row of the rules list, and the sentence every surface reads it out of.
// See docs/_design/04-screens.md §4.6.
//
// The sentence lives here rather than inside the row so that the list, the editor's preview and the
// correction sheet all describe a rule with the same words. Three descriptions of one rule is three
// chances for the screen to say something the engine does not do.

// MARK: - Naming an application

/// Turns a bundle identifier into the name on the user's Dock.
///
/// A rule's `matchValue` for an application is `com.tinyspeck.slackmacgap`, and that is the honest
/// thing to store — a display name changes with the system language and with a rename. It is not the
/// honest thing to *lead a row with*, so the row shows "Slack" and keeps the identifier on the
/// second line, where it can still be read and copied.
///
/// Cached because a list redraws on hover and `urlForApplication` touches Launch Services. A miss is
/// cached too: an application the user has uninstalled must not be looked up on every frame.
@MainActor
enum ApplicationNaming {

    private static var cache: [String: String] = [:]

    /// The application's own name, or `nil` when nothing on this Mac claims that identifier.
    static func displayName(forBundleIdentifier identifier: String) -> String? {
        let key = identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if let cached = cache[key] { return cached.isEmpty ? nil : cached }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else {
            cache[key] = ""
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path)
        cache[key] = name
        return name.isEmpty ? nil : name
    }
}

// MARK: - The sentence

/// A rule read left to right as `When … → Then …`, which is the hierarchy §4.6 asks for.
///
/// Every string a user reads about a rule comes from here.
@MainActor
enum RuleSentence {

    /// The condition: `Application Slack`, `Window title contains “Pull request”`.
    static func condition(_ rule: ClassificationRule, projects: [Project]) -> String {
        "\(rule.matchType.displayName) \(subject(rule, projects: projects))"
    }

    /// What the condition is about, on its own — the part a person recognises.
    ///
    /// Quoted for a window-title rule and only for that one, because it is the only match value that
    /// is a fragment of prose rather than an identifier, and *contains ideal* reads very differently
    /// from *contains “ideal”*.
    static func subject(_ rule: ClassificationRule, projects: [Project]) -> String {
        let value = rule.matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch rule.matchType {
        case .application:
            return ApplicationNaming.displayName(forBundleIdentifier: value) ?? value
        case .windowTitleContains:
            return "\u{201C}\(value)\u{201D}"
        case .browserDomain:
            return value
        case .project:
            return projectName(for: value, in: projects) ?? "a project that no longer exists"
        case .workType:
            return WorkType(rawValue: value)?.displayName ?? value
        }
    }

    /// The outcome: the category, and the project the rule files the activity under when it does.
    static func outcome(_ rule: ClassificationRule, projects: [Project]) -> String {
        guard
            let projectID = rule.projectID,
            let project = projects.first(where: { $0.id == projectID })
        else { return rule.category.displayName }
        return "\(rule.category.displayName) · \(project.name)"
    }

    /// The demoted second line: scope, then priority. §4.6's `Any project · Any work type ·
    /// Priority 20`.
    ///
    /// The identifier is appended when the row is showing a friendlier name than the one on disk, so
    /// nothing about what is actually stored is hidden behind a nicety.
    ///
    /// `demoted` is set for the built-in section, where §4.6 draws no second line at all. Eleven rows
    /// each restating *Any project · Any work type · Priority 0* is eleven rows of the same sentence:
    /// the default scope says nothing, so on those rows only the facts that differ are printed, and
    /// most of them print nothing.
    static func scope(
        _ rule: ClassificationRule,
        projects: [Project],
        demoted: Bool = false
    ) -> String {
        var parts: [String] = []

        if let projectID = rule.projectID,
            let project = projects.first(where: { $0.id == projectID })
        {
            parts.append("\(project.name) only")
        } else if demoted || rule.matchType == .project || rule.matchType == .workType {
            // Either the condition already names the project or the work type — repeating "Any
            // project" beside it would contradict the line above — or this is a shipped row, where the
            // default scope is the only scope there has ever been.
        } else {
            parts.append("Any project · Any work type")
        }

        if rule.matchType == .application {
            let value = rule.matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ApplicationNaming.displayName(forBundleIdentifier: value) != nil {
                parts.append(value)
            }
        }

        if !demoted || rule.priority != ClassificationRule.shippedPriority {
            parts.append("Priority \(rule.priority)")
        }

        return parts.joined(separator: " · ")
    }

    /// One line for VoiceOver and for the editor's preview: the whole rule as a sentence.
    static func full(_ rule: ClassificationRule, projects: [Project]) -> String {
        "When \(condition(rule, projects: projects).lowercasedFirstWordPreservingNames), "
            + "call it \(outcome(rule, projects: projects))."
    }

    private static func projectName(for value: String, in projects: [Project]) -> String? {
        projects.first { $0.id.uuidString.lowercased() == value.lowercased() }?.name
    }
}

extension String {
    /// Lowercases the first character only, so `Application Slack` reads as `application Slack`
    /// inside a longer sentence without touching the name that follows.
    fileprivate var lowercasedFirstWordPreservingNames: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

// MARK: - Row

/// One rule.
///
/// ```
/// ☑  Browser domain github.com          →  Code review
///    Any project · Any work type · Priority 10          [ ↑ ][ ↓ ]
/// ```
///
/// The row's controls brighten on hover and are always present, never conjured. Two reasons, and the
/// second is the stronger one: a row whose controls appear under the pointer is a row that moves, and
/// a control that only exists while the mouse is over it cannot be reached by anyone using the
/// keyboard. Lggr claims full keyboard operation (`04-screens.md` §7.2), so every action on this row
/// is in the tab order at all times and simply reads as quieter until it is wanted.
///
/// **On the drag handle §4.6 describes.** It is not here, and its absence is deliberate: a grip that
/// cannot be dragged is exactly the dead control the build rules forbid, and drag reordering cannot be
/// verified on a machine without Xcode. Two arrows do the same job, are keyboard-reachable, and say
/// what they do — including saying it when they are at the end of the list and cannot do it.
@MainActor
struct RuleRow: View {

    let rule: ClassificationRule
    let projects: [Project]
    /// Built-in rows are demoted and cannot be edited in place (`04-screens.md` §4.6).
    let isBuiltIn: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Toggle(isOn: Binding(get: { rule.isEnabled }, set: { onToggle($0) })) {
                Text(isEnabledLabel)
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(isEnabledLabel)

            VStack(alignment: .leading, spacing: Space.xxs) {
                sentence
                if !scopeLine.isEmpty {
                    Text(scopeLine)
                        .font(Type.secondary)
                        .foregroundStyle(
                            isBuiltIn ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: Space.m)

            rowControls
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        // Two dimmings compose here and the first version multiplied them: a built-in rule already
        // draws its sentence at `.secondary` (about 55% alpha), so `0.55` on top of it landed the one
        // switched-off built-in rule at roughly 30% — the Rules snapshot showed it as a grey smear in
        // light mode and a barely-there line in dark. A rule the user turned off is the rule they are
        // most likely to come back and turn on, so it has to stay readable. This is quiet, not absent.
        .opacity(rule.isEnabled ? 1 : 0.75)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        // The fill bleeds past the text column on both sides so the text stays aligned with the
        // heading above it. A row that indents on hover is a row that moves.
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(RuleSentence.full(rule, projects: projects))
        .accessibilityValue(spokenDetail)
    }

    // MARK: Pieces

    /// `Window title contains “Pull request”  →  Code review`.
    ///
    /// The arrow is a glyph rather than a hyphen pair, and it is hidden from VoiceOver, which reads
    /// the whole rule as a sentence from `accessibilityLabel` instead.
    private var sentence: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(RuleSentence.condition(rule, projects: projects))
                .font(Type.rowTitle)
                .foregroundStyle(isBuiltIn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: "\u{2192}")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Image(systemName: rule.category.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(RuleSentence.outcome(rule, projects: projects))
                    .font(Type.rowTitle)
                    .foregroundStyle(isBuiltIn ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
            }
        }
    }

    /// Edit, then the two arrows. Disabled at the ends of the list with the reason on hover rather
    /// than removed: a control that comes and goes as the pointer travels down a list is harder to hit
    /// than one that is simply not available.
    private var rowControls: some View {
        HStack(spacing: Space.xs) {
            rowButton(
                symbol: Icon.edit,
                label: isBuiltIn ? "Make it your own" : "Edit rule",
                help: isBuiltIn
                    ? "Make a rule of your own from this one"
                    : "Edit this rule",
                isEnabled: true,
                action: onEdit
            )

            if !isBuiltIn {
                rowButton(
                    symbol: "chevron.up",
                    label: "Move up",
                    help: canMoveUp ? "Move up — this rule wins over the one above" : "Already first",
                    isEnabled: canMoveUp,
                    action: onMoveUp
                )
                rowButton(
                    symbol: "chevron.down",
                    label: "Move down",
                    help: canMoveDown
                        ? "Move down — the rule below wins over this one"
                        : "Already last",
                    isEnabled: canMoveDown,
                    action: onMoveDown
                )
            }
        }
        .opacity(isHovered ? 1 : 0.4)
        .lggrAnimation(Motion.tap, value: isHovered)
    }

    private func rowButton(
        symbol: String,
        label: String,
        help: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .imageScale(.small)
                .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary))
                .frame(width: Layout.symbolColumnWidth, height: Layout.symbolColumnWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(label)
    }

    private var isEnabledLabel: String { rule.isEnabled ? "On" : "Off" }

    private var scopeLine: String {
        RuleSentence.scope(rule, projects: projects, demoted: isBuiltIn)
    }

    /// VoiceOver gets the whole scope, including the parts the shipped rows leave unprinted: reading a
    /// list aloud has no visual repetition to avoid, and "Priority 0" is the answer to the question a
    /// screen-reader user is most likely to be asking.
    private var spokenDetail: String {
        var parts = [RuleSentence.scope(rule, projects: projects)]
        if isBuiltIn { parts.append("Built in") }
        parts.append(rule.isEnabled ? "On" : "Off")
        return parts.joined(separator: ", ")
    }
}
