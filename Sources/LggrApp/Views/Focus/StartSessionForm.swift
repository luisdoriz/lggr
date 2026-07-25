import SwiftUI
import LggrKit

// The session-start panel. See docs/_design/04-screens.md § 5.2.
//
// This is the most important interaction in the product: starting a focus session must take under
// five seconds. Everything below is in service of one sentence — the panel opens with focus already
// in the outcome field, every other field already carries a correct default, and `Return` starts.
//
// One view, two hosts: 460pt as a sheet on the main window, 320pt rendered inline inside the menu bar
// popover (a `.menuBarExtraStyle(.window)` popover cannot present a sheet). Layout is identical; only
// the frame width and the interior padding differ.

/// The panel's focus chain, in visual order.
///
/// macOS ships with keyboard navigation limited to text boxes and lists unless the user changes a
/// System Settings toggle, so `Tab` alone is not load-bearing: the panel installs this chain itself
/// and every flow can be completed with `Return` and the arrow keys.
public enum StartPanelField: Hashable, Sendable {
    case outcome
    case duration
    case customMinutes
}

/// What the panel hands back when the user starts a session.
///
/// A value type rather than a direct call into `SessionManager` so the panel can be driven by a host
/// that has no store at all — the gallery, a snapshot render, a test.
public struct StartSessionRequest: Hashable, Sendable {
    public var projectID: UUID?
    public var intendedOutcome: String
    public var workType: WorkType
    public var plannedDuration: TimeInterval?

    public init(
        projectID: UUID?,
        intendedOutcome: String,
        workType: WorkType,
        plannedDuration: TimeInterval?
    ) {
        self.projectID = projectID
        self.intendedOutcome = intendedOutcome
        self.workType = workType
        self.plannedDuration = plannedDuration
    }
}

/// Everything the panel needs and cannot work out for itself.
///
/// All of it is synchronous. The panel opens instantly with defaults and is *never* blocked on I/O —
/// that is what makes five seconds achievable, and it is why the remembered project and the recent
/// outcomes come from `UserPreferences` rather than from the store.
public struct StartSessionContext: Equatable, Sendable {
    public var projects: [Project]
    public var recentOutcomes: [String]
    public var lastProjectID: UUID?
    public var lastWorkType: WorkType
    public var defaultDuration: TimeInterval
    /// Drives the one degraded-state line. The panel still starts sessions when this is true.
    public var projectsUnavailable: Bool

    public init(
        projects: [Project] = [],
        recentOutcomes: [String] = [],
        lastProjectID: UUID? = nil,
        lastWorkType: WorkType = .deepWork,
        defaultDuration: TimeInterval = UserPreferences.default.defaultSessionDuration,
        projectsUnavailable: Bool = false
    ) {
        self.projects = projects
        self.recentOutcomes = recentOutcomes
        self.lastProjectID = lastProjectID
        self.lastWorkType = lastWorkType
        self.defaultDuration = defaultDuration
        self.projectsUnavailable = projectsUnavailable
    }

    /// First run, no store, nothing remembered.
    public static let empty = StartSessionContext()

    /// The live context, read straight out of `SessionManager`.
    ///
    /// `lastWorkType` comes from the most recent session rather than from preferences because
    /// `UserPreferences` does not store one, and the most recent session is a better answer anyway:
    /// it is what the user was actually doing.
    @MainActor
    public static func live(_ manager: SessionManager) -> StartSessionContext {
        StartSessionContext(
            projects: manager.projects,
            recentOutcomes: manager.preferences.recentOutcomes,
            lastProjectID: manager.preferences.lastProjectID,
            lastWorkType: manager.todaySessions.first?.workType
                ?? manager.pendingReview?.workType
                ?? .deepWork,
            defaultDuration: manager.preferences.defaultSessionDuration,
            projectsUnavailable: manager.lastError != nil && manager.projects.isEmpty
        )
    }
}

/// "What are you working on?" — the panel that starts a focus session.
///
/// Hierarchy, in the order the eye should hit it: the outcome field, `Start Focus`, project and work
/// type, duration. Nothing else is on screen, because nothing else needs to be.
@MainActor
public struct StartSessionForm: View {

    /// Which host is rendering the panel. Only the width and the interior padding differ.
    public enum Presentation: Hashable, Sendable {
        case sheet
        case popover

        var width: CGFloat {
            switch self {
            case .sheet: Layout.startPanelSheetWidth
            case .popover: Layout.popoverWidth
            }
        }

        var padding: CGFloat {
            switch self {
            case .sheet: Space.xl
            case .popover: Space.m
            }
        }
    }

    @Environment(\.sessionManager) private var environmentManager

    private let presentation: Presentation
    private let injectedContext: StartSessionContext?
    private let injectedStart: ((StartSessionRequest) -> Void)?
    private let onCreateProject: (() -> Void)?
    private let onDismiss: () -> Void

    // MARK: - Form state

    @State private var outcome = ""
    @State private var projectID: UUID?
    @State private var workType: WorkType = .deepWork
    @State private var duration: DurationSelection = .preset(50)
    /// The one rule that makes the defaults feel intelligent rather than annoying: once the user has
    /// touched the duration, changing the work type stops moving it.
    @State private var durationWasEdited = false
    @State private var showsEmptyOutcomeHint = false
    @State private var hasAppliedDefaults = false

    @FocusState private var focus: StartPanelField?

    private let startShortcut = KeyboardShortcut(.return, modifiers: .command)
    private let openEndedShortcut = KeyboardShortcut(.return, modifiers: [.command, .option])

    // MARK: - Initialisers

