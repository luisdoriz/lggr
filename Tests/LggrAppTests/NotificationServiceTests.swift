import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

// The notification rules, as tests rather than as a convention.
//
// Everything here is a property of `NotificationGate` and of `SessionManager`'s use of it, and every
// one of them is a rule this app cannot afford to break by accident. macOS grants **one** notification
// authorisation for the whole application: a single unwanted banner and the user switches Lggr off in
// System Settings, where it cannot ask again, and every useful notification dies with it.
//
// So the four things asserted below are the four things that would cost the authorisation:
//
//   1. A kind that is switched off is never delivered, and switching it off withdraws what was armed.
//   2. Authorisation is requested when a switch is turned on, once, and never at launch.
//   3. A denial changes nothing except whether banners appear — no re-ask, and no feature stops.
//   4. Nothing fires because time passed. Every content in the catalogue is caused by an event, and
//      the copy is checked for the words that would make it a re-engagement mechanism.

// MARK: - Fixtures

private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 09:00:00 UTC, the same instant the domain suites use.
private let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

private let outcome = "Finish the receipt deduplication PR"

/// A report of `count` unlabelled blocks, for the end-of-day copy.
///
/// Built out of real `Episode` values rather than a hand-written sentence, so the copy asserted here
/// is the copy `UnlabelledWork.Report` actually produces.
private func unlabelledReport(count: Int) -> UnlabelledWork.Report {
    let blocks = (0..<count).map { index in
        Episode(
            start: nineAM.addingTimeInterval(minutes(Double(index) * 40)),
            end: nineAM.addingTimeInterval(minutes(Double(index) * 40 + 30)),
            apps: [
                Episode.AppShare(
                    bundleIdentifier: "com.apple.dt.Xcode",
                    displayName: "Xcode",
                    duration: minutes(28)
                )
            ],
            label: "Xcode",
            labelConfidence: .appRoster
        )
    }
    return UnlabelledWork.Report(blocks: blocks)
}

/// A scratch preferences suite, so a test can never overwrite the real user's settings.
private var scratchDefaults: UserDefaults {
    UserDefaults(suiteName: "com.lggr.tests.notifications") ?? .standard
}

@MainActor
private func makeGate(
    switches: NotificationSwitches = .allOff,
    authorization: NotificationAuthorization = .notRequested,
    responseToRequest: NotificationAuthorization = .allowed
) -> (gate: NotificationGate, service: RecordingNotificationService) {
    let service = RecordingNotificationService(
        authorization: authorization,
        responseToRequest: responseToRequest
    )
    return (NotificationGate(service: service, switches: switches), service)
}

// MARK: - The gate

@Suite("Notification gate")
@MainActor
struct NotificationGateTests {

    @Test("Nothing is authorised, and nothing is asked, until a switch is turned on")
    func launchAsksForNothing() async {
        let (gate, service) = makeGate()

        // Exactly what `AppEnvironment.bootstrap()` does. This is the first permission Lggr has ever
        // requested, and launch is not allowed to be the thing that requests it.
        await gate.prepare()

        #expect(service.authorizationRequests == 0)
        #expect(gate.authorization == .notRequested)
        #expect(!gate.switches.hasAnyEnabled)
        #expect(service.registeredCategories)
    }

    @Test("Every kind is off on a fresh install")
    func everythingDefaultsOff() {
        for kind in NotificationKind.allCases {
            #expect(!NotificationSwitches.allOff.isEnabled(kind))
        }
        #expect(!NotificationSwitches.allOff.hasAnyEnabled)
    }

    @Test("Turning a switch on is what requests authorisation, and it requests it once")
    func enablingRequestsAuthorizationOnce() async {
        let (gate, service) = makeGate()

        await gate.setEnabled(true, for: .sessionCompleted)
        #expect(service.authorizationRequests == 1)
        #expect(gate.authorization == .allowed)

        // A second kind must not produce a second prompt: `canRequest` is false once macOS has
        // answered, in either direction.
        await gate.setEnabled(true, for: .halfway)
        #expect(service.authorizationRequests == 1)
    }

