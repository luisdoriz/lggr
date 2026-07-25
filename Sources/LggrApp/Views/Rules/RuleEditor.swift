import LggrKit
import SwiftUI

// Create or change one rule. See docs/_design/04-screens.md §4.6 and INTELLIGENCE.md §3.3.
//
// A rule has one condition and one outcome, so the editor is one sentence with two halves and three
// modifiers. There is no rule builder, no `AND`, no nested group: `RuleMatchType`'s own
// documentation explains why a composite matcher was left out, and an editor that offered one would
// be promising something the engine cannot evaluate.
//
// The editor never touches the store. It hands a finished `ClassificationRule` to `onSave` and the
// host decides what to do with it, which is what lets it be exercised against fixtures.

/// The one screen in Lggr that can create a window-title rule — and the reason it is the only one.
@MainActor
public struct RuleEditor: View {

    /// What kind of save this is, which is the only thing that changes the copy.
    public enum Mode: Equatable, Sendable {
        case create
        case edit
        /// Editing a rule Lggr ships with. §4.6: the built-in cannot be edited in place, so saving
        /// creates a rule of the user's own that shadows it and switches the original off. The user is
        /// told that here, before they save, rather than discovering it in the list afterwards.
        case shadowBuiltIn(originalDescription: String)
    }

    private let mode: Mode
    private let existing: ClassificationRule
    private let projects: [Project]
    private let onSave: (ClassificationRule) -> Void
    private let onCancel: () -> Void
    /// Present only for a rule the user owns.
    ///
    /// It is here as well as in the row's context menu because a context menu cannot be opened from
    /// the keyboard alone, and Lggr claims full keyboard operation. It still routes through the same
    /// confirmation — nothing is deleted by pressing this.
    private let onDelete: (() -> Void)?

    @State private var matchType: RuleMatchType
    @State private var matchValue: String
    @State private var category: ActivityCategory
    @State private var projectID: UUID?
    @State private var priority: Int
    @State private var isEnabled: Bool

    @FocusState private var isValueFocused: Bool

