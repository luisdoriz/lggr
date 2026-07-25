import SwiftUI

// The chrome the two history screens share: which stretch of time you are looking at, a search
// field, and the quiet filters. See docs/_design/04-screens.md § 4.2 and § 4.3.
//
// This file exists so that "step back a month" means, looks and reads the same on Focus Sessions and
// on Accomplishments. Two hand-built headers would drift within a week, and the drift would be in the
// one control the user needs to trust: the label that says what they are being shown.
//
// Nothing here holds state beyond focus. Every control is a value in and a closure out, so both
// screens render in full from fixtures with no store behind them.

// MARK: - The window bar

/// `‹  July 2026  ›   [ Month ⌄ ]                                    Now`
///
/// The window is named, not implied. A history screen that silently shows "the last 30 days" leaves
/// the user unable to say whether something is missing or simply out of range — so the range is
/// printed, it is navigable in both directions, and the control that would walk into the future is
/// disabled rather than removed, because a row that changes width as you page through it is a row
/// that moves.
struct HistoryWindowBar: View {

    let window: HistoryWindow.Display
    /// Negative steps go back. The host decides what a step is worth; this view only knows direction.
    let onStep: (Int) -> Void
    let onSpanChange: (HistoryWindow.Span) -> Void
    let onGoToLatest: () -> Void
    /// The count of rows in the window, before any filter. `nil` prints nothing.
    ///
    /// A count of a list is a fact about the list. There is deliberately no total time, no average
    /// and no rate beside it — `INTELLIGENCE.md` § 3.4 removed every headline number that behaves
    /// like a score, and a history header is exactly where the next one would arrive.
    let rowCount: Int?
    /// "12 sessions" / "1 session". Supplied by the screen so the noun is its own.
    let rowNoun: (singular: String, plural: String)

    var body: some View {
        HStack(spacing: Space.s) {
            stepButton(
                -1,
                symbol: Icon.previousWeek,
                label: "Earlier",
                enabled: true
            )

            Text(window.title)
                .font(Type.rowTitle)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(minWidth: Layout.historyRangeLabelWidth, alignment: .center)
                .contentTransition(.identity)
                .accessibilityLabel("Showing \(window.title)")

            stepButton(
                1,
                symbol: Icon.nextWeek,
                label: "Later",
                enabled: window.canStepForward
            )

            Picker("Range", selection: spanBinding) {
                ForEach(HistoryWindow.Span.allCases) { span in
                    Text(span.displayName).tag(span)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("How much history one step covers")

            // Progressive disclosure: there is nothing to return to while you are already here.
            if !window.isCurrent {
                Button("Now", action: onGoToLatest)
                    .buttonStyle(.borderless)
                    .font(Type.secondary)
                    .help("Back to the range containing today")
            }

            // Belongs to the range rather than to the filters, so it sits with the range: "this is the
            // stretch you are looking at, and this is how many rows are in it." `fixedSize` because a
            // count that wraps to three lines is worse than one that pushes the row.
            if let rowCount {
                Text(countText(rowCount))
                    .font(Type.secondary)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .fixedSize()
                    .padding(.leading, Space.xs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Range")
        .accessibilityValue(window.title)
    }

    private func countText(_ count: Int) -> String {
        "\(count) \(count == 1 ? rowNoun.singular : rowNoun.plural)"
    }

    private var spanBinding: Binding<HistoryWindow.Span> {
        Binding(get: { window.span }, set: onSpanChange)
    }

    private func stepButton(
        _ steps: Int,
        symbol: String,
        label: String,
        enabled: Bool
    ) -> some View {
        Button {
            onStep(steps)
        } label: {
            Image(systemName: symbol)
                .imageScale(.medium)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(enabled ? label : "There is no history after today")
    }
}

// MARK: - Search

/// The search field the two history screens share, with `⌘F` on the glass.
///
/// The magnifying glass is a real button rather than an ornament, and it is what carries the
/// shortcut: a `⌘F` hint printed next to a decoration would be a promise made by something that
/// cannot keep it. Clicking the glass and pressing `⌘F` do the same thing — put the caret in the
/// field.
struct HistorySearchField: View {

    let prompt: String
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Button {
                isFocused = true
            } label: {
                Image(systemName: Icon.search)
                    .imageScale(.small)
                    .foregroundStyle(isFocused ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Search")

            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(Type.body)
                .labelsHidden()
                .focused($isFocused)
                .onSubmit { isFocused = false }

            if text.isEmpty {
                ShortcutHint(KeyboardShortcut("f", modifiers: .command))
                    .foregroundStyle(.tertiary)
            } else {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: Icon.dismiss)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(Surface.sunken, in: Theme.chipShape)
        .overlay(
            Theme.chipShape.strokeBorder(
                isFocused ? Color.accentColor.opacity(0.55) : Stroke.card,
                lineWidth: Layout.hairline
            )
        )
        .frame(width: Layout.searchFieldWidth)
        .lggrAnimation(Motion.tap, value: isFocused)
    }
}

// MARK: - Filters

/// A quiet "everything, or one of these" filter — the `[ All projects ⌄ ]` of § 4.2 and § 4.3.
///
/// The options are supplied by the screen and are only ever the values that can actually match what
/// is loaded. A menu with nine rows that return nothing makes the user do the app's work, so a filter
/// with nothing to choose between is not rendered at all: `options` empty means the whole control is
/// absent rather than present and useless.
struct HistoryFilterMenu<Value: Hashable>: View {

    struct Option: Identifiable {
        let value: Value
        let title: String
        /// An optional leading view — a project dot, a type glyph.
        let leading: AnyView?

        var id: Value { value }

        init(value: Value, title: String, leading: AnyView? = nil) {
            self.value = value
            self.title = title
            self.leading = leading
        }
    }

    /// The title of the "no filter" row: "All projects", "All types".
    let allTitle: String
    let options: [Option]
    @Binding var selection: Value?

    var body: some View {
        if !options.isEmpty {
            Picker(allTitle, selection: $selection) {
                Text(allTitle).tag(Value?.none)
                Divider()
                ForEach(options) { option in
                    optionLabel(option).tag(Value?.some(option.value))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(allTitle)
        }
    }

    /// A `Picker` row renders its label, so the leading view travels with the title rather than being
    /// drawn beside the closed control.
    @ViewBuilder private func optionLabel(_ option: Option) -> some View {
        if let leading = option.leading {
            HStack(spacing: Space.s) {
                leading
                Text(option.title)
            }
        } else {
            Text(option.title)
        }
    }
}