    @Test("Turning a switch off asks for nothing and withdraws what was armed")
    func disablingCancelsAndAsksNothing() async {
        let (gate, service) = makeGate(authorization: .allowed)

        await gate.setEnabled(true, for: .halfway)
        await gate.post(NotificationCopy.halfway(outcome: outcome, remaining: minutes(25)))
        #expect(gate.switches.halfway)
        #expect(service.pending(.halfway) != nil)

        await gate.setEnabled(false, for: .halfway)
        #expect(service.authorizationRequests == 0)
        #expect(service.cancelled.contains(.halfway))
        #expect(service.pending(.halfway) == nil)
    }

    @Test("A kind that is switched off is dropped, and anything pending for it is withdrawn")
    func offMeansOff() async {
        let (gate, service) = makeGate(switches: .allOff, authorization: .allowed)

        await gate.post(NotificationCopy.halfway(outcome: outcome, remaining: minutes(25)))

        #expect(service.posted.isEmpty)
        #expect(service.cancelled.contains(.halfway))
    }

    @Test("One switch does not carry another: enabling one leaves the rest off")
    func switchesAreIndependent() async {
        let (gate, service) = makeGate(authorization: .allowed)
        await gate.setEnabled(true, for: .longIdle)

        await gate.post(NotificationCopy.halfway(outcome: outcome, remaining: minutes(25)))
        await gate.post(
            NotificationCopy.longIdle(silence: minutes(20), proposedEndText: "12:04")
        )

        #expect(service.posted.count == 1)
        #expect(service.posted.first?.kind == .longIdle)
    }

    @Test("A denial delivers nothing, is never re-asked, and leaves the switch where the user put it")
    func denialDegradesSilently() async {
        let (gate, service) = makeGate(responseToRequest: .denied)

        await gate.setEnabled(true, for: .sessionCompleted)
        #expect(gate.authorization == .denied)
        // The switch stays on. Silently unticking the box the user just ticked would leave them with
        // no way to see what they chose, and macOS is the thing saying no.
        #expect(gate.switches.sessionCompleted)

        await gate.post(NotificationCopy.sessionCompleted(outcome: outcome, duration: minutes(50)))
        #expect(service.posted.isEmpty)
        #expect(!gate.isDelivering)

        // No second ask, ever — not on the next enable, not at the next launch.
        await gate.setEnabled(true, for: .halfway)
        await gate.prepare()
        #expect(service.authorizationRequests == 1)
    }

    @Test("An unavailable notification centre behaves exactly like a denial")
    func unavailableBehavesLikeDenied() async {
        let (gate, service) = makeGate(authorization: .unavailable)
        await gate.setEnabled(true, for: .sessionCompleted)
        await gate.post(NotificationCopy.sessionCompleted(outcome: outcome, duration: minutes(50)))
        #expect(service.posted.isEmpty)
        #expect(!gate.authorization.canRequest)
    }

    @Test("Restoring saved switches never prompts")
    func restoringDoesNotPrompt() async {
        let (gate, service) = makeGate()
        gate.restore(NotificationSwitches(sessionCompleted: true, longIdle: true))
        #expect(service.authorizationRequests == 0)
        #expect(gate.switches.sessionCompleted)
    }

    @Test("prepare() withdraws anything left armed for a kind that is now off")
    func prepareCleansUpDisabledKinds() async {
        let (gate, service) = makeGate(switches: NotificationSwitches(halfway: true))
        await gate.prepare()
        // Every kind except halfway was cancelled, and none of them was posted.
        #expect(service.cancelled.contains(.sessionCompleted))
        #expect(service.cancelled.contains(.longIdle))
        #expect(service.cancelled.contains(.endOfDayReview))
        #expect(!service.cancelled.contains(.halfway))
    }

    @Test("Only one notification is pending per kind at a time")
    func onePendingPerKind() async {
        let (gate, service) = makeGate(switches: NotificationSwitches(halfway: true), authorization: .allowed)
        await gate.post(NotificationCopy.halfway(outcome: outcome, remaining: minutes(25)))
        await gate.post(NotificationCopy.halfway(outcome: outcome, remaining: minutes(20)))
        #expect(service.posted.filter { $0.kind == .halfway }.count == 1)
    }

