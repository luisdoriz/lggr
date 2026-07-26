import LggrKit
import SwiftUI

// The main window. See docs/_design/04-screens.md § 1.1.
//
// Two columns and a push stack, not three columns: a middle column would be empty on five of the
// seven sections, and two columns plus `NavigationStack` is the calmer shape. Window frame is
// persisted by SwiftUI per scene id; the selected section is persisted by `AppModel`.
//
// This file is the only place in the app that knows how a section maps to a screen, and how a
// `SheetRoute` maps to a panel. Both switches are exhaustive on purpose — adding a case to either
// enum makes the compiler ask this file what it means.

/// The window's root.
///
/// Reads the composition root out of the environment rather than taking it as a parameter, because
/// `Window`'s content closure is evaluated by SwiftUI and there is nothing to hand it.
@MainActor
public struct RootWindow: View {

    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    public init() {}

    public var body: some View {
        if let environment {
            RootWindowContent(environment: environment)
        } else {
            // Only reachable from a host that forgot to inject the environment — a gallery window,
            // a snapshot render. Says so calmly rather than crashing on a force unwrap.
            EmptyStateView(
                symbol: Icon.error,
                title: "This window opened without Lggr's state.",
                message: "Quit and reopen Lggr and it will come back."
            )
            .background(Surface.canvas)
        }
    }
}

// MARK: - Content

@MainActor
private struct RootWindowContent: View {

    private let environment: AppEnvironment
    @Bindable private var appModel: AppModel

    /// Editing an existing accomplishment is local sheet state rather than an `AppModel.SheetRoute`,
    /// because the route carries a *session* id and there is no case that carries an accomplishment.
    /// It is only ever raised from a row, so it can never collide with the routed sheet.
    @State private var editingAccomplishment: Accomplishment? = nil

    /// The reconstructed day. Read from `TimelineModel.shared` rather than constructed here: ambient
    /// capture runs from launch whether or not this window is open, so the object the sampler flushes
    /// into cannot belong to a view's lifetime.
    private let timelineModel = TimelineModel.shared

    /// The two history screens' state. Owned by this window rather than by the composition root,
    /// because unlike capture and the inbox neither of them does anything until somebody is looking:
    /// they read a date range out of the store on demand and hold nothing the app needs while every
    /// window is closed.
    @State private var sessionsModel: SessionsModel
    @State private var accomplishmentsModel: AccomplishmentsModel

    /// The classification rules. Owned by the window rather than by the Rules screen, because two
    /// surfaces need the same set: `⌘6` renders and edits them, and every timeline block offers the
    /// correction loop against them (`Views/Rules/ReclassifySheet.swift`). One instance is what stops
    /// the offer a block raises from disagreeing with the list `⌘6` shows.
    @State private var rulesModel: RulesModel

    /// The week. Owned by the window for the same reason the history screens are: it reads a week out
    /// of the store when somebody opens `⌘4` and holds nothing the app needs while every window is
    /// closed. It is handed the same activity log the sampler writes, so the review's category
    /// breakdown and its per-day context-switch counts come from the days actually recorded.
    @State private var weeklyModel: WeeklyModel

    /// Editing an outcome is local sheet state rather than an `AppModel.SheetRoute`, for the same
    /// reason editing an accomplishment is: no route carries an outcome, and it is only ever raised
    /// from this screen.
    @State private var editingOutcome: OutcomeEditRequest? = nil

    init(environment: AppEnvironment) {
        self.environment = environment
        self.appModel = environment.appModel
        self._rulesModel = State(initialValue: RulesModel(store: environment.store))
        self._weeklyModel = State(
            initialValue: WeeklyModel(
                store: environment.store,
                activityLog: environment.capture.log,
                clock: environment.clock
            )
        )
        self._sessionsModel = State(
            initialValue: SessionsModel.live(store: environment.store, clock: environment.clock)
        )
        self._accomplishmentsModel = State(
            initialValue: AccomplishmentsModel(store: environment.store, clock: environment.clock)
        )
    }

    private var manager: SessionManager { environment.sessionManager }

    /// The interruption inbox. Read from the composition root rather than constructed here: `⌘⇧I`
    /// works with every window closed, so the object it writes into cannot belong to this window.
    private var inbox: InboxModel { environment.inbox }

