import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing, not decoration. `#expect` compares an
/// `Optional<Double>` against an integer-literal expression such as `40 * 60` by type as well as by
/// value, so that comparison reports a failure even when the numbers are identical. Routing every
/// duration through this helper keeps both sides of the comparison `Double`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

private func hours(_ count: Double) -> TimeInterval { count * 3600 }

/// 2024-01-15 00:00:00 UTC, the same anchor the fixture days use. Fixed so a failure reproduces
/// identically on any machine, in any timezone, on any day of the year.
private let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

private func at(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
    dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
}

private enum Bundle {
    static let xcode = "com.apple.dt.Xcode"
    static let terminal = "com.apple.Terminal"
    static let simulator = "com.apple.iphonesimulator"
    static let instruments = "com.apple.dt.Instruments"
    static let chrome = "com.google.Chrome"
    static let slack = "com.tinyspeck.slackmacgap"
    static let mail = "com.apple.mail"
    static let messages = "com.apple.MobileSMS"
    static let zoom = "us.zoom.xos"
    /// Deliberately absent from both shipped tables, so it has no category and no satellites.
    static let unknown = "com.example.Ledger"
}

private func displayName(_ bundleIdentifier: String) -> String {
    switch bundleIdentifier {
    case Bundle.xcode: "Xcode"
    case Bundle.terminal: "Terminal"
    case Bundle.simulator: "Simulator"
    case Bundle.instruments: "Instruments"
    case Bundle.chrome: "Chrome"
    case Bundle.slack: "Slack"
    case Bundle.mail: "Mail"
    case Bundle.messages: "Messages"
    case Bundle.zoom: "Zoom"
    default: "Ledger"
    }
}

/// One interval, written the way the sampler would have recorded it: wall clock and monotonic
/// measurement agreeing, because nothing stepped the clock.
private func interval(
    _ bundleIdentifier: String,
    from start: Date,
    seconds: TimeInterval,
    isIdle: Bool = false
) -> ActivityInterval {
    ActivityInterval(
        bundleIdentifier: bundleIdentifier,
        displayName: displayName(bundleIdentifier),
        start: start,
        end: start.addingTimeInterval(seconds),
        monotonicDuration: seconds,
        isIdle: isIdle,
        idleConfidence: isIdle ? .high : .low
    )
}

/// Lays a script of (application, seconds) steps out end to end.
private func stream(
    from start: Date,
    _ script: [(bundle: String, seconds: TimeInterval)]
) -> [ActivityInterval] {
    var cursor = start
    return script.map { step in
        let result = interval(step.bundle, from: cursor, seconds: step.seconds)
        cursor = cursor.addingTimeInterval(step.seconds)
        return result
    }
}

// MARK: - Fixture days

/// The four hand-written days from `docs/_design/INTELLIGENCE.md` §8, checked twice over: once
/// against the claims each day makes about itself, and once against the whole designed timeline.
///
/// The claims are the argument — "forty-six alternations are one block" — and they fail on the one
/// number that is wrong rather than on everything. The timeline comparison is the regression net: it
/// notices a block that moved by a second, an application credited with time it did not have, or a
/// visit counted twice.
@Suite("Episode builder: the four fixture days")
struct EpisodeBuilderFixtureTests {

    // The days are iterated rather than passed as `arguments:`, because a parameterised failure
    // prints the whole argument — here, several hundred intervals — and buries the one number that
    // is wrong under four megabytes of evidence.

    @Test("Every fixture day satisfies every claim it makes about itself")
    func fixtureClaimsHold() {
        for fixture in DayFixtures.allDays {
            let timeline = rebuild(fixture)
            for claim in fixture.claims {
                #expect(claim.holds(in: timeline), Comment(rawValue: "\(claim) failed. \(fixture.claim)"))
            }
        }
    }

    @Test("Every fixture day rebuilds into exactly the timeline it was designed to produce")
    func fixtureTimelinesMatch() {
        for fixture in DayFixtures.allDays {
            expectTimeline(rebuild(fixture), matches: fixture.expected, fixture.claim)
        }
    }

    @Test("Rebuilding the same day twice produces the same timeline, identifiers included")
    func buildIsDeterministic() {
        for fixture in DayFixtures.allDays {
            #expect(rebuild(fixture) == rebuild(fixture), Comment(rawValue: fixture.claim))
        }
    }

