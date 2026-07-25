import Foundation
import LggrKit

// The state behind Focus Sessions (`⌘2`). See docs/_design/04-screens.md § 4.2 and SPEC.md § 10.
//
// Two things shape this file:
//
//   * **History is read a window at a time.** A year of sessions is a few thousand rows, and a
//     screen that loads all of them to show you last Tuesday is a screen that gets slower every week
//     you use it. So the model owns a `HistoryWindow` — a month, a quarter or a year — asks the store
//     for exactly that interval, and the screen states which window it is showing. There is no
//     "load more": a date range is a place, and a place can be navigated back to. A button that
//     grows a list cannot.
//   * **Nothing here is a score.** The window carries a count of the sessions inside it, which is a
//     fact about the list. There is no total, no streak, no completion rate and no share-of-day —
//     `INTELLIGENCE.md` § 3.4 removed every headline number that behaves like one, four times over,
//     and a history screen is exactly where the fifth would arrive.
//
// The screen renders from plain values (`Day`, `Detail`, `HistoryWindow.Display`) rather than from
// this object, so it photographs and reviews without a store. This model is what the running app
// hands it.

// MARK: - The window

/// The stretch of history a screen is currently showing.
///
/// A window rather than a page, because the user's question is "what did I do in July", not "what
/// are rows 40 to 60". Both history screens share this type so that stepping back a month means the
/// same thing on each of them, and so the two agree on how a range is spelled.
public struct HistoryWindow: Hashable, Sendable {

    /// How much history one window covers.
    ///
    /// Three spans and no fourth. There is deliberately no "everything": the whole point of the
    /// window is that the store is never asked for the entire history at once, and an "All" option
    /// would be a load-everything button wearing a date range's clothes.
    public enum Span: String, CaseIterable, Identifiable, Sendable {
        case month
        case quarter
        case year

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .month: "Month"
            case .quarter: "Quarter"
            case .year: "Year"
            }
        }

        /// How far one step moves, in calendar months, except for `.year` which steps by years.
        fileprivate var monthStride: Int? {
            switch self {
            case .month: 1
            case .quarter: 3
            case .year: nil
            }
        }
    }

    /// Everything a header needs in order to render the window without doing date arithmetic.
    public struct Display: Hashable, Sendable {
        /// "July 2026", "May – Jul 2026", "2026".
        public var title: String
        public var span: Span
        /// The window contains the present, so "back" is history and "forward" is the future.
        public var isCurrent: Bool
        /// False when stepping forward would leave the present behind. The control is disabled
        /// rather than absent, so the row does not change width as the user walks backwards.
        public var canStepForward: Bool

        public init(title: String, span: Span, isCurrent: Bool, canStepForward: Bool) {
            self.title = title
            self.span = span
            self.isCurrent = isCurrent
            self.canStepForward = canStepForward
        }
    }

    public var span: Span
    /// Any instant inside the window. The window itself is derived from a `Calendar`, so this is a
    /// reference point rather than a boundary.
    public var anchor: Date

    public init(span: Span = .month, anchor: Date) {
        self.span = span
        self.anchor = anchor
    }

    // MARK: Resolution

    /// The window as an interval, or `nil` if the calendar cannot resolve it.
    ///
    /// Every boundary here comes from `Calendar`. Nothing in Lggr builds a month by multiplying
    /// 86,400 by 30 — see `CalendarWindows` for the same rule applied to days and weeks.
    public func interval(in calendar: Calendar) -> DateInterval? {
        switch span {
        case .month:
            return calendar.dateInterval(of: .month, for: anchor)
        case .year:
            return calendar.dateInterval(of: .year, for: anchor)
        case .quarter:
            // The anchor's month plus the two before it. Rolling rather than aligned to Jan/Apr/Jul:
            // a fixed quarter would make "step back one" jump between two and four months of context
            // depending on where the user happened to be standing.
            guard
                let month = calendar.dateInterval(of: .month, for: anchor),
                let start = calendar.date(byAdding: .month, value: -2, to: month.start)
            else { return nil }
            return DateInterval(start: start, end: month.end)
        }
    }

    /// The window moved by `steps`, negative for earlier.
    public func stepped(by steps: Int, in calendar: Calendar) -> HistoryWindow {
        guard steps != 0 else { return self }
        let moved: Date?
        if let stride = span.monthStride {
            moved = calendar.date(byAdding: .month, value: steps * stride, to: anchor)
        } else {
            moved = calendar.date(byAdding: .year, value: steps, to: anchor)
        }
        guard let moved else { return self }
        return HistoryWindow(span: span, anchor: moved)
    }

    /// The same anchor read at a different span.
    public func withSpan(_ span: Span) -> HistoryWindow {
        HistoryWindow(span: span, anchor: anchor)
    }

    public func contains(_ date: Date, in calendar: Calendar) -> Bool {
        guard let interval = interval(in: calendar) else { return false }
        // Half-open, matching `StoreOrdering.contains`: one window's end is the next one's start, and
        // a record stamped exactly on the boundary must belong to one window only.
        return date >= interval.start && date < interval.end
    }

    public func display(now: Date, in calendar: Calendar) -> Display {
        Display(
            title: title(in: calendar),
            span: span,
            isCurrent: contains(now, in: calendar),
            canStepForward: canStepForward(now: now, in: calendar)
        )
    }

    /// Forward is available only while it stays in the past. There is no history in the future, and
    /// a control that walks into empty months is a control that lies about having something to show.
    public func canStepForward(now: Date, in calendar: Calendar) -> Bool {
        guard let interval = interval(in: calendar) else { return false }
        return interval.end <= now
    }

    // MARK: Titles

    /// "July 2026" · "May – Jul 2026" · "2026".
    public func title(in calendar: Calendar) -> String {
        let base = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        switch span {
        case .month:
            return anchor.formatted(base.month(.wide).year())
        case .year:
            return anchor.formatted(base.year())
        case .quarter:
            guard let interval = interval(in: calendar) else {
                return anchor.formatted(base.month(.wide).year())
            }
            // The last instant *inside* the window, so a quarter ending on 1 August is not labelled
            // as reaching into August.
            let last = interval.end.addingTimeInterval(-1)
            let startYear = calendar.component(.year, from: interval.start)
            let endYear = calendar.component(.year, from: last)
            let monthYear = base.month(.abbreviated).year()
            if startYear == endYear {
                return "\(interval.start.formatted(base.month(.abbreviated))) – \(last.formatted(monthYear))"
            }
            return "\(interval.start.formatted(monthYear)) – \(last.formatted(monthYear))"
        }
    }
}

