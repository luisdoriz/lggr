import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes. The explicit `Double` is load-bearing: `#expect`
/// compares an `Optional<Double>` against an integer-literal expression by type as well as by value,
/// and reports a failure even when the numbers match.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// Creates an empty directory under the system temporary directory. The caller removes it.
private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("JSONFileStoreTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func quarantineFiles(in directory: URL) throws -> [String] {
    try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.hasPrefix("store-corrupt-") }
}

/// The store is the only place in Lggr where a bug costs the user data rather than a redraw, so
/// these tests run against a real file system: real writes, a real missing file, a real corrupt
/// file, and a real stand-in for a relaunch — a second store opened over the same URL.
@Suite("JSON file store")
@MainActor
struct JSONFileStoreTests {

    /// 2024-01-15 09:00:00 UTC. Fixed so a failure reproduces identically on any machine.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func at(_ minutes: Double) -> Date {
        Self.nineAM.addingTimeInterval(minutes * 60)
    }

    /// Midnight to midnight around `nineAM`.
    private func day() -> DateInterval {
        DateInterval(start: at(-540), end: at(900))
    }

    // MARK: - Round trip

    @Test("Everything saved comes back after the store is reopened")
    func roundTripThroughDisk() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let project = Project(name: "Receipt ingest", colorID: "teal", iconID: "tray.full")
        var session = FocusSession(
            projectID: project.id,
            intendedOutcome: "Finish the receipt deduplication PR",
            workType: .deepWork,
            plannedDuration: minutes(50),
            startedAt: Self.nineAM
        )
        session.finish(at: at(50), status: .madeProgress)
        session.resultSummary = "Split the dedup pass out of the ingest job."
        let accomplishment = Accomplishment(
            projectID: project.id,
            focusSessionID: session.id,
            type: .pullRequestOpened,
            title: "Opened the dedup PR",
            timestamp: at(51)
        )

        let writing = JSONFileStore(fileURL: url)
        try await writing.saveProject(project)
        try await writing.saveSession(session)
        try await writing.saveAccomplishment(accomplishment)

        // A fresh instance sees only what reached the disk.
        let reading = JSONFileStore(fileURL: url)
        let projects = try await reading.loadProjects()
        let restored = try await reading.loadSession(id: session.id)
        let sessions = try await reading.loadSessions(in: day())
        let accomplishments = try await reading.loadAccomplishments(in: day())

        #expect(projects == [project])
        #expect(restored == session)
        #expect(sessions == [session])
        #expect(accomplishments == [accomplishment])
        #expect(restored?.effectiveDuration == minutes(50))
    }

    @Test("The file on disk is JSON a human can read and a diff can show")
    func fileIsReadableJSON() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let store = JSONFileStore(fileURL: url)
        try await store.saveProject(Project(name: "Receipt ingest"))

        let data = try Data(contentsOf: url)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("Receipt ingest"))
        // Pretty printed, so a diff shows the record that changed rather than one enormous line.
        #expect(text.contains("\n"))

        let object = try JSONSerialization.jsonObject(with: data)
        let root = try #require(object as? [String: Any])
        #expect(root["schemaVersion"] as? Int == StoreSnapshot.currentSchemaVersion)
        #expect(root["projects"] is [Any])
        #expect(root["sessions"] is [Any])
        #expect(root["accomplishments"] is [Any])

        // Sorted keys: "accomplishments" is written before "projects".
        let accomplishmentsKey = try #require(text.range(of: "\"accomplishments\""))
        let projectsKey = try #require(text.range(of: "\"projects\""))
        #expect(accomplishmentsKey.lowerBound < projectsKey.lowerBound)
    }

    // MARK: - Missing and corrupt files

    @Test("A missing file is an empty store, not an error")
    func missingFileYieldsEmptyStore() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("Lggr", isDirectory: true)
            .appendingPathComponent("store.json")

        let store = JSONFileStore(fileURL: url)
        let projects = try await store.loadProjects()
        let sessions = try await store.loadSessions(in: day())
        let accomplishments = try await store.loadAccomplishments(in: day())
        let active = try await store.loadActiveSession()

        #expect(projects.isEmpty)
        #expect(sessions.isEmpty)
        #expect(accomplishments.isEmpty)
        #expect(active == nil)
        // Reading did not create anything.
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // The first save creates the intermediate directory.
        try await store.saveProject(Project(name: "Receipt ingest"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A corrupt file is moved aside and the store still opens")
    func corruptFileIsQuarantined() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        let garbage = "{ this is not json"
        try Data(garbage.utf8).write(to: url)

        let store = JSONFileStore(fileURL: url)
        let projects = try await store.loadProjects()
        #expect(projects.isEmpty)

        let quarantined = try quarantineFiles(in: directory)
        #expect(quarantined.count == 1)

        // The bytes are recoverable, not gone.
        let name = try #require(quarantined.first)
        let rescued = try Data(contentsOf: directory.appendingPathComponent(name))
        #expect(String(data: rescued, encoding: .utf8) == garbage)

        // And the store is usable from here on.
        let project = Project(name: "Receipt ingest")
        try await store.saveProject(project)
        let reloaded = try await JSONFileStore(fileURL: url).loadProjects()
        #expect(reloaded == [project])
    }

    @Test("A file from a newer schema is refused rather than quarantined or truncated")
    func futureSchemaVersionIsRefused() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        let future = """
            {"schemaVersion":\(StoreSnapshot.currentSchemaVersion + 1),\
            "accomplishments":[],"projects":[],"sessions":[]}
            """
        try Data(future.utf8).write(to: url)

        let store = JSONFileStore(fileURL: url)
        await #expect(throws: StoreError.self) {
            _ = try await store.loadProjects()
        }

        // Refusing is not losing: the original file is exactly where it was.
        let quarantined = try quarantineFiles(in: directory)
        #expect(quarantined.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Upsert

    @Test("Saving the same id twice updates in place instead of duplicating")
    func saveIsUpsertByID() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let store = JSONFileStore(fileURL: url)

        var project = Project(name: "Receipt ingest")
        try await store.saveProject(project)
        project.name = "Receipt pipeline"
        project.isActive = false
        try await store.saveProject(project)

        var session = FocusSession(
            intendedOutcome: "Draft the migration plan",
            startedAt: Self.nineAM
        )
        try await store.saveSession(session)
        session.finish(at: at(30), status: .completed)
        try await store.saveSession(session)

        let reopened = JSONFileStore(fileURL: url)
        let projects = try await reopened.loadProjects()
        let sessions = try await reopened.loadSessions(in: day())

        #expect(projects.count == 1)
        #expect(projects.first?.name == "Receipt pipeline")
        #expect(projects.first?.isActive == false)
        #expect(sessions.count == 1)
        #expect(sessions.first?.resultStatus == .completed)
    }

    // MARK: - Deleting a project

    @Test("Deleting a project clears references but keeps the history")
    func deleteProjectClearsReferencesWithoutDeletingHistory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let doomed = Project(name: "Receipt ingest")
        let kept = Project(name: "Hiring")
        let orphaned = FocusSession(
            projectID: doomed.id,
            intendedOutcome: "Finish the receipt deduplication PR",
            startedAt: Self.nineAM
        )
        let untouched = FocusSession(
            projectID: kept.id,
            intendedOutcome: "Write the loop interview rubric",
            startedAt: at(60)
        )
        let accomplishment = Accomplishment(
            projectID: doomed.id,
            type: .pullRequestOpened,
            title: "Opened the dedup PR",
            timestamp: at(51)
        )

        let store = JSONFileStore(fileURL: url)
        try await store.saveProject(doomed)
        try await store.saveProject(kept)
        try await store.saveSession(orphaned)
        try await store.saveSession(untouched)
        try await store.saveAccomplishment(accomplishment)

        try await store.deleteProject(id: doomed.id)

        let reopened = JSONFileStore(fileURL: url)
        let projects = try await reopened.loadProjects()
        let sessions = try await reopened.loadSessions(in: day())
        let reloadedOrphan = try await reopened.loadSession(id: orphaned.id)
        let reloadedUntouched = try await reopened.loadSession(id: untouched.id)
        let accomplishments = try await reopened.loadAccomplishments(in: day())

        #expect(projects == [kept])
        #expect(sessions.count == 2)
        #expect(reloadedOrphan?.projectID == nil)
        #expect(reloadedOrphan?.intendedOutcome == "Finish the receipt deduplication PR")
        #expect(reloadedUntouched?.projectID == kept.id)
        #expect(accomplishments.count == 1)
        #expect(accomplishments.first?.projectID == nil)
        #expect(accomplishments.first?.title == "Opened the dedup PR")
    }

    @Test("Deleting a project that is not there is not an error")
    func deleteMissingProjectIsIdempotent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = JSONFileStore(fileURL: directory.appendingPathComponent("store.json"))
        try await store.deleteProject(id: UUID())
        let projects = try await store.loadProjects()
        #expect(projects.isEmpty)
    }

    // MARK: - Interval filtering and order

    @Test("Sessions are filtered by startedAt and returned newest first")
    func sessionIntervalFilteringAndOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let tooEarly = FocusSession(intendedOutcome: "Before the window", startedAt: at(-120))
        let first = FocusSession(intendedOutcome: "Morning block", startedAt: at(0))
        let second = FocusSession(intendedOutcome: "Midday block", startedAt: at(120))
        let third = FocusSession(intendedOutcome: "Afternoon block", startedAt: at(300))
        let tooLate = FocusSession(intendedOutcome: "After the window", startedAt: at(600))

        let store = JSONFileStore(fileURL: url)
        // Saved out of order on purpose: ordering is the store's job, not the caller's.
        for session in [second, tooLate, first, tooEarly, third] {
            try await store.saveSession(session)
        }

        let window = DateInterval(start: at(-30), end: at(330))
        let found = try await JSONFileStore(fileURL: url).loadSessions(in: window)

        #expect(found.map(\.id) == [third.id, second.id, first.id])
    }

    @Test("Accomplishments are filtered by timestamp and returned newest first")
    func accomplishmentIntervalFilteringAndOrder() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let lastWeek = Accomplishment(title: "Last week", timestamp: at(-2_000))
        let older = Accomplishment(title: "Reviewed the ingest PR", timestamp: at(10))
        let newer = Accomplishment(title: "Unblocked Priya", timestamp: at(200))
        let tomorrow = Accomplishment(title: "Tomorrow", timestamp: at(2_000))

        let store = JSONFileStore(fileURL: url)
        for accomplishment in [older, tomorrow, lastWeek, newer] {
            try await store.saveAccomplishment(accomplishment)
        }

        let window = DateInterval(start: at(0), end: at(300))
        let found = try await JSONFileStore(fileURL: url).loadAccomplishments(in: window)

        #expect(found.map(\.title) == ["Unblocked Priya", "Reviewed the ingest PR"])
    }

    // MARK: - Active session

    @Test("The active session is the most recently started one that never ended")
    func activeSessionIsTheNewestUnendedSession() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        var finished = FocusSession(intendedOutcome: "Morning block", startedAt: at(0))
        finished.finish(at: at(50), status: .completed)
        let stale = FocusSession(intendedOutcome: "Abandoned block", startedAt: at(120))
        let current = FocusSession(intendedOutcome: "Current block", startedAt: at(240))
        // Started later than any of them, but it ended, so it is not what a relaunch restores.
        var latestFinished = FocusSession(intendedOutcome: "Later block", startedAt: at(400))
        latestFinished.finish(at: at(430), status: .madeProgress)

        let store = JSONFileStore(fileURL: url)
        for session in [finished, current, stale, latestFinished] {
            try await store.saveSession(session)
        }

        let restored = try await JSONFileStore(fileURL: url).loadActiveSession()
        #expect(restored?.id == current.id)
        #expect(restored?.intendedOutcome == "Current block")
    }

    @Test("A store with no unended session has no active session")
    func noActiveSession() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        var finished = FocusSession(intendedOutcome: "Morning block", startedAt: at(0))
        finished.finish(at: at(50), status: .completed)

        let store = JSONFileStore(fileURL: url)
        try await store.saveSession(finished)
        let active = try await store.loadActiveSession()

        #expect(active == nil)
    }

    // MARK: - Deletes

    @Test("Deleted sessions and accomplishments do not come back")
    func deletesArePersisted() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let session = FocusSession(intendedOutcome: "Morning block", startedAt: at(0))
        let accomplishment = Accomplishment(title: "Reviewed the ingest PR", timestamp: at(10))

        let store = JSONFileStore(fileURL: url)
        try await store.saveSession(session)
        try await store.saveAccomplishment(accomplishment)
        try await store.deleteSession(id: session.id)
        try await store.deleteAccomplishment(id: accomplishment.id)

        let reopened = JSONFileStore(fileURL: url)
        let found = try await reopened.loadSession(id: session.id)
        let sessions = try await reopened.loadSessions(in: day())
        let accomplishments = try await reopened.loadAccomplishments(in: day())

        #expect(found == nil)
        #expect(sessions.isEmpty)
        #expect(accomplishments.isEmpty)
    }
}

