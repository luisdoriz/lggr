import LggrKit
import SwiftUI

// Declaring, or revising, one thing the week is for. See docs/_design/SPEC.md § 8.
//
// The whole design of this sheet is one instruction from the spec: **emphasise outcomes, not tasks**,
// and *avoid encouraging the user to create a large task list*. Two things carry it:
//
//   1. **The priority control is where the shape of a week is enforced.** One primary, two secondary,
//      and however many operational responsibilities the job actually carries. When the primary seat
//      and both secondary seats are taken, those chips are visibly disabled and say why on hover — so
//      a fourth outcome is not merely discouraged, it has nowhere to sit. `WeeklyOutcomeSet` is the
//      real enforcement (an outcome can also arrive from a carry-over or a second window); this is
//      what makes that rule legible instead of surprising.
//   2. **There is no list here.** No subtasks, no checklist, no due date, no estimate. An outcome is
//      a sentence with a status.
//
// The editor never touches the store. It hands a finished `WeeklyOutcome` to `onSave` and the host
// decides what to do with it, which is what lets it be exercised against fixtures.

/// Which seats a week has left, and why one is unavailable.
///
/// Computed from the `WeeklyOutcomeSet` the review already built, so the sheet and the screen agree
/// about the shape of the week without either of them re-deriving it.
public struct OutcomeSeating: Sendable {

    /// The outcome being edited keeps its own seat, whatever the week's remaining capacity is —
    /// otherwise renaming the primary outcome would require demoting it first.
    private let editingPriority: OutcomePriority?
    private let primaryTitle: String?
    private let hasPrimary: Bool
    private let remainingSecondarySlots: Int

    public init(set: WeeklyOutcomeSet, editing: WeeklyOutcome? = nil) {
        self.editingPriority = editing?.priority
        self.primaryTitle = set.primary?.normalizedTitle
        self.hasPrimary = set.hasPrimary
        self.remainingSecondarySlots = set.remainingSecondarySlots
    }

    public func allows(_ priority: OutcomePriority) -> Bool {
        if priority == editingPriority { return true }
        switch priority {
        case .primary:
            return !hasPrimary
        case .secondary:
            return remainingSecondarySlots > 0
        case .operational:
            // Operational load is observed rather than chosen, and hiding some of it would understate
            // the week rather than simplify it. Never capped.
            return true
        }
    }

    /// One plain sentence for a seat that is taken. Shown on hover and under the control; it states a
    /// fact about the week, never a rule the user has broken.
    public func reason(for priority: OutcomePriority) -> String? {
        guard !allows(priority) else { return nil }
        switch priority {
        case .primary:
            if let primaryTitle {
                return "This week's primary outcome is \u{201C}\(primaryTitle)\u{201D}."
            }
            return "This week already has a primary outcome."
        case .secondary:
            return "A week has room for two secondary outcomes."
        case .operational:
            return nil
        }
    }

    /// The seat a new outcome opens on: primary if the week has none, then secondary, then
    /// operational. The sheet opens on the most important thing still missing.
    public var suggestedPriority: OutcomePriority {
        OutcomePriority.allCases.first { allows($0) } ?? .operational
    }

    /// Whether every seat an *outcome* can take is full, and only operational responsibilities remain.
    public var isFocusFull: Bool {
        !allows(.primary) && !allows(.secondary)
    }
}

/// What the host is presenting the editor for: a new outcome in a named seat, or one that exists.
///
/// `Identifiable`, so a host can drive `.sheet(item:)` with it. A new outcome gets a fresh id rather
/// than reusing a sentinel, which is what lets "add a secondary" open a second time after a cancel.
public struct OutcomeEditRequest: Identifiable, Sendable {

    public let id: UUID
    /// `nil` declares a new outcome.
    public let outcome: WeeklyOutcome?
    /// The seat the user clicked. Honoured for a new outcome; an existing one keeps its own.
    public let priority: OutcomePriority

    public init(priority: OutcomePriority) {
        self.id = UUID()
        self.outcome = nil
        self.priority = priority
    }

