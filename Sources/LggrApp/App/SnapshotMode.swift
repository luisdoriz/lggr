import AppKit
import LggrKit
import SwiftUI

/// Renders each Phase 2 screen to a PNG, in both appearances, then exits.
///
/// `#Preview` cannot compile without Xcode (see docs/_design/CONSTRAINTS.md), which would otherwise
/// leave the entire visual design unreviewable — and "looks right in light and dark mode" is a
/// requirement, not a nicety. `ImageRenderer` needs no window, no screen-recording permission and no
/// running app, so the build can photograph its own UI:
///
///     Scripts/snapshot.sh
///
/// A separate snapshot *target* is not possible: SwiftPM cannot import an executable target, and
/// restructuring the app into a library purely to photograph it would be a worse trade than one
/// launch flag.
@MainActor
enum SnapshotMode {

    static let flag = "--snapshot"

    /// The directory to render into, when the process was launched to take snapshots.
    static var requestedDirectory: URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// ### A wrong hour on nearly every screen, and why the camera cannot fix it
    ///
    /// `PreviewFixtures.dayStart` is 22:40 UTC — not midnight in any zone — even though its own comment
    /// says 00:00 UTC. Every fixture time is an offset from it, so `PreviewFixtures.time(9, 0)` resolves
    /// to 01:40 the next morning here, 07:40 in London and something else again in Tokyo. Today,
    /// Focus Sessions and the log therefore all photograph a working day that runs from 12:52 a.m. to
    /// 9:05 a.m., and no two reviewers see the same image.
    ///
    /// The obvious fix is to pin the process to a zone in which `dayStart` *is* midnight
    /// (`NSTimeZone.default = TimeZone(secondsFromGMT: 4_800)`). **It was tried and it makes things
    /// worse.** `Calendar.current` follows `NSTimeZone.default`, but `TimeZone.current`,
    /// `TimeZone.autoupdatingCurrent` and therefore every `Date.FormatStyle` — which is what the views
    /// print with — do not. Grouping moves a day and the printed labels stay put, so the Weekly Review
    /// came back headed "Week of January 6" over a week whose first bar was labelled Saturday.
    ///
    /// So the fixture instant is the thing that is wrong, `PreviewFixtures` is `LggrKit`'s, and a
    /// snapshot reader should read 1:40 a.m. as "9:00 in the fixture" rather than as a defect in the
    /// screen. `WeeklySnapshotFixtures` sidesteps it by anchoring to a real calendar week instead.
    static func run(writingTo directory: URL) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            FileHandle.standardError.write(
                Data("error: could not create \(directory.path): \(error)\n".utf8)
            )
            exit(1)
        }

        var written = 0
        var failed: [String] = []

        for screen in screens {
            for scheme in [ColorScheme.light, .dark] {
                let suffix = scheme == .light ? "light" : "dark"
                let url = directory.appendingPathComponent("\(screen.name)-\(suffix).png")
                if render(screen.content(), scheme: scheme, to: url) {
                    written += 1
                } else {
                    failed.append(url.lastPathComponent)
                }
            }
        }

        print("wrote \(written) snapshots to \(directory.path)")
        for gap in unphotographable {
            print("not rendered — \(gap.screen): \(gap.reason)")
        }
        if !failed.isEmpty {
            print("failed: \(failed.joined(separator: ", "))")
        }
        exit(failed.isEmpty ? 0 : 1)
    }

    private struct Screen {
        let name: String
        let content: () -> AnyView
    }

    /// Screens `ImageRenderer` cannot draw, named here so the gap is stated on every run rather than
    /// discovered by noticing an absence in a folder of 44 files.
    ///
    /// Registering them as `Screen`s instead would be worse in both directions: `snapshot.sh` would
    /// exit non-zero forever, and the pressure to make the exit code green would be pressure to reshape
    /// a working screen so a camera can see it — which `SPIKE-menubar.md` rules out explicitly.
    private static let unphotographable: [(screen: String, reason: String)] = [
        (
            "Settings (⌘7 and ⌘,)",
            "TabView draws as SwiftUI's yellow unsupported-view placeholder and Form(.formStyle(.grouped)) "
                + "draws as an empty rectangle. Both are correct in the running app; § 4.7 requires the "
                + "grouped form. Screenshot it: Scripts/make-app.sh debug && open build/Lggr.app, then ⌘,"
        )
    ]

    private static var screens: [Screen] {
        [
            Screen(name: "today") {
                AnyView(
                    TodayView(
                        today: PreviewFixtures.now,
                        hasActiveSession: false,
                        sessions: PreviewFixtures.finishedSessions,
                        accomplishments: PreviewFixtures.accomplishments,
                        projects: PreviewFixtures.projects,
                        timeline: PreviewFixtures.dayTimeline,
                        interruptions: InterruptionSnapshotFixtures.pendingInterruptions,
                        sessionCard: { EmptyView() }
                    )
                    // Tall on purpose. Today's lists live in a `LazyVStack` inside a `ScrollView`,
                    // and lazy content only materialises rows that fall inside the viewport — at a
                    // window-sized height the snapshot comes back with the header and nothing else,
                    // which looks like a bug in the screen rather than in the camera.
                    .frame(width: 900, height: 1_960)
                )
            },
            Screen(name: "today-empty") {
                AnyView(
                    TodayView(
                        today: PreviewFixtures.now,
                        hasActiveSession: false,
                        sessions: [],
                        accomplishments: [],
                        projects: [],
                        sessionCard: { EmptyView() }
                    )
                    .frame(width: 900, height: 620)
                )
            },
            // The timeline strip on its own, at the width Today gives it. Photographed separately
            // because the confidence distinction it carries — a solid rail against a dashed one —
            // is a two-pixel decision, and it has to survive both appearances at full size.
            Screen(name: "day-timeline") {
                AnyView(
                    DayTimelineStrip(timeline: PreviewFixtures.dayTimeline)
                        .padding(Space.xl)
                        .frame(width: 900, height: 900, alignment: .top)
                        .background(Surface.canvas)
                )
            },
            Screen(name: "active-session") {
                AnyView(
                    // Wired the way the running app wires it, so the plan line and the discard
                    // affordance are in the photograph. Handed `nil` they are absent, which is right in
                    // a host that cannot perform them and useless in a review.
                    ActiveSessionView(
                        session: PreviewFixtures.runningSession,
                        project: PreviewFixtures.projects.first,
                        now: { PreviewFixtures.now },
                        onTogglePause: {},
                        onFinish: {},
                        onAdjustPlan: { _ in },
                        onSetPlan: { _ in },
                        onDiscard: {}
                    )
                    .frame(width: 900, height: 560)
                )
            },
            Screen(name: "start-session") {
                AnyView(
                    StartSessionForm(
                        context: StartSessionContext(
                            projects: PreviewFixtures.projects,
                            recentOutcomes: [
                                "Finish the receipt deduplication PR",
                                "Review the ingestion rollout plan",
                            ],
                            lastProjectID: PreviewFixtures.receiptIngestionID,
                            lastWorkType: .deepWork
                        ),
                        onStart: { _ in },
                        onDismiss: {}
                    )
                    .padding(24)
                )
            },
            Screen(name: "session-review") {
                AnyView(
                    SessionReviewSheet(
                        session: PreviewFixtures.finishedSessions.first
                            ?? PreviewFixtures.runningSession,
                        project: PreviewFixtures.projects.first,
                        suggestedSummary:
                            "Deep work on Receipt ingestion for 50 minutes.",
                        onSave: { _ in },
                        onLogAccomplishment: { _, _ in },
                        onNotNow: {}
                    )
                    .padding(24)
                )
            },
            Screen(name: "settings-alerts") {
                AnyView(
                    AlertSettingsView(
                        gate: SettingsSnapshotFixtures.allowedGate,
                        preferences: SettingsSnapshotFixtures.preferences
                    )
                    .frame(width: 620, height: 900, alignment: .top)
                    .background(Surface.canvas)
                )
            },
            Screen(name: "settings-alerts-not-asked") {
                AnyView(
                    AlertSettingsView(
                        gate: SettingsSnapshotFixtures.notAskedGate,
                        preferences: SettingsSnapshotFixtures.preferences
                    )
                    .frame(width: 620, height: 900, alignment: .top)
                    .background(Surface.canvas)
                )
            },
            Screen(name: "settings-privacy") {
                AnyView(
                    PrivacySettingsView(model: SettingsSnapshotFixtures.privacy)
                    .frame(width: 620, height: 1000, alignment: .top)
                    .background(Surface.canvas)
                )
            },
            Screen(name: "menubar-idle") {
                AnyView(
                    MenuBarIdleView(
                        footer: MenuBarTodayFooter(sessions: PreviewFixtures.finishedSessions),
                        inboxCount: 2,
                        // Every row live, because every row is live in the app. A `nil` capture
                        // action would photograph the dimmed state and misreport the build.
                        actions: MenuBarIdleView.Actions(captureInterruption: {}),
                        // A frozen state, never the live controls: a pre-computed state reads nothing
                        // observable, which is exactly what a photograph wants and exactly what the
                        // menu bar must never have.
                        tracking: .fixed(.tracking)
                    )
                )
            },
            Screen(name: "menubar-tracking-paused") {
                AnyView(
                    MenuBarIdleView(
                        footer: MenuBarTodayFooter(sessions: PreviewFixtures.finishedSessions),
                        actions: MenuBarIdleView.Actions(captureInterruption: {}),
                        tracking: .fixed(.paused)
                    )
                )
            },
            Screen(name: "interruption-capture") {
                AnyView(
                    InterruptionCaptureSheet(
                        draft: "Review Omar's blocked PR",
                        onSave: { _, _ in true }
                    )
                    .padding(24)
                )
            },
            Screen(name: "interruption-inbox") {
                AnyView(
                    InterruptionInboxView(
                        interruptions: InterruptionSnapshotFixtures.pendingInterruptions,
                        processed: InterruptionSnapshotFixtures.processedInterruptions,
                        projects: PreviewFixtures.projects
                    )
                    .frame(width: 900, height: 460)
                )
            },
            Screen(name: "rules") {
                AnyView(
                    RulesView(
                        model: RulesModel.gallery(rules: RulesSnapshotFixtures.rules),
                        projects: PreviewFixtures.projects
                    )
                    // Tall on purpose: the built-in section is ten rows below the user's own, and the
                    // point of this snapshot is that a shipped row reads as quieter than a row the
                    // user wrote.
                    .frame(width: 900, height: 820)
                )
            },
            // The window-title editor, photographed on its own because the note in it is the
            // strongest privacy claim in the product (INTELLIGENCE.md §3.3) and it has to be legible
            // rather than merely present.
            Screen(name: "rule-editor-window-title") {
                AnyView(
                    RuleEditor(
                        rule: RulesSnapshotFixtures.titleRule,
                        projects: PreviewFixtures.projects,
                        onSave: { _ in }
                    )
                    .padding(24)
                )
            },
            // Correcting a finished session's times, in both of the states that matter: the sheet as it
            // opens, and the sheet with the one thing it has to say before it writes.
            Screen(name: "session-edit") {
                AnyView(
                    SessionEditSheet(
                        session: HistorySnapshotFixtures.pausedSession,
                        project: PreviewFixtures.projects.first,
                        now: PreviewFixtures.now,
                        onSave: { _, _ in }
                    )
                    .padding(24)
                )
            },
            // Design decision B on screen: the span has been shortened below the pauses the session
            // recorded, so the sheet states what saving would cost — inline, in `.secondary`, above the
            // buttons, and never as an alert.
            Screen(name: "session-edit-shrinks-pauses") {
                AnyView(
                    SessionEditSheet(
                        session: HistorySnapshotFixtures.pausedSession,
                        project: PreviewFixtures.projects.first,
                        now: PreviewFixtures.now,
                        draftEnd: HistorySnapshotFixtures.pausedSession.startedAt
                            .addingTimeInterval(3 * 60),
                        onSave: { _, _ in }
                    )
                    .padding(24)
                )
            },
            // The end-of-day queue, and the same queue with nothing left in it.
            //
            // Photographed because this sheet's *copy* is the risky part rather than its layout: it is
            // the one screen in the app that reports what the user did not declare, and the line
            // between "3 blocks from today aren't labelled" and an accusation is a matter of words.
            // Reviewing words on a machine with no Xcode means photographing them.
            Screen(name: "end-of-day-review") {
                AnyView(
                    EndOfDayReviewSheet(
                        items: UnlabelledWork.report(
                            for: PreviewFixtures.dayTimeline,
                            // The fixture day is a realistic one, so its blocks do not all clear the
                            // twenty-minute bar. Lowered here so the photograph shows a queue rather
                            // than the closing panel; the shipped constant is untouched.
                            policy: UnlabelledWork.Policy(minimumBlockDuration: 5 * 60)
                        )
                        .blocks
                        .map { episode in
                            EndOfDayReviewSheet.Item(
                                episode: episode,
                                claim: SessionFromEpisode.claim(for: episode, existingSessions: [])
                            )
                        },
                        projects: PreviewFixtures.projects,
                        recentOutcomes: PreviewFixtures.preferences.recentOutcomes,
                        estimateText: "about 2 minutes",
                        onFile: { _, _ in }
                    )
                    .padding(24)
                )
            },
            // Nothing left to label, which is the common state for a well-declared day. A fact and a
            // way out — no praise, no count of what was filed, no score.
            Screen(name: "end-of-day-review-empty") {
                AnyView(
                    EndOfDayReviewSheet(items: [], onFile: { _, _ in })
                        .padding(24)
                )
            },
            Screen(name: "rule-offer") {
                AnyView(
                    ReclassifySheet(
                        offer: RulesSnapshotFixtures.ruleOffer,
                        projects: PreviewFixtures.projects,
                        onCreate: {},
                        onNotNow: {}
                    )
                    .padding(24)
                )
            },
            // The two history screens. Tall frames for the same reason Today's is: their rows live in
            // a `LazyVStack`, and lazy content only materialises what falls inside the frame.
            Screen(name: "sessions-history") {
                AnyView(
                    SessionsListView(
                        window: HistorySnapshotFixtures.currentWindow,
                        days: HistorySnapshotFixtures.days,
                        projects: PreviewFixtures.projects,
                        sessionsInWindow: HistorySnapshotFixtures.sessions.count,
                        isFiltering: false,
                        searchText: .constant(""),
                        projectFilter: .constant(nil),
                        actions: SessionsActions(review: { _ in })
                    )
                    .frame(width: 900, height: 960)
                )
            },
            Screen(name: "sessions-history-empty") {
                AnyView(
                    SessionsListView(
                        window: HistorySnapshotFixtures.currentWindow,
                        days: [],
                        projects: PreviewFixtures.projects
                    )
                    .frame(width: 900, height: 620)
                )
            },
            // One session with everything it can record: a result, all four written fields, the blocks
            // ambient capture gave its span, an interruption captured inside it, and what it delivered.
            Screen(name: "session-detail") {
                AnyView(
                    SessionDetailView(
                        session: HistorySnapshotFixtures.detailedSession,
                        project: PreviewFixtures.projects.first,
                        episodes: HistorySnapshotFixtures.detailEpisodes,
                        interruptions: HistorySnapshotFixtures.detailInterruptions,
                        accomplishments: HistorySnapshotFixtures.detailAccomplishments,
                        projects: PreviewFixtures.projects,
                        actions: SessionDetailActions(save: { _ in }, editTimes: {})
                    )
                    .frame(width: 900, height: 1_320)
                )
            },
            // The same screen for a session that finished without an answer: offered for review, never
            // flagged as abandoned.
            Screen(name: "session-detail-unreviewed") {
                AnyView(
                    SessionDetailView(
                        session: HistorySnapshotFixtures.unreviewedSession,
                        project: nil,
                        actions: SessionDetailActions(review: {}, save: { _ in })
                    )
                    .frame(width: 900, height: 900)
                )
            },
            Screen(name: "accomplishments-log") {
                AnyView(
                    AccomplishmentsLogView(
                        window: HistorySnapshotFixtures.currentWindow,
                        weeks: HistorySnapshotFixtures.weeks,
                        projects: PreviewFixtures.projects,
                        entriesInWindow: HistorySnapshotFixtures.logEntries.count,
                        availableTypes: HistorySnapshotFixtures.logTypes,
                        availableProjects: PreviewFixtures.projects,
                        searchText: .constant(""),
                        typeFilter: .constant(nil),
                        projectFilter: .constant(nil)
                    )
                    .frame(width: 900, height: 1_260)
                )
            },
            Screen(name: "accomplishments-log-empty") {
                AnyView(
                    AccomplishmentsLogView(
                        window: HistorySnapshotFixtures.currentWindow,
                        weeks: [],
                        projects: PreviewFixtures.projects
                    )
                    .frame(width: 900, height: 620)
                )
            },
            // The week, answered. Every seat filled and every section carrying data, because the thing
            // to judge here is whether eight stacked sections still read as calm — the screen most at
            // risk of turning into the dashboard § 4.1 refuses to build.
            Screen(name: "weekly-review") {
                AnyView(
                    WeeklyReviewView(
                        review: WeeklySnapshotFixtures.review,
                        observations: WeeklySnapshotFixtures.observations,
                        projects: PreviewFixtures.projects,
                        actions: WeeklyReviewActions(
                            setOutcomeStatus: { _, _ in },
                            deleteOutcome: { _ in },
                            exportReview: {}
                        )
                    )
                    .frame(width: 900, height: 2_060)
                )
            },
            // A week with nothing in it. § 4.4's copy insists this is not a shortfall, and the
            // photograph is how that claim gets checked.
            Screen(name: "weekly-review-empty") {
                AnyView(
                    WeeklyReviewView(
                        review: WeeklySnapshotFixtures.emptyReview,
                        observations: [],
                        projects: PreviewFixtures.projects
                    )
                    .frame(width: 900, height: 620)
                )
            },
            // Settings is missing from this list on purpose — see `unphotographable`. Both panes were
            // wired up and rendered before that conclusion was reached: `SettingsView` came back as a
            // full-frame yellow placeholder (the `TabView`), and `PrivacySettingsView` came back as an
            // empty grey rectangle (the grouped `Form`). `SettingsSnapshotFixtures` is kept below so
            // whoever tries again has the models ready and does not have to rediscover that a camera
            // must not be handed the user's real `UserDefaults`.
        ]
    }

    /// - Returns: whether a file with something in it was written.
    private static func render(_ view: AnyView, scheme: ColorScheme, to url: URL) -> Bool {
        let renderer = ImageRenderer(
            content:
                view
                // Screens swap their `ScrollView` for a plain stack under this flag. An
                // `ImageRenderer` draws a scroll view as nothing whatsoever, so without it the
                // busiest screens photograph as an empty rectangle — see `ScrollingSection`.
                .environment(\.isGalleryMode, true)
                .environment(\.colorScheme, scheme)
                .background(scheme == .light ? Color.white : Color.black)
        )
        // 2× so text rendering can actually be judged rather than guessed at.
        renderer.scale = 2

        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            return false
        }

        // A blank render is a failure, not a snapshot. `ImageRenderer` returns a perfectly valid
        // image of nothing when it cannot draw the content, and a PNG of the background colour is
        // the one output that looks like success while telling the reviewer nothing — the same trap
        // `Scripts/test.sh` exists to close for a suite that runs zero tests.
        guard hasContent(bitmap, scheme: scheme) else {
            return false
        }

        do {
            try png.write(to: url)
            return true
        } catch {
            return false
        }
    }

    /// Whether the bitmap holds ink rather than one flat surface.
    ///
    /// Sampled on a grid rather than pixel by pixel: this runs on images of a few million pixels, and
    /// detecting "the screen drew something" needs a sample, not a census.
    ///
    /// ### Why this does not compare against the backdrop it was told to use
    ///
    /// The first version of this guard did: it counted pixels whose brightness differed from the white
    /// or black `render(_:scheme:to:)` puts behind the view. That version **waved a blank screen
    /// through.** `PrivacySettingsView` is a `Form` with `.formStyle(.grouped)`, which `ImageRenderer`
    /// draws as an empty rectangle of window-grey and nothing else — and grey is a long way from black,
    /// so every sample in a 1800 × 3400 image of nothing counted as content and the file was written.
    ///
    /// So the background is *measured* instead of assumed: the most common brightness in the sample is
    /// whatever the screen actually came back as, flat grey included, and content is what departs from
    /// it. A screen that drew only its own backdrop has almost nothing left over and fails, which is
    /// the whole point of the guard.
    private static func hasContent(_ bitmap: NSBitmapImageRep, scheme: ColorScheme) -> Bool {
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 200)
        let buckets = 32
        var histogram = [Int](repeating: 0, count: buckets)
        var brightnesses: [CGFloat] = []

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let brightness = colour.brightnessComponent
                brightnesses.append(brightness)
                let bucket = min(buckets - 1, max(0, Int(brightness * CGFloat(buckets))))
                histogram[bucket] += 1
            }
        }

        guard let modal = histogram.indices.max(by: { histogram[$0] < histogram[$1] }) else {
            return false
        }
        let background = (CGFloat(modal) + 0.5) / CGFloat(buckets)

        var differing = 0
        for brightness in brightnesses where abs(brightness - background) > 0.06 {
            differing += 1
            // Enough to prove the screen drew itself, and low enough that a nearly empty state — a
            // symbol, two lines and a button — still counts.
            if differing >= 200 { return true }
        }
        return false
    }
}