// MARK: - Sessions

/// The state behind `SessionsListView` and `SessionDetailView`.
@MainActor
@Observable
public final class SessionsModel {

    /// Where a load currently stands.
    ///
    /// `.failed` carries a sentence about the record, never about the user, and it never clears the
    /// rows already on screen: a window that loaded a minute ago and cannot be re-read is still the
    /// truest thing the app has, and blanking it would claim the history was empty.
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    /// One day of the window, with the heading the screen prints above it.
    ///
    /// The heading is computed here rather than in the view because "Today" and "Yesterday" are
    /// questions about the clock, and a view that formats relative dates cannot be tested without
    /// one. See `dayHeading(for:)`.
    public struct Day: Identifiable, Equatable, Sendable {
        public let start: Date
        /// "Today" · "Yesterday" · "Tuesday 22 July".
        public let heading: String
        /// Newest first inside the day, which is how § 4.2 orders a group.
        public let sessions: [FocusSession]

        public var id: Date { start }

        public init(start: Date, heading: String, sessions: [FocusSession]) {
            self.start = start
            self.heading = heading
            self.sessions = sessions
        }
    }

    /// Everything one session recorded, gathered for the detail screen.
    ///
    /// Assembled rather than derived from the list, because three of the four collections are not in
    /// the list's window: the episodes live in the activity log, and an accomplishment or an
    /// interruption can be filed after the day the session ran.
    public struct Detail: Equatable, Sendable {
        public var session: FocusSession
        /// The blocks of the reconstructed day that this session's span claimed. Empty when ambient
        /// capture recorded nothing for it — which is the ordinary case for a session run before the
        /// sampler existed, and is why the section is absent rather than empty.
        public var episodes: [Episode]
        public var interruptions: [Interruption]
        public var accomplishments: [Accomplishment]