    /// The live panel. Reads `SessionManager` from the environment and starts sessions through it.
    public init(
        presentation: Presentation = .sheet,
        onCreateProject: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.injectedContext = nil
        self.injectedStart = nil
        self.onCreateProject = onCreateProject
        self.onDismiss = onDismiss
    }

    /// The panel with everything supplied by the caller, for the gallery, snapshots and tests.
    public init(
        presentation: Presentation = .sheet,
        context: StartSessionContext,
        onCreateProject: (() -> Void)? = nil,
        onStart: @escaping (StartSessionRequest) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.injectedContext = context
        self.injectedStart = onStart
        self.onCreateProject = onCreateProject
        self.onDismiss = onDismiss
    }

    // MARK: - Body

    public var body: some View {
        let context = resolvedContext

        return VStack(alignment: .leading, spacing: 0) {
            Text("What are you working on?")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            OutcomeField(
                text: $outcome,
                recentOutcomes: context.recentOutcomes,
                focus: $focus,
                showsEmptyHint: showsEmptyOutcomeHint,
                onSubmit: { attemptStart(openEnded: false) },
                onCancel: onDismiss
            )
            .padding(.top, Space.l)

            HStack(spacing: Space.s) {
                ProjectPicker(
                    projects: context.projects,
                    selection: $projectID,
                    onCreateProject: onCreateProject
                )
                Spacer(minLength: Space.s)
                WorkTypePicker(selection: $workType, onChange: applySuggestedDuration(for:))
            }
            .padding(.top, Space.l)

            DurationPicker(
                selection: $duration,
                focus: $focus,
                onManualChange: { durationWasEdited = true }
            )
            .padding(.top, Space.m)

            if context.projectsUnavailable {
                // Losing the ability to start a session because a file is locked would be
                // indefensible, so this is a note, not a blocker.
                Text("Projects couldn't be loaded. You can still start a session.")
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, Space.m)
            }

            actions
                .padding(.top, Space.xl)
        }
        .padding(presentation.padding)
        .frame(width: presentation.width, alignment: .leading)
        .defaultFocus($focus, StartPanelField.outcome)
        .onExitCommand(perform: onDismiss)
        .onAppear { applyDefaults(from: context) }
        .onChange(of: outcome) { _, _ in showsEmptyOutcomeHint = false }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Space.m) {
            Button {
                attemptStart(openEnded: true)
            } label: {
                HStack(spacing: Space.xs) {
                    Text("Start without timer")
                    if presentation == .sheet {
                        ShortcutHint(openEndedShortcut)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(Type.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(openEndedShortcut)

            Spacer(minLength: Space.s)

            // Deliberately *not* `.disabled()`. § 5.2 requires that pressing ⌘⏎ with an empty
            // outcome returns focus to the field and explains why, and a disabled button swallows
            // its own shortcut. The reduced opacity is the "not ready yet" signal; the hint is the
            // reason. Nothing here is red and nothing scolds.
            Button("Start Focus") {
                attemptStart(openEnded: false)
            }
            .buttonStyle(.lggrPrimary(shortcut: startShortcut))
            .keyboardShortcut(startShortcut)
            .opacity(canStart ? 1 : 0.55)
            .lggrAnimation(Motion.settle, value: canStart)
            .accessibilityHint(canStart ? "" : "Add an outcome to start.")
        }
    }

    // MARK: - Defaults

    private var resolvedContext: StartSessionContext {
        if let injectedContext { return injectedContext }
        guard let environmentManager else { return .empty }
        return .live(environmentManager)
    }

    /// Applied once, on the first appearance. Re-applying them later would move fields under a user
    /// who is already typing.
    private func applyDefaults(from context: StartSessionContext) {
        guard !hasAppliedDefaults else { return }
        hasAppliedDefaults = true

        projectID = defaultProjectID(from: context)
        workType = context.lastWorkType
        duration = .matching(context.defaultDuration)
        focus = .outcome
    }

    /// The remembered project if it is still there and still active; otherwise the most recently
    /// touched active project; otherwise "No project", which is a fully supported way to work.
    private func defaultProjectID(from context: StartSessionContext) -> UUID? {
        if let remembered = context.lastProjectID,
           context.projects.contains(where: { $0.id == remembered && $0.isActive }) {
            return remembered
        }
        return context.projects
            .filter(\.isActive)
            .max { $0.updatedAt < $1.updatedAt }?
            .id
    }

    /// Changing the work type re-selects its suggested duration — 50 minutes for work that deserves
    /// a long runway, 25 for work that is inherently bursty — but only while the user has not chosen
    /// a duration themselves.
    private func applySuggestedDuration(for workType: WorkType) {
        guard !durationWasEdited else { return }
        duration = .matching(workType.suggestedDuration)
    }

    // MARK: - Starting

    private var trimmedOutcome: String {
        outcome.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canStart: Bool {
        !trimmedOutcome.isEmpty
    }

    private func attemptStart(openEnded: Bool) {
        guard canStart else {
            showsEmptyOutcomeHint = true
            focus = .outcome
            return
        }

        let request = StartSessionRequest(
            projectID: projectID,
            intendedOutcome: trimmedOutcome,
            workType: workType,
            plannedDuration: openEnded ? nil : duration.plannedDuration
        )

        if let injectedStart {
            injectedStart(request)
        } else if let environmentManager {
            // The panel closes now and the store catches up: a button that waits on a file is a
            // button that feels slow, and `SessionManager` already holds the session in memory.
            Task {
                await environmentManager.startSession(
                    projectID: request.projectID,
                    intendedOutcome: request.intendedOutcome,
                    workType: request.workType,
                    plannedDuration: request.plannedDuration
                )
            }
        }

        onDismiss()
    }
}
