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

    /// The session Lggr closed on the user's behalf, and why — set the moment it happens, and
    /// cleared when the user acknowledges it.
    ///
    /// Published rather than applied silently. A time the app chose must be visible as one, or the
    /// correction is indistinguishable from the defect it fixes: both change a number the user was
    /// not watching.
    public private(set) var autoCloseNotice: AutoCloseNotice?

    /// A session whose end Lggr decided, with the sentence that explains it.
    public struct AutoCloseNotice: Equatable, Sendable {
        public let session: FocusSession
        public let decision: SessionAutoClose.Decision
        /// "Ended at 12:04, the last input Lggr recorded."
        public let sentence: String
    }

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

    // MARK: - Closing a session the user forgot about

    /// Where notifications go. `nil` in the gallery, the snapshot renderer and any test that does not
    /// care — and every scheduling call below tolerates that, because a notification is never the
    /// mechanism by which anything happens.
    @ObservationIgnored private let notifications: NotificationGate?

    /// How long since human input reached this machine.
    ///
    /// The same reading `IdleMonitor` takes, taken directly rather than through it: this object needs
    /// the number at the moment it evaluates a decision, and routing it through a second timer would
    /// be a third timer in a subsystem that is allowed two (`IdleMonitor`'s documentation, criterion
    /// 8). Injectable because it is ground truth about the real machine — a test that expects a
    /// forgotten session to close cannot depend on the developer's own idle timer.
    @ObservationIgnored private let idleSeconds: @Sendable () -> TimeInterval

    /// The last instant the *previous* run of Lggr is known to have been alive, or `nil` when nothing
    /// is known.
    ///
    /// Read once, at bootstrap, and expected to be `ActivityHeartbeat.readLastBeatFromDisk()` — the
    /// same forty bytes `ActivityLaunchRecovery` computes the timeline's `.appNotRunning` gap from. It
    /// is deliberately the same source rather than a second one: a session's end and the gap beside
    /// it disagreeing by a minute would make the record contradict itself, which is worse than either
    /// number being slightly conservative.
    @ObservationIgnored private let lastHeartbeat: @MainActor () -> Date?

    /// When the machine went to sleep, if it is asleep or has just woken.
    ///
    /// `SleepWakeObserver` already tells this object about sleep; recording the instant is what turns
    /// that into a witness. A session running when the lid closes is closed here rather than credited
    /// with the night.
    @ObservationIgnored private var sleepStartedAt: Date?

    /// Whether the long-idle offer has already been made for the idle stretch in progress.
    ///
    /// One notification per stretch. Without this the offer would repeat on every tick, which is the
    /// single fastest way to lose the notification authorisation for good.
    @ObservationIgnored private var hasOfferedIdleTrim = false

    /// The policy constants. One value, not exposed in the UI, for the reason
    /// `SessionAutoClose.Policy` gives.
    @ObservationIgnored private let autoClosePolicy: SessionAutoClose.Policy

    /// How often the tick is allowed to evaluate. Matches `IdleMonitor.activeInterval`, because it
    /// reads the same signal and is subject to the same energy gate.
    private static let autoCloseCheckInterval: TimeInterval = IdleMonitor.activeInterval

    /// When the tick last evaluated. A backwards clock resets it rather than locking the check out.
    @ObservationIgnored private var lastAutoCloseCheck: Date?

    /// `defaults` is the gallery and test seam — pass a scratch suite and a preview cannot overwrite
    /// the real user's remembered project.
    public init(
        store: any LggrStore,
        clock: any DateProviding = SystemClock(),
        defaults: UserDefaults = .standard,
        notifications: NotificationGate? = nil,
        idleSeconds: @escaping @Sendable () -> TimeInterval = IdleMonitor.systemIdleSeconds,
        lastHeartbeat: @escaping @MainActor () -> Date? = { nil },
        autoClosePolicy: SessionAutoClose.Policy = .default
    ) {
        self.store = store
        self.clock = clock
        self.defaults = defaults
        self.now = clock.now
        self.preferences = PreferencesDefaults.load(from: defaults)
        self.notifications = notifications
        self.idleSeconds = idleSeconds
        self.lastHeartbeat = lastHeartbeat
        self.autoClosePolicy = autoClosePolicy
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
        // Before today is read, so a session the previous run left open is already closed — and
        // therefore already in today's list — rather than appearing there a moment later.
        //
        // This is the case that writes wrong data today: quit or crash with a session running and the
        // record claims every hour between then and the next launch. The absence is dated from the
        // last heartbeat, which is the instant the timeline is using for the same gap.
        await evaluateAutoClose(absence: launchAbsence())
        await reloadToday()
    }

    /// What the previous run left behind, as a witness `SessionAutoClose` can close a session at.
    ///
    /// `nil` on a first launch, on a clean quit that beat afterwards, and whenever the beat is not
    /// behind the clock — in which case there is no absence to account for and nothing is adjusted.
    private func launchAbsence() -> SessionAutoClose.Absence? {
        guard let beat = lastHeartbeat(), beat < clock.now else { return nil }
        return SessionAutoClose.Absence(lastWitnessedAt: beat, kind: .appNotRunning)
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
        // A new session is a new idle stretch as far as the offer is concerned, and a new
        // completion to schedule.
        hasOfferedIdleTrim = false
        autoCloseNotice = nil
        syncTick()

        rememberStart(projectID: projectID, intendedOutcome: session.intendedOutcome)
        await persist(session, failureMessage: "Couldn't save this session.")
        await scheduleSessionNotifications(for: session)
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
            // A pause moves the finish line, so the pending completion is wrong the instant it is
            // pressed. Rescheduling on resume rather than leaving the old one armed is the difference
            // between a notification that is useful and one the user learns to ignore.
            await self?.scheduleSessionNotifications(for: snapshot)
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
        hasOfferedIdleTrim = false
        syncTick()

        await persist(session, failureMessage: "Couldn't save this session.")
        await reloadTodaySessions()

        // Everything armed for this session is now a banner about the past.
        //
        // And **nothing is posted in its place.** A user who presses Finish is looking at the app;
        // telling them what they have just done is the kind of notification that costs the
        // authorisation the useful ones depend on. The `sessionCompleted` banner is the one that
        // arrives when the *planned duration* runs out with nobody watching — scheduled by
        // `scheduleSessionNotifications`, and withdrawn right here when the user gets there first.
        cancelSessionNotifications()
    }

    /// Withdraws every notification that belongs to a session in flight.
    private func cancelSessionNotifications() {
        notifications?.cancel(.sessionCompleted)
        notifications?.cancel(.halfway)
        notifications?.cancel(.longIdle)
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
        hasOfferedIdleTrim = false
        if autoCloseNotice?.session.id == session.id { autoCloseNotice = nil }
        // `activeSession` is already `nil`, so this is the call that stands the heartbeat down.
        syncTick()
        // A session the user has just said did not happen must not produce a banner about it a
        // quarter of an hour later.
        cancelSessionNotifications()

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
            cancelSessionNotifications()
        }
        if pendingReview?.id == id { pendingReview = nil }
        if autoCloseNotice?.session.id == id { autoCloseNotice = nil }
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
            // Moving the target moves the finish line, so the two notifications that were armed
            // against the old one are re-armed against the new. `+10` with a stale banner still
            // pending would announce a completion ten minutes before the session reaches it.
            await self?.scheduleSessionNotifications(for: snapshot)
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

    // MARK: - Filing a block the user labelled afterwards

    /// Saves a session built from a reconstructed block.
    ///
    /// The record arrives already complete: `SessionFromEpisode` decided its bounds, its paused time,
    /// its status and its provenance, and `TimelineModel` supplied the declared sessions the overlap
    /// was computed against. Nothing about it is decided here — this method's whole job is that the
    /// store is written by the one object allowed to write it.
    ///
    /// Three things it deliberately does **not** do:
    ///
    ///   * **It arms no notification and cancels none.** The session is already over. A banner
    ///     announcing work the user has just described would be the kind of notification that costs
    ///     the authorisation the useful ones depend on.
    ///   * **It does not touch `activeSession`.** Labelling a block is not starting one, and a
    ///     gesture on the timeline must never stop the timer somebody has running.
    ///   * **It does not put the session into `pendingReview`.** It lands answered — see decision 2 in
    ///     `SessionFromEpisode` — because three labelled blocks leaving three unanswered questions
    ///     behind them is a decision queue, which is the failure this whole phase is measured against.
    ///
    /// - Returns: `false` when the session had not finished and nothing was written, so a caller
    ///   cannot mistake a refusal for a save. A reconstruction always has an end; this guard is what
    ///   stops a future caller from filing something else through here.
    @discardableResult
    public func fileReconstructed(_ session: FocusSession) async -> Bool {
        guard session.isFinished, session.wasReconstructed else { return false }

        // Interface first, disk second, like every other mutation here. Inserted rather than
        // appended-and-forgotten so the row appears in Today at once, in the order the list keeps.
        if todayInterval().contains(session.startedAt) {
            todaySessions.removeAll { $0.id == session.id }
            todaySessions.append(session)
            todaySessions.sort { $0.startedAt > $1.startedAt }
        }
        now = clock.now

        await persist(session, failureMessage: "Couldn't save this block as a session.")
        // Re-read rather than trust the insert: a block labelled just after midnight belongs to
        // yesterday, and the list on screen is today's.
        await reloadTodaySessions()
        return true
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

    // MARK: - Closing a session the user forgot about

    // The decision is `SessionAutoClose`'s, in `LggrKit`, and every case of it is proved there
    // against fixtures. Everything below is the plumbing: gather the three witnesses, hand them over,
    // and persist whatever comes back. No rule about *when* a session should close lives in this
    // file — if one ever appears here, it is in the wrong place and untested.

    /// Runs the decision once, and applies it if there is one.
    ///
    /// - Parameter absence: a stretch nobody witnessed, when the caller observed one — a launch after
    ///   a quit, a wake after a sleep. `nil` on an ordinary evaluation.
    public func evaluateAutoClose(absence: SessionAutoClose.Absence? = nil) async {
        guard let session = activeSession else { return }
        let instant = clock.now

        let input = SessionAutoClose.Input(
            session: session,
            lastInputAt: lastInputInstant(at: instant),
            absence: absence,
            endOfDay: windows.day(containing: session.startedAt)?.end,
            idleThreshold: preferences.idleThreshold,
            now: instant,
            policy: autoClosePolicy
        )

        guard let decision = SessionAutoClose.decide(input) else {
            // Nothing to close. This is also the only branch on which the idle *offer* makes sense:
            // input has stopped, the session is still describing something, and the user may want to
            // end it early. Offering before the app would act is what keeps the action theirs.
            await offerIdleTrimIfNeeded(for: session, at: instant, input: input)
            return
        }

        await applyAutoClose(decision, to: session, at: instant)
    }

    /// The tick's evaluation, at most once every `autoCloseCheckInterval`.
    ///
    /// The throttle is not a micro-optimisation, it is acceptance criterion 8. The tick fires once a
    /// second so the timer on screen counts, but `idleSeconds()` is a synchronous call into the window
    /// server — and `IdleMonitor` polls the same value every *fifteen* seconds, with leeway, precisely
    /// so that Lggr does not appear in "Apps Using Significant Energy". Asking fifteen times as often
    /// for a decision whose shortest allowance is fifteen minutes would spend that budget for nothing.
    private func tickAutoClose() {
        let instant = clock.now
        if let last = lastAutoCloseCheck,
            instant.timeIntervalSince(last) < Self.autoCloseCheckInterval,
            instant >= last
        {
            return
        }
        lastAutoCloseCheck = instant
        Task { [weak self] in
            await self?.evaluateAutoClose()
        }
    }

    /// When input last reached the machine, derived from the idle timer.
    ///
    /// `nil` when the reading is not a number — a missing signal must never be the reason a session
    /// ends, so it produces no idle decision rather than an instant far in the past.
    private func lastInputInstant(at instant: Date) -> Date? {
        let seconds = idleSeconds()
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return instant.addingTimeInterval(-seconds)
    }

    /// Applies a decision: the session ends where the witness says, the record says who decided, and
    /// the user is told.
    private func applyAutoClose(
        _ decision: SessionAutoClose.Decision,
        to session: FocusSession,
        at instant: Date
    ) async {
        var closed = session
        guard closed.applyAutoClose(decision, at: instant) else { return }

        activeSession = nil
        // Straight into the review flow, exactly as `finishSession` does. The work happened; only
        // its end was decided by the app, and a session that skipped "What happened?" because
        // nobody pressed the button would be the same forgetting in a new place.
        pendingReview = closed
        now = instant
        hasOfferedIdleTrim = false
        syncTick()

        let closedAtText = decision.closeAt.formatted(date: .omitted, time: .shortened)
        autoCloseNotice = AutoCloseNotice(
            session: closed,
            decision: decision,
            sentence: decision.sentence(closedAtText: closedAtText)
        )

        await persist(closed, failureMessage: "Couldn't save this session.")
        await reloadTodaySessions()

        cancelSessionNotifications()
        // The one completion notification that is worth sending: the user was not there, so this is
        // the only way they learn that a number changed. It states the adjusted end and the witness
        // it came from rather than presenting it as an observed one.
        await notifications?.post(
            NotificationCopy.sessionAutoClosed(
                outcome: closed.intendedOutcome,
                decision: decision,
                closedAtText: closedAtText
            )
        )
    }

    /// Clears the notice once the user has seen it. The session keeps its provenance forever; only
    /// the announcement goes away.
    public func acknowledgeAutoClose() {
        autoCloseNotice = nil
    }

    /// Ends the running session at the last input Lggr recorded — the long-idle notification's
    /// action, and the same code path the automatic close uses.
    ///
    /// Deliberately the same path: the button the user presses and the decision the app makes must
    /// produce the same record, or the two disagree about what "the last input" means.
    @discardableResult
    public func endSessionAtLastInput() async -> Bool {
        guard let session = activeSession else { return false }
        let instant = clock.now
        guard let lastInput = lastInputInstant(at: instant), lastInput > session.startedAt else {
            // No usable reading, so there is nothing honest to close it at. Finishing now is the
            // conservative answer and it is the user's own press, not an inference.
            await finishSession()
            return true
        }
        await applyAutoClose(
            SessionAutoClose.Decision(
                closeAt: lastInput,
                reason: .idle,
                uncountedDuration: instant.timeIntervalSince(lastInput)
            ),
            to: session,
            at: instant
        )
        return true
    }

    /// Offers to end the session early, once per idle stretch.
    ///
    /// The threshold is the user's own idle threshold, not the auto-close allowance: the offer comes
    /// first and the automatic close comes later, so the user gets the chance to decide before the
    /// app decides for them. `keepGoing` is a real answer — it clears nothing and changes nothing,
    /// and this kind does not ask again until input returns.
    private func offerIdleTrimIfNeeded(
        for session: FocusSession,
        at instant: Date,
        input: SessionAutoClose.Input
    ) async {
        guard session.isRunning else { return }
        guard let lastInput = input.lastInputAt else { return }
        let silence = instant.timeIntervalSince(lastInput)

        guard silence >= max(60, preferences.idleThreshold) else {
            // Input came back. The next stretch gets its own single offer.
            hasOfferedIdleTrim = false
            return
        }
        guard !hasOfferedIdleTrim else { return }
        hasOfferedIdleTrim = true

        await notifications?.post(
            NotificationCopy.longIdle(
                silence: silence,
                proposedEndText: lastInput.formatted(date: .omitted, time: .shortened)
            )
        )
    }

    // MARK: - Notifications

    /// Arms the two notifications a running session can produce, and withdraws them when it cannot.
    ///
    /// Both are scheduled as an offset from *now* against the session's own clock, so a session that
    /// was paused for twenty minutes announces its completion twenty minutes later — the finish line
    /// is the one `SessionClock` computes, never a wall-clock time recorded when the session started.
    ///
    /// An open-ended session arms nothing at all. There is no completion to announce, and a
    /// notification for a session with no target would have to be invented out of a duration the user
    /// never asked for.
    private func scheduleSessionNotifications(for session: FocusSession) async {
        guard let notifications else { return }
        guard session.isRunning, let planned = session.plannedDuration, planned > 0 else {
            notifications.cancel(.sessionCompleted)
            notifications.cancel(.halfway)
            return
        }

        let elapsed = session.elapsed(at: clock.now)
        let remaining = max(0, planned - elapsed)

        if remaining > 0 {
            await notifications.post(
                NotificationCopy.sessionCompleted(
                    outcome: session.intendedOutcome,
                    duration: planned,
                    delay: remaining
                )
            )
        } else {
            notifications.cancel(.sessionCompleted)
        }

        // Halfway is only meaningful while the session has not reached it. A session resumed past
        // its own midpoint arms nothing, rather than announcing a halfway point in the past.
        let halfway = planned / 2
        if halfway > elapsed {
            await notifications.post(
                NotificationCopy.halfway(
                    outcome: session.intendedOutcome,
                    remaining: planned - halfway,
                    delay: halfway - elapsed
                )
            )
        } else {
            notifications.cancel(.halfway)
        }
    }

    // MARK: - Errors

    /// Puts one sentence in front of the user through the app's single message surface.
    ///
    /// `04-screens.md` §3.3 gives the detail column exactly one of these, so a caller with something
    /// to say routes it here rather than inventing a second banner. What arrives this way is not
    /// always a failure — a block the record already accounts for is a fact, not a fault — and the
    /// surface is deliberately the same either way: it is inline, never modal, never red, and states
    /// what is true rather than what the user should have done.
    public func surface(_ message: String) {
        report(message)
    }

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
        // The instant is recorded, and that is the whole change: a session running when the lid
        // closes has a witness now, so waking up eleven hours later closes it at 18:00 instead of
        // crediting the night. Nothing is written here — `handleWake` decides, because sleep is the
        // one notification that may be the last thing this process is told before it is frozen.
        sleepStartedAt = clock.now
        // Nothing to record: the session's dates already describe what happened. Standing the
        // heartbeat down just stops us waking a sleeping machine once a second.
        tick.stop()
    }

    private func handleWake() {
        // One read of the clock repaints every derived duration correctly, however long the machine
        // was away. No stored value is touched.
        now = clock.now
        syncTick()

        let absence = sleepStartedAt.map {
            SessionAutoClose.Absence(lastWitnessedAt: $0, kind: .machineAsleep)
        }
        sleepStartedAt = nil
        Task { [weak self] in
            await self?.evaluateAutoClose(absence: absence)
        }
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
            // The tick is where the idle rule is noticed, and it costs one read of the idle timer
            // and a pure function. No new timer: `IdleMonitor` and the activity heartbeat are the
            // two the capture subsystem is allowed, and this one was already running for the label.
            self.tickAutoClose()
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