// MARK: - Fixtures the gallery needs and `LggrKit` does not have

/// Interruptions for the inbox snapshot.
///
/// Local rather than in `PreviewFixtures`: these exist to photograph one screen, and the shared
/// fixtures are a description of a working day that several tests assert against. Timestamps hang
/// off `PreviewFixtures.time(_:_:)` so the inbox reads as part of the same day as Today does.
enum InterruptionSnapshotFixtures {

    static let pendingInterruptions: [Interruption] = [
        Interruption(
            focusSessionID: PreviewFixtures.runningSession.id,
            description: "Review Omar's blocked PR",
            source: .person,
            timestamp: PreviewFixtures.time(10, 12)
        ),
        Interruption(
            description: "Reply to finance about the Q3 invoice",
            source: .email,
            timestamp: PreviewFixtures.time(15, 47)
        ),
        Interruption(
            focusSessionID: PreviewFixtures.runningSession.id,
            description: "Check whether the ingestion alert fired twice",
            source: .incident,
            timestamp: PreviewFixtures.time(16, 5)
        ),
    ]

    static let processedInterruptions: [Interruption] = {
        var dismissed = Interruption(
            description: "Look at the new dashboard someone shared",
            source: .message,
            timestamp: PreviewFixtures.time(9, 40)
        )
        dismissed.dismiss()

        var converted = Interruption(
            description: "Unblock the mobile team on the retry contract",
            source: .person,
            timestamp: PreviewFixtures.time(11, 2)
        )
        converted.convert(toProjectID: PreviewFixtures.teamLeadershipID)

        return [converted, dismissed]
    }()
}

