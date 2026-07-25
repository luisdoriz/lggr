import SwiftUI
import LggrKit

// The project field of the start panel. See docs/_design/04-screens.md § 5.2.
//
// Starting without a project is fully supported and is never flagged: "No project" is the first item
// in the menu, not a fallback the app complains about.

/// The project menu: a coloured dot, the project's name, and a chevron.
///
/// It is a `Menu` of `Toggle`s rather than a hand-rolled popup so that the whole AppKit menu
/// behaviour comes for free — `Space`/`↓` opens, type-to-select jumps, `↑`/`↓` browses, `Return`
/// commits, `Escape` closes — which is exactly the interaction § 5.2 specifies and none of which we
/// would get right by hand.
@MainActor
public struct ProjectPicker: View {

    private let projects: [Project]
    @Binding private var selection: UUID?
    private let onCreateProject: (() -> Void)?

    /// - Parameter onCreateProject: when supplied, the menu ends with `New Project…`. Omit it in
    ///   hosts that cannot present the project editor.
    public init(
        projects: [Project],
        selection: Binding<UUID?>,
        onCreateProject: (() -> Void)? = nil
    ) {
        self.projects = projects
        self._selection = selection
        self.onCreateProject = onCreateProject
    }

    public var body: some View {
        Menu {
            Toggle("No project", isOn: binding(for: nil))

            if !menuProjects.isEmpty {
                Divider()
                ForEach(menuProjects) { project in
                    Toggle(project.normalizedName ?? "Untitled", isOn: binding(for: project.id))
                }
            }

            if let onCreateProject {
                Divider()
                Button("New Project…", action: onCreateProject)
            }
        } label: {
            StartPanelFieldChrome {
                ProjectDot(project: selectedProject)
                Text(selectedProject?.normalizedName ?? "No project")
                    .foregroundStyle(selectedProject == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Project")
        .accessibilityValue(selectedProject?.normalizedName ?? "No project")
    }

    private var selectedProject: Project? {
        guard let selection else { return nil }
        return projects.first { $0.id == selection }
    }

    /// Active projects, plus the selected one even if it has since been archived — a session already
    /// filed under an archived project must still show which project that is.
    private var menuProjects: [Project] {
        projects.filter { $0.isActive || $0.id == selection }
    }

    /// A `Toggle` in a macOS menu renders as a checkable item. Turning one *off* is meaningless here,
    /// so the setter only ever acts on selection.
    private func binding(for id: UUID?) -> Binding<Bool> {
        Binding(
            get: { selection == id },
            set: { isOn in
                guard isOn else { return }
                selection = id
            }
        )
    }
}

// MARK: - Shared chrome

/// The closed-state chrome shared by the start panel's menus: quiet by default, `Surface.hover` on
/// hover, `Radius.chip`, and a small trailing chevron.
///
/// It lives here because `ProjectPicker` and `WorkTypePicker` must be indistinguishable in weight —
/// they sit on the same line and neither is more important than the other.
@MainActor
struct StartPanelFieldChrome<Content: View>: View {

    @State private var isHovering = false

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Space.xs) {
            content
            Image(systemName: Icon.disclosureOpen)
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .font(Type.secondary)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(isHovering ? Surface.hover : Color.clear, in: Theme.chipShape)
        .contentShape(Theme.chipShape)
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
    }
}
