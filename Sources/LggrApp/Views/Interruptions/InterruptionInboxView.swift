import LggrKit
import SwiftUI

// The interruption inbox. See SPEC.md § 3 and § 7, 04-screens.md § 4.1's Interruptions section.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  AN INBOX THAT ONLY ACCUMULATES IS A GUILT PILE
//
//  This screen has one job that is not "show a list": it has to make emptying itself feel like
//  progress. Four decisions carry that:
//
//    1. **One visible verb per row, three more one keystroke or one menu away.** The row's primary
//       control is `Start session` — the interruption becomes tracked work in its own words. The
//       rest (log what it turned into, file it under a project, dismiss it) sit in the row's menu,
//       which is also its context menu, so mouse and keyboard reach the identical five items.
//    2. **Dismissing is a first-class outcome, not a failure.** `LggrKit` says so in
//       `InterruptionStatus.dismissed`'s own documentation: deciding something does not need doing
//       is an outcome. So there is no confirmation dialogue, no red, and no word like "ignore".
//    3. **Everything processed is reversible while the app is open.** `Processed` is a closed
//       disclosure under the list; each row in it offers `Put back`. That is what earns decision 2:
//       dismissing is easy *because* it is not final.
//    4. **No count of what you failed to process.** No age, no "waiting 3 days", no badge that
//       grows. The rows carry the time they were captured and nothing else — evidence, not a score
//       (`INTELLIGENCE.md` § 3.4).
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// What the inbox can do. Every one of these is wired by the host; the view owns no behaviour and
/// can therefore be rendered, in full, against plain values with no store.
///
/// `delete` is optional for the same reason Today's is: when the host cannot perform it, the menu
/// item is absent rather than present and inert.
public struct InterruptionInboxActions {
    public var capture: () -> Void
    public var convertToSession: (Interruption) -> Void
    public var logAccomplishment: (Interruption) -> Void
    public var fileUnderProject: (Interruption, UUID?) -> Void
    public var dismiss: (Interruption) -> Void
    public var returnToInbox: (Interruption) -> Void
    public var delete: ((Interruption) -> Void)?
    public var dismissFailure: () -> Void

    public init(
        capture: @escaping () -> Void = {},
        convertToSession: @escaping (Interruption) -> Void = { _ in },
        logAccomplishment: @escaping (Interruption) -> Void = { _ in },
        fileUnderProject: @escaping (Interruption, UUID?) -> Void = { _, _ in },
        dismiss: @escaping (Interruption) -> Void = { _ in },
        returnToInbox: @escaping (Interruption) -> Void = { _ in },
        delete: ((Interruption) -> Void)? = nil,
        dismissFailure: @escaping () -> Void = {}
    ) {
        self.capture = capture
        self.convertToSession = convertToSession
        self.logAccomplishment = logAccomplishment
        self.fileUnderProject = fileUnderProject
        self.dismiss = dismiss
        self.returnToInbox = returnToInbox
        self.delete = delete
        self.dismissFailure = dismissFailure
    }
}

/// The inbox as a place: a heading, the waiting rows, and what has already been dealt with.
@MainActor
public struct InterruptionInboxView: View {

    private let interruptions: [Interruption]
    private let processed: [Interruption]
    private let projects: [Project]
    private let failure: String?
    private let actions: InterruptionInboxActions

    @State private var showsProcessed = false
    @FocusState private var focusedRow: UUID?

    public init(
        interruptions: [Interruption],
        processed: [Interruption] = [],
        projects: [Project] = [],
        failure: String? = nil,
        actions: InterruptionInboxActions = InterruptionInboxActions()
    ) {
        self.interruptions = interruptions
        self.processed = processed
        self.projects = projects
        self.failure = failure
        self.actions = actions
    }