        public init(
            session: FocusSession,
            episodes: [Episode] = [],
            interruptions: [Interruption] = [],
            accomplishments: [Accomplishment] = []
        ) {
            self.session = session
            self.episodes = episodes
            self.interruptions = interruptions
            self.accomplishments = accomplishments
        }
    }

    // MARK: - Published state

    public private(set) var phase: Phase = .idle

    /// The window being shown. Changed only through `step(_:)`, `setSpan(_:)` and `goToLatest()`, so
    /// every change is followed by a load.
    public private(set) var window: HistoryWindow

    /// Every finished session that started inside the window, newest first.
    ///
    /// A session still running is deliberately absent: it belongs to Today, which is where its live
    /// clock is, and a history row that changes once a second is the opposite of calm.
    public private(set) var sessions: [FocusSession] = []

    /// The session currently open in the detail view, with everything it recorded.
    public private(set) var detail: Detail?
    public private(set) var detailPhase: Phase = .idle

    /// The search field. Matches the intended outcome, the summary and the tangible result — the
    /// three places the user's own words about a session live.
    public var searchText: String = ""

    /// `nil` is "All projects".
    public var projectFilter: UUID?

    // MARK: - Collaborators

    @ObservationIgnored private let store: any LggrStore
    /// The day files ambient capture writes. Optional because a machine whose Application Support
    /// directory cannot be opened still has a perfectly good session history, and the detail view
    /// simply omits the timeline section rather than failing.
    @ObservationIgnored private let log: (any ActivityLog)?
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar

    /// Guards two loads overlapping, and remembers a request that arrived mid-load rather than
    /// dropping it — the same arrangement `TimelineModel` uses, for the same reason.
    @ObservationIgnored private var isLoading = false
    @ObservationIgnored private var reloadRequested = false

    public init(
        store: any LggrStore,
        log: (any ActivityLog)? = nil,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        span: HistoryWindow.Span = .month
    ) {
        self.store = store
        self.log = log
        self.clock = clock
        self.calendar = calendar
        self.window = HistoryWindow(span: span, anchor: clock.now)
    }

