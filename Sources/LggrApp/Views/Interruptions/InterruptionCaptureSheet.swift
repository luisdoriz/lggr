import LggrKit
import SwiftUI

// Interruption capture, `⌘⇧I`. See docs/_design/04-screens.md § 5.4 and § 10.6, SPEC.md § 3.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  DESIGNED FOR TWO SECONDS, AND FOR THE SESSION TO SURVIVE THEM
//
//  Everything on this panel follows from one fact: **the session keeps running.** Someone is
//  mid-thought, something arrived, and the app's whole job is to take one sentence and get out of
//  the way. So:
//
//    • **No timer.** Showing the clock while capturing an interruption invites the user to end the
//      session, which is the exact opposite of the intent.
//    • **One field, focused on open.** `⏎` saves, `Esc` cancels and discards, `⌘⏎` saves from
//      anywhere in the panel.
//    • **The `From` menu does not exist until the user has typed.** Eight sources on screen before
//      there is anything to classify is a form; one menu afterwards is a refinement.
//    • **No toast, no confirmation.** The panel closes and the counts move. Interruption capture
//      must cost less attention than the interruption did.
//    • **The text is never cleared by a failure.** The write is awaited; if it did not land the
//      panel stays open with one quiet line above the buttons and the sentence still in the field.
//      Retyping it is the one cost that would stop people capturing at all.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// The copy, in one place, verbatim from `04-screens.md` § 10.6.
enum InterruptionCopy {
    static let title = "What came up?"
    static let placeholder = "Review Omar's blocked PR"
    static let sourceLabel = "From"
    static let save = "Save"
    static let cancel = "Cancel"
    static let saveFailure = "Couldn't save that yet — try again."
}

/// Write one line down and get back to work.
///
/// Two hosts, one view: a 420pt sheet on the main window, and an inline replacement of the menu bar
/// popover's body. The only difference is the frame and the padding — a capture from the menu bar
/// must not open a window, because the window is not where the work is.
///
/// `onSave` is `async` and returns whether the write landed. That is what lets this panel be both
/// instant in the ordinary case and honest in the failing one: the host dismisses on `true`, and on
/// `false` this view puts one sentence above the buttons and keeps everything the user typed.
@MainActor
public struct InterruptionCaptureSheet: View {

    /// Which host is drawing it.
    public enum Presentation {
        /// A sheet on the main window: 420pt wide, `Space.xl` of interior padding.
        case sheet
        /// Inline inside the 320pt menu bar popover, which supplies its own padding and width.
        case popover
    }

    private let presentation: Presentation
    private let onSave: (String, InterruptionSource) async -> Bool
    private let onCancel: () -> Void

    @State private var text: String = ""
    @State private var source: InterruptionSource = .other
    @State private var isSaving = false
    @State private var didFail = false

    @FocusState private var isFieldFocused: Bool

    /// - Parameter draft: the field's initial contents. Empty in the app — capture always starts from
    ///   nothing — and set by the headless snapshot renderer, which has to photograph the state
    ///   *after* the first character, because that is when the `From` menu exists.
    public init(
        presentation: Presentation = .sheet,
        draft: String = "",
        onSave: @escaping (String, InterruptionSource) async -> Bool,
        onCancel: @escaping () -> Void = {}
    ) {
        self.presentation = presentation
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: draft)
    }

    private static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(InterruptionCopy.title)
                .font(titleFont)
                .foregroundStyle(.primary)

            field

            // Appears with the first character, and only then. `Motion.reveal` is the app's
            // "something arrived" animation; under Reduce Motion it becomes a step, not a slide.
            if hasTyped {
                sourceRow
            }

            if didFail {
                Text(InterruptionCopy.saveFailure)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .lggrAnimation(Motion.reveal, value: hasTyped)
        .lggrAnimation(Motion.settle, value: didFail)
        .padding(presentation == .sheet ? Space.xl : 0)
        .frame(width: presentation == .sheet ? Layout.captureSheetWidth : nil)
        .background(presentation == .sheet ? AnyShapeStyle(Surface.canvas) : AnyShapeStyle(.clear))
        .defaultFocus($isFieldFocused, true)
        // Cancels and discards. Never mid-save: interrupting a write would leave the user unsure
        // whether the note survived, which is the one thing this panel may not do.
        .onExitCommand { if !isSaving { onCancel() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(InterruptionCopy.title)
    }

    // MARK: - The one field

    /// Focused on open, `⏎` submits. `Type.outcome` in the sheet because the sentence is the whole
    /// content of the panel; `Type.body` in the popover, where 320pt cannot carry a 22pt line
    /// without wrapping a short note onto three rows.
    private var field: some View {
        TextField(InterruptionCopy.placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(presentation == .sheet ? Type.outcome : Type.body)
            .focused($isFieldFocused)
            .disabled(isSaving)
            .onSubmit(save)
            // The failure line belongs to the attempt, not to the field: as soon as the user changes
            // what they wrote, the old sentence is stale and goes away.
            .onChange(of: text) { _, _ in didFail = false }
            .padding(Space.m)
            .background(Surface.sunken, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
            .accessibilityLabel(InterruptionCopy.title)
    }

    /// `From  Other ⌄`. One menu, seven cases, defaulting to `.other` — the source is useful to the
    /// weekly review and is never worth a keystroke at capture time.
    private var sourceRow: some View {
        HStack(spacing: Space.s) {
            Text(InterruptionCopy.sourceLabel)
                .font(Type.secondary)
                .foregroundStyle(.secondary)

            Picker(InterruptionCopy.sourceLabel, selection: $source) {
                ForEach(InterruptionSource.allCases) { option in
                    Label(option.displayName, systemImage: option.symbolName)
                        .tag(option)
                }
            }
            .labelsHidden()
            .font(Type.body)
            .fixedSize()
            .disabled(isSaving)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack(spacing: Space.m) {
            // `Esc` is handled by `.onExitCommand` on the panel rather than by a `.cancelAction`
            // shortcut here, and that is not a style choice: the menu bar popover registers its own
            // `.cancelAction` to dismiss itself, and two registrations in one view tree make which
            // one fires undefined. `StartSessionForm` resolves the same collision the same way.
            Button(InterruptionCopy.cancel, action: onCancel)
                .disabled(isSaving)

            Spacer(minLength: Space.m)

            Button(InterruptionCopy.save, action: save)
                .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                .keyboardShortcut(Self.saveShortcut)
                .disabled(!canSave)
        }
    }

    // MARK: - Saving

    private var titleFont: Font {
        presentation == .sheet ? Type.sectionTitle : Type.rowTitle
    }

    private var hasTyped: Bool {
        !text.isEmpty
    }

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Save is disabled while the trimmed note is empty — there is no error message for an empty
    /// field, because a button that is not ready yet is not the user doing something wrong.
    private var canSave: Bool {
        !trimmed.isEmpty && !isSaving
    }

    private func save() {
        guard canSave else { return }
        let note = trimmed
        let chosen = source
        isSaving = true
        Task {
            let saved = await onSave(note, chosen)
            isSaving = false
            // On success the host dismisses; touching `text` here would clear a field that is about
            // to disappear and would flash an empty panel on the way out.
            guard !saved else { return }
            didFail = true
            isFieldFocused = true
        }
    }
}
