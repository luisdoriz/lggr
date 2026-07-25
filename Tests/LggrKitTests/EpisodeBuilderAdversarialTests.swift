import Foundation
import Testing

@testable import LggrKit

// The days three adversarial reviews found the builder wrong on, written down so it cannot be wrong
// on them again.
//
// Everything here is a shape the four fixture days do not contain, because the four fixture days are
// tidy: their intervals abut exactly, their idle stretches are contiguous, their session edges land
// on interval boundaries and their absences begin and end where sampling stopped and resumed. Real
// days are not tidy, and every case below is a way a real day is untidy that used to produce a
// confidently wrong block, a fabricated absence, or a build that did not finish.

/// 2024-01-15 00:00:00 UTC, the anchor the fixture days use, so a failure here reproduces on any
/// machine in any timezone.
private let anchor = Date(timeIntervalSinceReferenceDate: 727_051_200)

private func moment(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    anchor.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
}

private enum App {
    static let xcode = "com.apple.dt.Xcode"
    static let terminal = "com.apple.Terminal"
    static let chrome = "com.google.Chrome"
    static let slack = "com.tinyspeck.slackmacgap"
}

/// One interval. `monotonic` defaults to the wall-clock length, which is what a day with no clock
/// step and no sleep in it looks like; the cases that need the two to disagree say so.
private func sample(
    _ bundleIdentifier: String,
    at start: Date,
    seconds: TimeInterval,
    monotonic: TimeInterval? = nil,
    isIdle: Bool = false
) -> ActivityInterval {
    ActivityInterval(
        bundleIdentifier: bundleIdentifier,
        displayName: bundleIdentifier,
        start: start,
        end: start.addingTimeInterval(seconds),
        monotonicDuration: monotonic ?? seconds,
        isIdle: isIdle,
        idleConfidence: isIdle ? .high : .low
    )
}

/// The largest stretch between two consecutive rows on a timeline that neither of them covers.
///
/// Zero is the only acceptable answer. A timeline whose rows do not touch is claiming nothing
/// happened in between while also refusing to say so, which is the one thing a gap exists to stop.
private func largestHole(in timeline: DayTimeline) -> TimeInterval {
    let entries = timeline.entries
    var worst: TimeInterval = 0
    for (earlier, later) in zip(entries, entries.dropFirst()) {
        worst = max(worst, later.start.timeIntervalSince(earlier.end))
    }
    return worst
}

/// The largest amount by which two consecutive rows overlap.
private func largestOverlap(in timeline: DayTimeline) -> TimeInterval {
    let entries = timeline.entries
    var worst: TimeInterval = 0
    for (earlier, later) in zip(entries, entries.dropFirst()) {
        worst = max(worst, earlier.end.timeIntervalSince(later.start))
    }
    return worst
}

// MARK: - Glances

@Suite("Episode builder: glances under a fast alternation")
struct EpisodeBuilderGlanceTests {

    @Test("A fast alternation is not swallowed by the rule meant to collapse glances into it")
    func alternationIsNotSwallowedByItsOwnGlanceRule() {
        // Ten minutes of the editor, forty two-sided five-second alternations, ten minutes of chat.
        // Asking `runs[index - 1]` rather than the block being assembled makes the rule fire on the
        // editor's own five-second runs as well as on the chat client's: the editor is recorded as
        // interrupting itself, its seconds are discarded, and four hundred of the sixteen hundred
        // seconds on the clock disappear with nothing on the timeline to explain them.
        var intervals = [sample(App.xcode, at: moment(9, 0), seconds: 600)]
        var cursor = moment(9, 0).addingTimeInterval(600)
        for _ in 0..<40 {
            intervals.append(sample(App.slack, at: cursor, seconds: 5))
            cursor = cursor.addingTimeInterval(5)
            intervals.append(sample(App.xcode, at: cursor, seconds: 5))
            cursor = cursor.addingTimeInterval(5)
        }
        intervals.append(sample(App.slack, at: cursor, seconds: 600))

        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        #expect(timeline.episodeCount == 2)
        // Ten minutes plus the forty five-second returns to it. Not ten minutes flat.
        #expect(timeline.episodes.first?.activeDuration == 800.0)
        #expect(timeline.episodes.last?.activeDuration == 600.0)
        // Forty glances at the chat client, and not one of them at the editor: an application can
        // never interrupt itself.
        #expect(timeline.interjectionCount == 40)
        // Forty-one intervals of editor behind the first block, one of chat behind the second.
        #expect(timeline.episodes.first?.intervalCount == 41)
        #expect(timeline.episodes.last?.intervalCount == 1)
        // Nothing on this day was unobserved, so nothing on it may be a hole.
        #expect(largestHole(in: timeline) == 0.0)
        #expect(largestOverlap(in: timeline) == 0.0)
    }

