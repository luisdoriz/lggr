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

    /// Bumped every time a document is taken from disk, and carried by every write.
    ///
    /// This is what makes the external-change refusal airtight rather than nearly airtight. When a
    /// write is refused the store reloads, which re-arms the writer's identity check against the new
    /// file — so a *second* save that was already in flight, built on the document from before the
    /// reload, would sail through the identity check and put the stale document on disk after all.
    /// The generation travels with the document, so the writer can reject anything descended from a
    /// document it has already refused.
    private var documentGeneration: UInt64 = 0

    /// Set when the file on disk could not be read and was preserved under another name. The app
    /// surfaces this; an unreadable store must never be indistinguishable from a first launch.
    public private(set) var quarantineNotice: String?

    /// Set when `store.json` was changed by something other than this instance, so a save was refused
    /// rather than allowed to overwrite it.
    ///
    /// Sibling to `quarantineNotice` and there for the same reason: the app has to be able to tell the
    /// user, because the alternative is two copies of Lggr quietly diverging and one of them winning.
    public private(set) var externalChangeNotice: String?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.file = SnapshotFile()
    }

    /// Uses `~/Library/Application Support/Lggr/store.json`.
    public convenience init() throws {
        self.init(fileURL: try JSONFileStore.defaultFileURL())
    }

    public static func defaultFileURL() throws -> URL {
        try LggrStoreLocation.baseDirectory()
            .appendingPathComponent("store.json", isDirectory: false)
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
        documentGeneration &+= 1
    }

    /// The message the app shows when a save was refused because the file had changed.
    private func message(for change: StoreFileChange) -> String {
        let name = fileURL.lastPathComponent
        var lines = [
            """
            \(name) was changed by something other than this copy of Lggr — another instance, or a \
            backup being restored — so this change was not saved. Lggr expected \(change.expected) \
            and found \(change.found). The file on disk has been left exactly as it is, and Lggr has \
            reloaded it.
            """
        ]
        if let preservedAs = change.preservedAs {
            lines.append(
                "What Lggr had not yet written was saved alongside it as \(preservedAs), so nothing "
                    + "has been thrown away."
            )
        }
        if let preserveFailure = change.preserveFailure {
            lines.append(
                "The unsaved change could not be written alongside it either: \(preserveFailure)"
            )
        }
        return lines.joined(separator: " ")
    }

    /// Handles a write the writer refused because the file no longer matched what was loaded.
    ///
    /// Three things happen, in this order, and none of them may destroy a record:
    ///
    /// 1. Nothing is written. The file on disk is left byte-for-byte as whatever changed it left it.
    /// 2. The document that was not written has already been preserved beside the store by the
    ///    writer, so the records this instance holds are not lost either.
    /// 3. The in-memory document is dropped and re-read, so this instance stops being stale.
    ///
    /// **Why not simply take the disk copy, or simply keep memory?** Taking the disk copy silently
    /// discards records this instance already told the user were saved. Keeping memory is the defect
    /// itself: it discards whatever the other writer put there, which is why a restored backup gets
    /// quietly undone. Merging the two is worse than either — with whole-document saves there is no
    /// way to tell "this record was deleted over there" from "this record is not there yet", so a
    /// union would resurrect rows the user deleted and a per-collection pick would silently choose one
    /// user's edit over another's. The only resolution that cannot destroy a record the user believes
    /// is saved is to keep *both* copies, write neither over the other, and say so. The mutation then
    /// fails loudly, which is the same contract as D6: a change that did not reach the disk must not
    /// stay visible as though it had.
    private func resolve(_ change: StoreFileChange) async -> StoreError {
        let notice = message(for: change)
        externalChangeNotice = notice

        // Not a rollback to the previous document: that one is stale too. Both are older than what is
        // on disk now, so the only honest thing to hold is the file.
        snapshot = nil
        loadTask = nil
        // Best effort. If the reload fails the store stays empty-handed and the next read tries
        // again — which is right, because guessing would put us back where we started.
        _ = try? await loaded()

        return StoreError.persistenceFailure(notice)
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

        // Read here, not next to the write. The generation has to be the one the document being
        // written actually descends from, and `loaded()` is the only thing that bumps it — so it must
        // be sampled in the same await-free stretch that takes `previous`. Sampling it after the
        // backup's `await` would let a refusal-and-reload that completed during that suspension stamp
        // this stale document with the post-reload generation, which is precisely the check it is
        // here to fail.
        let generation = documentGeneration

        var updated = previous
        body(&updated)
        updated.schemaVersion = StoreSnapshot.currentSchemaVersion
        snapshot = updated

        // Once per launch, before anything of this instance's is written over the file the user
        // arrived with. Cheap, and the only thing standing between a bad write and a lost week.
        await file.captureLaunchBackup(besides: fileURL)

        writeSequence &+= 1
        let sequence = writeSequence
        let outcome: SnapshotWriteOutcome
        do {
            outcome = try await file.write(
                updated,
                to: fileURL,
                sequence: sequence,
                generation: generation
            )
        } catch {
            if snapshot == updated { snapshot = previous }
            throw error
        }

        if case .refused(let change) = outcome {
            throw await resolve(change)
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

    /// The identity of the file the document in memory came from. Everything that touches the file
    /// goes through this actor, so this is the one place the answer can be kept honestly.
    private var fileGuard = StoreFileGuard()

    /// No document older than this generation may be written. Raised when a write is refused, so every
    /// save already in flight from the same stale document is refused too rather than sneaking in
    /// behind the reload.
    private var minimumGeneration: UInt64 = 0

    /// Whether this launch has already copied the document the user arrived with.
    private var hasCapturedLaunchBackup = false

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
            fileGuard.adopt(.absent)
            return SnapshotLoad(snapshot: StoreSnapshot())
        }

        // Stat *before* reading, not after. If the file changes between the two, the recorded identity
        // then describes an older file than the bytes we are holding, and the next write is refused —
        // which is the safe direction. Statting afterwards would record the newer file's identity
        // against the older file's contents, and the next write would happily overwrite the change.
        fileGuard.adoptIdentity(of: url)

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
    ///
    /// `generation` identifies which read the document descends from, and the write is refused if the
    /// file no longer matches what that read saw. This is the core of the fix: a store that writes its
    /// snapshot back unconditionally erases every change made by anything else — a second instance, a
    /// restored backup — and does it silently.
    func write(
        _ snapshot: StoreSnapshot,
        to url: URL,
        sequence: UInt64,
        generation: UInt64
    ) throws -> SnapshotWriteOutcome {
        guard sequence > lastWrittenSequence else { return .supersededByNewerWrite }

        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not encode the Lggr store: \(error.localizedDescription)"
            )
        }

        let found = StoreFileIdentity.read(url)
        let expected = fileGuard.expectedIdentity ?? .absent

        // A document from before a refusal, arriving after the reload that followed it. It looks
        // current to the identity check and is not.
        guard generation >= minimumGeneration else {
            return .refused(preserve(data, besides: url, expected: expected, found: found))
        }

        if case .changed = fileGuard.verify(against: found) {
            // Refuse everything descended from this document, not just this write.
            minimumGeneration = generation &+ 1
            return .refused(preserve(data, besides: url, expected: expected, found: found))
        }

        try AtomicFileWriter.write(data, to: url)
        fileGuard.adoptIdentity(of: url)
        lastWrittenSequence = sequence
        return .written
    }

    /// Copies the document the user arrived with, once per launch, before this instance writes over it.
    ///
    /// Best effort by design: a folder that will not take a backup is not a reason to refuse to record
    /// the session the user just finished. It reads the file rather than the in-memory document, so the
    /// backup is a copy of what was actually there, and reading does not disturb the file's identity.
    func captureLaunchBackup(besides url: URL) {
        guard !hasCapturedLaunchBackup else { return }
        hasCapturedLaunchBackup = true
        _ = try? StoreBackups.capture(storeAt: url)
    }

    /// Writes a refused document beside the store so the records it holds are not lost.
    ///
    /// Never overwrites, never throws: the caller's job is to refuse the write, and a preservation
    /// failure must not turn into a second failure that loses the disk copy too. What happened is
    /// reported back so the user can be told the whole truth.
    private func preserve(
        _ data: Data,
        besides url: URL,
        expected: StoreFileIdentity,
        found: StoreFileIdentity
    ) -> StoreFileChange {
        let directory = url.deletingLastPathComponent()
        let stamp = timestampFormatter.string(from: Date())

        var destination = directory.appendingPathComponent("store-unwritten-\(stamp).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "store-unwritten-\(stamp)-\(UUID().uuidString).json"
            )
        }

        do {
            try AtomicFileWriter.write(data, to: destination)
            return StoreFileChange(
                expected: expected,
                found: found,
                preservedAs: destination.lastPathComponent
            )
        } catch {
            return StoreFileChange(
                expected: expected,
                found: found,
                preserveFailure: error.localizedDescription
            )
        }
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
            // The document is gone from `url`, so the next write is a first write and must be allowed
            // to create it. Leaving the moved file's identity recorded would refuse every save.
            fileGuard.adopt(.absent)
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

/// What the writer did, so the store can tell "saved" from "not saved, and here is why".
///
/// A refusal is deliberately not an error thrown from the writer: it carries what was found and where
/// the unwritten document went, and the store has to reload before it reports anything.
enum SnapshotWriteOutcome: Sendable {
    case written
    /// Dropped because a newer document has already been written. Its changes are in that newer
    /// document, so there is nothing to report.
    case supersededByNewerWrite
    /// Not written, because the file on disk is no longer the one this document came from.
    case refused(StoreFileChange)
}

/// The outcome of reading the store, so a caller can tell "no file yet" from "your file was moved
/// aside". Without the distinction an unreadable store looks exactly like a fresh install.
struct SnapshotLoad: Sendable {
    var snapshot: StoreSnapshot
    /// The filename the unreadable original was preserved under, when one was moved aside.
    var quarantinedAs: String?
}
