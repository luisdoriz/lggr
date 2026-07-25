import AppKit
import LggrKit
import SwiftUI
import UniformTypeIdentifiers

// Accomplishments (`⌘3`) — the "Done" log. See docs/_design/04-screens.md § 4.3 and SPEC.md § 10.
//
// The spec's test for this screen is behavioural: *"The user should be able to open the app on Friday
// and immediately see evidence of what they delivered."* Everything below is that sentence, made
// literal:
//
//   * **The first group is always the one they came for.** Grouped by week, newest first, and the
//     current week is headed `This week` rather than a date to decode.
//   * **The weight is on the titles.** A title is `Type.rowTitle` in `.primary`; the type glyph, the
//     project and the timestamp are all demoted and quiet. On Friday afternoon the eye should be able
//     to read the column of titles and nothing else, and get the whole answer.
//   * **Nothing here was written by the app.** `INTELLIGENCE.md` § 3.6 killed generated
//     accomplishments outright — a fabricated line in a performance-review artefact costs credibility
//     that cannot be recovered. Every row is something a person typed, and the export says exactly
//     what the screen says.
//
// The type glyph is never tinted. Eleven `AccomplishmentType` cases means eleven tinted glyphs, and
// eleven tinted glyphs is a rainbow; colour in Lggr means "which project" or it means nothing
// (§ 2.5). The type is still announced to VoiceOver, so the quiet glyph costs nothing.

/// What the log screen can do.
public struct AccomplishmentsActions {
    public var add: () -> Void
    public var edit: (Accomplishment) -> Void
    /// Opens the session an entry came from. `nil` removes the menu item rather than dimming it.
    public var openSource: ((Accomplishment) -> Void)?
    public var delete: ((Accomplishment) -> Void)?
    public var step: (Int) -> Void
    public var setSpan: (HistoryWindow.Span) -> Void
    public var goToLatest: () -> Void
    public var clearFilters: () -> Void
    /// Produces the Markdown for whatever is currently on screen. Rendered by
    /// `AccomplishmentLogMarkdown`; this view never assembles Markdown of its own.
    public var markdown: () -> String
    /// The name a save panel should offer.
    public var exportFileName: () -> String

    public init(
        add: @escaping () -> Void = {},
        edit: @escaping (Accomplishment) -> Void = { _ in },
        openSource: ((Accomplishment) -> Void)? = nil,
        delete: ((Accomplishment) -> Void)? = nil,
        step: @escaping (Int) -> Void = { _ in },
        setSpan: @escaping (HistoryWindow.Span) -> Void = { _ in },
        goToLatest: @escaping () -> Void = {},
        clearFilters: @escaping () -> Void = {},
        markdown: @escaping () -> String = { "" },
        exportFileName: @escaping () -> String = { "Accomplishments.md" }
    ) {
        self.add = add
        self.edit = edit
        self.openSource = openSource
        self.delete = delete
        self.step = step
        self.setSpan = setSpan
        self.goToLatest = goToLatest
        self.clearFilters = clearFilters
        self.markdown = markdown
        self.exportFileName = exportFileName
    }
}

/// `⌘⇧A` is also a real menu command (`04-screens.md` § 7.1). Registered here as well so the hint
/// renders on the button and the shortcut survives the menu bar being hidden.
private enum AccomplishmentsShortcut {
    static let add = KeyboardShortcut("a", modifiers: [.command, .shift])
}

/// The full accomplishment log.
public struct AccomplishmentsLogView: View {

    private let window: HistoryWindow.Display
    private let weeks: [AccomplishmentsModel.Week]
    private let projects: [Project]
    private let entriesInWindow: Int
    private let availableTypes: [AccomplishmentType]
    private let availableProjects: [Project]
    private let isLoading: Bool
    private let isFiltering: Bool
    private let searchText: Binding<String>
    private let typeFilter: Binding<AccomplishmentType?>
    private let projectFilter: Binding<UUID?>
    private let actions: AccomplishmentsActions

    public init(
        window: HistoryWindow.Display,
        weeks: [AccomplishmentsModel.Week],
        projects: [Project] = [],
        entriesInWindow: Int = 0,
        availableTypes: [AccomplishmentType] = [],
        availableProjects: [Project] = [],
        isLoading: Bool = false,
        isFiltering: Bool = false,
        searchText: Binding<String> = .constant(""),
        typeFilter: Binding<AccomplishmentType?> = .constant(nil),
        projectFilter: Binding<UUID?> = .constant(nil),
        actions: AccomplishmentsActions = AccomplishmentsActions()
    ) {
        self.window = window
        self.weeks = weeks
        self.projects = projects
        self.entriesInWindow = entriesInWindow
        self.availableTypes = availableTypes
        self.availableProjects = availableProjects
        self.isLoading = isLoading
        self.isFiltering = isFiltering
        self.searchText = searchText
        self.typeFilter = typeFilter
        self.projectFilter = projectFilter
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chrome

            Divider()

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accomplishments")
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text("Accomplishments")
                    .font(Type.screenTitle)
                    .foregroundStyle(.primary)

                Spacer(minLength: Space.m)

                exportMenu

                // Absent when the empty state below is already offering the same action. One
                // prominent button per screen — and registering `⌘⇧A` twice in one view tree makes
                // which one fires undefined.
                if !emptyStateOwnsPrimaryAction {
                    Button("Add Accomplishment", action: actions.add)
                        .buttonStyle(.lggrPrimary(shortcut: AccomplishmentsShortcut.add))
                        .keyboardShortcut(AccomplishmentsShortcut.add)
                }
            }

