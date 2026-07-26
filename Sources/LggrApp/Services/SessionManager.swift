import Foundation
import LggrKit

/// The single owner of session state, and the only object in the app that talks to `LggrStore`.
///
/// Every view reads from here and calls back into here; no view ever touches the store, builds a
/// `DateInterval`, or does pause arithmetic of its own. That arithmetic lives in `LggrKit`'s
/// `SessionClock` and is unit-tested there — this type calls `pause(at:)`, `resume(at:)`,
/// `finish(at:)` and `togglePause(at:)` and never reimplements them.
///
/// Three rules shape the code below:
///
/// 1. **The interface updates first, the disk updates second.** A local JSON write takes
///    milliseconds, but "milliseconds" is not "never", and a button that waits on a file is a button
///    that feels slow. State is mutated, then persisted.
/// 2. **Nothing here crashes and nothing here swallows.** Every store call is wrapped; a failure
///    sets `lastError` to one plain sentence and the app keeps running with the work still on
///    screen. Losing the ability to record work is worse than any error.
/// 3. **Time is read, never counted.** `now` exists so that observing views redraw; the numbers
///    themselves always come from the session's stored dates.
@MainActor
@Observable
public final class SessionManager {

    // MARK: - Published state

    /// The session in flight, running or paused. `nil` when nothing is being tracked.
    public private(set) var activeSession: FocusSession?

    /// A finished session whose "What happened?" has not been answered.
    ///
    /// A finished session is never lost because a sheet was dismissed: `discardReview()` clears this
    /// without clearing the session, and the session stays `.awaitingReview` until it is reviewed.
    public private(set) var pendingReview: FocusSession?

    /// Every project, in the order the store keeps them, so a rename never reshuffles a list the
    /// user is looking at.
    public private(set) var projects: [Project] = []

    /// Today's finished sessions, newest first.
    public private(set) var todaySessions: [FocusSession] = []

    /// Today's accomplishments, newest first.
    public private(set) var todayAccomplishments: [Accomplishment] = []

    /// The last store failure, as one sentence, surfaced as a dismissible banner.
    public private(set) var lastError: String?

    /// The instant the interface should render against. Assigned once a second while a session is
    /// running, and once more on wake, on pause and on resume. Nothing else writes it, and it is
    /// deliberately *not* the source of any duration.
    public var now: Date

    /// User preferences, kept in `UserDefaults` rather than in the store.
    ///
    /// Read-only to callers; the start panel reads `lastProjectID`, `recentOutcomes` and
    /// `defaultSessionDuration` from here so it can open pre-filled without waiting on any I/O.
    public private(set) var preferences: UserPreferences

    // MARK: - Collaborators

    @ObservationIgnored private let store: any LggrStore
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let windows = CalendarWindows()
    @ObservationIgnored private let tick = TickTimer()
    @ObservationIgnored private let sleepWake = SleepWakeObserver()

    /// How many times each session has been paused. `FocusSession` stores how *long* it was paused
    /// but not how often, and the generated summary wants the count.
    @ObservationIgnored private var pauseCounts: [UUID: Int] = [:]

    /// `defaults` is the gallery and test seam — pass a scratch suite and a preview cannot overwrite
    /// the real user's remembered project.
    public init(
        store: any LggrStore,
        clock: any DateProviding = SystemClock(),
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.clock = clock
        self.defaults = defaults
        self.now = clock.now
        self.preferences = PreferencesDefaults.load(from: defaults)
    }

    // MARK: - Bootstrap

    /// Loads everything the first frame needs and restores an interrupted session.
    ///
    /// Restoration is a requirement, not a nicety: quitting with a session running must not lose it,
    /// and a session that was left *paused* must come back paused with the pause still open, so that
    /// `elapsed(at:)` keeps excluding the time the app was not there for.
    public func bootstrap() async {
        sleepWake.start(
            onSleep: { [weak self] in self?.handleSleep() },
            onWake: { [weak self] in self?.handleWake() }
        )

        await reloadProjects()
        await restoreActiveSession()
        await reloadToday()
    }

    private func restoreActiveSession() async {
        do {
            guard let restored = try await store.loadActiveSession() else {
                await adoptUnreviewedSessionIfNeeded()
                return
            }
            activeSession = restored
            now = clock.now
            // A restored pause keeps its open `pauseStartedAt`, so no heartbeat is needed until the
            // user resumes: the number on screen is frozen and correct.
            syncTick()
        } catch {
            report("Couldn't restore the session that was running.")
        }
    }