    /// The model the running app uses: the same store the rest of the app writes, plus the day files
    /// the sampler writes, read through the same `ActivityLog` type.
    public static func live(
        store: any LggrStore,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> SessionsModel {
        SessionsModel(store: store, log: try? FileActivityLog(), clock: clock, calendar: calendar)
    }

    // MARK: - Derived

    public var windowDisplay: HistoryWindow.Display {
        window.display(now: clock.now, in: calendar)
    }

    /// Whether the window holds anything at all, before the filters narrow it.
    ///
    /// This is what lets the screen tell "you have not started a session yet" apart from "there is
    /// nothing in June" — two facts that want two different sentences and only one of which should
    /// ever offer to start a session.
    public var hasSessionsInWindow: Bool { !sessions.isEmpty }

    public var isFiltering: Bool {
        !normalizedSearch.isEmpty || projectFilter != nil
    }

    /// The search text as it is matched: trimmed, and empty when the user typed only spaces.
    public var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The window's sessions after search and project filter, newest first.
    public var filteredSessions: [FocusSession] {
        let query = normalizedSearch
        return sessions.filter { session in
            if let projectFilter, session.projectID != projectFilter { return false }
            guard !query.isEmpty else { return true }
            return Self.matches(session, query: query)
        }
    }

    /// The filtered window, grouped by day, newest day first.
    public var days: [Day] {
        Self.group(filteredSessions, in: calendar, now: clock.now)
    }

    /// Sessions in the window that finished without an answer to "What happened?".
    ///
    /// Offered, never counted at the user: the number is used to decide whether a quiet line is
    /// worth printing, and the line names the sessions rather than the omission.
    public var unreviewedSessions: [FocusSession] {
        sessions.filter { $0.resultStatus == nil }
    }

    public func project(for id: UUID?, in projects: [Project]) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func clearFilters() {
        searchText = ""
        projectFilter = nil
    }

    // MARK: - Window navigation

    /// Steps the window and loads it. Forward past the present is refused rather than clamped, so
    /// the disabled control and the method agree.
    public func step(_ steps: Int) async {
        if steps > 0, !window.canStepForward(now: clock.now, in: calendar) { return }
        window = window.stepped(by: steps, in: calendar)
        await load()
    }

    public func setSpan(_ span: HistoryWindow.Span) async {
        guard span != window.span else { return }
        window = window.withSpan(span)
        await load()
    }

    /// Returns to the window containing the present.
    public func goToLatest() async {
        let latest = HistoryWindow(span: window.span, anchor: clock.now)
        guard latest != window else { return }
        window = latest
        await load()
    }

    // MARK: - Loading

    /// Reads the window out of the store.
    ///
    /// Called when the screen appears and after every window change. Coalesced, so a burst of
    /// changes — the user holding the back chevron down — costs one read per settle rather than one
    /// per keystroke.
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

    /// Re-reads the window. Spelled separately from `load()` so call sites read as what they mean.
    public func reload() async {
        await load()
    }

    /// Re-reads only when the window contains the present.
    ///
    /// This is what a session finishing elsewhere in the app calls. A user looking at March does not
    /// want the screen to move because something happened today.
    public func reloadIfCurrent() async {
        guard window.contains(clock.now, in: calendar) else { return }
        await load()
    }

    private func read() async {
        guard let interval = window.interval(in: calendar) else {
            phase = .failed("Lggr could not work out which dates to show.")
            return
        }

        if phase != .ready { phase = .loading }

        do {
            // The store already orders newest first and filters half-open; re-sorting here would be
            // a second opinion about ordering that `StoreOrdering` exists to prevent.
            sessions = try await store.loadSessions(in: interval).filter(\.isFinished)
            phase = .ready
        } catch {
            phase = .failed("Couldn't load your sessions. Your work is still on disk.")
        }
    }

    // MARK: - Detail

    /// Opens a session, then fills in everything around it.
    ///
    /// The session itself is published immediately from the row the user clicked, so the screen draws
    /// at once and the three surrounding collections arrive underneath it. A detail view that waits
    /// for its activity log before printing the outcome would feel slower than the list it came from.
    public func openDetail(_ session: FocusSession) async {
        if detail?.session.id != session.id {
            detail = Detail(session: session)
        }
        detailPhase = .loading

        let day = detailInterval(around: session)
        var episodes: [Episode] = []
        var interruptions: [Interruption] = []
        var accomplishments: [Accomplishment] = []
        var failure: String?

        do {
            interruptions = try await store.loadInterruptions(in: day)
                .filter { $0.focusSessionID == session.id }
            accomplishments = try await store.loadAccomplishments(in: day)
                .filter { $0.focusSessionID == session.id }
        } catch {
            failure = "Couldn't load everything this session recorded."
        }

        episodes = await loadEpisodes(for: session)

        // The user may have navigated on while this was in flight.
        guard detail?.session.id == session.id else { return }

        detail = Detail(
            session: detail?.session ?? session,
            episodes: episodes,
            interruptions: interruptions,
            accomplishments: accomplishments
        )
        detailPhase = failure.map(Phase.failed) ?? .ready
    }

    /// Opens a session the model may not be holding.
    ///
    /// A pushed detail outlives the range it was pushed from — the user can step the window while a
    /// session is open, or follow "Open source session" from the log to a session six months back — so
    /// the route carries an id and this resolves it, from the loaded range when it is there and from
    /// the store when it is not.
    public func openDetail(sessionID: UUID) async {
        if let loaded = sessions.first(where: { $0.id == sessionID }) {
            await openDetail(loaded)
            return
        }
        detailPhase = .loading
        do {
            guard let session = try await store.loadSession(id: sessionID) else {
                detail = nil
                detailPhase = .failed("That session is no longer in your history.")
                return
            }
            await openDetail(session)
        } catch {
            detail = nil
            detailPhase = .failed("Couldn't open that session. Your work is still on disk.")
        }
    }

    public func closeDetail() {
        detail = nil
        detailPhase = .idle
    }

    /// The blocks the reconstructed day gave this session.
    ///
    /// Rebuilt through `EpisodeBuilder` rather than stored: a session edge is ground truth to the
    /// segmenter, so the blocks a session claims depend on every session declared that day. Asking
    /// the shipped builder is the only way to get the same rows Today would draw.
    private func loadEpisodes(for session: FocusSession) async -> [Episode] {
        guard
            let log,
            let key = ActivityDayKey(date: session.startedAt, in: calendar),
            let day = calendar.dateInterval(of: .day, for: session.startedAt)
        else { return [] }

        do {
            let record = try await log.load(key)
            guard !record.isEmpty else { return [] }
            let declared = try await store.loadSessions(in: day).filter(\.isFinished)
            let timeline = EpisodeBuilder.build(
                intervals: record.intervals,
                absences: record.gaps,
                sessions: declared,
                dayStart: day.start
            )
            return timeline.episodes.filter { $0.sessionID == session.id }
        } catch {
            // A day file that cannot be read costs the timeline section and nothing else. The
            // session's own record is intact and is what the screen is mostly made of.
            return []
        }
    }

    /// The session's own day and the one after it.
    ///
    /// Interruptions land during the session, so its day would do — but an accomplishment is often
    /// filed the following morning, and a "Delivered" section that silently omits it would be the
    /// screen disagreeing with the log.
    private func detailInterval(around session: FocusSession) -> DateInterval {
        let start = calendar.startOfDay(for: session.startedAt)
        guard let end = calendar.date(byAdding: .day, value: 2, to: start) else {
            return DateInterval(start: start, duration: 48 * 60 * 60)
        }
        return DateInterval(start: start, end: end)
    }

    // MARK: - Applying changes made elsewhere

    /// Folds an edited session back into whatever this model is showing.
    ///
    /// The interface updates first and the disk updates second everywhere in Lggr
    /// (`SessionManager`'s rule 1), so the screen has to be able to accept a value it did not load.
    public func apply(_ session: FocusSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else if window.contains(session.startedAt, in: calendar), session.isFinished {
            sessions.append(session)
            sessions.sort { $0.startedAt > $1.startedAt }
        }
        if detail?.session.id == session.id {
            detail?.session = session
        }
    }

    // MARK: - Matching

    /// Case- and diacritic-insensitive, across the three fields that hold the user's own words about
    /// a session. Deliberately not the work type or the project name: those have their own filter,
    /// and a search that matched them would make "review" return every code-review session.
    nonisolated static func matches(_ session: FocusSession, query: String) -> Bool {
        let haystack = [
            session.intendedOutcome,
            session.resultSummary ?? "",
            session.tangibleResult ?? "",
        ]
        return haystack.contains { field in
            field.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: - Grouping

    /// Groups by calendar day, newest day first, newest session first inside each day.
    nonisolated static func group(_ sessions: [FocusSession], in calendar: Calendar, now: Date) -> [Day] {
        var order: [Date] = []
        var buckets: [Date: [FocusSession]] = [:]

        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            let start = calendar.startOfDay(for: session.startedAt)
            if buckets[start] == nil { order.append(start) }
            buckets[start, default: []].append(session)
        }

        return order.map { start in
            Day(
                start: start,
                heading: dayHeading(for: start, now: now, in: calendar),
                sessions: buckets[start] ?? []
            )
        }
    }

    /// "Today" · "Yesterday" · "Tuesday 22 July" — § 10.10's three forms, in that order.
    ///
    /// The absolute form carries no year, because a window is never wider than one and the header
    /// above it already says which. It gains one when the day is in a different year to the present,
    /// so a January window read in February of the next year is not ambiguous.
    nonisolated static func dayHeading(for start: Date, now: Date, in calendar: Calendar) -> String {
        // Compared against the injected `now`, never against `Calendar.isDateInToday`: that reads the
        // system clock, which would make the relative headings untestable and — worse — leave a window
        // that is open across midnight printing "Today" over yesterday's rows until it reloaded.
        if calendar.isDate(start, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(start, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        let base = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
        let sameYear =
            calendar.component(.year, from: start) == calendar.component(.year, from: now)
        let style = sameYear
            ? base.weekday(.wide).day().month(.wide)
            : base.weekday(.wide).day().month(.wide).year()
        return start.formatted(style)
    }
}