    @Test("No fixture day produces a negative duration or an entry that ends before it starts")
    func fixtureDaysAreWellFormed() {
        for fixture in DayFixtures.allDays {
            let timeline = rebuild(fixture)
            for episode in timeline.episodes {
                #expect(episode.end >= episode.start)
                #expect(episode.activeDuration >= 0)
                #expect(episode.apps.allSatisfy { $0.duration >= 0 && $0.visitCount >= 1 })
            }
            for gap in timeline.gaps {
                #expect(gap.duration > 0)
            }
            #expect(timeline.trackedDuration >= 0)
        }
    }

    @Test("Episodes and gaps tile the day without overlapping each other")
    func fixtureDaysDoNotOverlap() {
        for fixture in DayFixtures.allDays {
            let entries = rebuild(fixture).entries
            for (earlier, later) in zip(entries, entries.dropFirst()) {
                #expect(earlier.end <= later.start, Comment(rawValue: fixture.claim))
            }
        }
    }
}

// MARK: - Stage 0, normalise

@Suite("Episode builder: normalising")
struct EpisodeBuilderNormalisationTests {

    @Test("An empty day is an empty timeline, not a crash and not an invented block")
    func emptyDay() {
        let timeline = EpisodeBuilder.build(intervals: [], sessions: [], weights: .default)

        #expect(timeline.isEmpty)
        #expect(timeline.episodes.isEmpty)
        #expect(timeline.gaps.isEmpty)
        #expect(timeline.trackedDuration == 0.0)
        #expect(timeline.bounds == nil)
    }

    @Test("A single interval is a single block named after the one application in it")
    func singleInterval() {
        let timeline = EpisodeBuilder.build(
            intervals: [interval(Bundle.xcode, from: at(9, 0), seconds: minutes(40))],
            dayStart: dayStart
        )

        #expect(timeline.episodeCount == 1)
        #expect(timeline.gaps.isEmpty)
        #expect(timeline.episodes.first?.label == "Xcode")
        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
        #expect(timeline.episodes.first?.activeDuration == minutes(40))
        #expect(timeline.episodes.first?.intervalCount == 1)
        #expect(timeline.episodes.first?.apps.first?.visitCount == 1)
    }

