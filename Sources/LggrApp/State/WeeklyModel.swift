import Foundation
import LggrKit

// The week, assembled: the state behind Weekly Review. See docs/_design/SPEC.md § 8 and § 9.
//
// This object loads a week and hands it to `WeeklyReviewBuilder`. It computes **nothing** about the
// week itself — no shares, no totals, no sentences. Every number the screen shows comes out of
// `WeeklyReview`, and every sentence comes out of `InsightGenerator`, which is why the same week
// always reads the same way whether it is opened here, exported to Markdown, or asserted in a test.
//
// Two measurements arrive from two different places and are deliberately never added together:
//
//   * **Session time** — from `LggrStore`. Time the user declared.
//   * **Observed time** — from the day files in `ActivityLog`, run back through `EpisodeBuilder` one
//     day at a time. Time applications were in front of them, session or no session.
//
// The activity log is optional. A host that has none gets a review with no episodes, which is the
// honest outcome: the category breakdown and the per-day context-switch counts are then absent from
// the screen rather than rendered as zeros. A zero there would be a claim that Lggr watched all week
// and saw nothing.

/// The state behind `WeeklyReviewView`: one week, built, plus the outcomes the user can edit.
@MainActor
@Observable
public final class WeeklyModel {

    /// Where the week currently stands.
    ///
    /// `.failed` carries a sentence about the record rather than about the user, and it never
    /// replaces the week already on screen: a week that loaded a minute ago and cannot be re-read is
    /// still the truest thing the app has.
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    // MARK: - Published state

    /// The week under review, as `WeeklyReviewBuilder` computed it. Always describes `week`: a
    /// navigation resets it to an empty week of the new range before the load starts, so the header
    /// and the sections can never disagree about which week is on screen.
    public private(set) var review: WeeklyReview

    /// The sentences the evidence supports, in `WeeklyObservation.Kind` order. Fewer than seven is
    /// normal and none at all is a valid week; nothing here pads the list.
    public private(set) var observations: [WeeklyObservation] = []

    public private(set) var projects: [Project] = []

    public private(set) var phase: Phase = .idle

    /// Set when a write failed. Surfaced by the host's error banner (`04-screens.md` § 3.3).
    public private(set) var lastError: String?

    /// Set when part of the week's application activity could not be read. Stated rather than
    /// swallowed: a damaged day must never be indistinguishable from a day nobody worked.
    public private(set) var activityNotice: String?

    // MARK: - Collaborators

    @ObservationIgnored private let store: any LggrStore
    @ObservationIgnored private let activityLog: (any ActivityLog)?
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let windows: CalendarWindows
    @ObservationIgnored private let weights: SegmentationWeights

    /// The window every load reads. Kept in step with `review.week` by `show(_:)`.
    @ObservationIgnored private var week: DateInterval

    /// Guards against two loads overlapping. A request that arrives mid-load is remembered rather
    /// than dropped, so a save that lands during a read still refreshes the screen.
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var reloadRequested = false

    // MARK: - Init

    public init(
        store: any LggrStore,
        activityLog: (any ActivityLog)? = nil,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        weights: SegmentationWeights = .default
    ) {
        self.store = store
        self.activityLog = activityLog
        self.clock = clock
        self.calendar = calendar
        self.windows = CalendarWindows(calendar: calendar)
        self.weights = weights

        let interval = WeeklyModel.week(containing: clock.now, in: calendar)
        self.week = interval
        self.review = WeeklyReviewBuilder.build(
            WeeklyReviewInput(week: interval, calendar: calendar)
        )
    }