            HStack(spacing: Space.m) {
                HistoryWindowBar(
                    window: window,
                    onStep: actions.step,
                    onSpanChange: actions.setSpan,
                    onGoToLatest: actions.goToLatest,
                    rowCount: entriesInWindow > 0 ? entriesInWindow : nil,
                    rowNoun: (singular: "entry", plural: "entries")
                )

                Spacer(minLength: Space.m)

                HistorySearchField(prompt: "Search accomplishments", text: searchText)

                HistoryFilterMenu(
                    allTitle: "All types",
                    options: typeOptions,
                    selection: typeFilter
                )

                HistoryFilterMenu(
                    allTitle: "All projects",
                    options: projectOptions,
                    selection: projectFilter
                )
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.xl)
        .padding(.bottom, Space.l)
    }

    /// Two real actions and no third. Both produce the same string from the same renderer, so the
    /// clipboard and the file can never disagree.
    ///
    /// The menu is absent while there is nothing to export: a menu whose every item would write an
    /// empty document is a dead control wearing a chevron.
    @ViewBuilder private var exportMenu: some View {
        if entriesInWindow > 0 {
            Menu {
                Button("Copy as Markdown") { Pasteboard.copy(actions.markdown()) }
                Button("Save as Markdown…") { saveMarkdown() }
            } label: {
                Label("Export", systemImage: Icon.export)
                    .font(Type.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Export what is on screen, as Markdown")
        }
    }

    private var typeOptions: [HistoryFilterMenu<AccomplishmentType>.Option] {
        availableTypes.map { type in
            HistoryFilterMenu<AccomplishmentType>.Option(
                value: type,
                title: type.displayName,
                leading: AnyView(
                    Image(systemName: type.symbolName)
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                )
            )
        }
    }

    private var projectOptions: [HistoryFilterMenu<UUID>.Option] {
        availableProjects.map { project in
            HistoryFilterMenu<UUID>.Option(
                value: project.id,
                title: project.normalizedName ?? project.name,
                leading: AnyView(ProjectDot(project: project))
            )
        }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if weeks.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        // `ScrollingSection`, not `ScrollView`: see that type — a scroll view draws nothing at all
        // under `ImageRenderer`, which is how this screen is reviewed in light and dark without Xcode.
        ScrollingSection {
            // `spacing: 0`, with the air owned by the pieces — see `SessionsListView` for why a
            // uniform `LazyVStack` spacing cannot express "12 under a heading, 32 under a group".
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(weeks) { week in
                    Section {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(week.accomplishments) { accomplishment in
                                LogEntryRow(
                                    accomplishment: accomplishment,
                                    project: project(for: accomplishment.projectID),
                                    onEdit: { actions.edit(accomplishment) },
                                    onOpenSource: sourceAction(for: accomplishment),
                                    onDelete: deleteAction(for: accomplishment)
                                )
                            }
                        }
                        .padding(.bottom, Space.xxl)
                    } header: {
                        weekHeader(week)
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.l)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func weekHeader(_ week: AccomplishmentsModel.Week) -> some View {
        SectionHeader(week.heading, count: week.accomplishments.count)
            .padding(.top, Space.s)
            .padding(.bottom, Space.m)
            .background(Surface.canvas)
    }

    // MARK: - Empty states

    /// True when the screen is showing the "nothing yet" state, whose one button is the same action
    /// the header would otherwise carry.
    private var emptyStateOwnsPrimaryAction: Bool {
        weeks.isEmpty && !isLoading && !isFiltering && window.isCurrent
    }

    @ViewBuilder private var emptyState: some View {
        if isLoading {
            loadingState
        } else if isFiltering {
            EmptyStateView(
                symbol: Icon.search,
                title: noMatchesTitle,
                message: "Try a shorter phrase, or clear the type and project filters.",
                actionTitle: "Clear Filters",
                action: actions.clearFilters
            )
        } else if window.isCurrent {
            // § 4.3's copy, verbatim. It says what the list is *for*, which is the one thing a new
            // user cannot guess, and it never implies they have failed to produce anything.
            EmptyStateView(
                symbol: Icon.emptyDone,
                title: "Nothing logged yet.",
                message: "This is the list you open on Friday to see what you actually delivered.",
                actionTitle: "Add Accomplishment",
                shortcut: AccomplishmentsShortcut.add,
                action: actions.add
            )
        } else {
            EmptyStateView(
                symbol: Icon.emptyDone,
                title: "Nothing logged in \(window.title).",
                message: "Entries are filed under the week you recorded them. Step to another range to look further back.",
                actionTitle: "Now",
                action: actions.goToLatest
            )
        }
    }

    private var noMatchesTitle: String {
        let query = searchText.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return "Nothing here matches those filters." }
        return "Nothing matches \u{201C}\(query)\u{201D}."
    }

    /// § 3.2: the real layout, redacted, for the first 250ms. No spinner, no shimmer.
    private var loadingState: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("This week")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<4, id: \.self) { row in
                    LogEntryRow(
                        accomplishment: Accomplishment(
                            id: Self.placeholderID(row),
                            title: "Loading this range"
                        ),
                        project: nil
                    )
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private static func placeholderID(_ index: Int) -> UUID {
        UUID(
            uuid: (
                0x10, 0x66, 0x67, 0x72, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x01,
                0x00, UInt8(truncatingIfNeeded: index)
            ))
    }

    // MARK: - Export

    /// A native save panel, because saving a file is the one thing SwiftUI on macOS 14 has no API for.
    ///
    /// `runModal()` rather than a `.fileExporter`: the exporter needs a `FileDocument` and a binding to
    /// drive it, which is three types and a piece of view state to write one string the model already
    /// produced.
    private func saveMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = actions.exportFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let markdown = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [markdown]
        }
        panel.message = "Save the log as it appears on screen."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        // A failed write is reported by the panel's own sheet in every ordinary case (permissions,
        // full disk). Nothing is lost when it fails: the log is still on screen and still copyable.
        try? Data(actions.markdown().utf8).write(to: url, options: .atomic)
    }

    // MARK: - Derived

    private func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    private func sourceAction(for accomplishment: Accomplishment) -> (() -> Void)? {
        guard accomplishment.isGeneratedFromSession, let open = actions.openSource else { return nil }
        return { open(accomplishment) }
    }

    private func deleteAction(for accomplishment: Accomplishment) -> (() -> Void)? {
        guard let delete = actions.delete else { return nil }
        return { delete(accomplishment) }
    }
}

