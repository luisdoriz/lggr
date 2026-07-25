import LggrKit
import SwiftUI

/// Record one thing that got done. See `04-screens.md` § 10.7.
///
/// Two hosts, one view:
///
///   * `⌘⇧A` from anywhere — a blank editor titled *Add an accomplishment*;
///   * the review sheet's *Log accomplishment* — the same editor, pre-filled from the session that
///     just finished and titled *Log what you delivered*.
///
/// Only one field is required. Details and the timestamp sit behind a disclosure that is closed on
/// open, because the overwhelmingly common case is "type what you did and press Return", and a form
/// that shows five controls to capture one sentence is a form people stop filling in.
///
/// The editor produces a `Accomplishment` value and hands it to `onSave`. It preserves the seed's
/// `id`, `focusSessionID` and `weeklyOutcomeID`, so editing an existing row updates it rather than
/// creating a second one, and a row generated from a session keeps knowing where it came from.
public struct AccomplishmentEditor: View {

    private let seed: Accomplishment
    private let projects: [Project]
    private let isFromSession: Bool
    private let onSave: (Accomplishment) -> Void
    private let onCancel: () -> Void

    @State private var title: String
    @State private var type: AccomplishmentType
    @State private var projectID: UUID?
    @State private var details: String
    @State private var timestamp: Date
    @State private var showsMore = false

    @FocusState private var isTitleFocused: Bool

    /// `accomplishment` is the seed: a fresh value for manual entry, a pre-filled one when a finished
    /// session offered it, or the existing record when editing.
    public init(
        accomplishment: Accomplishment,
        projects: [Project],
        isFromSession: Bool = false,
        onSave: @escaping (Accomplishment) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.seed = accomplishment
        self.projects = projects
        self.isFromSession = isFromSession
        self.onSave = onSave
        self.onCancel = onCancel
        _title = State(initialValue: accomplishment.title)
        _type = State(initialValue: accomplishment.type)
        _projectID = State(initialValue: accomplishment.projectID)
        _details = State(initialValue: accomplishment.details ?? "")
        _timestamp = State(initialValue: accomplishment.timestamp)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(isFromSession ? "Log what you delivered" : "Add an accomplishment")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            titleField

            HStack(alignment: .top, spacing: Space.l) {
                field("Type") { typePicker }
                field("Project") { projectPicker }
            }

            DisclosureGroup("Add details or change the time", isExpanded: $showsMore) {
                VStack(alignment: .leading, spacing: Space.l) {
                    field("Details") {
                        TextField("Optional", text: $details, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .font(Type.body)
                            .lineLimit(2...4)
                    }

                    DatePicker(
                        "When",
                        selection: $timestamp,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .font(Type.body)
                }
                .padding(.top, Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Type.body)
            .lggrAnimation(Motion.reveal, value: showsMore)

            HStack(spacing: Space.m) {
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
        // No width of its own in `Layout`, and inventing a tenth number is exactly what § 2.2
        // forbids. This sheet carries a `Type.outcome` field and two menus, the same shape as the
        // start panel, so it takes the same width.
        .frame(width: Layout.startPanelSheetWidth)
        .background(Surface.canvas)
        .defaultFocus($isTitleFocused, true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isFromSession ? "Log what you delivered" : "Add an accomplishment")
    }

    private static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    // MARK: - Fields

    /// The one required field, and the only one set at `Type.outcome`. Return commits, which is what
    /// makes logging something a two-second act rather than a form.
    private var titleField: some View {
        field("What happened") {
            TextField("Reviewed the ingest retry PR", text: $title)
                .textFieldStyle(.plain)
                .font(Type.outcome)
                .focused($isTitleFocused)
                .onSubmit(save)
                .padding(Space.m)
                .background(Surface.sunken, in: Theme.cardShape)
                .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
        }
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(label)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var typePicker: some View {
        Picker("Type", selection: $type) {
            ForEach(AccomplishmentType.allCases) { option in
                Label(option.displayName, systemImage: option.symbolName)
                    .tag(option)
            }
        }
        .labelsHidden()
        .font(Type.body)
    }

    private var projectPicker: some View {
        Picker("Project", selection: $projectID) {
            Text("No project").tag(UUID?.none)
            ForEach(selectableProjects) { project in
                Text(project.name).tag(UUID?.some(project.id))
            }
        }
        .labelsHidden()
        .font(Type.body)
    }

    /// Active projects, plus whichever one this record already belongs to. An inactive project stays
    /// selectable while it is selected, so opening an old row and pressing Save cannot silently
    /// reassign it.
    private var selectableProjects: [Project] {
        projects.filter { $0.isActive || $0.id == projectID }
    }

    // MARK: - Saving

    private var trimmedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canSave: Bool { trimmedTitle != nil }

    private func save() {
        guard let trimmedTitle else { return }
        let trimmedDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)

        var updated = seed
        updated.title = trimmedTitle
        updated.type = type
        updated.projectID = projectID
        updated.details = trimmedDetails.isEmpty ? nil : trimmedDetails
        updated.timestamp = timestamp
        onSave(updated)
    }
}