    /// After a relaunch, a session that finished but was never reviewed goes back into
    /// `pendingReview` so the menu bar shows `questionmark.circle` and the popover offers
    /// "Review last session" (`04-screens.md` § 1.3). Presenting the sheet is the app's decision,
    /// not this method's.
    private func adoptUnreviewedSessionIfNeeded() async {
        guard pendingReview == nil else { return }
        do {
            // Deliberately not scoped to today: a session finished at 11pm and left unanswered
            // until the next morning is the ordinary case, and scanning only today's sessions would
            // strand it with no result forever.
            pendingReview = try await store.loadUnreviewedSession()
        } catch {
            // Today's list will report its own failure a moment from now; one banner is enough.
        }
    }

    // MARK: - Starting

    /// Starts a session and begins ticking.
    ///
    /// If something is already running it is finished first rather than discarded — the five-second
    /// path must never be the thing that loses an hour of work.
    public func startSession(
        projectID: UUID?,
        intendedOutcome: String,
        workType: WorkType,
        plannedDuration: TimeInterval?
    ) async {
        if activeSession != nil {
            await finishSession()
        }

        let startedAt = clock.now
        let session = FocusSession(
            projectID: projectID,
            intendedOutcome: intendedOutcome.trimmingCharacters(in: .whitespacesAndNewlines),
            workType: workType,
            plannedDuration: plannedDuration,
            startedAt: startedAt
        )

        activeSession = session
        now = startedAt
        syncTick()

        rememberStart(projectID: projectID, intendedOutcome: session.intendedOutcome)
        await persist(session, failureMessage: "Couldn't save this session.")
    }

    // MARK: - Pause and resume

    /// Pauses a running session or resumes a paused one.
    ///
    /// The transition itself belongs to `FocusSession.togglePause(at:)`; all this method does is
    /// hand it the current instant, decide whether the heartbeat is still needed, and write the
    /// result back.
    public func togglePause() {
        guard var session = activeSession else { return }
        let wasRunning = session.isRunning

        session.togglePause(at: clock.now)
        if wasRunning, session.isPaused {
            pauseCounts[session.id, default: 0] += 1
        }

        activeSession = session
        now = clock.now
        syncTick()

        let snapshot = session
        Task { [weak self] in
            await self?.persist(snapshot, failureMessage: "Couldn't save this session.")
        }
    }

    // MARK: - Finishing

    /// Ends the session and hands it to the review flow. The heartbeat stops here.
    public func finishSession() async {
        guard var session = activeSession else { return }

        session.finish(at: clock.now)
        activeSession = nil
        pendingReview = session
        now = clock.now
        syncTick()

        await persist(session, failureMessage: "Couldn't save this session.")
        await reloadTodaySessions()
    }

    // MARK: - Discarding and deleting

    /// Ends the active session and removes it, leaving no record of it anywhere.
    ///
    /// The exit for a session started by mistake. Until this existed the only way out of a session
    /// was `Finish`, and with no delete either, a session begun by pressing the wrong thing stayed in
    /// the log for good — which is how a trustworthy record of a day acquires entries that never
    /// happened.
    ///
    /// It is deliberately *not* `finish` followed by `delete`: finishing hands the session to the
    /// review flow, and a "What happened?" sheet for work the user has just said did not happen is
    /// the one thing this must not do. So the heartbeat stops, `activeSession` clears, nothing is left
    /// in `pendingReview`, and the record is removed.
    ///
    /// - Returns: `false` when nothing was running, so a caller cannot mistake a no-op for a discard.
    @discardableResult
    public func discardActiveSession() async -> Bool {
        guard let session = activeSession else { return false }

        activeSession = nil
        // A session cannot be active and awaiting review at the same time, so this can only match a
        // value left behind by a restore. Clearing it *by id* is what makes the promise above true
        // without throwing away somebody else's unanswered review.
        if pendingReview?.id == session.id { pendingReview = nil }
        todaySessions.removeAll { $0.id == session.id }
        pauseCounts[session.id] = nil
        now = clock.now
        // `activeSession` is already `nil`, so this is the call that stands the heartbeat down.
        syncTick()

        await remove(sessionID: session.id, failureMessage: "Couldn't discard that session.")
        return true
    }

