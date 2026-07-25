import Foundation

@testable import LggrKit

// Four days, written by hand before the builder exists.
//
// These are not test data. Each one is a design claim about what a person recognises as a block,
// written down in a form that can be shown to be wrong. Someone should be able to read
// `normalDeveloperDay` and say "no, that lunch break does not end the morning" — and then change the
// fixture and watch the builder fail. That argument is the point; the fixture is where it happens.
//
// Every day is generated from a script of (application, seconds) steps rather than pasted out as
// hundreds of literals, so it stays readable and so it produces the same bytes on every run: there is
// no `Date()`, no randomness and no clock anywhere below.
//
// Each fixture carries two things the builder is measured against:
//
//   `expected` — the whole `DayTimeline` as designed. Its episode boundaries and labels are the
//                claim; its per-application durations are arithmetic over the same intervals and
//                carry no opinion.
//   `claims`   — the assertions §8 of `docs/_design/INTELLIGENCE.md` names, each independently
//                checkable, so a builder that gets the shape right and one number wrong fails on the
//                number rather than on everything.

enum DayFixtures {

    // MARK: - Time

    /// 2024-01-15 00:00:00 UTC. Every fixture instant is an offset from here, and every interval
    /// records a zero timezone offset, so the times written in the comments below are the times the
    /// data actually holds.
    static let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

    /// The morning after `dayStart`, for the day that spans a night.
    static let nextDayStart = dayStart.addingTimeInterval(24 * 3600)