    @Test("An excursion whose return is two hours later was a person leaving, not a glance")
    func aGlanceMustTouchTheApplicationItInterrupted() {
        // Six seconds of chat, then two hours of silence, then the editor again. The applications
        // either side match and the excursion is short, so every test but the clock says "glance" —
        // and collapsing it would weld two hours nobody observed into the block before it.
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 1200),
            sample(App.slack, at: moment(9, 20), seconds: 6),
            sample(App.xcode, at: moment(11, 20, 6), seconds: 1200),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        #expect(timeline.interjectionCount == 0)
        #expect(timeline.episodeCount == 2)
        #expect(timeline.unexplainedDuration == 7200.0)
        #expect(timeline.episodes.first?.end == moment(9, 20, 6))
        #expect(largestHole(in: timeline) == 0.0)
    }

    @Test("A glance is still collapsed when it really is one")
    func anAbuttingGlanceIsStillAGlance() {
        // The control for the two tests above: the tightened rule must not have stopped collapsing.
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 1200),
            sample(App.slack, at: moment(9, 20), seconds: 6),
            sample(App.xcode, at: moment(9, 20, 6), seconds: 1200),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.interjectionCount == 1)
        #expect(timeline.episodes.first?.apps.count == 1)
    }
}

// MARK: - Absences

@Suite("Episode builder: absences under untidy geometry")
struct EpisodeBuilderAbsenceGeometryTests {

