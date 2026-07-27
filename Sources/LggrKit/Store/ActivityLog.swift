import Foundation

// MARK: - Day key

/// Which day a file of activity belongs to: a calendar label, not an instant.
///
/// Activity is stored one file per day, and a file needs a name. That name is this type, rendered as
/// `YYYY-MM-DD`, and the type carries nothing else — no calendar, no timezone, no clock.
///
/// The calendar stays outside on purpose. Which day 00:20 belongs to is a question about the user's
/// calendar and the timezone they were in at the time, and answering it inside a value that is also
/// used as a filename is how a day silently changes name after a flight. A caller with a calendar
/// answers it once, at capture, and the answer is then a label that never moves again.
///
/// Ordering is lexicographic on the rendered form, which for zero-padded fixed-width fields is the
/// same as chronological. That is what makes retention pruning — "delete everything before this
/// day" — a comparison of names rather than a date computation.
public struct ActivityDayKey: Hashable, Sendable, Comparable, CustomStringConvertible {

    public let year: Int
    public let month: Int
    public let day: Int

    /// Fails rather than clamps. A key built from nonsense would become a filename, and a filename is
    /// the only index this store has; silently correcting one would file a Tuesday under Monday.
    ///
    /// The ranges are the ranges a *label* can take, not the ranges a calendar would validate: this
    /// type does not know how long February was in any given year, and does not need to, because the
    /// caller derived the components from a real calendar in the first place.
    public init?(year: Int, month: Int, day: Int) {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on, according to the calendar the caller supplies.
    ///
    /// There is no default calendar. `Calendar.current` read from inside a domain type is a hidden
    /// global that changes under the app when the user changes a system setting, and every file this
    /// store has ever written would then be filed under a different name than it is looked up by.
    public init?(date: Date, in calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
            let month = components.month,
            let day = components.day
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DD`.
    public var rawValue: String {
        "\(Self.padded(year, width: 4))-\(Self.padded(month, width: 2))-\(Self.padded(day, width: 2))"
    }

    public var description: String { rawValue }

    /// The file this day is stored in, relative to the activity directory.
    public var fileName: String { "\(rawValue).json" }

    /// Parses `YYYY-MM-DD` and nothing else.
    ///
    /// Strict by design. The directory also holds files this store must never mistake for a day — a
    /// quarantined `2024-01-15-corrupt-….json`, the heartbeat — and a lenient parser is how a
    /// quarantined file gets loaded, re-quarantined, and eventually pruned as if it were the day it
    /// was rescued from.
    public init?(rawValue: String) {
        let characters = Array(rawValue)
        guard characters.count == 10, characters[4] == "-", characters[7] == "-" else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                guard let digit = characters[index].wholeNumberValue,
                    characters[index].isASCII,
                    (0...9).contains(digit)
                else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    /// Recovers the day from a file name, or `nil` for anything that is not a day file.
    public init?(fileName: String) {
        guard fileName.hasSuffix(".json") else { return nil }
        self.init(rawValue: String(fileName.dropLast(5)))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static func padded(_ value: Int, width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

extension ActivityDayKey: Codable {

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let key = ActivityDayKey(rawValue: raw) else {
            throw StoreError.invalidData("\"\(raw)\" is not a YYYY-MM-DD activity day.")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Day record

/// One day of ambient capture: what was in front of the user, and the absences the sampler observed.
///
/// This is a day file replayed into memory. It is deliberately not part of `StoreSnapshot`: that
/// document is rewritten whole on every save, and an interval per application switch would mean
/// hundreds of full-document rewrites a day and a year of intervals loaded on every read the app
/// makes. One file per day makes retention pruning and "delete all activity history" file deletions,
/// which are both faster and far easier to verify than row deletion.
///
/// This is a *view* of the file rather than its layout. Since schema 2 the file is JSON Lines — a
/// header line and one record per line — so that adding a record costs the bytes it adds instead of
/// the size of the day. See `ActivityDayFile`.
///
/// The gaps here are the ones the sampler **observed** — a sleep, a lock, a heartbeat that stopped —
/// not the ones `EpisodeBuilder` derives. Derived gaps are a conclusion and are recomputed from this
/// record every time a day is rebuilt; storing them would let a conclusion outlive the evidence it
/// was drawn from.
public struct ActivityDayRecord: Codable, Sendable, Equatable {

    /// Version of the on-disk layout this build writes.
    ///
    /// - Version 1: one pretty-printed JSON document per day, rewritten whole on every flush.
    /// - Version 2: JSON Lines. A header line, then one record per line, appended.
    ///
    /// Version 1 files are still read — the migration happens on the first flush that touches a day,
    /// not on upgrade, so a machine with a year of history pays nothing at launch.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var day: ActivityDayKey
    /// Ordered by `start`, then `end`, then `id`, so the file is stable and diffable.
    public var intervals: [ActivityInterval]
    /// Ordered the same way.
    public var gaps: [Gap]

    public init(
        schemaVersion: Int = ActivityDayRecord.currentSchemaVersion,
        day: ActivityDayKey,
        intervals: [ActivityInterval] = [],
        gaps: [Gap] = []
    ) {
        self.schemaVersion = schemaVersion
        self.day = day
        self.intervals = intervals.sorted(by: ActivityDayRecord.inOrder)
        self.gaps = gaps.sorted(by: ActivityDayRecord.inOrder)
    }

    public var isEmpty: Bool { intervals.isEmpty && gaps.isEmpty }

    /// Summed from the monotonic measurement, never from the wall clock.
    public var sampledDuration: TimeInterval {
        intervals.reduce(0) { $0 + $1.monotonicDuration }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case day
        case intervals
        case gaps
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)

        guard version >= 1 else {
            throw StoreError.invalidData("Activity schema version \(version) is not a valid version.")
        }
        // Refusing a newer file rather than decoding it is the same rule `StoreSnapshot` follows: a
        // build that quietly read it would drop every field it has no property for, and the next
        // flush would write that loss back over the user's day.
        guard version <= Self.currentSchemaVersion else {
            throw StoreError.invalidData(
                """
                Activity file schema version \(version) was written by a newer version of Lggr. \
                This build understands up to version \(Self.currentSchemaVersion).
                """
            )
        }

        self.schemaVersion = version
        self.day = try container.decode(ActivityDayKey.self, forKey: .day)
        self.intervals =
            try container.decodeIfPresent([ActivityInterval].self, forKey: .intervals) ?? []
        self.gaps = try container.decodeIfPresent([Gap].self, forKey: .gaps) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(day, forKey: .day)
        try container.encode(intervals, forKey: .intervals)
        try container.encode(gaps, forKey: .gaps)
    }

    // MARK: - Ordering

    static func inOrder(_ left: ActivityInterval, _ right: ActivityInterval) -> Bool {
        (left.start, left.end, left.id.uuidString) < (right.start, right.end, right.id.uuidString)
    }

    static func inOrder(_ left: Gap, _ right: Gap) -> Bool {
        (left.start, left.end, left.id.uuidString) < (right.start, right.end, right.id.uuidString)
    }
}

extension ActivityDayRecord {

    /// The on-disk format, defined once — and deliberately the same one `StoreSnapshot` uses.
    ///
    /// Dates are written as seconds since the reference date, not as ISO-8601 strings. ISO-8601
    /// truncates to whole seconds, which has already silently changed durations once in this
    /// project: every timestamp would lose its fractional part on the first flush-and-reload cycle,
    /// so a day loaded from disk would no longer equal the day that was written, and a run measured
    /// across a reload would be a different length than the run that was measured live.
    public static func makeEncoder() -> JSONEncoder { StoreSnapshot.makeEncoder() }

    public static func makeDecoder() -> JSONDecoder { StoreSnapshot.makeDecoder() }

    /// The encoder the JSON Lines format needs: identical to `makeEncoder()` except that indentation
    /// is off, because a record has to occupy exactly one line to be one record.
    ///
    /// Nothing is lost by dropping the indentation. `store.json` is pretty-printed so a human can
    /// read it; a day file is now more legible than it was, not less — one record per line is what
    /// `grep` and `tail` already expect, and an append-only file diffs as pure addition.
    static func makeLineEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

// MARK: - Protocol

/// Durable storage for ambient capture, one file per day.
///
/// Separate from `LggrStore` because the write pattern is the opposite of it. `LggrStore` holds a
/// few thousand small records a year and rewrites the whole document on every save; activity is
/// hundreds of intervals a day and must never provoke a write per application switch. So this
/// protocol is explicit about the distinction the other one does not need: `append` buffers, and
/// only `flush` is a promise that bytes reached the disk.
///
/// **Flushing is event-driven, not periodic.** Callers flush when the buffer has grown, when an
/// app-switch burst settles, and at every moment capture could stop — sleep, lock, resign-active,
/// terminate — never merely because a minute has passed. A minute is not an event, and a flush per
/// minute is 1,440 writes a day for a record nothing reads until the timeline is next drawn.
///
/// `durability` says which of those a flush is. The boundaries where capture is about to stop get a
/// device sync; everything else gets an ordinary buffered write, because the worst case there is
/// losing the last few seconds of which application was frontmost, and the timeline already renders
/// that honestly as an absence rather than as time attributed to the wrong application.
///
/// **A missing day is an empty day, not an error.** Most days in a retention window were never
/// recorded, and a store that threw for them would make "open a week" a week of error handling.
///
/// **Deletes are idempotent**, exactly as in `LggrStore`: deleting a day that is not there succeeds.
@MainActor
public protocol ActivityLog: AnyObject {

    /// Adds to a day, in memory. Does not necessarily touch the disk.
    ///
    /// Both collections are merged by `id`, so replaying the same batch cannot duplicate a day. A
    /// caller that has revised an interval — closing an open one at the last heartbeat, say — saves
    /// it back under the same `id` and it replaces its earlier self.
    func append(intervals: [ActivityInterval], gaps: [Gap], to day: ActivityDayKey) async throws

    /// Writes every day with unflushed changes. Returns once the bytes have been handed over, to
    /// the degree `durability` asks for.
    ///
    /// A day that fails to write stays dirty, and the other days are still attempted: one bad day
    /// must never cost the rest.
    func flush(durability: FileDurability) async throws

    /// Everything recorded for a day, including anything appended but not yet flushed. A day with no
    /// file is an empty record.
    func load(_ day: ActivityDayKey) async throws -> ActivityDayRecord

    /// Every day that has a file, oldest first. Files that are not day files are ignored.
    func availableDays() async throws -> [ActivityDayKey]

    /// Removes one day's file, and anything buffered for it.
    func delete(_ day: ActivityDayKey) async throws

    /// Removes every day file. Buffered changes are discarded rather than written afterwards.
    func deleteAll() async throws

    /// Retention. Removes every day strictly before `day` and returns what was removed, oldest
    /// first, so the caller can state what happened rather than assert it.
    @discardableResult
    func pruneDays(before day: ActivityDayKey) async throws -> [ActivityDayKey]

    /// Set when a day file could not be read whole — either it was preserved under another name, or
    /// some of its records were unreadable and the rest were kept. The app surfaces this; a damaged
    /// day must never be indistinguishable from a day nobody worked.
    var quarantineNotice: String? { get }
}

extension ActivityLog {

    /// The ordinary flush: buffered. Every call site that is not a boundary where capture stops
    /// wants this one, so it is the one that is easy to type.
    public func flush() async throws {
        try await flush(durability: .buffered)
    }
}

// MARK: - File-backed

/// The `ActivityLog` Lggr ships: one append-only JSON Lines file per day under `activity/`, buffered
/// in memory and flushed on events.
///
/// Buffering is half the point. A sampler that wrote on every application activation would produce
/// hundreds of writes a day for a record that nothing reads until the timeline is next drawn, so
/// appends cost a dictionary update and the disk is touched on events.
///
/// **Appending only what changed is the other half, and it is what this class was rebuilt for.** The
/// original wrote the whole day through `AtomicFileWriter` on every flush. By evening a day file is
/// around 145 KB, so appending a few hundred bytes cost a 145 KB rewrite plus a physical device
/// sync — and on the old sixty-second cadence that happened 1,440 times a day. That is the exact
/// shape of an entry in "Apps Using Significant Energy", and Phase 1 acceptance criterion 8 is a
/// gate. A flush now costs the bytes it adds.
///
/// The price of an append-only log is duplication: a record revised after it was written — the open
/// interval, republished with a later end on every flush — appears more than once, and the reader
/// keeps the highest-sequenced copy. That duplication is bounded, not unbounded. Every flush appends
/// at most the one open interval and the one open gap on top of whatever genuinely closed, and a
/// flush happens roughly once per transition, so a day file settles at about twice the size of its
/// distinct records. Trading a constant factor of file size for a linear factor of write cost is the
/// whole trade.
///
/// The cost of buffering is that an unflushed append is lost if the process dies. That is accepted
/// and bounded: the heartbeat file records that the app stopped, and the resulting hole reaches the
/// timeline as an honest `.appNotRunning` gap rather than as time attributed to the wrong
/// application.
///
/// Encoding and every disk touch happen on a private actor, so the main actor is free while a day is
/// written.
@MainActor
public final class FileActivityLog: ActivityLog {

    /// The directory holding `YYYY-MM-DD.json`.
    public let directoryURL: URL

    private let file: ActivityDayFile
    /// Days held in memory: the full record as it should be on disk, replayed from the file and kept
    /// current by every append. This is what `load` answers from; it is not what gets written.
    private var cache: [ActivityDayKey: ActivityDayRecord] = [:]
    /// What each dirty day still owes the file — the delta, keyed by `id` so that a record revised
    /// twice between flushes is appended once.
    private var unwritten: [ActivityDayKey: PendingDay] = [:]
    /// The next line sequence number for each day, seeded from the highest one already in the file
    /// so that a relaunch cannot append a revision that reads as older than what it revises.
    private var nextSequence: [ActivityDayKey: UInt64] = [:]
    /// Days whose file is still in the pre-JSON-Lines layout. The next flush that touches one
    /// rewrites it whole, once, and every flush after that is an append.
    private var needsMigration: Set<ActivityDayKey> = []

    /// One day's delta. A dictionary rather than an array because the sampler republishes the open
    /// interval on every flush under the same `id`, and only the latest version is worth a line.
    private struct PendingDay {
        var intervals: [UUID: ActivityInterval] = [:]
        var gaps: [UUID: Gap] = [:]
        var isEmpty: Bool { intervals.isEmpty && gaps.isEmpty }
    }

    public private(set) var quarantineNotice: String?

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.file = ActivityDayFile()
    }

    /// Uses `~/Library/Application Support/Lggr/activity/`.
    public convenience init() throws {
        self.init(directoryURL: try FileActivityLog.defaultDirectoryURL())
    }

    public static func defaultDirectoryURL() throws -> URL {
        do {
            let base = try LggrStoreLocation.baseDirectory()
            return base.appendingPathComponent("activity", isDirectory: true)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not locate the Application Support directory: \(error.localizedDescription)"
            )
        }
    }

    public func url(for day: ActivityDayKey) -> URL {
        directoryURL.appendingPathComponent(day.fileName, isDirectory: false)
    }

    // MARK: - Buffering

    /// Days appended to but not yet written. Exposed so a caller can decide whether a flush is worth
    /// making, and so a test can assert that appending did not write.
    public var pendingDays: [ActivityDayKey] { unwritten.keys.sorted() }

    public var hasPendingChanges: Bool { !unwritten.isEmpty }

    /// What this log has actually done to the disk. For tests and for measurement; nothing in the
    /// app reads it.
    public func statistics() async -> ActivityLogStatistics {
        await file.statistics()
    }

    public func append(
        intervals: [ActivityInterval],
        gaps: [Gap],
        to day: ActivityDayKey
    ) async throws {
        guard !intervals.isEmpty || !gaps.isEmpty else { return }

        var record = try await record(for: day)
        var pending = unwritten[day] ?? PendingDay()
        let changed = merge(intervals: intervals, gaps: gaps, into: &record, owing: &pending)
        guard changed else { return }

        cache[day] = record
        unwritten[day] = pending
    }

    public func flush(durability: FileDurability) async throws {
        var firstError: (any Error)?
        // Oldest first, so a partial flush leaves a prefix of the week on disk rather than a
        // scattering of days.
        for day in unwritten.keys.sorted() {
            do {
                try await flush(day, durability: durability)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Appends one day's delta, if it has one.
    ///
    /// Sequence numbers are assigned here, on the main actor, in mutation order — and then travel
    /// *in the lines themselves*. The old design assigned a sequence per write and had the writer
    /// drop anything that arrived out of order, which works when every write is the whole document
    /// and the newest one contains all the others. It does not work for deltas: dropping one would
    /// drop the only copy of its records. Carrying the sequence into the file instead makes the
    /// replay order-independent, so two flushes of the same day racing through the actor resolve
    /// correctly whichever one lands first.
    public func flush(_ day: ActivityDayKey, durability: FileDurability = .buffered) async throws {
        guard let pending = unwritten[day], !pending.isEmpty else { return }

        var sequence = nextSequence[day] ?? 1
        var lines: [ActivityDayLine] = []
        lines.reserveCapacity(pending.intervals.count + pending.gaps.count)

        // Timeline order within the batch, so a file read by eye still runs down the day.
        for interval in pending.intervals.values.sorted(by: ActivityDayRecord.inOrder) {
            lines.append(ActivityDayLine(seq: sequence, interval: interval))
            sequence &+= 1
        }
        for gap in pending.gaps.values.sorted(by: ActivityDayRecord.inOrder) {
            lines.append(ActivityDayLine(seq: sequence, gap: gap))
            sequence &+= 1
        }
        nextSequence[day] = sequence

        if needsMigration.contains(day), let record = cache[day] {
            // A day still in the version-1 layout. Appending lines after a pretty-printed document
            // would produce a file neither reader understands, so this one file is rewritten whole —
            // once, on the first flush that touches it, never again.
            try await file.rewrite(record, to: url(for: day))
            needsMigration.remove(day)
        } else {
            try await file.append(lines, for: day, to: url(for: day), durability: durability)
        }

        // Clear only what was written and has not been revised since. A record appended while the
        // write was in flight is the version the user is looking at, and it still owes the file a
        // line.
        var remaining = unwritten[day] ?? PendingDay()
        for (id, interval) in pending.intervals where remaining.intervals[id] == interval {
            remaining.intervals.removeValue(forKey: id)
        }
        for (id, gap) in pending.gaps where remaining.gaps[id] == gap {
            remaining.gaps.removeValue(forKey: id)
        }
        unwritten[day] = remaining.isEmpty ? nil : remaining
    }

    // MARK: - Reading

    public func load(_ day: ActivityDayKey) async throws -> ActivityDayRecord {
        try await record(for: day)
    }

    public func availableDays() async throws -> [ActivityDayKey] {
        try await file.days(in: directoryURL)
    }

    /// The cached record, reading the file exactly once per day.
    private func record(for day: ActivityDayKey) async throws -> ActivityDayRecord {
        if let cached = cache[day] { return cached }

        let load = try await file.read(day, from: url(for: day))

        // Re-check after the await. An append that landed while the read was in flight published a
        // newer record, and returning the disk value would hand back a day that predates it — after
        // which the next append would build on the stale value and erase what was appended.
        if let cached = cache[day] { return cached }

        if let quarantinedAs = load.quarantinedAs {
            quarantineNotice =
                "Lggr could not read its activity for \(day.rawValue), so that day is empty. "
                + "The original is still there, saved as \(quarantinedAs). Other days are unaffected."
        } else if load.unreadableRecords > 0 {
            // Records lost inside an otherwise readable day. The file is left exactly as it is, so
            // it stays recoverable by hand — but the day is now shorter than it was, and a shorter
            // day the user was not told about is a day they would read as time they did not work.
            let count = load.unreadableRecords
            quarantineNotice =
                "Lggr could not read \(count) record\(count == 1 ? "" : "s") in its activity for "
                + "\(day.rawValue), so that much of the day is missing. The file has not been "
                + "changed. Other days are unaffected."
        }
        cache[day] = load.record
        nextSequence[day] = load.highestSequence &+ 1
        if load.needsMigration { needsMigration.insert(day) }
        return load.record
    }

    // MARK: - Deleting

    public func delete(_ day: ActivityDayKey) async throws {
        forget(day)
        try await file.delete(url(for: day))
    }

    /// Drops everything this log remembers about a day, sequence numbers included. A day whose file
    /// is gone starts again at one; keeping a stale counter would only leave a hole in the numbering.
    private func forget(_ day: ActivityDayKey) {
        cache.removeValue(forKey: day)
        unwritten.removeValue(forKey: day)
        nextSequence.removeValue(forKey: day)
        needsMigration.remove(day)
    }

    /// Removes every day file, and every quarantined day alongside them — a quarantined file is
    /// still the user's activity, and "delete all activity history" that left one behind would be a
    /// promise the directory contradicts.
    ///
    /// The heartbeat is not activity history and is left alone. Deleting it would tell the next
    /// launch that the app had crashed, and manufacture an `.appNotRunning` gap out of a privacy
    /// action.
    public func deleteAll() async throws {
        cache.removeAll()
        unwritten.removeAll()
        nextSequence.removeAll()
        needsMigration.removeAll()
        quarantineNotice = nil
        try await file.deleteAllDays(in: directoryURL)
    }

    @discardableResult
    public func pruneDays(before day: ActivityDayKey) async throws -> [ActivityDayKey] {
        let expired = try await availableDays().filter { $0 < day }
        var removed: [ActivityDayKey] = []
        var firstError: (any Error)?

        for expiredDay in expired {
            do {
                try await delete(expiredDay)
                removed.append(expiredDay)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        // Anything buffered for an expired day would otherwise be flushed straight back after the
        // prune and resurrect a day the user asked to be rid of.
        for buffered in unwritten.keys.sorted() where buffered < day {
            forget(buffered)
        }

        if let firstError { throw firstError }
        return removed
    }

    // MARK: - Merging

    /// Folds a batch into a day, replacing anything with the same `id`, and records what the file is
    /// now owed.
    ///
    /// Returns whether the day actually changed, so a redundant append cannot mark a clean day dirty
    /// and provoke a write. That check is what keeps the sampler's republished open interval from
    /// costing a line on a flush where it did not move.
    private func merge(
        intervals: [ActivityInterval],
        gaps: [Gap],
        into record: inout ActivityDayRecord,
        owing pending: inout PendingDay
    ) -> Bool {
        var changed = false

        if !intervals.isEmpty {
            var merged = record.intervals
            for interval in intervals {
                if let index = merged.firstIndex(where: { $0.id == interval.id }) {
                    guard merged[index] != interval else { continue }
                    merged[index] = interval
                } else {
                    merged.append(interval)
                }
                pending.intervals[interval.id] = interval
                changed = true
            }
            if changed { record.intervals = merged.sorted(by: ActivityDayRecord.inOrder) }
        }

        var gapsChanged = false
        if !gaps.isEmpty {
            var merged = record.gaps
            for gap in gaps {
                if let index = merged.firstIndex(where: { $0.id == gap.id }) {
                    guard merged[index] != gap else { continue }
                    merged[index] = gap
                } else {
                    merged.append(gap)
                }
                pending.gaps[gap.id] = gap
                gapsChanged = true
            }
            if gapsChanged { record.gaps = merged.sorted(by: ActivityDayRecord.inOrder) }
        }

        return changed || gapsChanged
    }
}

// MARK: - Measurement

/// What a `FileActivityLog` has cost the disk, so the claim that a flush is O(added bytes) can be
/// asserted rather than believed.
public struct ActivityLogStatistics: Sendable, Equatable {

    /// Calls to the append path.
    public var appends: Int = 0
    /// Bytes added by them.
    public var bytesAppended: Int = 0
    /// `F_FULLFSYNC` calls. The number that shows up as energy on a laptop.
    public var deviceSyncs: Int = 0
    /// Whole-file rewrites. Expected to be zero in steady state, and one per day file that was
    /// migrated from the version-1 layout.
    public var rewrites: Int = 0
    public var bytesRewritten: Int = 0
    /// Day files read from disk, and their size. A day is read at most once per process.
    public var reads: Int = 0
    public var bytesRead: Int = 0

    public init() {}

    /// Everything the disk was asked to absorb, however it was asked.
    public var bytesWritten: Int { bytesAppended + bytesRewritten }
}

// MARK: - Disk

/// One line of a day file: a record, and the sequence number that says how recent it is.
///
/// The envelope has exactly one of `interval` and `gap` set, so a line names its own kind and a
/// reader never has to guess from shape. `seq` is what makes the log order-independent: the same
/// `id` may appear many times, and the copy with the highest sequence is the current one, wherever
/// in the file it happens to sit.
struct ActivityDayLine: Codable, Sendable {
    var seq: UInt64
    var interval: ActivityInterval?
    var gap: Gap?
}

/// The first line of a day file. Present so the file states its own layout rather than having it
/// inferred, which is what lets version 1 and version 2 live in the same directory.
private struct ActivityDayHeader: Codable {
    var schemaVersion: Int
    var day: ActivityDayKey
}

/// Owns the JSON coders and every disk touch, off the main actor.
private actor ActivityDayFile {

    private let encoder: JSONEncoder
    private let lineEncoder: JSONEncoder
    private let decoder: JSONDecoder
    private let timestampFormatter: DateFormatter
    private var stats = ActivityLogStatistics()

    private static let newline = UInt8(ascii: "\n")

    init() {
        self.encoder = ActivityDayRecord.makeEncoder()
        self.lineEncoder = ActivityDayRecord.makeLineEncoder()
        self.decoder = ActivityDayRecord.makeDecoder()

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmssSSS"
        self.timestampFormatter = formatter
    }

    func statistics() -> ActivityLogStatistics { stats }

    // MARK: - Reading

    /// A missing file is an empty day. Anything that cannot be read as this build's record is
    /// preserved — moved aside, or refused outright — never overwritten.
    func read(_ day: ActivityDayKey, from url: URL) throws -> ActivityDayLoad {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ActivityDayLoad(record: ActivityDayRecord(day: day))
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not read \(url.path): \(error.localizedDescription)"
            )
        }
        stats.reads += 1
        stats.bytesRead += data.count

        // Every file this writer can produce begins with at least a header line, so zero bytes means
        // something truncated it. Treating that as a day nobody worked would let the next flush
        // write over whatever is still recoverable.
        guard !data.isEmpty else {
            return ActivityDayLoad(
                record: ActivityDayRecord(day: day),
                quarantinedAs: try quarantine(url, day: day)
            )
        }

        let lines = data.split(separator: Self.newline, omittingEmptySubsequences: false)

        // The discriminator is the first line, and it is unambiguous in both directions: a version-1
        // document is pretty-printed, so its first line is a lone `{` that is not valid JSON, while
        // a version-2 header has no `intervals` key for a record line to be confused with.
        guard let first = lines.first,
            let header = try? decoder.decode(ActivityDayHeader.self, from: trimmed(first))
        else {
            return try readWholeDocument(day, data: data, from: url)
        }

        guard header.schemaVersion >= 1 else {
            throw StoreError.invalidData(
                "Activity schema version \(header.schemaVersion) is not a valid version."
            )
        }
        // Refusing a newer file rather than reading it is the same rule `StoreSnapshot` follows: a
        // build that quietly read it would drop every field it has no property for.
        guard header.schemaVersion <= ActivityDayRecord.currentSchemaVersion else {
            throw StoreError.invalidData(
                """
                Activity file schema version \(header.schemaVersion) was written by a newer version \
                of Lggr. This build understands up to version \
                \(ActivityDayRecord.currentSchemaVersion).
                """
            )
        }
        guard header.schemaVersion >= 2 else {
            return try readWholeDocument(day, data: data, from: url)
        }

        return try replay(lines, for: day)
    }

    /// Replays a JSON Lines day: last sequence wins per `id`.
    ///
    /// Three outcomes are deliberately distinct for a line that will not decode:
    ///
    /// - **Valid JSON this build cannot interpret** — a downgrade meeting an enum case a later
    ///   version added — refuses the whole day, per `DECISIONS.md` D5. The file is intact and
    ///   re-updating recovers it completely.
    /// - **The final line, not valid JSON** — an append interrupted by a power cut. Dropped in
    ///   silence, because that is the expected consequence of the append being unsynced, and it
    ///   costs one record whose successor the sampler will republish anyway.
    /// - **Any earlier line, not valid JSON** — real damage. Everything readable is kept and the
    ///   count is reported, because a day that is quietly shorter than it was reads as time the user
    ///   did not work.
    private func replay(
        _ lines: [Data.SubSequence],
        for day: ActivityDayKey
    ) throws -> ActivityDayLoad {
        var intervals: [UUID: (seq: UInt64, value: ActivityInterval)] = [:]
        var gaps: [UUID: (seq: UInt64, value: Gap)] = [:]
        var highestSequence: UInt64 = 0
        var unreadable = 0

        let lastIndex = lines.count - 1
        for index in stride(from: 1, through: lastIndex, by: 1) {
            let body = trimmed(lines[index])
            if body.isEmpty { continue }

            guard let line = try? decoder.decode(ActivityDayLine.self, from: body) else {
                if (try? JSONSerialization.jsonObject(with: body)) != nil {
                    throw StoreError.invalidData(
                        "The activity for \(day.rawValue) contains something this version does not "
                            + "understand. It has not been changed. Updating Lggr should open it."
                    )
                }
                if index != lastIndex { unreadable += 1 }
                continue
            }

            highestSequence = max(highestSequence, line.seq)

            if let interval = line.interval {
                if let existing = intervals[interval.id], existing.seq > line.seq { continue }
                intervals[interval.id] = (line.seq, interval)
            } else if let gap = line.gap {
                if let existing = gaps[gap.id], existing.seq > line.seq { continue }
                gaps[gap.id] = (line.seq, gap)
            } else {
                unreadable += 1
            }
        }

        return ActivityDayLoad(
            record: ActivityDayRecord(
                schemaVersion: 2,
                day: day,
                intervals: intervals.values.map(\.value),
                gaps: gaps.values.map(\.value)
            ),
            unreadableRecords: unreadable,
            highestSequence: highestSequence
        )
    }

    /// The version-1 layout: one JSON document for the whole day.
    private func readWholeDocument(
        _ day: ActivityDayKey,
        data: Data,
        from url: URL
    ) throws -> ActivityDayLoad {
        do {
            return ActivityDayLoad(
                record: try decoder.decode(ActivityDayRecord.self, from: data),
                needsMigration: true
            )
        } catch let error as StoreError {
            // A file this build is not allowed to read — a newer schema — is intact, not corrupt.
            // Quarantining it would turn "update Lggr" into "your day moved".
            throw error
        } catch {
            // Well-formed JSON carrying a value this build cannot interpret is intact data too; the
            // usual cause is a downgrade meeting an enum case a later version added. Refuse it and
            // leave the file exactly where the user left it.
            if (try? JSONSerialization.jsonObject(with: data)) != nil {
                throw StoreError.invalidData(
                    "The activity for \(day.rawValue) contains something this version does not "
                        + "understand. It has not been changed. Updating Lggr should open it."
                )
            }
            return ActivityDayLoad(
                record: ActivityDayRecord(day: day),
                quarantinedAs: try quarantine(url, day: day)
            )
        }
    }

    /// Drops leading and trailing ASCII whitespace, so a `\r\n` file and a hand-edited one both read.
    private func trimmed(_ slice: Data.SubSequence) -> Data {
        func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
        var start = slice.startIndex
        var end = slice.endIndex
        while start < end, isSpace(slice[start]) { start += 1 }
        while end > start, isSpace(slice[end - 1]) { end -= 1 }
        return Data(slice[start..<end])
    }

    // MARK: - Writing

    /// Adds lines to the end of a day, and nothing else. This is the whole write path in steady
    /// state, and it reads nothing: its cost is the bytes it appends.
    func append(
        _ lines: [ActivityDayLine],
        for day: ActivityDayKey,
        to url: URL,
        durability: FileDurability
    ) throws {
        guard !lines.isEmpty else { return }

        var payload = Data()
        // A zero-length file is one whose header write was itself interrupted; writing the records
        // after it would leave a file whose first line is not a header, which the reader would then
        // hand to the version-1 path and quarantine.
        if try repairTornTail(at: url) == 0 {
            payload.append(
                try encodeLine(ActivityDayHeader(schemaVersion: 2, day: day), describing: day)
            )
        }
        for line in lines {
            payload.append(try encodeLine(line, describing: day))
        }

        try AppendOnlyFileWriter.append(payload, to: url, durability: durability)

        stats.appends += 1
        stats.bytesAppended += payload.count
        if durability == .deviceSynced { stats.deviceSyncs += 1 }
    }

    /// Writes a whole day in the version-2 layout, replacing whatever was there.
    ///
    /// Reached only to migrate a version-1 file, once per file. It goes through `AtomicFileWriter`
    /// rather than the append path because replacing a file is exactly what that type is for, and a
    /// migration that was interrupted halfway would leave a day that is neither layout.
    func rewrite(_ record: ActivityDayRecord, to url: URL) throws {
        var payload = try encodeLine(
            ActivityDayHeader(schemaVersion: 2, day: record.day),
            describing: record.day
        )
        var sequence: UInt64 = 1
        for interval in record.intervals {
            payload.append(
                try encodeLine(ActivityDayLine(seq: sequence, interval: interval), describing: record.day)
            )
            sequence &+= 1
        }
        for gap in record.gaps {
            payload.append(
                try encodeLine(ActivityDayLine(seq: sequence, gap: gap), describing: record.day)
            )
            sequence &+= 1
        }

        try AtomicFileWriter.write(payload, to: url)

        stats.rewrites += 1
        stats.bytesRewritten += payload.count
        stats.deviceSyncs += 1
    }

    private func encodeLine(_ value: some Encodable, describing day: ActivityDayKey) throws -> Data {
        do {
            var data = try lineEncoder.encode(value)
            data.append(Self.newline)
            return data
        } catch {
            throw StoreError.persistenceFailure(
                "Could not encode the activity for \(day.rawValue): \(error.localizedDescription)"
            )
        }
    }

    /// Zero for a file that is not there, which is the same answer the caller needs.
    private func sizeOfFile(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// How far back a search for the last record boundary is willing to look. Comfortably longer than
    /// any single record, and a fixed cost, which is the point: the repair must not become a read of
    /// the day it exists to protect.
    private static let tailWindow = 64 * 1024

    /// Leaves the file ending at a record boundary and returns its size afterwards.
    ///
    /// Appends are unsynced, so a power cut can leave a partial final record. The reader already
    /// tolerates that — a torn *final* line is dropped in silence, because the sampler republishes
    /// the open interval on the next flush. What it cannot tolerate is that fragment becoming an
    /// *interior* line: the moment anything is appended after it, it stops being last, and from then
    /// on every read of that day reports a record as missing and tells the user their day is short.
    /// One power cut would mark the day damaged forever.
    ///
    /// So the fragment is dropped here, before it can become interior. Truncating a user's file needs
    /// a stronger justification than convenience, and it has one: what is discarded is provably
    /// uninterpretable — bytes after the final newline of a line-oriented log, which no reader of
    /// this format can ever parse — and it costs the one record the next flush republishes anyway.
    private func repairTornTail(at url: URL) throws -> Int {
        let size = sizeOfFile(at: url)
        guard size > 0 else { return 0 }

        let window = min(size, Self.tailWindow)
        guard let handle = try? FileHandle(forUpdating: url) else { return size }
        defer { try? handle.close() }

        guard let tail = try? readTail(of: handle, at: size - window, count: window),
            tail.last != Self.newline
        else { return size }

        // No boundary anywhere in the window means either a file with no newline at all — a header
        // write torn mid-line, so nothing in it is interpretable — or a single record longer than the
        // window, which this writer cannot produce. The first is truncated to nothing and starts
        // again from a header; the second is left alone, because guessing at a boundary inside real
        // data is worse than one record the reader reports as unreadable.
        guard let boundary = tail.lastIndex(of: Self.newline) else {
            guard window == size else { return size }
            try truncate(handle, to: 0, path: url.path)
            return 0
        }

        let keep = size - window + tail.distance(from: tail.startIndex, to: boundary) + 1
        try truncate(handle, to: keep, path: url.path)
        return keep
    }

    private func readTail(of handle: FileHandle, at offset: Int, count: Int) throws -> Data? {
        try handle.seek(toOffset: UInt64(offset))
        guard let tail = try handle.read(upToCount: count), !tail.isEmpty else { return nil }
        return tail
    }

    private func truncate(_ handle: FileHandle, to size: Int, path: String) throws {
        do {
            try handle.truncate(atOffset: UInt64(size))
        } catch {
            throw StoreError.persistenceFailure(
                "Could not trim the incomplete record at the end of \(path): "
                    + error.localizedDescription
            )
        }
    }

    /// Deleting a day that is not there succeeds: the caller's intent already holds.
    func delete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not delete \(url.path): \(error.localizedDescription)"
            )
        }
    }

    func days(in directory: URL) throws -> [ActivityDayKey] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not list \(directory.path): \(error.localizedDescription)"
            )
        }
        return names.compactMap(ActivityDayKey.init(fileName:)).sorted()
    }

    func deleteAllDays(in directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not list \(directory.path): \(error.localizedDescription)"
            )
        }

        var firstError: (any Error)?
        for name in names where ActivityDayKey(fileName: name) != nil || isQuarantined(name) {
            do {
                try FileManager.default.removeItem(
                    at: directory.appendingPathComponent(name, isDirectory: false)
                )
            } catch {
                if firstError == nil {
                    firstError = StoreError.persistenceFailure(
                        "Could not delete \(name): \(error.localizedDescription)"
                    )
                }
            }
        }
        if let firstError { throw firstError }
    }

    private func isQuarantined(_ name: String) -> Bool {
        name.hasSuffix(".json") && name.contains("-corrupt-")
    }

    /// Moves an unreadable day aside and returns the name it was preserved under.
    ///
    /// One day, and only that day. Every other file in the directory is untouched, which is the
    /// whole reason activity is stored per day rather than in one document: a single bad file costs
    /// a day, never the year.
    private func quarantine(_ url: URL, day: ActivityDayKey) throws -> String {
        let directory = url.deletingLastPathComponent()
        let stamp = timestampFormatter.string(from: Date())

        var destination = directory.appendingPathComponent("\(day.rawValue)-corrupt-\(stamp).json")
        if FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent(
                "\(day.rawValue)-corrupt-\(stamp)-\(UUID().uuidString).json"
            )
        }

        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw StoreError.persistenceFailure(
                """
                The activity for \(day.rawValue) could not be read and could not be moved aside: \
                \(error.localizedDescription)
                """
            )
        }
        return destination.lastPathComponent
    }
}

/// The outcome of reading one day, so a caller can tell "nothing recorded" from "your day was moved
/// aside". Without the distinction an unreadable day looks exactly like a day off.
private struct ActivityDayLoad: Sendable {
    var record: ActivityDayRecord
    /// Set when the file was moved aside whole.
    var quarantinedAs: String?
    /// Records inside an otherwise readable day that could not be read. The file is left alone.
    var unreadableRecords: Int = 0
    /// The largest sequence number in the file, so the next append cannot reuse one.
    var highestSequence: UInt64 = 0
    /// The file is still in the version-1 layout and the next flush has to rewrite it.
    var needsMigration: Bool = false
}

// MARK: - In-memory

/// One durable change to the activity log, recorded so a test can assert that appending buffered and
/// only flushing wrote.
public enum ActivityWrite: Hashable, Sendable {
    case dayFlushed(ActivityDayKey)
    case dayDeleted(ActivityDayKey)
    case allDeleted
}

/// The `ActivityLog` that unit tests and previews run against.
///
/// Held to the same contract as the file-backed log rather than to a convenient approximation: a
/// missing day is an empty record, appends buffer and only `flush` records a write, merging is by
/// `id`, deletes are idempotent, and pruning is exclusive of its own day. A fake that behaves
/// differently from the real backend — in either direction — green-lights code that breaks in
/// production, or forces call sites to handle errors production never raises.
@MainActor
public final class InMemoryActivityLog: ActivityLog {

    /// When set, every method throws this instead of doing its work. Nothing is mutated and nothing
    /// is recorded, so error paths can be driven without leaving the log dirty.
    public var failureToInject: StoreError?

    /// What has been flushed: the durable half.
    public private(set) var days: [ActivityDayKey: ActivityDayRecord] = [:]
    /// What has been appended but not flushed.
    public private(set) var buffered: [ActivityDayKey: ActivityDayRecord] = [:]
    /// Every durable change since the last `resetWrites()`, oldest first.
    public private(set) var writes: [ActivityWrite] = []

    public private(set) var quarantineNotice: String?

    public init(days: [ActivityDayKey: ActivityDayRecord] = [:]) {
        self.days = days
    }

    // MARK: - Write log

    public var writeCount: Int { writes.count }

    public func resetWrites() { writes.removeAll() }

    public var pendingDays: [ActivityDayKey] { buffered.keys.sorted() }

    public var hasPendingChanges: Bool { !buffered.isEmpty }

    /// Sets the notice the file-backed log would set after moving a day aside, so the surface that
    /// renders it can be driven without a corrupt file.
    public func simulateQuarantine(of day: ActivityDayKey, as fileName: String) {
        quarantineNotice =
            "Lggr could not read its activity for \(day.rawValue), so that day is empty. "
            + "The original is still there, saved as \(fileName). Other days are unaffected."
    }

    private func checkFailure() throws {
        if let failureToInject { throw failureToInject }
    }

    // MARK: - ActivityLog

    public func append(
        intervals: [ActivityInterval],
        gaps: [Gap],
        to day: ActivityDayKey
    ) async throws {
        try checkFailure()
        guard !intervals.isEmpty || !gaps.isEmpty else { return }

        var record = buffered[day] ?? days[day] ?? ActivityDayRecord(day: day)

        for interval in intervals {
            if let index = record.intervals.firstIndex(where: { $0.id == interval.id }) {
                record.intervals[index] = interval
            } else {
                record.intervals.append(interval)
            }
        }
        for gap in gaps {
            if let index = record.gaps.firstIndex(where: { $0.id == gap.id }) {
                record.gaps[index] = gap
            } else {
                record.gaps.append(gap)
            }
        }
        record.intervals.sort(by: ActivityDayRecord.inOrder)
        record.gaps.sort(by: ActivityDayRecord.inOrder)

        guard record != days[day] else {
            buffered.removeValue(forKey: day)
            return
        }
        buffered[day] = record
    }

    /// Durability is not modelled: there is no disk here for a power cut to catch out. The parameter
    /// is accepted so the fake has the same shape as the real backend, per the note above.
    public func flush(durability: FileDurability) async throws {
        try checkFailure()
        for day in buffered.keys.sorted() {
            guard let record = buffered[day] else { continue }
            days[day] = record
            buffered.removeValue(forKey: day)
            writes.append(.dayFlushed(day))
        }
    }

    public func load(_ day: ActivityDayKey) async throws -> ActivityDayRecord {
        try checkFailure()
        return buffered[day] ?? days[day] ?? ActivityDayRecord(day: day)
    }

    public func availableDays() async throws -> [ActivityDayKey] {
        try checkFailure()
        return days.keys.sorted()
    }

    public func delete(_ day: ActivityDayKey) async throws {
        try checkFailure()
        days.removeValue(forKey: day)
        buffered.removeValue(forKey: day)
        writes.append(.dayDeleted(day))
    }

    public func deleteAll() async throws {
        try checkFailure()
        days.removeAll()
        buffered.removeAll()
        quarantineNotice = nil
        writes.append(.allDeleted)
    }

    @discardableResult
    public func pruneDays(before day: ActivityDayKey) async throws -> [ActivityDayKey] {
        try checkFailure()
        let expired = days.keys.filter { $0 < day }.sorted()
        for expiredDay in expired {
            days.removeValue(forKey: expiredDay)
            writes.append(.dayDeleted(expiredDay))
        }
        for pending in buffered.keys where pending < day {
            buffered.removeValue(forKey: pending)
        }
        return expired
    }
}