/// Rules for the `⌘6` snapshot, the window-title editor and the correction offer.
enum RulesSnapshotFixtures {

    /// A window-title rule the user typed, and one that files an application under a project — the two
    /// shapes `04-screens.md` §4.6 draws — on top of everything Lggr ships.
    static let rules: [ClassificationRule] = ClassificationRule.defaults + [
        titleRule,
        ClassificationRule(
            matchType: .application,
            matchValue: "com.figma.Desktop",
            category: .planning,
            projectID: PreviewFixtures.receiptIngestionID,
            priority: 20
        ),
    ]

    /// The one rule kind the user has to type themselves.
    static let titleRule = ClassificationRule(
        matchType: .windowTitleContains,
        matchValue: "Pull request",
        category: .codeReview,
        priority: 30
    )

    /// A correction waiting to be agreed to. Never a title rule — the correction loop cannot derive
    /// one, and this fixture is not allowed to imply otherwise.
    static let ruleOffer = RuleOffer(
        rule: ClassificationRule(
            matchType: .browserDomain,
            matchValue: "figma.com",
            category: .planning,
            priority: 11
        ),
        subject: "figma.com",
        replacedCategory: .research,
        replacesExistingRule: false
    )
}

/// History for the `⌘2` and `⌘3` snapshots.
///
/// `PreviewFixtures` describes one day, which is the right shape for Today and the wrong one for two
/// screens whose whole subject is grouping: a history photographed as a single group proves nothing
/// about the day headings, the pinned section headers, or the air between groups. So this walks the
/// fixture day backwards to build three days of sessions and three weeks of log entries, and every
/// timestamp still hangs off `PreviewFixtures.time(_:_:)` so the two screens read as the same working
/// life Today does.
enum HistorySnapshotFixtures {