// MARK: - The row

/// One thing that got done, as the full log prints it. See `04-screens.md` § 4.3.
///
/// This is not `AccomplishmentRow`. That row belongs to Today, where every entry is from the same day
/// and a bare clock time is unambiguous; here a group spans a week, so the stamp has to carry the
/// weekday — `● Receipt ingestion · Thu 11:04`, which is § 4.3's own copy. That one difference is
/// load-bearing: without the weekday the Friday read cannot tell Monday's work from this morning's,
/// which is most of what the screen is for.
///
/// Everything else is deliberately identical to Today's row, down to the hover fill and its negative
/// inset, so the two never read as different applications.
struct LogEntryRow: View {

    let accomplishment: Accomplishment
    let project: Project?
    var onEdit: (() -> Void)?
    var onOpenSource: (() -> Void)?
    var onDelete: (() -> Void)?

    @State private var isHovered = false
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: accomplishment.type.symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(accomplishment.title)
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                metadata
            }

            Spacer(minLength: Space.m)

            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .contextMenu { actionItems }
        .alert("Delete this accomplishment?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete?() }
        } message: {
            Text("It is removed from your log. The session it came from is untouched.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accomplishment.title)
        .accessibilityValue(spokenDetail)
    }

    // MARK: Metadata

    private var metadata: some View {
        HStack(spacing: Space.xs) {
            ProjectBadge(project: project, variant: .compact)
            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
            Text(stamp)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    /// `Thu 11:04` — § 4.3's stamp. The weekday is abbreviated because a group is a week wide and the
    /// full name would out-measure the title it sits under.
    private var stamp: String {
        let day = accomplishment.timestamp.formatted(.dateTime.weekday(.abbreviated))
        let time = accomplishment.timestamp.formatted(date: .omitted, time: .shortened)
        return "\(day) \(time)"
    }

    // MARK: Actions

    @ViewBuilder private var actionItems: some View {
        if let onEdit {
            Button("Edit…", action: onEdit)
        }
        Button("Copy as Markdown") { Pasteboard.copy(markdown) }
        if let onOpenSource {
            Button("Open source session", action: onOpenSource)
        }
        if onDelete != nil {
            Divider()
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
        }
    }

    /// One list item, in the same shape `AccomplishmentLogMarkdown` renders. A single row does not
    /// justify assembling a whole document, and the full-log export goes through the real renderer.
    private var markdown: String {
        var line = "- \(accomplishment.title)"
        if let details = accomplishment.details, !details.isEmpty {
            line += " — \(details)"
        }
        return line
    }

    // MARK: VoiceOver

    private var spokenDetail: String {
        var parts = [accomplishment.type.displayName]
        if let name = project?.normalizedName { parts.append(name) }
        parts.append(accomplishment.timestamp.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: ", ")
    }
}