    @Test("A single interval shorter than a block still stands rather than disappearing")
    func singleShortInterval() {
        let timeline = EpisodeBuilder.build(
            intervals: [interval(Bundle.chrome, from: at(9, 0), seconds: 30)],
            dayStart: dayStart
        )

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.activeDuration == 30.0)
    }

    @Test("One interval spanning the whole day is one block, not one per hour")
    func wholeDayInterval() {
        let timeline = EpisodeBuilder.build(
            intervals: [interval(Bundle.xcode, from: at(0, 0), seconds: hours(24))],
            dayStart: dayStart
        )

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.start == at(0, 0))
        #expect(timeline.episodes.first?.end == at(0, 0).addingTimeInterval(hours(24)))
        #expect(timeline.trackedDuration == hours(24))
        #expect(timeline.gaps.isEmpty)
    }

    @Test("Intervals arriving out of order are placed by their timestamps, not by their position")
    func outOfOrderInput() {
        let ordered = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.terminal, minutes(10)),
                (Bundle.xcode, minutes(20)),
            ]
        )
        let shuffled = [ordered[2], ordered[0], ordered[1]]

        let fromOrdered = EpisodeBuilder.build(intervals: ordered, dayStart: dayStart)
        let fromShuffled = EpisodeBuilder.build(intervals: shuffled, dayStart: dayStart)

        #expect(fromOrdered == fromShuffled)
        #expect(fromShuffled.episodeCount == 1)
        #expect(fromShuffled.episodes.first?.start == at(9, 0))
        #expect(fromShuffled.trackedDuration == minutes(50))
    }

    @Test("Two intervals overlapping in time produce no negative duration and no double count")
    func overlappingIntervals() {
        // Malformed input: the second interval starts ten minutes before the first one ended.
        let first = interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30))
        let second = interval(Bundle.chrome, from: at(9, 20), seconds: minutes(30))

        let timeline = EpisodeBuilder.build(intervals: [first, second], dayStart: dayStart)

        #expect(timeline.episodes.allSatisfy { $0.end >= $0.start })
        #expect(timeline.episodes.allSatisfy { $0.activeDuration >= 0 })
        // Fifty minutes of wall clock produced fifty minutes of work, not sixty: the ten minutes the
        // two intervals both claimed are counted once.
        #expect(timeline.trackedDuration == minutes(50))
        #expect(timeline.bounds?.duration == minutes(50))
    }

    @Test("An interval swallowed whole by the one before it is dropped rather than placed")
    func fullyContainedInterval() {
        let outer = interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30))
        let inner = interval(Bundle.chrome, from: at(9, 5), seconds: minutes(5))

        let timeline = EpisodeBuilder.build(intervals: [outer, inner], dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.apps.count == 1)
        #expect(timeline.trackedDuration == minutes(30))
    }

    @Test("A clock step cannot inflate a run: the monotonic measurement wins")
    func clockStepDoesNotInflateABlock() {
        // The wall clock says four hours; the monotonic clock, which cannot be stepped, says forty
        // minutes. An NTP correction, a timezone change or a user dragging the clock forward all
        // look like this, and all three would otherwise manufacture three hours of work.
        let stepped = ActivityInterval(
            bundleIdentifier: Bundle.xcode,
            displayName: "Xcode",
            start: at(9, 0),
            end: at(13, 0),
            monotonicDuration: minutes(40)
        )
        let timeline = EpisodeBuilder.build(intervals: [stepped], dayStart: dayStart)

        #expect(timeline.trackedDuration == minutes(40))
        #expect(timeline.episodes.first?.activeDuration == minutes(40))
        #expect(timeline.episodes.first?.apps.first?.duration == minutes(40))
        // The block is still placed where it happened; only its length comes from the safe clock.
        #expect(timeline.episodes.first?.wallClockSpan == hours(4))
    }

    @Test("A clock step backwards shortens the wall clock without inverting anything")
    func backwardsClockStep() {
        let stepped = ActivityInterval(
            bundleIdentifier: Bundle.terminal,
            displayName: "Terminal",
            start: at(9, 0),
            end: at(8, 0),
            monotonicDuration: minutes(20)
        )
        let timeline = EpisodeBuilder.build(intervals: [stepped], dayStart: dayStart)

        #expect(timeline.episodes.first?.wallClockSpan == 0.0)
        #expect(timeline.trackedDuration == minutes(20))
        #expect(timeline.episodes.allSatisfy { $0.end >= $0.start })
    }

    @Test("Intervals under two seconds fold into the following neighbour without being credited")
    func briefIntervalsAreDropped() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.chrome, 1),
                (Bundle.terminal, minutes(20)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        let apps = timeline.episodes.first?.apps ?? []
        #expect(apps.count == 2)
        #expect(!apps.contains { $0.bundleIdentifier == Bundle.chrome })
        // The one second is not handed to an application that was never really in front of anyone.
        #expect(timeline.trackedDuration == minutes(40))
        // The evidence count still knows three intervals were sampled.
        #expect(timeline.episodes.first?.intervalCount == 3)
    }

    @Test("A day made only of sampling noise is not erased, because it is still evidence")
    func dayOfOnlyBriefIntervals() {
        let script = stream(
            from: at(9, 0),
            [(Bundle.chrome, 1), (Bundle.slack, 1), (Bundle.zoom, 1)]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(!timeline.episodes.isEmpty)
        #expect(timeline.trackedDuration == 3.0)
    }

    @Test("Adjacent intervals of the same application merge into one visit")
    func adjacentSameBundleIntervalsMerge() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(10)),
                (Bundle.xcode, minutes(10)),
                (Bundle.xcode, minutes(10)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodes.first?.apps.first?.visitCount == 1)
        #expect(timeline.episodes.first?.intervalCount == 3)
        #expect(timeline.trackedDuration == minutes(30))
    }

    @Test("A glance that returns is an interjection, not a block and not a switch")
    func glanceCollapsing() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.slack, 6),
                (Bundle.xcode, minutes(20)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.interjectionCount == 1)
        #expect(timeline.episodes.first?.apps.count == 1)
        #expect(timeline.episodes.first?.apps.first?.visitCount == 1)
        #expect(timeline.episodes.first?.label == "Xcode")
        // The six seconds are not credited to the editor either; a glance is not work in it.
        #expect(timeline.trackedDuration == minutes(40))
    }

    @Test("An excursion long enough to be noticed is a switch, not a glance")
    func longExcursionIsNotAGlance() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.slack, minutes(9)),
                (Bundle.xcode, minutes(20)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.interjectionCount == 0)
        #expect(timeline.episodes.contains { $0.apps.contains { $0.bundleIdentifier == Bundle.slack } })
    }

    @Test("An excursion that does not return is never a glance, however short it was")
    func shortExcursionWithoutReturnIsNotAGlance() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.slack, 5),
                (Bundle.chrome, minutes(20)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.interjectionCount == 0)
    }
}

// MARK: - Idle and gaps

@Suite("Episode builder: absences")
struct EpisodeBuilderGapTests {

