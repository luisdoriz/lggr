import Foundation
import Testing

@testable import LggrKit

/// Backups are the only thing that makes a *successful but wrong* write survivable. Atomic writes
/// protect against a write that fails; nothing in the app protected against one that succeeded and
/// erased a week.
///
/// Every test works in a temporary directory. `StoreBackups` derives its folder from the document's own
/// location, which is why nothing here can reach `~/Library/Application Support/Lggr`.
@Suite("Store backups")
struct StoreBackupsTests {

    static let friday = Date(timeIntervalSinceReferenceDate: 806_500_000)

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreBackupsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func day(_ offset: Int) -> Date {
        Self.friday.addingTimeInterval(Double(offset) * 86_400)
    }

    private func documentWithContent(_ name: String = "Receipt ingestion") throws -> Data {
        try StoreSnapshot.makeEncoder().encode(StoreSnapshot(projects: [Project(name: name)]))
    }

    private func emptyDocument() throws -> Data {
        try StoreSnapshot.makeEncoder().encode(StoreSnapshot())
    }

    /// Puts a backup in place directly, the way an earlier launch would have.
    private func seedBackup(_ data: Data, on date: Date, in directory: URL) throws {
        let folder = directory.appendingPathComponent(StoreBackups.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(StoreBackups.fileName(for: date)))
    }

    private func backupNames(in directory: URL) -> [String] {
        StoreBackups
            .existingBackups(
                in: directory.appendingPathComponent(
                    StoreBackups.directoryName,
                    isDirectory: true
                )
            )
            .map(\.lastPathComponent)
    }

