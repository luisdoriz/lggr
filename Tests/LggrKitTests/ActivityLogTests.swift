import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes. The explicit `Double` is load-bearing: `#expect`
/// compares an `Optional<Double>` against an integer-literal expression by type as well as by value,
/// and reports a failure even when the numbers match.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// The instant every timestamp below is measured from. Fixed so a failure reproduces identically on
/// any machine, in any timezone, on any day of the year.
///
/// Which calendar day it falls on is deliberately not relied upon: the day keys in these tests are
/// labels chosen by the test, and the one test that does care about a calendar builds its instant
/// from components rather than from an offset against this.
private let anchor = Date(timeIntervalSinceReferenceDate: 727_051_200)

private func at(_ hour: Int, _ minute: Int, second: Double = 0) -> Date {
    anchor.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60) + second)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActivityLogTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func key(_ raw: String) throws -> ActivityDayKey {
    try #require(ActivityDayKey(rawValue: raw))
}

/// One interval, written the way the sampler would have recorded it: both clocks agreeing, because
/// nothing stepped the wall clock.
private func interval(
    _ bundleIdentifier: String,
    from start: Date,
    seconds: TimeInterval,
    id: UUID = UUID()
) -> ActivityInterval {
    ActivityInterval(
        id: id,
        bundleIdentifier: bundleIdentifier,
        displayName: bundleIdentifier == "com.apple.dt.Xcode" ? "Xcode" : "Terminal",
        start: start,
        end: start.addingTimeInterval(seconds),
        monotonicDuration: seconds,
        tzOffsetMinutes: 0
    )
}

private func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func bytes(of url: URL) throws -> Data {
    try Data(contentsOf: url)
}

/// The file split the way the reader splits it: a header line, then one record per line.
private func lines(of url: URL) throws -> [String] {
    let text = String(decoding: try bytes(of: url), as: UTF8.self)
    return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}

// MARK: - Day key

@Suite("Activity day key")
struct ActivityDayKeyTests {

    @Test("A day renders as a zero-padded YYYY-MM-DD file name")
    func rendersFixedWidth() throws {
        let day = try #require(ActivityDayKey(year: 2024, month: 1, day: 5))
        #expect(day.rawValue == "2024-01-05")
        #expect(day.fileName == "2024-01-05.json")
        #expect(day.description == "2024-01-05")
    }

    @Test("A rendered day parses back to the same day")
    func roundTripsThroughItsOwnName() throws {
        let day = try #require(ActivityDayKey(year: 2026, month: 12, day: 31))
        #expect(ActivityDayKey(rawValue: day.rawValue) == day)
        #expect(ActivityDayKey(fileName: day.fileName) == day)
    }

    /// The activity directory also holds files that must never be mistaken for a day: a quarantined
    /// copy, the heartbeat, a stray temporary file. A lenient parser is how a quarantined day gets
    /// loaded, re-quarantined and eventually pruned as if it were the day it was rescued from.
    @Test(
        "Anything that is not exactly a day file is refused",
        arguments: [
            "2024-1-5.json",
            "2024-01-15-corrupt-20240115-101010101.json",
            "heartbeat",
            "2024-01-15",
            "2024-01-15.json.tmp",
            ".2024-01-15.json.tmp",
            "store.json",
            "0000-01-15.json",
            "2024-13-01.json",
            "2024-01-32.json",
            "20a4-01-15.json",
            "2024-01-1٥.json",
        ]
    )
    func refusesAnythingElse(name: String) {
        #expect(ActivityDayKey(fileName: name) == nil)
    }

    @Test("Days sort chronologically")
    func sortsChronologically() throws {
        let days = [
            try key("2024-02-01"), try key("2023-12-31"), try key("2024-01-15"),
            try key("2024-01-05"),
        ]
        #expect(days.sorted().map(\.rawValue) == ["2023-12-31", "2024-01-05", "2024-01-15", "2024-02-01"])
    }

    @Test("A day survives a JSON round trip as its own name")
    func codesAsAString() throws {
        let day = try key("2024-01-15")
        let data = try ActivityDayRecord.makeEncoder().encode([day])
        #expect(String(decoding: data, as: UTF8.self).contains("2024-01-15"))
        #expect(try ActivityDayRecord.makeDecoder().decode([ActivityDayKey].self, from: data) == [day])
    }

    @Test("Decoding a day that is not a day fails rather than inventing one")
    func refusesAnUndecodableDay() {
        let data = Data(#"["not-a-day"]"#.utf8)
        #expect(throws: (any Error).self) {
            try ActivityDayRecord.makeDecoder().decode([ActivityDayKey].self, from: data)
        }
    }

