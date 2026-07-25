import Foundation

/// What a day looked like, stated as facts rather than as a verdict.
///
/// Four timing-only signals, computed from a `DayTimeline` and nothing else: the longest unbroken
/// runs, the excursions that left an application and came back, the alternation rhythms that reveal
/// a review loop, and which applications did the interrupting. Every one of them is available at
/// **zero permissions** and with no window title anywhere near it — the applications and the clock
/// are the whole input.
///
/// **This is evidence, not judgment.** Every number here is a count or a duration, and that is a
/// constraint rather than an accident. There is no score, no index, no grade, no streak and no
/// percentage, and none may be added: `INTELLIGENCE.md` §3.4 removed every headline number that
/// behaves like one — the live stretch counter, the daily maximum in the recap footer, the
/// fragmentation index, the undeclared-block badge — because a visible number that goes up when you
/// comply and down when you do not is a score with a loss condition, whatever it is called. A caller
/// may render *"the longest unbroken run was 54 minutes"* or *"Slack interrupted the three longest
/// runs"*. It may not render *"78% focused"*, and this type gives it nothing to compute one from.
///
/// It is also silent about anything it did not observe. An application that never came back is never
/// called an interruption; three runs that do not exist are never "the three longest runs". Under-
/// claiming is the only acceptable failure direction, because a plausible wrong claim gets believed,
/// exported, and pasted into a document that matters.
///
/// **Cost.** One pass over the timeline's entries builds the runs, one pass over the runs derives
/// everything else, and the summaries are sorted at the end. Nothing rescans, nothing searches
/// backwards, and there is no nested loop over the day anywhere — a day of five thousand blocks
/// costs five thousand steps and a sort, not twenty-five million comparisons.
///
/// Pure, like `EpisodeBuilder`: no clock, no I/O, no actor, no global state. The same timeline
/// produces the same shape on any machine at any hour, forever.
public struct ShapeOfWork: Hashable, Sendable {

    // MARK: - Pieces

    /// An application, named the way a person would recognise it.
    ///
    /// Identity is the bundle identifier; the display name travels with it so a shape built months
    /// ago still renders after the application has been renamed or uninstalled.
    public struct App: Hashable, Sendable, Identifiable, Comparable {
        public let bundleIdentifier: String
        public let displayName: String

        public var id: String { bundleIdentifier }

        public init(bundleIdentifier: String, displayName: String) {
            self.bundleIdentifier = bundleIdentifier
            self.displayName = displayName
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(bundleIdentifier)
        }