    @Test("A day spent entirely idle is a gap, not a block of work")
    func allIdleDay() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: hours(3), isIdle: true),
            interval(Bundle.xcode, from: at(12, 0), seconds: hours(3), isIdle: true),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: dayStart)

        #expect(timeline.episodes.isEmpty)
        #expect(timeline.trackedDuration == 0.0)
        #expect(timeline.gaps(for: .idle).count == 1)
        #expect(timeline.gapDuration(for: .idle) == hours(6))
        #expect(!timeline.hasUnexplainedTime)
    }

    @Test("Stillness short enough to be reading stays inside the block")
    func shortIdleStaysInsideTheBlock() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(20)),
            interval(Bundle.xcode, from: at(9, 20), seconds: minutes(2), isIdle: true),
            interval(Bundle.xcode, from: at(9, 22), seconds: minutes(20)),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: dayStart)

        #expect(timeline.gaps.isEmpty)
        #expect(timeline.episodeCount == 1)
        // The application never left the front, so the stillness is not a second visit to it.
        #expect(timeline.episodes.first?.apps.first?.visitCount == 1)
        #expect(timeline.trackedDuration == minutes(42))
    }

    @Test("Stillness long enough to stop being reading ends the block and opens a gap")
    func longIdleBecomesAGap() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(20)),
            interval(Bundle.xcode, from: at(9, 20), seconds: minutes(30), isIdle: true),
            interval(Bundle.xcode, from: at(9, 50), seconds: minutes(20)),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: dayStart)

        #expect(timeline.episodeCount == 2)
        #expect(timeline.gaps(for: .idle).count == 1)
        #expect(timeline.gapDuration(for: .idle) == minutes(30))
        #expect(timeline.trackedDuration == minutes(40))
    }

    @Test("Silence nobody accounted for is marked as silence nobody accounted for")
    func unexplainedSilence() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30)),
            interval(Bundle.xcode, from: at(11, 0), seconds: minutes(30)),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: dayStart)

        #expect(timeline.gaps(for: .unexplained).count == 1)
        #expect(timeline.unexplainedDuration == minutes(90))
        #expect(timeline.hasUnexplainedTime)
        #expect(timeline.episodeCount == 2)
    }

    @Test("An absence the sampler observed explains the silence, so nothing is left unexplained")
    func observedAbsenceExplainsSilence() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30)),
            interval(Bundle.xcode, from: at(11, 0), seconds: minutes(30)),
        ]
        let locked = Gap(reason: .screenLocked, start: at(9, 30), end: at(11, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [locked], dayStart: dayStart
        )

        #expect(timeline.gaps(for: .screenLocked).count == 1)
        #expect(timeline.gaps(for: .unexplained).isEmpty)
        #expect(timeline.episodeCount == 2)
    }

    @Test("An absence that explains only part of a silence leaves the rest unexplained")
    func partiallyExplainedSilence() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30)),
            interval(Bundle.xcode, from: at(11, 0), seconds: minutes(30)),
        ]
        let paused = Gap(reason: .trackingPaused, start: at(9, 30), end: at(10, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [paused], dayStart: dayStart
        )

        #expect(timeline.gapDuration(for: .trackingPaused) == minutes(30))
        #expect(timeline.unexplainedDuration == minutes(60))
    }

    @Test("A night the machine slept is a sleep, not a crash: the two never both appear")
    func sleepOutranksAnAbsentApplication() {
        let intervals = [
            interval(Bundle.xcode, from: at(17, 0), seconds: minutes(60)),
            interval(Bundle.xcode, from: at(18, 0).addingTimeInterval(hours(15)), seconds: minutes(60)),
        ]
        let sleep = Gap(reason: .systemSleep, start: at(18, 0), end: at(18, 0).addingTimeInterval(hours(15)))
        let heartbeat = Gap(
            reason: .appNotRunning,
            start: at(18, 0).addingTimeInterval(60),
            end: at(18, 0).addingTimeInterval(hours(14))
        )

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [sleep, heartbeat], dayStart: dayStart
        )

        #expect(timeline.gaps(for: .systemSleep).count == 1)
        #expect(timeline.gaps(for: .appNotRunning).isEmpty)
        #expect(timeline.gapDuration(for: .systemSleep) == hours(15))
        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.allSatisfy { $0.wallClockSpan <= hours(1) })
    }

    @Test("A crash that is not covered by a sleep keeps its own reason")
    func uncoveredHeartbeatGapSurvives() {
        let intervals = [
            interval(Bundle.xcode, from: at(13, 0), seconds: minutes(90)),
            interval(Bundle.xcode, from: at(16, 10), seconds: minutes(70)),
        ]
        let crash = Gap(reason: .appNotRunning, start: at(14, 30), end: at(16, 10))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [crash], dayStart: dayStart
        )

        #expect(timeline.gaps(for: .appNotRunning).count == 1)
        #expect(timeline.gapDuration(for: .appNotRunning) == minutes(100))
        #expect(timeline.episodes.first?.end == at(14, 30))
    }

    @Test("An interval that contradicts an observed absence is dropped, not placed inside it")
    func intervalInsideAnAbsenceIsDropped() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30)),
            // The sampler was not running here, so this cannot have been recorded.
            interval(Bundle.chrome, from: at(10, 0), seconds: minutes(30)),
            interval(Bundle.xcode, from: at(12, 0), seconds: minutes(30)),
        ]
        let crash = Gap(reason: .appNotRunning, start: at(9, 30), end: at(12, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [crash], dayStart: dayStart
        )

        #expect(timeline.episodeCount == 2)
        #expect(!timeline.episodes.contains { $0.apps.contains { $0.bundleIdentifier == Bundle.chrome } })
        #expect(timeline.gapDuration(for: .appNotRunning) == minutes(150))
    }

    @Test("Nothing is ever merged across an absence that ended the run outright")
    func hardGapsAreNeverMergedAcross() {
        // Two one-minute stretches of the same application, either side of a ten-second crash. Both
        // are far below the minimum block length and would otherwise absorb into each other.
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: 60),
            interval(Bundle.xcode, from: at(9, 1, second: 10), seconds: 60),
        ]
        let crash = Gap(reason: .appNotRunning, start: at(9, 1), end: at(9, 1, second: 10))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [crash], dayStart: dayStart
        )

        #expect(timeline.episodeCount == 2)
        #expect(timeline.gaps(for: .appNotRunning).count == 1)
    }

    @Test("Overlapping absences are reduced to an ordered record rather than double counted")
    func overlappingAbsencesAreResolved() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30)),
            interval(Bundle.xcode, from: at(12, 0), seconds: minutes(30)),
        ]
        let first = Gap(reason: .displayOff, start: at(9, 30), end: at(11, 0))
        let second = Gap(reason: .screenLocked, start: at(10, 0), end: at(12, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [first, second], dayStart: dayStart
        )

        let entries = timeline.entries
        for (earlier, later) in zip(entries, entries.dropFirst()) {
            #expect(earlier.end <= later.start)
        }
        #expect(timeline.gapDuration == minutes(150))
        #expect(timeline.gaps(for: .unexplained).isEmpty)
    }
}