    @Test("A day built from a date uses the calendar it was given, not a global one")
    func usesTheSuppliedCalendar() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        var madrid = Calendar(identifier: .gregorian)
        madrid.timeZone = try #require(TimeZone(identifier: "Europe/Madrid"))
        var mexico = Calendar(identifier: .gregorian)
        mexico.timeZone = try #require(TimeZone(identifier: "America/Mexico_City"))

        // 2024-01-16 00:30 UTC: already the 16th in Madrid, still the 15th in Mexico City. The same
        // instant, two different days — which is exactly why this type refuses to pick a calendar
        // for the caller.
        let instant = try #require(
            utc.date(from: DateComponents(year: 2024, month: 1, day: 16, hour: 0, minute: 30))
        )
        #expect(ActivityDayKey(date: instant, in: madrid)?.rawValue == "2024-01-16")
        #expect(ActivityDayKey(date: instant, in: mexico)?.rawValue == "2024-01-15")
    }
}

// MARK: - File-backed log

/// The activity log is the second place in Lggr where a bug costs the user data rather than a
/// redraw, so these tests run against a real file system: real writes, a real missing day, a real
/// corrupt day, and a real stand-in for a relaunch — a second log opened over the same directory.
@Suite("Activity log")
@MainActor
struct ActivityLogTests {

    // MARK: - Buffering

    @Test("Appending buffers; nothing reaches the disk until a flush")
    func appendDoesNotWrite() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        for step in 0..<50 {
            try await log.append(
                intervals: [
                    interval("com.apple.dt.Xcode", from: at(9, step), seconds: minutes(1))
                ],
                gaps: [],
                to: day
            )
        }

        #expect(log.hasPendingChanges)
        #expect(log.pendingDays == [day])
        #expect(try names(in: directory).isEmpty)

        try await log.flush()