@Suite("Atomic file writer")
struct AtomicFileWriterTests {

    @Test("Writing creates intermediate directories")
    func createsIntermediateDirectories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
            .appendingPathComponent("store.json")

        try AtomicFileWriter.write(Data("first".utf8), to: url)

        let written = try Data(contentsOf: url)
        #expect(written == Data("first".utf8))
    }

    @Test("Rewriting replaces the contents and leaves no temporary file behind")
    func replacesWithoutLeavingDebris() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        try AtomicFileWriter.write(Data("first".utf8), to: url)
        try AtomicFileWriter.write(Data("second".utf8), to: url)

        let written = try Data(contentsOf: url)
        #expect(written == Data("second".utf8))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names == ["store.json"])
    }

    @Test("A path that cannot be created reports a persistence failure")
    func reportsPersistenceFailure() throws {
        // /dev/null is a character device, so no directory can ever live underneath it.
        let url = URL(fileURLWithPath: "/dev/null/lggr/store.json")

        #expect(throws: StoreError.self) {
            try AtomicFileWriter.write(Data("payload".utf8), to: url)
        }
    }
}

@Suite("Store snapshot")
struct StoreSnapshotTests {

    // The snapshot is exercised through the same coders the store writes with, so a change to the
    // on-disk format cannot pass here and then lose data in `JSONFileStore`.
    private func makeDecoder() -> JSONDecoder {
        StoreSnapshot.makeDecoder()
    }

