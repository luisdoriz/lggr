import LggrKit
import SwiftUI

/// Create or rename a project, give it a colour and an icon, and retire it. See `04-screens.md` § 4.5.
///
/// Four fields and two buttons. There is no description field, no parent project and no archive date,
/// because a project in Lggr is a label on a stream of work, not a planning artefact.
///
/// The editor never touches the store. It hands a finished `Project` value to `onSave` and the host
/// decides what to do with it, which is what lets the same view be exercised against fixtures.
public struct ProjectEditor: View {

    private let existing: Project?
    private let onSave: (Project) -> Void
    private let onCancel: () -> Void

    @Environment(\.clock) private var clock

    @State private var name: String
    @State private var colorID: String
    @State private var iconID: String
    @State private var isActive: Bool

    @FocusState private var isNameFocused: Bool

    /// `project == nil` creates; anything else edits in place, preserving `id` and `createdAt`.
    public init(
        project: Project?,
        onSave: @escaping (Project) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.existing = project
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: project?.name ?? "")
        _colorID = State(initialValue: project?.colorID ?? Project.defaultColorID)
        _iconID = State(initialValue: project?.iconID ?? Project.defaultIconID)
        _isActive = State(initialValue: project?.isActive ?? true)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(existing == nil ? "New Project" : "Edit Project")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.l) {
                GridRow(alignment: .firstTextBaseline) {
                    label("Name")
                        .gridColumnAlignment(.trailing)
                    TextField("SOR engineering", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(Type.body)
                        .focused($isNameFocused)
                        .onSubmit(save)
                }

                GridRow(alignment: .top) {
                    label("Colour")
                    colourPicker
                }

                GridRow(alignment: .top) {
                    label("Icon")
                    iconPicker
                }

                GridRow(alignment: .firstTextBaseline) {
                    // An empty label cell keeps the checkbox on the control column, where every
                    // other input on this sheet begins.
                    Text(verbatim: "")
                    Toggle("Active", isOn: $isActive)
                        .toggleStyle(.checkbox)
                        .font(Type.body)
                }
            }

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
        .frame(width: Layout.projectEditorWidth)
        .background(Surface.canvas)
        .defaultFocus($isNameFocused, true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(existing == nil ? "New Project" : "Edit Project")
    }

    private static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    // MARK: - Pieces

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Type.body)
            .foregroundStyle(.secondary)
    }

    /// Nine swatches. `LazyVGrid` with an adaptive column rather than an `HStack`, so the row wraps
    /// instead of overflowing when the labels are wider at an accessibility text size.
    private var colourPicker: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Layout.projectSwatchSize), spacing: Space.s)],
            alignment: .leading,
            spacing: Space.s
        ) {
            ForEach(Project.colorIDs, id: \.self) { id in
                Button {
                    colorID = id
                } label: {
                    ColourSwatch(colorID: id, isSelected: colorID == id)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Palette.projectColorName(id))
                .accessibilityAddTraits(colorID == id ? [.isSelected] : [])
            }
        }
    }

    private var iconPicker: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: Layout.projectSwatchSize), spacing: Space.s)],
            alignment: .leading,
            spacing: Space.s
        ) {
            ForEach(Project.iconIDs, id: \.self) { id in
                Button {
                    iconID = id
                } label: {
                    Image(systemName: id)
                        .imageScale(.medium)
                        .foregroundStyle(
                            iconID == id
                                ? AnyShapeStyle(Palette.project(colorID))
                                : AnyShapeStyle(.secondary)
                        )
                        .frame(width: Layout.projectSwatchSize, height: Layout.projectSwatchSize)
                        .background(
                            iconID == id ? Surface.selected : Color.clear,
                            in: Theme.chipShape
                        )
                        .contentShape(Theme.chipShape)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(id)
                .accessibilityAddTraits(iconID == id ? [.isSelected] : [])
            }
        }
    }

    // MARK: - Saving

    private var trimmedName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Disabled, never red and never accompanied by an error message. Validation in Lggr is "the
    /// button is not ready yet", not "you did something wrong".
    private var canSave: Bool { trimmedName != nil }

    private func save() {
        guard let trimmedName else { return }
        let now = clock.now

        if var project = existing {
            project.name = trimmedName
            project.colorID = colorID
            project.iconID = iconID
            project.isActive = isActive
            project.updatedAt = now
            onSave(project)
        } else {
            onSave(
                Project(
                    name: trimmedName,
                    colorID: colorID,
                    iconID: iconID,
                    isActive: isActive,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
    }
}

// MARK: - Swatch

/// One 28pt colour swatch in the picker.
///
/// Selection is carried by a ring drawn *outside* the circle as well as by the checkmark inside it.
/// The ring is the load-bearing signal: a white checkmark is legible on blue, purple and red but not
/// on yellow, and no single foreground colour reads on all nine. A shape that is either there or not
/// works on every one of them, and works for a colour-blind user too.
struct ColourSwatch: View {

    let colorID: String
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Palette.project(colorID))
            .frame(width: Layout.projectSwatchSize, height: Layout.projectSwatchSize)
            .overlay(
                Circle().strokeBorder(Stroke.projectDot, lineWidth: Stroke.projectDotWidth)
            )
            .overlay(checkmark)
            .overlay(ring)
            .lggrAnimation(Motion.tap, value: isSelected)
    }

    @ViewBuilder private var checkmark: some View {
        if isSelected {
            Image(systemName: Icon.selected)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var ring: some View {
        if isSelected {
            Circle()
                .strokeBorder(Color.primary.opacity(0.7), lineWidth: 2)
                .padding(-3)
                .accessibilityHidden(true)
        }
    }
}
