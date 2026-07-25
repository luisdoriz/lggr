import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing, not decoration. `#expect` compares an
/// `Optional<Double>` against an integer-literal expression such as `54 * 60` by type as well as by
/// value, so that comparison reports a failure even when the numbers are identical. Routing every
/// duration through this helper keeps both sides of the comparison `Double`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 00:00:00 UTC, the same anchor the fixture days use. Fixed so a failure reproduces
/// identically on any machine, in any timezone, on any day of the year.
private let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
}

private enum Bundle {
    static let xcode = "com.apple.dt.Xcode"
    static let terminal = "com.apple.Terminal"
    static let chrome = "com.google.Chrome"
    static let slack = "com.tinyspeck.slackmacgap"
    static let zoom = "us.zoom.xos"
}

private func displayName(_ bundleIdentifier: String) -> String {
    switch bundleIdentifier {
    case Bundle.xcode: "Xcode"
    case Bundle.terminal: "Terminal"
    case Bundle.chrome: "Chrome"
    case Bundle.slack: "Slack"
    case Bundle.zoom: "Zoom"
    default: bundleIdentifier
    }
}

/// One block, dominated by `bundleIdentifier`, with its whole span credited to that application.
private func block(
    _ bundleIdentifier: String,
    from start: Date,
    minutes span: Double,
    label: String? = nil
) -> Episode {
    let duration = minutes(span)
    return Episode(
        start: start,
        end: start.addingTimeInterval(duration),
        apps: [
            Episode.AppShare(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName(bundleIdentifier),
                duration: duration,
                visitCount: 1
            )
        ],
        label: label ?? displayName(bundleIdentifier),
        labelConfidence: .appRoster,
        intervalCount: 1
    )
}

/// Contiguous blocks, one after another with no silence between them.
private func chain(_ steps: [(String, Double)], from start: Date) -> [Episode] {
    var result: [Episode] = []
    var cursor = start
    for (bundleIdentifier, span) in steps {
        result.append(block(bundleIdentifier, from: cursor, minutes: span))
        cursor = cursor.addingTimeInterval(minutes(span))
    }
    return result
}

private func timeline(_ episodes: [Episode], gaps: [Gap] = []) -> DayTimeline {
    DayTimeline(dayStart: dayStart, episodes: episodes, gaps: gaps)
}

/// The application that dominates the run at `index`, or nothing if there is no such run.
private func runApp(_ shape: ShapeOfWork, _ index: Int) -> String? {
    guard shape.runs.indices.contains(index) else { return nil }
    return shape.runs[index].app.bundleIdentifier
}

// MARK: - The empty and the trivial

@Suite("Shape of work — the degenerate days")
struct ShapeOfWorkEdgeTests {

    /// A day with nothing in it produces nothing. Not a zero, not an empty ranking that reads as one
    /// — the caller must be able to tell "nobody worked" from "we could not tell", and only `nil`
    /// says the first.
    @Test("An empty day has no shape at all")
    func emptyDay() {
        let shape = ShapeOfWork(timeline([]))

        #expect(shape.isEmpty)
        #expect(shape.runs.isEmpty)
        #expect(shape.excursions.isEmpty)
        #expect(shape.alternations.isEmpty)
        #expect(shape.interruptions.isEmpty)
        #expect(shape.longestRun == nil)
        #expect(shape.longestRuns(3).isEmpty)
        #expect(shape.dominantAlternation == nil)
        #expect(shape.appInterruptingEveryLongestRun(3) == nil)
        #expect(shape.runDuration == 0)
        #expect(shape.interruptedRunCount == 0)
        #expect(shape.appsByRunDuration().isEmpty)
    }

    @Test("The default shape is the empty one")
    func defaultIsEmpty() {
        #expect(ShapeOfWork() == ShapeOfWork(timeline([])))
    }