        #expect(!log.hasPendingChanges)
        #expect(try names(in: directory) == ["2024-01-15.json"])
    }

    @Test("A flushed day is there after a relaunch")
    func survivesAReopen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")

        let writing = FileActivityLog(directoryURL: directory)
        try await writing.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(41))],
            gaps: [Gap(reason: .systemSleep, start: at(12, 0), end: at(13, 0))],
            to: day
        )
        try await writing.flush()

        let reading = FileActivityLog(directoryURL: directory)
        let record = try await reading.load(day)

        #expect(record.day == day)
        #expect(record.intervals.count == 1)
        #expect(record.gaps.count == 1)
        #expect(record.gaps.first?.reason == .systemSleep)
        #expect(record.sampledDuration == minutes(41))
        #expect(try await reading.availableDays() == [day])
    }

    /// The trap this project has already fallen into once: ISO-8601 truncates to whole seconds, so
    /// every timestamp would lose its fractional part on the first flush-and-reload cycle and a run
    /// measured across a reload would be a different length than the run measured live.
    @Test("Fractional seconds survive the round trip")
    func keepsFractionalSeconds() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")

        let start = at(9, 0, second: 0.375)
        let sampled = interval("com.apple.dt.Xcode", from: start, seconds: 41.125)

        let writing = FileActivityLog(directoryURL: directory)
        try await writing.append(intervals: [sampled], gaps: [], to: day)
        try await writing.flush()

        let reloaded = try await FileActivityLog(directoryURL: directory).load(day)
        #expect(reloaded.intervals == [sampled])
        #expect(reloaded.intervals.first?.start == start)
        #expect(reloaded.intervals.first?.monotonicDuration == 41.125)
    }

    @Test("Appending the same interval twice does not duplicate it")
    func mergesByIdentifier() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        let identifier = UUID()
        let open = interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(4), id: identifier)
        try await log.append(intervals: [open], gaps: [], to: day)
        try await log.append(intervals: [open], gaps: [], to: day)

        // The sampler revises an open interval when it closes it at the last heartbeat, under the
        // same identifier. The revision replaces its earlier self rather than joining it.
        let closed = interval(
            "com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(12), id: identifier
        )
        try await log.append(intervals: [closed], gaps: [], to: day)
        try await log.flush()

        let record = try await FileActivityLog(directoryURL: directory).load(day)
        #expect(record.intervals.count == 1)
        #expect(record.intervals.first?.monotonicDuration == minutes(12))
    }

    @Test("An append that changes nothing does not mark the day for writing")
    func redundantAppendStaysClean() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        let sampled = interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(4))
        try await log.append(intervals: [sampled], gaps: [], to: day)
        try await log.flush()
        #expect(!log.hasPendingChanges)

        try await log.append(intervals: [sampled], gaps: [], to: day)
        try await log.append(intervals: [], gaps: [], to: day)
        #expect(!log.hasPendingChanges)
    }

    @Test("Intervals and gaps come back in timeline order however they were appended")
    func keepsTheFileOrdered() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        try await log.append(
            intervals: [
                interval("com.apple.Terminal", from: at(14, 0), seconds: minutes(5)),
                interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(5)),
                interval("com.apple.Terminal", from: at(11, 0), seconds: minutes(5)),
            ],
            gaps: [
                Gap(reason: .screenLocked, start: at(13, 0), end: at(13, 30)),
                Gap(reason: .idle, start: at(10, 0), end: at(10, 30)),
            ],
            to: day
        )
        try await log.flush()

        let record = try await log.load(day)
        #expect(record.intervals.map(\.start) == [at(9, 0), at(11, 0), at(14, 0)])
        #expect(record.gaps.map(\.reason) == [.idle, .screenLocked])
    }

    @Test("A day appended to but not flushed still reads back in full")
    func readsThroughTheBuffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        try await log.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(4))],
            gaps: [],
            to: day
        )

        #expect(try await log.load(day).intervals.count == 1)
        #expect(try names(in: directory).isEmpty)
    }

    // MARK: - Missing days

    @Test("A day with no file is an empty day, not an error")
    func missingDayIsEmpty() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        let record = try await log.load(day)
        #expect(record.isEmpty)
        #expect(record.day == day)
        #expect(log.quarantineNotice == nil)
        #expect(try await log.availableDays().isEmpty)
    }

    @Test("A directory that does not exist yet lists no days rather than failing")
    func missingDirectoryIsEmpty() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(
            directoryURL: directory.appendingPathComponent("activity", isDirectory: true)
        )
        #expect(try await log.availableDays().isEmpty)
        try await log.deleteAll()
        #expect(try await log.pruneDays(before: try key("2024-01-15")).isEmpty)
    }

    // MARK: - Corruption

    /// The property the whole per-day layout exists for: one unreadable file costs one day. The
    /// other three hundred and sixty-four are untouched, which is not true of any single-document
    /// store.
    @Test("A corrupt day is quarantined and every other day survives")
    func oneBadDayCostsOneDay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = FileActivityLog(directoryURL: directory)

        for raw in ["2024-01-14", "2024-01-16"] {
            let day = try key(raw)
            try await good.append(
                intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
                gaps: [],
                to: day
            )
        }
        try await good.flush()

        try Data([0xFF, 0xFE, 0x00, 0x01]).write(
            to: directory.appendingPathComponent("2024-01-15.json")
        )

        let log = FileActivityLog(directoryURL: directory)
        let broken = try await log.load(try key("2024-01-15"))

        #expect(broken.isEmpty)
        let notice = try #require(log.quarantineNotice)
        #expect(notice.contains("2024-01-15"))
        #expect(notice.contains("Other days are unaffected"))

        // The other days still load, and the original is still on disk under another name.
        #expect(try await log.load(try key("2024-01-14")).intervals.count == 1)
        #expect(try await log.load(try key("2024-01-16")).intervals.count == 1)
        let quarantined = try names(in: directory).filter { $0.contains("-corrupt-") }
        #expect(quarantined.count == 1)
        #expect(quarantined.first?.hasPrefix("2024-01-15-corrupt-") == true)
    }

    @Test("A truncated, zero-length day is quarantined rather than treated as a day off")
    func zeroLengthIsQuarantined() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("2024-01-15.json"))

        let log = FileActivityLog(directoryURL: directory)
        #expect(try await log.load(try key("2024-01-15")).isEmpty)
        #expect(log.quarantineNotice != nil)
        #expect(try names(in: directory).contains { $0.contains("-corrupt-") })
    }

    /// Well-formed JSON this build cannot interpret is intact data. Moving it aside would turn "a
    /// later version wrote this" into "your day disappeared".
    @Test("A day written by a newer Lggr is refused, not moved")
    func refusesANewerSchema() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2024-01-15.json")
        try Data(#"{"schemaVersion":99,"day":"2024-01-15","intervals":[],"gaps":[]}"#.utf8)
            .write(to: url)

        let log = FileActivityLog(directoryURL: directory)
        await #expect(throws: StoreError.self) { try await log.load(try key("2024-01-15")) }
        #expect(log.quarantineNotice == nil)
        #expect(try names(in: directory) == ["2024-01-15.json"])
    }

    @Test("A day whose JSON is well formed but wrong is refused, not moved")
    func refusesUndecodableJSON() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("2024-01-15.json")
        try Data(#"{"schemaVersion":1,"day":"2024-01-15","intervals":"gone","gaps":[]}"#.utf8)
            .write(to: url)

        let log = FileActivityLog(directoryURL: directory)
        await #expect(throws: StoreError.self) { try await log.load(try key("2024-01-15")) }
        #expect(try names(in: directory) == ["2024-01-15.json"])
    }

    // MARK: - Deleting

    @Test("Deleting a day removes its file and leaves the rest alone")
    func deletesOneDay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)

        for raw in ["2024-01-14", "2024-01-15"] {
            try await log.append(
                intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
                gaps: [],
                to: try key(raw)
            )
        }
        try await log.flush()
        try await log.delete(try key("2024-01-15"))

        #expect(try names(in: directory) == ["2024-01-14.json"])
        #expect(try await log.load(try key("2024-01-15")).isEmpty)
    }

    @Test("Deleting a day that is not there succeeds")
    func deleteIsIdempotent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        try await log.delete(try key("2024-01-15"))
        try await log.delete(try key("2024-01-15"))
        #expect(try names(in: directory).isEmpty)
    }

    @Test("Deleting a day discards what was buffered for it")
    func deleteDropsTheBuffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        try await log.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
            gaps: [],
            to: day
        )
        try await log.delete(day)
        try await log.flush()

        #expect(try names(in: directory).isEmpty)
        #expect(try await log.load(day).isEmpty)
    }

    /// "Delete all activity history" has to be true of the directory afterwards, quarantined copies
    /// included — a rescued day is still the user's activity. The heartbeat is not history and is
    /// left alone: deleting it would tell the next launch the app had crashed and manufacture an
    /// `.appNotRunning` gap out of a privacy action.
    @Test("Deleting everything removes every day and every quarantined day, and nothing else")
    func deletesEverything() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)

        for raw in ["2024-01-14", "2024-01-15", "2024-01-16"] {
            try await log.append(
                intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
                gaps: [],
                to: try key(raw)
            )
        }
        try await log.flush()
        try Data("x".utf8).write(
            to: directory.appendingPathComponent("2024-01-13-corrupt-20240113-000000000.json")
        )
        try Data("739000000".utf8).write(to: directory.appendingPathComponent("heartbeat"))

        try await log.deleteAll()

        #expect(try names(in: directory) == ["heartbeat"])
        #expect(try await log.availableDays().isEmpty)
        #expect(log.quarantineNotice == nil)
    }

    @Test("Deleting everything discards the buffer rather than writing it back")
    func deleteAllDropsTheBuffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)

        try await log.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
            gaps: [],
            to: try key("2024-01-15")
        )
        try await log.deleteAll()
        try await log.flush()

        #expect(try names(in: directory).isEmpty)
    }

    // MARK: - Retention

    @Test("Pruning removes every day before the cut and keeps the cut itself")
    func prunesByDate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)

        let all = ["2023-12-31", "2024-01-14", "2024-01-15", "2024-01-16"]
        for raw in all {
            try await log.append(
                intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
                gaps: [],
                to: try key(raw)
            )
        }
        try await log.flush()

        let removed = try await log.pruneDays(before: try key("2024-01-15"))

        #expect(removed.map(\.rawValue) == ["2023-12-31", "2024-01-14"])
        #expect(try await log.availableDays().map(\.rawValue) == ["2024-01-15", "2024-01-16"])
        #expect(try names(in: directory) == ["2024-01-15.json", "2024-01-16.json"])
    }

    @Test("Pruning also drops buffered days, so an expired day cannot be flushed back")
    func prunesTheBuffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)

        try await log.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
            gaps: [],
            to: try key("2024-01-01")
        )
        #expect(log.hasPendingChanges)

        try await log.pruneDays(before: try key("2024-01-15"))
        try await log.flush()

        #expect(try names(in: directory).isEmpty)
        #expect(try await log.availableDays().isEmpty)
    }

    @Test("Listing days ignores anything that is not a day file")
    func listsOnlyDays() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)

        try await log.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
            gaps: [],
            to: try key("2024-01-15")
        )
        try await log.flush()
        try Data("739000000".utf8).write(to: directory.appendingPathComponent("heartbeat"))
        try Data("x".utf8).write(
            to: directory.appendingPathComponent("2024-01-14-corrupt-20240114-000000000.json")
        )
        try Data("x".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        #expect(try await log.availableDays().map(\.rawValue) == ["2024-01-15"])
    }

    // MARK: - Concurrency

    /// Every flush is ordered behind the last by a sequence number, because actor jobs are not
    /// guaranteed to run in the order they were enqueued. Without it an older version of a day could
    /// land on disk after a newer one and silently shorten the morning.
    @Test("Repeated flushes accumulate rather than replace")
    func repeatedFlushesAccumulate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        for step in 0..<40 {
            try await log.append(
                intervals: [
                    interval("com.apple.dt.Xcode", from: at(9, step), seconds: minutes(1))
                ],
                gaps: [],
                to: day
            )
            try await log.flush()
        }

        let reloaded = try await FileActivityLog(directoryURL: directory).load(day)
        #expect(reloaded.intervals.count == 40)
        #expect(reloaded.sampledDuration == minutes(40))
    }
}