    @Test("Every kind has a row, and every row moves something")
    func everyKindIsSwitchable() {
        // The condition the previous build stated and could not yet meet: a row for a kind nothing
        // schedules would be a control the user could move that changed nothing — the failure this
        // project has shipped twice. `ProactivePrompts` is the scheduler for the last two, so the
        // assertion inverts: the pane must now offer *all* of them, and a kind added in future
        // without a scheduler fails here rather than shipping as a dead switch.
        #expect(Set(NotificationSwitches.switchableKinds) == Set(NotificationKind.allCases))
        #expect(NotificationSwitches.switchableKinds.count == NotificationKind.allCases.count)
        #expect(NotificationSwitches.switchableKinds.contains(.endOfDayReview))
        #expect(NotificationSwitches.switchableKinds.contains(.unlabelledBlock))
    }

    @Test("Every kind is off on a fresh install, including the two about undeclared work")
    func everythingStartsOff() {
        // These two are the only notifications Lggr sends that are not about something the user
        // started, so they are the two where shipping on would be least forgivable.
        for kind in NotificationKind.allCases {
            #expect(!NotificationSwitches.allOff.isEnabled(kind))
        }
        #expect(!NotificationSwitches().unlabelledBlock)
        #expect(!NotificationSwitches().endOfDayReview)
    }

    @Test("Switches survive a round trip, and an unknown-key file reads as off")
    func switchesAreCodableAndTolerant() throws {
        let switches = NotificationSwitches(sessionCompleted: true, longIdle: true)
        let data = try JSONEncoder().encode(switches)
        #expect(try JSONDecoder().decode(NotificationSwitches.self, from: data) == switches)

        // A stored value written before a kind existed must not switch it on.
        let partial = Data(#"{"longIdle":true}"#.utf8)
        let decoded = try JSONDecoder().decode(NotificationSwitches.self, from: partial)
        #expect(decoded.longIdle)
        #expect(!decoded.sessionCompleted)
        #expect(!decoded.halfway)
        #expect(!decoded.endOfDayReview)
        #expect(!decoded.unlabelledBlock)
    }
}

// MARK: - The copy

@Suite("Notification copy")
@MainActor
struct NotificationCopyTests {

    /// Everything Lggr can put in a notification, in the shapes it can put it in.
    private var catalogue: [NotificationContent] {
        [
            NotificationCopy.sessionCompleted(outcome: outcome, duration: minutes(50)),
            NotificationCopy.sessionCompleted(outcome: "", duration: minutes(50)),
            NotificationCopy.sessionAutoClosed(
                outcome: outcome,
                decision: SessionAutoClose.Decision(
                    closeAt: nineAM, reason: .idle, uncountedDuration: minutes(180)),
                closedAtText: "12:04"
            ),
            NotificationCopy.halfway(outcome: outcome, remaining: minutes(25)),
            NotificationCopy.longIdle(silence: minutes(20), proposedEndText: "12:04"),
            NotificationCopy.endOfDayReview(unlabelledReport(count: 1)),
            NotificationCopy.endOfDayReview(unlabelledReport(count: 3)),
            NotificationCopy.endOfDayReview(.nothing),
            NotificationCopy.unlabelledBlock(blockLabel: "Xcode, Terminal", duration: minutes(18)),
            NotificationCopy.unlabelledBlock(blockLabel: "", duration: minutes(18)),
        ]
    }

    @Test("§ 10.12's completion copy, verbatim")
    func completionMatchesTheCatalogue() {
        let content = NotificationCopy.sessionCompleted(outcome: outcome, duration: minutes(50))
        #expect(content.title == "Session finished")
        #expect(content.body == "Finish the receipt deduplication PR · 50 minutes")
        #expect(content.actions == [.review])
    }

    @Test("An automatically closed session states the adjusted end and the witness for it")
    func autoClosedCopyNamesItsWitness() {
        let content = NotificationCopy.sessionAutoClosed(
            outcome: outcome,
            decision: SessionAutoClose.Decision(
                closeAt: nineAM, reason: .appNotRunning, uncountedDuration: minutes(100)),
            closedAtText: "14:30"
        )
        // Never an app-adjusted time presented as an observed one.
        #expect(content.body.contains("14:30"))
        #expect(content.body.contains("the last minute Lggr was running"))
    }

