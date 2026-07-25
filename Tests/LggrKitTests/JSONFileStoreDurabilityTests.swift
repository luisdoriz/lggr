import Foundation
import Testing

@testable import LggrKit

/// Regression tests for defects that silently destroyed user records.
///
/// Each of these passed review as "obviously fine" code. They are grouped here, apart from the
/// behavioural suite, because what they protect is not a feature — it is the promise that a record
/// the app said it saved is still there tomorrow. There is no server copy to fall back on.
@Suite("JSON file store durability")
@MainActor
struct JSONFileStoreDurabilityTests {

    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func at(_ minutes: Double) -> Date {
        Self.nineAM.addingTimeInterval(minutes * 60)
    }

    private func day() -> DateInterval {
        DateInterval(start: at(-540), end: at(900))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JSONFileStoreDurabilityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func quarantineFiles(in directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("store-corrupt-") }
    }

    // MARK: - Concurrent first writes

    /// Two saves that overlap *before the first disk read finishes* must both survive.
    ///
    /// The store loads lazily, so the very first save has to wait for the file. A second save
    /// arriving during that wait used to receive the document as it was on disk rather than as it
    /// had just become in memory, build its mutation on that stale copy, and write it back — erasing
    /// the first save from memory and then from the file. The app reaches this on every launch: a
    /// global shortcut starting a session while `bootstrap()` is still loading produces exactly this
    /// interleaving.
    @Test("Two saves racing the initial load both survive")
    func concurrentFirstSavesBothSurvive() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let project = Project(name: "Receipt ingestion")
        let session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            startedAt: Self.nineAM
        )

        let store = JSONFileStore(fileURL: url)
        async let saveProject: Void = store.saveProject(project)
        async let saveSession: Void = store.saveSession(session)
        _ = try await (saveProject, saveSession)

        // Reopening is the honest check: it proves the bytes on disk hold both, not just memory.
        let reopened = JSONFileStore(fileURL: url)
        #expect(try await reopened.loadProjects() == [project])
        #expect(try await reopened.loadSessions(in: day()).count == 1)
    }

    @Test("Many overlapping saves all survive")
    func manyConcurrentSavesSurvive() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let projects = (0..<12).map { Project(name: "Project \($0)") }
        let store = JSONFileStore(fileURL: url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for project in projects {
                group.addTask { try await store.saveProject(project) }
            }
            try await group.waitForAll()
        }

        let reopened = JSONFileStore(fileURL: url)
        let loaded = try await reopened.loadProjects()
        #expect(loaded.count == projects.count)
        #expect(Set(loaded.map(\.id)) == Set(projects.map(\.id)))
    }

    // MARK: - Truncated file

    /// A zero-length `store.json` is a truncated write, never a fresh install: an empty store still
    /// encodes to a JSON object, so this writer cannot produce one. Reading it as "new user" would
    /// let the next save overwrite whatever was still recoverable.
    @Test("A zero-length file is preserved, not treated as a new install")
    func emptyFileIsQuarantined() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        try Data().write(to: url)

        let store = JSONFileStore(fileURL: url)
        #expect(try await store.loadProjects().isEmpty)

        #expect(try quarantineFiles(in: directory).count == 1)
        #expect(store.quarantineNotice != nil)
    }

    // MARK: - Unknown values

    /// A single enum raw value this build does not know must not condemn the whole document.
    ///
    /// The realistic cause is a downgrade: a later version records a session with a work type this
    /// build has never heard of, and the user goes back a version. Quarantining would move every
    /// project, session and accomplishment out of the way over one unknown string. Refusing leaves
    /// the file exactly where it is, so re-updating recovers everything.
    @Test("An unknown enum value refuses the file instead of quarantining it")
    func unknownEnumValueRefusesRatherThanQuarantines() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let document = """
            {
              "accomplishments" : [],
              "projects" : [],
              "schemaVersion" : 1,
              "sessions" : [
                {
                  "id" : "\(UUID().uuidString)",
                  "intendedOutcome" : "Finish the receipt deduplication PR",
                  "workType" : "quantumTunnelling",
                  "startedAt" : 727083600,
                  "pausedDuration" : 0,
                  "isReactive" : false,
                  "interruptionCount" : 0
                }
              ]
            }
            """
        let original = Data(document.utf8)
        try original.write(to: url)

        let store = JSONFileStore(fileURL: url)
        await #expect(throws: StoreError.self) {
            _ = try await store.loadProjects()
        }

        #expect(try quarantineFiles(in: directory).isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    /// Genuine rubbish still gets moved aside — the point is to distinguish "not JSON" from
    /// "JSON this build cannot interpret", not to stop quarantining altogether.
    @Test("A file that is not JSON at all is still moved aside")
    func nonJSONIsQuarantined() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        try Data("this is not json".utf8).write(to: url)

        let store = JSONFileStore(fileURL: url)
        #expect(try await store.loadProjects().isEmpty)
        #expect(try quarantineFiles(in: directory).count == 1)
        #expect(store.quarantineNotice != nil)
    }

    // MARK: - Failed writes

    /// A change that never reached the disk must not stay visible in memory.
    ///
    /// Otherwise the app shows the project as saved, the error banner says it failed, and the next
    /// launch disagrees with both — and the user has no way to tell which one was true.
    @Test("A failed write rolls the in-memory document back")
    func failedWriteRollsBack() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // The store's parent is a regular file, so creating its directory cannot succeed.
        let blocker = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        let url = blocker.appendingPathComponent("store.json")

        let store = JSONFileStore(fileURL: url)
        await #expect(throws: StoreError.self) {
            try await store.saveProject(Project(name: "Receipt ingestion"))
        }

        #expect(try await store.loadProjects().isEmpty)
    }

    // MARK: - Ordering agreement

    /// The fake and the durable store must order identically, including ties. Unit tests run against
    /// the fake, so any divergence means the suite is green about behaviour production does not have.
    @Test("Both stores order ties identically")
    func bothStoresAgreeOnTieOrdering() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let sameInstant = Self.nineAM
        let first = FocusSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID(),
            intendedOutcome: "first",
            startedAt: sameInstant
        )
        let second = FocusSession(
            id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001") ?? UUID(),
            intendedOutcome: "second",
            startedAt: sameInstant
        )

        let file = JSONFileStore(fileURL: url)
        try await file.saveSession(first)
        try await file.saveSession(second)

        let memory = InMemoryStore(sessions: [first, second])

        let fileOrder = try await file.loadSessions(in: day()).map(\.intendedOutcome)
        let memoryOrder = try await memory.loadSessions(in: day()).map(\.intendedOutcome)

        #expect(fileOrder == memoryOrder)
        #expect(fileOrder == ["second", "first"])
    }

    // MARK: - Unreviewed sessions

    /// Finishing a session and quitting before answering "What happened?" is ordinary — the sheet
    /// appears exactly when someone is standing up to leave. The session has an `endedAt`, so
    /// `loadActiveSession` will never return it; without a separate lookup it is stranded with no
    /// result, forever, and the day's log quietly under-reports.
    @Test("A finished but unreviewed session is recoverable after a relaunch")
    func unreviewedSessionSurvivesRelaunch() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        var session = FocusSession(
            intendedOutcome: "Finish the receipt deduplication PR",
            startedAt: Self.nineAM
        )
        session.finish(at: at(45))

        let store = JSONFileStore(fileURL: url)
        try await store.saveSession(session)

        let reopened = JSONFileStore(fileURL: url)
        #expect(try await reopened.loadActiveSession() == nil)
        #expect(try await reopened.loadUnreviewedSession()?.id == session.id)

        // Once reviewed it stops being offered.
        var reviewed = session
        reviewed.resultStatus = .madeProgress
        try await reopened.saveSession(reviewed)
        #expect(try await reopened.loadUnreviewedSession() == nil)
    }

    @Test("Both stores agree on which session needs reviewing")
    func bothStoresAgreeOnUnreviewedSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        var unreviewed = FocusSession(intendedOutcome: "unreviewed", startedAt: Self.nineAM)
        unreviewed.finish(at: at(30))
        var reviewed = FocusSession(intendedOutcome: "reviewed", startedAt: at(60))
        reviewed.finish(at: at(90), status: .completed)

        let file = JSONFileStore(fileURL: url)
        try await file.saveSession(unreviewed)
        try await file.saveSession(reviewed)
        let memory = InMemoryStore(sessions: [unreviewed, reviewed])

        let fromFile = try await file.loadUnreviewedSession()?.intendedOutcome
        let fromMemory = try await memory.loadUnreviewedSession()?.intendedOutcome

        #expect(fromFile == fromMemory)
        #expect(fromFile == "unreviewed")
    }

    /// The spec asks the review sheet for a tangible result alongside the summary, the blocker and
    /// the next step. It is the artefact the weekly review can point at, so it has to survive a
    /// round trip like everything else.
    @Test("The tangible result round-trips")
    func tangibleResultRoundTrips() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        var session = FocusSession(intendedOutcome: "Dedup PR", startedAt: Self.nineAM)
        session.finish(at: at(45), status: .completed)
        session.resultSummary = "Split the dedup pass out of the ingest job."
        session.tangibleResult = "Opened PR #482"
        session.nextStep = "Ask Omar to review"

        let store = JSONFileStore(fileURL: url)
        try await store.saveSession(session)

        let reopened = JSONFileStore(fileURL: url)
        let loaded = try await reopened.loadSession(id: session.id)
        #expect(loaded?.tangibleResult == "Opened PR #482")
        #expect(loaded == session)
    }

    @Test("Both stores pick the same active session when several are unfinished")
    func bothStoresAgreeOnActiveSession() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let older = FocusSession(intendedOutcome: "older", startedAt: Self.nineAM)
        let newer = FocusSession(intendedOutcome: "newer", startedAt: at(30))

        let file = JSONFileStore(fileURL: url)
        try await file.saveSession(older)
        try await file.saveSession(newer)

        let memory = InMemoryStore(sessions: [older, newer])

        let fromFile = try await file.loadActiveSession()?.intendedOutcome
        let fromMemory = try await memory.loadActiveSession()?.intendedOutcome

        #expect(fromFile == fromMemory)
        #expect(fromFile == "newer")
    }
}