// MARK: - Append-only layout

/// The reason the day file is JSON Lines rather than one document, asserted rather than asserted-in-
/// prose.
///
/// The old design rewrote the whole day on every flush and forced a device sync each time. By evening
/// a day file is around 145 KB, so appending a few hundred bytes cost a 145 KB rewrite plus a
/// physical sync — 1,440 times a day on the old sixty-second cadence. These tests pin the three
/// properties that replaced it: an append costs the bytes it adds, a torn final record costs that
/// record, and a sync happens only where it is worth its energy.
@Suite("Activity log: append-only day files")
@MainActor
struct ActivityLogAppendTests {

    // MARK: - Layout

    @Test("A day file is a header line and one line per record")
    func writesOneRecordPerLine() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        try await log.append(
            intervals: [
                interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(5)),
                interval("com.apple.Terminal", from: at(9, 5), seconds: minutes(5)),
            ],
            gaps: [Gap(reason: .idle, start: at(10, 0), end: at(10, 30))],
            to: day
        )
        try await log.flush()

        let written = try lines(of: log.url(for: day))
        #expect(written.count == 4)

        // The header states the layout rather than leaving it to be inferred, which is what lets a
        // version-1 file and a version-2 file sit in the same directory.
        let header = try #require(written.first)
        #expect(header.contains("\"schemaVersion\":2"))
        #expect(header.contains("\"day\":\"2024-01-15\""))

        #expect(written.dropFirst().allSatisfy { $0.contains("\"seq\":") })
        #expect(written.filter { $0.contains("\"interval\":") }.count == 2)
        #expect(written.filter { $0.contains("\"gap\":") }.count == 1)
    }

    /// The append-only trade, stated: a record revised after it was written appears twice in the file,
    /// and the copy with the higher sequence number is the one that survives — across a relaunch too,
    /// where the sequence counter has to be recovered from the file rather than remembered.
    @Test("A revised record wins over its earlier self, in the file and after a relaunch")
    func laterSequenceWins() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")
        let identifier = UUID()

        let writing = FileActivityLog(directoryURL: directory)
        try await writing.append(
            intervals: [
                interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(4), id: identifier)
            ],
            gaps: [],
            to: day
        )
        try await writing.flush()

        let reopened = FileActivityLog(directoryURL: directory)
        try await reopened.append(
            intervals: [
                interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(31), id: identifier)
            ],
            gaps: [],
            to: day
        )
        try await reopened.flush()

        // Both versions are still in the file — that is what append-only means.
        #expect(try lines(of: reopened.url(for: day)).count == 3)

        let reloaded = try await FileActivityLog(directoryURL: directory).load(day)
        #expect(reloaded.intervals.count == 1)
        #expect(reloaded.intervals.first?.monotonicDuration == minutes(31))
    }

    // MARK: - Cost

    /// The claim the rewrite exists to make: a flush is O(added bytes), not O(day). Five thousand
    /// intervals is a heavier day than any real one, and appending to it must not read or rewrite a
    /// byte of them.
    @Test("Appending to a day of five thousand intervals neither reads nor rewrites them")
    func appendIsProportionalToWhatItAdds() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        let existing = (0..<5_000).map {
            interval("com.apple.dt.Xcode", from: at(0, 0, second: Double($0) * 5), seconds: 4)
        }
        try await log.append(intervals: existing, gaps: [], to: day)
        try await log.flush()

        let sizeBefore = try bytes(of: log.url(for: day)).count
        let before = await log.statistics()

        try await log.append(
            intervals: [interval("com.apple.Terminal", from: at(18, 0), seconds: minutes(7))],
            gaps: [],
            to: day
        )
        try await log.flush()

        let after = await log.statistics()
        let sizeAfter = try bytes(of: log.url(for: day)).count

        #expect(after.reads == before.reads)
        #expect(after.rewrites == before.rewrites)
        #expect(after.bytesRewritten == before.bytesRewritten)
        #expect(after.deviceSyncs == before.deviceSyncs)

        // The whole cost of the flush is the record it added, and the file grew by exactly that.
        let added = after.bytesAppended - before.bytesAppended
        #expect(added == sizeAfter - sizeBefore)
        #expect(added < 400)
        // The old design would have paid the whole day for this. Around 1.2 MB against 260 bytes.
        #expect(added * 1_000 < sizeBefore)
    }

    /// The same statement without a magic number in it: the cost of a record does not depend on how
    /// much is already in the file. The only legitimate difference between the two is the width of the
    /// sequence number.
    @Test("A record costs the same on a heavy day as on an empty one")
    func costDoesNotGrowWithTheDay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let light = try key("2024-01-14")
        let heavy = try key("2024-01-15")

        func costOfOneMoreRecord(on day: ActivityDayKey) async throws -> Int {
            let before = await log.statistics()
            try await log.append(
                intervals: [interval("com.apple.Terminal", from: at(18, 0), seconds: minutes(7))],
                gaps: [],
                to: day
            )
            try await log.flush()
            return await log.statistics().bytesAppended - before.bytesAppended
        }

        try await log.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(5))],
            gaps: [],
            to: light
        )
        try await log.append(
            intervals: (0..<5_000).map {
                interval("com.apple.dt.Xcode", from: at(0, 0, second: Double($0) * 5), seconds: 4)
            },
            gaps: [],
            to: heavy
        )
        try await log.flush()

        #expect(try bytes(of: log.url(for: heavy)).count > 20 * (try bytes(of: log.url(for: light)).count))

        let onLight = try await costOfOneMoreRecord(on: light)
        let onHeavy = try await costOfOneMoreRecord(on: heavy)
        // Four extra digits of sequence number, and nothing else.
        #expect(abs(onHeavy - onLight) <= 4)
    }

    /// The measurement Phase 1 acceptance criterion 8 is about, run as a test so it cannot quietly
    /// regress.
    ///
    /// Eight hours with a transition every forty-five seconds — 640 intervals — flushed once per
    /// transition, which is the worst cadence the event-driven scheme can produce. Measured on this
    /// machine: 155 KB appended across 640 writes and no device sync at all, against 48 MB rewritten
    /// and 640 syncs for the same day under whole-file rewrites — and 1,440 syncs a day under the
    /// minute cadence that used to drive them.
    @Test("A simulated eight-hour day costs its own size to write, once")
    func measuresASimulatedDay() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")
        let url = log.url(for: day)

        // What the same day would have cost when every flush rewrote the whole file.
        var rewriteCost = 0

        for step in 0..<640 {
            try await log.append(
                intervals: [
                    interval(
                        step.isMultiple(of: 2) ? "com.apple.dt.Xcode" : "com.apple.Terminal",
                        from: at(9, 0, second: Double(step) * 45),
                        seconds: 44
                    )
                ],
                gaps: [],
                to: day
            )
            try await log.flush()
            rewriteCost += try bytes(of: url).count
        }

        let stats = await log.statistics()
        let size = try bytes(of: url).count

        #expect(stats.appends == 640)
        #expect(stats.rewrites == 0)
        // Nothing here is worth an energy-visible physical sync. The boundaries that are ask for one
        // explicitly; see `boundaryFlushSyncsAndOrdinaryOneDoesNot`.
        #expect(stats.deviceSyncs == 0)
        // The day cost exactly its own size to write, delivered in pieces.
        #expect(stats.bytesWritten == size)
        // And two orders of magnitude less than rewriting it 640 times.
        #expect(stats.bytesWritten * 100 < rewriteCost)

        let reloaded = try await FileActivityLog(directoryURL: directory).load(day)
        #expect(reloaded.intervals.count == 640)
    }

    // MARK: - Durability

    /// `F_FULLFSYNC` is tens of milliseconds and real energy, so it is spent where losing the record
    /// would cost more than the last few seconds of which application was frontmost.
    @Test("A boundary flush syncs the device and an ordinary one does not")
    func boundaryFlushSyncsAndOrdinaryOneDoesNot() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = FileActivityLog(directoryURL: directory)
        let day = try key("2024-01-15")

        for step in 0..<20 {
            try await log.append(
                intervals: [
                    interval("com.apple.dt.Xcode", from: at(9, step), seconds: minutes(1))
                ],
                gaps: [],
                to: day
            )
            try await log.flush()
        }
        #expect(await log.statistics().deviceSyncs == 0)

        // Sleep, lock, terminate: after this there may be no second chance to write.
        try await log.append(
            intervals: [interval("com.apple.Terminal", from: at(18, 0), seconds: minutes(2))],
            gaps: [],
            to: day
        )
        try await log.flush(durability: .deviceSynced)
        #expect(await log.statistics().deviceSyncs == 1)

        // A buffered append is still visible to the next process — the bytes went to the kernel, not
        // to a queue inside this one. Only a power cut in the seconds afterwards can lose them.
        #expect(try await FileActivityLog(directoryURL: directory).load(day).intervals.count == 21)
    }

    /// `store.json` is the user's own record of their sessions, with no server copy. Nothing in the
    /// activity rework is allowed to reach it: it keeps the whole-file, device-synced path.
    @Test("The session store keeps its atomic, device-synced write")
    func sessionStoreDurabilityIsUntouched() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        try AtomicFileWriter.write(Data("first".utf8), to: url)
        try AtomicFileWriter.write(Data("second".utf8), to: url)

        // Replaced whole, not appended to — the property `LggrStore` depends on.
        #expect(try bytes(of: url) == Data("second".utf8))
        #expect(try names(in: directory) == ["store.json"])
    }

    // MARK: - A torn append

    /// An unsynced append can be interrupted by a power cut, which leaves a partial record at the end
    /// of the file. That is the accepted price of not syncing, and the price has to be one record.
    @Test("A torn final record costs that record and nothing else")
    func tornFinalRecordCostsOneRecord() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")

        let writing = FileActivityLog(directoryURL: directory)
        for step in 0..<10 {
            try await writing.append(
                intervals: [
                    interval("com.apple.dt.Xcode", from: at(9, step), seconds: minutes(1))
                ],
                gaps: [],
                to: day
            )
        }
        try await writing.flush()

        // A write that stopped in the middle of a record: no closing brace, no newline.
        let url = writing.url(for: day)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":99,"interval":{"bundleIdentifier":"com.app"#.utf8))
        try handle.close()

        let log = FileActivityLog(directoryURL: directory)
        let record = try await log.load(day)

        #expect(record.intervals.count == 10)
        #expect(record.sampledDuration == minutes(10))
        // Not a notice. Losing the last unsynced record is the expected consequence of not syncing,
        // and the sampler republishes the open interval on its next flush; telling the user their day
        // is damaged would be alarming and wrong.
        #expect(log.quarantineNotice == nil)
    }

    /// The failure mode the repair exists for. Without it, one power cut marks a day damaged forever:
    /// the fragment stops being the final line the instant anything is appended after it, and every
    /// later read reports a record as missing.
    @Test("A torn record does not become permanent damage once the day continues")
    func tornRecordIsNotPermanent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")

        let writing = FileActivityLog(directoryURL: directory)
        try await writing.append(
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(5))],
            gaps: [],
            to: day
        )
        try await writing.flush()

        let url = writing.url(for: day)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"seq":99,"interval":{"bundleId"#.utf8))
        try handle.close()

        // The next launch reads the day, loses the fragment, and carries on recording into it.
        let resumed = FileActivityLog(directoryURL: directory)
        #expect(try await resumed.load(day).intervals.count == 1)
        try await resumed.append(
            intervals: [interval("com.apple.Terminal", from: at(14, 0), seconds: minutes(9))],
            gaps: [],
            to: day
        )
        try await resumed.flush()

        let reloaded = FileActivityLog(directoryURL: directory)
        let record = try await reloaded.load(day)
        #expect(record.intervals.count == 2)
        #expect(record.sampledDuration == minutes(14))
        #expect(reloaded.quarantineNotice == nil)
        // The fragment was dropped rather than buried: every line in the file is a whole record.
        #expect(try lines(of: url).count == 3)
    }

    /// Damage that is not a torn tail is a different thing and is reported. A day that is quietly
    /// shorter than it was reads as time the user did not work.
    @Test("A damaged record in the middle is reported and the rest of the day is kept")
    func interiorDamageIsReported() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")

        let writing = FileActivityLog(directoryURL: directory)
        for step in 0..<5 {
            try await writing.append(
                intervals: [
                    interval("com.apple.dt.Xcode", from: at(9, step), seconds: minutes(1))
                ],
                gaps: [],
                to: day
            )
            try await writing.flush()
        }

        let url = writing.url(for: day)
        var written = try lines(of: url)
        written[3] = "\u{FFFD}\u{FFFD} not a record at all"
        try Data(written.joined(separator: "\n").appending("\n").utf8).write(to: url)

        let log = FileActivityLog(directoryURL: directory)
        let record = try await log.load(day)

        #expect(record.intervals.count == 4)
        let notice = try #require(log.quarantineNotice)
        #expect(notice.contains("1 record"))
        #expect(notice.contains("2024-01-15"))
        #expect(notice.contains("has not been changed"))
        // Reported, not moved: the file stays exactly where the user left it, still recoverable.
        #expect(try names(in: directory) == ["2024-01-15.json"])
    }

    // MARK: - Migration

    /// A machine with a year of history pays nothing at launch: a version-1 file is read as it is, and
    /// rewritten once by the first flush that touches its day. Every flush after that is an append.
    @Test("A version-one day is read, rewritten once, and appended to afterwards")
    func migratesOnFirstFlush() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let day = try key("2024-01-15")
        let url = directory.appendingPathComponent(day.fileName)

        let original = ActivityDayRecord(
            schemaVersion: 1,
            day: day,
            intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(25))],
            gaps: [Gap(reason: .systemSleep, start: at(13, 0), end: at(13, 30))]
        )
        try ActivityDayRecord.makeEncoder().encode(original).write(to: url)

        let log = FileActivityLog(directoryURL: directory)
        let asRead = try await log.load(day)
        #expect(asRead.intervals == original.intervals)
        #expect(asRead.gaps == original.gaps)
        #expect(log.quarantineNotice == nil)
        #expect(await log.statistics().rewrites == 0)

        try await log.append(
            intervals: [interval("com.apple.Terminal", from: at(15, 0), seconds: minutes(11))],
            gaps: [],
            to: day
        )
        try await log.flush()

        // Once, because appending lines after a pretty-printed document would leave a file neither
        // reader understands.
        #expect(await log.statistics().rewrites == 1)
        #expect(try lines(of: url).first?.contains("\"schemaVersion\":2") == true)

        try await log.append(
            intervals: [interval("com.apple.Terminal", from: at(16, 0), seconds: minutes(3))],
            gaps: [],
            to: day
        )
        try await log.flush()
        #expect(await log.statistics().rewrites == 1)

        let reloaded = try await FileActivityLog(directoryURL: directory).load(day)
        #expect(reloaded.intervals.count == 3)
        #expect(reloaded.gaps == original.gaps)
        #expect(reloaded.sampledDuration == minutes(39))
    }
}

