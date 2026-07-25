import LggrKit
import SwiftUI

// Projects. See docs/_design/04-screens.md § 4.5.
//
// Projects are optional in Lggr — a session can be started without one — so this screen never
// pressures the user into creating any. It offers one obvious action, lists what exists, and hides
// everything else behind hover and a context menu.

/// This week's usage of one project, as the row's second line.
///
/// Passed in rather than derived here: aggregating a week of sessions is a `[P4]` job
/// (`DailyDigest`, `WeeklyReviewBuilder`), and `SessionManager` only publishes *today*. When a
/// project has no entry the second line is simply absent — the screen says nothing rather than
/// printing a row of zeros at somebody.
public struct ProjectUsage: Hashable, Sendable {
    public var sessionCount: Int
    public var focusedDuration: TimeInterval

    public init(sessionCount: Int, focusedDuration: TimeInterval) {
        self.sessionCount = sessionCount
        self.focusedDuration = focusedDuration
    }

    /// `12 sessions · 8h 24m this week`, or `No sessions this week`.
    public var summaryLine: String {
        guard sessionCount > 0 else { return "No sessions this week" }
        let sessions = sessionCount == 1 ? "1 session" : "\(sessionCount) sessions"
        return "\(sessions) · \(DurationFormatting.compact(focusedDuration)) this week"
    }
}

/// `⌘N` is New Project while Projects is the selected section (`04-screens.md` § 7.1).
private enum ProjectsShortcut {
    static let newProject = KeyboardShortcut("n", modifiers: .command)
}

public struct ProjectsView: View {

    private let projects: [Project]
    private let usage: [UUID: ProjectUsage]
    private let onNewProject: () -> Void
    private let onEditProject: (Project) -> Void
    private let onSaveProject: (Project) -> Void
    private let onDeleteProject: (UUID) -> Void

    @Environment(\.clock) private var clock

    @State private var showsInactive = false
    @State private var selection: UUID?
    @State private var projectPendingDeletion: Project?

    public init(
        projects: [Project],
        usage: [UUID: ProjectUsage] = [:],
        onNewProject: @escaping () -> Void = {},
        onEditProject: @escaping (Project) -> Void = { _ in },
        onSaveProject: @escaping (Project) -> Void = { _ in },
        onDeleteProject: @escaping (UUID) -> Void = { _ in }
    ) {
        self.projects = projects
        self.usage = usage
        self.onNewProject = onNewProject
        self.onEditProject = onEditProject
        self.onSaveProject = onSaveProject
        self.onDeleteProject = onDeleteProject
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.l)