    /// A day with a gap and no blocks is still a day with no shape: an absence is not a run, and
    /// nothing here may invent one to fill it.
    @Test("A day that is only a gap has no runs")
    func onlyAGap() {
        let shape = ShapeOfWork(
            timeline([], gaps: [Gap(reason: .systemSleep, start: at(9, 0), end: at(17, 0))])
        )
        #expect(shape.isEmpty)
        #expect(shape.longestRun == nil)
    }

    @Test("A single block is one run and nothing else")
    func singleEpisode() {
        let shape = ShapeOfWork(timeline([block(Bundle.xcode, from: at(9, 4), minutes: 54)]))

        #expect(shape.runs.count == 1)
        #expect(shape.longestRun?.app.bundleIdentifier == Bundle.xcode)
        #expect(shape.longestRun?.app.displayName == "Xcode")
        #expect(shape.longestRun?.activeDuration == minutes(54))
        #expect(shape.longestRun?.episodeCount == 1)
        #expect(shape.longestRun?.start == at(9, 4))
        #expect(shape.longestRun?.end == at(9, 58))
        #expect(shape.longestRun?.interruptedBy == nil)
        #expect(shape.longestRun?.wasInterrupted == false)

        // One block cannot leave and come back, and cannot alternate with anything.
        #expect(shape.excursions.isEmpty)
        #expect(shape.alternations.isEmpty)
        #expect(shape.interruptions.isEmpty)
        #expect(shape.interruptedRunCount == 0)
    }

    /// "The three longest runs" is a false sentence on a day that contains two, so the affordance
    /// that would produce it returns nothing rather than the best two-thirds of a claim.
    @Test("A day with fewer runs than asked for makes no claim about them")
    func refusesToClaimRunsThatDoNotExist() {
        let shape = ShapeOfWork(
            timeline(chain([(Bundle.xcode, 20), (Bundle.slack, 5), (Bundle.xcode, 20)], from: at(9, 0)))
        )

        #expect(shape.runs.count == 3)
        #expect(shape.longestRuns(9).count == 3)
        #expect(shape.longestRuns(0).isEmpty)
        #expect(shape.appInterruptingEveryLongestRun(4) == nil)
        #expect(shape.appInterruptingEveryLongestRun(0) == nil)
    }

    /// A block that recorded no application says nothing about what was in front of anybody.
    /// Inventing a break out of it would shorten a run on no evidence at all.
    @Test("A block with no applications is passed over without breaking a run")
    func blockWithNoApps() {
        let empty = Episode(
            start: at(9, 30),
            end: at(9, 31),
            apps: [],
            label: "",
            labelConfidence: .appRoster
        )
        let shape = ShapeOfWork(
            timeline(
                [
                    block(Bundle.xcode, from: at(9, 0), minutes: 30),
                    empty,
                    block(Bundle.xcode, from: at(9, 31), minutes: 30),
                ]
            )
        )

        #expect(shape.runs.count == 1)
        #expect(shape.longestRun?.episodeCount == 2)
        #expect(shape.longestRun?.activeDuration == minutes(60))
    }
}

// MARK: - Runs

@Suite("Shape of work — unbroken runs")
struct ShapeOfWorkRunTests {

