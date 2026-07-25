import AppKit
import SwiftUI

// The editable generated summary. See docs/_design/04-screens.md § 5.3.
//
// The suggestion is written by `SessionSummaryBuilder` and is deliberately flat: it saves typing, it
// does not have an opinion. This view's whole job is to make that text feel like the user's own — a
// plain `TextEditor` with the standard editing menu, standard `⌘Z`, and a `Regenerate` that is one
// undo away from being taken back.

/// The summary field of the review sheet, with its `Regenerate` action.
///
/// Regeneration overwrites the field with no confirmation on purpose. Asking "are you sure?" over a
/// text field that supports `⌘Z` is a dialog protecting the user from a keystroke they already know.
public struct SummaryEditor: View {

    /// `⌘R`, per the keyboard map. Registered here rather than by the sheet so the shortcut lives
    /// next to the action it fires.
    public static let regenerateShortcut = KeyboardShortcut("r", modifiers: .command)

    @Binding private var text: String
    private let onRegenerate: () -> Void

    /// Roughly three lines of body text, expressed in spacing tokens rather than as a raw number.
    /// The editor grows with its content; this is only the floor, so a one-sentence summary does not
    /// leave the sheet looking like it lost a section.
    private var minimumHeight: CGFloat { Space.hero + Space.xl }

    public init(text: Binding<String>, onRegenerate: @escaping () -> Void) {
        self._text = text
        self.onRegenerate = onRegenerate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            editor
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text("Summary")
                .font(Type.secondary)
                .foregroundStyle(.secondary)

            Spacer(minLength: Space.s)

            Button(action: onRegenerate) {
                HStack(spacing: Space.xs) {
                    Image(systemName: Icon.regenerate)
                        .imageScale(.small)
                    Text("Regenerate")
                    ShortcutHint(Self.regenerateShortcut)
                        .foregroundStyle(.tertiary)
                }
                .font(Type.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(Self.regenerateShortcut)
            .accessibilityLabel("Regenerate summary")
        }
    }

    // MARK: - Editor

    /// A recessed well (`Surface.sunken`), because this is somewhere text goes in rather than a card
    /// that comes forward. `.scrollContentBackground(.hidden)` is what lets the token show through —
    /// a `TextEditor` paints its own background otherwise and the well disappears in dark mode.
    private var editor: some View {
        TextEditor(text: $text)
            .font(Type.body)
            .scrollContentBackground(.hidden)
            .padding(Space.s)
            .frame(minHeight: minimumHeight)
            .background(Surface.sunken, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
            .contextMenu {
                // The system's cut/copy/paste/undo items are added to this menu automatically; these
                // two are the additions § 5.3 asks for.
                Button("Regenerate", action: onRegenerate)
                Button("Copy as Markdown", action: copyAsMarkdown)
            }
            .accessibilityLabel("Summary")
    }

    /// The summary is already plain prose, so "as Markdown" means "as a paragraph a note-taking app
    /// will accept" — the text, trimmed. There is nothing to escape and nothing to decorate.
    ///
    /// `NSPasteboard` rather than SwiftUI: `.copyable(_:)` needs focus and a `Transferable` payload,
    /// which a context-menu item on a text view has neither of.
    private func copyAsMarkdown() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
    }
}