    private static let day: TimeInterval = 24 * 60 * 60

    /// The range both screens are showing: the month containing the fixture "now".
    static let currentWindow = HistoryWindow(span: .month, anchor: PreviewFixtures.now)
        .display(now: PreviewFixtures.now, in: .current)

    // MARK: Sessions

    /// A finished session with real pauses inside it: 10:05–10:40 with five minutes paused, so thirty
    /// minutes of active time.
    ///
    /// The subject of the edit sheet's two snapshots, because the pauses are what make design decision
    /// B visible — shorten this span below five minutes and the sheet has something to warn about.
    static let pausedSession = FocusSession(
        id: PreviewFixtures.fixtureID(330),
        projectID: PreviewFixtures.receiptIngestionID,
        intendedOutcome: "Review the ingest retry PR",
        workType: .codeReview,
        plannedDuration: 30 * 60,
        startedAt: PreviewFixtures.time(10, 5),
        endedAt: PreviewFixtures.time(10, 40),
        pausedDuration: 5 * 60,
        resultStatus: .madeProgress
    )

    /// Today's declared work plus two earlier days, so the list has three day groups to head.
    static let sessions: [FocusSession] = {
        var all = PreviewFixtures.finishedSessions

        all += [
            FocusSession(
                id: PreviewFixtures.fixtureID(300),
                projectID: PreviewFixtures.receiptIngestionID,
                intendedOutcome: "Trace the duplicate commission report",
                workType: .incident,
                plannedDuration: 50 * 60,
                startedAt: PreviewFixtures.time(9, 20).addingTimeInterval(-day),
                endedAt: PreviewFixtures.time(10, 15).addingTimeInterval(-day),
                resultStatus: .completed,
                resultSummary: "The duplicates came from a retry that did not carry the idempotency key.",
                interruptionCount: 1
            ),
            FocusSession(
                id: PreviewFixtures.fixtureID(301),
                projectID: PreviewFixtures.teamLeadershipID,
                intendedOutcome: "One-to-ones",
                workType: .management,
                plannedDuration: 25 * 60,
                startedAt: PreviewFixtures.time(14, 0).addingTimeInterval(-day),
                endedAt: PreviewFixtures.time(15, 5).addingTimeInterval(-day),
                resultStatus: .madeProgress
            ),
            FocusSession(
                id: PreviewFixtures.fixtureID(302),
                projectID: PreviewFixtures.platformMigrationID,
                intendedOutcome: "Write the connection-pool migration plan",
                workType: .planning,
                startedAt: PreviewFixtures.time(10, 30).addingTimeInterval(-4 * day),
                endedAt: PreviewFixtures.time(11, 48).addingTimeInterval(-4 * day),
                resultStatus: .completed,
                resultSummary: "Two phases, and the second one needs a maintenance window."
            ),
            FocusSession(
                id: PreviewFixtures.fixtureID(303),
                intendedOutcome: "Clear the review queue",
                workType: .codeReview,
                plannedDuration: 50 * 60,
                startedAt: PreviewFixtures.time(15, 10).addingTimeInterval(-4 * day),
                endedAt: PreviewFixtures.time(16, 2).addingTimeInterval(-4 * day),
                resultStatus: .interrupted,
                interruptionCount: 3
            ),
        ]
        return all
    }()