    @Test("A day that is one unbroken run reports one run and its whole length")
    func oneUnbrokenRun() {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [(Bundle.xcode, 30), (Bundle.xcode, 40), (Bundle.xcode, 50)],
                    from: at(9, 0)
                )
            )
        )

        #expect(shape.runs.count == 1)
        #expect(shape.longestRun?.activeDuration == minutes(120))
        #expect(shape.longestRun?.episodeCount == 3)
        #expect(shape.longestRun?.start == at(9, 0))
        #expect(shape.longestRun?.end == at(11, 0))
        #expect(shape.excursions.isEmpty)
        #expect(shape.alternations.isEmpty)
        #expect(shape.runDuration == minutes(120))
    }

    /// Idle is forgeable — any process can zero the system idle timer, and Screen Sharing, mouse
    /// jigglers and remote-control sessions all do it in ordinary use. A run that any idle stretch
    /// ended would be a run a background process could lengthen, so frontmost continuity defines it
    /// and idle does not.
    @Test("An idle stretch does not end a run")
    func idleDoesNotSever() {
        let shape = ShapeOfWork(
            timeline(
                [
                    block(Bundle.xcode, from: at(9, 0), minutes: 30),
                    block(Bundle.xcode, from: at(9, 40), minutes: 30),
                ],
                gaps: [Gap(reason: .idle, start: at(9, 30), end: at(9, 40))]
            )
        )

        #expect(shape.runs.count == 1)
        #expect(shape.longestRun?.activeDuration == minutes(60))
        #expect(shape.longestRun?.wallClockSpan == minutes(70))
    }

    @Test(
        "Anything the app did not observe ends a run",
        arguments: [
            GapReason.systemSleep, .displayOff, .screenLocked, .fastUserSwitched,
            .appNotRunning, .trackingPaused, .excludedApplication, .unexplained,
        ]
    )
    func hardGapsSever(reason: GapReason) {
        let shape = ShapeOfWork(
            timeline(
                [
                    block(Bundle.xcode, from: at(9, 0), minutes: 30),
                    block(Bundle.xcode, from: at(13, 0), minutes: 30),
                ],
                gaps: [Gap(reason: reason, start: at(9, 30), end: at(13, 0))]
            )
        )

        #expect(shape.runs.count == 2)
        #expect(shape.longestRun?.activeDuration == minutes(30))
        // Nothing was observed across the gap, so nothing crossed it: no transition, no excursion.
        #expect(shape.alternations.isEmpty)
        #expect(shape.excursions.isEmpty)
    }

    /// Lunch between two stretches of the same work is a break, not a run. Joining them would be the
    /// confabulation the gap exists to prevent, wearing a longer number.
    @Test("The same application either side of a hard gap is two runs, not one")
    func sameAppAcrossAGapIsTwoRuns() {
        let shape = ShapeOfWork(
            timeline(
                [
                    block(Bundle.xcode, from: at(9, 0), minutes: 60),
                    block(Bundle.xcode, from: at(13, 0), minutes: 90),
                ],
                gaps: [Gap(reason: .appNotRunning, start: at(10, 0), end: at(13, 0))]
            )
        )

        #expect(shape.runs.count == 2)
        #expect(shape.longestRun?.activeDuration == minutes(90))
        #expect(shape.runs.first?.activeDuration == minutes(60))
    }

    /// Every duration here comes from the blocks' own monotonic measurements. Wall clock places a
    /// run on the timeline; it never measures one, or a clock step would inflate a morning.
    @Test("A run is as long as the work in it, not as long as the clock says")
    func measuresWorkNotWallClock() {
        let sparse = Episode(
            start: at(9, 0),
            end: at(10, 0),
            apps: [
                Episode.AppShare(
                    bundleIdentifier: Bundle.xcode,
                    displayName: "Xcode",
                    duration: minutes(22),
                    visitCount: 1
                )
            ],
            label: "Xcode",
            labelConfidence: .appRoster
        )
        let shape = ShapeOfWork(timeline([sparse]))

        #expect(shape.longestRun?.activeDuration == minutes(22))
        #expect(shape.longestRun?.wallClockSpan == minutes(60))
    }

    @Test("Ties between equally long runs go to the earlier one, every time")
    func tiesAreDeterministic() {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [(Bundle.xcode, 30), (Bundle.chrome, 30), (Bundle.zoom, 30)],
                    from: at(9, 0)
                )
            )
        )

        #expect(shape.longestRun?.start == at(9, 0))
        #expect(shape.longestRuns(3).map(\.start) == [at(9, 0), at(9, 30), at(10, 0)])
        // Asking twice gives the same answer, because nothing here reads a random source.
        #expect(ShapeOfWork(timeline(chain(
            [(Bundle.xcode, 30), (Bundle.chrome, 30), (Bundle.zoom, 30)], from: at(9, 0)
        ))) == shape)
    }

    @Test("Total run time is exactly the day's tracked time")
    func runsAccountForEveryBlock() {
        let day = timeline(
            chain(
                [
                    (Bundle.xcode, 40), (Bundle.slack, 6), (Bundle.xcode, 35),
                    (Bundle.chrome, 12), (Bundle.zoom, 30),
                ],
                from: at(9, 0)
            )
        )
        let shape = ShapeOfWork(day)
        #expect(shape.runDuration == day.trackedDuration)
    }
}