// MARK: - Stage 2 and 3, segmenting

@Suite("Episode builder: segmenting")
struct EpisodeBuilderSegmentationTests {

    @Test("A tight alternation between satellites is one block, not one block per switch")
    func satelliteAlternationIsOneBlock() {
        var script: [(bundle: String, seconds: TimeInterval)] = []
        for _ in 0..<40 {
            script += [(Bundle.xcode, 30), (Bundle.terminal, 22)]
        }
        let timeline = EpisodeBuilder.build(intervals: stream(from: at(9, 0), script), dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.label == "Xcode, Terminal")
        #expect(timeline.episodes.first?.intervalCount == 80)
    }

    @Test("Two unrelated stretches of work are two blocks")
    func unrelatedWorkIsTwoBlocks() {
        let script = stream(
            from: at(9, 0),
            [(Bundle.xcode, minutes(45)), (Bundle.zoom, minutes(45))]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.first?.label == "Xcode")
        #expect(timeline.episodes.last?.label == "Zoom")
    }

    @Test("A short segment merges into the neighbour it shares more evidence with")
    func shortSegmentsAbsorbIntoTheirBestNeighbour() {
        // Two minutes of the simulator between an hour of Zoom and an hour of Xcode. It belongs with
        // the editor, which it shares a satellite group with, and nowhere near the call.
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.zoom, minutes(60)),
                (Bundle.simulator, minutes(2)),
                (Bundle.xcode, minutes(60)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 2)
        let editorBlock = timeline.episodes.last
        #expect(editorBlock?.apps.contains { $0.bundleIdentifier == Bundle.simulator } == true)
        #expect(editorBlock?.start == at(9, 60))
    }

    @Test("No block survives that is shorter than a block a person would recognise")
    func absorptionReachesAFixedPoint() {
        // A shredded hour: nothing here is longer than ninety seconds.
        var script: [(bundle: String, seconds: TimeInterval)] = []
        let rotation = [Bundle.chrome, Bundle.slack, Bundle.zoom, Bundle.xcode, Bundle.mail]
        for index in 0..<40 {
            script.append((rotation[index % rotation.count], 90))
        }
        let timeline = EpisodeBuilder.build(intervals: stream(from: at(9, 0), script), dayStart: dayStart)

        #expect(!timeline.episodes.isEmpty)
        #expect(timeline.episodes.allSatisfy { $0.activeDuration >= SegmentationWeights.default.minEpisodeDuration })
        #expect(timeline.trackedDuration == minutes(60))
    }

    @Test("A segment walled in on both sides stands alone rather than being smeared into a block")
    func isolatedShortSegmentStandsAlone() {
        let intervals = [
            interval(Bundle.xcode, from: at(9, 0), seconds: minutes(30)),
            interval(Bundle.chrome, from: at(10, 0), seconds: minutes(1)),
            interval(Bundle.xcode, from: at(11, 0), seconds: minutes(30)),
        ]
        let before = Gap(reason: .screenLocked, start: at(9, 30), end: at(10, 0))
        let after = Gap(reason: .screenLocked, start: at(10, 1), end: at(11, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [before, after], dayStart: dayStart
        )

        #expect(timeline.episodeCount == 3)
        #expect(timeline.episodes[1].label == "Chrome")
        #expect(timeline.episodes[1].activeDuration == minutes(1))
    }

    @Test("A short excursion between two stretches of the same work does not cut the block in three")
    func excursionBetweenTwoStretchesIsAbsorbed() {
        // Twenty minutes of a call, a look at the browser and a message, then the rest of the call.
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.zoom, minutes(20)),
                (Bundle.chrome, minutes(3)),
                (Bundle.slack, minutes(2)),
                (Bundle.zoom, minutes(15)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.label == "Zoom, Chrome, Slack")
        #expect(timeline.episodes.first?.start == at(9, 0))
        #expect(timeline.episodes.first?.end == at(9, 40))
    }

    @Test("A stretch long enough to be a block of its own is never treated as an excursion")
    func longInterludeIsNotAnExcursion() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.zoom, minutes(20)),
                (Bundle.xcode, minutes(30)),
                (Bundle.zoom, minutes(20)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 3)
        #expect(timeline.episodes.map(\.label) == ["Zoom", "Xcode", "Zoom"])
    }

    @Test("A fragment that opens new work is carried forward rather than added to the block before")
    func fragmentOpeningNewWorkIsCarriedForward() {
        // Three minutes of messaging after an hour of editing, and then more messaging. The three
        // minutes belong to what follows; attaching them to the editor would claim they were part
        // of work they had nothing to do with.
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(60)),
                (Bundle.slack, minutes(3)),
                (Bundle.chrome, minutes(1)),
                (Bundle.slack, minutes(20)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.first?.end == at(10, 0))
        #expect(timeline.episodes.first?.apps.count == 1)
        #expect(timeline.episodes.last?.start == at(10, 0))
    }

    @Test("Absorption is finished after one pass: the cap is documentation, not a working limit")
    func absorptionSettlesInOnePass() {
        // The claim written on `absorbed`, made falsifiable. If a change ever needs a third pass to
        // reach the same answer, this fails rather than the comment quietly becoming untrue.
        for fixture in DayFixtures.allDays {
            let capped = SegmentationWeights(maximumAbsorptionPasses: 2)
            let built = EpisodeBuilder.build(
                intervals: fixture.intervals,
                absences: fixture.absences,
                sessions: fixture.sessions,
                weights: capped,
                dayStart: fixture.expected.dayStart,
                sealed: fixture.expected.sealed
            )
            expectTimeline(built, matches: fixture.expected, fixture.claim)
        }
    }

    @Test("An unknown application never manufactures a boundary out of ignorance")
    func unknownCategoryDoesNotCut() {
        let script = stream(
            from: at(9, 0),
            [(Bundle.unknown, minutes(30)), (Bundle.unknown, minutes(30))]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
    }

    @Test("Weights are honoured: raising the threshold merges what the default would cut")
    func weightsChangeTheAnswer() {
        let script = stream(
            from: at(9, 0),
            [(Bundle.xcode, minutes(45)), (Bundle.zoom, minutes(45))]
        )
        let permissive = SegmentationWeights(boundaryThreshold: 10)

        #expect(EpisodeBuilder.build(intervals: script, weights: permissive, dayStart: dayStart).episodeCount == 1)
        #expect(EpisodeBuilder.build(intervals: script, dayStart: dayStart).episodeCount == 2)
    }
}