    static let days: [SessionsModel.Day] = SessionsModel.group(
        sessions,
        in: .current,
        now: PreviewFixtures.now
    )

    // MARK: One session, in full

    /// The morning session, with all four written fields filled in so the detail view is photographed
    /// with content in every one rather than with three empty boxes.
    static let detailedSession: FocusSession = {
        var session = FocusSession(
            id: PreviewFixtures.fixtureID(20),
            projectID: PreviewFixtures.receiptIngestionID,
            intendedOutcome: "Ship the receipt deduplication PR",
            workType: .deepWork,
            plannedDuration: 50 * 60,
            startedAt: PreviewFixtures.time(9, 0),
            endedAt: PreviewFixtures.time(9, 50),
            resultStatus: .completed,
            resultSummary:
                "Deep work in Xcode and Terminal on the deduplication pass, with one trip through the "
                + "simulator to confirm the collapse happens on ingest.",
            tangibleResult: "Pull request #412, open and passing",
            nextStep: "Ask Dana to review the migration before Thursday",
            interruptionCount: 1
        )
        session.blocker = "The backfill needs a maintenance window nobody has booked yet"
        // Corrected by hand an hour after it ran — the ordinary "I forgot to press stop" repair. It is
        // here so the quiet provenance line design decision A asks for is in a photograph, and so a
        // reviewer can check that it reads as a fact about the record rather than as a warning.
        session.editedAt = PreviewFixtures.time(10, 55)
        return session
    }()

    /// The blocks the shipped segmenter gave that session's span — asked for rather than written out,
    /// so the snapshot cannot show a reconstruction the real builder would never produce.
    static let detailEpisodes: [Episode] = PreviewFixtures.dayTimeline.episodes
        .filter { $0.sessionID == PreviewFixtures.fixtureID(20) }

    static let detailInterruptions: [Interruption] = [
        Interruption(
            id: PreviewFixtures.fixtureID(310),
            focusSessionID: PreviewFixtures.fixtureID(20),
            description: "Review Omar's blocked PR",
            source: .person,
            timestamp: PreviewFixtures.time(9, 24)
        )
    ]

    static let detailAccomplishments: [Accomplishment] = PreviewFixtures.accomplishments
        .filter { $0.focusSessionID == PreviewFixtures.fixtureID(20) }

    /// Finished, never answered for. The screen offers it rather than marking it incomplete.
    static let unreviewedSession = FocusSession(
        id: PreviewFixtures.fixtureID(25),
        intendedOutcome: "File the expense reports",
        workType: .administrative,
        plannedDuration: 25 * 60,
        startedAt: PreviewFixtures.time(15, 50),
        endedAt: PreviewFixtures.time(16, 5)
    )

    // MARK: The log

    /// Three weeks of entries, so the log has `This week`, `Last week` and a dated heading to show.
    static let logEntries: [Accomplishment] = {
        var all = PreviewFixtures.accomplishments

        all += [
            Accomplishment(
                id: PreviewFixtures.fixtureID(320),
                projectID: PreviewFixtures.receiptIngestionID,
                type: .incidentResolved,
                title: "Resolved the duplicate commission ingestion",
                details: "The retry path was missing the idempotency key.",
                timestamp: PreviewFixtures.time(10, 20).addingTimeInterval(-day)
            ),
            Accomplishment(
                id: PreviewFixtures.fixtureID(321),
                projectID: PreviewFixtures.teamLeadershipID,
                type: .personUnblocked,
                title: "Unblocked Omar on the ingestion retry",
                timestamp: PreviewFixtures.time(15, 5).addingTimeInterval(-day)
            ),
            Accomplishment(
                id: PreviewFixtures.fixtureID(322),
                projectID: PreviewFixtures.platformMigrationID,
                type: .documentWritten,
                title: "Wrote the connection-pool migration plan",
                timestamp: PreviewFixtures.time(11, 48).addingTimeInterval(-4 * day)
            ),
            Accomplishment(
                id: PreviewFixtures.fixtureID(323),
                type: .pullRequestReviewed,
                title: "Reviewed three blocking pull requests",
                timestamp: PreviewFixtures.time(16, 2).addingTimeInterval(-4 * day)
            ),
            Accomplishment(
                id: PreviewFixtures.fixtureID(324),
                projectID: PreviewFixtures.quarterlyPlanningID,
                type: .riskIdentified,
                title: "Flagged the reporting query as the migration's real risk",
                timestamp: PreviewFixtures.time(11, 30).addingTimeInterval(-9 * day)
            ),
            Accomplishment(
                id: PreviewFixtures.fixtureID(325),
                projectID: PreviewFixtures.receiptIngestionID,
                type: .featureCompleted,
                title: "Shipped the ingest retry budget",
                timestamp: PreviewFixtures.time(17, 10).addingTimeInterval(-11 * day)
            ),
        ]
        return all
    }()