    var body: some View {
        NavigationSplitView(columnVisibility: $appModel.columnVisibility) {
            Sidebar(
                selection: $appModel.section,
                isSessionRunning: manager.activeSession != nil
            )
            .navigationSplitViewColumnWidth(
                min: Layout.sidebarMinWidth,
                ideal: Layout.sidebarIdealWidth,
                max: Layout.sidebarMaxWidth
            )
        } detail: {
            NavigationStack(path: $appModel.detailPath) {
                detailColumn
                    // The inbox is a place, pushed on top of Today, so it gets a real back button and
                    // does not have to be dismissed before the user can look at anything else.
                    .navigationDestination(for: InboxRoute.self) { _ in inboxScreen }
                    // Registered on the stack's root rather than inside Focus Sessions, so a route
                    // still on the path when the user switches section resolves to a real view
                    // instead of SwiftUI's "no destination" placeholder.
                    .navigationDestination(for: SessionRoute.self) { route in
                        sessionDetail(route)
                    }
            }
            .frame(minWidth: Layout.detailMinWidth)
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $appModel.sheet) { route in
            panel(for: route)
        }
        .sheet(item: $editingAccomplishment) { accomplishment in
            AccomplishmentEditor(
                accomplishment: accomplishment,
                projects: manager.projects,
                onSave: { updated in
                    Task { await manager.addAccomplishment(updated) }
                    editingAccomplishment = nil
                },
                onCancel: { editingAccomplishment = nil }
            )
        }
        .sheet(item: $editingOutcome) { request in
            WeeklyOutcomeEditor(
                outcome: request.outcome,
                weekStart: weeklyModel.review.week.start,
                // The seating is computed from the week the review already built, so the sheet and the
                // screen agree about which seats are free without either re-deriving it.
                seating: OutcomeSeating(
                    set: weeklyModel.review.outcomes,
                    editing: request.outcome
                ),
                initialPriority: request.priority,
                projects: manager.projects,
                onSave: { outcome in
                    Task { await weeklyModel.save(outcome) }
                    editingOutcome = nil
                },
                onCancel: { editingOutcome = nil }
            )
        }
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if let banner = bannerMessage {
                ErrorBanner(
                    message: banner.message,
                    // Nothing to recover from when the banner is stating a fact rather than a
                    // failure: *Show in Finder* beside "Ended at 12:04" would be offering the data
                    // folder as the remedy for something that is not broken.
                    recoveryTitle: banner.isFailure ? recoveryTitle : nil,
                    kind: banner.kind,
                    onRecover: { environment.revealDataFolder() },
                    onDismiss: {
                        manager.dismissError()
                        weeklyModel.dismissError()
                        environment.exportService.clearFailure()
                        // The notice is acknowledged, not deleted: the session keeps `autoClosedAt`
                        // and its reason forever, and `SessionRow` and `SessionDetailView` go on
                        // showing them. Only the announcement goes away.
                        manager.acknowledgeAutoClose()
                    }
                )
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.l)
            }

            sectionContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Surface.canvas)
        .lggrAnimation(Motion.settle, value: bannerMessage)
        // The correction loop, installed once for every screen in the detail column. A row that shows
        // an application's time picks this up and offers *Always classify Slack as ▸*; a row that does
        // not, or a build where nothing installed it, gets no context menu rather than an inert one.
        .ruleCorrection(
            RuleCorrectionScope(
                category: { rulesModel.category(for: $0) },
                offer: { context, category in
                    _ = rulesModel.offerRule(for: context, as: category)
                }
            )
        )
        // Presented from the window rather than from the Rules screen, because the correction is made
        // on the timeline: the offer has to appear over whatever the user was looking at. Dismissing
        // it any way at all — Esc, the button, clicking away — is *Not now*, and writes nothing.
        .sheet(
            item: Binding(
                get: { rulesModel.offer },
                set: { if $0 == nil { rulesModel.declineOffer() } }
            )
        ) { offer in
            ReclassifySheet(
                offer: offer,
                projects: manager.projects,
                onCreate: { Task { await rulesModel.acceptOffer() } },
                onNotNow: { rulesModel.declineOffer() }
            )
        }
        // One read of the rules for the whole window. Every category the timeline shows is derived
        // from them, so they are loaded even when the user never opens `⌘6`.
        .task { await rulesModel.load() }
    }

    @ViewBuilder private var sectionContent: some View {
        switch appModel.section {
        case .today:
            today
        case .sessions:
            sessionsScreen
        case .accomplishments:
            accomplishmentsScreen
        case .weeklyReview:
            weeklyReviewScreen
        case .projects:
            ProjectsView(
                projects: manager.projects,
                onNewProject: { appModel.presentProjectEditor() },
                onEditProject: { appModel.presentProjectEditor(projectID: $0.id) },
                onSaveProject: { project in Task { await manager.saveProject(project) } },
                onDeleteProject: { id in Task { await manager.deleteProject(id: id) } }
            )
        case .rules:
            RulesView(model: rulesModel, projects: manager.projects)
        case .settings:
            SettingsView(environment: environment, host: .detail)
        }
    }

    /// Today, with the active-session card injected into its slot.
    ///
    /// `today:` reads the clock rather than `manager.now`: `now` ticks once a second, and reading it
    /// here would repaint the whole screen every second to change a date that changes once a day.
    /// The tick belongs inside `TimerDisplay`, which is why the card takes `now` as a closure.
    ///
    /// The reconstructed day comes from `TimelineModel`, which is read here and never rebuilt here:
    /// it reloads once when the window appears, folds in each flush the sampler hands it, and
    /// rebuilds when the declared sessions change. Nothing about it is on the timer's path.
    private var today: some View {
        TodayView(
            today: environment.clock.now,
            hasActiveSession: manager.activeSession != nil,
            sessions: manager.todaySessions,
            accomplishments: manager.todayAccomplishments,
            projects: manager.projects,
            timeline: timelineModel.timeline,
            interruptions: inbox.pending,
            actions: todayActions
        ) {
            if let session = manager.activeSession {
                ActiveSessionView(
                    session: session,
                    project: project(for: session.projectID),
                    now: { manager.now },
                    onTogglePause: { manager.togglePause() },
                    onFinish: { finishSession() },
                    onAdjustPlan: { delta in manager.adjustPlannedDuration(by: delta) },
                    onSetPlan: { target in manager.adjustPlannedDuration(to: target) },
                    // The card has already confirmed by the time this runs.
                    onDiscard: { discardActiveSession() }
                )
            }
        }
        // One read of the day, when the window first shows it. Everything after that arrives
        // through `TimelineModel.apply(_:)` from the sampler's flushes.
        .task { await timelineModel.load(sessions: manager.todaySessions) }
        // A session that starts, finishes or is reviewed changes what the segmenter may cut on and
        // what a block may be called, so the day is rebuilt from the evidence already in memory.
        .onChange(of: manager.todaySessions) { _, sessions in
            timelineModel.update(sessions: sessions)
        }
    }

    /// Accomplishment deletion is still deliberately absent: `SessionManager` has no delete for one,
    /// and `TodayActions` drops the menu item when the handler is `nil`. A menu that offers an action it
    /// cannot perform is worse than one that does not offer it.
    private var todayActions: TodayActions {
        TodayActions(
            startSession: { appModel.presentStartPanel(inPopover: false) },
            addAccomplishment: { appModel.presentAccomplishmentEditor() },
            reviewSession: { session in review(session) },
            logAccomplishment: { session in
                appModel.presentAccomplishmentEditor(sessionID: session.id)
            },
            editAccomplishment: { editingAccomplishment = $0 },
            reviewInbox: { appModel.presentInbox() },
            editSessionTimes: { session in
                appModel.presentSessionEditor(sessionID: session.id)
            },
            // The row has already confirmed by the time this runs.
            deleteSession: { session in delete(session) },
            labelBlock: { episode in
                appModel.presentBlockLabel(episodeID: episode.id)
            },
            // The queue, reachable without a notification. `DayTimelineStrip` shows the action only
            // when the day holds something it would offer, so this never opens an empty sheet.
            reviewUnlabelled: { appModel.presentEndOfDayReview() }
        )
    }

    // MARK: - Focus Sessions

    /// `⌘2`. The full history, a date range at a time.
    ///
    /// The range reloads on appearance and whenever today's sessions change — and only then. A user
    /// looking at March does not want the screen to move because something finished this afternoon,
    /// which is why the reload is `reloadIfCurrent()` rather than `reload()`.
    private var sessionsScreen: some View {
        SessionsListView(
            window: sessionsModel.windowDisplay,
            days: sessionsModel.days,
            projects: manager.projects,
            sessionsInWindow: sessionsModel.sessions.count,
            isLoading: sessionsModel.phase == .loading,
            isFiltering: sessionsModel.isFiltering,
            searchText: $sessionsModel.searchText,
            projectFilter: $sessionsModel.projectFilter,
            actions: SessionsActions(
                newSession: { appModel.presentStartPanel(inPopover: false) },
                open: { session in open(session) },
                review: { session in review(session) },
                addAccomplishment: { session in
                    appModel.presentAccomplishmentEditor(sessionID: session.id)
                },
                editTimes: { session in
                    appModel.presentSessionEditor(sessionID: session.id)
                },
                delete: { session in delete(session) },
                step: { steps in Task { await sessionsModel.step(steps) } },
                setSpan: { span in Task { await sessionsModel.setSpan(span) } },
                goToLatest: { Task { await sessionsModel.goToLatest() } },
                clearFilters: { sessionsModel.clearFilters() }
            )
        )
        .task { await sessionsModel.load() }
        .onChange(of: manager.todaySessions) { _, _ in
            Task { await sessionsModel.reloadIfCurrent() }
        }
    }

    /// One session, pushed. The route carries an id, so the screen resolves it rather than trusting
    /// that the range it was pushed from is still loaded.
    @ViewBuilder private func sessionDetail(_ route: SessionRoute) -> some View {
        if let detail = sessionsModel.detail, detail.session.id == route.sessionID {
            SessionDetailView(
                session: detail.session,
                project: project(for: detail.session.projectID),
                episodes: detail.episodes,
                interruptions: detail.interruptions,
                accomplishments: detail.accomplishments,
                projects: manager.projects,
                actions: SessionDetailActions(
                    back: { popDetail() },
                    review: detail.session.resultStatus == nil
                        ? { review(detail.session) }
                        : nil,
                    save: { updated in
                        // Interface first, disk second: the screen accepts its own edit immediately
                        // and the manager writes it, exactly as every other mutation in the app does.
                        sessionsModel.apply(updated)
                        Task { await manager.update(updated) }
                    },
                    editTimes: {
                        appModel.presentSessionEditor(sessionID: detail.session.id)
                    },
                    addAccomplishment: {
                        appModel.presentAccomplishmentEditor(sessionID: detail.session.id)
                    },
                    editAccomplishment: { editingAccomplishment = $0 }
                )
            )
            .navigationTitle(detail.session.intendedOutcome)
        } else if case .failed(let message) = sessionsModel.detailPhase {
            EmptyStateView(
                symbol: Icon.emptySessions,
                title: message,
                message: "It may have been deleted since this list was loaded.",
                actionTitle: "Focus Sessions",
                action: { popDetail() }
            )
            .background(Surface.canvas)
        } else {
            // Resolving. § 3.2 forbids a full-screen spinner, so this is a plain canvas for the few
            // milliseconds a local read takes, and the load is what fills it.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Surface.canvas)
                .task { await sessionsModel.openDetail(sessionID: route.sessionID) }
        }
    }

    // MARK: - Accomplishments

    /// `⌘3`. The "Done" log, grouped by week.
    private var accomplishmentsScreen: some View {
        AccomplishmentsLogView(
            window: accomplishmentsModel.windowDisplay,
            weeks: accomplishmentsModel.weeks,
            projects: manager.projects,
            entriesInWindow: accomplishmentsModel.accomplishments.count,
            availableTypes: accomplishmentsModel.availableTypes,
            availableProjects: accomplishmentsModel.availableProjects(from: manager.projects),
            isLoading: accomplishmentsModel.phase == .loading,
            isFiltering: accomplishmentsModel.isFiltering,
            searchText: $accomplishmentsModel.searchText,
            typeFilter: $accomplishmentsModel.typeFilter,
            projectFilter: $accomplishmentsModel.projectFilter,
            actions: AccomplishmentsActions(
                add: { appModel.presentAccomplishmentEditor() },
                edit: { editingAccomplishment = $0 },
                // Present only for an entry that came from a session, and it pushes the same detail
                // view Focus Sessions does.
                openSource: { accomplishment in
                    guard let sessionID = accomplishment.focusSessionID else { return }
                    open(sessionID: sessionID)
                },
                // Deletion is deliberately absent: `SessionManager` has no delete for accomplishments,
                // and the row drops the menu item when the handler is `nil`. A menu that offers an
                // action it cannot perform is worse than one that does not offer it.
                delete: nil,
                step: { steps in Task { await accomplishmentsModel.step(steps) } },
                setSpan: { span in Task { await accomplishmentsModel.setSpan(span) } },
                goToLatest: { Task { await accomplishmentsModel.goToLatest() } },
                clearFilters: { accomplishmentsModel.clearFilters() },
                markdown: { accomplishmentsModel.markdown(projects: manager.projects) },
                exportFileName: { accomplishmentsModel.suggestedExportFileName }
            )
        )
        .task { await accomplishmentsModel.load() }
        .onChange(of: manager.todayAccomplishments) { _, _ in
            Task { await accomplishmentsModel.reloadIfCurrent() }
        }
    }

    /// One error surface for the whole detail column (`04-screens.md` § 3.3).
    ///
    /// A week that could not be read or an outcome that could not be saved rides the same banner the
    /// store's own failures do, and only while `⌘4` is the section showing — a stale weekly message
    /// over Today would be reporting a failure the user is not looking at.
    ///
    /// An export that could not be written rides it from *every* section, and deliberately: `File ▸
    /// Export` is reachable from the menu bar with no window open, `ExportService` opens the window so
    /// there is somewhere to read the sentence, and a message tied to one section would then be
    /// invisible on whichever section happened to be selected.
    ///
    /// The automatic close rides it too, and last. It is the one thing on this banner that is not a
    /// failure: a session Lggr closed itself is a number that changed while nobody was watching, and
    /// `SessionManager.autoCloseNotice` is the sentence that says where the new end came from. Without
    /// a reader it was a control that existed in code and never appeared — the completion notification
    /// is off on a fresh install, so on that install the end simply moved in silence. Last in the
    /// order, because a store that could not be written is more urgent than an explanation.
    private var bannerMessage: Banner? {
        if let message = manager.lastError { return Banner(failure: message) }
        if let message = environment.exportService.failure { return Banner(failure: message) }
        if appModel.section == .weeklyReview, let message = weeklyModel.lastError {
            return Banner(failure: message)
        }
        guard let notice = manager.autoCloseNotice else { return nil }
        return Banner(notice: notice.sentence)
    }

    /// What the one banner is currently saying, and whether it is a failure.
    ///
    /// The distinction is not cosmetic: it decides the recovery button and the word VoiceOver leads
    /// with. Announcing "Error, ended at 12:04, the last input Lggr recorded" would make provenance
    /// sound like a fault, which is the one thing every note about `autoClosedAt` says it is not.
    struct Banner: Equatable {
        let message: String
        let kind: ErrorBanner.Kind

        var isFailure: Bool { kind == .failure }

        init(failure message: String) {
            self.message = message
            self.kind = .failure
        }

        init(notice message: String) {
            self.message = message
            self.kind = .notice
        }
    }

    // MARK: - Weekly Review

    /// `⌘4`. The screen renders what `WeeklyReviewBuilder` and `InsightGenerator` computed and nothing
    /// else; every action below is a store write followed by a rebuild, so the numbers and the
    /// sentences can never drift from the records they came from.
    private var weeklyReviewScreen: some View {
        WeeklyReviewView(
            review: weeklyModel.review,
            observations: weeklyModel.observations,
            projects: weeklyModel.projects,
            isCurrentWeek: weeklyModel.isViewingCurrentWeek,
            isLoading: weeklyModel.phase == .loading,
            recordNotice: weeklyModel.activityNotice,
            actions: WeeklyReviewActions(
                showPreviousWeek: { Task { await weeklyModel.showPreviousWeek() } },
                showNextWeek: { Task { await weeklyModel.showNextWeek() } },
                showCurrentWeek: { Task { await weeklyModel.showCurrentWeek() } },
                addOutcome: { priority in
                    editingOutcome = OutcomeEditRequest(priority: priority)
                },
                editOutcome: { outcome in
                    editingOutcome = OutcomeEditRequest(outcome: outcome)
                },
                setOutcomeStatus: { outcome, status in
                    Task { await weeklyModel.setStatus(status, for: outcome) }
                },
                deleteOutcome: { outcome in
                    Task { await weeklyModel.delete(outcomeID: outcome.id) }
                },
                // Writes the week **on screen**, not the week the calendar is in: the user navigated
                // to it on purpose. The document comes from `WeeklyModel.markdown`, which is the same
                // function behind the screen's Copy as Markdown, so the file and the clipboard cannot
                // disagree. `File ▸ Export ▸ Weekly Review…` covers the no-window case separately.
                exportReview: {
                    environment.exportService.save(
                        ExportDocument(
                            text: weeklyModel.markdown,
                            fileName: weeklyExportFileName,
                            format: .markdown
                        ),
                        message: ExportKind.weeklyReview.panelMessage
                    )
                }
            )
        )
        .task { await weeklyModel.load() }
        // A session finished or reviewed this week changes the week's totals, so the review is rebuilt
        // from the store rather than left showing the figures it opened with.
        .onChange(of: manager.todaySessions) { _, _ in
            Task { await weeklyModel.load() }
        }
        .onChange(of: manager.todayAccomplishments) { _, _ in
            Task { await weeklyModel.load() }
        }
    }

    /// `Weekly Review 2026-07-20.md` — the week's Monday, as an ISO date so a folder of them sorts
    /// correctly and none of them can be read as a US or European date by mistake.
    private var weeklyExportFileName: String {
        let stamp = ExportFormatter().isoDate(weeklyModel.review.week.start)
        return "Weekly Review \(stamp).md"
    }

    // MARK: - Panels

    @ViewBuilder private func panel(for route: AppModel.SheetRoute) -> some View {
        switch route {
        case .startSession:
            StartSessionForm(
                presentation: .sheet,
                context: environment.startSessionContext(),
                onCreateProject: { appModel.present(.projectEditor(projectID: nil)) },
                onStart: { request in
                    environment.start(request)
                    appModel.dismissSheet()
                },
                onDismiss: { appModel.dismissSheet() }
            )
        case .sessionReview:
            reviewPanel
        case .addAccomplishment(let sessionID):
            AccomplishmentEditor(
                accomplishment: seedAccomplishment(sessionID: sessionID),
                projects: manager.projects,
                isFromSession: sessionID != nil,
                onSave: { accomplishment in
                    Task { await manager.addAccomplishment(accomplishment) }
                    appModel.dismissSheet()
                },
                onCancel: { appModel.dismissSheet() }
            )
        case .projectEditor(let projectID):
            ProjectEditor(
                project: project(for: projectID),
                onSave: { project in
                    Task { await manager.saveProject(project) }
                    appModel.dismissSheet()
                },
                onCancel: { appModel.dismissSheet() }
            )
        case .captureInterruption:
            InterruptionCaptureSheet(
                presentation: .sheet,
                // The sheet closes only once the note is on disk. On a failed write it stays open
                // with the sentence intact, which is the one thing that must never be retyped.
                onSave: { note, source in
                    let saved = await inbox.capture(note, source: source)
                    if saved { appModel.dismissSheet() }
                    return saved
                },
                onCancel: { appModel.dismissSheet() }
            )
        case .interruptionAccomplishment(let interruptionID):
            interruptionAccomplishmentPanel(interruptionID: interruptionID)
        case .editSession(let sessionID):
            sessionEditPanel(sessionID: sessionID)
        case .labelBlock(let episodeID):
            labelBlockPanel(episodeID: episodeID)
        case .endOfDayReview:
            endOfDayReviewPanel
        }
    }

    /// "Today's record" — the queue of blocks nobody declared anything over.
    ///
    /// The queue is assembled **here, now**, from `UnlabelledWork.report(for:)` over the timeline as it
    /// currently stands — never from a list captured when the notification was posted. Minutes have
    /// passed since then, and a queue that offered a block a session has since accounted for would be
    /// the sheet arguing with the record.
    ///
    /// An empty report is a valid state and renders the closing panel rather than closing itself: the
    /// user pressed a button and is owed one sentence saying why there is nothing to do, not a sheet
    /// that flashes and vanishes.
    @ViewBuilder private var endOfDayReviewPanel: some View {
        let report = environment.prompts.currentReport()
        EndOfDayReviewSheet(
            items: report.blocks.map { episode in
                let classification = classification(for: episode)
                return EndOfDayReviewSheet.Item(
                    episode: episode,
                    claim: timelineModel.claim(for: episode),
                    suggestedProjectID: classification?.projectID,
                    suggestedWorkType: classification
                        .flatMap { SessionFromEpisode.suggestedWorkType(for: $0.category) }
                        ?? environment.startSessionContext().lastWorkType
                )
            },
            projects: manager.projects,
            recentOutcomes: manager.preferences.recentOutcomes,
            estimateText: report.estimateText,
            setAside: report.setAside,
            onFile: { episode, label in labelBlock(episode, as: label) },
            // Skipping writes nothing at all. The block stays on the timeline, labellable there, and
            // ages out silently into neutral tracked time — `INTELLIGENCE.md` §3.4.
            onSkip: { _ in },
            onClose: { appModel.dismissSheet() }
        )
    }

    /// "This was…", opened from a timeline row or from the menu bar's one keystroke.
    ///
    /// Everything the sheet renders is resolved here, at present time, rather than captured when the
    /// row was clicked: the timeline is rebuilt on every flush of the sampler, and a claim computed a
    /// minute ago may since have been taken by a session that finished. `TimelineModel` owns the day's
    /// declared sessions, so it is what answers whether the span is still free.
    ///
    /// The project and work type are pre-filled from the *rules the user wrote*, not from inference.
    /// `RulesModel.engine` classifies the block's dominant application; a rule that assigns a project
    /// supplies one, and the category it returns supplies a work type through
    /// `SessionFromEpisode.suggestedWorkType`. Both fail closed — no rule, no pre-fill — which is
    /// `INTELLIGENCE.md` §3.8's refusal to infer a project before there is evidence to infer from.
    @ViewBuilder private func labelBlockPanel(episodeID: UUID) -> some View {
        if let episode = timelineModel.episode(id: episodeID) {
            let classification = classification(for: episode)
            LabelBlockSheet(
                episode: episode,
                outcome: timelineModel.claim(for: episode),
                projects: manager.projects,
                suggestedProjectID: classification?.projectID,
                // The user's last work type when the rules have nothing to say, which is the same
                // fallback the start panel uses and for the same reason: it is what they were
                // actually doing.
                suggestedWorkType: classification
                    .flatMap { SessionFromEpisode.suggestedWorkType(for: $0.category) }
                    ?? environment.startSessionContext().lastWorkType,
                recentOutcomes: manager.preferences.recentOutcomes,
                onSave: { label in
                    labelBlock(episode, as: label)
                    appModel.dismissSheet()
                },
                // Present only when there really is a session accounting for this block, which is the
                // only case where correcting times is the way through.
                onCorrectTimes: timelineModel.sessionCovering(episode).map { covering in
                    { appModel.presentSessionEditor(sessionID: covering.id) }
                },
                onCancel: { appModel.dismissSheet() }
            )
        } else {
            // The day was rebuilt into different blocks while this route was up — the sampler flushed
            // and the segmenter cut elsewhere. Nothing to label, so the sheet closes itself rather
            // than showing a form about a block that is no longer on the timeline. The same
            // arrangement every other route here uses for the same race.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { appModel.dismissSheet() }
                .accessibilityHidden(true)
        }
    }

    /// What the user's rules make of this block, or `nil` when there is nothing to ask about.
    ///
    /// The dominant application only. A block's second and third applications are evidence about the
    /// block, not about its project, and consulting them would be a vote — which is a model with two
    /// voters wearing a rule table's clothes.
    private func classification(for episode: Episode) -> Classification? {
        guard let app = episode.dominantApp, !app.bundleIdentifier.isEmpty else { return nil }
        return rulesModel.engine.classify(
            ActivityContext(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName)
        )
    }

    /// "Correct the times", opened from Today, from the history or from a pushed detail.
    ///
    /// Refuses a session that has not finished rather than inventing an `endedAt` for it — the same
    /// refusal `FocusSession.reschedule(start:end:at:)` makes, for the same reason. A running session's
    /// end is not a stored value yet, and the way to change one is the plan line on its card.
    @ViewBuilder private func sessionEditPanel(sessionID: UUID) -> some View {
        if let session = session(withID: sessionID), session.isFinished {
            SessionEditSheet(
                session: session,
                project: project(for: session.projectID),
                now: environment.clock.now,
                onSave: { start, end in
                    correctTimes(session, start: start, end: end)
                    appModel.dismissSheet()
                },
                onCancel: { appModel.dismissSheet() }
            )
        } else {
            // The session was deleted, or finished elsewhere, while this route was up. Nothing to
            // correct, so the sheet closes itself rather than showing a form with no subject — the
            // arrangement every other route here uses for the same race.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { appModel.dismissSheet() }
                .accessibilityHidden(true)
        }
    }

    /// The accomplishment editor, opened from an inbox row. Saving files the accomplishment *and*
    /// settles the interruption, so a row cannot be logged and left waiting at the same time.
    @ViewBuilder private func interruptionAccomplishmentPanel(interruptionID: UUID) -> some View {
        if let interruption = inbox.pending.first(where: { $0.id == interruptionID }) {
            AccomplishmentEditor(
                accomplishment: inbox.accomplishmentSeed(for: interruption),
                projects: manager.projects,
                onSave: { accomplishment in
                    Task {
                        await inbox.convertToAccomplishment(
                            interruption,
                            accomplishment: accomplishment
                        )
                    }
                    appModel.dismissSheet()
                },
                onCancel: { appModel.dismissSheet() }
            )
        } else {
            // The row was processed from somewhere else while this route was up. Nothing to file, so
            // the sheet closes itself rather than showing a form with no subject.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { appModel.dismissSheet() }
                .accessibilityHidden(true)
        }
    }

    // MARK: - The inbox

    private var inboxScreen: some View {
        InterruptionInboxView(
            interruptions: inbox.pending,
            processed: inbox.processed,
            projects: manager.projects,
            failure: inbox.failure,
            actions: InterruptionInboxActions(
                capture: { appModel.presentCapture(inPopover: false) },
                convertToSession: { interruption in
                    Task { await inbox.convertToSession(interruption) }
                },
                logAccomplishment: { interruption in
                    appModel.present(.interruptionAccomplishment(interruptionID: interruption.id))
                },
                fileUnderProject: { interruption, projectID in
                    Task { await inbox.fileUnderProject(interruption, projectID: projectID) }
                },
                dismiss: { interruption in
                    Task { await inbox.dismiss(interruption) }
                },
                returnToInbox: { interruption in
                    Task { await inbox.returnToInbox(interruption) }
                },
                delete: { interruption in
                    Task { await inbox.delete(interruption) }
                },
                dismissFailure: { inbox.clearFailure() }
            )
        )
        .navigationTitle("Interruptions")
    }

    @ViewBuilder private var reviewPanel: some View {
        if let session = manager.pendingReview {
            SessionReviewSheet(
                session: session,
                project: project(for: session.projectID),
                suggestedSummary: manager.suggestedSummary(for: session),
                regenerate: { manager.suggestedSummary(for: session) },
                // `saveFailed` raises the one alert in the app. `SessionManager` reports a failed
                // write through `lastError`, which the banner above already carries, and it clears
                // `pendingReview` before persisting — so there is no state here that could tell the
                // two apart honestly. One surface, not two half-wired ones.
                saveFailed: false,
                onSave: { review in
                    submit(review)
                    appModel.dismissSheet()
                },
                onLogAccomplishment: { review, _ in
                    // Both records are the user's intent, so the review is filed first and the
                    // editor opens on the same session, pre-filled. Swapping the route rather than
                    // raising a second sheet keeps one panel on screen at a time.
                    submit(review)
                    appModel.present(.addAccomplishment(sessionID: session.id))
                },
                onNotNow: {
                    Task { await manager.discardReview() }
                    appModel.dismissSheet()
                }
            )
        } else {
            // The review was filed from somewhere else while this route was up. Nothing to answer,
            // so the sheet closes itself instead of showing an empty form.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { appModel.dismissSheet() }
                .accessibilityHidden(true)
        }
    }

    // MARK: - Behaviour

    /// Opens the review sheet for a finished session, whether it is the one that just ended or one
    /// from six months ago.
    ///
    /// The session already waiting for review needs nothing; anything else is re-offered through
    /// `offerReview(for:)`, which refuses a session that already has a result. That refusal is why the
    /// `Review` control is only ever rendered for a session without one.
    /// Ends the session and asks "What happened?" — § 5.3's "triggered by Finish".
    ///
    /// The same pairing `AppCommands.finish()` performs, and for the same reason it is here rather
    /// than in an observer on `pendingReview`: `bootstrap()` also sets that property, and a sheet that
    /// opened by itself at launch would be interrogating somebody who has just arrived.
    private func finishSession() {
        Task {
            await manager.finishSession()
            guard manager.pendingReview != nil else { return }
            appModel.presentReview()
        }
    }

    private func review(_ session: FocusSession) {
        if manager.pendingReview?.id != session.id {
            guard manager.offerReview(for: session) else { return }
        }
        appModel.presentReview()
    }

    /// Discards the session in flight. Confirmed on the card before this is reached.
    private func discardActiveSession() {
        Task {
            guard await manager.discardActiveSession() else { return }
            // A discarded session was never in the history — it had not finished — but the range may
            // have been loaded before it was started, so this costs one local read and removes the one
            // state where a deleted record could still be on screen.
            await sessionsModel.reloadIfCurrent()
        }
    }

    /// Deletes a session. Confirmed on the row before this is reached.
    ///
    /// Interface first, disk second: the row leaves the list and any detail pushed on top of it is
    /// popped, then the write goes out. A pushed screen describing a record that no longer exists is
    /// the one state a delete must not leave behind.
    private func delete(_ session: FocusSession) {
        if sessionsModel.detail?.session.id == session.id { popDetail() }
        sessionsModel.remove(sessionID: session.id)
        Task { await manager.deleteSession(id: session.id) }
    }

    /// Writes corrected times, then brings every screen showing that session up to date.
    ///
    /// The warning about reduced pause time has already been read: `SessionEditSheet` puts it in front
    /// of the user before it calls this, from the same `SessionRescheduleResult` the write applies.
    private func correctTimes(_ session: FocusSession, start: Date, end: Date) {
        Task {
            guard
                let outcome = await manager.reschedule(session: session, start: start, end: end)
            else { return }
            // The corrected record first, so the list and any open detail move at once.
            sessionsModel.apply(outcome.corrected)
            // Then the range, because a corrected start can move a session to another day — or out of
            // the window on screen entirely, which is the point of correcting a forgotten stop time.
            await sessionsModel.reload()
        }
    }

    /// Turns a block into a session and files it.
    ///
    /// The claim is recomputed here rather than reusing the one the sheet opened on: the sampler may
    /// have flushed and a session may have finished while the user was typing, and the arithmetic that
    /// decides the bounds must be the arithmetic that runs last. A refusal at this point is the honest
    /// outcome — the record already accounts for the span — and it surfaces through the same banner
    /// every other failure in the detail column uses rather than silently writing nothing.
    private func labelBlock(_ episode: Episode, as label: SessionFromEpisode.Label) {
        switch timelineModel.reconstruction(for: episode, label: label, at: environment.clock.now) {
        case .success(let reconstruction):
            Task {
                guard await manager.fileReconstructed(reconstruction.session) else { return }
                // The block is now part of a session, so the segmenter has new ground truth to cut on
                // and the row it came from changes to the user's own sentence. `todaySessions` changing
                // rebuilds the timeline through this screen's own `onChange`; the history range is
                // re-read here because a labelled block belongs in it too.
                await sessionsModel.reloadIfCurrent()
            }
        case .failure(let refusal):
            manager.surface(refusal.sentence)
        }
    }

    private func submit(_ review: SessionReview) {
        Task {
            await manager.submitReview(
                status: review.status,
                summary: review.summary,
                blocker: review.blocker,
                nextStep: review.nextStep
            )
            // The reviewed session may be anywhere in history, not just today, so the range on screen
            // is re-read rather than assumed to have been refreshed by `submitReview`.
            await sessionsModel.reload()
        }
    }

    // MARK: - Pushing a session

    /// Pushes a session's detail view and starts filling it in.
    private func open(_ session: FocusSession) {
        Task { await sessionsModel.openDetail(session) }
        appModel.detailPath.append(SessionRoute(sessionID: session.id))
    }

    /// Pushes by id, for a caller that has a reference rather than a record — the log's
    /// "Open source session".
    private func open(sessionID: UUID) {
        Task { await sessionsModel.openDetail(sessionID: sessionID) }
        appModel.detailPath.append(SessionRoute(sessionID: sessionID))
    }

    private func popDetail() {
        guard !appModel.detailPath.isEmpty else { return }
        appModel.detailPath.removeLast()
        sessionsModel.closeDetail()
    }

    // MARK: - Lookups

    /// The banner's one way out. Absent only for the in-memory fallback, which has no folder to
    /// show — and in that case the banner's own sentence is already the whole story.
    private var recoveryTitle: String? {
        environment.storage.folderURL == nil ? nil : "Show in Finder"
    }

    private func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return manager.projects.first { $0.id == id }
    }

    /// Resolves an id against everything this window currently holds.
    ///
    /// The order is nearest-first: the session in flight and the one awaiting review are the live
    /// copies, today's list next, then the pushed detail and the loaded history range. A route carries
    /// an id precisely so it can be raised from any of those five and still find its subject.
    private func session(withID id: UUID) -> FocusSession? {
        if let pending = manager.pendingReview, pending.id == id { return pending }
        if let active = manager.activeSession, active.id == id { return active }
        if let today = manager.todaySessions.first(where: { $0.id == id }) { return today }
        if let open = sessionsModel.detail?.session, open.id == id { return open }
        return sessionsModel.sessions.first { $0.id == id }
    }

    /// A blank accomplishment, or one pre-filled from the session that offered it.
    private func seedAccomplishment(sessionID: UUID?) -> Accomplishment {
        guard let sessionID, let session = session(withID: sessionID) else {
            return Accomplishment(title: "", timestamp: environment.clock.now)
        }
        return Accomplishment(
            projectID: session.projectID,
            focusSessionID: session.id,
            title: session.intendedOutcome,
            timestamp: session.endedAt ?? environment.clock.now
        )
    }
}