    /// `rule == nil` creates. Anything else edits in place, preserving `id`.
    public init(
        rule: ClassificationRule?,
        projects: [Project],
        mode: Mode? = nil,
        onSave: @escaping (ClassificationRule) -> Void,
        onCancel: @escaping () -> Void = {},
        onDelete: (() -> Void)? = nil
    ) {
        let seed =
            rule
            ?? ClassificationRule(
                matchType: .application,
                matchValue: "",
                category: .coding,
                priority: 10
            )
        self.existing = seed
        self.mode = mode ?? (rule == nil ? .create : .edit)
        self.projects = projects
        self.onSave = onSave
        self.onCancel = onCancel
        self.onDelete = onDelete
        _matchType = State(initialValue: seed.matchType)
        _matchValue = State(initialValue: seed.matchValue)
        _category = State(initialValue: seed.category)
        _projectID = State(initialValue: seed.projectID)
        _priority = State(initialValue: seed.priority)
        _isEnabled = State(initialValue: seed.isEnabled)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(title)
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.l) {
                GridRow(alignment: .firstTextBaseline) {
                    label("When")
                        .gridColumnAlignment(.trailing)
                    Picker("When", selection: $matchType) {
                        ForEach(RuleMatchType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .font(Type.body)
                }

                GridRow(alignment: .firstTextBaseline) {
                    label(valueLabel)
                    valueField
                }

                GridRow(alignment: .firstTextBaseline) {
                    label("Then call it")
                    Picker("Then call it", selection: $category) {
                        ForEach(ActivityCategory.allCases) { option in
                            Label(option.displayName, systemImage: option.symbolName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .font(Type.body)
                }

                GridRow(alignment: .firstTextBaseline) {
                    label("File under")
                    Picker("File under", selection: $projectID) {
                        Text("Leave the project alone").tag(UUID?.none)
                        ForEach(projects) { project in
                            Text(project.name).tag(UUID?.some(project.id))
                        }
                    }
                    .labelsHidden()
                    .font(Type.body)
                    .disabled(projects.isEmpty)
                    .help(
                        projects.isEmpty
                            ? "Create a project first and a rule can file activity under it."
                            : "Activity this rule matches is also filed under that project.")
                }

                GridRow(alignment: .firstTextBaseline) {
                    label("Priority")
                    HStack(spacing: Space.s) {
                        Stepper(value: $priority, in: 0...999, step: 10) {
                            Text(verbatim: "\(priority)")
                                .font(Type.body)
                                .monospacedDigit()
                        }
                        Text("Higher wins when two rules match.")
                            .font(Type.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GridRow(alignment: .firstTextBaseline) {
                    // An empty label cell keeps the checkbox on the control column, where every
                    // other input on this sheet begins.
                    Text(verbatim: "")
                    Toggle("On", isOn: $isEnabled)
                        .toggleStyle(.checkbox)
                        .font(Type.body)
                }
            }

            if matchType == .windowTitleContains {
                windowTitleNote
            }

            if case .shadowBuiltIn(let original) = mode {
                shadowNote(original: original)
            }

            preview

            HStack(spacing: Space.m) {
                if let onDelete {
                    Button("Delete Rule…", role: .destructive, action: onDelete)
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Space.m)
                Button("Save", action: save)
                    .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                    .keyboardShortcut(Self.saveShortcut)
                    .disabled(!canSave)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.ruleEditorWidth)
        .background(Surface.canvas)
        // Switching the axis clears the condition, and this is a safeguard rather than a nicety: a
        // bundle identifier is not a domain and neither of them is a phrase from a window title. It
        // is also what makes it impossible for a string that arrived from anywhere but this text
        // field to end up as a `.windowTitleContains` value — see `windowTitleNote`.
        .onChange(of: matchType) { previous, current in
            guard previous != current else { return }
            matchValue = current == existing.matchType ? existing.matchValue : ""
        }
        .defaultFocus($isValueFocused, true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    // MARK: - Copy

    private var title: String {
        switch mode {
        case .create: "New Rule"
        case .edit: "Edit Rule"
        case .shadowBuiltIn: "Make It Your Own"
        }
    }

    private var valueLabel: String {
        switch matchType {
        case .application: "Bundle identifier"
        case .windowTitleContains: "Words you type"
        case .browserDomain: "Domain"
        case .project: "Project"
        case .workType: "Work type"
        }
    }

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Type.body)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder private var valueField: some View {
        switch matchType {
        case .application, .windowTitleContains, .browserDomain:
            TextField(placeholder, text: $matchValue)
                .textFieldStyle(.roundedBorder)
                .font(Type.body)
                .focused($isValueFocused)
                .onSubmit(save)

        case .project:
            Picker("Project", selection: $matchValue) {
                Text("Choose a project").tag("")
                ForEach(projects) { project in
                    Text(project.name).tag(project.id.uuidString)
                }
            }
            .labelsHidden()
            .font(Type.body)

        case .workType:
            Picker("Work type", selection: $matchValue) {
                Text("Choose a work type").tag("")
                ForEach(WorkType.allCases) { type in
                    Text(type.displayName).tag(type.rawValue)
                }
            }
            .labelsHidden()
            .font(Type.body)
        }
    }

    private var placeholder: String {
        switch matchType {
        case .application: "com.apple.dt.Xcode"
        case .windowTitleContains: "Pull request"
        case .browserDomain: "github.com"
        case .project, .workType: ""
        }
    }

    /// The one note in the application that has to be read rather than skimmed.
    ///
    /// `INTELLIGENCE.md` §3.3 killed stored window titles outright — a browser title is a page title,
    /// a mail title is a subject line, and Lggr's data folder is an ordinary readable directory. A
    /// title rule survives that decision for exactly one reason: **the string on disk is one the user
    /// typed.** So the editor says so plainly instead of hiding the distinction behind a field label,
    /// and the field itself is the only way a value of this kind can ever come into being — the
    /// correction loop refuses to derive one (`ClassificationEngine.suggestedRule`), and switching the
    /// axis clears whatever was in the field before.
    private var windowTitleNote: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Window titles are never stored.")
                .font(Type.rowTitle)
                .foregroundStyle(.primary)

            Text(
                "Lggr reads the title of the window in front of you, checks whether it contains the "
                    + "words you type here, and forgets it. The title never reaches a file. The words "
                    + "you type do, so type only what you would be comfortable reading back."
            )
            .font(Type.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Lggr will not fill this in for you from a title it has read.")
                .font(Type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.sunken, in: Theme.panelShape)
        .overlay(Theme.panelShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
        .accessibilityElement(children: .combine)
    }

    /// Said before the save, not after it: shadowing switches a shipped rule off, and a change the
    /// user did not ask for is not made quietly here either.
    private func shadowNote(original: String) -> some View {
        Text(
            "Rules Lggr ships with stay as they are. Saving this makes a rule of your own from "
                + "\(original), gives it a higher priority, and switches the built-in one off. You can "
                + "put it back from the ⋯ menu at any time."
        )
        .font(Type.body)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The rule as the list will read it, updating as the fields change.
    ///
    /// Progressive disclosure in reverse: the user is composing a sentence in five controls, and this
    /// is the sentence. It is also the same helper the list and the correction sheet use, so what is
    /// previewed here is literally what appears there.
    @ViewBuilder private var preview: some View {
        if canSave {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: category.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(RuleSentence.full(draft, projects: projects))
                    .font(Type.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Behaviour

    /// The rule the fields currently describe. `id` is preserved so an edit replaces rather than
    /// duplicates; a shadow arrives with a fresh identifier from `RulesModel.shadowCopy(of:)`.
    private var draft: ClassificationRule {
        ClassificationRule(
            id: existing.id,
            matchType: matchType,
            matchValue: matchValue.trimmingCharacters(in: .whitespacesAndNewlines),
            category: category,
            projectID: projectID,
            priority: priority,
            isEnabled: isEnabled
        )
    }

    /// A rule whose condition can never be true is inert, and an inert rule in the list looks like a
    /// working one — so the editor refuses to make one rather than reporting an error about it.
    private var canSave: Bool { draft.isWellFormed }

    private func save() {
        guard canSave else { return }
        onSave(draft)
    }
}