    @Test("Stillness at nine and stillness at noon are two stretches, not three hours of idle")
    func nonContiguousIdleIsNeverOneStretch() {
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 60, isIdle: true),
            sample(App.xcode, at: moment(12, 0), seconds: 60, isIdle: true),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        // Three hours nobody observed must never be asserted as three hours of anything.
        #expect(timeline.gaps(for: .idle).isEmpty)
        #expect(timeline.unexplainedDuration == 10_740.0)
        #expect(timeline.gapDuration == 10_740.0)
        #expect(largestOverlap(in: timeline) == 0.0)
        #expect(largestHole(in: timeline) == 0.0)
    }

    @Test("A fabricated idle stretch can no longer overlap the absence that really explains the day")
    func anIdleGapNeverOverlapsARecordedAbsence() {
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 60, isIdle: true),
            sample(App.xcode, at: moment(12, 0), seconds: 60, isIdle: true),
        ]
        let asleep = Gap(reason: .systemSleep, start: moment(9, 1), end: moment(12, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [asleep], dayStart: anchor
        )

        #expect(timeline.gaps.count == 1)
        #expect(timeline.gaps(for: .systemSleep).count == 1)
        // Spanning both stretches would report 21 600 seconds of absence across a 10 860 second day.
        #expect(timeline.gapDuration == 10_740.0)
        #expect(largestOverlap(in: timeline) == 0.0)
    }

    @Test("A night whose heartbeat gap contains the sleep is still reported as a night")
    func aHeartbeatGapContainingASleepIsStillASleep() {
        // The geometry of every ordinary night: the last heartbeat is written a little before the
        // machine sleeps and the first one after waking a little after it wakes, so the heartbeat gap
        // *contains* the sleep rather than sitting inside it. Testing containment the other way round
        // keeps the heartbeat gap, clips the sleep to nothing, and renders a normal night as
        // "Lggr was not running" for fifteen hours.
        let intervals = [
            sample(App.xcode, at: moment(17, 0), seconds: 3600),
            sample(App.xcode, at: moment(33, 12, 40), seconds: 3600),
        ]
        let asleep = Gap(reason: .systemSleep, start: moment(18, 4), end: moment(33, 12))
        let heartbeat = Gap(
            reason: .appNotRunning, start: moment(18, 3, 20), end: moment(33, 12, 40)
        )

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [asleep, heartbeat], dayStart: anchor
        )

        #expect(timeline.gaps(for: .systemSleep).count == 1)
        #expect(timeline.gapDuration(for: .systemSleep) == 54_480.0)
        // The forty seconds either side are time the machine was awake and the application was not
        // running. That is a true statement about the day and it survives; what does not survive is
        // the night being called a crash.
        #expect(timeline.gapDuration(for: .appNotRunning) == 80.0)
        #expect(largestOverlap(in: timeline) == 0.0)
        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.allSatisfy { $0.wallClockSpan <= 3600 })
    }

    @Test("A crash in the afternoon is not erased by a sleep that evening")
    func aCrashBeforeASleepKeepsItsOwnReason() {
        // The case a blanket "any overlap with a sleep means it was a sleep" rule would destroy: six
        // hours of a genuinely absent application, followed by a night. Both happened.
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 3600),
            sample(App.xcode, at: moment(33, 0), seconds: 3600),
        ]
        let asleep = Gap(reason: .systemSleep, start: moment(18, 0), end: moment(33, 0))
        let crash = Gap(reason: .appNotRunning, start: moment(12, 0), end: moment(33, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [asleep, crash], dayStart: anchor
        )

        #expect(timeline.gapDuration(for: .appNotRunning) == 21_600.0)
        #expect(timeline.gapDuration(for: .systemSleep) == 54_000.0)
        #expect(largestOverlap(in: timeline) == 0.0)
    }

    @Test("A four-minute silence is reported, not folded into the row on either side of it")
    func aShortSilenceIsStillASilence() {
        // Two half hours of the editor with four minutes of nothing between them. Suppressing the
        // gap because it is short leaves one row reading "9:00–10:04" that claims four minutes it
        // never observed — the same lie as the fifteen-hour block, told quietly.
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 1800),
            sample(App.xcode, at: moment(9, 34), seconds: 1800),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        #expect(timeline.unexplainedDuration == 240.0)
        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.first?.end == moment(9, 30))
        #expect(timeline.episodes.last?.start == moment(9, 34))
        #expect(timeline.trackedDuration == 3600.0)
        #expect(largestHole(in: timeline) == 0.0)
    }

    @Test("An interval a crash cut short keeps the minutes it did observe")
    func anIntervalClippedByACrashKeepsWhatItObserved() {
        // Sampling stops when the process dies, not when the heartbeat file was last written, so the
        // final interval routinely runs a little past the last heartbeat. Here it runs two minutes
        // past a twelve-minute interval. Dropping the whole interval for contradicting the absence
        // throws away the ten minutes that were observed and reports them as time nobody saw.
        let intervals = [
            sample(App.xcode, at: moment(13, 0), seconds: 4800),
            sample(App.xcode, at: moment(14, 20), seconds: 720),
            sample(App.xcode, at: moment(16, 10), seconds: 3600),
        ]
        let crash = Gap(reason: .appNotRunning, start: moment(14, 30), end: moment(16, 10))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [crash], dayStart: anchor
        )

        // The block closes at the last heartbeat, and it closes there because it was clipped rather
        // than because the fixture arranged for an interval to end on that instant.
        #expect(timeline.episodes.first?.end == moment(14, 30))
        #expect(timeline.episodes.first?.activeDuration == 5400.0)
        #expect(timeline.episodes.first?.intervalCount == 2)
        #expect(timeline.gapDuration(for: .appNotRunning) == 6000.0)
        #expect(timeline.unexplainedDuration == 0.0)
        #expect(largestHole(in: timeline) == 0.0)
    }

    @Test("An interval a recorded absence swallows whole is still dropped entirely")
    func anIntervalInsideAnAbsenceIsStillDropped() {
        // The control for the clipping above: nothing survives, so nothing is placed.
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 1800),
            sample(App.chrome, at: moment(10, 0), seconds: 1800),
            sample(App.xcode, at: moment(12, 0), seconds: 1800),
        ]
        let crash = Gap(reason: .appNotRunning, start: moment(9, 30), end: moment(12, 0))

        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: [crash], dayStart: anchor
        )

        #expect(timeline.episodeCount == 2)
        #expect(!timeline.episodes.contains { $0.apps.contains { $0.bundleIdentifier == App.chrome } })
        #expect(timeline.gapDuration(for: .appNotRunning) == 9000.0)
    }
}

