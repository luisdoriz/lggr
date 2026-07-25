import Foundation
import LggrKit

// The day, rebuilt: the state behind Today's timeline strip.
//
// This object owns three things and nothing else — the evidence for the day being shown, the
// sessions that were declared over it, and the `DayTimeline` that `EpisodeBuilder` derives from the
// two. It holds no clock of its own, draws nothing, and knows nothing about the sampler beyond the
// batches the sampler hands it.
//
// **The day is rebuilt when the day changes, not when the clock moves.** `EpisodeBuilder.build` is
// pure and cheap, but "cheap" multiplied by 3,600 ticks an hour is a wasted core and a screen that
// repaints to show the same nine blocks. So there are exactly three things that rebuild a timeline:
// a load, a flush landing, and the declared sessions changing. A tick is not one of them, and this
// type deliberately exposes no `now`.

/// The state behind `DayTimelineStrip`: one day's intervals, run through `EpisodeBuilder`.
@MainActor
@Observable
public final class TimelineModel {

    /// Where the day currently stands.
    ///
    /// `.failed` carries a sentence about the record rather than about the user, and it never
    /// replaces the last good timeline: a day that loaded an hour ago and cannot be re-read is
    /// still the truest thing the app has, and blanking the screen would claim otherwise.
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Published state

    /// The day as it currently stands. Empty until the first load lands.
    public private(set) var timeline: DayTimeline

    public private(set) var phase: Phase = .idle

    /// Set when a day file could not be read and was preserved under another name. Surfaced by the
    /// host, because an unreadable day must never look like a day nobody worked.
    public private(set) var notice: String?

    // MARK: - Collaborators

    @ObservationIgnored private let log: any ActivityLog
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let weights: SegmentationWeights

    // MARK: - Evidence

    /// Both stores are keyed by `id` because every source of activity is an **upsert**: the sampler
    /// republishes its still-open interval on every flush with the end moved forward, and the day
    /// file merges by `id` for the same reason. Keying by anything else would accumulate a new copy
    /// of the open interval once a minute.
    @ObservationIgnored private var intervals: [UUID: ActivityInterval] = [:]
    @ObservationIgnored private var absences: [UUID: Gap] = [:]
    @ObservationIgnored private var sessions: [FocusSession] = []

    @ObservationIgnored private var day: ActivityDayKey?
    @ObservationIgnored private var dayStart: Date

    /// Guards against two loads overlapping. A request that arrives mid-load is remembered rather
    /// than dropped, so a flush that lands during the first read is not lost.
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var reloadRequested = false

    // MARK: - Init

    public init(
        log: any ActivityLog,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        weights: SegmentationWeights = .default
    ) {
        let start = calendar.startOfDay(for: clock.now)
        self.log = log
        self.clock = clock
        self.calendar = calendar
        self.weights = weights
        self.dayStart = start
        self.timeline = DayTimeline(dayStart: start, episodes: [], gaps: [])
    }