// MARK: - Excursions, alternation and interruption

@Suite("Shape of work — leaving and coming back")
struct ShapeOfWorkExcursionTests {

    @Test("Leaving an application and coming back is one excursion and one interruption")
    func excursionAndReturn() {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [(Bundle.xcode, 40), (Bundle.slack, 6), (Bundle.xcode, 35)],
                    from: at(9, 0)
                )
            )
        )

        #expect(shape.runs.count == 3)
        #expect(shape.excursions.count == 1)
        #expect(shape.excursions.first?.from.bundleIdentifier == Bundle.xcode)
        #expect(shape.excursions.first?.to.bundleIdentifier == Bundle.slack)
        #expect(shape.excursions.first?.count == 1)
        #expect(shape.excursions.first?.totalAway == minutes(6))
        #expect(shape.excursions.first?.medianAway == minutes(6))

        #expect(shape.interruptions.count == 1)
        #expect(shape.interruptions.first?.app.displayName == "Slack")
        #expect(shape.interruptions.first?.count == 1)
        #expect(shape.interruptions.first?.interruptedDuration == minutes(40))

        // The interruption is recorded on the run it interrupted, not only in a table beside it.
        #expect(shape.runs.first?.interruptedBy?.bundleIdentifier == Bundle.slack)
        #expect(shape.runs.last?.interruptedBy == nil)
        #expect(shape.interruptedRunCount == 1)
    }

    /// Moving on is not being interrupted. Counting it as one would let "Slack interrupted you nine
    /// times" include the nine times the day simply finished in Slack — a claim about a return that
    /// never happened.
    @Test("Moving on to something else is not an interruption")
    func movingOnIsNotAnInterruption() {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [(Bundle.xcode, 40), (Bundle.slack, 20), (Bundle.zoom, 30)],
                    from: at(9, 0)
                )
            )
        )

        #expect(shape.runs.count == 3)
        #expect(shape.excursions.isEmpty)
        #expect(shape.interruptions.isEmpty)
        #expect(shape.interruptedRunCount == 0)
        // Two moves still happened, and they are still reported as moves.
        #expect(shape.alternations.count == 2)
        #expect(shape.alternations.allSatisfy { $0.cycles == 0 })
    }

    /// A return that only happens after a gap is not a return: the app did not observe what came in
    /// between, and claiming continuity across it would be the confabulation gaps exist to prevent.
    @Test("An excursion that ends after a gap is not an excursion")
    func gapBreaksTheReturn() {
        let shape = ShapeOfWork(
            timeline(
                [
                    block(Bundle.xcode, from: at(9, 0), minutes: 40),
                    block(Bundle.slack, from: at(9, 40), minutes: 6),
                    block(Bundle.xcode, from: at(13, 0), minutes: 35),
                ],
                gaps: [Gap(reason: .systemSleep, start: at(9, 46), end: at(13, 0))]
            )
        )

        #expect(shape.runs.count == 3)
        #expect(shape.excursions.isEmpty)
        #expect(shape.interruptions.isEmpty)
        #expect(shape.alternations.count == 1)
        #expect(shape.alternations.first?.transitions == 1)
        #expect(shape.alternations.first?.cycles == 0)
    }

    @Test("Leaving Xcode for Slack and leaving Slack for Xcode are two different habits")
    func directionMatters() throws {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [
                        (Bundle.xcode, 20), (Bundle.slack, 4), (Bundle.xcode, 20),
                        (Bundle.slack, 4), (Bundle.xcode, 20), (Bundle.slack, 4),
                        (Bundle.xcode, 20),
                    ],
                    from: at(9, 0)
                )
            )
        )

        #expect(shape.excursions.count == 2)
        let out = try #require(shape.excursions.first { $0.to.bundleIdentifier == Bundle.slack })
        let back = try #require(shape.excursions.first { $0.to.bundleIdentifier == Bundle.xcode })
        #expect(out.count == 3)
        #expect(out.from.bundleIdentifier == Bundle.xcode)
        #expect(back.count == 2)
        #expect(back.from.bundleIdentifier == Bundle.slack)
    }

    /// The median is not the mean, and the difference is the whole reason it is the median: one long
    /// detour must not be allowed to describe eleven short glances.
    @Test("Time away is reported as a median, not an average")
    func awayIsAMedian() throws {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [
                        (Bundle.xcode, 20), (Bundle.slack, 1), (Bundle.xcode, 20),
                        (Bundle.slack, 1), (Bundle.xcode, 20), (Bundle.slack, 40),
                        (Bundle.xcode, 20),
                    ],
                    from: at(9, 0)
                )
            )
        )

        let out = try #require(shape.excursions.first { $0.to.bundleIdentifier == Bundle.slack })
        #expect(out.count == 3)
        #expect(out.totalAway == minutes(42))
        #expect(out.medianAway == minutes(1))
    }

    /// The sentence this exists to license — *"Slack interrupted the three longest runs"* — is only
    /// ever produced when it is literally true of all three. A "mostly" version reads identically to
    /// a reader and is a different claim.
    @Test("One application interrupting every longest run can be named; a mixture cannot")
    func namesOnlyAUnanimousInterrupter() {
        let unanimous = ShapeOfWork(
            timeline(
                chain(
                    [
                        (Bundle.xcode, 50), (Bundle.slack, 3), (Bundle.xcode, 45),
                        (Bundle.slack, 3), (Bundle.xcode, 40), (Bundle.slack, 3),
                        (Bundle.xcode, 5),
                    ],
                    from: at(9, 0)
                )
            )
        )
        #expect(unanimous.appInterruptingEveryLongestRun(3)?.displayName == "Slack")
        #expect(unanimous.interruptions.first?.count == 3)

        let mixed = ShapeOfWork(
            timeline(
                chain(
                    [
                        (Bundle.xcode, 50), (Bundle.slack, 3), (Bundle.xcode, 45),
                        (Bundle.chrome, 3), (Bundle.xcode, 40), (Bundle.slack, 3),
                        (Bundle.xcode, 5),
                    ],
                    from: at(9, 0)
                )
            )
        )
        #expect(mixed.appInterruptingEveryLongestRun(3) == nil)
        #expect(mixed.appInterruptingEveryLongestRun(1)?.displayName == "Slack")
    }

    @Test("Interruption sources rank by how often they interrupted")
    func interruptionRanking() {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [
                        (Bundle.xcode, 20), (Bundle.slack, 2), (Bundle.xcode, 20),
                        (Bundle.chrome, 9), (Bundle.xcode, 20), (Bundle.slack, 2),
                        (Bundle.xcode, 20),
                    ],
                    from: at(9, 0)
                )
            )
        )

        #expect(shape.interruptions.map(\.app.displayName) == ["Slack", "Chrome"])
        #expect(shape.interruptions.first?.count == 2)
        #expect(shape.interruptions.first?.totalAway == minutes(4))
        #expect(shape.interruptions.last?.count == 1)
        #expect(shape.interruptions.last?.totalAway == minutes(9))
    }
}