// MARK: - Declared work

@Suite("Episode builder: declared edges inside an activation")
struct EpisodeBuilderSessionEdgeTests {

    @Test("A session edge that lands inside one long activation still cuts")
    func aSessionEdgeInsideAnIntervalStillCuts() {
        // One unbroken hour of the editor with thirty-six minutes declared over its first half. The
        // segmenter can only cut where a run ends, so without splitting the activation the edge is
        // unenforceable: the overlap clears `sessionOverlapFraction` and the whole hour wears the
        // user's own sentence, twenty-four minutes of which they never declared.
        let declared = FocusSession(
            intendedOutcome: "Rewrite the importer",
            workType: .deepWork,
            startedAt: moment(9, 0),
            endedAt: moment(9, 36)
        )
        let timeline = EpisodeBuilder.build(
            intervals: [sample(App.xcode, at: moment(9, 0), seconds: 3600)],
            sessions: [declared],
            dayStart: anchor
        )

        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.first?.labelConfidence == .declared)
        #expect(timeline.episodes.first?.label == "Rewrite the importer")
        #expect(timeline.episodes.first?.start == moment(9, 0))
        #expect(timeline.episodes.first?.end == moment(9, 36))
        // The declared block claims exactly the thirty-six minutes that were declared.
        #expect(timeline.episodes.first?.activeDuration == 2160.0)
        #expect(timeline.episodes.last?.labelConfidence == .appRoster)
        #expect(timeline.episodes.last?.activeDuration == 1440.0)
        // Splitting divides the measurement; it never invents any.
        #expect(timeline.trackedDuration == 3600.0)
        #expect(largestHole(in: timeline) == 0.0)
    }

    @Test("Pro-rating a split activation cannot manufacture time a stepped clock did not measure")
    func splittingPreservesTheMonotonicMeasurement() {
        // Four wall-clock hours that the monotonic clock says were forty minutes, cut in three by a
        // declared session. The pieces must still add up to forty minutes.
        let declared = FocusSession(
            intendedOutcome: "Pair on the migration",
            workType: .deepWork,
            startedAt: moment(10, 0),
            endedAt: moment(11, 30)
        )
        let stepped = ActivityInterval(
            bundleIdentifier: App.xcode,
            displayName: "Xcode",
            start: moment(9, 0),
            end: moment(13, 0),
            monotonicDuration: 2400
        )
        let timeline = EpisodeBuilder.build(
            intervals: [stepped], sessions: [declared], dayStart: anchor
        )

        #expect(timeline.episodeCount == 3)
        #expect(timeline.trackedDuration == 2400.0)
        #expect(timeline.episodes.allSatisfy { $0.activeDuration >= 0 })
        #expect(largestHole(in: timeline) == 0.0)
    }
}

// MARK: - Evidence attribution

@Suite("Episode builder: where the evidence is credited")
struct EpisodeBuilderEvidenceTests {