    static let weeks: [AccomplishmentsModel.Week] = AccomplishmentsModel.group(
        logEntries,
        in: CalendarWindows(calendar: .current),
        now: PreviewFixtures.now
    )

    /// The kinds present in the range, in declaration order — what the type filter would offer.
    static let logTypes: [AccomplishmentType] = {
        let present = Set(logEntries.map(\.type))
        return AccomplishmentType.allCases.filter { present.contains($0) }
    }()
}

/// A finished week, for the `⌘4` snapshot.
///
/// Three things make this its own fixture rather than a reuse of `HistorySnapshotFixtures`.
///
/// 1. **It is the week that has ended, not the week in progress.** `PreviewFixtures.now` falls early
///    in its week, so photographing the current one would show a Friday review of a Tuesday — two
///    active days, an empty allocation bar and no observation the generator will speak for. The week
///    before it is complete, which is when a person actually opens this screen.
/// 2. **Times are anchored to the week, not to `PreviewFixtures.dayStart`.** Every timestamp is built
///    with `Calendar` from the week's own Monday, so the work lands on weekdays at working hours and
///    survives a daylight-saving transition inside the week.
/// 3. **The episodes are asked for, never written.** `EpisodeBuilder` reconstructs each day from
///    intervals, exactly as the shipped pipeline does, so the observed-time figures and the per-day
///    context-switch bars cannot show a week the real builder would never produce.
enum WeeklySnapshotFixtures {

    private static let calendar = Calendar.current

    /// The completed week before the one `PreviewFixtures.now` sits in.
    static let week: DateInterval = {
        let fallback = DateInterval(start: PreviewFixtures.dayStart, duration: 7 * 24 * 60 * 60)
        guard let current = calendar.dateInterval(of: .weekOfYear, for: PreviewFixtures.now),
            let earlier = calendar.date(byAdding: .weekOfYear, value: -1, to: current.start),
            let previous = calendar.dateInterval(of: .weekOfYear, for: earlier)
        else { return fallback }
        return previous
    }()