    /// The week around `date`, or a seven-day window from its midnight if the calendar cannot resolve
    /// one. Stated rather than force-unwrapped; unreachable with any real calendar.
    private static func week(containing date: Date, in calendar: Calendar) -> DateInterval {
        if let interval = CalendarWindows(calendar: calendar).week(containing: date) {
            return interval
        }
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, duration: 7 * 24 * 60 * 60)
    }

    // MARK: - Derived

    /// Whether the week on screen is the one the user is living in. The host passes this to the view,
    /// which uses it to retire both the "next week" step and the "This week" shortcut — a control
    /// that cannot do anything does not sit there pretending it can.
    public var isViewingCurrentWeek: Bool {
        WeeklyModel.week(containing: clock.now, in: calendar).start == week.start
    }

    /// The review as the Markdown export renders it. Provided for the host's `⌘⇧E`; the screen's own
    /// Copy action renders the same document from the same function.
    public var markdown: String {
        WeeklyReviewMarkdown.render(review, observations: observations)
    }

    /// A blank outcome for the week on screen, seated at `priority`.
    public func newOutcome(priority: OutcomePriority) -> WeeklyOutcome {
        WeeklyOutcome(
            title: "",
            priority: priority,
            weekStartDate: week.start,
            createdAt: clock.now,
            updatedAt: clock.now
        )
    }

    // MARK: - Navigation

    /// Moves the review to the week containing `date` and loads it.
    public func show(_ date: Date) async {
        let interval = WeeklyModel.week(containing: date, in: calendar)
        guard interval.start != week.start else { return }
        week = interval
        // The old week's numbers are dropped rather than left on screen under a new heading. This is
        // the one place a blank moment is correct: the alternative is showing last week's totals
        // labelled as this week's.
        review = WeeklyReviewBuilder.build(WeeklyReviewInput(week: interval, calendar: calendar))
        observations = []
        activityNotice = nil
        phase = .loading
        await load()
    }

    public func showPreviousWeek() async {
        await shift(by: -1)
    }

    public func showNextWeek() async {
        await shift(by: 1)
    }

    public func showCurrentWeek() async {
        await show(clock.now)
    }

    private func shift(by weeks: Int) async {
        guard let moved = calendar.date(byAdding: .weekOfYear, value: weeks, to: week.start) else {
            return
        }
        await show(moved)
    }

    // MARK: - Loading

    /// Reads the week and rebuilds. Called when the screen appears, after every write, and after a
    /// week change.
    public func load() async {
        guard !isLoading else {
            reloadRequested = true
            return
        }
        isLoading = true
        defer { isLoading = false }

        repeat {
            reloadRequested = false
            await read()
        } while reloadRequested
    }

    private func read() async {
        if phase != .ready { phase = .loading }
        let interval = week

        do {
            let projects = try await store.loadProjects()
            let sessions = try await store.loadSessions(in: interval)
            let accomplishments = try await store.loadAccomplishments(in: interval)
            let interruptions = try await store.loadInterruptions(in: interval)
            let outcomes = try await store.loadWeeklyOutcomes(in: interval)
            let activity = await readActivity(sessions: sessions)

            // The week may have moved while the reads were in flight — a keyboard arrow held down is
            // enough. The later navigation already queued its own load, so this result is dropped
            // rather than published against the wrong heading.
            guard interval.start == week.start else { return }

            self.projects = projects
            self.activityNotice = activity.notice

            var names: [UUID: String] = [:]
            for project in projects {
                names[project.id] = project.normalizedName ?? project.name
            }

            let built = WeeklyReviewBuilder.build(
                WeeklyReviewInput(
                    week: interval,
                    sessions: sessions,
                    accomplishments: accomplishments,
                    interruptions: interruptions,
                    episodes: activity.episodes,
                    outcomes: WeeklyOutcomeSet(weekStart: interval.start, outcomes: outcomes),
                    projectNames: names,
                    calendar: calendar
                )
            )
            review = built
            observations = InsightGenerator.observations(for: built)
            phase = .ready
        } catch {
            // The message goes to both: `phase` is what the screen reads, and `lastError` is what the
            // host's banner reads and the user can dismiss (`04-screens.md` § 3.3). A read that failed
            // must not be indistinguishable from a week nobody worked.
            let message = "Lggr could not read this week. Your work is still on disk."
            phase = .failed(message)
            lastError = message
        }
    }

    // MARK: - Observed activity

    /// The week's episodes, rebuilt one day at a time.
    ///
    /// A day is the unit `EpisodeBuilder` works in — it anchors gaps and sealing to a day start — so
    /// a week is seven builds, not one build over seven days of intervals.
    ///
    /// Every day is attempted even when one fails. A single unreadable file must not cost the other
    /// six, and the count of failures becomes a sentence on the screen rather than a silent shortfall.
    private func readActivity(
        sessions: [FocusSession]
    ) async -> (episodes: [Episode], notice: String?) {
        guard let activityLog else { return ([], nil) }

        var episodes: [Episode] = []
        var unreadableDays = 0

        for day in windows.daysIn(week: week) {
            guard let key = ActivityDayKey(date: day.start, in: calendar) else { continue }
            do {
                let record = try await activityLog.load(key)
                guard !record.isEmpty else { continue }
                // Every session of the week is offered to every day. A session edge only cuts where
                // there are intervals to cut, so an edge outside this day contributes nothing, and
                // filtering per day would drop the edges of a session that ran across midnight.
                let timeline = EpisodeBuilder.build(
                    intervals: record.intervals,
                    absences: record.gaps,
                    sessions: sessions,
                    weights: weights,
                    dayStart: day.start,
                    sealed: isSealed(day.start)
                )
                episodes.append(contentsOf: timeline.episodes)
            } catch {
                unreadableDays += 1
            }
        }

        var sentences: [String] = []
        if unreadableDays > 0 {
            sentences.append(
                unreadableDays == 1
                    ? "One day of application activity could not be read, so the activity figures "
                        + "cover the rest of the week."
                    : "\(unreadableDays) days of application activity could not be read, so the "
                        + "activity figures cover the rest of the week."
            )
        }
        if let quarantine = activityLog.quarantineNotice {
            sentences.append(quarantine)
        }
        return (episodes, sentences.isEmpty ? nil : sentences.joined(separator: " "))
    }

    /// A day seals at 04:00 local on the day after it — the hours either side of midnight belong to
    /// the day whose work they are. Every day of a past week is sealed; only today is open.
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

    // MARK: - Outcomes

    /// Saves an outcome and reloads, so the seating in `WeeklyOutcomeSet` is recomputed by the domain
    /// rather than guessed at here.
    public func save(_ outcome: WeeklyOutcome) async {
        guard outcome.normalizedTitle != nil else { return }
        var updated = outcome
        updated.updatedAt = clock.now
        await write(
            failureMessage: "Couldn't save that outcome. Nothing else about the week changed."
        ) {
            try await self.store.saveWeeklyOutcome(updated)
        }
    }

    /// Records the status the user picked. Same path as a full save, so a status set from the review
    /// is the same record as one set in the editor.
    public func setStatus(_ status: OutcomeStatus, for outcome: WeeklyOutcome) async {
        guard status != outcome.status else { return }
        var updated = outcome
        updated.status = status
        await save(updated)
    }

    public func delete(outcomeID: UUID) async {
        await write(
            failureMessage: "Couldn't remove that outcome. The week is unchanged."
        ) {
            try await self.store.deleteWeeklyOutcome(id: outcomeID)
        }
    }

    private func write(failureMessage: String, _ body: () async throws -> Void) async {
        do {
            try await body()
            lastError = nil
            await load()
        } catch {
            lastError = failureMessage
        }
    }

    public func dismissError() {
        lastError = nil
    }
}