    @Test("The long-idle notification offers, and offers an answer that changes nothing")
    func longIdleIsAnOfferNotAnAccusation() {
        let content = NotificationCopy.longIdle(silence: minutes(20), proposedEndText: "12:04")
        #expect(content.actions == [.endAtLastInput, .keepGoing])
        #expect(content.body.contains("12:04"))
        // Facts about the record. The subject of every sentence is the session, not the person.
        #expect(!content.body.lowercased().contains("you have"))
    }

    @Test("No notification contains a word that reads as a verdict or as re-engagement")
    func noBannedWords() {
        for content in catalogue {
            for word in NotificationCopy.bannedWords {
                #expect(
                    !content.title.lowercased().contains(word),
                    "\(content.kind) title contains \(word): \(content.title)"
                )
                #expect(
                    !content.body.lowercased().contains(word),
                    "\(content.kind) body contains \(word): \(content.body)"
                )
            }
        }
    }

    @Test("No notification asserts an outcome")
    func noOutcomeVerbs() {
        // `INTELLIGENCE.md` §3.6: a generated string may state durations and application names. It
        // may never assert that something was opened, reviewed, resolved, written or shipped.
        let banned = ["opened", "reviewed", "resolved", "wrote", "shipped", "completed a"]
        for content in catalogue {
            for verb in banned {
                #expect(!content.body.lowercased().contains(verb), "\(content.kind): \(content.body)")
            }
        }
    }

    @Test("Nothing in the catalogue mentions a day, a streak or a count of days")
    func nothingIsScheduledCopy() {
        // A notification whose copy talks about days is a notification that fires because time
        // passed. The wording is the tell, so it is the thing checked.
        for content in catalogue {
            let text = (content.title + " " + content.body).lowercased()
            #expect(!text.contains("today you"))
            #expect(!text.contains("yesterday"))
            #expect(!text.contains("in a row"))
        }
    }

    @Test("A blank outcome degrades to the detail alone rather than to a stray separator")
    func blankOutcomeIsHandled() {
        let content = NotificationCopy.sessionCompleted(outcome: "   ", duration: minutes(50))
        #expect(content.body == "50 minutes")
        #expect(!content.body.hasPrefix("·"))
    }

    @Test("Only the kinds with a destination carry a button")
    func actionsMatchTheirKinds() {
        #expect(NotificationActionKind.actions(for: .halfway).isEmpty)
        #expect(NotificationActionKind.actions(for: .sessionCompleted) == [.review])
        #expect(NotificationActionKind.actions(for: .longIdle) == [.endAtLastInput, .keepGoing])
        // The queue, not the app: a notification whose only affordance is "come and look" has made
        // work rather than saved it.
        #expect(NotificationActionKind.actions(for: .endOfDayReview) == [.reviewUnlabelled])
        // Answer, dismiss, or switch it off — all three on the banner, because the way out has to be
        // findable without hunting.
        #expect(
            NotificationActionKind.actions(for: .unlabelledBlock)
                == [.labelBlock, .dismissBlock, .stopAsking]
        )
    }

    @Test("The two answers that need no window do not activate the app")
    func cheapAnswersStayCheap() {
        // A dismissal that costs a context switch is one the user avoids by switching notifications
        // off instead — which costs Lggr the whole authorisation.
        #expect(!NotificationActionKind.dismissBlock.activatesApp)
        #expect(!NotificationActionKind.stopAsking.activatesApp)
        #expect(!NotificationActionKind.keepGoing.activatesApp)
        #expect(NotificationActionKind.labelBlock.activatesApp)
        #expect(NotificationActionKind.reviewUnlabelled.activatesApp)
    }

    @Test("The first action of every kind is the affirmative one")
    func bannerClickDoesTheHelpfulThing() {
        // `ActionDelegate` routes a click on the banner body to the first action, so the order is not
        // cosmetic: it decides what clicking the notification does.
        #expect(NotificationActionKind.actions(for: .sessionCompleted).first == .review)
        #expect(NotificationActionKind.actions(for: .longIdle).first == .endAtLastInput)
        #expect(NotificationActionKind.actions(for: .endOfDayReview).first == .reviewUnlabelled)
        #expect(NotificationActionKind.actions(for: .unlabelledBlock).first == .labelBlock)
    }

    @Test("The end-of-day copy states the record and the cost of answering it")
    func endOfDayCopy() {
        let content = NotificationCopy.endOfDayReview(unlabelledReport(count: 3))
        #expect(content.title == "Today's record")
        #expect(content.body == "3 blocks from today aren't labelled — about 2 minutes.")
        #expect(content.delay == 0)
    }

    @Test("An empty day produces an empty sentence — there is nothing to congratulate")
    func endOfDaySaysNothingAboutNothing() {
        // Belt and braces behind `UnlabelledWork.reviewOffer`, which never returns a report to post
        // for a well-declared day. If a caller ever posted one anyway, the body must not invent a
        // sentence: praise and shame are the same mechanism.
        #expect(NotificationCopy.endOfDayReview(.nothing).body.isEmpty)
    }

    @Test("The live offer states the evidence and then asks, without naming the user's conduct")
    func unlabelledBlockCopy() {
        let content = NotificationCopy.unlabelledBlock(
            blockLabel: "Xcode, Terminal",
            duration: minutes(18)
        )
        #expect(content.title == "Xcode, Terminal · 18m")
        #expect(content.body == "No session is running. What are you working on?")
        // The subject of both sentences is the record, never the person.
        let text = (content.title + " " + content.body).lowercased()
        #expect(!text.contains("you have"))
        #expect(!text.contains("you did"))
        #expect(!text.contains("forgot"))
        #expect(!content.body.contains("!"))
        // Immediate, and relative: a live offer scheduled for later would be a timer.
        #expect(content.delay == 0)
    }

    @Test("A block with no name degrades to its length rather than to a stray separator")
    func unlabelledBlockWithoutALabel() {
        let content = NotificationCopy.unlabelledBlock(blockLabel: "  ", duration: minutes(18))
        #expect(content.title == "18m")
        #expect(!content.title.hasPrefix("·"))
    }

    @Test("Every kind and action has a distinct identifier")
    func identifiersAreDistinct() {
        let kindIDs = Set(NotificationKind.allCases.map(\.requestIdentifier))
        #expect(kindIDs.count == NotificationKind.allCases.count)
        let actionIDs = Set(NotificationActionKind.allCases.map(\.identifier))
        #expect(actionIDs.count == NotificationActionKind.allCases.count)
    }

    @Test("A delay is never negative, and never a calendar date")
    func delayIsAlwaysRelative() {
        let content = NotificationContent(kind: .halfway, title: "t", body: "b", delay: -10)
        #expect(content.delay == 0)
        let nonsense = NotificationContent(kind: .halfway, title: "t", body: "b", delay: .nan)
        #expect(nonsense.delay == 0)
    }
}

