import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

// The interruption inbox, from capture to processed. See SPEC.md § 3, 04-screens.md § 5.4.
//
// Every test here is about one of the three properties the feature lives or dies by: a capture is
// never lost, the running session is never disturbed, and processing a row is reversible.

@MainActor
private func makeModel(
    store: InMemoryStore,
    at now: Date = Date(timeIntervalSinceReferenceDate: 727_100_000),
    // Optional rather than defaulted to `.detached`, for the reason `InboxModel.init` gives at its own
    // `session` parameter: a default argument is evaluated in a nonisolated context and
    // `InboxSessionContext` is main-actor isolated, so spelling `.detached` here is a warning today and
    // an error in the Swift 6 language mode.
    session: InboxSessionContext? = nil
) -> InboxModel {
    InboxModel(store: store, clock: FixedClock(now), session: session ?? .detached)
}

@Suite("Interruption capture")
@MainActor
struct InterruptionCaptureTests {

    @Test("A capture with no session running still lands in the inbox")
    func captureWithoutSession() async {
        let store = InMemoryStore()
        let inbox = makeModel(store: store)

        let saved = await inbox.capture("Review Omar's blocked PR", source: .person)

        #expect(saved)
        #expect(inbox.pending.count == 1)
        #expect(inbox.pending.first?.description == "Review Omar's blocked PR")
        #expect(inbox.pending.first?.focusSessionID == nil)
        #expect(inbox.pending.first?.status == .inbox)
        #expect(store.interruptions.count == 1)
    }

    @Test("A capture mid-session carries the session and increments its count exactly once")
    func captureDuringSession() async {
        let store = InMemoryStore()
        let sessionID = UUID()
        var noted = 0
        let inbox = makeModel(
            store: store,
            session: InboxSessionContext(
                activeSessionID: { sessionID },
                noteInterruption: { noted += 1 }
            )
        )

        _ = await inbox.capture("Reply to finance about the Q3 invoice", source: .email)

        #expect(inbox.pending.first?.focusSessionID == sessionID)
        #expect(inbox.pending.first?.interruptedASession == true)
        #expect(noted == 1)
    }

    @Test("Whitespace is trimmed, and a note that is only whitespace is not saved")
    func blankCaptureIsRefused() async {
        let store = InMemoryStore()
        let inbox = makeModel(store: store)

        #expect(await inbox.capture("   Unblock the mobile team \n") == true)
        #expect(inbox.pending.first?.description == "Unblock the mobile team")

        #expect(await inbox.capture("   \n  ") == false)
        #expect(inbox.pending.count == 1)
        #expect(store.interruptions.count == 1)
    }

    @Test("A failed write reports false, adds nothing, and does not touch the session count")
    func failedCapture() async {
        let store = InMemoryStore()
        store.failureToInject = .persistenceFailure("disk full")
        var noted = 0
        let inbox = makeModel(
            store: store,
            session: InboxSessionContext(
                activeSessionID: { UUID() },
                noteInterruption: { noted += 1 }
            )
        )

        let saved = await inbox.capture("Something arrived")

        #expect(saved == false)
        #expect(inbox.pending.isEmpty)
        // The panel keeps the user's sentence on screen because of exactly this.
        #expect(inbox.failure == "Couldn't save that yet — try again.")
        #expect(noted == 0)
    }
}

@Suite("Interruption inbox — processing")
@MainActor
struct InterruptionInboxProcessingTests {

    private func waiting(_ description: String = "Review Omar's blocked PR") -> Interruption {
        Interruption(description: description, source: .person, timestamp: Date())
    }

    @Test("Converting to a session starts reactive work on the interruption's own words")
    func convertToSession() async {
        let row = waiting()
        let store = InMemoryStore(interruptions: [row])
        var started: [StartSessionRequest] = []
        let inbox = makeModel(
            store: store,
            session: InboxSessionContext(startSession: { started.append($0) })
        )
        await inbox.load()

        await inbox.convertToSession(row)

        #expect(started.count == 1)
        #expect(started.first?.intendedOutcome == "Review Omar's blocked PR")
        // A person interrupting is communication, and communication is reactive by default — which is
        // what makes planned-versus-reactive answerable at all.
        #expect(started.first?.workType == .communication)
        #expect(started.first?.workType.isReactiveByDefault == true)
        #expect(inbox.pending.isEmpty)
        #expect(inbox.processed.first?.status == .converted)
    }

    @Test("Logging an accomplishment files it and settles the row under the same project")
    func convertToAccomplishment() async {
        let row = waiting()
        let projectID = UUID()
        let store = InMemoryStore(interruptions: [row])
        var logged: [Accomplishment] = []
        let inbox = makeModel(
            store: store,
            session: InboxSessionContext(logAccomplishment: { logged.append($0) })
        )
        await inbox.load()

        var seed = inbox.accomplishmentSeed(for: row)
        #expect(seed.title == "Review Omar's blocked PR")
        #expect(seed.type == .personUnblocked)
        seed.projectID = projectID

        await inbox.convertToAccomplishment(row, accomplishment: seed)

        #expect(logged.count == 1)
        #expect(inbox.pending.isEmpty)
        #expect(inbox.processed.first?.status == .converted)
        #expect(inbox.processed.first?.convertedProjectID == projectID)
    }

