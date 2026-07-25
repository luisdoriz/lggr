import Foundation
import Testing

@testable import LggrKit

/// Phase 1 acceptance criterion 6, from `docs/_design/INTELLIGENCE.md` §4:
///
/// > A synthetic day with a DST transition and a timezone change produces no negative durations and
/// > no overlapping blocks.
///
/// The two events are different failures and are built separately here before being combined.
///
/// - A **DST transition** moves the wall clock without moving time. On the spring-forward night
///   02:00 becomes 03:00, so an interval that ran for thirty minutes across it has a wall-clock span
///   of ninety; in autumn 02:00 happens twice and a thirty-minute interval has a wall-clock span of
///   minus thirty. `Date` is an absolute instant and does not itself jump — the jump appears when a
///   sampler that reads local wall-clock components writes them down, which is the case this
///   fixture reproduces by writing the intervals the way a naive sampler would have.
/// - A **timezone change** is a flight: the same instants arrive with a different `tzOffsetMinutes`,
///   and a builder that mixed the two would render a 23-minute stretch as `1:52–1:15`.
///
/// Both are asserted the same way, over the whole rebuilt timeline: nothing has a negative
/// duration, and no two blocks overlap each other or a gap.
@Suite("Phase 1 acceptance — criterion 6: DST and a timezone change")
struct Phase1DaylightSavingTests {

    // MARK: - Anchors

    /// 2024-03-10 in New York: 02:00 local becomes 03:00 local. The instant below is 00:00 EST.
    private static let springForwardMidnight = Date(timeIntervalSince1970: 1_709_960_400)
    /// 2024-11-03 in New York: 01:00 EDT recurs as 01:00 EST. The instant below is 00:00 EDT.
    private static let fallBackMidnight = Date(timeIntervalSince1970: 1_730_606_400)

    private func minutes(_ count: Double) -> TimeInterval { count * 60 }

    /// One interval, written the way the sampler writes it: wall clock for placement, a monotonic
    /// measurement for length, and the UTC offset that was in force while it ran.
    private func interval(
        _ bundle: String,
        start: Date,
        seconds: TimeInterval,
        offsetMinutes: Int,
        wallClockEnd: Date? = nil
    ) -> ActivityInterval {
        ActivityInterval(
            bundleIdentifier: bundle,
            displayName: bundle,
            start: start,
            end: wallClockEnd ?? start.addingTimeInterval(seconds),
            monotonicDuration: seconds,
            tzOffsetMinutes: offsetMinutes
        )
    }

    /// Every well-formedness property criterion 6 names, checked over a whole rebuilt day.
    private func expectWellFormed(_ timeline: DayTimeline, _ what: String) {
        let note = Comment(rawValue: what)

        for episode in timeline.episodes {
            #expect(episode.end >= episode.start, note)
            #expect(episode.wallClockSpan >= 0, note)
            #expect(episode.activeDuration >= 0, note)
            #expect(episode.apps.allSatisfy { $0.duration >= 0 }, note)
        }
        for gap in timeline.gaps {
            #expect(gap.end >= gap.start, note)
            #expect(gap.duration >= 0, note)
        }
        #expect(timeline.trackedDuration >= 0, note)

        // No two blocks overlap, and no block overlaps a gap.
        let episodes = timeline.episodes.sorted { $0.start < $1.start }
        for (left, right) in zip(episodes, episodes.dropFirst()) {
            #expect(right.start >= left.end, note)
        }
        for episode in episodes {
            for gap in timeline.gaps {
                let overlaps = episode.start < gap.end && gap.start < episode.end
                #expect(!overlaps, Comment(rawValue: "\(what): block overlaps \(gap.reason)"))
            }
        }
        let gaps = timeline.gaps.sorted { $0.start < $1.start }
        for (left, right) in zip(gaps, gaps.dropFirst()) {
            #expect(right.start >= left.end, note)
        }
    }

    // MARK: - Cases

    @Test("Spring forward: the hour that does not exist produces no negative durations")
    func springForward() {
        let midnight = Self.springForwardMidnight
        let est = -300  // UTC-5
        let edt = -240  // UTC-4

        // 01:00–01:30 EST, then the interval that straddles the jump: it ran for thirty minutes of
        // real time, and its local end reads 03:00 rather than 02:30.
        let intervals = [
            interval("com.apple.dt.Xcode", start: midnight.addingTimeInterval(3600),
                seconds: minutes(30), offsetMinutes: est),
            interval(
                "com.apple.Terminal",
                start: midnight.addingTimeInterval(5400),
                seconds: minutes(30),
                offsetMinutes: est,
                // 01:30 EST + 30 real minutes = 03:00 EDT, which is the same instant as 02:00 EST.
                wallClockEnd: midnight.addingTimeInterval(7200)
            ),
            interval("com.apple.dt.Xcode", start: midnight.addingTimeInterval(7200),
                seconds: minutes(60), offsetMinutes: edt),
        ]

        let timeline = EpisodeBuilder.build(intervals: intervals)
        expectWellFormed(timeline, "spring forward")
        #expect(timeline.trackedDuration == minutes(120))
    }