    @Test("A brief run that touches nothing keeps its own evidence instead of donating it")
    func anIsolatedBriefRunDoesNotDonateItsEvidenceToADistantBlock() {
        // One second of the browser at nine in the morning and an hour of the editor at two in the
        // afternoon. Crediting the second to the afternoon makes a block that starts at 14:00 claim
        // two intervals of evidence, one of which happened five hours earlier, and erases the only
        // thing anybody observed that morning.
        let intervals = [
            sample(App.chrome, at: moment(9, 0), seconds: 1),
            sample(App.xcode, at: moment(14, 0), seconds: 3600),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        #expect(timeline.episodeCount == 2)
        #expect(timeline.episodes.last?.start == moment(14, 0))
        #expect(timeline.episodes.last?.intervalCount == 1)
        #expect(timeline.episodes.first?.intervalCount == 1)
        #expect(timeline.episodes.first?.apps.first?.bundleIdentifier == App.chrome)
        #expect(timeline.unexplainedDuration == 17_999.0)
        #expect(largestHole(in: timeline) == 0.0)
    }

    @Test("A brief run that does touch its neighbour is still folded into it")
    func anAbuttingBriefRunIsStillFolded() {
        // The control: the fold still happens where the two really are one stretch of sampling.
        let intervals = [
            sample(App.xcode, at: moment(9, 0), seconds: 1200),
            sample(App.chrome, at: moment(9, 20), seconds: 1),
            sample(App.terminal, at: moment(9, 20, 1), seconds: 1200),
        ]
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)

        #expect(timeline.episodeCount == 1)
        #expect(timeline.episodes.first?.intervalCount == 3)
        #expect(timeline.episodes.first?.apps.count == 2)
        #expect(timeline.trackedDuration == 2400.0)
    }
}

// MARK: - Tiling

@Suite("Episode builder: the timeline accounts for the span it covers")
struct EpisodeBuilderTilingTests {

    /// Every day the suite knows about, tidy and untidy alike.
    private static func days() -> [(String, DayTimeline)] {
        var result: [(String, DayTimeline)] = DayFixtures.allDays.map {
            (
                $0.claim,
                EpisodeBuilder.build(
                    intervals: $0.intervals,
                    absences: $0.absences,
                    sessions: $0.sessions,
                    weights: $0.weights,
                    dayStart: $0.expected.dayStart,
                    sealed: $0.expected.sealed
                )
            )
        }

        result.append(
            (
                "a four-minute silence",
                EpisodeBuilder.build(
                    intervals: [
                        sample(App.xcode, at: moment(9, 0), seconds: 1800),
                        sample(App.xcode, at: moment(9, 34), seconds: 1800),
                    ],
                    dayStart: anchor
                )
            ))
        result.append(
            (
                "stillness three hours apart",
                EpisodeBuilder.build(
                    intervals: [
                        sample(App.xcode, at: moment(9, 0), seconds: 60, isIdle: true),
                        sample(App.xcode, at: moment(12, 0), seconds: 60, isIdle: true),
                    ],
                    dayStart: anchor
                )
            ))
        result.append(
            (
                "a night whose heartbeat gap contains the sleep",
                EpisodeBuilder.build(
                    intervals: [
                        sample(App.xcode, at: moment(17, 0), seconds: 3600),
                        sample(App.xcode, at: moment(33, 12, 40), seconds: 3600),
                    ],
                    absences: [
                        Gap(reason: .systemSleep, start: moment(18, 4), end: moment(33, 12)),
                        Gap(
                            reason: .appNotRunning, start: moment(18, 3, 20),
                            end: moment(33, 12, 40)
                        ),
                    ],
                    dayStart: anchor
                )
            ))
        result.append(
            (
                "an interval a crash cut short",
                EpisodeBuilder.build(
                    intervals: [
                        sample(App.xcode, at: moment(13, 0), seconds: 4800),
                        sample(App.xcode, at: moment(14, 20), seconds: 720),
                        sample(App.xcode, at: moment(16, 10), seconds: 3600),
                    ],
                    absences: [
                        Gap(reason: .appNotRunning, start: moment(14, 30), end: moment(16, 10))
                    ],
                    dayStart: anchor
                )
            ))
        return result
    }

    @Test("Between the first row and the last, no instant belongs to nothing")
    func timelinesLeaveNoHole() {
        // The invariant the whole design rests on, and the one the fixture days cannot test because
        // their intervals abut exactly. Every instant between the start of the first row and the end
        // of the last is inside a block or inside a named absence. There is no third state, and a
        // stretch that reached neither would be time the app silently dropped.
        for (claim, timeline) in Self.days() {
            #expect(largestHole(in: timeline) == 0.0, Comment(rawValue: claim))
        }
    }