// MARK: - Alternation

@Suite("Shape of work — alternation")
struct ShapeOfWorkAlternationTests {

    /// A review loop — editor to browser and back, over and over — is invisible in any single block,
    /// because collapsing it is the segmenter's whole job. It shows up here or nowhere.
    @Test("A day that is nothing but alternation is reported as one rhythm")
    func pureAlternation() {
        var steps: [(String, Double)] = []
        for index in 0..<40 {
            steps.append((index.isMultiple(of: 2) ? Bundle.xcode : Bundle.chrome, 3))
        }
        let shape = ShapeOfWork(timeline(chain(steps, from: at(9, 0))))

        #expect(shape.runs.count == 40)
        #expect(shape.alternations.count == 1)

        let rhythm = shape.dominantAlternation
        #expect(rhythm?.transitions == 39)
        #expect(rhythm?.cycles == 38)
        #expect(rhythm?.medianAway == minutes(3))
        // The pair is unordered and canonicalised on the bundle identifier, so {A, B} and {B, A}
        // are the same row however the day happened to move between them.
        #expect(rhythm?.first.bundleIdentifier == Bundle.xcode)
        #expect(rhythm?.second.bundleIdentifier == Bundle.chrome)

        // Both directions of the round trip are counted, and they are counted separately.
        #expect(shape.excursions.count == 2)
        #expect(shape.excursions.map(\.count).reduce(0, +) == 38)
        #expect(shape.interruptions.count == 2)

        // Every run is the same length, so the longest three are the first three — and they were
        // not all interrupted by the same application, so nothing is claimed about them.
        #expect(shape.longestRuns(3).count == 3)
        #expect(shape.appInterruptingEveryLongestRun(3) == nil)
    }