    @Test("Fall back: the hour that happens twice produces no negative durations")
    func fallBack() {
        let midnight = Self.fallBackMidnight
        let edt = -240
        let est = -300

        // A naive sampler reading local components would write 01:50 → 01:20 here. `Date` is
        // absolute, so what actually reaches the builder is a forward instant with the earlier
        // offset — and the offset is the only thing that changed.
        let intervals = [
            interval("com.apple.dt.Xcode", start: midnight.addingTimeInterval(3000),
                seconds: minutes(20), offsetMinutes: edt),
            interval("com.apple.Terminal", start: midnight.addingTimeInterval(4200),
                seconds: minutes(30), offsetMinutes: edt),
            // The repeated hour, now on standard time.
            interval("com.apple.dt.Xcode", start: midnight.addingTimeInterval(6000),
                seconds: minutes(25), offsetMinutes: est),
            interval("com.apple.Terminal", start: midnight.addingTimeInterval(7500),
                seconds: minutes(40), offsetMinutes: est),
        ]

        let timeline = EpisodeBuilder.build(intervals: intervals)
        expectWellFormed(timeline, "fall back")
        #expect(timeline.trackedDuration == minutes(115))
    }

    /// An interval whose wall clock says it ran backwards. `ActivityInterval` clamps `end` to
    /// `start` at construction, so this can never reach the builder as a negative span — and the
    /// builder must not turn the clamped zero-length interval into an overlapping block either.
    @Test("An interval whose wall clock ran backwards is clamped, not negated")
    func backwardsWallClockIsClamped() {
        let midnight = Self.fallBackMidnight
        let backwards = ActivityInterval(
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode",
            start: midnight.addingTimeInterval(6600),
            end: midnight.addingTimeInterval(4800),
            monotonicDuration: minutes(30),
            tzOffsetMinutes: -300
        )
        #expect(backwards.end == backwards.start)
        #expect(backwards.wallClockDuration == 0)
        // The two clocks now disagree by half an hour, which is precisely what the sampler drops on.
        #expect(!backwards.clocksAgree())

        let timeline = EpisodeBuilder.build(
            intervals: [
                interval("com.google.Chrome", start: midnight.addingTimeInterval(3600),
                    seconds: minutes(40), offsetMinutes: -240),
                backwards,
            ]
        )
        expectWellFormed(timeline, "backwards wall clock")
    }

    /// The whole criterion in one day: a DST transition and a flight, with a sleep gap and a
    /// declared session laid over the top so every stage of the pipeline is exercised.
    @Test("A synthetic day containing both a DST transition and a timezone change is well formed")
    func dstAndTimeZoneChangeInOneDay() {
        let midnight = Self.springForwardMidnight
        let est = -300
        let edt = -240
        let cet = 60  // Berlin, after the flight

        var intervals: [ActivityInterval] = []

        // 23:00 the previous evening through the spring-forward jump.
        intervals.append(
            interval("com.apple.dt.Xcode", start: midnight.addingTimeInterval(-3600),
                seconds: minutes(45), offsetMinutes: est))
        intervals.append(
            interval("com.apple.Terminal", start: midnight.addingTimeInterval(-900),
                seconds: minutes(15), offsetMinutes: est))
        intervals.append(
            interval(
                "com.apple.dt.Xcode",
                start: midnight.addingTimeInterval(5400),
                seconds: minutes(30),
                offsetMinutes: est,
                wallClockEnd: midnight.addingTimeInterval(7200)
            ))
        intervals.append(
            interval("com.apple.Terminal", start: midnight.addingTimeInterval(7200),
                seconds: minutes(50), offsetMinutes: edt))

        // The flight. Eight hours of sleep, then the same clock reading a different offset.
        let flight = Gap(
            reason: .systemSleep,
            start: midnight.addingTimeInterval(10200),
            end: midnight.addingTimeInterval(39000)
        )

        intervals.append(
            interval("com.google.Chrome", start: midnight.addingTimeInterval(39000),
                seconds: minutes(35), offsetMinutes: cet))
        intervals.append(
            interval("com.tinyspeck.slackmacgap", start: midnight.addingTimeInterval(41100),
                seconds: minutes(25), offsetMinutes: cet))
        intervals.append(
            interval("com.google.Chrome", start: midnight.addingTimeInterval(42600),
                seconds: minutes(60), offsetMinutes: cet))

        let session = FocusSession(
            intendedOutcome: "Land in Berlin with the migration merged",
            startedAt: midnight.addingTimeInterval(39000),
            endedAt: midnight.addingTimeInterval(46200)
        )

        let timeline = EpisodeBuilder.build(
            intervals: intervals,
            absences: [flight],
            sessions: [session],
            dayStart: midnight,
            sealed: true
        )

        expectWellFormed(timeline, "DST plus a timezone change")
        #expect(timeline.trackedDuration == minutes(260))
        #expect(timeline.gaps(for: .systemSleep).count == 1)
        // Rebuilding the same day gives the same timeline: no wall-clock reading leaked in.
        #expect(
            timeline
                == EpisodeBuilder.build(
                    intervals: intervals.reversed(),
                    absences: [flight],
                    sessions: [session],
                    dayStart: midnight,
                    sealed: true
                )
        )
    }

    /// The offset is carried per interval, so an hour-of-day bucket survives the flight. Without it
    /// no circadian claim in any later phase can be honest.
    @Test("Each interval carries the offset that was in force while it ran")
    func offsetsAreCarriedPerInterval() {
        let midnight = Self.springForwardMidnight
        let before = interval("com.apple.dt.Xcode", start: midnight, seconds: 600, offsetMinutes: -300)
        let after = interval(
            "com.google.Chrome", start: midnight.addingTimeInterval(40000), seconds: 600,
            offsetMinutes: 60)

        #expect(before.tzOffsetMinutes == -300)
        #expect(after.tzOffsetMinutes == 60)
        #expect(before.tzOffsetMinutes != after.tzOffsetMinutes)
    }
}