    @Test("No block ever overlaps another block or an absence")
    func timelinesDoNotOverlap() {
        for (claim, timeline) in Self.days() {
            #expect(largestOverlap(in: timeline) == 0.0, Comment(rawValue: claim))
        }
    }

    @Test("No block is ever longer on the clock than the span its evidence covers")
    func noBlockOutrunsItsEvidence() {
        for (claim, timeline) in Self.days() {
            for episode in timeline.episodes {
                #expect(episode.activeDuration <= episode.wallClockSpan, Comment(rawValue: claim))
            }
        }
    }
}

// MARK: - The fixture claims, made falsifiable

@Suite("Episode builder: the fixture claims can fail")
struct EpisodeBuilderClaimFalsifiabilityTests {

    private func rebuild(_ fixture: DayFixtures.DayFixture, sessions: [FocusSession]) -> DayTimeline {
        EpisodeBuilder.build(
            intervals: fixture.intervals,
            absences: fixture.absences,
            sessions: sessions,
            weights: fixture.weights,
            dayStart: fixture.expected.dayStart,
            sealed: fixture.expected.sealed
        )
    }

    @Test("`labelsNameApplicationsOnly` is a claim about the day, not a property of the checker")
    func labelsNameApplicationsOnlyCanFail() {
        // The manager's day carries no sessions, so nothing on it can reach the one naming rule that
        // produces a sentence — which makes the claim pass whatever the builder does. Declare a
        // session over it and the claim must fail, or it was never testing anything.
        let manager = DayFixtures.fragmentedManagerDay
        let declared = FocusSession(
            intendedOutcome: "Quarterly planning review",
            workType: .meeting,
            startedAt: DayFixtures.time(12, 45),
            endedAt: DayFixtures.time(14, 30)
        )

        let untouched = rebuild(manager, sessions: [])
        let named = rebuild(manager, sessions: [declared])

        #expect(DayFixtures.Claim.labelsNameApplicationsOnly.holds(in: untouched))
        #expect(!DayFixtures.Claim.labelsNameApplicationsOnly.holds(in: named))
        #expect(named.episodes.contains { $0.label == "Quarterly planning review" })
        #expect(named.episodes.contains { $0.labelConfidence == .declared })
    }

    @Test("`labelConfidenceAtMost(.category)` is a claim about the day too")
    func labelConfidenceCeilingCanFail() {
        let manager = DayFixtures.fragmentedManagerDay
        let declared = FocusSession(
            intendedOutcome: "Quarterly planning review",
            workType: .meeting,
            startedAt: DayFixtures.time(12, 45),
            endedAt: DayFixtures.time(14, 30)
        )

        #expect(DayFixtures.Claim.labelConfidenceAtMost(.category).holds(in: rebuild(manager, sessions: [])))
        #expect(
            !DayFixtures.Claim.labelConfidenceAtMost(.category)
                .holds(in: rebuild(manager, sessions: [declared]))
        )
    }

    @Test("The manager's day lands on exactly six blocks, not merely somewhere inside one and eight")
    func theManagerDayHasExactlySixBlocks() {
        // `episodeCount(1...8)` cannot fail on the low side: one block is what a builder that gave up
        // and merged everything would produce, and the claim would still pass. The designed answer is
        // six, and six is what is asserted here.
        let timeline = rebuild(DayFixtures.fragmentedManagerDay, sessions: [])
        #expect(timeline.episodeCount == 6)
    }

    @Test("`noGap(.appNotRunning)` on the overnight day is a claim the builder could break")
    func theOvernightNoCrashClaimCanFail() {
        // The fixture supplies no heartbeat gap at all, so the claim holds by arithmetic. Supply one
        // the sleep does not explain and it must fail — which is what makes it worth asserting on the
        // day where the sleep does explain it.
        let night = DayFixtures.overnightSleepDay
        let strayCrash = Gap(
            reason: .appNotRunning,
            start: DayFixtures.nextDayTime(10, 5),
            end: DayFixtures.nextDayTime(10, 15)
        )
        let built = EpisodeBuilder.build(
            intervals: night.intervals,
            absences: night.absences + [strayCrash],
            sessions: night.sessions,
            weights: night.weights,
            dayStart: night.expected.dayStart,
            sealed: night.expected.sealed
        )

        #expect(DayFixtures.Claim.noGap(reason: .appNotRunning).holds(in: rebuild(night, sessions: [])))
        #expect(!DayFixtures.Claim.noGap(reason: .appNotRunning).holds(in: built))
    }
}