    @Test("Two applications that follow each other once have a transition and no rhythm")
    func oneTransitionIsNotARhythm() {
        let shape = ShapeOfWork(
            timeline(chain([(Bundle.xcode, 30), (Bundle.chrome, 30)], from: at(9, 0)))
        )

        #expect(shape.alternations.count == 1)
        #expect(shape.alternations.first?.transitions == 1)
        #expect(shape.alternations.first?.cycles == 0)
        #expect(shape.dominantAlternation == nil)
    }

    @Test("Alternations rank by how much moving there was")
    func alternationRanking() {
        var steps: [(String, Double)] = []
        for _ in 0..<6 { steps.append(contentsOf: [(Bundle.xcode, 4), (Bundle.chrome, 4)]) }
        steps.append(contentsOf: [(Bundle.zoom, 10), (Bundle.slack, 5), (Bundle.zoom, 10)])
        let shape = ShapeOfWork(timeline(chain(steps, from: at(9, 0))))

        let ranked = shape.alternations
        #expect(ranked.count >= 2)
        #expect(ranked.first?.transitions == 11)
        #expect(ranked.first?.cycles == 10)
        #expect(
            Set([ranked.first?.first.bundleIdentifier, ranked.first?.second.bundleIdentifier])
                == Set([Bundle.chrome, Bundle.xcode])
        )
        // Ranking is by movement, so the heavier rhythm outranks the single round trip.
        #expect((ranked.first?.transitions ?? 0) > (ranked.last?.transitions ?? 0))
    }
}

// MARK: - Scale

@Suite("Shape of work — scale")
struct ShapeOfWorkScaleTests {

    private func alternatingDay(blocks: Int) -> DayTimeline {
        var steps: [(String, Double)] = []
        steps.reserveCapacity(blocks)
        for index in 0..<blocks {
            steps.append((index.isMultiple(of: 2) ? Bundle.xcode : Bundle.chrome, 1))
        }
        return timeline(chain(steps, from: at(0, 0)))
    }

    /// Five thousand blocks, which no real day has. The point is not the day; it is that the answer
    /// is exact and arrives, which a quadratic implementation would not manage.
    @Test("A five-thousand-block day is read exactly, and in one pass")
    func fiveThousandBlocks() {
        let shape = ShapeOfWork(alternatingDay(blocks: 5_000))

        #expect(shape.runs.count == 5_000)
        #expect(shape.runDuration == minutes(5_000))
        #expect(shape.alternations.count == 1)
        #expect(shape.dominantAlternation?.transitions == 4_999)
        #expect(shape.dominantAlternation?.cycles == 4_998)
        #expect(shape.excursions.count == 2)
        #expect(shape.excursions.map(\.count).reduce(0, +) == 4_998)
        #expect(shape.interruptions.count == 2)
        #expect(shape.interruptedRunCount == 4_998)
        #expect(shape.longestRun?.start == at(0, 0))
    }