    public init(outcome: WeeklyOutcome) {
        self.id = outcome.id
        self.outcome = outcome
        self.priority = outcome.priority
    }
}

/// Create or revise a weekly outcome.
@MainActor
public struct WeeklyOutcomeEditor: View {

    private let existing: WeeklyOutcome?
    private let weekStart: Date
    private let seating: OutcomeSeating
    private let projects: [Project]
    private let onSave: (WeeklyOutcome) -> Void
    private let onCancel: () -> Void

    @Environment(\.clock) private var clock

    @State private var title: String
    @State private var details: String
    @State private var priority: OutcomePriority
    @State private var status: OutcomeStatus
    @State private var progress: Double
    @State private var projectIDs: [UUID]

    @FocusState private var isTitleFocused: Bool

    private static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    /// - Parameters:
    ///   - outcome: `nil` declares a new one.
    ///   - initialPriority: the seat a new outcome opens in — the one whose button the user pressed.
    ///     `nil` falls back to the most important seat the week still has free.
    ///   - weekStart: midnight at the start of the week the outcome belongs to. Passed in rather than
    ///     read from a clock, so declaring next week's outcome on Friday files it against next week.
    public init(
        outcome: WeeklyOutcome?,
        weekStart: Date,
        seating: OutcomeSeating,
        initialPriority: OutcomePriority? = nil,
        projects: [Project] = [],
        onSave: @escaping (WeeklyOutcome) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.existing = outcome
        self.weekStart = weekStart
        self.seating = seating
        self.projects = projects.filter { $0.isActive || outcome?.projectIDs.contains($0.id) == true }
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: outcome?.title ?? "")
        _details = State(initialValue: outcome?.details ?? "")
        _priority = State(
            initialValue: outcome?.priority ?? initialPriority ?? seating.suggestedPriority
        )
        _status = State(initialValue: outcome?.status ?? .notStarted)
        _progress = State(initialValue: outcome?.progress ?? 0)
        _projectIDs = State(initialValue: outcome?.projectIDs ?? [])
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(existing == nil ? "New Outcome" : "Edit Outcome")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            fields

