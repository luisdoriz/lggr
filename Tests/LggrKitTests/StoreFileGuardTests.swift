import Foundation
import Testing

@testable import LggrKit

/// The defect: `JSONFileStore` read the document once and treated its in-memory copy as authoritative
/// forever, writing the whole thing back on every save. Anything else that touched the file — a second
/// copy of the app, a second launch, a user putting a good `store.json` back while Lggr was open — was
/// silently overwritten by the next save.
///
/// Reproduced in the wild: a running instance overwrote a file that had been replaced underneath it and
/// re-seeded the default classification rules on top, believing itself to be on a first launch.
///
/// Every test here works in a temporary directory. Nothing in this file may touch
/// `~/Library/Application Support/Lggr`.
@Suite("Store file guard")
@MainActor
struct StoreFileGuardTests {

    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreFileGuardTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a document straight to disk, the way another instance or a restore would.
    @discardableResult
    private func writeDocument(_ snapshot: StoreSnapshot, to url: URL) throws -> Data {
        let data = try StoreSnapshot.makeEncoder().encode(snapshot)
        try data.write(to: url)
        return data
    }

    private func readDocument(at url: URL) throws -> StoreSnapshot {
        try StoreSnapshot.makeDecoder().decode(StoreSnapshot.self, from: Data(contentsOf: url))
    }

