import LggrKit
import SwiftUI

// Rules `⌘6`. See SPEC.md §5 and docs/_design/04-screens.md §4.6.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT THIS SCREEN IS FOR
//
//  Lggr says things about a person's day — this was Coding, that was Communication, forty minutes of
//  Friday afternoon was Distraction. Every one of those statements comes from a row on this screen.
//  There is no model, no heuristic and no hidden table: `ClassificationEngine` holds no knowledge of
//  Xcode, Slack or YouTube, and the shipped behaviour is `ClassificationRule.defaults`, a literal
//  array rendered below under "Built in", editable and deletable like anything else.
//
//  That is what makes judgment-shaped categories acceptable at all. If the app is going to file part
//  of someone's afternoon under Distraction, the user has to be able to open the sentence that did it
//  and change it in one action — which is the whole design of this screen and the reason it is not
//  buried inside Settings.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// `⌘N` is New Rule while Rules is the selected section (`04-screens.md` §7.1).
private enum RulesShortcut {
    static let newRule = KeyboardShortcut("n", modifiers: .command)
}

@MainActor
public struct RulesView: View {

    private let model: RulesModel
    private let projects: [Project]

    /// Which rule the editor is open on, and what kind of save it will be.
    @State private var editing: Editing?
    /// The rule waiting on a delete confirmation. Nothing in Lggr deletes on a keystroke alone.
    @State private var pendingDeletion: ClassificationRule?
    @State private var isConfirmingReset = false

    public init(model: RulesModel, projects: [Project] = []) {
        self.model = model
        self.projects = projects
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.l)