// MARK: - Stage 4, naming

@Suite("Episode builder: naming")
struct EpisodeBuilderNamingTests {

    private func session(
        _ outcome: String,
        from start: Date,
        to end: Date,
        id: UUID = UUID()
    ) -> FocusSession {
        FocusSession(
            id: id,
            intendedOutcome: outcome,
            workType: .deepWork,
            startedAt: start,
            endedAt: end
        )
    }

    @Test("A block that is mostly a declared session borrows the user's own sentence, verbatim")
    func declaredSessionNamesTheBlock() {
        let outcome = "Finish the receipt deduplication PR"
        let declared = session(outcome, from: at(9, 0), to: at(10, 0))
        let script = stream(from: at(9, 0), [(Bundle.xcode, minutes(60))])

        let timeline = EpisodeBuilder.build(
            intervals: script, sessions: [declared], dayStart: dayStart
        )

        #expect(timeline.episodes.first?.label == outcome)
        #expect(timeline.episodes.first?.labelConfidence == .declared)
        #expect(timeline.episodes.first?.sessionID == declared.id)
        #expect(timeline.declaredEpisodes.count == 1)
    }

    @Test("A session edge always cuts, whatever the applications either side have in common")
    func sessionEdgesCutUnconditionally() {
        let declared = session("Review the migration plan", from: at(9, 30), to: at(10, 0))
        let script = stream(
            from: at(9, 0),
            [(Bundle.xcode, minutes(30)), (Bundle.xcode, minutes(30)), (Bundle.xcode, minutes(30))]
        )

        let timeline = EpisodeBuilder.build(
            intervals: script, sessions: [declared], dayStart: dayStart
        )

        #expect(timeline.episodeCount == 3)
        #expect(timeline.episodes[1].labelConfidence == .declared)
        #expect(timeline.episodes[0].labelConfidence == .appRoster)
        #expect(timeline.episodes[2].labelConfidence == .appRoster)
    }