// MARK: - Error banner

/// The one error surface in the application. See `04-screens.md` § 3.3.
///
/// Inline at the top of the detail column, never a modal, and **never red** — the symbol is
/// `.secondary` and the fill is an ordinary card. One sentence that says what failed and reassures
/// about the data, in that order, plus a way out. It is dismissible with `⌘.` or the trailing
/// `xmark` that appears on hover, and it returns on the next failure.
struct ErrorBanner: View {

    /// Whether the sentence is a failure or a fact.
    ///
    /// One surface, two things it can be saying. `.failure` is every existing caller and is the
    /// default, so no call site, no glyph and no announcement changes. `.notice` exists for the
    /// automatic close, whose sentence explains a number rather than reporting a fault — announcing
    /// "Error, ended at 12:04, the last input Lggr recorded" would turn provenance into a warning,
    /// which is the one thing every note about `autoClosedAt` says it must not be.
    enum Kind: Hashable {
        case failure
        case notice

        /// What VoiceOver leads with.
        var spokenRole: String {
            switch self {
            case .failure: "Error"
            case .notice: "Notice"
            }
        }

        var symbolName: String {
            switch self {
            case .failure: Icon.error
            case .notice: Icon.notice
            }
        }
    }

    let message: String
    let recoveryTitle: String?
    var kind: Kind = .failure
    let onRecover: () -> Void
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: kind.symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s) {
                Text(message)
                    .font(Type.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let recoveryTitle {
                    Button(recoveryTitle, action: onRecover)
                        .buttonStyle(.borderless)
                        .font(Type.secondary)
                }
            }

            Spacer(minLength: Space.s)

            Button(action: onDismiss) {
                Image(systemName: Icon.dismiss)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .opacity(isHovering ? 1 : 0)
            .accessibilityLabel("Dismiss")
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.raised, in: Theme.cardShape)
        .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.spokenRole)
        .accessibilityValue(message)
    }
}