    /// Monday through Friday of that week, whichever day the user's region starts a week on.
    private static let weekdays: [Date] = {
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: week.start) }
        let working = days.filter { (2...6).contains(calendar.component(.weekday, from: $0)) }
        return working.isEmpty ? days : working
    }()

    /// `at(0, 9, 20)` — 9:20 on the Monday. Built through `Calendar` rather than by adding seconds, so
    /// a week containing a clock change still has five days in it at the hours written here.
    private static func at(_ weekday: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = weekdays[min(weekday, weekdays.count - 1)]
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    // MARK: Outcomes

    static let primaryOutcome = WeeklyOutcome(
        id: PreviewFixtures.fixtureID(400),
        title: "Make receipt ingestion trustworthy end to end",
        details: "No duplicate commissions, and a retry path someone else can reason about.",
        priority: .primary,
        status: .inProgress,
        progress: 0.68,
        weekStartDate: week.start,
        projectIDs: [PreviewFixtures.receiptIngestionID],
        createdAt: week.start,
        updatedAt: at(4, 17, 0)
    )

    static let secondaryOutcome = WeeklyOutcome(
        id: PreviewFixtures.fixtureID(401),
        title: "Get the connection-pool migration agreed",
        priority: .secondary,
        status: .achieved,
        progress: 1,
        weekStartDate: week.start,
        projectIDs: [PreviewFixtures.platformMigrationID],
        createdAt: week.start.addingTimeInterval(60),
        updatedAt: at(3, 12, 0)
    )

    static let operationalOutcome = WeeklyOutcome(
        id: PreviewFixtures.fixtureID(402),
        title: "On-call for ingestion",
        priority: .operational,
        status: .inProgress,
        progress: 0,
        weekStartDate: week.start,
        createdAt: week.start.addingTimeInterval(120),
        updatedAt: at(2, 9, 0)
    )

    static let outcomes = WeeklyOutcomeSet(
        weekStart: week.start,
        outcomes: [primaryOutcome, secondaryOutcome, operationalOutcome]
    )

    // MARK: Sessions

    /// Eighteen finished sessions across five days: enough evidence for the observations to speak, and
    /// a spread across every work type so the allocation bar has something to divide.
    static let sessions: [FocusSession] = [
        // Monday
        session(
            10, day: 0, from: (9, 5), to: (9, 58), outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID, type: .deepWork,
            title: "Reproduce the duplicate commission",
            result: .completed,
            summary: "The retry path drops the idempotency key when the first attempt times out."
        ),
        session(
            11, day: 0, from: (10, 20), to: (11, 10), outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID, type: .deepWork,
            title: "Write the deduplication pass", result: .madeProgress, interruptions: 1
        ),
        session(
            12, day: 0, from: (14, 0), to: (14, 50), outcome: nil,
            project: PreviewFixtures.teamLeadershipID, type: .management,
            title: "One-to-ones", result: .completed
        ),
        session(
            13, day: 0, from: (15, 30), to: (16, 12), outcome: nil,
            project: nil, type: .codeReview,
            title: "Clear the review queue", result: .interrupted, interruptions: 2
        ),
        // Tuesday
        session(
            14, day: 1, from: (9, 0), to: (9, 52), outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID, type: .deepWork,
            title: "Ship the receipt deduplication PR", result: .completed,
            summary: "Pull request #412, open and passing."
        ),
        session(
            15, day: 1, from: (10, 15), to: (10, 45), outcome: nil,
            project: nil, type: .incident, title: "Ingestion alert fired twice",
            result: .completed, interruptions: 1
        ),
        session(
            16, day: 1, from: (11, 30), to: (12, 5), outcome: secondaryOutcome,
            project: PreviewFixtures.platformMigrationID, type: .planning,
            title: "Draft the connection-pool migration plan", result: .madeProgress
        ),
        session(
            17, day: 1, from: (14, 30), to: (15, 25), outcome: nil,
            project: PreviewFixtures.teamLeadershipID, type: .communication,
            title: "Answer the support escalations", result: .completed, interruptions: 2
        ),
        // Wednesday
        session(
            18, day: 2, from: (9, 10), to: (10, 5), outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID, type: .deepWork,
            title: "Back-fill the affected receipts", result: .blocked,
            summary: "The backfill needs a maintenance window nobody has booked."
        ),
        session(
            19, day: 2, from: (11, 0), to: (11, 45), outcome: nil,
            project: PreviewFixtures.teamLeadershipID, type: .codeReview,
            title: "Review the mobile retry contract", result: .completed, interruptions: 1
        ),
        session(
            20, day: 2, from: (13, 30), to: (14, 30), outcome: nil,
            project: nil, type: .meeting, title: "Architecture review", result: .madeProgress
        ),
        session(
            21, day: 2, from: (15, 0), to: (15, 40), outcome: nil,
            project: nil, type: .administrative, title: "File the expense reports",
            result: .completed
        ),
        // Thursday
        session(
            22, day: 3, from: (9, 0), to: (10, 10), outcome: secondaryOutcome,
            project: PreviewFixtures.platformMigrationID, type: .deepWork,
            title: "Prototype the pool sizing change", result: .completed
        ),
        session(
            23, day: 3, from: (10, 40), to: (11, 30), outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID, type: .deepWork,
            title: "Add the idempotency regression test", result: .completed, interruptions: 1
        ),
        session(
            24, day: 3, from: (14, 0), to: (15, 5), outcome: nil,
            project: PreviewFixtures.quarterlyPlanningID, type: .planning,
            title: "Rewrite the quarter's objectives", result: .reprioritized
        ),
        // Friday
        session(
            25, day: 4, from: (9, 15), to: (10, 5), outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID, type: .deepWork,
            title: "Land the retry budget", result: .completed, interruptions: 1
        ),
        session(
            26, day: 4, from: (11, 0), to: (11, 40), outcome: nil,
            project: PreviewFixtures.teamLeadershipID, type: .codeReview,
            title: "Review Omar's blocked pull request", result: .completed
        ),
        session(
            27, day: 4, from: (15, 0), to: (16, 30), outcome: secondaryOutcome,
            project: PreviewFixtures.platformMigrationID, type: .communication,
            title: "Walk the platform team through the migration", result: .completed
        ),
    ]

    private static func session(
        _ index: Int,
        day: Int,
        from: (Int, Int),
        to: (Int, Int),
        outcome: WeeklyOutcome?,
        project: UUID?,
        type: WorkType,
        title: String,
        result: SessionResultStatus,
        summary: String? = nil,
        interruptions: Int = 0
    ) -> FocusSession {
        FocusSession(
            id: PreviewFixtures.fixtureID(400 + index),
            projectID: project,
            weeklyOutcomeID: outcome?.id,
            intendedOutcome: title,
            workType: type,
            plannedDuration: 50 * 60,
            startedAt: at(day, from.0, from.1),
            endedAt: at(day, to.0, to.1),
            resultStatus: result,
            resultSummary: summary,
            interruptionCount: interruptions
        )
    }

    // MARK: Accomplishments

    static let accomplishments: [Accomplishment] = [
        entry(
            0, day: 0, at: (9, 58), type: .decisionMade, outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID,
            title: "Traced the duplicate commissions to the retry path"
        ),
        entry(
            1, day: 0, at: (16, 12), type: .pullRequestReviewed, outcome: nil, project: nil,
            title: "Reviewed four blocking pull requests"
        ),
        entry(
            2, day: 1, at: (9, 52), type: .pullRequestOpened, outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID,
            title: "Opened the receipt deduplication PR"
        ),
        entry(
            3, day: 1, at: (10, 45), type: .incidentResolved, outcome: nil, project: nil,
            title: "Resolved the double ingestion alert"
        ),
        entry(
            4, day: 1, at: (15, 25), type: .customerIssueResolved, outcome: nil,
            project: PreviewFixtures.teamLeadershipID,
            title: "Closed the three oldest support escalations"
        ),
        entry(
            5, day: 2, at: (11, 45), type: .personUnblocked, outcome: nil,
            project: PreviewFixtures.teamLeadershipID,
            title: "Unblocked the mobile team on the retry contract"
        ),
        entry(
            6, day: 2, at: (14, 30), type: .riskIdentified, outcome: secondaryOutcome,
            project: PreviewFixtures.platformMigrationID,
            title: "Named the reporting query as the migration's real risk"
        ),
        entry(
            7, day: 3, at: (10, 10), type: .documentWritten, outcome: secondaryOutcome,
            project: PreviewFixtures.platformMigrationID,
            title: "Wrote the connection-pool migration plan"
        ),
        entry(
            8, day: 3, at: (11, 30), type: .featureCompleted, outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID,
            title: "Idempotency regression test in place"
        ),
        entry(
            9, day: 3, at: (15, 5), type: .workDeprioritized, outcome: nil,
            project: PreviewFixtures.quarterlyPlanningID,
            title: "Dropped the CSV importer from this quarter"
        ),
        entry(
            10, day: 4, at: (10, 5), type: .featureCompleted, outcome: primaryOutcome,
            project: PreviewFixtures.receiptIngestionID,
            title: "Shipped the ingest retry budget"
        ),
        entry(
            11, day: 4, at: (11, 40), type: .personUnblocked, outcome: nil,
            project: PreviewFixtures.teamLeadershipID,
            title: "Unblocked Omar on the ingestion retry"
        ),
    ]

    private static func entry(
        _ index: Int,
        day: Int,
        at time: (Int, Int),
        type: AccomplishmentType,
        outcome: WeeklyOutcome?,
        project: UUID?,
        title: String
    ) -> Accomplishment {
        Accomplishment(
            id: PreviewFixtures.fixtureID(440 + index),
            projectID: project,
            weeklyOutcomeID: outcome?.id,
            type: type,
            title: title,
            timestamp: at(day, time.0, time.1)
        )
    }

    // MARK: Interruptions

    /// Nine, with people ahead of every other source. Above `EvidenceThresholds.minimumInterruptions`
    /// so the leading-source observation has the evidence it insists on before it will say anything.
    static let interruptions: [Interruption] = [
        interruption(0, day: 0, at: (10, 42), source: .person, "Review Omar's blocked PR"),
        interruption(1, day: 0, at: (15, 48), source: .person, "Dana on the schema change"),
        interruption(2, day: 1, at: (10, 30), source: .incident, "Ingestion alert fired twice"),
        interruption(3, day: 1, at: (14, 52), source: .person, "Support escalation from Rosa"),
        interruption(4, day: 1, at: (15, 4), source: .email, "Finance about the Q3 invoice"),
        interruption(5, day: 2, at: (11, 20), source: .person, "Mobile team on the retry contract"),
        interruption(6, day: 2, at: (11, 35), source: .message, "Someone shared a dashboard"),
        interruption(7, day: 3, at: (11, 5), source: .person, "Pairing request on the test harness"),
        interruption(8, day: 4, at: (9, 40), source: .meeting, "Pulled into the incident review"),
    ]

    private static func interruption(
        _ index: Int,
        day: Int,
        at time: (Int, Int),
        source: InterruptionSource,
        _ description: String
    ) -> Interruption {
        Interruption(
            id: PreviewFixtures.fixtureID(460 + index),
            description: description,
            source: source,
            timestamp: at(day, time.0, time.1)
        )
    }

    // MARK: Observed time

    /// Five reconstructed days. Each one is a worked stretch of realistic dwells run through
    /// `EpisodeBuilder`, so the observed totals, the block labels and the per-day context-switch counts
    /// are the shipped pipeline's answers rather than numbers typed into a fixture.
    static let episodes: [Episode] = {
        let xcode = ("com.apple.dt.Xcode", "Xcode")
        let terminal = ("com.apple.Terminal", "Terminal")
        let chrome = ("com.google.Chrome", "Google Chrome")
        let slack = ("com.tinyspeck.slackmacgap", "Slack")
        let zoom = ("us.zoom.xos", "Zoom")
        let notes = ("com.apple.Notes", "Notes")

        // One pattern per day, and deliberately different shapes: a coding Monday reads nothing like a
        // Wednesday spent in meetings, and a week of identical days would photograph the bar chart as
        // five bars of the same height.
        let days: [[((String, String), TimeInterval)]] = [
            [(xcode, 240), (terminal, 90), (xcode, 420), (slack, 45), (chrome, 150)],
            [(xcode, 300), (chrome, 120), (xcode, 360), (slack, 60), (terminal, 120)],
            [(zoom, 900), (slack, 120), (chrome, 300), (notes, 240), (slack, 90)],
            [(xcode, 480), (chrome, 180), (terminal, 150), (slack, 60), (xcode, 300)],
            [(chrome, 240), (slack, 180), (xcode, 300), (terminal, 90), (zoom, 420)],
        ]

        var episodes: [Episode] = []
        for (index, pattern) in days.enumerated() {
            var intervals: [ActivityInterval] = []
            var cursor = at(index, 9, 0)
            let end = at(index, 17, 0)
            var step = 0
            while cursor < end {
                let (app, seconds) = pattern[step % pattern.count]
                let length = min(seconds, end.timeIntervalSince(cursor))
                intervals.append(
                    ActivityInterval(
                        id: PreviewFixtures.fixtureID(600 + episodes.count + step + index * 200),
                        bundleIdentifier: app.0,
                        displayName: app.1,
                        start: cursor,
                        end: cursor.addingTimeInterval(length),
                        monotonicDuration: length
                    )
                )
                cursor = cursor.addingTimeInterval(length)
                step += 1
            }

            let dayOfSessions = sessions.filter {
                calendar.isDate($0.startedAt, inSameDayAs: at(index, 12, 0))
            }
            episodes += EpisodeBuilder.build(
                intervals: intervals,
                sessions: dayOfSessions,
                dayStart: at(index, 0, 0),
                sealed: true
            ).episodes
        }
        return episodes
    }()

    // MARK: The review

    static let review: WeeklyReview = WeeklyReviewBuilder.build(
        WeeklyReviewInput(
            week: week,
            sessions: sessions,
            accomplishments: accomplishments,
            interruptions: interruptions,
            episodes: episodes,
            outcomes: outcomes,
            projectNames: Dictionary(
                uniqueKeysWithValues: PreviewFixtures.projects.map { ($0.id, $0.name) }
            ),
            calendar: calendar
        )
    )

    static let observations: [WeeklyObservation] = InsightGenerator.observations(for: review)

    /// A week nobody tracked and nobody declared anything for. `04-screens.md` § 4.4's empty state is
    /// the strongest copy in the product — *there's nothing to fix here* — and it only holds if the
    /// screen really shows that and not a grid of zeroes.
    static let emptyReview: WeeklyReview = WeeklyReviewBuilder.build(
        WeeklyReviewInput(week: week, calendar: calendar)
    )
}