    @Test("A session that overlaps only a sliver of a block does not get to name it")
    func partialSessionOverlapDoesNotName() {
        // Ten minutes of a sixty-minute block: the session describes some other work.
        let declared = session("Answer the on-call page", from: at(8, 50), to: at(9, 10))
        let script = stream(from: at(9, 0), [(Bundle.chrome, minutes(60))])

        let timeline = EpisodeBuilder.build(
            intervals: script, sessions: [declared], dayStart: dayStart
        )

        #expect(timeline.episodes.last?.labelConfidence == .appRoster)
        #expect(timeline.episodes.last?.label == "Chrome")
    }

    @Test("A session with no intervals at all names nothing and invents nothing")
    func sessionWithNoIntervals() {
        let declared = session("Write the design review", from: at(9, 0), to: at(10, 0))

        let timeline = EpisodeBuilder.build(
            intervals: [], sessions: [declared], weights: .default, dayStart: dayStart
        )

        #expect(timeline.isEmpty)
        #expect(timeline.declaredEpisodes.isEmpty)
    }

    @Test("A session still running names nothing, because measuring it would need a clock")
    func unfinishedSessionNamesNothing() {
        let running = FocusSession(
            intendedOutcome: "Still going",
            workType: .deepWork,
            startedAt: at(9, 0)
        )
        let script = stream(from: at(9, 0), [(Bundle.xcode, minutes(60))])

        let timeline = EpisodeBuilder.build(
            intervals: script, sessions: [running], dayStart: dayStart
        )

        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
        #expect(timeline.episodes.first?.sessionID == nil)
    }

    @Test("A session with a blank outcome falls through to what the applications can prove")
    func blankOutcomeFallsThrough() {
        let declared = session("   ", from: at(9, 0), to: at(10, 0))
        let script = stream(from: at(9, 0), [(Bundle.xcode, minutes(60))])

        let timeline = EpisodeBuilder.build(
            intervals: script, sessions: [declared], dayStart: dayStart
        )

        #expect(timeline.episodes.first?.label == "Xcode")
        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
        // The block still knows which session it sat inside, even though it did not borrow a name.
        #expect(timeline.episodes.first?.sessionID == declared.id)
    }