            HStack(spacing: Space.m) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Space.m)
                Button("Save", action: save)
                    .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                    .keyboardShortcut(Self.saveShortcut)
                    .disabled(trimmedTitle == nil)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.projectEditorWidth)
        .background(Surface.canvas)
        .defaultFocus($isTitleFocused, true)
        .lggrAnimation(Motion.reveal, value: showsProgress)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(existing == nil ? "New Outcome" : "Edit Outcome")
    }

    // MARK: - Fields

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.l) {
            GridRow(alignment: .firstTextBaseline) {
                label("Outcome")
                    .gridColumnAlignment(.trailing)
                TextField("Improve receipt ingestion reliability", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(Type.body)
                    .focused($isTitleFocused)
                    .onSubmit(save)
            }

            GridRow(alignment: .firstTextBaseline) {
                label("Detail")
                // `TextField` with a vertical axis rather than a `TextEditor`: two or three lines is
                // the whole need, and it keeps the sheet's one text style consistent.
                TextField("What would make this done?", text: $details, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(Type.body)
                    .lineLimit(2...4)
            }

            GridRow(alignment: .top) {
                label("Priority")
                priorityControl
            }

            if existing != nil {
                GridRow(alignment: .firstTextBaseline) {
                    label("Status")
                    Picker("Status", selection: $status) {
                        ForEach(OutcomeStatus.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

                if showsProgress {
                    GridRow(alignment: .firstTextBaseline) {
                        label("Progress")
                        progressControl
                    }
                }
            }

            if !projects.isEmpty {
                GridRow(alignment: .top) {
                    label("Projects")
                    projectChips
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Type.body)
            .foregroundStyle(.secondary)
    }

    // MARK: - Priority

    /// Three chips. A chip whose seat is taken is disabled and carries its reason on hover, and the
    /// same sentence is repeated under the row so it is discoverable without a pointer.
    private var priorityControl: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xxs) {
                ForEach(OutcomePriority.allCases) { option in
                    PriorityChip(
                        title: option.displayName,
                        isSelected: priority == option,
                        reasonUnavailable: seating.reason(for: option),
                        action: { priority = option }
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Priority")

            if let note = seatingNote {
                Text(note)
                    .font(Type.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// At most one sentence, and only about the seat the user cannot take. Two notes at once would be
    /// a form telling the user off.
    private var seatingNote: String? {
        seating.reason(for: .primary) ?? seating.reason(for: .secondary)
    }

    // MARK: - Progress

    /// Absent for an operational responsibility: a percentage on "on-call" would be a number about
    /// being available, which is not progress and not something to improve.
    private var showsProgress: Bool { priority != .operational }

    private var progressControl: some View {
        HStack(spacing: Space.m) {
            Slider(value: $progress, in: 0...1, step: 0.05)
                .controlSize(.small)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int((progress * 100).rounded())) percent")

            Text(verbatim: "\(Int((progress * 100).rounded()))%")
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .help("Your own figure. Lggr reports the time separately and never adjusts this.")
    }

    // MARK: - Projects

    /// Which streams of work this outcome runs through. Optional, and the weekly review resolves time
    /// from the sessions themselves — so linking a project here is a note about intent, not a filter.
    private var projectChips: some View {
        // A wrapping row of chips. The minimum column is a third of the sheet, derived from the sheet's
        // own width rather than invented at this call site.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Layout.projectEditorWidth / 3), spacing: Space.s)],
            alignment: .leading,
            spacing: Space.s
        ) {
            ForEach(projects) { project in
                let isLinked = projectIDs.contains(project.id)
                Button {
                    toggle(project.id)
                } label: {
                    HStack(spacing: Space.xs) {
                        ProjectDot(project: project)
                        Text(project.normalizedName ?? project.name)
                            .font(Type.secondary)
                            .foregroundStyle(isLinked ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, Space.s)
                    .padding(.vertical, Space.xs)
                    .background(isLinked ? Surface.selected : Surface.hover, in: Theme.chipShape)
                    .contentShape(Theme.chipShape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(project.normalizedName ?? project.name)
                .accessibilityAddTraits(isLinked ? [.isSelected] : [])
            }
        }
    }

    private func toggle(_ projectID: UUID) {
        if let index = projectIDs.firstIndex(of: projectID) {
            projectIDs.remove(at: index)
        } else {
            projectIDs.append(projectID)
        }
    }

    // MARK: - Saving

    private var trimmedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var trimmedDetails: String? {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        guard let trimmedTitle else { return }
        let now = clock.now

        if var outcome = existing {
            outcome.title = trimmedTitle
            outcome.details = trimmedDetails
            outcome.priority = priority
            outcome.status = status
            outcome.progress = showsProgress ? progress : 0
            outcome.projectIDs = projectIDs
            outcome.updatedAt = now
            onSave(outcome)
        } else {
            onSave(
                WeeklyOutcome(
                    title: trimmedTitle,
                    details: trimmedDetails,
                    priority: priority,
                    status: .notStarted,
                    progress: 0,
                    weekStartDate: weekStart,
                    projectIDs: projectIDs,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
    }
}

// MARK: - One chip

/// A priority chip. Selected is `Surface.selected` with accent text; hover is `Surface.hover`; a chip
/// with no seat left is disabled and explains itself on hover rather than disappearing.
///
/// The same anatomy as `DurationSegment` in the start panel: nothing scales, nothing pulses, and the
/// fill is the whole affordance.
private struct PriorityChip: View {
    let title: String
    let isSelected: Bool
    let reasonUnavailable: String?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Type.secondary)
                .foregroundStyle(foreground)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .background(fill, in: Theme.chipShape)
                .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .disabled(reasonUnavailable != nil)
        .help(reasonUnavailable ?? "")
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .lggrAnimation(Motion.settle, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(reasonUnavailable ?? "")
    }

    private var foreground: AnyShapeStyle {
        if reasonUnavailable != nil { return AnyShapeStyle(.tertiary) }
        return isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary)
    }

    private var fill: Color {
        if reasonUnavailable != nil { return .clear }
        if isSelected { return Surface.selected }
        return isHovering ? Surface.hover : .clear
    }
}