    /// The model the running app uses: the day files under Application Support, read through the
    /// same `ActivityLog` the sampler writes.
    ///
    /// Falls back to an in-memory log rather than failing. A machine whose Application Support
    /// directory cannot be opened has a much larger problem than an empty timeline, and the rest of
    /// Today keeps working.
    public static func live(
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> TimelineModel {
        let log: any ActivityLog
        if let file = try? FileActivityLog() {
            log = file
        } else {
            log = InMemoryActivityLog()
        }
        return TimelineModel(log: log, clock: clock, calendar: calendar)
    }

    /// The one instance the main window renders.
    ///
    /// A singleton for the same reason `AppEnvironment.shared` is one: the ambient sampler is
    /// constructed outside the view tree — it runs from launch, whether or not a window is open —
    /// so there is no seam to hand it a model through. The flush handler calls `apply(_:)` on this;
    /// the window reads `timeline` from it.
    public static let shared = TimelineModel.live()

    // MARK: - Derived

    /// Whether there is anything to draw. A day with neither blocks nor gaps has no section.
    public var hasContent: Bool { !timeline.isEmpty }

    // MARK: - Loading

    /// Reads the day being shown out of the activity log and rebuilds.
    ///
    /// Called when the window appears and when the day rolls over — not on a cadence. Everything
    /// that happens while the app is running arrives through `apply(_:)`, which needs no disk.
    ///
    /// The read **merges** into what is already held rather than replacing it, so long as the day is
    /// the same. Two things make that the right choice rather than the lenient one: every record is
    /// keyed by `id` and every write is an upsert, so merging is idempotent; and the log the model
    /// reads may not be the same instance the sampler buffers into, in which case a replace would
    /// quietly discard everything `apply(_:)` had already been given.
    public func load(sessions: [FocusSession]? = nil) async {
        if let sessions { self.sessions = sessions }

        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        repeat {
            reloadRequested = false
            await readCurrentDay()
        } while reloadRequested
    }

    private func readCurrentDay() async {
        let now = clock.now
        let start = calendar.startOfDay(for: now)

        guard let key = ActivityDayKey(date: now, in: calendar) else {
            // Unreachable with any real calendar; stated rather than force-unwrapped.
            phase = .failed("Lggr could not work out which day to show.")
            return
        }

        if phase != .ready { phase = .loading }

        do {
            let record = try await log.load(key)

            if day != key {
                intervals.removeAll()
                absences.removeAll()
                day = key
                dayStart = start
            }
            for interval in record.intervals { intervals[interval.id] = interval }
            for gap in record.gaps { absences[gap.id] = gap }

            notice = log.quarantineNotice
            rebuild()
            phase = .ready
        } catch {
            // The last good timeline stays on screen. A sentence about the record, never about the
            // person, and never a claim that the day was empty.
            phase = .failed(
                "Lggr could not read today's activity. \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Flushes

    /// Folds the sampler's batches in and rebuilds. No disk, no `await`, no clock.
    ///
    /// This is the refresh path while the app runs: the sampler flushes on its heartbeat, on a
    /// switch burst settling, on sleep, on lock and on terminate, and each of those — and only each
    /// of those — moves the timeline.
    public func apply(_ flushes: [ActivityFlush]) {
        guard !flushes.isEmpty else { return }

        guard let day else {
            // Nothing has been loaded yet, so there is no day to merge into. The read that is about
            // to happen picks these up from the log anyway.
            Task { await load() }
            return
        }

        var changed = false
        var latestDay = day

        for flush in flushes {
            guard let key = flush.dayKey(in: calendar) else { continue }
            if key > latestDay { latestDay = key }
            guard key == day else { continue }
            for interval in flush.intervals {
                intervals[interval.id] = interval
                changed = true
            }
            for gap in flush.gaps {
                absences[gap.id] = gap
                changed = true
            }
        }

        // Midnight, or a wake into a new day. Re-reading is what moves the screen onto the day the
        // user is now in; a batch for a day already past is merged where it belongs and ignored here.
        if latestDay > day {
            Task { await load() }
            return
        }

        if changed { rebuild() }
    }

    // MARK: - Sessions

    /// The declared work over this day. A session edge is ground truth to the segmenter and a
    /// session's intended outcome is the only block name in Phase 1 that is not the app's own
    /// reading, so a change to either has to reach the timeline.
    public func update(sessions: [FocusSession]) {
        guard sessions != self.sessions else { return }
        self.sessions = sessions
        rebuild()
    }

    // MARK: - Rebuilding

    private func rebuild() {
        timeline = EpisodeBuilder.build(
            intervals: Array(intervals.values),
            absences: Array(absences.values),
            sessions: sessions,
            weights: weights,
            dayStart: dayStart,
            sealed: isSealed(dayStart)
        )
    }

    /// A day seals at 04:00 local on the day after it — the hours either side of midnight belong to
    /// the day whose work they are. Whether that instant has passed is a question for something with
    /// a clock, which `DayTimeline` deliberately is not.
    private func isSealed(_ dayStart: Date) -> Bool {
        guard
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
            let sealingInstant = calendar.date(
                bySettingHour: DayTimeline.sealingHourLocal,
                minute: 0,
                second: 0,
                of: nextDay
            )
        else { return false }
        return clock.now >= sealingInstant
    }
}