    static let captureShortcut = KeyboardShortcut("i", modifiers: [.command, .shift])

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)

            if let failure {
                ErrorBanner(
                    message: failure,
                    recoveryTitle: nil,
                    onRecover: {},
                    onDismiss: actions.dismissFailure
                )
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.l)
            }

            if interruptions.isEmpty && processed.isEmpty {
                empty
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .lggrAnimation(Motion.settle, value: interruptions.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interruptions")
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text("Interruptions")
                    .font(Type.screenTitle)
                    .foregroundStyle(.primary)

                Spacer(minLength: Space.m)

                // The screen's one primary action. Capturing from inside the inbox is not a strange
                // thing to want: this is the screen people are on when the next thing arrives.
                Button("Capture", action: actions.capture)
                    .buttonStyle(.lggrPrimary(shortcut: Self.captureShortcut))
            }

            // States what the list is, without telling the user what to do about it.
            Text("Written down without stopping what you were doing. Deal with them when it suits you.")
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - The list

    private var content: some View {
        // `ScrollingSection`, not `ScrollView`: identical in the app, and the difference is what
        // makes this screen visible to `LggrApp --snapshot`. See `ScrollingSection`.
        ScrollingSection {
            VStack(alignment: .leading, spacing: Space.xxl) {
                if interruptions.isEmpty {
                    emptyWaiting
                } else {
                    waiting
                }

                if !processed.isEmpty {
                    processedSection
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Waiting", count: interruptions.count)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ordered) { interruption in
                    InterruptionRow(
                        interruption: interruption,
                        project: project(for: interruption.convertedProjectID),
                        projects: selectableProjects,
                        isFocused: focusedRow == interruption.id,
                        actions: actions
                    )
                    .focusable()
                    .focused($focusedRow, equals: interruption.id)
                    .focusEffectDisabled()
                    // Attached to the focused row rather than registered as a shortcut on the
                    // screen: a bare `Return` shortcut would still be live underneath the capture
                    // panel, where `Return` means "save this note" and nothing else.
                    .onKeyPress { press in handle(press, for: interruption) }
                }
            }
            // Arrow keys move between rows, the same chain the popover installs. macOS limits
            // keyboard navigation to text fields and lists unless the user changes a System Settings
            // toggle, and we never ask them to (§ 7.2) — so the first row takes focus on arrival and
            // the whole screen is workable from there without a mouse ever being involved.
            .onMoveCommand { move($0) }
            .defaultFocus($focusedRow, ordered.first?.id)

            Text("⏎ starts a session on the selected line. ⌘⌫ takes it off the list.")
                .font(Type.caption)
                .foregroundStyle(Ink.support)
                .padding(.top, Space.xs)
        }
    }

    /// Already dealt with, closed by default. It exists so dismissing can be casual: the way back is
    /// one disclosure away for as long as the app is open.
    private var processedSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            DisclosureGroup(isExpanded: $showsProcessed) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(processed) { interruption in
                        ProcessedInterruptionRow(
                            interruption: interruption,
                            project: project(for: interruption.convertedProjectID),
                            onReturn: { actions.returnToInbox(interruption) }
                        )
                    }
                }
                .padding(.top, Space.m)
            } label: {
                Text("Processed · \(processed.count)")
                    .font(Type.sectionTitle)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .font(Type.body)
            .lggrAnimation(Motion.reveal, value: showsProcessed)
        }
    }

    // MARK: - Empty states

    /// Nothing has ever been captured. An empty inbox is good news, so it is stated as good news and
    /// carries no button: there is nothing here to do, and the capture action is already in the
    /// header.
    private var empty: some View {
        EmptyStateView(
            symbol: Icon.inbox,
            title: "Nothing waiting.",
            message: "Press ⌘⇧I when something arrives and it lands here, without ending your session."
        )
    }

    /// Everything captured has been processed, and the `Processed` list below proves it.
    private var emptyWaiting: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Inbox clear.")
                .font(Type.rowTitle)
                .foregroundStyle(.primary)
            Text("Everything you captured has been dealt with.")
                .font(Type.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Space.l)
    }

    // MARK: - Keyboard

    /// What the focused row answers to: `⏎` turns it into a session, `⌘⌫` takes it off the list.
    ///
    /// Two keys and no more. Every one of the five actions is reachable from the row's menu; these
    /// two are the ones worth muscle memory, because they are the two that empty the inbox.
    private func handle(_ press: KeyPress, for interruption: Interruption) -> KeyPress.Result {
        switch press.key {
        case .return:
            actions.convertToSession(interruption)
            return .handled
        case .delete where press.modifiers.contains(.command):
            actions.dismiss(interruption)
            return .handled
        default:
            return .ignored
        }
    }

    /// Stops at the ends rather than wrapping: in a list you are working through top to bottom,
    /// wrapping puts you somewhere you did not aim for.
    private func move(_ direction: MoveCommandDirection) {
        let rows = ordered.map(\.id)
        guard !rows.isEmpty else { return }
        guard let current = focusedRow, let index = rows.firstIndex(of: current) else {
            focusedRow = direction == .up ? rows.last : rows.first
            return
        }
        switch direction {
        case .up, .left:
            focusedRow = rows[max(0, index - 1)]
        case .down, .right:
            focusedRow = rows[min(rows.count - 1, index + 1)]
        @unknown default:
            break
        }
    }

    // MARK: - Derived

    /// Newest first. This is a queue of things that arrived, and the most recent one is the one still
    /// in the user's head.
    private var ordered: [Interruption] {
        interruptions.sorted { $0.timestamp > $1.timestamp }
    }

    private var selectableProjects: [Project] {
        projects.filter(\.isActive)
    }

    private func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }
}