    @Test("The roster names applications by descending time and counts the rest")
    func rosterOverflow() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.slack, minutes(20)),
                (Bundle.mail, minutes(15)),
                (Bundle.zoom, minutes(12)),
                (Bundle.chrome, minutes(10)),
                (Bundle.messages, minutes(8)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, weights: SegmentationWeights(boundaryThreshold: 10), dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.label == "Slack, Mail, Zoom +2 more")
        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
    }

    @Test("A category may name a block only when every application in it agrees")
    func unanimousCategoryNamesAnOverflowingRoster() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.terminal, minutes(15)),
                (Bundle.simulator, minutes(12)),
                (Bundle.instruments, minutes(10)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.label == "Development")
        #expect(timeline.episodes.first?.labelConfidence == .category)
    }

    @Test("A category never names a block whose applications disagree about what it was")
    func mixedCategoriesKeepTheRoster() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.xcode, minutes(20)),
                (Bundle.terminal, minutes(15)),
                (Bundle.simulator, minutes(12)),
                (Bundle.chrome, minutes(10)),
            ]
        )
        let timeline = EpisodeBuilder.build(
            intervals: script, weights: SegmentationWeights(boundaryThreshold: 10), dayStart: dayStart
        )

        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
        #expect(timeline.episodes.first?.label == "Xcode, Terminal, Simulator +1 more")
    }

    @Test("A block a shipped table cannot classify keeps the roster rather than guessing")
    func unknownApplicationsAreNeverCategorised() {
        let script = stream(
            from: at(9, 0),
            [
                (Bundle.unknown, minutes(20)),
                (Bundle.unknown, minutes(15)),
            ]
        )
        let timeline = EpisodeBuilder.build(intervals: script, dayStart: dayStart)

        #expect(timeline.episodes.first?.label == "Ledger")
        #expect(timeline.episodes.first?.labelConfidence == .appRoster)
    }

    @Test("No block on a reconstructed day is ever named from an identifier: that phase is unbuilt")
    func noBlockClaimsAnIdentifier() {
        for fixture in DayFixtures.allDays {
            let timeline = rebuild(fixture)
            #expect(timeline.episodes.allSatisfy { $0.labelConfidence != .identifier })
        }
    }
}

// MARK: - Helpers

private func rebuild(_ fixture: DayFixtures.DayFixture) -> DayTimeline {
    EpisodeBuilder.build(
        intervals: fixture.intervals,
        absences: fixture.absences,
        sessions: fixture.sessions,
        weights: fixture.weights,
        dayStart: fixture.expected.dayStart,
        sealed: fixture.expected.sealed
    )
}

/// Compares a rebuilt day against its design field by field, ignoring identifiers.
///
/// Identifiers are derived rather than designed, so comparing whole values would only ever report
/// that two `UUID`s differ. Everything a person would see is compared instead, and each difference
/// is reported where it happened rather than as one unreadable inequality.
private func expectTimeline(
    _ built: DayTimeline,
    matches expected: DayTimeline,
    _ claim: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        built.episodeCount == expected.episodeCount,
        Comment(rawValue: "\(claim)\nblocks: \(describe(built.episodes)) expected \(describe(expected.episodes))"),
        sourceLocation: sourceLocation
    )
    #expect(built.dayStart == expected.dayStart, sourceLocation: sourceLocation)
    #expect(built.sealed == expected.sealed, sourceLocation: sourceLocation)

    for (builtEpisode, expectedEpisode) in zip(built.episodes, expected.episodes) {
        let where_ = "block \(expectedEpisode.label)"
        #expect(builtEpisode.start == expectedEpisode.start, Comment(rawValue: "\(where_) start"), sourceLocation: sourceLocation)
        #expect(builtEpisode.end == expectedEpisode.end, Comment(rawValue: "\(where_) end"), sourceLocation: sourceLocation)
        #expect(builtEpisode.label == expectedEpisode.label, Comment(rawValue: "\(where_) label"), sourceLocation: sourceLocation)
        #expect(
            builtEpisode.labelConfidence == expectedEpisode.labelConfidence,
            Comment(rawValue: "\(where_) confidence"), sourceLocation: sourceLocation
        )
        #expect(builtEpisode.sessionID == expectedEpisode.sessionID, Comment(rawValue: "\(where_) session"), sourceLocation: sourceLocation)
        #expect(
            builtEpisode.interjections == expectedEpisode.interjections,
            Comment(rawValue: "\(where_) interjections"), sourceLocation: sourceLocation
        )
        #expect(
            builtEpisode.intervalCount == expectedEpisode.intervalCount,
            Comment(rawValue: "\(where_) interval count"), sourceLocation: sourceLocation
        )
        #expect(builtEpisode.apps == expectedEpisode.apps, Comment(rawValue: "\(where_) applications"), sourceLocation: sourceLocation)
    }

    #expect(built.gaps.count == expected.gaps.count, Comment(rawValue: "\(claim) gap count"), sourceLocation: sourceLocation)
    for (builtGap, expectedGap) in zip(built.gaps, expected.gaps) {
        #expect(builtGap.reason == expectedGap.reason, sourceLocation: sourceLocation)
        #expect(builtGap.start == expectedGap.start, sourceLocation: sourceLocation)
        #expect(builtGap.end == expectedGap.end, sourceLocation: sourceLocation)
    }
}

private func describe(_ episodes: [Episode]) -> String {
    episodes.map { "\($0.label) \(Int($0.start.timeIntervalSinceReferenceDate))" }.joined(separator: " | ")
}