// MARK: - In-memory fake

/// The fake is held to the file-backed log's contract rather than to a convenient approximation. A
/// fake that behaves differently in either direction green-lights code that breaks in production, or
/// forces call sites to handle errors production never raises.
@Suite("In-memory activity log")
@MainActor
struct InMemoryActivityLogTests {

    @Test("A missing day is an empty day, not an error")
    func missingDayIsEmpty() async throws {
        let log = InMemoryActivityLog()
        let day = try key("2024-01-15")
        let record = try await log.load(day)
        #expect(record.isEmpty)
        #expect(record.day == day)
    }

    @Test("Appending buffers and records no write; flushing records exactly one")
    func appendBuffersAndFlushWrites() async throws {
        let log = InMemoryActivityLog()
        let day = try key("2024-01-15")

        for step in 0..<25 {
            try await log.append(
                intervals: [
                    interval("com.apple.dt.Xcode", from: at(9, step), seconds: minutes(1))
                ],
                gaps: [],
                to: day
            )
        }

        #expect(log.writeCount == 0)
        #expect(log.hasPendingChanges)
        #expect(try await log.load(day).intervals.count == 25)

        try await log.flush()

        #expect(log.writes == [.dayFlushed(day)])
        #expect(!log.hasPendingChanges)
        #expect(log.days[day]?.intervals.count == 25)
    }

