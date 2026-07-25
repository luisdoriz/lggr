import Foundation

/// Turns a day of raw application activations into the eight or ten blocks a person recognises.
///
/// `build` is a pure function of its arguments. There is no clock inside it, no I/O, no actor and no
/// global state, so the same intervals, sessions and weights produce the same timeline on any
/// machine at any hour, forever. That is what makes the riskiest component of the intelligence layer
/// provable today, against hand-written fixture days, with no permissions and nothing running.
///
/// Every duration it sums comes from `ActivityInterval.monotonicDuration`. Wall-clock dates place
/// blocks on the timeline and measure the silences between them; they never measure work. A clock
/// step, a timezone change or an NTP correction can therefore move a block but cannot inflate one.
///
/// Where the evidence does not support a claim, the builder says nothing rather than something
/// plausible: an absence it cannot account for stays `.unexplained`, a block whose applications
/// disagree about what kind of work it was keeps the roster it can prove, and a session that has not
/// finished yet names nothing at all. A confidently wrong block is worse than no block.
public enum EpisodeBuilder {

    // MARK: - Entry point

    /// Rebuilds one day.
    ///
    /// - Parameters:
    ///   - intervals: What the sampler saw. Any order; overlaps and clock steps are tolerated.
    ///   - absences: Gaps the sampler observed or reconstructed — sleep, a lock, a heartbeat that
    ///     stopped. These are record, not inference, and they always cut.
    ///   - sessions: Declared work. A session edge is ground truth and outranks every heuristic.
    ///   - weights: The shipped constants. Never exposed in the UI.
    ///   - dayStart: The instant the day is anchored to. Defaults to the first thing on the
    ///     timeline, because a day boundary is a calendar question and this function has no calendar.
    ///   - sealed: Whether the day is closed. A caller with a clock answers that question.
    public static func build(
        intervals: [ActivityInterval],
        absences: [Gap] = [],
        sessions: [FocusSession] = [],
        weights: SegmentationWeights = .default,
        dayStart: Date? = nil,
        sealed: Bool = false
    ) -> DayTimeline {
        let observed = resolvedAbsences(absences)
        let edges = sessionEdges(sessions)
        let normalisedRuns = normalised(
            intervals, absences: observed, sessionEdges: edges, weights: weights
        )
        let split = separatingIdleGaps(normalisedRuns, weights: weights)
        let runs = split.runs

        let known = (split.gaps + observed).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let gaps = (known + unexplainedGaps(between: runs, known: known))
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        let boundaries = boundaries(runs, gaps: gaps, sessionEdges: edges)
        let segments = absorbed(
            segmenting(runs, boundaries: boundaries, weights: weights),
            runs: runs,
            boundaries: boundaries,
            weights: weights
        )
        let episodes = segments.enumerated().map {
            episode($1, index: $0, runs: runs, sessions: sessions, weights: weights)
        }

        return DayTimeline(
            dayStart: dayStart ?? anchor(runs: runs, gaps: gaps),
            episodes: episodes,
            gaps: gaps,
            sealed: sealed
        )
    }