    /// Removes a session from the log.
    ///
    /// Interface first, disk second, like every other mutation here: the row leaves the screen at
    /// once. A failed delete re-reads today rather than leaving a list that claims a session is gone
    /// while it is still on disk — the banner says what happened and the row comes back.
    ///
    /// Deleting the session that is currently running is allowed and stops the clock. It is reached
    /// only from a list of *finished* sessions today, but the store keys on an id and so does this.
    public func deleteSession(id: UUID) async {
        if activeSession?.id == id {
            activeSession = nil
            now = clock.now
            syncTick()
        }
        if pendingReview?.id == id { pendingReview = nil }
        todaySessions.removeAll { $0.id == id }
        pauseCounts[id] = nil

        await remove(sessionID: id, failureMessage: "Couldn't delete that session.")
    }

    private func remove(sessionID: UUID, failureMessage: String) async {
        do {
            try await store.deleteSession(id: sessionID)
        } catch {
            report(failureMessage)
            await reloadTodaySessions()
        }
    }

    // MARK: - Correcting the times

    /// Corrects a finished session's start and end, and reports what the correction cost.
    ///
    /// The everyday case is "I forgot to press stop and it recorded four hours". All of the
    /// arithmetic — clamping an inverted range, closing a pause left open, fitting the recorded pauses
    /// inside a shortened span — belongs to `FocusSession.reschedule(start:end:at:)`; this method
    /// hands it the instant, writes the result, and passes the report back up so the caller can say
    /// what changed.
    ///
    /// - Returns: the corrected record and what the domain reported, or `nil` when the session has not
    ///   finished and nothing was touched. A running session's end is not a stored value yet, so
    ///   there is nothing to correct; `adjustPlannedDuration(to:)` is what changes a live session.
    @discardableResult
    public func reschedule(
        session: FocusSession,
        start: Date,
        end: Date
    ) async -> (corrected: FocusSession, report: SessionRescheduleResult)? {
        var corrected = session
        // Not named `report`: that is the name of this type's error-reporting method, and shadowing it
        // inside the one function that also has to call it is a trap for the next reader.
        guard let outcome = corrected.reschedule(start: start, end: end, at: clock.now) else {
            report("Only a session that has finished can have its times corrected.")
            return nil
        }

        if let index = todaySessions.firstIndex(where: { $0.id == corrected.id }) {
            todaySessions[index] = corrected
        }
        if pendingReview?.id == corrected.id { pendingReview = corrected }

        await persist(corrected, failureMessage: "Couldn't save the corrected times.")
        // Correcting a forgotten stop time can move a session into or out of today, so today is
        // re-read rather than patched: that is the whole point of the edit.
        await reloadTodaySessions()

        return (corrected, outcome)
    }

    // MARK: - Adjusting the target

    /// Changes the running session's target duration. `nil` makes it open-ended.
    ///
    /// Deliberately does not stamp `editedAt`: a target is a statement of intent, not evidence, and
    /// revising it leaves every recorded time exactly as it was observed. `FocusSession`'s own
    /// documentation for `adjustPlannedDuration(to:)` carries the reasoning.
    ///
    /// Synchronous, and persisted in the background, exactly as `togglePause()` is: this is a button
    /// under a live timer, and a button that waits on a file is a button that feels slow.
    public func adjustPlannedDuration(to target: TimeInterval?) {
        guard var session = activeSession else { return }
        let previous = session.plannedDuration
        session.adjustPlannedDuration(to: target)
        guard session.plannedDuration != previous else { return }

        activeSession = session
        now = clock.now

        let snapshot = session
        Task { [weak self] in
            await self?.persist(snapshot, failureMessage: "Couldn't save the new target.")
        }
    }

    /// Moves the running session's target by `delta` seconds — the `+10` / `−10` controls.
    ///
    /// An open-ended session has no target to move, so the time already spent is the base: `+10` then
    /// means "ten minutes more from where I am", which is the only reading that does not invent a
    /// number. The domain clamps at zero, so `−10` can shorten a target to nothing but never past it.
    public func adjustPlannedDuration(by delta: TimeInterval) {
        guard let session = activeSession else { return }
        let base = session.plannedDuration ?? session.elapsed(at: clock.now)
        adjustPlannedDuration(to: max(0, base + delta))
    }

    // MARK: - Review

    /// Answers "What happened?" and files the session.
    public func submitReview(
        status: SessionResultStatus,
        summary: String,
        blocker: String?,
        nextStep: String?
    ) async {
        guard var session = pendingReview else { return }

        session.resultStatus = status
        session.resultSummary = Self.trimmedOrNil(summary)
        session.blocker = Self.trimmedOrNil(blocker)
        session.nextStep = Self.trimmedOrNil(nextStep)

        pendingReview = nil
        pauseCounts[session.id] = nil

        await persist(session, failureMessage: "Couldn't save this session.")
        await reloadTodaySessions()
    }