// MARK: - What the session manager schedules

@Suite("Session notifications")
@MainActor
struct SessionNotificationTests {

    /// `store` is required rather than defaulted: `InMemoryStore.init` is main-actor isolated and a
    /// default argument is evaluated in a nonisolated context.
    private func makeManager(
        store: InMemoryStore,
        clock: FixedClock,
        switches: NotificationSwitches = NotificationSwitches(
            sessionCompleted: true, halfway: true, longIdle: true),
        authorization: NotificationAuthorization = .allowed,
        idleSeconds: @escaping @Sendable () -> TimeInterval = { 0 },
        lastHeartbeat: @escaping @MainActor () -> Date? = { nil }
    ) -> (manager: SessionManager, service: RecordingNotificationService) {
        let service = RecordingNotificationService(authorization: authorization)
        let gate = NotificationGate(service: service, switches: switches)
        let manager = SessionManager(
            store: store,
            clock: clock,
            defaults: scratchDefaults,
            notifications: gate,
            idleSeconds: idleSeconds,
            lastHeartbeat: lastHeartbeat
        )
        return (manager, service)
    }

    @Test("Starting a session arms the completion and the halfway banner, both relative to now")
    func startingASessionArmsBoth() async {
        let clock = FixedClock(nineAM)
        let (manager, service) = makeManager(store: InMemoryStore(), clock: clock)

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork,
            plannedDuration: minutes(50)
        )

