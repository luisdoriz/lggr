import Foundation

/// The persistence backend Lggr ships with: one JSON document, held in memory, written whole.
///
/// Reads never touch the disk after the first load, so no menu bar interaction can block on I/O.
/// Writes serialize the entire document, which is the right trade at this scale — a few thousand
/// small records a year — because it removes every class of bug where two collections disagree.
///
/// Encoding and writing happen on a private actor, so the main actor is free while the file is
/// produced. Saves are `async` and only return once the bytes are on disk, so a caller that awaits
/// its saves in order gets them applied in order.
@MainActor
public final class JSONFileStore: LggrStore {

    /// The document this store reads and writes.
    public let fileURL: URL

    private let file: SnapshotFile
    private var snapshot: StoreSnapshot?
    private var loadTask: Task<SnapshotLoad, any Error>?
    /// Assigned on the main actor in mutation order, then checked inside the writer. Actor jobs are
    /// not guaranteed to run in the order they were enqueued, so without this an older document
    /// could land on disk after a newer one.
    private var writeSequence: UInt64 = 0

    /// Set when the file on disk could not be read and was preserved under another name. The app
    /// surfaces this; an unreadable store must never be indistinguishable from a first launch.
    public private(set) var quarantineNotice: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.file = SnapshotFile()
    }

    /// Uses `~/Library/Application Support/Lggr/store.json`.
    public convenience init() throws {
        self.init(fileURL: try JSONFileStore.defaultFileURL())
    }

    public static func defaultFileURL() throws -> URL {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return
                base
                .appendingPathComponent("Lggr", isDirectory: true)
                .appendingPathComponent("store.json", isDirectory: false)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not locate the Application Support directory: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Projects

    public func loadProjects() async throws -> [Project] {
        try await loaded().projects
    }

    public func saveProject(_ project: Project) async throws {
        try await mutate { snapshot in upsert(project, into: &snapshot.projects) }
    }

    /// Deleting a project is not a cascade. Sessions and accomplishments filed under it keep every
    /// field except `projectID`, because the record of work done is not the project's to take away.
    ///
    /// Deleting a project that is not there succeeds: the caller's intent — "this project should not
    /// exist" — already holds, and a menu bar app should not surface an error for that.
    public func deleteProject(id: UUID) async throws {
        try await mutate { snapshot in
            snapshot.projects.removeAll { $0.id == id }
            for index in snapshot.sessions.indices where snapshot.sessions[index].projectID == id {
                snapshot.sessions[index].projectID = nil
            }
            for index in snapshot.accomplishments.indices
            where snapshot.accomplishments[index].projectID == id {
                snapshot.accomplishments[index].projectID = nil
            }
            // A converted interruption stays converted: turning it into tracked work is what
            // happened, and only the label that work was filed under is going away.
            for index in snapshot.interruptions.indices
            where snapshot.interruptions[index].convertedProjectID == id {
                snapshot.interruptions[index].convertedProjectID = nil
            }
            for index in snapshot.weeklyOutcomes.indices
            where snapshot.weeklyOutcomes[index].projectIDs.contains(id) {
                snapshot.weeklyOutcomes[index].projectIDs.removeAll { $0 == id }
            }
        }
    }

    // MARK: - Focus sessions

    public func loadSessions(in interval: DateInterval) async throws -> [FocusSession] {
        try await loaded().sessions
            .filter { StoreOrdering.contains($0.startedAt, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func loadSession(id: UUID) async throws -> FocusSession? {
        try await loaded().sessions.first { $0.id == id }
    }

    public func loadActiveSession() async throws -> FocusSession? {
        try await loaded().sessions
            .filter { $0.endedAt == nil }
            .min(by: StoreOrdering.newestFirst)
    }

    public func loadUnreviewedSession() async throws -> FocusSession? {
        try await loaded().sessions
            .filter { $0.endedAt != nil && $0.resultStatus == nil }
            .min(by: StoreOrdering.newestFirst)
    }

    public func saveSession(_ session: FocusSession) async throws {
        try await mutate { snapshot in upsert(session, into: &snapshot.sessions) }
    }

    public func deleteSession(id: UUID) async throws {
        try await mutate { snapshot in
            snapshot.sessions.removeAll { $0.id == id }
        }
    }

    // MARK: - Accomplishments

    public func loadAccomplishments(in interval: DateInterval) async throws -> [Accomplishment] {
        try await loaded().accomplishments
            .filter { StoreOrdering.contains($0.timestamp, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func saveAccomplishment(_ accomplishment: Accomplishment) async throws {
        try await mutate { snapshot in upsert(accomplishment, into: &snapshot.accomplishments) }
    }

    public func deleteAccomplishment(id: UUID) async throws {
        try await mutate { snapshot in
            snapshot.accomplishments.removeAll { $0.id == id }
        }
    }

    // MARK: - Interruptions

    public func loadInterruptions(in interval: DateInterval) async throws -> [Interruption] {
        try await loaded().interruptions
            .filter { StoreOrdering.contains($0.timestamp, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func loadPendingInterruptions() async throws -> [Interruption] {
        try await loaded().interruptions
            .filter(\.isPending)
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func saveInterruption(_ interruption: Interruption) async throws {
        try await mutate { snapshot in upsert(interruption, into: &snapshot.interruptions) }
    }

    public func deleteInterruption(id: UUID) async throws {
        try await mutate { snapshot in
            snapshot.interruptions.removeAll { $0.id == id }
        }
    }

    // MARK: - Weekly outcomes

    public func loadWeeklyOutcomes(in interval: DateInterval) async throws -> [WeeklyOutcome] {
        try await loaded().weeklyOutcomes
            .filter { StoreOrdering.contains($0.weekStartDate, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func saveWeeklyOutcome(_ outcome: WeeklyOutcome) async throws {
        try await mutate { snapshot in upsert(outcome, into: &snapshot.weeklyOutcomes) }
    }

    /// The week's declared intent is gone; the work that was done towards it is not. Sessions and
    /// accomplishments keep every field except `weeklyOutcomeID`.
    public func deleteWeeklyOutcome(id: UUID) async throws {
        try await mutate { snapshot in
            snapshot.weeklyOutcomes.removeAll { $0.id == id }
            for index in snapshot.sessions.indices
            where snapshot.sessions[index].weeklyOutcomeID == id {
                snapshot.sessions[index].weeklyOutcomeID = nil
            }
            for index in snapshot.accomplishments.indices
            where snapshot.accomplishments[index].weeklyOutcomeID == id {
                snapshot.accomplishments[index].weeklyOutcomeID = nil
            }
        }
    }

    // MARK: - Classification rules

    public func loadClassificationRules() async throws -> [ClassificationRule] {
        try await loaded().classificationRules
    }

    public func saveClassificationRule(_ rule: ClassificationRule) async throws {
        try await mutate { snapshot in upsert(rule, into: &snapshot.classificationRules) }
    }

    public func deleteClassificationRule(id: UUID) async throws {
        try await mutate { snapshot in
            snapshot.classificationRules.removeAll { $0.id == id }
        }
    }

    // MARK: - Snapshot lifecycle

    /// The in-memory document, loading it from disk exactly once.
    ///
    /// Concurrent first calls share one `Task` rather than each reading the file, so two views
    /// appearing at the same moment cannot produce two decodes or two quarantine files.
    ///
    /// Both returns re-check `snapshot` *after* awaiting. The disk value is only current until the
    /// first mutation lands: a caller that suspended on the shared load task and then returned that
    /// task's value would hand back a document that predates a save which completed while it slept,
    /// and the mutation built on top of it would erase that save from memory and then from disk.
    private func loaded() async throws -> StoreSnapshot {
        if let snapshot { return snapshot }

        // Deliberately not a retry loop. Re-checking in a loop can spin: a caller that wakes before
        // the loader has stored its result finds `snapshot` still nil and `loadTask` still set,
        // awaits an already-finished task — which need not suspend — and starves the very caller it
        // is waiting for. One re-check after one await is all the correctness requires.
        if let loadTask {
            let fromDisk = try await loadTask.value
            if let snapshot { return snapshot }
            adopt(fromDisk)
            return fromDisk.snapshot
        }

        let url = fileURL
        let file = self.file
        let task = Task { try await file.read(from: url) }
        loadTask = task
        defer { loadTask = nil }

        let result = try await task.value
        if let snapshot { return snapshot }
        adopt(result)
        return result.snapshot
    }

    /// Takes the freshly read document as the current one, unless a mutation already published a
    /// newer version while the read was in flight.
    private func adopt(_ load: SnapshotLoad) {
        if let quarantinedAs = load.quarantinedAs {
            quarantineNotice =
                "Lggr could not read its data file, so it started with an empty log. "
                + "The original is still there, saved as \(quarantinedAs)."
        }
        snapshot = load.snapshot
    }

    /// Applies `body` to the in-memory document, then writes the whole document.
    ///
    /// `body` runs synchronously between the two `await`s, so once the document is loaded no other
    /// call can interleave between reading it and storing the mutated version.
    ///
    /// A failed write rolls the in-memory document back. Publishing a change that never reached the
    /// disk would leave the app showing one thing, telling the user the save failed, and then losing
    /// the change at quit — three states that disagree. The rollback is skipped if a newer mutation
    /// has already replaced the value this call published, since that newer value is the one the
    /// user is now looking at.
    private func mutate(_ body: (inout StoreSnapshot) -> Void) async throws {
        let previous = try await loaded()
        var updated = previous
        body(&updated)
        updated.schemaVersion = StoreSnapshot.currentSchemaVersion
        snapshot = updated

        writeSequence &+= 1
        let sequence = writeSequence
        do {
            try await file.write(updated, to: fileURL, sequence: sequence)
        } catch {
            if snapshot == updated { snapshot = previous }
            throw error
        }
    }
}

private func upsert<Value: Identifiable>(
    _ value: Value,
    into collection: inout [Value]
) where Value.ID == UUID {
    if let index = collection.firstIndex(where: { $0.id == value.id }) {
        collection[index] = value
    } else {
        collection.append(value)
    }
}

/// Owns the JSON coders and every disk touch, off the main actor.
private actor SnapshotFile {

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let timestampFormatter: DateFormatter
    private var lastWrittenSequence: UInt64 = 0

    init() {
        // Every coder setting lives on StoreSnapshot, so the format the store writes and the format
        // anything else reads cannot drift apart.
        self.encoder = StoreSnapshot.makeEncoder()
        self.decoder = StoreSnapshot.makeDecoder()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        self.timestampFormatter = formatter
    }

    /// A missing file is an empty store. Anything else that cannot be read as this build's document
    /// is preserved — either moved aside, or refused outright — never overwritten.
    func read(from url: URL) throws -> SnapshotLoad {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SnapshotLoad(snapshot: StoreSnapshot())
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not read \(url.path): \(error.localizedDescription)"
            )
        }

        // An empty snapshot still encodes to a JSON object, so this writer can never produce a
        // zero-length file. Zero bytes means something truncated it — a power loss during the
        // rename, a sync client, a failed restore. Treating that as a fresh install would let the
        // next save write over whatever is still recoverable underneath.
        guard !data.isEmpty else {
            return SnapshotLoad(snapshot: StoreSnapshot(), quarantinedAs: try quarantine(url))
        }

        do {
            return SnapshotLoad(snapshot: try decoder.decode(StoreSnapshot.self, from: data))
        } catch let error as StoreError {
            // A file this build is not allowed to read — a newer schema — is intact, not corrupt.
            // Quarantining it would turn "update Lggr" into "your data moved".
            throw error
        } catch {
            // Well-formed JSON carrying a value this build cannot interpret is intact data too. The
            // usual cause is a downgrade: a session recorded with an enum case added by a later
            // version fails to decode, and that single unknown string would otherwise send every
            // project, session and accomplishment in the file to quarantine. Refuse it instead, and
            // leave the file exactly where the user left it.
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                throw StoreError.invalidData(
                    "The Lggr data file contains something this version does not understand. "
                        + "It has not been changed. Updating Lggr should open it."
                )
            }
            return SnapshotLoad(snapshot: StoreSnapshot(), quarantinedAs: try quarantine(url))
        }
    }

    /// `sequence` is assigned in mutation order by the caller. A write that arrives out of order is
    /// dropped rather than allowed to put an older document back on top of a newer one — the newer
    /// document already contains this one's changes, because every mutation starts from the current
    /// in-memory snapshot.
    func write(_ snapshot: StoreSnapshot, to url: URL, sequence: UInt64) throws {
        guard sequence > lastWrittenSequence else { return }

        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not encode the Lggr store: \(error.localizedDescription)"
            )
        }
        try AtomicFileWriter.write(data, to: url)
        lastWrittenSequence = sequence
    }

    /// Moves an unreadable file aside and returns the name it was preserved under, so the app can
    /// tell the user where their data went instead of silently opening empty.
    @discardableResult
    private func quarantine(_ url: URL) throws -> String {
        let directory = url.deletingLastPathComponent()
        let stamp = timestampFormatter.string(from: Date())

        var destination = directory.appendingPathComponent("store-corrupt-\(stamp).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "store-corrupt-\(stamp)-\(UUID().uuidString).json"
            )
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw StoreError.persistenceFailure(
                """
                The Lggr store at \(url.path) could not be read and could not be moved aside: \
                \(error.localizedDescription)
                """
            )
        }

        return destination.lastPathComponent
    }
}

/// The outcome of reading the store, so a caller can tell "no file yet" from "your file was moved
/// aside". Without the distinction an unreadable store looks exactly like a fresh install.
struct SnapshotLoad: Sendable {
    var snapshot: StoreSnapshot
    /// The filename the unreadable original was preserved under, when one was moved aside.
    var quarantinedAs: String?
}