            if let message = model.lastError {
                ErrorBanner(
                    message: message,
                    recoveryTitle: nil,
                    onRecover: {},
                    onDismiss: { model.dismissError() }
                )
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.l)
            }

            switch model.phase {
            case .failed(let message):
                failure(message)
            case .idle, .loading, .ready:
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .task { await model.load() }
        .sheet(item: $editing) { editing in
            RuleEditor(
                rule: editing.rule,
                projects: projects,
                mode: editing.mode,
                onSave: { rule in save(rule, from: editing) },
                onCancel: { self.editing = nil },
                onDelete: deleteAction(for: editing)
            )
        }
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { rule in
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
            Button("Delete Rule", role: .destructive) {
                Task { await model.delete(id: rule.id) }
                pendingDeletion = nil
            }
        } message: { _ in
            // Exact rather than reassuring-sounding: categories are derived from the rules every time
            // a day is drawn, so deleting one really does change how earlier days read, and no history
            // is lost in the process.
            Text(
                "Days already recorded will be read by your remaining rules. No time or session is "
                    + "deleted.")
        }
        .confirmationDialog(
            "Put back the rules Lggr ships with?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Built-in Rules") { Task { await model.resetBuiltInRules() } }
            Button("Cancel", role: .cancel) { isConfirmingReset = false }
        } message: {
            Text("Your own rules are untouched. Only the built-in rows go back to how they arrived.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rules")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Text("Rules")
                .font(Type.screenTitle)
                .foregroundStyle(.primary)

            Spacer(minLength: Space.m)

            // Progressive disclosure: the menu only exists when it holds something that can be done.
            // A `⋯` that opens onto two greyed-out rows is worse than no `⋯`.
            if hasOverflowActions {
                Menu {
                    if canReorder {
                        Button("Reorder by Priority") { Task { await model.reorderByPriority() } }
                    }
                    if model.canResetBuiltInRules {
                        Button("Reset Built-in Rules…") { isConfirmingReset = true }
                    }
                } label: {
                    Image(systemName: Icon.more)
                        .imageScale(.large)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions")
            }

            Button("New Rule") { editing = .init(rule: nil, mode: .create) }
                .buttonStyle(.lggrPrimary(shortcut: RulesShortcut.newRule))
                .keyboardShortcut(RulesShortcut.newRule)
        }
    }

    // MARK: - List

    private var list: some View {
        // See `ScrollingSection`: a `ScrollView` renders as nothing under `ImageRenderer`, which is
        // how every screen in this app is reviewed for light and dark without Xcode.
        ScrollingSection {
            VStack(alignment: .leading, spacing: Space.xxl) {
                ownRules
                builtInRules
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var ownRules: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Your rules", count: model.userRules.isEmpty ? nil : model.userRules.count)

            if model.userRules.isEmpty {
                noRulesOfYourOwn
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.userRules) { rule in
                        row(for: rule, isBuiltIn: false)
                    }
                }
            }
        }
    }

    private var builtInRules: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Built in")

            Text(
                "These are the rules Lggr arrives with. Switch one off, or open it to make a version "
                    + "of your own."
            )
            .font(Type.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.builtInRules) { rule in
                    row(for: rule, isBuiltIn: true)
                }
            }
        }
    }

    private func row(for rule: ClassificationRule, isBuiltIn: Bool) -> some View {
        RuleRow(
            rule: rule,
            projects: projects,
            isBuiltIn: isBuiltIn,
            canMoveUp: !isBuiltIn && model.canMoveUp(rule),
            canMoveDown: !isBuiltIn && model.canMoveDown(rule),
            onToggle: { isEnabled in Task { await model.setEnabled(isEnabled, for: rule) } },
            onEdit: { edit(rule, isBuiltIn: isBuiltIn) },
            onMoveUp: { Task { await model.moveUp(rule) } },
            onMoveDown: { Task { await model.moveDown(rule) } }
        )
        .contextMenu { actionItems(for: rule, isBuiltIn: isBuiltIn) }
        // Double-click is the native "open this row" gesture on macOS, and editing is the only thing
        // a rule row can be opened into.
        .onTapGesture(count: 2) { edit(rule, isBuiltIn: isBuiltIn) }
    }

    // MARK: - Empty and failed

    /// §4.6's copy, verbatim.
    ///
    /// Inline rather than a full-screen `EmptyStateView`, because the screen is not empty — the
    /// built-in rules are always below this, doing work. A centred empty state over a populated list
    /// would be a lie about the state of the app, and the primary action is already in the header.
    private var noRulesOfYourOwn: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("No rules of your own yet.")
                .font(Type.rowTitle)
                .foregroundStyle(.primary)
            Text(
                "Lggr ships with sensible defaults. Correct a category on the timeline and it will "
                    + "offer to make the correction permanent."
            )
            .font(Type.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }

    /// The standard error policy (`04-screens.md` §3.3): one sentence about the record, never about
    /// the user, and one way forward that actually does something.
    private func failure(_ message: String) -> some View {
        EmptyStateView(
            symbol: Icon.error,
            title: message,
            message: "Lggr is classifying with the rules it ships with in the meantime.",
            actionTitle: "Try Again",
            action: { Task { await model.load() } }
        )
    }

    // MARK: - Actions

    @ViewBuilder private func actionItems(
        for rule: ClassificationRule,
        isBuiltIn: Bool
    ) -> some View {
        Button(isBuiltIn ? "Make It Your Own…" : "Edit…") { edit(rule, isBuiltIn: isBuiltIn) }
        Button("Duplicate") { Task { await model.duplicate(rule) } }
        Button(rule.isEnabled ? "Switch Off" : "Switch On") {
            Task { await model.setEnabled(!rule.isEnabled, for: rule) }
        }

        if !isBuiltIn {
            Divider()
            Button("Move Up") { Task { await model.moveUp(rule) } }
                .disabled(!model.canMoveUp(rule))
            Button("Move Down") { Task { await model.moveDown(rule) } }
                .disabled(!model.canMoveDown(rule))
            Divider()
            Button("Delete Rule", role: .destructive) { pendingDeletion = rule }
        } else if rule != shippedVersion(of: rule) {
            Divider()
            // Offered only when this row actually differs from the one Lggr ships, so the item is
            // never a no-op dressed as an action.
            Button("Reset to Default") {
                guard let shipped = shippedVersion(of: rule) else { return }
                Task { await model.save(shipped) }
            }
        }
    }

    /// Editing a built-in opens the editor on a *copy* — §4.6: the shipped row cannot be changed in
    /// place, and saving the copy switches the original off. The copy is not persisted until Save.
    private func edit(_ rule: ClassificationRule, isBuiltIn: Bool) {
        guard isBuiltIn else {
            editing = Editing(rule: rule, mode: .edit)
            return
        }
        editing = Editing(
            rule: model.shadowCopy(of: rule),
            mode: .shadowBuiltIn(originalDescription: RuleSentence.condition(rule, projects: projects)),
            shadowedOriginal: rule
        )
    }

    /// Deleting is offered from inside the editor only for a rule the user owns and that exists.
    /// A new rule has nothing to delete, and a shipped rule is switched off rather than removed.
    private func deleteAction(for editing: Editing) -> (() -> Void)? {
        guard
            editing.mode == .edit,
            let rule = editing.rule,
            !RulesModel.isBuiltIn(rule)
        else { return nil }
        return {
            self.editing = nil
            pendingDeletion = rule
        }
    }

    private func save(_ rule: ClassificationRule, from editing: Editing) {
        self.editing = nil
        Task {
            if let original = editing.shadowedOriginal {
                await model.adoptShadow(rule, replacing: original)
            } else {
                await model.save(rule)
            }
        }
    }

    // MARK: - Derived

    private var canReorder: Bool { model.userRules.count > 1 }

    private var hasOverflowActions: Bool { canReorder || model.canResetBuiltInRules }

    private func shippedVersion(of rule: ClassificationRule) -> ClassificationRule? {
        ClassificationRule.defaults.first { $0.id == rule.id }
    }

    private var deletionTitle: String {
        guard let pendingDeletion else { return "Delete this rule?" }
        // Typographic quotes, because this string is set in the alert's own title style and a
        // straight double quote is a typewriter artefact.
        let sentence = RuleSentence.condition(pendingDeletion, projects: projects)
        return "Delete \u{201C}\(sentence)\u{201D}?"
    }

    // MARK: - Editor route

    /// What the editor sheet is open on. A value rather than three booleans, so two editors can never
    /// be half-open at once.
    struct Editing: Identifiable, Equatable {
        let rule: ClassificationRule?
        let mode: RuleEditor.Mode
        /// The shipped rule this edit shadows, when it shadows one. Held here rather than in the
        /// editor because switching the original off is the host's job, not the form's.
        var shadowedOriginal: ClassificationRule?

        init(
            rule: ClassificationRule?,
            mode: RuleEditor.Mode,
            shadowedOriginal: ClassificationRule? = nil
        ) {
            self.rule = rule
            self.mode = mode
            self.shadowedOriginal = shadowedOriginal
        }

        var id: String { rule?.id.uuidString ?? "new" }
    }
}