    /// The single-pass claim, made falsifiable. Eight times the day costs roughly eight times the
    /// work; a quadratic implementation would cost sixty-four. The bound is loose enough that a
    /// loaded machine cannot fail it and tight enough that a nested loop over the day cannot pass.
    @Test("Eight times the day does not cost sixty-four times the work")
    func scalesLinearly() {
        let small = alternatingDay(blocks: 1_250)
        let large = alternatingDay(blocks: 10_000)

        // Warm the code paths so the measurement is of the work rather than of first use.
        _ = ShapeOfWork(small)
        _ = ShapeOfWork(large)

        let smallStart = Date()
        for _ in 0..<4 { _ = ShapeOfWork(small) }
        let smallElapsed = Date().timeIntervalSince(smallStart) / 4

        let largeStart = Date()
        let shape = ShapeOfWork(large)
        let largeElapsed = Date().timeIntervalSince(largeStart)

        #expect(shape.runs.count == 10_000)
        // The floor keeps a sub-millisecond baseline from turning scheduler noise into a failure.
        #expect(largeElapsed < max(0.5, smallElapsed * 24))
    }

    /// The other end of the pipeline: five thousand raw activations, through the proven segmenter,
    /// and out into a shape. Whatever the segmenter decides the blocks are, the runs account for
    /// every second of them and no second is counted twice.
    @Test("Five thousand sampled intervals become a day with a readable shape")
    func fiveThousandIntervals() {
        var intervals: [ActivityInterval] = []
        intervals.reserveCapacity(5_000)
        var cursor = at(0, 0)

        for index in 0..<5_000 {
            let bundleIdentifier: String
            switch index % 5 {
            case 0, 1, 2: bundleIdentifier = Bundle.xcode
            case 3: bundleIdentifier = Bundle.terminal
            default: bundleIdentifier = Bundle.slack
            }
            let seconds: TimeInterval = index % 7 == 0 ? 45 : 20
            intervals.append(
                ActivityInterval(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName(bundleIdentifier),
                    start: cursor,
                    end: cursor.addingTimeInterval(seconds),
                    monotonicDuration: seconds,
                    tzOffsetMinutes: 0
                )
            )
            cursor = cursor.addingTimeInterval(seconds)
        }

        let day = EpisodeBuilder.build(intervals: intervals)
        let shape = ShapeOfWork(day)

        #expect(!shape.isEmpty)
        #expect(shape.runs.count <= day.episodes.count)
        #expect(shape.runDuration == day.trackedDuration)
        #expect(shape.longestRun != nil)
        // Runs are in timeline order and never overlap.
        for pair in zip(shape.runs, shape.runs.dropFirst()) {
            #expect(pair.0.start <= pair.1.start)
            #expect(pair.0.end <= pair.1.start)
        }
        // Rebuilding the same day gives the same shape: nothing here reads a clock or a random
        // source, so a sealed day re-derives identically.
        #expect(ShapeOfWork(EpisodeBuilder.build(intervals: intervals)) == shape)
    }

    @Test("Every application that ran appears in the run ranking, most time first")
    func appRanking() {
        let shape = ShapeOfWork(
            timeline(
                chain(
                    [
                        (Bundle.xcode, 40), (Bundle.slack, 6), (Bundle.xcode, 35),
                        (Bundle.chrome, 12),
                    ],
                    from: at(9, 0)
                )
            )
        )

        let ranked = shape.appsByRunDuration()
        #expect(ranked.map(\.app.displayName) == ["Xcode", "Chrome", "Slack"])
        #expect(ranked.first?.duration == minutes(75))
        #expect(runApp(shape, 0) == Bundle.xcode)
    }
}