// MARK: - Scale

@Suite("Episode builder: a day the sampler had a bad time with still finishes")
struct EpisodeBuilderScaleTests {

    /// Generous by two orders of magnitude against the shapes that used to be quadratic — those took
    /// between seventy seconds and forever — and by more than thirty against what these now measure
    /// in a debug build. A machine under load will not fail this; a reintroduced quadratic will.
    private static let budget: TimeInterval = 20

    @Test("Thirty-two thousand intervals that measured no monotonic time at all still finish")
    func zeroMonotonicDurationDoesNotGoQuadratic() {
        // The monotonic clock does not advance while the machine is asleep, so a run of intervals
        // measuring zero seconds each is a real thing to be handed. Anything that walks forward by
        // adding those durations up never gets anywhere, and every boundary on the day ends up
        // rescanning the whole tail behind it.
        let intervals = (0..<32_000).map { index in
            sample(
                "com.example.app\(index)",
                at: anchor.addingTimeInterval(TimeInterval(index)),
                seconds: 1,
                monotonic: 0
            )
        }

        let started = Date()
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < Self.budget, Comment(rawValue: "took \(elapsed)s"))
        #expect(!timeline.episodes.isEmpty)
        #expect(timeline.trackedDuration == 0.0)
    }

    @Test("Fifty thousand short activations separated by silence still finish")
    func aDayOfNothingButUnexplainedGapsStaysLinear() {
        // Every boundary on this day carries an unexplained gap, so the gap list is as long as the
        // run list. Searching one for each element of the other is quadratic in the only case that
        // produces the most of both.
        let intervals = (0..<50_000).map { index in
            sample(
                "com.example.app\(index % 5)",
                at: anchor.addingTimeInterval(TimeInterval(index) * 460),
                seconds: 60
            )
        }

        let started = Date()
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < Self.budget, Comment(rawValue: "took \(elapsed)s"))
        #expect(timeline.gaps(for: .unexplained).count == 49_999)
        #expect(timeline.episodeCount == 50_000)
    }

    @Test("Four thousand intervals against four thousand recorded absences still finish")
    func manyAbsencesStayLinear() {
        let intervals = (0..<4_000).map { index in
            sample(App.xcode, at: anchor.addingTimeInterval(TimeInterval(index) * 200), seconds: 60)
        }
        let absences = (0..<4_000).map { index in
            Gap(
                reason: .screenLocked,
                start: anchor.addingTimeInterval(TimeInterval(index) * 200 + 60),
                end: anchor.addingTimeInterval(TimeInterval(index) * 200 + 200)
            )
        }

        let started = Date()
        let timeline = EpisodeBuilder.build(
            intervals: intervals, absences: absences, dayStart: anchor
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < Self.budget, Comment(rawValue: "took \(elapsed)s"))
        #expect(timeline.gaps(for: .screenLocked).count == 4_000)
        #expect(timeline.unexplainedDuration == 0.0)
    }

    @Test("A realistic fifty-thousand-interval day is still one block")
    func aLongRealisticDayIsUnchanged() {
        let intervals = (0..<50_000).map { index in
            sample(
                "com.example.app\(index % 8)",
                at: anchor.addingTimeInterval(TimeInterval(index) * 30),
                seconds: 30
            )
        }

        let started = Date()
        let timeline = EpisodeBuilder.build(intervals: intervals, dayStart: anchor)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < Self.budget, Comment(rawValue: "took \(elapsed)s"))
        #expect(timeline.trackedDuration == 1_500_000.0)
        #expect(largestHole(in: timeline) == 0.0)
    }
}