    @Test("Dismissing is an outcome: the row leaves the inbox and keeps no project")
    func dismiss() async {
        let row = waiting()
        let store = InMemoryStore(interruptions: [row])
        let inbox = makeModel(store: store)
        await inbox.load()

        await inbox.dismiss(row)

        #expect(inbox.pending.isEmpty)
        #expect(inbox.processed.first?.status == .dismissed)
        #expect(inbox.processed.first?.convertedProjectID == nil)
        #expect(store.interruptions.first?.status == .dismissed)
    }

    @Test("A dismissed row can be put back, which is what makes dismissing casual")
    func returnToInbox() async {
        let row = waiting()
        let store = InMemoryStore(interruptions: [row])
        let inbox = makeModel(store: store)
        await inbox.load()

        await inbox.dismiss(row)
        guard let dismissed = inbox.processed.first else {
            Issue.record("The dismissed row is missing from the processed list.")
            return
        }
        await inbox.returnToInbox(dismissed)

        #expect(inbox.processed.isEmpty)
        #expect(inbox.pending.count == 1)
        #expect(inbox.pending.first?.status == .inbox)
        #expect(store.interruptions.first?.status == .inbox)
    }

    @Test("A failed write puts the row back in the inbox rather than losing it")
    func failedTransitionRestoresTheRow() async {
        let row = waiting()
        let store = InMemoryStore(interruptions: [row])
        let inbox = makeModel(store: store)
        await inbox.load()
        store.failureToInject = .persistenceFailure("disk full")

        await inbox.dismiss(row)

        #expect(inbox.pending.count == 1)
        #expect(inbox.pending.first?.status == .inbox)
        #expect(inbox.processed.isEmpty)
        #expect(inbox.failure == "Couldn't save that yet — try again.")
    }

    @Test("Filing under a project settles the row without starting anything")
    func fileUnderProject() async {
        let row = waiting()
        let projectID = UUID()
        let store = InMemoryStore(interruptions: [row])
        var started: [StartSessionRequest] = []
        let inbox = makeModel(
            store: store,
            session: InboxSessionContext(startSession: { started.append($0) })
        )
        await inbox.load()

        await inbox.fileUnderProject(row, projectID: projectID)

        #expect(started.isEmpty)
        #expect(inbox.pending.isEmpty)
        #expect(inbox.processed.first?.convertedProjectID == projectID)
    }

    @Test("Deleting removes the record entirely, and a failed delete restores it")
    func delete() async {
        let row = waiting()
        let store = InMemoryStore(interruptions: [row])
        let inbox = makeModel(store: store)
        await inbox.load()

        store.failureToInject = .persistenceFailure("disk full")
        await inbox.delete(row)
        #expect(inbox.pending.count == 1)

        store.failureToInject = nil
        await inbox.delete(row)
        #expect(inbox.pending.isEmpty)
        #expect(store.interruptions.isEmpty)
    }

    @Test("A load failure states one sentence and never empties the screen silently")
    func loadFailure() async {
        let store = InMemoryStore(interruptions: [waiting()])
        store.failureToInject = .persistenceFailure("unreadable")
        let inbox = makeModel(store: store)

        await inbox.load()

        #expect(inbox.hasLoaded)
        #expect(inbox.failure == "Couldn't load your inbox. Nothing has been lost.")
    }

    @Test("Every source maps to reactive work, because an interruption is work that arrived")
    func everySourceIsReactive() {
        for source in InterruptionSource.allCases {
            #expect(InboxModel.workType(for: source).isReactiveByDefault)
        }
    }
}

@Suite("Interruption capture leaves the session alone")
@MainActor
struct InterruptionSessionSideEffectTests {

    @Test("The running session keeps running and only its interruption count moves")
    func captureDoesNotDisturbTheSession() async {
        let store = InMemoryStore()
        let clock = FixedClock(Date(timeIntervalSinceReferenceDate: 727_100_000))
        let manager = SessionManager(
            store: store,
            clock: clock,
            defaults: UserDefaults(suiteName: "com.lggr.tests.inbox") ?? .standard
        )
        await manager.startSession(
            projectID: nil,
            intendedOutcome: "Finish the receipt deduplication PR",
            workType: .deepWork,
            plannedDuration: 50 * 60
        )
        guard let before = manager.activeSession else {
            Issue.record("The session did not start.")
            return
        }

        let inbox = InboxModel(
            store: store,
            clock: clock,
            session: .live(manager: manager, startSession: { _ in })
        )
        _ = await inbox.capture("Review Omar's blocked PR", source: .person)

        guard let after = manager.activeSession else {
            Issue.record("Capturing an interruption ended the session.")
            return
        }
        #expect(after.id == before.id)
        #expect(after.isRunning)
        #expect(after.isPaused == false)
        #expect(after.endedAt == nil)
        #expect(after.startedAt == before.startedAt)
        #expect(after.pausedDuration == before.pausedDuration)
        #expect(after.interruptionCount == before.interruptionCount + 1)
        #expect(inbox.pending.first?.focusSessionID == before.id)
    }

    @Test("With nothing running, noting an interruption changes nothing at all")
    func noteWithoutSession() async {
        let store = InMemoryStore()
        let manager = SessionManager(
            store: store,
            clock: FixedClock(Date(timeIntervalSinceReferenceDate: 727_100_000)),
            defaults: UserDefaults(suiteName: "com.lggr.tests.inbox") ?? .standard
        )

        manager.noteInterruption()

        #expect(manager.activeSession == nil)
        #expect(store.sessions.isEmpty)
    }
}
