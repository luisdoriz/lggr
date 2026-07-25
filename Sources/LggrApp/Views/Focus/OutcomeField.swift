import SwiftUI
import LggrKit

// The one required field in the product. See docs/_design/04-screens.md § 5.2.
//
// It is set at `Type.outcome` (17pt) while every other field on the panel is 13pt, because it is the
// only thing the user actually came here to type. Everything else on the panel already has a correct
// default; this does not, and never will — a prefilled intent is not an intent.

/// The intended-outcome field, with a `Recent` list of previously used outcomes.
///
/// Keyboard: `Return` starts the session — that *is* the five-second path — unless a suggestion is
/// highlighted, in which case `Return` accepts it and stays in the field. `↓`/`↑` move through the
/// suggestions, `Escape` closes them, and a second `Escape` cancels the panel.
@MainActor
public struct OutcomeField: View {

    @Binding private var text: String
    private let recentOutcomes: [String]
    @FocusState.Binding private var focus: StartPanelField?
    private let showsEmptyHint: Bool
    private let onSubmit: () -> Void
    private let onCancel: () -> Void

    /// The keyboard cursor inside the `Recent` list. `nil` means the user is typing, not browsing.
    @State private var highlighted: Int?
    /// Set by `Escape`; cleared by the next keystroke. Without it, `Escape` would have to choose
    /// between closing the list and cancelling the panel, and § 5.2 asks for both, in that order.
    @State private var suggestionsDismissed = false

    /// At most three. A suggestion list longer than a glance is slower than typing.
    private static let suggestionLimit = 3

    /// - Parameter showsEmptyHint: shown when a start was attempted with an empty outcome. The panel
    ///   owns it so that the hint appears for `⌘⏎` as well as for the button.
    public init(
        text: Binding<String>,
        recentOutcomes: [String],
        focus: FocusState<StartPanelField?>.Binding,
        showsEmptyHint: Bool,
        onSubmit: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._text = text
        self.recentOutcomes = recentOutcomes
        self._focus = focus
        self.showsEmptyHint = showsEmptyHint
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            field

            if showsEmptyHint {
                // No red, no icon, nothing shakes. The panel states the missing thing once and then
                // gets out of the way.
                Text("Add an outcome to start.")
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, Space.xxs)
                    .accessibilityAddTraits(.isStaticText)
            }

            if isShowingSuggestions {
                suggestionList
            }
        }
        .lggrAnimation(Motion.reveal, value: isShowingSuggestions)
        .lggrAnimation(Motion.settle, value: showsEmptyHint)
        .onExitCommand(perform: handleEscape)
    }

    // MARK: - The field

    private var field: some View {
        TextField("Finish the receipt deduplication PR", text: $text)
            .textFieldStyle(.plain)
            .font(Type.outcome)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Surface.sunken, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
            .focused($focus, equals: .outcome)
            .onSubmit(submit)
            .onKeyPress(.downArrow) { moveHighlight(by: 1) }
            .onKeyPress(.upArrow) { moveHighlight(by: -1) }
            .onChange(of: text) { _, _ in
                highlighted = nil
                suggestionsDismissed = false
            }
            .accessibilityLabel("Intended outcome")
    }

    // MARK: - Recent

    private var suggestionList: some View {
        // Resolved once rather than per row: `suggestions` filters the recent list every time it is
        // read, and the rows must all agree on the same array for the highlight index to mean
        // anything. Identified by index because `UserPreferences` already guarantees the strings are
        // unique, so index and value are equally stable here and the index is what the keyboard uses.
        let items = suggestions

        return VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(Type.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, Space.s)
                .padding(.bottom, Space.xxs)

            ForEach(items.indices, id: \.self) { index in
                SuggestionRow(
                    text: items[index],
                    isHighlighted: highlighted == index,
                    action: { accept(items[index]) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent outcomes")
    }

    /// Recent outcomes that are not already exactly what the user has typed, filtered by the query.
    ///
    /// `UserPreferences` already deduplicates case-insensitively, so the strings are unique and safe
    /// to use as `ForEach` identity.
    private var suggestions: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = recentOutcomes.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        guard !query.isEmpty else { return Array(pool.prefix(Self.suggestionLimit)) }
        return Array(pool.filter { $0.localizedCaseInsensitiveContains(query) }.prefix(Self.suggestionLimit))
    }

    /// No suggestions means no list — not an empty list and not a "no suggestions" message.
    private var isShowingSuggestions: Bool {
        focus == .outcome && !suggestionsDismissed && !suggestions.isEmpty
    }

    // MARK: - Keyboard

    private func moveHighlight(by offset: Int) -> KeyPress.Result {
        guard isShowingSuggestions else { return .ignored }
        let count = suggestions.count
        guard let current = highlighted else {
            highlighted = offset > 0 ? 0 : count - 1
            return .handled
        }
        let next = current + offset
        // Stepping up past the first row returns the user to typing, which is where they came from.
        guard next >= 0 else {
            highlighted = nil
            return .handled
        }
        highlighted = min(next, count - 1)
        return .handled
    }

    private func submit() {
        if let highlighted, suggestions.indices.contains(highlighted) {
            accept(suggestions[highlighted])
            return
        }
        onSubmit()
    }

    private func accept(_ suggestion: String) {
        text = suggestion
        highlighted = nil
        suggestionsDismissed = true
        focus = .outcome
    }

    private func handleEscape() {
        if isShowingSuggestions {
            suggestionsDismissed = true
            highlighted = nil
            return
        }
        onCancel()
    }
}

// MARK: - One suggestion

/// A row of the `Recent` list.
///
/// Hover uses `Surface.hover` and the keyboard cursor uses `Surface.selected`, deliberately different
/// so the mouse and the keyboard never contradict each other on screen (§ 8.6).
private struct SuggestionRow: View {
    let text: String
    let isHighlighted: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Text(verbatim: "↳")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(Type.secondary)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: Theme.chipShape)
            .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .lggrAnimation(Motion.settle, value: isHighlighted)
        .accessibilityLabel(text)
    }

    private var fill: Color {
        if isHighlighted { return Surface.selected }
        return isHovering ? Surface.hover : .clear
    }
}