    @Test("Appending merges by identifier, exactly as the file-backed log does")
    func mergesByIdentifier() async throws {
        let log = InMemoryActivityLog()
        let day = try key("2024-01-15")
        let identifier = UUID()

        try await log.append(
            intervals: [
                interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(4), id: identifier)
            ],
            gaps: [],
            to: day
        )
        try await log.append(
            intervals: [
                interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(12), id: identifier)
            ],
            gaps: [],
            to: day
        )
        try await log.flush()

        #expect(log.days[day]?.intervals.count == 1)
        #expect(log.days[day]?.intervals.first?.monotonicDuration == minutes(12))
    }

    @Test("Deleting is idempotent and pruning keeps the cut day")
    func deletesAndPrunes() async throws {
        let log = InMemoryActivityLog()
        for raw in ["2023-12-31", "2024-01-14", "2024-01-15"] {
            try await log.append(
                intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(30))],
                gaps: [],
                to: try key(raw)
            )
        }
        try await log.flush()
        log.resetWrites()

        try await log.delete(try key("2024-01-14"))
        try await log.delete(try key("2024-01-14"))
        #expect(try await log.availableDays().map(\.rawValue) == ["2023-12-31", "2024-01-15"])

        let removed = try await log.pruneDays(before: try key("2024-01-15"))
        #expect(removed.map(\.rawValue) == ["2023-12-31"])
        #expect(try await log.availableDays().map(\.rawValue) == ["2024-01-15"])

        try await log.deleteAll()
        #expect(try await log.availableDays().isEmpty)
        #expect(log.writes.last == .allDeleted)
    }

    @Test("An injected failure leaves the log untouched")
    func injectedFailure() async throws {
        let log = InMemoryActivityLog()
        let day = try key("2024-01-15")
        log.failureToInject = .persistenceFailure("disk full")

        await #expect(throws: StoreError.persistenceFailure("disk full")) {
            try await log.append(
                intervals: [interval("com.apple.dt.Xcode", from: at(9, 0), seconds: minutes(4))],
                gaps: [],
                to: day
            )
        }

        log.failureToInject = nil
        #expect(try await log.load(day).isEmpty)
        #expect(log.writeCount == 0)
    }
}