    /// The first thing on the timeline, or the reference epoch for a day with nothing in it.
    ///
    /// A day with no evidence has no anchor to derive, and the epoch is the only value available
    /// that is not a reading of a clock this function is forbidden to take.
    private static func anchor(runs: [Run], gaps: [Gap]) -> Date {
        let candidates = runs.map(\.start) + gaps.map(\.start)
        return candidates.min() ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    // MARK: - Stage 0, normalise

    /// One stretch of a single application, after the sampling noise has been taken out of it.
    private struct Run {
        var bundleIdentifier: String
        var displayName: String
        var start: Date
        var end: Date
        /// Monotonic. Never `end - start`.
        var duration: TimeInterval
        var isIdle: Bool
        /// Glances that returned to this application without interrupting it in any sense a person
        /// would recognise.
        var interjections: Int
        /// How many sampled intervals were folded in here. Carried so the episode can report the
        /// size of the evidence behind it rather than the size of the tidied version.
        var sourceCount: Int
    }

    /// - Parameters:
    ///   - absences: Already resolved by `resolvedAbsences`, so it is sorted by start and its members
    ///     do not overlap. That is what lets the contradiction test below walk a single cursor rather
    ///     than rescanning every absence for every interval.
    ///   - sessionEdges: Sorted ascending, deduplicated.
    private static func normalised(
        _ intervals: [ActivityInterval],
        absences: [Gap],
        sessionEdges: [Date],
        weights: SegmentationWeights
    ) -> [Run] {
        let ordered = intervals.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        let edgeSet = Set(sessionEdges)

        var runs: [Run] = []
        runs.reserveCapacity(ordered.count)
        var cursor: Date?
        var absenceIndex = 0

        for interval in ordered {
            // `ordered` and `absences` are both sorted by start and the absences do not overlap, so
            // the earliest absence that could still reach this interval is the first one that has
            // not already ended before it began. Everything before that can never be needed again.
            while absenceIndex < absences.count, absences[absenceIndex].end <= interval.start {
                absenceIndex += 1
            }

            let start = max(interval.start, cursor ?? interval.start)
            let end = max(start, interval.end)
            let wasClipped = start > interval.start
            // Clipping is the one place the wall clock caps the monotonic measurement. The seconds
            // an earlier interval already accounts for cannot also belong to this one, and counting
            // an overlap twice inflates a block for exactly the reason `monotonicDuration` exists.
            let duration =
                wasClipped
                ? min(interval.monotonicDuration, max(0, end.timeIntervalSince(start)))
                : interval.monotonicDuration

            guard end > start || duration > 0 else { continue }
            cursor = end

            for piece in observable(from: start, to: end, absences: absences, from: absenceIndex) {
                let span = end.timeIntervalSince(start)
                let share =
                    span > 0
                    ? duration * (piece.end.timeIntervalSince(piece.start) / span)
                    : duration
                appendSplitAtSessionEdges(
                    interval,
                    from: piece.start,
                    to: piece.end,
                    duration: max(0, min(duration, share)),
                    sessionEdges: sessionEdges,
                    into: &runs
                )
            }
        }

        let tidied = collapsingGlances(droppingBriefRuns(runs, weights: weights), weights: weights)
        return merging(tidied, sessionEdges: edgeSet)
    }

    /// The parts of `start…end` that a supplied absence does not already account for.
    ///
    /// A supplied absence is the sampler's own record that nothing was in front of the user, and
    /// placing a block inside one is exactly the confabulation the gap exists to prevent. But the
    /// two records only conflict where they overlap. The last interval before a crash is the case
    /// that matters: sampling stopped when the process died, not when the heartbeat file was last
    /// written, so that interval routinely runs a little past the last heartbeat. Discarding all of
    /// it throws away the minutes that *were* observed — ten of them, in a twelve-minute interval
    /// that a crash cut two minutes from — and reports them as time nobody saw.
    ///
    /// So the overlap is removed and the remainder kept. An interval swallowed whole returns nothing
    /// and is dropped, which is the original behaviour for the case the original test had in mind.
    ///
    /// - Parameters:
    ///   - absences: Sorted by start, non-overlapping.
    ///   - first: Index of the earliest absence that has not already ended before `start`.
    private static func observable(
        from start: Date,
        to end: Date,
        absences: [Gap],
        from first: Int
    ) -> [(start: Date, end: Date)] {
        guard first < absences.count, absences[first].start < end else { return [(start, end)] }

        // A zero-length interval has no overlap to measure, only a position to test.
        guard end > start else {
            return absences[first].start <= start && start < absences[first].end ? [] : [(start, end)]
        }

        var pieces: [(start: Date, end: Date)] = []
        var cursor = start
        var position = first

        while position < absences.count, absences[position].start < end {
            let absence = absences[position]
            if absence.end > cursor {
                if absence.start > cursor { pieces.append((cursor, min(absence.start, end))) }
                cursor = max(cursor, absence.end)
                if cursor >= end { return pieces }
            }
            position += 1
        }
        if cursor < end { pieces.append((cursor, end)) }
        return pieces
    }

    /// Cuts one sampled interval where the user declared work started or stopped.
    ///
    /// A session edge is ground truth, and the segmenter can only cut where a run ends. An edge that
    /// happens to land inside a single long activation would otherwise be silently unenforceable:
    /// one hour of Xcode with a thirty-six-minute session declared over its first half arrives as one
    /// sixty-minute block wearing the user's own sentence, twenty-four minutes of which they never
    /// declared. That is the user's own words placed over work they were not written about, which is
    /// worse than any heuristic getting it wrong.
    ///
    /// The monotonic measurement is pro-rated across the pieces by their share of the wall clock —
    /// the only division available, since nothing finer was sampled — and the last piece takes the
    /// remainder so the pieces still sum to exactly what was measured.
    private static func appendSplitAtSessionEdges(
        _ interval: ActivityInterval,
        from start: Date,
        to end: Date,
        duration: TimeInterval,
        sessionEdges: [Date],
        into runs: inout [Run]
    ) {
        func append(_ pieceStart: Date, _ pieceEnd: Date, _ pieceDuration: TimeInterval) {
            runs.append(
                Run(
                    bundleIdentifier: interval.bundleIdentifier,
                    displayName: interval.displayName,
                    start: pieceStart,
                    end: pieceEnd,
                    duration: pieceDuration,
                    isIdle: interval.isIdle,
                    interjections: 0,
                    // Each piece is still the one interval that was sampled. Counting it in every
                    // block it reaches is what makes the audit trail usable: a block that reported
                    // no evidence at all could not be traced back to anything.
                    sourceCount: 1
                )
            )
        }

        let span = end.timeIntervalSince(start)
        guard !sessionEdges.isEmpty, span > 0 else {
            append(start, end, duration)
            return
        }
        let interior = sessionEdges.filter { $0 > start && $0 < end }
        guard !interior.isEmpty else {
            append(start, end, duration)
            return
        }

        var pieceStart = start
        var remaining = duration
        for edge in interior {
            let share = duration * (edge.timeIntervalSince(pieceStart) / span)
            let pieceDuration = min(max(0, share), max(0, remaining))
            append(pieceStart, edge, pieceDuration)
            remaining -= pieceDuration
            pieceStart = edge
        }
        append(pieceStart, end, max(0, remaining))
    }

    /// Intervals below `minimumIntervalDuration` are sampling noise: a window that took focus while
    /// another was closing, a launcher, a permission prompt.
    ///
    /// The span is folded into the neighbour so the timeline stays continuous, but the seconds are
    /// not credited to it — they belong to an application that was never really in front of anyone,
    /// and attributing them to a different one would be a small invention rather than a small gap.
    /// A brief run that touches nothing is not noise beside a neighbour; it is the only thing anybody
    /// observed at that hour, so it survives on its own rather than handing its evidence to a block
    /// five hours away. Crediting it forwards is how one second of Chrome at 09:00 turns into an
    /// `intervalCount` of two on a block that starts at 14:00 and a morning that vanishes.
    private static func droppingBriefRuns(_ runs: [Run], weights: SegmentationWeights) -> [Run] {
        guard runs.count > 1 else { return runs }

        // Fold forwards first so a brief run lands in the application that followed it, then mop up
        // a trailing one into whatever preceded it.
        var folded: [Run] = []
        var carried: [Run] = []
        for run in runs {
            if run.duration < weights.minimumIntervalDuration {
                carried.append(run)
                continue
            }
            var current = run
            // The span moves only across brief runs that actually touched this one, and so does the
            // evidence. A silence between them belongs to the timeline, not to the block on either
            // side of it.
            var absorbed = 0
            var frontier = current.start
            for brief in carried.reversed() {
                guard brief.end == frontier else { break }
                frontier = brief.start
                absorbed += 1
            }
            current.start = frontier
            let touching = carried.suffix(absorbed)
            current.sourceCount += touching.reduce(0) { $0 + $1.sourceCount }
            current.interjections += touching.reduce(0) { $0 + $1.interjections }
            folded.append(contentsOf: carried.prefix(carried.count - absorbed))
            carried.removeAll()
            folded.append(current)
        }

        guard !carried.isEmpty else { return folded }
        guard var last = folded.last else { return carried }
        var absorbed = 0
        var frontier = last.end
        for brief in carried {
            guard brief.start == frontier else { break }
            frontier = brief.end
            absorbed += 1
        }
        last.end = frontier
        let touching = carried.prefix(absorbed)
        last.sourceCount += touching.reduce(0) { $0 + $1.sourceCount }
        last.interjections += touching.reduce(0) { $0 + $1.interjections }
        folded[folded.count - 1] = last
        folded.append(contentsOf: carried.dropFirst(absorbed))
        return folded
    }

    /// A cmd-tab to Slack and back is not a context switch in any sense the person who did it
    /// recognises. An activation shorter than `glanceThreshold` that returns to the application it
    /// interrupted is not an interval at all: it increments `interjections` on the run it landed in.
    ///
    /// This removes a large fraction of the activations in a real day, and it is the single change
    /// that stops a morning of editing from arriving as forty-six blocks.
    /// The interrupted application is read off `result`, never off `runs[index - 1]`.
    ///
    /// Those two are not the same run once anything has been collapsed, and the difference is not
    /// cosmetic: in a fast alternation `A, B, A, B, A, …` where every excursion is short,
    /// `runs[index - 1].bundle == runs[index + 1].bundle` is true for the `A`s as well as the `B`s,
    /// so `A` is recorded as interrupting itself and its seconds are thrown away. A thousand seconds
    /// of wall clock came out as six hundred of work with no gap to explain the rest — the
    /// confidently wrong block the whole design is arranged against.
    ///
    /// The two clock tests are the other half of it. An excursion is only a glance if the stream
    /// left and came back with nothing in between: `Xcode, six seconds of Slack, two hours of
    /// silence, Xcode` is a person going home, not a cmd-tab, and the silence must reach the
    /// timeline as a silence.
    private static func collapsingGlances(_ runs: [Run], weights: SegmentationWeights) -> [Run] {
        guard runs.count > 2 else { return runs }
        var result: [Run] = []
        var index = 0

        while index < runs.count {
            let run = runs[index]
            guard index + 1 < runs.count,
                let previous = result.last,
                !run.isIdle,
                run.duration < weights.glanceThreshold,
                previous.bundleIdentifier != run.bundleIdentifier,
                runs[index + 1].bundleIdentifier == previous.bundleIdentifier,
                previous.end == run.start,
                run.end == runs[index + 1].start
            else {
                result.append(run)
                index += 1
                continue
            }

            var interrupted = previous
            interrupted.end = max(interrupted.end, run.end)
            // The glance is reported in `interjections`, never also in `sourceCount`: every folded
            // interval is accounted for in exactly one field, so `intervalCount + interjections` is
            // the number of intervals behind the block and neither number double counts the other.
            interrupted.interjections += 1 + run.interjections
            result[result.count - 1] = interrupted
            index += 1
        }
        return result
    }

    /// Adjacent runs merge only when they touch on the clock and share a bundle identifier **and**
    /// an idle state.
    ///
    /// Merging across the idle boundary would erase the evidence a gap is built from and turn a
    /// lunch break into work. Merging across a silence would do something worse: the same
    /// application either side of an hour nobody observed would become one unbroken hour of it.
    ///
    /// A session edge is preserved for the same reason: the user said the work started there, and a
    /// merge that erased the junction would leave the segmenter with nowhere to cut.
    private static func merging(_ runs: [Run], sessionEdges: Set<Date>) -> [Run] {
        var result: [Run] = []
        for run in runs {
            guard var last = result.last,
                last.end == run.start,
                !sessionEdges.contains(run.start),
                last.bundleIdentifier == run.bundleIdentifier,
                last.isIdle == run.isIdle
            else {
                result.append(run)
                continue
            }
            last.end = max(last.end, run.end)
            last.duration += run.duration
            last.interjections += run.interjections
            last.sourceCount += run.sourceCount
            result[result.count - 1] = last
        }
        return result
    }

    // MARK: - Idle

    /// An unbroken stretch of stillness at least `idleGapThreshold` long stops being reading and
    /// becomes an absence. Shorter idle stays inside the block as ordinary time.
    ///
    /// Idle never defines whether a run was unbroken — any process can zero the idle timer — so this
    /// only ever removes time from a block. It never joins two.
    ///
    /// "Unbroken" is the load-bearing word, and it is checked rather than assumed. A stretch is the
    /// idle runs that actually abut each other: a minute of stillness at 09:00 and another at 12:00
    /// are two stretches, not one, and the three hours between them were not observed by anybody.
    /// Spanning them would assert `Idle` over unobserved time — the confabulation gaps exist to
    /// prevent — and would emit a gap overlapping whatever else already explains those hours.
    private static func separatingIdleGaps(
        _ runs: [Run],
        weights: SegmentationWeights
    ) -> (runs: [Run], gaps: [Gap]) {
        var active: [Run] = []
        var gaps: [Gap] = []
        var stretch: [Run] = []

        func closeStretch() {
            defer { stretch.removeAll() }
            guard let first = stretch.first, let last = stretch.last else { return }
            let span = max(0, last.end.timeIntervalSince(first.start))
            guard span >= weights.idleGapThreshold else {
                active.append(contentsOf: stretch)
                return
            }
            gaps.append(
                Gap(
                    id: identifier(kind: .idleGap, index: gaps.count, start: first.start, end: last.end),
                    reason: .idle,
                    start: first.start,
                    end: last.end
                )
            )
        }

        for run in runs {
            if run.isIdle {
                if let previous = stretch.last, previous.end < run.start { closeStretch() }
                stretch.append(run)
            } else {
                closeStretch()
                active.append(run)
            }
        }
        closeStretch()
        return (active, gaps)
    }

    // MARK: - Gaps

    /// Resolves the absences the sampler supplied into an ordered, non-overlapping record.
    ///
    /// `.systemSleep` and `.appNotRunning` collide every single night — the sampler is not running
    /// while the machine sleeps — and marking the most ordinary event in the corpus as a crash would
    /// make the crash marker worthless on the day it matters. Wherever a sleep explains the same
    /// span, the sleep wins.
    ///
    /// Containment is the wrong test for it, and testing containment in the wrong direction is worse
    /// than not testing at all. The real geometry runs the other way round every night: the last
    /// heartbeat lands *before* `willSleep` and the first one after waking lands *after* `didWake`,
    /// so the heartbeat gap contains the sleep rather than sitting inside it. Under a `covers` test
    /// the heartbeat gap survives, the sleep is then clipped to nothing by the cursor below and
    /// deleted, and an ordinary night renders as "Lggr was not running" for fifteen hours.
    ///
    /// So the sleep is subtracted from the heartbeat gap instead. Whatever is left over is time the
    /// application was genuinely absent and the machine was genuinely awake, which is a real fact
    /// about the day, and it is kept: a crash at noon followed by a sleep at six is two different
    /// things that happened, not one.
    private static func resolvedAbsences(_ absences: [Gap]) -> [Gap] {
        let positive = absences.filter { $0.duration > 0 }
        let sleeps = positive.filter { $0.reason == .systemSleep }.sorted { $0.start < $1.start }

        var resolved: [Gap] = []
        for gap in positive {
            guard gap.reason == .appNotRunning, !sleeps.isEmpty else {
                resolved.append(gap)
                continue
            }
            resolved.append(contentsOf: subtracting(sleeps, from: gap))
        }

        let ordered = resolved.sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        var result: [Gap] = []
        var cursor: Date?

        for gap in ordered {
            let start = max(gap.start, cursor ?? gap.start)
            guard gap.end > start else { continue }
            result.append(
                start == gap.start
                    ? gap
                    : Gap(id: gap.id, reason: gap.reason, start: start, end: gap.end)
            )
            cursor = max(cursor ?? gap.end, gap.end)
        }
        return result
    }

    /// What is left of `gap` once every stretch the machine spent asleep has been taken out of it.
    ///
    /// `sleeps` is sorted by start and may overlap itself; the cursor handles both. An empty result
    /// means the sleep accounted for the whole absence, which is the ordinary night.
    private static func subtracting(_ sleeps: [Gap], from gap: Gap) -> [Gap] {
        var fragments: [Gap] = []
        var cursor = gap.start

        func append(_ start: Date, _ end: Date) {
            guard end > start else { return }
            fragments.append(
                start == gap.start && end == gap.end
                    ? gap
                    : Gap(
                        id: identifier(
                            kind: .clippedAbsence, index: fragments.count, start: start, end: end
                        ),
                        reason: gap.reason,
                        start: start,
                        end: end
                    )
            )
        }

        for sleep in sleeps where sleep.end > gap.start && sleep.start < gap.end {
            append(cursor, min(sleep.start, gap.end))
            cursor = max(cursor, sleep.end)
            if cursor >= gap.end { return fragments }
        }
        append(cursor, gap.end)
        return fragments
    }

    /// Silence between two runs that nothing accounts for.
    ///
    /// This case exists so that an absence the app cannot explain stays an absence. The pressure to
    /// make a timeline look tidy is exactly the pressure that would smear an unexplained hour into
    /// the block beside it and invent work that did not happen.
    /// - Parameter known: Sorted by start and non-overlapping, which is what lets the scan below
    ///   carry a cursor instead of filtering the whole list once per pair of runs.
    private static func unexplainedGaps(between runs: [Run], known: [Gap]) -> [Gap] {
        guard runs.count > 1 else { return [] }
        var result: [Gap] = []
        var first = 0

        for index in 0..<(runs.count - 1) {
            let start = runs[index].end
            let end = runs[index + 1].start
            guard end > start else { continue }

            // Runs are ordered, so `start` never goes backwards: an absence that ended before this
            // silence began can never be reached by a later one either.
            while first < known.count, known[first].end <= start { first += 1 }

            var cursor = start
            var position = first
            while position < known.count, known[position].start < end {
                let gap = known[position]
                if gap.start > cursor {
                    appendUnexplained(from: cursor, to: gap.start, into: &result)
                }
                cursor = max(cursor, gap.end)
                position += 1
            }
            if cursor < end {
                appendUnexplained(from: cursor, to: end, into: &result)
            }
        }
        return result
    }

    /// Any positive silence is emitted, however short.
    ///
    /// A threshold here does not tidy the timeline; it hides the untidiness inside a block. Two Xcode
    /// stretches, 09:00–09:30 and 09:34–10:04, with a four-minute silence nobody observed between
    /// them, become one row reading "9:00–10:04" that claims four minutes it has no evidence for.
    /// The silence is short, so the lie is small — and a small lie in the mechanism whose entire job
    /// is to be trusted about absences is still the mechanism failing. `.unexplained` is a hard
    /// boundary, so emitting it also stops the two stretches being welded into one block.
    private static func appendUnexplained(from start: Date, to end: Date, into result: inout [Gap]) {
        guard end > start else { return }
        result.append(
            Gap(
                id: identifier(kind: .unexplainedGap, index: result.count, start: start, end: end),
                reason: .unexplained,
                start: start,
                end: end
            )
        )
    }

    // MARK: - Stage 2, boundary score

    /// What separates two adjacent runs, computed once and reused by every stage that scores a
    /// boundary.
    private struct Boundary {
        let silence: TimeInterval
        /// A hard gap or a session edge sits here. Nothing may ever be merged across it.
        let isHard: Bool
    }

    /// - Parameters:
    ///   - gaps: Sorted by start and non-overlapping.
    ///   - edges: Sorted ascending.
    ///
    /// Both are walked with a cursor rather than searched. A day of short activations separated by
    /// silence produces one unexplained gap per boundary, and re-scanning every gap at every boundary
    /// is quadratic in exactly the case that generates the most of both.
    private static func boundaries(
        _ runs: [Run],
        gaps: [Gap],
        sessionEdges edges: [Date]
    ) -> [Boundary] {
        guard runs.count > 1 else { return [] }
        let hardGaps = gaps.filter(\.isHardBoundary)

        var result: [Boundary] = []
        result.reserveCapacity(runs.count - 1)
        var first = 0

        for index in 0..<(runs.count - 1) {
            let start = runs[index].end
            let end = runs[index + 1].start
            while first < hardGaps.count, hardGaps[first].end <= start { first += 1 }
            // `hardGaps` does not overlap itself, so the earliest gap that has not already ended is
            // the only one that can reach this boundary.
            let hasHardGap = first < hardGaps.count && hardGaps[first].start < end
            let edge = firstEdge(edges, atLeast: start)
            let hasSessionEdge = edge < edges.count && edges[edge] <= end
            result.append(
                Boundary(
                    silence: max(0, end.timeIntervalSince(start)),
                    isHard: hasHardGap || hasSessionEdge
                )
            )
        }
        return result
    }

    /// The position of the first edge at or after `date` in an ascending array.
    private static func firstEdge(_ edges: [Date], atLeast date: Date) -> Int {
        var low = 0
        var high = edges.count
        while low < high {
            let middle = low + (high - low) / 2
            if edges[middle] < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The instants a user declared, ascending and deduplicated. A session that has not finished
    /// contributes only its start: where it ends is a question for a caller with a clock, and this
    /// function does not have one.
    private static func sessionEdges(_ sessions: [FocusSession]) -> [Date] {
        let edges = sessions.flatMap { session -> [Date] in
            guard let end = session.endedAt else { return [session.startedAt] }
            return [session.startedAt, max(session.startedAt, end)]
        }
        return Array(Set(edges)).sorted()
    }

    /// The score from §8, applied to two applications either side of a boundary.
    ///
    /// The same function scores a boundary between two sampled intervals and a boundary between two
    /// whole segments; a segment is represented by the application that dominates it, which for a
    /// segment of one interval is that interval's application. One formula, one threshold, one place
    /// to argue about the constants.
    private static func boundaryScore(
        from leftBundle: String,
        to rightBundle: String,
        at index: Int,
        runs: [Run],
        boundaries: [Boundary],
        weights: SegmentationWeights
    ) -> Double {
        guard index >= 0, index < boundaries.count else { return weights.sessionBoundaryScore }
        let boundary = boundaries[index]

        // Ground truth, and the reason `sessionBoundaryScore` is `.infinity`: it is returned rather
        // than multiplied, because zero times infinity is a NaN that would compare false against
        // every threshold and silently stop cutting anywhere.
        guard !boundary.isHard else { return weights.sessionBoundaryScore }

        var score = weights.gapWeight * weights.gapScore(boundary.silence)
        score +=
            weights.evidenceWeight
            * (1 - jaccard(weights.evidenceBag(for: leftBundle), weights.evidenceBag(for: rightBundle)))
        score += weights.categoryWeight * weights.categoryDistance(leftBundle, rightBundle)

        if weights.areSatellites(leftBundle, rightBundle) {
            score -= weights.satelliteBonus
        }
        if returns(
            to: leftBundle, after: index, runs: runs, boundaries: boundaries,
            window: weights.returnWindow
        ) {
            score -= weights.returnBonus
        }
        return score
    }

    /// Leaving an application and coming straight back is one activity being carried out, not two.
    ///
    /// The search is bounded twice over, by the monotonic measurement and by the wall clock, and it
    /// has to be. The monotonic clock does not advance while the machine is asleep, so a run of
    /// intervals can legitimately measure zero seconds each — at which point `elapsed` never grows,
    /// the window never closes, and every boundary on the day scans the whole tail behind it. That
    /// is the difference between a linear pass and thirty-two thousand intervals taking a minute.
    ///
    /// Using the wall clock here does not measure any work: it only decides how far ahead to look.
    private static func returns(
        to bundleIdentifier: String,
        after index: Int,
        runs: [Run],
        boundaries: [Boundary],
        window: TimeInterval
    ) -> Bool {
        var position = index + 1
        guard position < runs.count else { return false }

        let deadline = runs[position].start.addingTimeInterval(max(0, window))
        var elapsed: TimeInterval = 0

        while position < runs.count, elapsed <= window, runs[position].start <= deadline {
            if runs[position].bundleIdentifier == bundleIdentifier { return true }
            elapsed += max(0, runs[position].duration)
            if position < boundaries.count, boundaries[position].isHard { return false }
            position += 1
        }
        return false
    }

    private static func jaccard(_ left: Set<String>, _ right: Set<String>) -> Double {
        let union = left.union(right)
        guard !union.isEmpty else { return 1 }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    // MARK: - Segments

    /// A candidate block: a contiguous range of runs, with the totals every later stage asks for.
    private struct Segment {
        var lower: Int
        var upper: Int
        var duration: TimeInterval
        var appDurations: [String: TimeInterval]
        var bag: Set<String>

        /// The application a person would name this stretch after. Ties break on the bundle
        /// identifier so the choice is total and the same evidence always names the same block.
        var dominantBundle: String {
            appDurations
                .max { left, right in
                    left.value == right.value ? left.key > right.key : left.value < right.value
                }?
                .key ?? ""
        }
    }

    private static func segmenting(
        _ runs: [Run],
        boundaries: [Boundary],
        weights: SegmentationWeights
    ) -> [Segment] {
        guard !runs.isEmpty else { return [] }
        var result: [Segment] = [segment(at: 0, runs: runs, weights: weights)]

        for index in 1..<runs.count {
            let score = boundaryScore(
                from: runs[index - 1].bundleIdentifier,
                to: runs[index].bundleIdentifier,
                at: index - 1,
                runs: runs,
                boundaries: boundaries,
                weights: weights
            )
            let next = segment(at: index, runs: runs, weights: weights)
            if score > weights.boundaryThreshold {
                result.append(next)
            } else if let last = result.last {
                result[result.count - 1] = merged(last, next)
            }
        }
        return result
    }

    private static func segment(at index: Int, runs: [Run], weights: SegmentationWeights) -> Segment {
        let run = runs[index]
        return Segment(
            lower: index,
            upper: index,
            duration: run.duration,
            appDurations: [run.bundleIdentifier: run.duration],
            bag: weights.evidenceBag(for: run.bundleIdentifier)
        )
    }

    private static func merged(_ left: Segment, _ right: Segment) -> Segment {
        var result = left
        absorb(right, into: &result)
        return result
    }

    /// Folds one segment into another, in place.
    ///
    /// In place rather than by value on purpose. `appDurations` and `bag` grow with the number of
    /// distinct applications in a block, and a chain of fragments absorbing forwards one at a time
    /// copies both at every step if the accumulator is rebuilt each time — quadratic in the length
    /// of the chain, on exactly the day whose segments are all too short to stand alone. Every field
    /// here combines commutatively, so absorbing left into right and right into left agree.
    private static func absorb(_ other: Segment, into segment: inout Segment) {
        segment.lower = min(segment.lower, other.lower)
        segment.upper = max(segment.upper, other.upper)
        segment.duration += other.duration
        for (bundle, duration) in other.appDurations {
            segment.appDurations[bundle, default: 0] += duration
        }
        segment.bag.formUnion(other.bag)
    }

    // MARK: - Stage 3, absorb to a fixed point

    /// Merges away every segment too short to be a block a person would recognise, then re-scores
    /// the boundaries that survived, until neither step changes anything.
    ///
    /// Both steps sweep once and collapse chains as they go: a short segment merges into a
    /// neighbour that is itself still being assembled, and the result is examined again in the same
    /// sweep rather than being left for a later pass, so a run of fragments becomes one segment
    /// without the loop going round twice. The same holds for healing, which merges into an
    /// accumulator and re-scores it against what follows. One pass therefore reaches the fixed
    /// point, the second finds nothing to do and returns, and `maximumAbsorptionPasses` is never
    /// approached — `EpisodeBuilderSegmentationTests` asserts that by rebuilding every fixture day
    /// with the cap set to two and getting the same timeline.
    ///
    /// The cap exists so that a change which breaks that reasoning fails loudly rather than
    /// hanging. Termination does not depend on the reasoning at all: a pass either strictly reduces
    /// the segment count or ends the loop, and a segment count cannot fall below one.
    private static func absorbed(
        _ segments: [Segment],
        runs: [Run],
        boundaries: [Boundary],
        weights: SegmentationWeights
    ) -> [Segment] {
        var current = segments
        for _ in 0..<max(1, weights.maximumAbsorptionPasses) {
            let shortened = absorbingShortSegments(
                current, runs: runs, boundaries: boundaries, weights: weights
            )
            let healed = healingBoundaries(
                shortened, runs: runs, boundaries: boundaries, weights: weights
            )
            guard healed.count < current.count else { return healed }
            current = healed
        }
        return current
    }

    /// A segment shorter than `minEpisodeDuration` merges into whichever neighbour shares more
    /// evidence — unless both sides of it are walled off, in which case it is genuinely isolated and
    /// stands alone rather than being smeared into a block it did not belong to. Standing alone is
    /// the honest answer there: a two-minute block between two recorded absences is odd to look at,
    /// and a two-minute block glued to work that happened either side of an hour away is a lie.
    private static func absorbingShortSegments(
        _ segments: [Segment],
        runs: [Run],
        boundaries: [Boundary],
        weights: SegmentationWeights
    ) -> [Segment] {
        guard segments.count > 1 else { return segments }
        var pending = segments
        var result: [Segment] = []
        var index = 0

        func score(_ left: Segment, _ right: Segment) -> Double {
            boundaryScore(
                from: left.dominantBundle,
                to: right.dominantBundle,
                at: left.upper,
                runs: runs,
                boundaries: boundaries,
                weights: weights
            )
        }

        // Every segment here is addressed by position rather than bound to a local. Absorption is
        // always into the side that is already accumulating, and that only stays cheap while the
        // accumulator is referenced from exactly one place: a second binding would put its
        // dictionaries back into shared storage and rebuild them at every step of the chain.
        while index < pending.count {
            guard pending[index].duration < weights.minEpisodeDuration else {
                result.append(pending[index])
                index += 1
                continue
            }

            let canAbsorbLeft = result.last.map { absorbs($0.upper, boundaries, weights) } ?? false

            if canAbsorbLeft,
                let end = excursionEnd(
                    after: result[result.count - 1], from: index, in: pending,
                    runs: runs, boundaries: boundaries, weights: weights
                )
            {
                var bridged = result.removeLast()
                for position in index...end { absorb(pending[position], into: &bridged) }
                pending[end] = bridged
                index = end
                continue
            }

            let canAbsorbRight =
                index + 1 < pending.count && absorbs(pending[index].upper, boundaries, weights)

            switch (canAbsorbLeft, canAbsorbRight) {
            case (false, false):
                result.append(pending[index])
            case (true, false):
                absorb(pending[index], into: &result[result.count - 1])
            case (false, true):
                carryForward(&pending, from: index)
            case (true, true):
                // "Whichever neighbour shares more evidence" is asked of the boundary
                // score, the same measure that decided to cut here in the first place. Sharing more
                // evidence and being separated less are the same question, and answering it twice
                // with two different formulas is how a segmenter acquires a second, undocumented
                // opinion.
                //
                // A tie carries the fragment forward. Backwards would extend a block that is
                // already whole, on no evidence that the fragment was part of that work; forwards
                // lets a run of fragments accumulate into a candidate of its own and be judged
                // again on what it turns out to be.
                if score(result[result.count - 1], pending[index])
                    < score(pending[index], pending[index + 1])
                {
                    absorb(pending[index], into: &result[result.count - 1])
                } else {
                    carryForward(&pending, from: index)
                }
            }
            index += 1
        }
        return result
    }

    /// Hands the fragment at `index` on to `index + 1`, so a run of fragments accumulates.
    ///
    /// The accumulator moves forward and the fresh neighbour is folded into it, rather than the
    /// accumulator being folded into the neighbour. The two produce the same segment — every field
    /// combines commutatively — but only this direction costs one insertion per step instead of
    /// re-inserting everything gathered so far, which is the difference between a linear pass and a
    /// quadratic one on a day whose segments are all too short to stand alone.
    private static func carryForward(_ pending: inout [Segment], from index: Int) {
        let neighbour = pending[index + 1]
        pending.swapAt(index, index + 1)
        absorb(neighbour, into: &pending[index + 1])
    }

    /// Absorption changes what each segment is about, so the boundaries it leaves behind are scored
    /// again. Two stretches of the same call, either side of a glance at the browser, stop being two
    /// once the glance has been absorbed into one of them.
    private static func healingBoundaries(
        _ segments: [Segment],
        runs: [Run],
        boundaries: [Boundary],
        weights: SegmentationWeights
    ) -> [Segment] {
        guard segments.count > 1 else { return segments }
        var result: [Segment] = [segments[0]]

        for segment in segments.dropFirst() {
            guard !result.isEmpty else {
                result.append(segment)
                continue
            }
            let score = boundaryScore(
                from: result[result.count - 1].dominantBundle,
                to: segment.dominantBundle,
                at: result[result.count - 1].upper,
                runs: runs,
                boundaries: boundaries,
                weights: weights
            )
            if score > weights.boundaryThreshold {
                result.append(segment)
            } else {
                absorb(segment, into: &result[result.count - 1])
            }
        }
        return result
    }

    /// Looks ahead for the segment that closes an excursion.
    ///
    /// An excursion is a stretch too short to be a block sitting between two stretches that would
    /// not have been cut from each other without it: twenty minutes of a call, a look at the browser
    /// and a message, then the rest of the same call. Glance collapsing does this for six seconds
    /// between two activations; this does it for three minutes between two blocks, and it is the
    /// only thing that tells an excursion apart from the opening of something new — the applications
    /// on the far side of it do.
    ///
    /// The search stops as soon as the fragments passed over would be long enough to be a block on
    /// their own. Beyond that they are no longer an excursion from anything; they are the work.
    private static func excursionEnd(
        after left: Segment,
        from index: Int,
        in pending: [Segment],
        runs: [Run],
        boundaries: [Boundary],
        weights: SegmentationWeights
    ) -> Int? {
        var span: TimeInterval = 0
        var position = index

        while position + 1 < pending.count, absorbs(pending[position].upper, boundaries, weights) {
            let candidate = pending[position + 1]
            // Both boundaries are scored and the worse one decides, so a fragment with a silence on
            // one side of it is never bridged across that silence.
            let opening = boundaryScore(
                from: left.dominantBundle, to: candidate.dominantBundle, at: left.upper,
                runs: runs, boundaries: boundaries, weights: weights
            )
            let closing = boundaryScore(
                from: left.dominantBundle, to: candidate.dominantBundle, at: pending[position].upper,
                runs: runs, boundaries: boundaries, weights: weights
            )
            if max(opening, closing) <= weights.boundaryThreshold { return position + 1 }

            span += pending[position].duration
            guard span < weights.minEpisodeDuration,
                candidate.duration < weights.minEpisodeDuration
            else { return nil }
            position += 1
        }
        return nil
    }

    /// Whether a short segment may be absorbed across this boundary at all.
    ///
    /// Absorption exists to undo cuts the score made too finely, so it is allowed to cross one — but
    /// never a saturated silence. A recorded absence is structural evidence that outscores every
    /// bonus combined, and a block that straddled one would be a block that claimed time nothing was
    /// observed in. That is the lunch break turning back into work.
    private static func absorbs(
        _ index: Int,
        _ boundaries: [Boundary],
        _ weights: SegmentationWeights
    ) -> Bool {
        guard index >= 0, index < boundaries.count else { return false }
        let boundary = boundaries[index]
        return !boundary.isHard && weights.gapScore(boundary.silence) < 1
    }

    // MARK: - Stage 4, name

    private static func episode(
        _ segment: Segment,
        index: Int,
        runs: [Run],
        sessions: [FocusSession],
        weights: SegmentationWeights
    ) -> Episode {
        let members = runs[segment.lower...segment.upper]
        let start = members.map(\.start).min() ?? Date(timeIntervalSinceReferenceDate: 0)
        let end = max(start, members.map(\.end).max() ?? start)

        var order: [String] = []
        var durations: [String: TimeInterval] = [:]
        var names: [String: String] = [:]
        var visits: [String: Int] = [:]
        var previousBundle: String?

        for run in members {
            let bundle = run.bundleIdentifier
            if durations[bundle] == nil {
                order.append(bundle)
                durations[bundle] = 0
                visits[bundle] = 0
                names[bundle] = run.displayName
            }
            durations[bundle, default: 0] += run.duration
            // A change of idle state is not a visit: the application never left the front.
            if previousBundle != bundle { visits[bundle, default: 0] += 1 }
            previousBundle = bundle
        }

        let shares: [Episode.AppShare] = order.map { bundle in
            Episode.AppShare(
                bundleIdentifier: bundle,
                displayName: names[bundle] ?? bundle,
                duration: durations[bundle] ?? 0,
                visitCount: visits[bundle] ?? 0
            )
        }
        let apps: [Episode.AppShare] = shares.sorted { left, right in
            if left.duration == right.duration {
                return left.bundleIdentifier < right.bundleIdentifier
            }
            return left.duration > right.duration
        }

        let identifier = identifier(kind: .episode, index: index, start: start, end: end)
        let interjections = members.reduce(0) { $0 + $1.interjections }
        let intervalCount = members.reduce(0) { $0 + $1.sourceCount }

        // The roster is asked of a draft rather than reimplemented here, so a block's name and
        // `Episode.appRoster(limit:)` can never drift apart.
        let draft = Episode(
            id: identifier,
            start: start,
            end: end,
            apps: apps,
            interjections: interjections,
            label: "",
            labelConfidence: .appRoster,
            sessionID: nil,
            intervalCount: intervalCount
        )
        let naming = name(draft, sessions: sessions, weights: weights)

        return Episode(
            id: identifier,
            start: start,
            end: end,
            apps: apps,
            interjections: interjections,
            label: naming.label,
            labelConfidence: naming.confidence,
            sessionID: naming.sessionID,
            intervalCount: intervalCount
        )
    }

    /// Strict precedence, first match wins.
    private static func name(
        _ episode: Episode,
        sessions: [FocusSession],
        weights: SegmentationWeights
    ) -> (label: String, confidence: LabelConfidence, sessionID: UUID?) {
        // 1. The user's own sentence, verbatim, when this block is mostly that session.
        let session = declaringSession(for: episode, sessions: sessions, weights: weights)
        if let session {
            let outcome = session.intendedOutcome.trimmingCharacters(in: .whitespacesAndNewlines)
            if !outcome.isEmpty {
                return (outcome, .declared, session.id)
            }
        }

        // 2. Reserved for the identifiers a window-title grammar would extract — a repository slug,
        // an issue key. Phase 4 fills this in once the title probe has earned it. It is deliberately
        // left unimplemented rather than approximated: a name guessed from evidence Lggr does not
        // have is the confidently wrong block the whole design is arranged to avoid.

        // 3. The category, but only when it is unanimous and the roster has stopped being a list a
        // person reads. A merely dominant category would name a block after work it only partly
        // contains, which claims more than the evidence supports.
        if episode.apps.count > weights.appRosterLimit,
            let shared = unanimousCategory(episode.apps, weights: weights)
        {
            return (shared.displayName, .category, session?.id)
        }

        // 4. The applications, by descending time. Claims nothing beyond what was on screen.
        return (episode.appRoster(limit: weights.appRosterLimit), .appRoster, session?.id)
    }

    /// The session this block is mostly inside, if there is one.
    ///
    /// Measured against the block's own span: a session that overlaps a sliver of it describes some
    /// other work, and borrowing its sentence would put the user's own words on a block they were
    /// not written about. A session still running has no measurable span here, because working out
    /// where it ends needs a clock.
    private static func declaringSession(
        for episode: Episode,
        sessions: [FocusSession],
        weights: SegmentationWeights
    ) -> FocusSession? {
        let span = episode.wallClockSpan
        guard span > 0 else { return nil }

        let candidates = sessions.compactMap { session -> (session: FocusSession, overlap: TimeInterval)? in
            guard let ended = session.endedAt else { return nil }
            let start = max(episode.start, session.startedAt)
            let end = min(episode.end, max(session.startedAt, ended))
            let overlap = max(0, end.timeIntervalSince(start))
            guard overlap / span >= weights.sessionOverlapFraction else { return nil }
            return (session, overlap)
        }

        return candidates
            .max { left, right in
                if left.overlap != right.overlap { return left.overlap < right.overlap }
                if left.session.startedAt != right.session.startedAt {
                    return left.session.startedAt > right.session.startedAt
                }
                return left.session.id.uuidString > right.session.id.uuidString
            }?
            .session
    }

    /// The one category every application in the block agrees on, or `nil` when any of them is
    /// unknown or they disagree. An unknown application means the block contains work the table
    /// cannot classify, and a category claimed over it would be claimed over nothing.
    private static func unanimousCategory(
        _ apps: [Episode.AppShare],
        weights: SegmentationWeights
    ) -> AppCategory? {
        guard !apps.isEmpty else { return nil }
        let categories = Set(apps.map { weights.category(of: $0.bundleIdentifier) })
        guard categories.count == 1, let only = categories.first, only != .unknown else { return nil }
        return only
    }

    // MARK: - Identifiers

    private enum IdentifierKind: UInt8 {
        case episode = 0xE9
        case idleGap = 0x1D
        case unexplainedGap = 0x11
        /// A supplied absence that had to be cut into pieces, because something else explains part
        /// of the same span.
        case clippedAbsence = 0xCA
    }

    /// A stable identifier derived from the content it names.
    ///
    /// `UUID()` is a reading of the system's random source, which would make two builds over the
    /// same day differ — and a day that cannot be re-derived byte for byte cannot be sealed.
    /// `Hashable.hashValue` is seeded per process and is no better, so the mix is written out here.
    private static func identifier(kind: IdentifierKind, index: Int, start: Date, end: Date) -> UUID {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325

        func mix(_ value: UInt64) {
            var remaining = value
            for _ in 0..<8 {
                hash = (hash ^ (remaining & 0xFF)) &* 0x0000_0100_0000_01b3
                remaining >>= 8
            }
        }

        mix(start.timeIntervalSinceReferenceDate.bitPattern)
        mix(end.timeIntervalSinceReferenceDate.bitPattern)
        mix(UInt64(bitPattern: Int64(index)))

        let position = UInt32(truncatingIfNeeded: index)
        return UUID(
            uuid: (
                0x1D, 0xA1, 0xF1, kind.rawValue,
                UInt8(truncatingIfNeeded: position >> 24),
                UInt8(truncatingIfNeeded: position >> 16),
                UInt8(truncatingIfNeeded: position >> 8),
                UInt8(truncatingIfNeeded: position),
                UInt8(truncatingIfNeeded: hash >> 56),
                UInt8(truncatingIfNeeded: hash >> 48),
                UInt8(truncatingIfNeeded: hash >> 40),
                UInt8(truncatingIfNeeded: hash >> 32),
                UInt8(truncatingIfNeeded: hash >> 24),
                UInt8(truncatingIfNeeded: hash >> 16),
                UInt8(truncatingIfNeeded: hash >> 8),
                UInt8(truncatingIfNeeded: hash)
            ))
    }
}
