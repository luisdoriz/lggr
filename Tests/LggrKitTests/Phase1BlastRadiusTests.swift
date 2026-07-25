import Foundation
import Testing

@testable import LggrKit

/// "Can a single corrupt day file cost the user more than that day?"
///
/// `ActivityLogTests` already proves that a corrupt file is quarantined and that its neighbours
/// still load. This suite asks the follow-on question a running app raises: after the quarantine,
/// does the *directory* still work — can it be listed, can the damaged day be written to again, and
/// does anything else lose data?
@Suite("Phase 1 — the blast radius of one corrupt day")
@MainActor
struct Phase1BlastRadiusTests {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lggr-blast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func key(_ raw: String) throws -> ActivityDayKey {
        try #require(ActivityDayKey(rawValue: raw))
    }

    private func interval(from start: Date, seconds: TimeInterval) -> ActivityInterval {
        ActivityInterval(
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode",
            start: start,
            end: start.addingTimeInterval(seconds),
            monotonicDuration: seconds
        )
    }

    private let anchor = Date(timeIntervalSinceReferenceDate: 727_051_200)

    @Test("A corrupt day costs exactly that day: listing, neighbours and further writes all survive")
    func oneCorruptDayCostsOneDay() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = FileActivityLog(directoryURL: directory)
        for raw in ["2024-01-13", "2024-01-14", "2024-01-15", "2024-01-16"] {
            try await seed.append(
                intervals: [interval(from: anchor, seconds: 1800)], gaps: [], to: try key(raw))
        }
        try await seed.flush()

        // One file is destroyed on disk, the way a power loss mid-write would destroy it.
        try Data([0xFF, 0xFE, 0x00, 0x01, 0x02]).write(
            to: directory.appendingPathComponent("2024-01-15.json"))

        let log = FileActivityLog(directoryURL: directory)

        // Listing the directory still works, and still reports four days: the damaged one has not
        // yet been touched, so nothing has been renamed.
        #expect(try await log.availableDays().count == 4)

        // Reading the damaged day quarantines it and yields an empty day rather than throwing.
        #expect(try await log.load(try key("2024-01-15")).isEmpty)

        // Every other day is intact, to the byte.
        for raw in ["2024-01-13", "2024-01-14", "2024-01-16"] {
            let record = try await log.load(try key(raw))
            #expect(record.intervals.count == 1)
            #expect(record.intervals.first?.monotonicDuration == 1800)
        }

        // Listing still works afterwards, and the quarantined file is not mistaken for a day.
        let remaining = try await log.availableDays()
        #expect(remaining.count == 3)
        #expect(!remaining.contains(try key("2024-01-15")))

        // The damaged day can be written to again — today does not stop recording because this
        // morning's file was destroyed.
        try await log.append(
            intervals: [interval(from: anchor.addingTimeInterval(3600), seconds: 600)],
            gaps: [],
            to: try key("2024-01-15")
        )
        try await log.flush()
        #expect(try await log.load(try key("2024-01-15")).intervals.count == 1)

        // And the original bytes are still on disk under another name, so nothing was destroyed by
        // the recovery itself.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.filter { $0.contains("-corrupt-") }.count == 1)
    }

    @Test("A corrupt day does not stop the following days from being read")
    func aCorruptDayDoesNotBlockLaterDays() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let seed = FileActivityLog(directoryURL: directory)
        try await seed.append(
            intervals: [interval(from: anchor, seconds: 900)], gaps: [], to: try key("2024-02-01"))
        try await seed.flush()
        try Data("{not json".utf8).write(
            to: directory.appendingPathComponent("2024-02-02.json"))

        let log = FileActivityLog(directoryURL: directory)
        // Reading the newest day first — which is what the launch path does — must not prevent the
        // older one from loading afterwards.
        #expect(try await log.load(try key("2024-02-02")).isEmpty)
        #expect(try await log.load(try key("2024-02-01")).intervals.count == 1)
        #expect(log.quarantineNotice != nil)
    }
}