        #expect(service.pending(.sessionCompleted)?.delay == minutes(50))
        #expect(service.pending(.halfway)?.delay == minutes(25))
    }

    @Test("An open-ended session arms nothing — there is no completion to announce")
    func openEndedSessionArmsNothing() async {
        let clock = FixedClock(nineAM)
        let (manager, service) = makeManager(store: InMemoryStore(), clock: clock)

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork, plannedDuration: nil
        )

        #expect(service.posted.isEmpty)
    }

    @Test("A pause moves the finish line, and the banner moves with it")
    func pauseRearmsTheCompletion() async {
        let clock = FixedClock(nineAM)
        let (manager, service) = makeManager(store: InMemoryStore(), clock: clock)

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork,
            plannedDuration: minutes(50)
        )
        clock.advance(by: minutes(10))
        manager.togglePause()
        clock.advance(by: minutes(20))
        manager.togglePause()
        // The manager persists and re-arms in a detached task; let it land.
        await Task.yield()
        await Task.yield()

        // Forty minutes of the plan are left, measured on the session's own clock rather than on the
        // wall clock the session started against.
        #expect(service.pending(.sessionCompleted)?.delay == minutes(40))
    }

    @Test("Finishing by hand withdraws everything and announces nothing")
    func finishingByHandIsSilent() async {
        let clock = FixedClock(nineAM)
        let (manager, service) = makeManager(store: InMemoryStore(), clock: clock)

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork,
            plannedDuration: minutes(50)
        )
        clock.advance(by: minutes(45))
        await manager.finishSession()

        // The user is looking at the app. A banner telling them what they have just done is the kind
        // of notification that costs the authorisation the useful ones depend on.
        #expect(service.posted.isEmpty)
        #expect(service.cancelled.contains(.sessionCompleted))
        #expect(service.cancelled.contains(.halfway))
    }

    @Test("Discarding a session withdraws its banners")
    func discardingWithdrawsBanners() async {
        let clock = FixedClock(nineAM)
        let (manager, service) = makeManager(store: InMemoryStore(), clock: clock)

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork,
            plannedDuration: minutes(50)
        )
        await manager.discardActiveSession()

        #expect(service.pending(.sessionCompleted) == nil)
        #expect(service.pending(.halfway) == nil)
    }

    // MARK: The forgotten session

    @Test("A session the previous run left open is closed at the last heartbeat")
    func launchClosesAForgottenSession() async {
        // The case that writes wrong data today: quit or crash at 14:30 with a session running, come
        // back at 16:10, and the record claims a hundred minutes that never happened.
        let store = InMemoryStore()
        let startedAt = nineAM
        let lastBeat = nineAM.addingTimeInterval(minutes(330))
        var stranded = FocusSession(intendedOutcome: outcome, startedAt: startedAt)
        stranded.plannedDuration = nil
        try? await store.saveSession(stranded)

        let clock = FixedClock(nineAM.addingTimeInterval(minutes(430)))
        let service = RecordingNotificationService(authorization: .allowed)
        let gate = NotificationGate(
            service: service, switches: NotificationSwitches(sessionCompleted: true))
        let manager = SessionManager(
            store: store,
            clock: clock,
            defaults: scratchDefaults,
            notifications: gate,
            idleSeconds: { 0 },
            lastHeartbeat: { lastBeat }
        )

        await manager.bootstrap()

        #expect(manager.activeSession == nil)
        #expect(manager.pendingReview?.endedAt == lastBeat)
        #expect(manager.pendingReview?.autoCloseReason == .appNotRunning)
        #expect(manager.autoCloseNotice?.decision.closeAt == lastBeat)
        // Announced, because the user was not there to see it. It states the adjusted end.
        #expect(service.pending(.sessionCompleted)?.body.contains("the last minute Lggr was running") == true)
    }

    @Test("A paused session the previous run left behind comes back paused, not closed")
    func launchLeavesAPausedSessionAlone() async {
        // Pausing is the user saying "I am coming back". Closing it would be the app contradicting an
        // explicit instruction, whatever the heartbeat says.
        let store = InMemoryStore()
        var paused = FocusSession(
            intendedOutcome: outcome, plannedDuration: nil, startedAt: nineAM)
        paused.pause(at: nineAM.addingTimeInterval(minutes(20)))
        try? await store.saveSession(paused)

        let clock = FixedClock(nineAM.addingTimeInterval(minutes(900)))
        let (manager, service) = makeManager(
            store: store,
            clock: clock,
            lastHeartbeat: { nineAM.addingTimeInterval(minutes(30)) }
        )

        await manager.bootstrap()

        #expect(manager.activeSession?.isPaused == true)
        #expect(manager.activeSession?.autoClosedAt == nil)
        #expect(manager.pendingReview == nil)
        #expect(service.posted.isEmpty)
    }

    @Test("A forgotten session is closed even when notifications are denied")
    func autoCloseDoesNotDependOnPermission() async {
        // The data correction is the feature; the notification is how the user hears about it. A
        // denial must not leave the wrong number on disk.
        let store = InMemoryStore()
        let lastBeat = nineAM.addingTimeInterval(minutes(330))
        try? await store.saveSession(
            FocusSession(intendedOutcome: outcome, plannedDuration: nil, startedAt: nineAM))

        let clock = FixedClock(nineAM.addingTimeInterval(minutes(430)))
        let (manager, service) = makeManager(
            store: store,
            clock: clock,
            switches: .allOff,
            authorization: .denied,
            lastHeartbeat: { lastBeat }
        )

        await manager.bootstrap()

        #expect(manager.pendingReview?.endedAt == lastBeat)
        #expect(manager.pendingReview?.wasAutoClosed == true)
        #expect(service.posted.isEmpty)
    }

    @Test("A launch with no stale heartbeat leaves a running session running")
    func cleanLaunchTouchesNothing() async {
        let store = InMemoryStore()
        try? await store.saveSession(
            FocusSession(intendedOutcome: outcome, plannedDuration: nil, startedAt: nineAM))

        let clock = FixedClock(nineAM.addingTimeInterval(minutes(20)))
        let (manager, _) = makeManager(store: store, clock: clock, lastHeartbeat: { nil })

        await manager.bootstrap()

        #expect(manager.activeSession != nil)
        #expect(manager.activeSession?.autoClosedAt == nil)
    }

    @Test("Ending at the last input uses the same path the automatic close uses")
    func notificationActionEndsAtLastInput() async {
        let clock = FixedClock(nineAM)
        let (manager, _) = makeManager(
            store: InMemoryStore(), clock: clock, idleSeconds: { minutes(20) })

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork, plannedDuration: nil
        )
        clock.advance(by: minutes(60))

        let ended = await manager.endSessionAtLastInput()

        #expect(ended)
        #expect(manager.pendingReview?.endedAt == nineAM.addingTimeInterval(minutes(40)))
        #expect(manager.pendingReview?.autoCloseReason == .idle)
        #expect(manager.autoCloseNotice?.sentence.hasPrefix("Ended at") == true)
    }

    @Test("Acknowledging the notice clears the announcement and keeps the provenance")
    func acknowledgingKeepsTheRecord() async {
        let clock = FixedClock(nineAM)
        let (manager, _) = makeManager(
            store: InMemoryStore(), clock: clock, idleSeconds: { minutes(20) })

        await manager.startSession(
            projectID: nil, intendedOutcome: outcome, workType: .deepWork, plannedDuration: nil
        )
        clock.advance(by: minutes(60))
        await manager.endSessionAtLastInput()

        manager.acknowledgeAutoClose()
        #expect(manager.autoCloseNotice == nil)
        #expect(manager.pendingReview?.wasAutoClosed == true)
    }

    @Test("Nothing to end reports itself rather than pretending")
    func endingWithNoSessionIsRefused() async {
        let clock = FixedClock(nineAM)
        let (manager, _) = makeManager(store: InMemoryStore(), clock: clock)
        let ended = await manager.endSessionAtLastInput()
        #expect(ended == false)
    }
}