            if projects.isEmpty {
                emptyState
            } else if visibleProjects.isEmpty {
                allInactiveState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            presenting: projectPendingDeletion
        ) { project in
            Button("Cancel", role: .cancel) { projectPendingDeletion = nil }
            Button("Delete Project", role: .destructive) {
                onDeleteProject(project.id)
                projectPendingDeletion = nil
            }
        } message: { _ in
            // Verbatim from § 10.9, and it is exact rather than reassuring-sounding: `deleteProject`
            // nullifies references instead of cascading, so the history really does survive.
            Text("Sessions and accomplishments keep their history and lose the project label. Nothing is deleted.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Projects")
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            Text("Projects")
                .font(Type.screenTitle)
                .foregroundStyle(.primary)

            Spacer(minLength: Space.m)

            // Progressive disclosure: the toggle only exists once there is something for it to
            // reveal. An empty control that can never change anything is noise.
            if hasInactiveProjects {
                Toggle("Show inactive", isOn: $showsInactive)
                    .toggleStyle(.checkbox)
                    .font(Type.secondary)
            }

            Button("New Project", action: onNewProject)
                .buttonStyle(.lggrPrimary(shortcut: ProjectsShortcut.newProject))
                .keyboardShortcut(ProjectsShortcut.newProject)
        }
    }

    // MARK: - List

    private var list: some View {
        List(visibleProjects, selection: $selection) { project in
            ProjectRow(
                project: project,
                usage: usage[project.id],
                onToggleActive: { setActive($0, on: project) }
            )
            .listRowSeparator(.visible)
            .listRowSeparatorTint(Stroke.separator)
            .contextMenu { actionItems(for: project) }
            // Double-click is the native "open this row" gesture on macOS, and editing is the only
            // thing a project row can be opened into.
            .onTapGesture(count: 2) { onEditProject(project) }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand(perform: deleteSelection)
    }

    // MARK: - Empty states

    private var emptyState: some View {
        EmptyStateView(
            symbol: Icon.emptyProjects,
            title: "No projects yet.",
            message: emptyMessage,
            actionTitle: "New Project",
            action: onNewProject
        )
    }

    /// § 10.9's copy runs to three lines at the empty state's 340pt text column, and `EmptyStateView`
    /// caps its message at two. Rather than truncate a sentence the design document sets verbatim,
    /// the clause the user needs first is kept and the parenthetical is dropped.
    private var emptyMessage: String {
        "Projects are optional, but they're how the weekly review splits your time."
    }

    private var allInactiveState: some View {
        EmptyStateView(
            symbol: Icon.emptyProjects,
            title: "Nothing active right now.",
            message: "Turn on Show inactive to see the rest.",
            actionTitle: "New Project",
            action: onNewProject
        )
    }

    // MARK: - Actions

    @ViewBuilder private func actionItems(for project: Project) -> some View {
        Button("Edit…") { onEditProject(project) }
        Button("Duplicate") { duplicate(project) }
        Button(project.isActive ? "Mark Inactive" : "Mark Active") {
            setActive(!project.isActive, on: project)
        }
        Divider()
        Button("Delete Project", role: .destructive) { projectPendingDeletion = project }
    }

    private func setActive(_ isActive: Bool, on project: Project) {
        guard project.isActive != isActive else { return }
        var updated = project
        updated.isActive = isActive
        updated.updatedAt = clock.now
        onSaveProject(updated)
    }

    private func duplicate(_ project: Project) {
        let copy = Project(
            name: "\(project.name) copy",
            colorID: project.colorID,
            iconID: project.iconID,
            isActive: project.isActive,
            createdAt: clock.now,
            updatedAt: clock.now
        )
        onSaveProject(copy)
    }

    /// `⌘⌫` on the selected row (`04-screens.md` § 7.1). It routes through the same confirmation as
    /// the menu item; nothing in Lggr deletes on a keystroke alone.
    private func deleteSelection() {
        guard let selection, let project = projects.first(where: { $0.id == selection }) else { return }
        projectPendingDeletion = project
    }

    // MARK: - Derived

    private var visibleProjects: [Project] {
        showsInactive ? projects : projects.filter(\.isActive)
    }

    private var hasInactiveProjects: Bool {
        projects.contains { !$0.isActive }
    }

    private var deletionTitle: String {
        // Typographic quotes, because this string is set in the alert's own title style and a
        // straight double quote is a typewriter artefact.
        "Delete \u{201C}\(projectPendingDeletion?.normalizedName ?? "this project")\u{201D}?"
    }
}

// MARK: - Row

/// A project row: colour dot, its own symbol, its name, and what it cost this week.
///
/// The dot is always followed by the name, so colour is never the only carrier of "which project"
/// and colour blindness costs nothing (`04-screens.md` § 2.5).
struct ProjectRow: View {

    let project: Project
    let usage: ProjectUsage?
    let onToggleActive: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            ProjectDot(colorID: project.colorID)

            Image(systemName: project.iconID)
                .imageScale(.medium)
                .foregroundStyle(Palette.project(project.colorID))
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(project.name)
                        .font(Type.rowTitle)
                        .foregroundStyle(
                            project.isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !project.isActive {
                        Text("Inactive")
                            .font(Type.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let usage {
                    Text(usage.summaryLine)
                        .font(Type.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Space.m)

            // Revealed on hover, kept in the layout at zero opacity so the row never reflows under
            // the pointer.
            Toggle("Active", isOn: Binding(get: { project.isActive }, set: onToggleActive))
                .toggleStyle(.checkbox)
                .font(Type.secondary)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
                .lggrAnimation(Motion.tap, value: isHovered)
        }
        .padding(.vertical, Space.s)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(project.normalizedName ?? "Untitled project")
        .accessibilityValue(spokenDetail)
    }

    private var spokenDetail: String {
        var parts = [Palette.projectColorName(project.colorID)]
        if let usage { parts.append(usage.summaryLine) }
        if !project.isActive { parts.append("Inactive") }
        return parts.joined(separator: ", ")
    }
}