    /// Steps away from the review without touching the session.
    ///
    /// The session keeps its `endedAt` and keeps `resultStatus == nil`, which is what makes it show
    /// a `Review` button in Today and in Focus Sessions instead of quietly disappearing.
    public func discardReview() async {
        guard pendingReview != nil else { return }
        pendingReview = nil
        await reloadTodaySessions()
    }

    /// Re-offers a finished session that was never answered for.
    ///
    /// This is what makes the `Review` button in the Focus Sessions history a real control rather than
    /// a label. Without it, only the session that happened to be pending when the app launched could
    /// ever be reviewed again, and every earlier one would be stranded: it has an `endedAt`, so
    /// `loadActiveSession()` will not return it, and `loadUnreviewedSession()` runs once at bootstrap.
    ///
    /// A session that already has a result is refused. Re-answering "What happened?" would discard the
    /// summary the user wrote, because the sheet collects a whole answer rather than a patch; editing a
    /// filed session is `update(_:)`'s job and happens in the detail view, in place.
    ///
    /// Replacing an already-pending review is safe and deliberate: the displaced session keeps its
    /// `endedAt` and its empty `resultStatus`, so it is still unreviewed on disk and still carries its
    /// own `Review` button in the very list this was called from.
    @discardableResult
    public func offerReview(for session: FocusSession) -> Bool {
        guard session.isFinished, session.resultStatus == nil else { return false }
        pendingReview = session
        return true
    }

    /// Saves an edited session.
    ///
    /// The four fields the detail view edits in place — summary, tangible result, blocker, next step —
    /// are the user's own words about work already done, so this deliberately does not touch dates,
    /// status or counts: whatever the caller hands over is written whole, and nothing here rewrites it.
    ///
    /// Interface first, disk second, like every other mutation here: the local copies are updated
    /// before the write so a list the user is looking at does not wait on a file.
    public func update(_ session: FocusSession) async {
        if let index = todaySessions.firstIndex(where: { $0.id == session.id }) {
            todaySessions[index] = session
        }
        if activeSession?.id == session.id { activeSession = session }
        if pendingReview?.id == session.id { pendingReview = session }

        await persist(session, failureMessage: "Couldn't save this session.")
    }

    // MARK: - Accomplishments

    public func addAccomplishment(_ accomplishment: Accomplishment) async {
        if todayInterval().contains(accomplishment.timestamp) {
            todayAccomplishments.removeAll { $0.id == accomplishment.id }
            todayAccomplishments.append(accomplishment)
            todayAccomplishments.sort { $0.timestamp > $1.timestamp }
        }

        do {
            try await store.saveAccomplishment(accomplishment)
        } catch {
            report("Couldn't save that accomplishment.")
            return
        }
        await reloadTodayAccomplishments()
    }

    // MARK: - Interruptions

    /// Records that something arrived while this session was running.
    ///
    /// The session is otherwise untouched: it is not paused, not finished, and its dates do not move.
    /// That is the whole promise of interruption capture — the note is written down and the work
    /// carries on (`04-screens.md` § 5.4).
    ///
    /// `InboxModel` owns the `Interruption` record; this owns the count on the session, because this
    /// object holds the live copy and rewrites the whole value on every pause and finish. An
    /// increment written anywhere else would be overwritten by the next tick of ordinary session
    /// state.
    public func noteInterruption() {
        guard var session = activeSession else { return }
        session.interruptionCount += 1
        activeSession = session

        let snapshot = session
        Task { [weak self] in
            // Not surfaced on failure. The interruption itself is already saved, and a banner about
            // a count would be a second error message for a note that landed.
            try? await self?.store.saveSession(snapshot)
        }
    }

    // MARK: - Projects

    public func saveProject(_ project: Project) async {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }

        do {
            try await store.saveProject(project)
        } catch {
            report("Couldn't save that project.")
            return
        }
        await reloadProjects()
    }

    /// Deletes a project without cascading. Sessions and accomplishments keep their history and lose
    /// the label, which is exactly what the delete confirmation promises the user.
    public func deleteProject(id: UUID) async {
        projects.removeAll { $0.id == id }
        if activeSession?.projectID == id { activeSession?.projectID = nil }
        if pendingReview?.projectID == id { pendingReview?.projectID = nil }
        if preferences.lastProjectID == id { updatePreferences { $0.lastProjectID = nil } }

        do {
            try await store.deleteProject(id: id)
        } catch {
            report("Couldn't delete that project.")
            return
        }
        await reloadProjects()
        await reloadToday()
    }

    // MARK: - Derived text

    /// The pre-filled text of the review sheet's summary field.
    ///
    /// Deterministic string assembly in `LggrKit`, not a judgement: it states what was worked on and
    /// for how long, and a blocked session reads exactly as calmly as a completed one.
    public func suggestedSummary(for session: FocusSession) -> String {
        SessionSummaryBuilder.summary(
            for: session,
            projectName: projectName(for: session.projectID),
            pauseCount: pauseCounts[session.id] ?? 0,
            at: clock.now
        )
    }

    public func projectName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return projects.first { $0.id == id }?.name
    }

    // MARK: - Errors

    /// Dismisses the error banner. It comes back on the next failure.
    public func dismissError() {
        lastError = nil
    }

    /// Spelling of `dismissError()` for call sites that read better this way.
    public func clearError() {
        lastError = nil
    }

    // MARK: - Sleep and wake

    private func handleSleep() {
        // Nothing to record: the session's dates already describe what happened. Standing the
        // heartbeat down just stops us waking a sleeping machine once a second.
        tick.stop()
    }

    private func handleWake() {
        // One read of the clock repaints every derived duration correctly, however long the machine
        // was away. No stored value is touched.
        now = clock.now
        syncTick()
    }

    // MARK: - Ticking

    /// The heartbeat runs while, and only while, a session is actually advancing. A paused session's
    /// numbers are frozen, so ticking for it would be a wake-up that changes nothing.
    private func syncTick() {
        guard activeSession?.isRunning == true else {
            tick.stop()
            return
        }
        guard !tick.isRunning else { return }
        tick.start { [weak self] in
            guard let self else { return }
            self.now = self.clock.now
        }
    }

    // MARK: - Loading

    private func reloadProjects() async {
        do {
            projects = try await store.loadProjects()
        } catch {
            report("Couldn't load your projects.")
        }
    }

    private func reloadToday() async {
        await reloadTodaySessions()
        await reloadTodayAccomplishments()
    }

    private func reloadTodaySessions() async {
        do {
            todaySessions = try await store.loadSessions(in: todayInterval())
                .filter(\.isFinished)
        } catch {
            report("Couldn't load today. Your work is still on disk.")
        }
    }

    private func reloadTodayAccomplishments() async {
        do {
            todayAccomplishments = try await store.loadAccomplishments(in: todayInterval())
        } catch {
            report("Couldn't load today. Your work is still on disk.")
        }
    }

    /// Midnight to midnight around now, through `Calendar` — never by adding 86,400 seconds, because
    /// a day is 23 hours twice a year.
    private func todayInterval() -> DateInterval {
        let reference = clock.now
        if let day = windows.day(containing: reference) { return day }
        return DateInterval(start: windows.startOfDay(for: reference), duration: 24 * 60 * 60)
    }

    // MARK: - Persistence helpers

    private func persist(_ session: FocusSession, failureMessage: String) async {
        do {
            try await store.saveSession(session)
        } catch {
            report(failureMessage)
        }
    }

    private func report(_ message: String) {
        lastError = message
    }

    // MARK: - Preferences

    /// Records what the start panel should offer next time: the project just used, and the outcome
    /// as a suggestion. Both are conveniences, so neither is allowed to fail loudly.
    private func rememberStart(projectID: UUID?, intendedOutcome: String) {
        updatePreferences { preferences in
            preferences.lastProjectID = projectID
            preferences.recordOutcome(intendedOutcome)
        }
    }

    private func updatePreferences(_ mutate: (inout UserPreferences) -> Void) {
        var updated = preferences
        mutate(&updated)
        guard updated != preferences else { return }
        preferences = updated
        PreferencesDefaults.save(updated, to: defaults)
    }

    // MARK: - Text helpers

    private static func trimmedOrNil(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }
}

/// `UserPreferences` lives in `UserDefaults`, not in `LggrStore`.
///
/// It is a handful of small values the start panel reads on the first frame; routing them through an
/// `async` store would mean the panel either waits or opens with the wrong defaults, and both are
/// worse than a synchronous read of a property list. A failure to encode or decode falls back to the
/// documented defaults rather than throwing: a corrupt preference must never stop the app from
/// starting a session.
private enum PreferencesDefaults {

    static let key = "com.lggr.preferences"

    static func load(from defaults: UserDefaults) -> UserPreferences {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ preferences: UserPreferences, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