/// What Settings is photographed with.
///
/// Both models are given their own `UserDefaults` suite, for the same reason `RulesModel.gallery` is:
/// `AppPreferences` and `PrivacyModel` write every change straight through to defaults, and a camera
/// must not be able to reach into the preferences of whoever runs it.
@MainActor
enum SettingsSnapshotFixtures {

    private static let suite = UserDefaults(suiteName: "com.lggr.gallery.settings") ?? .standard

    static let preferences = AppPreferences(defaults: suite)

    static let privacy = PrivacyModel(defaults: suite, controls: .fixed(.tracking))

    /// A real-looking location, written out rather than read off this machine, so the pane is
    /// photographed at the path length it will actually have to fit.
    /// Authorization already granted, with every kind switched on — the state the pane spends its
    /// life in, and the one that shows every row's copy at once.
    static let allowedGate = NotificationGate(
        service: RecordingNotificationService(authorization: .allowed),
        switches: NotificationSwitches(
            sessionCompleted: true,
            halfway: true,
            longIdle: true,
            endOfDayReview: true,
            unlabelledBlock: true
        )
    )

    /// Nothing asked for yet, which is what a new user opens. This is the state the pane had never
    /// been photographed in.
    static let notAskedGate = NotificationGate(
        service: RecordingNotificationService(authorization: .notRequested)
    )

    static let storage = StorageSummary(
        backendName: "JSON files",
        folderURL: URL(
            fileURLWithPath: "/Users/you/Library/Application Support/Lggr",
            isDirectory: true
        )
    )
}