    private func isEmptyDocument(at url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return true }
        return try StoreSnapshot.makeDecoder().decode(StoreSnapshot.self, from: data).isEmpty
    }

    // MARK: - Taking a backup

    @Test("A backup is a byte-for-byte copy in the backups subdirectory")
    func capturesTheDocument() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")
        let data = try documentWithContent()
        try data.write(to: store)

        let backup = try StoreBackups.capture(storeAt: store, on: Self.friday)

        let url = try #require(backup)
        #expect(url.deletingLastPathComponent().lastPathComponent == StoreBackups.directoryName)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test("No document yet means no backup and no error")
    func missingDocumentProducesNoBackup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        #expect(try StoreBackups.capture(storeAt: store, on: Self.friday) == nil)
        #expect(backupNames(in: directory).isEmpty)
    }

    /// The day's copy was taken before whatever has happened since, which makes it the better of the
    /// two by definition. A second launch must not replace it with today's later state.
    @Test("A second capture on the same day leaves the day's backup alone")
    func secondCaptureOnTheSameDayIsDeclined() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        let morning = try documentWithContent("Receipt ingestion")
        try morning.write(to: store)
        let first = try #require(try StoreBackups.capture(storeAt: store, on: Self.friday))

        // Something went wrong during the day and the document is now different.
        try emptyDocument().write(to: store)
        #expect(try StoreBackups.capture(storeAt: store, on: Self.friday) == nil)

        #expect(try Data(contentsOf: first) == morning)
        #expect(backupNames(in: directory).count == 1)
    }

    // MARK: - Rotation

    @Test("Rotation keeps the most recent and drops the oldest")
    func rotationKeepsTheMostRecent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        // Exactly at the limit already: seven days of copies, all with content.
        for offset in -7...(-1) {
            try seedBackup(try documentWithContent("Day \(offset)"), on: day(offset), in: directory)
        }
        let oldest = StoreBackups.fileName(for: day(-7))
        #expect(backupNames(in: directory).count == StoreBackups.keepCount)

        try documentWithContent("Today").write(to: store)
        _ = try StoreBackups.capture(storeAt: store, on: Self.friday)

        let names = backupNames(in: directory)
        #expect(names.count == StoreBackups.keepCount)
        #expect(!names.contains(oldest))
        #expect(names.contains(StoreBackups.fileName(for: Self.friday)))
    }

    /// **The subtle one.** The defect these backups exist for produces an empty store. If an empty
    /// document could take a slot, the first launch after the fault would rotate out the one copy that
    /// could have saved the user — the remedy destroyed by the fault it is the remedy for.
    @Test("An empty store does not displace a backup that has content")
    func emptyStoreDoesNotDisplaceContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        for offset in -7...(-1) {
            try seedBackup(try documentWithContent("Day \(offset)"), on: day(offset), in: directory)
        }
        let before = backupNames(in: directory)

        try emptyDocument().write(to: store)
        #expect(try StoreBackups.capture(storeAt: store, on: Self.friday) == nil)

        #expect(backupNames(in: directory) == before)
        let folder = directory.appendingPathComponent(StoreBackups.directoryName, isDirectory: true)
        for url in StoreBackups.existingBackups(in: folder) {
            #expect(try isEmptyDocument(at: url) == false)
        }
    }

    /// Even one surviving copy is enough to refuse, because that copy is the whole point.
    @Test("An empty store does not displace the single remaining full backup")
    func emptyStoreDoesNotDisplaceTheLastFullBackup() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        try seedBackup(try documentWithContent("The only copy"), on: day(-3), in: directory)
        try emptyDocument().write(to: store)

        #expect(try StoreBackups.capture(storeAt: store, on: Self.friday) == nil)
        #expect(backupNames(in: directory) == [StoreBackups.fileName(for: day(-3))])
    }

    /// A truncated `store.json` is the same case: zero bytes has nothing to protect.
    @Test("A zero-length store does not displace a backup that has content")
    func zeroLengthStoreDoesNotDisplaceContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        try seedBackup(try documentWithContent(), on: day(-1), in: directory)
        try Data().write(to: store)

        #expect(try StoreBackups.capture(storeAt: store, on: Self.friday) == nil)
        #expect(backupNames(in: directory) == [StoreBackups.fileName(for: day(-1))])
    }

    /// With nothing to lose there is no reason to refuse: an empty backup on a genuinely empty store is
    /// harmless, and it is the first one pruned once anything better exists.
    @Test("An empty store is backed up when there is nothing better to keep")
    func emptyStoreIsBackedUpWhenThereIsNothingElse() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")
        try emptyDocument().write(to: store)

        #expect(try StoreBackups.capture(storeAt: store, on: Self.friday) != nil)
        #expect(backupNames(in: directory) == [StoreBackups.fileName(for: Self.friday)])
    }

    /// Oldest-first pruning would delete the only full copy while keeping six empty ones written by a
    /// broken instance. Empty backups are shed first.
    @Test("Rotation sheds empty backups before ones with content")
    func rotationPrefersToDeleteEmptyBackups() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        // The oldest is the good one; everything after it is empty.
        try seedBackup(try documentWithContent("The good copy"), on: day(-7), in: directory)
        for offset in -6...(-1) {
            try seedBackup(try emptyDocument(), on: day(offset), in: directory)
        }
        #expect(backupNames(in: directory).count == StoreBackups.keepCount)

        try documentWithContent("Today").write(to: store)
        _ = try StoreBackups.capture(storeAt: store, on: Self.friday)

        let names = backupNames(in: directory)
        #expect(names.count == StoreBackups.keepCount)
        // The good copy survived; the oldest *empty* one went instead.
        #expect(names.contains(StoreBackups.fileName(for: day(-7))))
        #expect(!names.contains(StoreBackups.fileName(for: day(-6))))
    }

    @Test("A smaller limit rotates down to it")
    func rotationHonoursASmallerLimit() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")

        for offset in -5...(-1) {
            try seedBackup(try documentWithContent("Day \(offset)"), on: day(offset), in: directory)
        }
        try documentWithContent("Today").write(to: store)

        _ = try StoreBackups.capture(storeAt: store, on: Self.friday, keeping: 3)

        let names = backupNames(in: directory)
        #expect(names.count == 3)
        #expect(names.contains(StoreBackups.fileName(for: Self.friday)))
        #expect(!names.contains(StoreBackups.fileName(for: day(-5))))
    }

    /// Keeping zero would delete the copy that was just written, which is worse than keeping one.
    @Test("A limit below one still keeps a backup")
    func limitBelowOneStillKeepsOne() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("store.json")
        try documentWithContent().write(to: store)

        _ = try StoreBackups.capture(storeAt: store, on: Self.friday, keeping: 0)

        #expect(backupNames(in: directory).count == 1)
    }

    // MARK: - The store takes one on launch

    /// The backup has to be a copy of what the user arrived with, not of what this instance decided the
    /// document should be. It is taken before the first write for exactly that reason.
    @Test("The store backs the document up before its first write")
    @MainActor
    func launchBackupPrecedesTheFirstWrite() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let arrived = Project(name: "Receipt ingestion")
        let original = try StoreSnapshot.makeEncoder().encode(StoreSnapshot(projects: [arrived]))
        try original.write(to: url)

        let store = JSONFileStore(fileURL: url)
        try await store.saveProject(Project(name: "Added by this launch"))

        let folder = directory.appendingPathComponent(StoreBackups.directoryName, isDirectory: true)
        let backups = StoreBackups.existingBackups(in: folder)
        #expect(backups.count == 1)

        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup) == original)
    }

    /// One per launch, not one per save: a backup on every write would rotate a week down to an hour.
    @Test("Many saves in one launch take one backup")
    @MainActor
    func launchBackupIsTakenOnce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        try StoreSnapshot.makeEncoder()
            .encode(StoreSnapshot(projects: [Project(name: "Receipt ingestion")]))
            .write(to: url)

        let store = JSONFileStore(fileURL: url)
        for index in 0..<5 {
            try await store.saveProject(Project(name: "Project \(index)"))
        }

        #expect(backupNames(in: directory).count == 1)
    }
}