    private func setModificationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func unwrittenFiles(in directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("store-unwritten-") }
    }

    // MARK: - Identity

    @Test("A missing file has no identity to match")
    func missingFileIsAbsent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(StoreFileIdentity.read(directory.appendingPathComponent("store.json")) == .absent)
    }

    @Test("A file that has not changed verifies as unchanged")
    func unchangedFileVerifies() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        try writeDocument(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]), to: url)

        var fileGuard = StoreFileGuard()
        fileGuard.adoptIdentity(of: url)

        #expect(fileGuard.verify(url) == .unchanged)
    }

    /// The blind spot that made "modification date only" the wrong choice. Two writes inside the same
    /// timestamp tick leave the date identical, so the size is what catches them.
    @Test("A same-second rewrite with a different size is still a change")
    func sameSecondDifferentSizeIsAChange() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        try writeDocument(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]), to: url)
        try setModificationDate(Self.nineAM, of: url)

        var fileGuard = StoreFileGuard()
        fileGuard.adoptIdentity(of: url)

        // A different document, forced back to the very same modification date.
        try writeDocument(
            StoreSnapshot(projects: [
                Project(name: "Receipt ingestion"),
                Project(name: "Invoice reconciliation"),
            ]),
            to: url
        )
        try setModificationDate(Self.nineAM, of: url)

        guard case .changed = fileGuard.verify(url) else {
            Issue.record("A same-second rewrite of a different size was not detected.")
            return
        }
    }

    /// The other half: same size, different modification date. Editing an outcome string to another of
    /// equal length does exactly this.
    @Test("A same-size rewrite at a later time is still a change")
    func sameSizeLaterDateIsAChange() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        // One project, renamed to another name of the same length, with every date held fixed — so
        // the two documents are guaranteed to encode to the same number of bytes.
        var project = Project(
            name: "AAAA",
            createdAt: Self.nineAM,
            updatedAt: Self.nineAM
        )
        let first = try writeDocument(StoreSnapshot(projects: [project]), to: url)
        try setModificationDate(Self.nineAM, of: url)

        var fileGuard = StoreFileGuard()
        fileGuard.adoptIdentity(of: url)

        project.name = "BBBB"
        let second = try writeDocument(StoreSnapshot(projects: [project]), to: url)
        try setModificationDate(Self.nineAM.addingTimeInterval(60), of: url)

        // The premise of the test: the sizes really are equal, so only the date can catch this.
        #expect(first.count == second.count)
        guard case .changed = fileGuard.verify(url) else {
            Issue.record("A same-size rewrite at a later time was not detected.")
            return
        }
    }

    @Test("Content we have never read is a change, not a blank slate")
    func unreadFileIsAChange() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        try writeDocument(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]), to: url)

        // Nothing recorded: the file is content this guard has never seen.
        let fileGuard = StoreFileGuard()
        guard case .changed = fileGuard.verify(url) else {
            Issue.record("An unread file was treated as unchanged.")
            return
        }
    }

    @Test("With nothing recorded, a missing file is the genuine first write")
    func absentFileWithNothingRecordedIsUnchanged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileGuard = StoreFileGuard()
        #expect(fileGuard.verify(directory.appendingPathComponent("store.json")) == .unchanged)
    }

    // MARK: - The store refuses to overwrite

    /// The headline case. Another instance, or a restored backup, replaces the file between our load
    /// and our save. The save must not land, and the replacement must survive untouched.
    @Test("A file changed between load and write is not overwritten")
    func changeBetweenLoadAndWriteIsRefused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let ours = Project(name: "Receipt ingestion")
        try writeDocument(StoreSnapshot(projects: [ours]), to: url)

        let store = JSONFileStore(fileURL: url)
        #expect(try await store.loadProjects() == [ours])

        // What the user restored, or what the other instance wrote.
        let theirs = Project(name: "Invoice reconciliation")
        let restored = StoreSnapshot(
            projects: [theirs],
            sessions: [FocusSession(intendedOutcome: "Ship the importer", startedAt: Self.nineAM)]
        )
        let restoredBytes = try writeDocument(restored, to: url)

        await #expect(throws: StoreError.self) {
            try await store.saveProject(Project(name: "Something new"))
        }

        // The restored file is byte-for-byte what was put there.
        #expect(try Data(contentsOf: url) == restoredBytes)
        #expect(store.externalChangeNotice != nil)
    }

    /// Nothing may be destroyed on either side: the disk copy stays, and the document this instance was
    /// holding is written down beside it.
    @Test("The document that was not written is preserved beside the store")
    func refusedDocumentIsPreserved() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        try writeDocument(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]), to: url)
        let store = JSONFileStore(fileURL: url)
        _ = try await store.loadProjects()

        try writeDocument(StoreSnapshot(projects: [Project(name: "Invoice reconciliation")]), to: url)

        let unsaved = Project(name: "The one the user thinks is saved")
        await #expect(throws: StoreError.self) { try await store.saveProject(unsaved) }

        let preserved = try unwrittenFiles(in: directory)
        #expect(preserved.count == 1)
        guard let name = preserved.first else { return }

        let rescued = try readDocument(at: directory.appendingPathComponent(name))
        #expect(rescued.projects.contains(unsaved))
        // And the notice names the file, so the user can find it.
        #expect(store.externalChangeNotice?.contains(name) == true)
    }

    /// Reloading is the other half of the fix: an instance that refused a write but kept its stale
    /// document would go on refusing forever, and would still be showing the user the wrong history.
    @Test("After a refusal the store reloads and shows what is on disk")
    func refusalReloadsFromDisk() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let ours = Project(name: "Receipt ingestion")
        try writeDocument(StoreSnapshot(projects: [ours]), to: url)

        let store = JSONFileStore(fileURL: url)
        _ = try await store.loadProjects()

        let theirs = Project(name: "Invoice reconciliation")
        try writeDocument(StoreSnapshot(projects: [theirs]), to: url)

        await #expect(throws: StoreError.self) { try await store.saveProject(Project(name: "New")) }

        #expect(try await store.loadProjects() == [theirs])
    }

    /// And the instance has to keep working afterwards. A store that is permanently wedged after one
    /// external change would cost the user every session from then on.
    @Test("The next save after a refusal lands on disk")
    func saveAfterRefusalSucceeds() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let theirs = Project(name: "Invoice reconciliation")
        try writeDocument(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]), to: url)

        let store = JSONFileStore(fileURL: url)
        _ = try await store.loadProjects()
        try writeDocument(StoreSnapshot(projects: [theirs]), to: url)
        await #expect(throws: StoreError.self) { try await store.saveProject(Project(name: "New")) }

        let afterwards = Project(name: "Recorded after the conflict")
        try await store.saveProject(afterwards)

        let reopened = JSONFileStore(fileURL: url)
        let projects = try await reopened.loadProjects()
        #expect(projects.contains(afterwards))
        // The other writer's project is still there: the recovery did not restart from our stale copy.
        #expect(projects.contains(theirs))
    }

    /// A restore that shrinks the file — putting back a smaller, earlier `store.json` — is the same
    /// defect wearing different clothes, and used to be undone just as silently.
    @Test("A file replaced by a shorter one is not overwritten")
    func shorterReplacementIsRefused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let long = StoreSnapshot(
            projects: (0..<8).map { Project(name: "Project \($0)") },
            sessions: (0..<8).map {
                FocusSession(
                    intendedOutcome: "Outcome \($0)",
                    startedAt: Self.nineAM.addingTimeInterval(Double($0) * 600)
                )
            }
        )
        let longBytes = try writeDocument(long, to: url)

        let store = JSONFileStore(fileURL: url)
        #expect(try await store.loadProjects().count == 8)

        let shortBytes = try writeDocument(
            StoreSnapshot(projects: [Project(name: "Receipt ingestion")]),
            to: url
        )
        #expect(shortBytes.count < longBytes.count)

        await #expect(throws: StoreError.self) {
            try await store.saveProject(Project(name: "Something new"))
        }

        #expect(try Data(contentsOf: url) == shortBytes)
        #expect(store.externalChangeNotice != nil)
    }

    /// A deleted file must not be silently recreated from memory.
    ///
    /// Both plausible causes say the same thing. If the user deleted their history, writing it back
    /// undoes a deliberate act. If a restore is in progress — a `rm` followed by a `cp` — writing now
    /// races the copy and can corrupt it. Refusing, preserving and reloading is right for both.
    @Test("A file deleted underneath us is not silently recreated")
    func deletedFileIsRefused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        try writeDocument(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]), to: url)
        let store = JSONFileStore(fileURL: url)
        _ = try await store.loadProjects()

        try FileManager.default.removeItem(at: url)

        await #expect(throws: StoreError.self) {
            try await store.saveProject(Project(name: "Something new"))
        }

        #expect(!FileManager.default.fileExists(atPath: url.path))
        // Nothing lost: the document we were holding is on disk under its own name.
        #expect(try unwrittenFiles(in: directory).count == 1)
        #expect(store.externalChangeNotice != nil)
    }

    // MARK: - What must still work

    /// The guard must not get in the way of the ordinary case, which is one instance writing over its
    /// own file, over and over.
    @Test("Repeated saves from one instance are unaffected")
    func repeatedSavesStillWork() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let store = JSONFileStore(fileURL: url)
        let projects = (0..<10).map { Project(name: "Project \($0)") }
        for project in projects {
            try await store.saveProject(project)
        }

        let reopened = JSONFileStore(fileURL: url)
        #expect(try await reopened.loadProjects().count == 10)
        #expect(store.externalChangeNotice == nil)
        #expect(try unwrittenFiles(in: directory).isEmpty)
    }

    /// A quarantined file has been moved out of the way, so the store is genuinely starting fresh and
    /// the first write has to be allowed to create the file. Recording the moved file's identity would
    /// have refused every save from then on.
    @Test("A save after a quarantine is allowed to create the file")
    func saveAfterQuarantineSucceeds() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        try Data("this is not json".utf8).write(to: url)

        let store = JSONFileStore(fileURL: url)
        #expect(try await store.loadProjects().isEmpty)

        let project = Project(name: "Receipt ingestion")
        try await store.saveProject(project)

        let reopened = JSONFileStore(fileURL: url)
        #expect(try await reopened.loadProjects() == [project])
        #expect(store.externalChangeNotice == nil)
    }
}