        /// Total, so every ranking below has a deterministic tie-break.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.bundleIdentifier < rhs.bundleIdentifier
        }
    }

    /// An unbroken stretch on one application.
    ///
    /// "Unbroken" is defined by **frontmost continuity** and by nothing else. Idle deliberately does
    /// not enter into it: any process can zero the system idle timer — Screen Sharing, a jiggler,
    /// Karabiner, a remote-control session all do it in ordinary use — so a run defined by idle is a
    /// run any background process can lengthen. A run ends where the frontmost application changes,
    /// or where a hard gap says nothing was observed at all.
    ///
    /// Consecutive blocks on the same application join into one run when nothing hard separates
    /// them, so a stretch of editing that the segmenter split at a soft idle boundary is still one
    /// run here.
    public struct Run: Hashable, Sendable, Identifiable {
        public let app: App
        public let start: Date
        public let end: Date
        /// Summed from the blocks' own monotonic measurements. Never `end - start`.
        public let activeDuration: TimeInterval
        /// How many blocks were joined into this run.
        public let episodeCount: Int
        /// The application the user went to and then came back from, when this run was interrupted
        /// and resumed. `nil` when the run simply ended — moving on to something else is not an
        /// interruption, and calling it one would invent a return that never happened.
        public let interruptedBy: App?

        /// Two runs cannot begin at the same instant, so the start identifies the run.
        public var id: Date { start }

        public init(
            app: App,
            start: Date,
            end: Date,
            activeDuration: TimeInterval,
            episodeCount: Int,
            interruptedBy: App? = nil
        ) {
            self.app = app
            self.start = start
            self.end = max(start, end)
            self.activeDuration = activeDuration.isFinite ? max(0, activeDuration) : 0
            self.episodeCount = max(0, episodeCount)
            self.interruptedBy = interruptedBy
        }

        /// Where the run sits on the timeline. Position, not length.
        public var wallClockSpan: TimeInterval { max(0, end.timeIntervalSince(start)) }

        public var wasInterrupted: Bool { interruptedBy != nil }
    }

    /// You left an application and you came back: `from → to → from`, with nothing hard in between.
    ///
    /// One row per ordered pair, because leaving Xcode for Slack and leaving Slack for Xcode are two
    /// different habits and averaging them together describes neither.
    public struct Excursion: Hashable, Sendable, Identifiable {
        public let from: App
        public let to: App
        /// How many times the round trip happened.
        public let count: Int
        /// Time spent away, summed across the round trips.
        public let totalAway: TimeInterval
        /// The middle value of the time spent away. Median rather than mean: one forty-minute
        /// detour would otherwise describe eleven ten-second glances.
        public let medianAway: TimeInterval

        public var id: String { "\(from.bundleIdentifier)→\(to.bundleIdentifier)" }

        public init(
            from: App,
            to: App,
            count: Int,
            totalAway: TimeInterval,
            medianAway: TimeInterval
        ) {
            self.from = from
            self.to = to
            self.count = max(0, count)
            self.totalAway = totalAway.isFinite ? max(0, totalAway) : 0
            self.medianAway = medianAway.isFinite ? max(0, medianAway) : 0
        }
    }

    /// The A↔B↔A rhythm: two applications the day kept moving between.
    ///
    /// This is the signal that reveals a review loop — editor to browser and back, thirty times —
    /// which no single block can show, because the segmenter's whole job is to collapse it into one.
    /// The pair is unordered, canonicalised so that `{A, B}` and `{B, A}` are the same row.
    public struct Alternation: Hashable, Sendable, Identifiable {
        /// The lower bundle identifier of the pair, so the row is stable.
        public let first: App
        public let second: App
        /// Moves between the two, in either direction.
        public let transitions: Int
        /// Complete round trips — `A → B → A` or `B → A → B`. A rhythm needs a return; without one
        /// this is two applications that happened to follow each other once.
        public let cycles: Int
        /// The middle time spent on the far side of a round trip.
        public let medianAway: TimeInterval

        public var id: String { "\(first.bundleIdentifier)↔\(second.bundleIdentifier)" }

        public init(
            first: App,
            second: App,
            transitions: Int,
            cycles: Int,
            medianAway: TimeInterval
        ) {
            self.first = first
            self.second = second
            self.transitions = max(0, transitions)
            self.cycles = max(0, cycles)
            self.medianAway = medianAway.isFinite ? max(0, medianAway) : 0
        }
    }

    /// An application ranked by how often it interrupted a run that then resumed.
    ///
    /// Only round trips count. An application the user moved to and stayed on ended a run rather
    /// than interrupting one, and counting it here would let "Slack interrupted you nine times"
    /// include the nine times the day simply finished in Slack.
    public struct Interruption: Hashable, Sendable, Identifiable {
        public let app: App
        /// How many runs this application interrupted.
        public let count: Int
        /// Time the interruptions took, summed.
        public let totalAway: TimeInterval
        public let medianAway: TimeInterval
        /// Time inside the interrupted runs, summed. Present so a caller can say which runs were
        /// affected rather than only how many.
        public let interruptedDuration: TimeInterval

        public var id: String { app.bundleIdentifier }

        public init(
            app: App,
            count: Int,
            totalAway: TimeInterval,
            medianAway: TimeInterval,
            interruptedDuration: TimeInterval
        ) {
            self.app = app
            self.count = max(0, count)
            self.totalAway = totalAway.isFinite ? max(0, totalAway) : 0
            self.medianAway = medianAway.isFinite ? max(0, medianAway) : 0
            self.interruptedDuration =
                interruptedDuration.isFinite ? max(0, interruptedDuration) : 0
        }
    }

    // MARK: - Stored

    /// In timeline order.
    public let runs: [Run]
    /// Most frequent first; ties broken by time away, then by bundle identifier.
    public let excursions: [Excursion]
    /// Most transitions first; ties broken by cycles, then by bundle identifier.
    public let alternations: [Alternation]
    /// Most interruptions first; ties broken by time away, then by bundle identifier.
    public let interruptions: [Interruption]

    // MARK: - Building

    /// Reads a day.
    ///
    /// - Parameter timeline: The rebuilt day. Blocks with no applications carry no evidence about
    ///   what was in front of anybody and are passed over without breaking a run.
    public init(_ timeline: DayTimeline) {
        var drafts = Self.runs(in: timeline)
        let derived = Self.derive(from: &drafts)

        self.runs = drafts.map(\.finished)
        self.excursions = derived.excursions
        self.alternations = derived.alternations
        self.interruptions = derived.interruptions
    }

    /// An empty shape, for a caller that has no day yet.
    public init() {
        self.runs = []
        self.excursions = []
        self.alternations = []
        self.interruptions = []
    }

    // MARK: - Reading

    public var isEmpty: Bool { runs.isEmpty }

    /// The single longest unbroken run, or `nil` for a day with nothing in it.
    ///
    /// Ties go to the earlier run, so the answer is the same every time it is asked.
    public var longestRun: Run? { longestRuns(1).first }

    /// The longest unbroken runs, longest first.
    ///
    /// Fewer than `limit` runs are returned when the day has fewer; the caller must check, because
    /// "the three longest runs" is a false sentence on a day that contains two.
    public func longestRuns(_ limit: Int) -> [Run] {
        guard limit > 0 else { return [] }
        return
            runs
            .sorted { left, right in
                if left.activeDuration != right.activeDuration {
                    return left.activeDuration > right.activeDuration
                }
                return left.start < right.start
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Total time inside runs, summed from the blocks' monotonic measurements.
    public var runDuration: TimeInterval { runs.reduce(0) { $0 + $1.activeDuration } }

    /// How many runs were interrupted and resumed.
    public var interruptedRunCount: Int { runs.reduce(0) { $0 + ($1.wasInterrupted ? 1 : 0) } }

    /// The application that interrupted **every one** of the longest `limit` runs, if one did.
    ///
    /// Deliberately all-or-nothing, and deliberately `nil` when the day holds fewer than `limit`
    /// runs. It exists so that the sentence *"Slack interrupted the three longest runs"* can only be
    /// produced when it is literally true of all three; a "mostly" version of the same sentence
    /// reads identically to a reader and is a different claim.
    public func appInterruptingEveryLongestRun(_ limit: Int) -> App? {
        guard limit > 0 else { return nil }
        let longest = longestRuns(limit)
        guard longest.count == limit, let first = longest.first?.interruptedBy else { return nil }
        return longest.allSatisfy { $0.interruptedBy == first } ? first : nil
    }

    /// The alternation the day was mostly made of, if any pair returned at all.
    public var dominantAlternation: Alternation? {
        alternations.first { $0.cycles > 0 }
    }

    /// Every application that appeared as a run, most time first.
    public func appsByRunDuration() -> [(app: App, duration: TimeInterval)] {
        var totals: [App: TimeInterval] = [:]
        for run in runs { totals[run.app, default: 0] += run.activeDuration }
        return
            totals
            .map { (app: $0.key, duration: $0.value) }
            .sorted { left, right in
                if left.duration != right.duration { return left.duration > right.duration }
                return left.app < right.app
            }
    }
}

// MARK: - Single pass

extension ShapeOfWork {

    /// A run under construction, plus the one fact that cannot be known until the runs after it are.
    fileprivate struct Draft {
        var app: App
        var start: Date
        var end: Date
        var activeDuration: TimeInterval
        var episodeCount: Int
        /// Something the app did not observe sits immediately before this run.
        var severedBefore: Bool
        var interruptedBy: App?

        var finished: Run {
            Run(
                app: app,
                start: start,
                end: end,
                activeDuration: activeDuration,
                episodeCount: episodeCount,
                interruptedBy: interruptedBy
            )
        }
    }

    /// Pass one: the timeline's rows, in order, become runs.
    ///
    /// A hard gap severs; a soft one does not. `.idle` is the only soft reason there is, and it is
    /// soft on purpose — the application never left the front, the user may well have been reading,
    /// and a run that any idle stretch ended would be a run defined by a forgeable timer.
    fileprivate static func runs(in timeline: DayTimeline) -> [Draft] {
        var drafts: [Draft] = []
        drafts.reserveCapacity(timeline.episodes.count)
        var severed = true

        // `entries` is built and sorted once. Asking for it inside the loop would rebuild the whole
        // day on every row, which is the quadratic cost this type exists to avoid.
        for entry in timeline.entries {
            switch entry {
            case .gap(let gap):
                if gap.isHardBoundary { severed = true }

            case .episode(let episode):
                // A block with no applications says nothing about what was in front of anybody. It
                // is passed over rather than treated as a boundary: inventing a break out of a block
                // that recorded no evidence would shorten a run on no evidence at all.
                guard let dominant = episode.dominantApp else { continue }
                let app = App(
                    bundleIdentifier: dominant.bundleIdentifier,
                    displayName: dominant.displayName
                )

                if !severed, var last = drafts.last, last.app == app {
                    last.end = max(last.end, episode.end)
                    last.activeDuration += episode.activeDuration
                    last.episodeCount += 1
                    drafts[drafts.count - 1] = last
                } else {
                    drafts.append(
                        Draft(
                            app: app,
                            start: episode.start,
                            end: episode.end,
                            activeDuration: episode.activeDuration,
                            episodeCount: 1,
                            severedBefore: severed,
                            interruptedBy: nil
                        )
                    )
                }
                severed = false
            }
        }
        return drafts
    }

    /// Pass two: excursions, alternations and interruptions, from one walk over the runs.
    ///
    /// All three are read off the same window of three consecutive runs, which is why they agree
    /// with each other by construction rather than by three separate definitions that drift apart.
    /// `drafts` is `inout` because the walk is also what discovers which run was interrupted by
    /// what, and that belongs on the run rather than in a fourth table.
    fileprivate static func derive(
        from drafts: inout [Draft]
    ) -> (excursions: [Excursion], alternations: [Alternation], interruptions: [Interruption]) {
        var excursionAways: [Pair: [TimeInterval]] = [:]
        var transitions: [Pair: Int] = [:]
        var cycleAways: [Pair: [TimeInterval]] = [:]
        var interruptionAways: [App: [TimeInterval]] = [:]
        var interruptedDurations: [App: TimeInterval] = [:]

        for index in drafts.indices {
            let next = index + 1
            guard next < drafts.count, !drafts[next].severedBefore else { continue }

            // A move from one application to the next, with nothing unobserved in between.
            transitions[Pair(drafts[index].app, drafts[next].app), default: 0] += 1

            let after = next + 1
            guard after < drafts.count,
                !drafts[after].severedBefore,
                drafts[after].app == drafts[index].app
            else { continue }

            // Left, and came back: the excursion, the cycle and the interruption are the same event
            // seen three ways.
            let away = drafts[next].activeDuration
            let direction = Pair(drafts[index].app, drafts[next].app, ordered: true)
            excursionAways[direction, default: []].append(away)
            cycleAways[Pair(drafts[index].app, drafts[next].app), default: []].append(away)
            interruptionAways[drafts[next].app, default: []].append(away)
            interruptedDurations[drafts[next].app, default: 0] += drafts[index].activeDuration
            drafts[index].interruptedBy = drafts[next].app
        }

        return (
            excursions: excursions(from: excursionAways),
            alternations: alternations(transitions: transitions, cycleAways: cycleAways),
            interruptions: interruptions(
                aways: interruptionAways, interrupted: interruptedDurations
            )
        )
    }

    /// Two applications, keyed either as an ordered move or as an unordered rhythm.
    ///
    /// One type for both so a pair is canonicalised in exactly one place. `ordered` keeps `A → B`
    /// apart from `B → A` for excursions, where the direction is the whole point; the unordered form
    /// sorts the two so `{A, B}` and `{B, A}` land on the same alternation row.
    fileprivate struct Pair: Hashable {
        let left: App
        let right: App
        let ordered: Bool

        init(_ left: App, _ right: App, ordered: Bool = false) {
            if ordered || left <= right {
                self.left = left
                self.right = right
            } else {
                self.left = right
                self.right = left
            }
            self.ordered = ordered
        }
    }

    fileprivate static func excursions(from aways: [Pair: [TimeInterval]]) -> [Excursion] {
        aways
            .map { pair, values in
                Excursion(
                    from: pair.left,
                    to: pair.right,
                    count: values.count,
                    totalAway: values.reduce(0, +),
                    medianAway: median(values)
                )
            }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                if left.totalAway != right.totalAway { return left.totalAway > right.totalAway }
                return (left.from, left.to) < (right.from, right.to)
            }
    }

    fileprivate static func alternations(
        transitions: [Pair: Int],
        cycleAways: [Pair: [TimeInterval]]
    ) -> [Alternation] {
        transitions
            .map { pair, count in
                let aways = cycleAways[pair] ?? []
                return Alternation(
                    first: pair.left,
                    second: pair.right,
                    transitions: count,
                    cycles: aways.count,
                    medianAway: median(aways)
                )
            }
            .sorted { left, right in
                if left.transitions != right.transitions {
                    return left.transitions > right.transitions
                }
                if left.cycles != right.cycles { return left.cycles > right.cycles }
                return (left.first, left.second) < (right.first, right.second)
            }
    }

    fileprivate static func interruptions(
        aways: [App: [TimeInterval]],
        interrupted: [App: TimeInterval]
    ) -> [Interruption] {
        aways
            .map { app, values in
                Interruption(
                    app: app,
                    count: values.count,
                    totalAway: values.reduce(0, +),
                    medianAway: median(values),
                    interruptedDuration: interrupted[app] ?? 0
                )
            }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                if left.totalAway != right.totalAway { return left.totalAway > right.totalAway }
                return left.app < right.app
            }
    }

    /// The middle value, averaging the two middles for an even count. `0` for nothing at all, which
    /// is only ever read alongside a `count` of zero.
    fileprivate static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}