    static func time(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    static func nextDayTime(_ hour: Int, _ minute: Int, second: Int = 0) -> Date {
        nextDayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    /// A duration in seconds, written in minutes.
    ///
    /// The explicit `Double` parameter is load-bearing rather than decoration. `#expect` compares an
    /// `Optional<Double>` against an integer-literal expression such as `40 * 60` by type as well as
    /// by value, and reports a failure even when the two numbers are identical. Routing every
    /// duration through these helpers keeps both sides of every comparison `Double`.
    static func minutes(_ count: Double) -> TimeInterval { count * 60 }

    static func hours(_ count: Double) -> TimeInterval { count * 3600 }

    // MARK: - Applications

    /// The applications the fixtures use, with the bundle identifiers the shipped satellite and
    /// category tables key on. A typo here would silently make a satellite group stop applying, so
    /// the identifiers are written once.
    enum App: String, Sendable {
        case xcode = "com.apple.dt.Xcode"
        case terminal = "com.apple.Terminal"
        case simulator = "com.apple.iphonesimulator"
        case chrome = "com.google.Chrome"
        case slack = "com.tinyspeck.slackmacgap"
        case mail = "com.apple.mail"
        case messages = "com.apple.MobileSMS"
        case zoom = "us.zoom.xos"

        var displayName: String {
            switch self {
            case .xcode: "Xcode"
            case .terminal: "Terminal"
            case .simulator: "Simulator"
            case .chrome: "Chrome"
            case .slack: "Slack"
            case .mail: "Mail"
            case .messages: "Messages"
            case .zoom: "Zoom"
            }
        }
    }

    // MARK: - Scripts

    /// One step of a day: an application in front of the user for a number of seconds.
    struct Step: Sendable {
        let app: App
        let seconds: TimeInterval
        let isIdle: Bool
    }

    static func step(_ app: App, _ seconds: TimeInterval) -> Step {
        Step(app: app, seconds: seconds, isIdle: false)
    }

    /// The application stayed frontmost and no input arrived. Idle is recorded as an interval, not as
    /// an absence: only the builder decides how long a stretch of stillness has to be before it stops
    /// being reading and becomes a gap.
    static func idle(_ app: App, _ seconds: TimeInterval) -> Step {
        Step(app: app, seconds: seconds, isIdle: true)
    }

    static func repeated(_ pattern: [Step], times: Int) -> [Step] {
        Array(Array(repeating: pattern, count: max(0, times)).joined())
    }

    /// Lays a script out end to end from `start`, one interval per step.
    ///
    /// `monotonicDuration` is the scripted length and the wall-clock span matches it exactly, which
    /// is what a day with no clock steps in it looks like. A future fixture that wants to prove the
    /// builder ignores a clock step gives the two different values.
    static func intervals(
        _ script: [Step],
        from start: Date,
        stream: Int,
        tzOffsetMinutes: Int = 0
    ) -> [ActivityInterval] {
        var cursor = start
        return script.enumerated().map { index, step in
            let end = cursor.addingTimeInterval(step.seconds)
            defer { cursor = end }
            return ActivityInterval(
                id: fixtureID(stream, index),
                bundleIdentifier: step.app.rawValue,
                displayName: step.app.displayName,
                start: cursor,
                end: end,
                monotonicDuration: step.seconds,
                isIdle: step.isIdle,
                idleConfidence: step.isIdle ? .high : .low,
                tzOffsetMinutes: tzOffsetMinutes
            )
        }
    }

    /// A stable identifier per stream and index, built from a fixed byte pattern rather than parsed
    /// from a string, so nothing is random and nothing needs unwrapping.
    static func fixtureID(_ stream: Int, _ index: Int) -> UUID {
        UUID(
            uuid: (
                0x1D, 0xA1, 0xF1, 0x00, 0x00, 0x00, 0x40, 0x00, 0x80, 0x00, 0x00, 0x00,
                UInt8(truncatingIfNeeded: stream),
                UInt8(truncatingIfNeeded: index >> 16),
                UInt8(truncatingIfNeeded: index >> 8),
                UInt8(truncatingIfNeeded: index)
            ))
    }

    // MARK: - Claims

    /// One falsifiable statement about a rebuilt day.
    ///
    /// Written as data rather than as assertions inside a test so that the claim and the day it is
    /// made about live in the same file, and so that no claim can be quietly skipped by deleting a
    /// line from a test body.
    enum Claim: Hashable, Sendable {
        /// "9 ± 2 episodes." "≤ 8 episodes."
        case episodeCount(ClosedRange<Int>)
        /// Exactly one episode spans this whole range: the alternation inside it is not a boundary.
        case singleEpisode(covering: DateInterval)
        /// The block covering this instant is dominated by this application, so the excursion that
        /// happened here did not become a block of its own.
        case instantBelongsTo(bundleIdentifier: String, at: Date)
        /// Glances collapsed across the whole day.
        case interjections(atLeast: Int)
        case gapCount(reason: GapReason, count: Int)
        /// Exact, in seconds. A gap that is approximately right is a gap that has absorbed something.
        case gapDuration(reason: GapReason, seconds: TimeInterval)
        case noGap(reason: GapReason)
        /// No block is longer than this, measured on the wall clock — the fifteen-hour-block test.
        case noEpisodeLonger(than: TimeInterval)
        /// Some block ends exactly here.
        case anEpisodeEnds(at: Date)
        case label(at: Date, text: String, confidence: LabelConfidence)
        case labelConfidenceAtMost(LabelConfidence)
        /// No block is named anything more specific than the applications in it or the category they
        /// share. The persona-neutrality test: nothing here may know what the work was about.
        case labelsNameApplicationsOnly

        func holds(in timeline: DayTimeline) -> Bool {
            switch self {
            case .episodeCount(let range):
                return range.contains(timeline.episodeCount)

            case .singleEpisode(let range):
                let covering = timeline.episodes.filter {
                    $0.start <= range.start && $0.end >= range.end
                }
                return covering.count == 1

            case .instantBelongsTo(let bundleIdentifier, let instant):
                return timeline.episode(containing: instant)?.dominantApp?.bundleIdentifier
                    == bundleIdentifier

            case .interjections(let minimum):
                return timeline.interjectionCount >= minimum

            case .gapCount(let reason, let count):
                return timeline.gaps(for: reason).count == count

            case .gapDuration(let reason, let seconds):
                return timeline.gapDuration(for: reason) == seconds

            case .noGap(let reason):
                return timeline.gaps(for: reason).isEmpty

            case .noEpisodeLonger(let limit):
                return timeline.episodes.allSatisfy { $0.wallClockSpan <= limit }

            case .anEpisodeEnds(let instant):
                return timeline.episodes.contains { $0.end == instant }

            case .label(let instant, let text, let confidence):
                guard let episode = timeline.episode(containing: instant) else { return false }
                return episode.label == text && episode.labelConfidence == confidence

            case .labelConfidenceAtMost(let ceiling):
                return timeline.episodes.allSatisfy { $0.labelConfidence <= ceiling }

            case .labelsNameApplicationsOnly:
                let categoryNames = Set(AppCategory.allCases.map(\.displayName))
                return timeline.episodes.allSatisfy { episode in
                    if categoryNames.contains(episode.label) { return true }
                    let rosters = (1...max(1, episode.apps.count)).map { episode.appRoster(limit: $0) }
                    return rosters.contains(episode.label)
                }
            }
        }
    }

    // MARK: - Fixture

    struct DayFixture: Sendable {
        /// What this day is claiming, in one sentence a reader can disagree with.
        let claim: String
        let intervals: [ActivityInterval]
        /// Absences the sampler observed or reconstructed rather than inferred. Idle is not here: it
        /// lives on the intervals, because only the builder decides how long stillness has to last.
        let absences: [Gap]
        let sessions: [FocusSession]
        let weights: SegmentationWeights
        let expected: DayTimeline
        let claims: [Claim]
    }

    // MARK: - Expected timeline construction

    /// One designed block: the boundaries and the name are the claim.
    private struct Block {
        let start: Date
        let end: Date
        let label: String
        let confidence: LabelConfidence
        let sessionID: UUID?

        init(
            _ start: Date,
            _ end: Date,
            _ label: String,
            _ confidence: LabelConfidence = .appRoster,
            session: UUID? = nil
        ) {
            self.start = start
            self.end = end
            self.label = label
            self.confidence = confidence
            self.sessionID = session
        }
    }

    /// Indices of intervals that are glances: short enough, and bounded on both sides by the same
    /// application they interrupted.
    ///
    /// Computed here so the expected application rosters do not credit a six-second Slack activation
    /// with a place in the block it interrupted. It is the only piece of stage 0 this file restates,
    /// and it restates it in order to describe an outcome, not to check one.
    private static func glanceIndices(
        _ intervals: [ActivityInterval],
        threshold: TimeInterval
    ) -> Set<Int> {
        var result: Set<Int> = []
        for index in intervals.indices.dropFirst().dropLast() {
            let interval = intervals[index]
            guard !interval.isIdle, interval.monotonicDuration < threshold else { continue }
            let before = intervals[index - 1].bundleIdentifier
            let after = intervals[index + 1].bundleIdentifier
            if before == after, before != interval.bundleIdentifier {
                result.insert(index)
            }
        }
        return result
    }

    /// Maximal runs of idle intervals long enough to stop being reading.
    private static func idleGaps(
        _ intervals: [ActivityInterval],
        threshold: TimeInterval,
        stream: Int
    ) -> [Gap] {
        var gaps: [Gap] = []
        var runStart: Date?
        var runEnd: Date?

        func closeRun() {
            guard let start = runStart, let end = runEnd else { return }
            if end.timeIntervalSince(start) >= threshold {
                gaps.append(
                    Gap(id: fixtureID(stream, 900_000 + gaps.count), reason: .idle, start: start, end: end)
                )
            }
            runStart = nil
            runEnd = nil
        }

        for interval in intervals {
            if interval.isIdle {
                if runStart == nil { runStart = interval.start }
                runEnd = interval.end
            } else {
                closeRun()
            }
        }
        closeRun()
        return gaps
    }

    private static func episode(
        _ block: Block,
        index: Int,
        intervals: [ActivityInterval],
        glances: Set<Int>,
        stream: Int
    ) -> Episode {
        var order: [String] = []
        var durations: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        var visits: [String: Int] = [:]
        var interjections = 0
        var counted = 0
        var previousBundle: String?

        for (position, interval) in intervals.enumerated() {
            guard interval.start >= block.start, interval.end <= block.end else { continue }
            if glances.contains(position) {
                interjections += 1
                continue
            }
            guard !interval.isIdle else { continue }

            let bundle = interval.bundleIdentifier
            if durations[bundle] == nil {
                order.append(bundle)
                durations[bundle] = 0
                visits[bundle] = 0
                names[bundle] = interval.displayName
            }
            durations[bundle, default: 0] += interval.monotonicDuration
            if previousBundle != bundle { visits[bundle, default: 0] += 1 }
            previousBundle = bundle
            counted += 1
        }

        let shares: [Episode.AppShare] = order.map { bundle in
            Episode.AppShare(
                bundleIdentifier: bundle,
                displayName: names[bundle] ?? bundle,
                duration: durations[bundle] ?? 0,
                visitCount: visits[bundle] ?? 0
            )
        }

        // Descending by time, then by bundle identifier so the roster order is total and a tie can
        // never reorder itself between two runs.
        let apps: [Episode.AppShare] = shares.sorted { left, right in
            if left.duration == right.duration {
                return left.bundleIdentifier < right.bundleIdentifier
            }
            return left.duration > right.duration
        }

        return Episode(
            id: fixtureID(stream, 800_000 + index),
            start: block.start,
            end: block.end,
            apps: apps,
            interjections: interjections,
            label: block.label,
            labelConfidence: block.confidence,
            sessionID: block.sessionID,
            intervalCount: counted
        )
    }

    private static func timeline(
        anchoredAt dayStart: Date,
        sealed: Bool,
        intervals: [ActivityInterval],
        absences: [Gap],
        blocks: [Block],
        weights: SegmentationWeights,
        stream: Int
    ) -> DayTimeline {
        let glances = glanceIndices(intervals, threshold: weights.glanceThreshold)
        let episodes = blocks.enumerated().map {
            episode($1, index: $0, intervals: intervals, glances: glances, stream: stream)
        }
        let gaps =
            idleGaps(intervals, threshold: weights.idleGapThreshold, stream: stream) + absences
        return DayTimeline(dayStart: dayStart, episodes: episodes, gaps: gaps, sealed: sealed)
    }

    // MARK: - 1. A normal developer day

    /// 380 intervals, 09:04 to 18:04.
    ///
    /// The claim: a day that contains forty-six Xcode↔Terminal alternations in its first hour is one
    /// block of work, not forty-six. The alternation runs at a 22-second median — the rhythm of
    /// editing, building, reading the failure and editing again — and a person asked what they did
    /// before ten o'clock says "I was in Xcode", not "I switched applications forty-six times".
    ///
    /// Two Slack excursions, six seconds each, land inside blocks that continue afterwards in the
    /// application they interrupted. They are interjections. A cmd-tab to Slack and back is not a
    /// context switch in any sense the person who did it recognises, and cutting a block at one would
    /// turn nine readable blocks into a shredded log nobody opens twice.
    ///
    /// One session is declared over the early afternoon, so the block that overlaps it borrows the
    /// user's own sentence and outranks every heuristic in `SegmentationWeights`.
    static let sessionOutcome = "Finish the receipt deduplication PR"
    static let normalDeveloperSessionID = fixtureID(1, 700_001)

    static let normalDeveloperDay: DayFixture = makeNormalDeveloperDay()

    private static func makeNormalDeveloperDay() -> DayFixture {
        let weights = SegmentationWeights.default
        let alternation = [
            step(.terminal, 22), step(.xcode, 22), step(.terminal, 22), step(.xcode, 180),
        ]

        var script: [Step] = []

        // 09:04 → 09:50. Xcode and Terminal, 48 intervals, one Slack glance in the middle.
        script += repeated(alternation, times: 5)
        script += [step(.terminal, 12), step(.xcode, 22), step(.slack, 6), step(.xcode, 14)]
        script += repeated(alternation, times: 6)
        // 09:50 → 10:12. Away from the desk with Xcode still frontmost.
        script += [idle(.xcode, 1320)]
        // 10:12 → 11:52. Reviewing in the browser against the editor.
        script += repeated([step(.chrome, 120), step(.xcode, 80)], times: 30)
        // 11:52 → 11:58. A short break, long enough to end the block.
        script += [idle(.xcode, 360)]
        // 11:58 → 12:30. Build and test, Terminal-led.
        script += repeated([step(.terminal, 60), step(.xcode, 30)], times: 21)
        script += [step(.terminal, 20), step(.xcode, 10)]
        // 12:30 → 13:20. Lunch.
        script += [idle(.xcode, 3000)]
        // 13:20 → 14:35. The declared session, with the second Slack glance inside it.
        script += repeated(alternation, times: 9)
        script += [step(.terminal, 20), step(.xcode, 26), step(.slack, 6), step(.xcode, 20)]
        script += repeated(alternation, times: 9)
        // 14:35 → 15:05. A call, with the browser open beside it.
        script += [
            step(.zoom, 1200), step(.chrome, 120), step(.zoom, 300), step(.chrome, 60),
            step(.zoom, 120),
        ]
        // 15:05 → 16:10. Back to the editor, browser alongside.
        script += repeated(
            [step(.xcode, 100), step(.chrome, 70), step(.xcode, 60), step(.terminal, 30)],
            times: 15
        )
        // 16:10 → 16:40. Messaging, with a brief call and two browser checks inside it.
        script += repeated(
            [
                step(.slack, 120), step(.mail, 60), step(.messages, 45), step(.chrome, 40),
                step(.zoom, 90), step(.mail, 50), step(.chrome, 30), step(.messages, 15),
            ],
            times: 4
        )
        // 16:40 → 17:35. Editor, simulator and terminal: one activity, three applications.
        script += repeated([step(.xcode, 100), step(.simulator, 60), step(.terminal, 40)], times: 16)
        script += [step(.xcode, 100)]
        // 17:35 → 18:04. Reading, in the browser. 380 intervals in total.
        script += [step(.chrome, 850), step(.xcode, 40), step(.chrome, 850)]

        let stream = 1
        let intervals = intervals(script, from: time(9, 4), stream: stream)

        let session = FocusSession(
            id: normalDeveloperSessionID,
            intendedOutcome: sessionOutcome,
            workType: .deepWork,
            plannedDuration: minutes(75),
            startedAt: time(13, 20),
            endedAt: time(14, 35),
            resultStatus: .madeProgress
        )

        let blocks: [Block] = [
            Block(time(9, 4), time(9, 50), "Xcode, Terminal"),
            Block(time(10, 12), time(11, 52), "Chrome, Xcode"),
            Block(time(11, 58), time(12, 30), "Terminal, Xcode"),
            Block(
                time(13, 20), time(14, 35), sessionOutcome, .declared,
                session: normalDeveloperSessionID
            ),
            Block(time(14, 35), time(15, 5), "Zoom, Chrome"),
            Block(time(15, 5), time(16, 10), "Xcode, Chrome, Terminal"),
            Block(time(16, 10), time(16, 40), "Slack, Mail, Zoom +2 more"),
            Block(time(16, 40), time(17, 35), "Xcode, Simulator, Terminal"),
            Block(time(17, 35), time(18, 4), "Chrome, Xcode"),
        ]

        return DayFixture(
            claim: """
                Forty-six Xcode↔Terminal alternations before ten o'clock are one block of work, and \
                two six-second Slack excursions are interjections inside blocks rather than blocks \
                of their own.
                """,
            intervals: intervals,
            absences: [],
            sessions: [session],
            weights: weights,
            expected: timeline(
                anchoredAt: dayStart,
                sealed: true,
                intervals: intervals,
                absences: [],
                blocks: blocks,
                weights: weights,
                stream: stream
            ),
            claims: [
                .episodeCount(7...11),
                // The whole morning alternation, start to finish, as one block.
                .singleEpisode(covering: DateInterval(start: time(9, 4), end: time(9, 50))),
                // 09:25:04 → 09:25:10 and 13:57:40 → 13:57:46 are the two Slack activations. Both
                // instants must land inside a block the editor dominates.
                .instantBelongsTo(bundleIdentifier: App.xcode.rawValue, at: time(9, 25, second: 7)),
                .instantBelongsTo(bundleIdentifier: App.xcode.rawValue, at: time(13, 57, second: 43)),
                .interjections(atLeast: 2),
                .gapCount(reason: .idle, count: 3),
                .gapDuration(reason: .idle, seconds: minutes(78)),
                .noGap(reason: .unexplained),
                .label(at: time(14, 0), text: sessionOutcome, confidence: .declared),
            ]
        )
    }

    // MARK: - 2. A night in the middle

    /// Work stops at 18:04, the machine sleeps, work resumes at 09:12 the next morning.
    ///
    /// The claim: fifteen hours of silence is a night, and a night is a gap. The failure this fixture
    /// exists to catch is the one that destroys trust fastest — a lid closed on a Monday evening
    /// rendered as a fifteen-hour Xcode block on Tuesday morning. Nobody who sees that ever believes
    /// another number in the application.
    ///
    /// It also fixes the precedence for the collision that happens every single night: the sampler is
    /// not running while the machine is asleep, so the same span is describable as both `.systemSleep`
    /// and `.appNotRunning`. A sleep that covers the absence is a sleep. Marking the most ordinary
    /// event in the corpus as a crash would make the crash marker worthless on the day it matters.
    static let overnightSleepDay: DayFixture = makeOvernightSleepDay()

    private static func makeOvernightSleepDay() -> DayFixture {
        let weights = SegmentationWeights.default
        let stream = 2

        let evening: [Step] =
            // 16:30 → 17:20
            repeated([step(.xcode, 250), step(.terminal, 125)], times: 8)
            // 17:20 → 17:26
            + [idle(.terminal, 360)]
            // 17:26 → 18:04
            + repeated([step(.chrome, 200), step(.slack, 85)], times: 8)

        let morning: [Step] =
            // 09:12 → 10:05
            repeated([step(.mail, 180), step(.slack, 85)], times: 12)
            // 10:05 → 10:15
            + [idle(.slack, 600)]
            // 10:15 → 11:30
            + repeated([step(.xcode, 200), step(.terminal, 100)], times: 15)

        let eveningIntervals = intervals(evening, from: time(16, 30), stream: stream)
        let morningIntervals = intervals(morning, from: nextDayTime(9, 12), stream: stream + 100)
        let allIntervals = eveningIntervals + morningIntervals

        let sleep = Gap(
            id: fixtureID(stream, 600_001),
            reason: .systemSleep,
            start: time(18, 4),
            end: nextDayTime(9, 12)
        )

        let blocks: [Block] = [
            Block(time(16, 30), time(17, 20), "Xcode, Terminal"),
            Block(time(17, 26), time(18, 4), "Chrome, Slack"),
            Block(nextDayTime(9, 12), nextDayTime(10, 5), "Mail, Slack"),
            Block(nextDayTime(10, 15), nextDayTime(11, 30), "Xcode, Terminal"),
        ]

        return DayFixture(
            claim: """
                Fifteen hours of silence is a night, not a block, and the sleep that explains it \
                outranks the absence of the application that could not observe it.
                """,
            intervals: allIntervals,
            absences: [sleep],
            sessions: [],
            weights: weights,
            expected: timeline(
                anchoredAt: dayStart,
                sealed: true,
                intervals: allIntervals,
                absences: [sleep],
                blocks: blocks,
                weights: weights,
                stream: stream
            ),
            claims: [
                // Two evening blocks and two morning ones.
                .episodeCount(4...4),
                .gapCount(reason: .systemSleep, count: 1),
                // 18:04 to 09:12 the next day, to the second.
                .gapDuration(reason: .systemSleep, seconds: minutes(908)),
                // The night must not also be reported as a crash.
                .noGap(reason: .appNotRunning),
                .noGap(reason: .unexplained),
                // Nothing anywhere near fifteen hours. The longest designed block is 75 minutes.
                .noEpisodeLonger(than: hours(3)),
                .gapCount(reason: .idle, count: 2),
            ]
        )
    }

    // MARK: - 3. The day the application died

    /// The heartbeat stops at 14:30 and the interval stream resumes at 16:10.
    ///
    /// The claim: the block before the crash ends at the last heartbeat, and the hundred minutes
    /// nobody observed are marked as a hundred minutes nobody observed.
    ///
    /// This is the single most important honesty mechanism in the plan, and the temptation it resists
    /// is real: closing the open interval at relaunch instead would produce a tidier timeline with a
    /// hundred extra minutes of Xcode in it, and the user would have no way of knowing. A gap the
    /// application cannot explain must survive contact with the wish for a tidy timeline.
    ///
    /// `willSleepNotification` is not delivered on a power loss or a panic, so the heartbeat — a
    /// 60-second write to its own small file — is the only thing that knows when the day stopped.
    static let crashedAppDay: DayFixture = makeCrashedAppDay()

    /// The last heartbeat before the process died. Everything about this fixture hangs off it.
    static let lastHeartbeat = time(14, 30)
    static let relaunch = time(16, 10)

    private static func makeCrashedAppDay() -> DayFixture {
        let weights = SegmentationWeights.default
        let stream = 3

        let beforeCrash: [Step] =
            // 09:00 → 10:30
            repeated([step(.xcode, 200), step(.terminal, 100)], times: 18)
            // 10:30 → 10:45
            + [idle(.terminal, 900)]
            // 10:45 → 12:00
            + repeated([step(.chrome, 150), step(.xcode, 75)], times: 20)
            // 12:00 → 12:50
            + [idle(.xcode, 3000)]
            // 12:50 → 14:30. The final interval was closed by the heartbeat, not by an activation.
            + repeated([step(.xcode, 250), step(.terminal, 125)], times: 16)

        // 16:10 → 17:20
        let afterRelaunch: [Step] = repeated([step(.xcode, 200), step(.terminal, 100)], times: 14)

        let beforeIntervals = intervals(beforeCrash, from: time(9, 0), stream: stream)
        let afterIntervals = intervals(afterRelaunch, from: relaunch, stream: stream + 100)
        let allIntervals = beforeIntervals + afterIntervals

        // Reconstructed on relaunch from the heartbeat file: it begins at the last heartbeat and ends
        // when the process came back. Nothing else in the system knows this span existed.
        let crash = Gap(
            id: fixtureID(stream, 600_001),
            reason: .appNotRunning,
            start: lastHeartbeat,
            end: relaunch
        )

        let blocks: [Block] = [
            Block(time(9, 0), time(10, 30), "Xcode, Terminal"),
            Block(time(10, 45), time(12, 0), "Chrome, Xcode"),
            Block(time(12, 50), lastHeartbeat, "Xcode, Terminal"),
            Block(relaunch, time(17, 20), "Xcode, Terminal"),
        ]

        return DayFixture(
            claim: """
                The block before a crash ends at the last heartbeat, and the hundred minutes nobody \
                observed are marked as a hundred minutes nobody observed.
                """,
            intervals: allIntervals,
            absences: [crash],
            sessions: [],
            weights: weights,
            expected: timeline(
                anchoredAt: dayStart,
                sealed: true,
                intervals: allIntervals,
                absences: [crash],
                blocks: blocks,
                weights: weights,
                stream: stream
            ),
            claims: [
                .episodeCount(4...4),
                .gapCount(reason: .appNotRunning, count: 1),
                // Exactly 100 minutes. Not 99, and emphatically not zero.
                .gapDuration(reason: .appNotRunning, seconds: minutes(100)),
                // The block closes at the heartbeat, not at the relaunch.
                .anEpisodeEnds(at: lastHeartbeat),
                .noGap(reason: .systemSleep),
                .noGap(reason: .unexplained),
                .gapCount(reason: .idle, count: 2),
            ]
        )
    }

    // MARK: - 4. A manager's day

    /// Chrome, Slack and Zoom. Forty activations, no satellite structure, no editor anywhere.
    ///
    /// The claim: the segmenter is not a developer tool. Every mechanism that makes the developer day
    /// readable — the Xcode↔Terminal satellite group, the tight alternation, the build-and-test
    /// rhythm — is absent here, and the day must still come out as blocks a person recognises rather
    /// than as forty rows.
    ///
    /// The second claim is the one worth arguing about: **no block on this day may be named anything
    /// more specific than the applications in it.** A manager's applications carry the whole company
    /// in their window titles, and this fixture is where a future change that starts naming blocks
    /// from them gets caught. It should be written by someone who is not a developer, and if their
    /// day does not look like this, the fixture is wrong and should be rewritten rather than argued
    /// with.
    static let fragmentedManagerDay: DayFixture = makeFragmentedManagerDay()

    private static func makeFragmentedManagerDay() -> DayFixture {
        let weights = SegmentationWeights.default
        let stream = 4

        let script: [Step] = [
            // 09:00 → 09:35. Inbox and messages.
            step(.chrome, 700), step(.slack, 180), step(.chrome, 600), step(.slack, 150),
            step(.chrome, 470),
            // 09:35 → 10:30. Standup, then a one-to-one, with two short looks away.
            step(.zoom, 1200), step(.chrome, 200), step(.slack, 150), step(.zoom, 900),
            step(.chrome, 200), step(.zoom, 650),
            // 10:30 → 10:50. Away from the desk.
            idle(.zoom, 1200),
            // 10:50 → 12:00. Documents in the browser, messages alongside.
            step(.chrome, 900), step(.slack, 220), step(.chrome, 800), step(.slack, 200),
            step(.chrome, 850), step(.slack, 180), step(.chrome, 1050),
            // 12:00 → 12:45. Lunch.
            idle(.chrome, 2700),
            // 12:45 → 14:30. Two back-to-back calls.
            step(.zoom, 1500), step(.chrome, 150), step(.zoom, 1400), step(.slack, 120),
            step(.zoom, 1300), step(.chrome, 130), step(.zoom, 1700),
            // 14:30 → 15:40. Messages, with documents alongside.
            step(.slack, 700), step(.chrome, 200), step(.slack, 800), step(.chrome, 220),
            step(.slack, 750), step(.chrome, 180), step(.slack, 1350),
            // 15:40 → 15:55. Away from the desk.
            idle(.slack, 900),
            // 15:55 → 17:00. Reading and writing in the browser.
            step(.chrome, 1200), step(.slack, 200), step(.chrome, 1100), step(.slack, 180),
            step(.chrome, 1220),
        ]

        let intervals = intervals(script, from: time(9, 0), stream: stream)

        let blocks: [Block] = [
            Block(time(9, 0), time(9, 35), "Chrome, Slack"),
            Block(time(9, 35), time(10, 30), "Zoom, Chrome, Slack"),
            Block(time(10, 50), time(12, 0), "Chrome, Slack"),
            Block(time(12, 45), time(14, 30), "Zoom, Chrome, Slack"),
            Block(time(14, 30), time(15, 40), "Slack, Chrome"),
            Block(time(15, 55), time(17, 0), "Chrome, Slack"),
        ]

        return DayFixture(
            claim: """
                A day made only of a browser, a chat client and a call application still reduces to \
                a handful of readable blocks, and not one of them is named anything the application \
                could only have learned from a window title.
                """,
            intervals: intervals,
            absences: [],
            sessions: [],
            weights: weights,
            expected: timeline(
                anchoredAt: dayStart,
                sealed: false,
                intervals: intervals,
                absences: [],
                blocks: blocks,
                weights: weights,
                stream: stream
            ),
            claims: [
                .episodeCount(1...8),
                .labelsNameApplicationsOnly,
                // Nothing here overlaps a session and nothing here reads a title, so no block may
                // claim more than the category its applications share.
                .labelConfidenceAtMost(.category),
                .gapCount(reason: .idle, count: 3),
                .noGap(reason: .unexplained),
                // Forty activations is what the sampler saw. It is not what the person did.
                .noEpisodeLonger(than: hours(2)),
            ]
        )
    }

    // MARK: - All four

    static let allDays: [DayFixture] = [
        normalDeveloperDay,
        overnightSleepDay,
        crashedAppDay,
        fragmentedManagerDay,
    ]
}