// MARK: - A waiting row

/// One captured line, and everything that can become of it.
///
/// The glyph is the source, untinted — colour in Lggr means "which project" or it means nothing
/// (`04-screens.md` § 2.5), and seven tinted glyphs would be a rainbow in a list read at a glance.
@MainActor
struct InterruptionRow: View {

    let interruption: Interruption
    let project: Project?
    let projects: [Project]
    let isFocused: Bool
    let actions: InterruptionInboxActions

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: interruption.source.symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(interruption.description)
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metadata
            }

            Spacer(minLength: Space.m)

            // The one visible verb. Revealed on hover or focus rather than always drawn, so a list
            // of eight rows is eight sentences rather than eight buttons.
            if isHovered || isFocused {
                Button("Start session") { actions.convertToSession(interruption) }
                    .buttonStyle(.borderless)
                    .font(Type.secondary)
            }

            RowMoreMenu(isVisible: isHovered || isFocused) { actionItems }
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        .background(background, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .lggrAnimation(Motion.tap, value: isFocused)
        .contextMenu { actionItems }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(interruption.description)
        .accessibilityValue(spokenDetail)
    }

    private var background: Color {
        if isFocused { return Surface.selected }
        if isHovered { return Surface.hover }
        return .clear
    }

    // MARK: Metadata

    /// The source, the time, and — when it happened mid-session — that fact. Stated flatly: it is
    /// evidence the weekly review will use, not a comment on the user's morning.
    private var metadata: some View {
        HStack(spacing: Space.xs) {
            Text(interruption.source.displayName)
                .font(Type.secondary)
                .foregroundStyle(.secondary)

            separator

            Text(interruption.timestamp.formatted(date: .omitted, time: .shortened))
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if interruption.interruptedASession {
                separator
                Text("during a session")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.support)
            }

            if let project {
                separator
                ProjectBadge(project: project, variant: .compact)
            }
        }
        .lineLimit(1)
        .accessibilityHidden(true)
    }

    private var separator: some View {
        Text(verbatim: "·")
            .font(Type.secondary)
            .foregroundStyle(.tertiary)
    }

    // MARK: Actions

    /// The same five items in the hover menu and the context menu, so mouse and keyboard never see a
    /// different set of possibilities.
    @ViewBuilder private var actionItems: some View {
        Button("Start session") { actions.convertToSession(interruption) }
        Button("Log accomplishment…") { actions.logAccomplishment(interruption) }

        if !projects.isEmpty {
            Menu("File under") {
                ForEach(projects) { project in
                    Button(project.name) { actions.fileUnderProject(interruption, project.id) }
                }
                Divider()
                Button("No project") { actions.fileUnderProject(interruption, nil) }
            }
        }

        Divider()

        // Not destructive, not confirmed, and reversible from the Processed list. Dismissing is a
        // decision the app records, not one it argues with.
        Button("Dismiss") { actions.dismiss(interruption) }

        if let delete = actions.delete {
            Button("Delete", role: .destructive) { delete(interruption) }
        }
    }

    private var spokenDetail: String {
        var parts = [interruption.source.displayName]
        parts.append(interruption.timestamp.formatted(date: .omitted, time: .shortened))
        if interruption.interruptedASession { parts.append("captured during a session") }
        if let name = project?.normalizedName { parts.append(name) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - A processed row

/// One row that has already been dealt with, and the way back.
///
/// Quieter than a waiting row by a whole step — `Type.body` and `.secondary` — because this list is
/// a receipt, not work. Its status is spelled out so "Converted" and "Dismissed" are never guessed
/// from a shade of grey.
@MainActor
struct ProcessedInterruptionRow: View {

    let interruption: Interruption
    let project: Project?
    let onReturn: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(interruption.description)
                .font(Type.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)

            Text(statusText)
                .font(Type.secondary)
                .foregroundStyle(Ink.support)
                .lineLimit(1)

            Spacer(minLength: Space.m)

            Button("Put back", action: onReturn)
                .buttonStyle(.borderless)
                .font(Type.secondary)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .contextMenu {
            Button("Put back", action: onReturn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(interruption.description)
        .accessibilityValue(statusText)
    }

    /// `Dismissed` · `Filed under SOR engineering` · `Converted`.
    private var statusText: String {
        switch interruption.status {
        case .dismissed:
            return "Dismissed"
        case .converted:
            guard let name = project?.normalizedName else { return "Converted" }
            return "Filed under \(name)"
        case .inbox:
            return "Waiting"
        }
    }
}
