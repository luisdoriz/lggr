import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes. See `SessionClockTests` for why the explicit `Double`
/// return is load-bearing: `#expect` compares an `Optional<Double>` against an integer-literal
/// expression by type as well as by value, and reports a failure when the types differ.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// These tests describe the persistence contract itself, not this particular implementation. Every
/// assertion here must hold for the durable store too — that is the whole reason the fake exists, so
/// the same expectations are worth reading as the specification both backends are held to.
@MainActor
@Suite("In-memory store")
struct InMemoryStoreTests {

    /// 2024-01-15 09:00:00 UTC. Fixed so a failure reproduces identically on any machine.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func at(_ minutes: Double) -> Date {
        Self.nineAM.addingTimeInterval(minutes * 60)
    }

    /// The window 09:00–10:00, used to exercise inclusive boundary filtering.
    private var theHour: DateInterval {
        DateInterval(start: Self.nineAM, end: at(60))
    }

    private func session(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        outcome: String = "Finish the receipt deduplication PR",
        startedAt: Date,
        endedAt: Date? = nil
    ) -> FocusSession {
        FocusSession(
            id: id,
            projectID: projectID,
            intendedOutcome: outcome,
            plannedDuration: 50 * 60,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    private func accomplishment(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        title: String = "Reviewed the ingest PR",
        timestamp: Date
    ) -> Accomplishment {
        Accomplishment(id: id, projectID: projectID, type: .pullRequestReviewed, title: title, timestamp: timestamp)
    }

    // MARK: - Seeding

    @Test("A store seeded from fixtures holds the fixtures and has recorded no writes")
    func seedingIsNotAWrite() async throws {
        let store = InMemoryStore(
            projects: [Project(name: "Ingest")],
            sessions: [session(startedAt: Self.nineAM)],
            accomplishments: [accomplishment(timestamp: at(30))]
        )

        #expect(try await store.loadProjects().count == 1)
        #expect(try await store.loadSessions(in: theHour).count == 1)
        #expect(try await store.loadAccomplishments(in: theHour).count == 1)
        #expect(store.writeCount == 0)
    }

    @Test("An empty store loads empty rather than failing")
    func emptyStore() async throws {
        let store = InMemoryStore()

        #expect(try await store.loadProjects().isEmpty)
        #expect(try await store.loadSessions(in: theHour).isEmpty)
        #expect(try await store.loadAccomplishments(in: theHour).isEmpty)
        #expect(try await store.loadActiveSession() == nil)
    }

    // MARK: - Upsert

    @Test("Saving the same project twice updates it in place instead of duplicating it")
    func projectUpsertDoesNotDuplicate() async throws {
        let store = InMemoryStore()
        var project = Project(name: "Ingest")
        try await store.saveProject(project)

        project.name = "Ingest pipeline"
        project.colorID = "teal"
        try await store.saveProject(project)

        let loaded = try await store.loadProjects()
        #expect(loaded.count == 1)
        #expect(loaded.first?.name == "Ingest pipeline")
        #expect(loaded.first?.colorID == "teal")
    }

    @Test("An upsert leaves a project where it already was in the list")
    func projectUpsertKeepsPosition() async throws {
        let first = Project(name: "Ingest")
        let second = Project(name: "Billing")
        let third = Project(name: "Platform")
        let store = InMemoryStore(projects: [first, second, third])

        var renamed = second
        renamed.name = "Billing v2"
        try await store.saveProject(renamed)

        let names = try await store.loadProjects().map(\.name)
        #expect(names == ["Ingest", "Billing v2", "Platform"])
    }

    @Test("Saving the same session twice updates it in place instead of duplicating it")
    func sessionUpsertDoesNotDuplicate() async throws {
        let store = InMemoryStore()
        var stored = session(startedAt: Self.nineAM)
        try await store.saveSession(stored)

        stored.finish(at: at(50), status: .completed)
        try await store.saveSession(stored)

        let loaded = try await store.loadSessions(in: theHour)
        #expect(loaded.count == 1)
        #expect(loaded.first?.resultStatus == .completed)
        #expect(loaded.first?.plannedDuration == minutes(50))
        #expect(loaded.first?.effectiveDuration == minutes(50))
    }

    @Test("Saving the same accomplishment twice updates it in place instead of duplicating it")
    func accomplishmentUpsertDoesNotDuplicate() async throws {
        let store = InMemoryStore()
        var stored = accomplishment(timestamp: at(30))
        try await store.saveAccomplishment(stored)

        stored.title = "Reviewed the dedup PR"
        try await store.saveAccomplishment(stored)

        let loaded = try await store.loadAccomplishments(in: theHour)
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == "Reviewed the dedup PR")
    }

    // MARK: - Deleting a project never cascades

    @Test("Deleting a project keeps the work done under it and clears the reference")
    func deleteProjectPreservesHistory() async throws {
        let project = Project(name: "Ingest")
        let other = Project(name: "Billing")
        let store = InMemoryStore(
            projects: [project, other],
            sessions: [
                session(projectID: project.id, startedAt: Self.nineAM),
                session(projectID: other.id, startedAt: at(10)),
            ],
            accomplishments: [
                accomplishment(projectID: project.id, timestamp: at(20)),
                accomplishment(projectID: other.id, timestamp: at(30)),
            ]
        )

        try await store.deleteProject(id: project.id)

        #expect(try await store.loadProjects().map(\.id) == [other.id])

        let sessions = try await store.loadSessions(in: theHour)
        #expect(sessions.count == 2)
        #expect(sessions.filter { $0.projectID == nil }.count == 1)
        #expect(sessions.filter { $0.projectID == other.id }.count == 1)

        let accomplishments = try await store.loadAccomplishments(in: theHour)
        #expect(accomplishments.count == 2)
        #expect(accomplishments.filter { $0.projectID == nil }.count == 1)
        #expect(accomplishments.filter { $0.projectID == other.id }.count == 1)
    }

    /// Deletes are idempotent across every conformer — see the contract on `LggrStore`. A user who
    /// hits delete twice, or deletes from a list that was rendered before another change landed,
    /// must not be shown a failure for an operation that achieved what they asked for.
    @Test("Deleting a record that is not there succeeds and changes nothing")
    func deleteMissingRecordIsIdempotent() async throws {
        let project = Project(name: "Receipt ingestion")
        let store = InMemoryStore(projects: [project])
        let missing = UUID()

        try await store.deleteProject(id: missing)
        try await store.deleteSession(id: missing)
        try await store.deleteAccomplishment(id: missing)

        #expect(try await store.loadProjects() == [project])
    }

    @Test("Deleting the same record twice is not an error the second time")
    func repeatedDeleteIsIdempotent() async throws {
        let project = Project(name: "Receipt ingestion")
        let store = InMemoryStore(projects: [project])

        try await store.deleteProject(id: project.id)
        try await store.deleteProject(id: project.id)

        #expect(try await store.loadProjects().isEmpty)
    }

    @Test("Deleting a session removes only that session")
    func deleteSession() async throws {
        let doomed = session(startedAt: Self.nineAM)
        let kept = session(startedAt: at(10))
        let store = InMemoryStore(sessions: [doomed, kept])

        try await store.deleteSession(id: doomed.id)

        #expect(try await store.loadSession(id: doomed.id) == nil)
        #expect(try await store.loadSession(id: kept.id)?.id == kept.id)
        #expect(try await store.loadSessions(in: theHour).count == 1)
    }

    @Test("Deleting an accomplishment removes only that accomplishment")
    func deleteAccomplishment() async throws {
        let doomed = accomplishment(timestamp: at(20))
        let kept = accomplishment(timestamp: at(30))
        let store = InMemoryStore(accomplishments: [doomed, kept])

        try await store.deleteAccomplishment(id: doomed.id)

        let loaded = try await store.loadAccomplishments(in: theHour)
        #expect(loaded.map(\.id) == [kept.id])
    }

    // MARK: - Ordering and filtering

    @Test("Sessions come back newest first")
    func sessionsAreNewestFirst() async throws {
        let earliest = session(outcome: "earliest", startedAt: Self.nineAM)
        let middle = session(outcome: "middle", startedAt: at(20))
        let latest = session(outcome: "latest", startedAt: at(40))
        // Seeded out of order on purpose: insertion order must not leak into the result.
        let store = InMemoryStore(sessions: [middle, earliest, latest])

        let loaded = try await store.loadSessions(in: theHour)
        #expect(loaded.map(\.intendedOutcome) == ["latest", "middle", "earliest"])
    }

    @Test("Accomplishments come back newest first")
    func accomplishmentsAreNewestFirst() async throws {
        let store = InMemoryStore(accomplishments: [
            accomplishment(title: "middle", timestamp: at(20)),
            accomplishment(title: "latest", timestamp: at(40)),
            accomplishment(title: "earliest", timestamp: Self.nineAM),
        ])

        let loaded = try await store.loadAccomplishments(in: theHour)
        #expect(loaded.map(\.title) == ["latest", "middle", "earliest"])
    }

    @Test("Records sharing an instant still come back in a stable order")
    func tiesAreOrderedDeterministically() async throws {
        let sameInstant = at(15)
        let store = InMemoryStore(accomplishments: [
            accomplishment(title: "a", timestamp: sameInstant),
            accomplishment(title: "b", timestamp: sameInstant),
            accomplishment(title: "c", timestamp: sameInstant),
        ])

        let first = try await store.loadAccomplishments(in: theHour).map(\.id)
        let second = try await store.loadAccomplishments(in: theHour).map(\.id)
        #expect(first == second)
    }

    /// The window is half-open: `start` belongs to it, `end` does not.
    ///
    /// `Calendar.dateInterval(of: .day, for:)` produces adjacent windows where one day's `end` is
    /// exactly the next day's `start`. Under closed filtering a record stamped at midnight would be
    /// returned for both days, so the per-day breakdown of a week would not add up to the week —
    /// and midnight is not an exotic value once an accomplishment can be back-dated with a date
    /// picker, which defaults to exactly that.
    @Test("Interval filtering includes the start, excludes the end")
    func intervalFilteringIsHalfOpen() async throws {
        let store = InMemoryStore(
            sessions: [
                session(outcome: "before", startedAt: at(-1)),
                session(outcome: "on the start", startedAt: Self.nineAM),
                session(outcome: "inside", startedAt: at(30)),
                session(outcome: "on the end", startedAt: at(60)),
                session(outcome: "after", startedAt: at(61)),
            ],
            accomplishments: [
                accomplishment(title: "before", timestamp: at(-1)),
                accomplishment(title: "on the start", timestamp: Self.nineAM),
                accomplishment(title: "on the end", timestamp: at(60)),
                accomplishment(title: "after", timestamp: at(61)),
            ]
        )

        let sessions = try await store.loadSessions(in: theHour).map(\.intendedOutcome)
        #expect(sessions == ["inside", "on the start"])

        let accomplishments = try await store.loadAccomplishments(in: theHour).map(\.title)
        #expect(accomplishments == ["on the start"])
    }

    /// Two adjacent windows must partition the timeline: every record lands in exactly one. This is
    /// the property the half-open boundary exists to guarantee, and the one a daily breakdown of a
    /// week depends on.
    @Test("Adjacent windows never both claim the same record")
    func adjacentWindowsPartition() async throws {
        let boundary = at(60)
        let store = InMemoryStore(
            sessions: [session(outcome: "on the boundary", startedAt: boundary)]
        )

        let firstHour = DateInterval(start: Self.nineAM, end: boundary)
        let secondHour = DateInterval(start: boundary, end: at(120))

        #expect(try await store.loadSessions(in: firstHour).isEmpty)
        #expect(try await store.loadSessions(in: secondHour).count == 1)
    }

    @Test("A session is filtered by when it started, not by when it ended")
    func filteringUsesStartedAt() async throws {
        // Started inside the window, ran long past it.
        let store = InMemoryStore(sessions: [session(startedAt: at(55), endedAt: at(180))])

        #expect(try await store.loadSessions(in: theHour).count == 1)
    }

    @Test("Loading a session by an unknown id yields nil rather than throwing")
    func loadUnknownSession() async throws {
        let store = InMemoryStore()
        #expect(try await store.loadSession(id: UUID()) == nil)
    }

    // MARK: - The active session

    @Test("The active session is the most recent one that never ended")
    func activeSessionIsTheNewestUnended() async throws {
        let stale = session(outcome: "stale", startedAt: Self.nineAM)
        let current = session(outcome: "current", startedAt: at(40))
        let finished = session(outcome: "finished", startedAt: at(50), endedAt: at(55))
        let store = InMemoryStore(sessions: [stale, finished, current])

        #expect(try await store.loadActiveSession()?.intendedOutcome == "current")
    }

    @Test("There is no active session once every session has ended")
    func noActiveSessionWhenAllFinished() async throws {
        let store = InMemoryStore(sessions: [
            session(startedAt: Self.nineAM, endedAt: at(30)),
            session(startedAt: at(40), endedAt: at(60)),
        ])

        #expect(try await store.loadActiveSession() == nil)
    }

    @Test("A session that ends stops being the active session")
    func finishingClearsTheActiveSession() async throws {
        let store = InMemoryStore()
        var live = session(startedAt: Self.nineAM)
        try await store.saveSession(live)
        #expect(try await store.loadActiveSession()?.id == live.id)

        live.finish(at: at(50), status: .completed)
        try await store.saveSession(live)
        #expect(try await store.loadActiveSession() == nil)
    }

    @Test("The active session is found regardless of how far outside any window it started")
    func activeSessionIgnoresIntervals() async throws {
        let ancient = session(startedAt: at(-10_000))
        let store = InMemoryStore(sessions: [ancient])

        #expect(try await store.loadSessions(in: theHour).isEmpty)
        #expect(try await store.loadActiveSession()?.id == ancient.id)
    }

    // MARK: - Write log

    @Test("Saving once records exactly one write")
    func savingOnceRecordsOneWrite() async throws {
        let store = InMemoryStore()
        let project = Project(name: "Ingest")

        try await store.saveProject(project)

        #expect(store.writeCount == 1)
        #expect(store.writes == [.projectSaved(project.id)])
    }

    @Test("Loading is not a write")
    func loadingIsNotAWrite() async throws {
        let store = InMemoryStore(sessions: [session(startedAt: Self.nineAM)])

        _ = try await store.loadSessions(in: theHour)
        _ = try await store.loadActiveSession()
        _ = try await store.loadProjects()

        #expect(store.writeCount == 0)
    }

    @Test("Every kind of change is recorded in the order it happened")
    func writeLogRecordsEveryChange() async throws {
        let store = InMemoryStore()
        let project = Project(name: "Ingest")
        let focus = session(projectID: project.id, startedAt: Self.nineAM)
        let done = accomplishment(projectID: project.id, timestamp: at(30))

        try await store.saveProject(project)
        try await store.saveSession(focus)
        try await store.saveAccomplishment(done)
        try await store.deleteAccomplishment(id: done.id)
        try await store.deleteSession(id: focus.id)
        try await store.deleteProject(id: project.id)

        #expect(
            store.writes == [
                .projectSaved(project.id),
                .sessionSaved(focus.id),
                .accomplishmentSaved(done.id),
                .accomplishmentDeleted(done.id),
                .sessionDeleted(focus.id),
                .projectDeleted(project.id),
            ]
        )
    }

    @Test("Resetting the log leaves the data alone")
    func resetWrites() async throws {
        let store = InMemoryStore()
        try await store.saveProject(Project(name: "Ingest"))
        store.resetWrites()

        #expect(store.writeCount == 0)
        #expect(try await store.loadProjects().count == 1)
    }

    // MARK: - Injected failure

    @Test("An injected failure propagates out of every method")
    func injectedFailurePropagates() async throws {
        let store = InMemoryStore(projects: [Project(name: "Ingest")])
        let failure = StoreError.persistenceFailure("The disk is full.")
        store.failureToInject = failure

        await #expect(throws: failure) { try await store.loadProjects() }
        await #expect(throws: failure) { try await store.saveProject(Project(name: "Billing")) }
        await #expect(throws: failure) { try await store.deleteProject(id: UUID()) }
        await #expect(throws: failure) { try await store.loadSessions(in: theHour) }
        await #expect(throws: failure) { try await store.loadSession(id: UUID()) }
        await #expect(throws: failure) { try await store.loadActiveSession() }
        await #expect(throws: failure) { try await store.saveSession(session(startedAt: Self.nineAM)) }
        await #expect(throws: failure) { try await store.deleteSession(id: UUID()) }
        await #expect(throws: failure) { try await store.loadAccomplishments(in: theHour) }
        await #expect(throws: failure) { try await store.saveAccomplishment(accomplishment(timestamp: at(30))) }
        await #expect(throws: failure) { try await store.deleteAccomplishment(id: UUID()) }
    }

    @Test("A failed write changes nothing and is not recorded")
    func failedWriteLeavesNoTrace() async throws {
        let existing = Project(name: "Ingest")
        let store = InMemoryStore(projects: [existing])
        store.failureToInject = .persistenceFailure("The disk is full.")

        await #expect(throws: StoreError.self) { try await store.saveProject(Project(name: "Billing")) }
        await #expect(throws: StoreError.self) { try await store.deleteProject(id: existing.id) }

        store.failureToInject = nil
        #expect(try await store.loadProjects().map(\.id) == [existing.id])
        #expect(store.writeCount == 0)
    }

    @Test("Clearing the injected failure restores normal service")
    func clearingTheFailureRecovers() async throws {
        let store = InMemoryStore()
        store.failureToInject = .persistenceFailure("The disk is full.")
        await #expect(throws: StoreError.self) { try await store.saveProject(Project(name: "Ingest")) }

        store.failureToInject = nil
        try await store.saveProject(Project(name: "Ingest"))

        #expect(try await store.loadProjects().count == 1)
        #expect(store.writeCount == 1)
    }
}