    private func makeEncoder() -> JSONEncoder {
        StoreSnapshot.makeEncoder()
    }

    @Test("An empty snapshot round trips at the current schema version")
    func emptySnapshotRoundTrips() throws {
        let data = try makeEncoder().encode(StoreSnapshot())
        let decoded = try makeDecoder().decode(StoreSnapshot.self, from: data)

        #expect(decoded.schemaVersion == StoreSnapshot.currentSchemaVersion)
        #expect(decoded.isEmpty)
    }

    @Test("A populated snapshot round trips unchanged")
    func populatedSnapshotRoundTrips() throws {
        let snapshot = StoreSnapshot(
            projects: [Project(name: "Receipt ingest")],
            sessions: [FocusSession(intendedOutcome: "Morning block")],
            accomplishments: [Accomplishment(title: "Reviewed the ingest PR")]
        )

        let data = try makeEncoder().encode(snapshot)
        let decoded = try makeDecoder().decode(StoreSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }

    @Test("A newer schema version is rejected as invalid data")
    func newerSchemaVersionIsInvalid() throws {
        let decoder = makeDecoder()
        let data = Data("{\"schemaVersion\":\(StoreSnapshot.currentSchemaVersion + 1)}".utf8)

        #expect(throws: StoreError.self) {
            _ = try decoder.decode(StoreSnapshot.self, from: data)
        }
    }

    @Test("A zero or negative schema version is rejected")
    func nonPositiveSchemaVersionIsInvalid() throws {
        let decoder = makeDecoder()

        #expect(throws: StoreError.self) {
            _ = try decoder.decode(StoreSnapshot.self, from: Data("{\"schemaVersion\":0}".utf8))
        }
    }

    @Test("Missing collections decode as empty rather than failing")
    func missingCollectionsDecodeAsEmpty() throws {
        let decoder = makeDecoder()
        let decoded = try decoder.decode(
            StoreSnapshot.self,
            from: Data("{\"schemaVersion\":1}".utf8)
        )

        #expect(decoded.isEmpty)
    }
}
