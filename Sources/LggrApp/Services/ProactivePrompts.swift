import Foundation
import LggrKit

// The two prompts that catch a user who never opens the app.
// See docs/_design/INTELLIGENCE.md §1 and §4 Phase 2, and docs/_design/SPEC.md § Notifications.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THESE ARE THE HIGHEST-RISK NOTIFICATIONS IN THE PRODUCT
//
//  Everything else Lggr sends is about a session the user started. These two are about work they
//  did not announce, which means they arrive uninvited — and macOS grants **one** notification
//  authorisation for the whole application. Get the tone wrong once and the user switches Lggr off
//  in System Settings, where the app cannot ask again, and the useful notifications die with the
//  annoying one.
//
//  So this file's job is mostly to *not send things*. Every decision it makes is delegated to
//  `UnlabelledWork`, which is pure and has a named case for each of the ten reasons to stay quiet.
//  What lives here is the wiring the domain deliberately cannot own: a clock, a calendar, the app's
//  own state, and the small amount of memory that makes "once per block" survive a relaunch.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// ## The five rules, and where each one is enforced
//
// 1. **Once per block, and never twice for the same stretch of work.** A block is recorded as asked
//    **at the moment the notification is posted**, not when the user answers it — so a banner that
//    was ignored, swept away by Notification Centre, or delivered while the user was in another room
//    still counts as asked. `UnlabelledWork.BlockKey` names the stretch by its start and its dominant
//    application rather than by `Episode.id`, because the identifier of the newest block changes on
//    every flush of the sampler while the block grows. The set is persisted, so a relaunch in the
//    middle of a block does not produce a second offer.
//
// 2. **Silent while a session runs, while tracking is paused, while the screen is locked, and outside
//    the user's hours.** Four cases of `UnlabelledWork.Silence`, decided before the timeline is even
//    read.
//
// 3. **Dismissing is cheap and final, and switching it off is on the banner.** *Not this one* and
//    *Stop asking* both complete without activating Lggr (`NotificationActionKind.activatesApp`), and
//    *Stop asking* moves the same switch the Alerts pane moves. There is no third state and no
//    "remind me later".
//
// 4. **Nothing fires because time passed.** The live offer is caused by a stretch of work reaching a
//    length. The end-of-day review's chosen hour is permission to *look at the record*; the record is
//    what causes the notification, and a day with nothing unlabelled sends nothing at all — not a
//    summary, and not a congratulation, which is the same interruption wearing a compliment.
//
// 5. **It is an offer, never a demand.** No sound, no badge, no modal, nothing blocking. All three of
//    those are properties of `NotificationService`, which never sets a sound and never sets a badge.
//
// ## Why a timer at all, and why it is not a scheduler
//
// The evaluation has to happen repeatedly, because the thing being watched — a block getting longer —
// changes without any event the app can subscribe to. So there is a one-minute tick, and three
// properties keep it from becoming the scheduler this file is written to avoid:
//
//   * **It only runs when the user has switched one of the two kinds on.** Both off is both no tick
//     and no work, which is the default state of a fresh install.
//   * **It computes a decision, it does not post one.** Ninety-nine ticks out of a hundred return a
//     `.silent` case and do nothing at all.
//   * **It carries no state that accumulates.** Every tick re-derives from the timeline, so a missed
//     tick, a slept machine and a stepped clock are all invisible — the same discipline `TickTimer`
//     documents for the session timer.

/// The scheduler for the two prompts about undeclared work, and the only thing that posts them.
///
/// Constructed inert: nothing happens until `start()` is called, and `start()` installs a tick only
/// if the user has switched one of the two kinds on. Everything it reads is injected, so the whole
/// object runs in a test with no clock, no sampler and no notification centre.
@MainActor
@Observable
public final class ProactivePrompts {

    // MARK: - Settings

    /// When Lggr is allowed to say something. The user's, and stored under its own key.
    public struct Schedule: Codable, Equatable, Sendable {

        /// The window in which the live offer may appear.
        public var hours: PromptHours

        /// Local hour at which the end-of-day review may look at the day. 0–23.
        ///
        /// Not the hour it arrives: see `UnlabelledWork.reviewOffer(for:conditions:policy:)`.
        public var endOfDayHour: Int

        public init(hours: PromptHours = .default, endOfDayHour: Int = 18) {
            self.hours = hours
            self.endOfDayHour = min(23, max(0, endOfDayHour))
        }

        public static let `default` = Schedule()

        /// Hours the review's own time can sit inside, so the two settings cannot contradict each
        /// other on screen. Advisory only — nothing is silently corrected.
        public var reviewIsInsideHours: Bool {
            hours.isAllDay || (endOfDayHour >= hours.startHour && endOfDayHour <= hours.endHour)
        }
    }

    // MARK: - Observable state

    /// What the last evaluation decided about the live offer, and what the last one decided about the
    /// review.
    ///
    /// Diagnostics, for the Alerts pane and for a test. **Never rendered as a status the user has to
    /// act on:** the correct user-facing expression of every `.silent` case is nothing at all.
    public private(set) var lastLiveDecision: UnlabelledWork.PromptDecision?
    public private(set) var lastReviewDecision: UnlabelledWork.ReviewDecision?

    /// The stretch of work the outstanding live offer is about, if there is one.
    ///
    /// Cleared when the offer is answered or when the block stops being the newest unlabelled one.
    public private(set) var outstandingOffer: UnlabelledWork.BlockKey?

    /// True while the one-minute tick is installed.
    public var isRunning: Bool { tick != nil }

    // MARK: - Collaborators

    @ObservationIgnored private let gate: NotificationGate
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let policy: UnlabelledWork.Policy
    @ObservationIgnored private let defaults: UserDefaults

    /// The day as it currently stands. A closure rather than a reference to `TimelineModel`, because
    /// the timeline is rebuilt on every flush and this must always read the one that exists now.
    @ObservationIgnored private let timeline: @MainActor () -> DayTimeline
    @ObservationIgnored private let isSessionRunning: @MainActor () -> Bool
    @ObservationIgnored private let isTrackingPaused: @MainActor () -> Bool
    /// The window server's view of the login session. Injected for the reason `ActivitySampler`
    /// injects it: it is ground truth about the real machine, and a test running while the
    /// developer's screen happens to be locked would otherwise watch this correctly stay silent and
    /// call that a failure.
    @ObservationIgnored private let sessionState: @Sendable () -> SystemSessionState.Snapshot
    @ObservationIgnored private let schedule: @MainActor () -> Schedule

    /// Opens `LabelBlockSheet` for a block. Set by the composition root.
    ///
    /// Optional because a host may have no window to present into; when it is absent the notification
    /// still carries its buttons, and `labelOutstandingBlock()` reports that it could not act rather
    /// than pretending it did.
    @ObservationIgnored public var onLabelBlock: (@MainActor (UUID) -> Void)?

    /// Opens `EndOfDayReviewSheet`. Set by the composition root.
    @ObservationIgnored public var onOpenReview: (@MainActor () -> Void)?

    // MARK: - Memory

    /// Stretches of work already asked about today.
    @ObservationIgnored private var offeredBlocks: Set<UnlabelledWork.BlockKey> = []
    /// The day `offeredBlocks` belongs to, so the set empties itself at midnight instead of growing.
    @ObservationIgnored private var offeredDay: String?
    /// The day the end-of-day review has already been offered for, if any.
    @ObservationIgnored private var reviewedDay: String?

    @ObservationIgnored private var tick: Timer?

    /// How often the day is re-examined. A minute: the live threshold is fifteen, so a minute of
    /// lateness is invisible, and a wake-up a minute is what the heartbeat already costs.
    public static let evaluationInterval: TimeInterval = 60

    private static let offeredBlocksKey = "com.lggr.prompts.offeredBlocks"
    private static let offeredDayKey = "com.lggr.prompts.offeredDay"
    private static let reviewedDayKey = "com.lggr.prompts.reviewedDay"

    // MARK: - Init

    public init(
        gate: NotificationGate,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        policy: UnlabelledWork.Policy = .default,
        defaults: UserDefaults = .standard,
        schedule: @escaping @MainActor () -> Schedule = { .default },
        timeline: @escaping @MainActor () -> DayTimeline,
        isSessionRunning: @escaping @MainActor () -> Bool,
        isTrackingPaused: @escaping @MainActor () -> Bool = { false },
        sessionState: @escaping @Sendable () -> SystemSessionState.Snapshot = {
            SystemSessionState.snapshot
        }
    ) {
        self.gate = gate
        self.clock = clock
        self.calendar = calendar
        self.policy = policy
        self.defaults = defaults
        self.schedule = schedule
        self.timeline = timeline
        self.isSessionRunning = isSessionRunning
        self.isTrackingPaused = isTrackingPaused
        self.sessionState = sessionState

        self.offeredDay = defaults.string(forKey: Self.offeredDayKey)
        self.reviewedDay = defaults.string(forKey: Self.reviewedDayKey)
        self.offeredBlocks = Set(
            (defaults.stringArray(forKey: Self.offeredBlocksKey) ?? [])
                .compactMap(UnlabelledWork.BlockKey.init(storageKey:))
        )
    }

    // MARK: - Lifecycle

    /// Begins watching, if there is anything to watch for.
    ///
    /// Idempotent, and safe to call whenever a switch moves — which is exactly what
    /// `refreshForSwitchChange()` does. A user with both kinds off gets no timer at all.
    public func start() {
        stop()
        guard isAnyPromptEnabled else { return }

        // `RunLoop.main` in `.common` mode, for the reason `TickTimer` documents: in the default mode
        // a timer stops firing while a menu is being tracked, and the menu bar popover being open is
        // not a reason to stop watching the day. Generous tolerance — nothing here is time-critical
        // to the second, and letting the system coalesce the wake-up is most of the battery story.
        let timer = Timer(timeInterval: Self.evaluationInterval, repeats: true) { [weak self] _ in
            // A timer scheduled on `RunLoop.main` fires on the main thread by definition, so this is a
            // documented invariant rather than an assumption about ordering — the same reasoning
            // `TickTimer` writes down.
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in await self.evaluate() }
            }
        }
        timer.tolerance = Self.evaluationInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        tick = timer

        Task { await evaluate() }
    }

    public func stop() {
        tick?.invalidate()
        tick = nil
    }

    /// Re-reads the switches and starts or stops the tick accordingly.
    ///
    /// Called after anything moves a switch — the Alerts pane, or *Stop asking* on the banner. A kind
    /// switched off must stop costing the user work immediately, not at the next launch.
    public func refreshForSwitchChange() {
        if isAnyPromptEnabled {
            if !isRunning { start() }
        } else {
            stop()
            lastLiveDecision = nil
            lastReviewDecision = nil
            outstandingOffer = nil
        }
    }

    private var isAnyPromptEnabled: Bool {
        gate.switches.isEnabled(.unlabelledBlock) || gate.switches.isEnabled(.endOfDayReview)
    }

    // MARK: - The evaluation

    /// Decides whether either prompt has anything to say, and posts at most one of them.
    ///
    /// At most one, and the live offer wins: it is about work happening right now and expires with
    /// the stretch, while the review is about the whole day and loses nothing by waiting a minute.
    /// Two banners at once for two different flavours of the same fact is how one notification
    /// becomes two.
    public func evaluate() async {
        let now = clock.now
        rollOverIfNeeded(at: now)

        if await evaluateLiveOffer(at: now) { return }
        await evaluateReview(at: now)
    }

    /// - Returns: whether a notification was posted.
    @discardableResult
    private func evaluateLiveOffer(at now: Date) async -> Bool {
        let hours = schedule().hours
        let state = sessionState()

        let decision = UnlabelledWork.liveOffer(
            in: timeline(),
            now: now,
            conditions: UnlabelledWork.Conditions(
                isEnabled: gate.switches.isEnabled(.unlabelledBlock),
                isSessionRunning: isSessionRunning(),
                isTrackingPaused: isTrackingPaused(),
                // Locked, asleep, or another account on the console. All three mean nobody is here to
                // read a banner, and a banner nobody read arrives as a pile later.
                isScreenLocked: state.corroboratesAbsence || !state.isOnConsole,
                isWithinHours: hours.contains(now, calendar: calendar),
                offeredBlocks: offeredBlocks
            ),
            policy: policy
        )
        lastLiveDecision = decision

        guard let offer = decision.offer else {
            // A stretch that is no longer the newest unlabelled block has nothing outstanding about
            // it. Clearing this is what stops the notification's button from acting on yesterday.
            if decision.silence != .alreadyOffered { outstandingOffer = nil }
            return false
        }

        // Recorded **before** the post, and recorded whatever happens next. If the post fails, if the
        // banner is never seen, if the user ignores it — this block has been asked about and will not
        // be asked about again. Marking after a user answer would make an ignored banner repeat once a
        // minute, which is the one failure this feature cannot survive.
        remember(offer.key, at: now)
        outstandingOffer = offer.key

        await gate.post(
            NotificationCopy.unlabelledBlock(
                blockLabel: offer.episode.label,
                duration: offer.duration
            )
        )
        return true
    }

    @discardableResult
    private func evaluateReview(at now: Date) async -> Bool {
        let day = dayStamp(for: now)
        let hour = calendar.component(.hour, from: now)
        let state = sessionState()

        let decision = UnlabelledWork.reviewOffer(
            for: timeline(),
            conditions: UnlabelledWork.ReviewConditions(
                isEnabled: gate.switches.isEnabled(.endOfDayReview),
                isDue: hour >= schedule().endOfDayHour,
                isScreenLocked: state.corroboratesAbsence || !state.isOnConsole,
                isSessionRunning: isSessionRunning(),
                hasAlreadyOffered: reviewedDay == day
            ),
            policy: policy
        )
        lastReviewDecision = decision

        guard let report = decision.report else { return false }

        // One per day, recorded before the post for the same reason the live offer is.
        reviewedDay = day
        defaults.set(day, forKey: Self.reviewedDayKey)

        await gate.post(NotificationCopy.endOfDayReview(report))
        return true
    }

    // MARK: - What the buttons do

    /// *Label this* — resolves the outstanding offer to a block that is still on the timeline and
    /// hands it to the host.
    ///
    /// Resolved late, by `UnlabelledWork.BlockKey`, because the banner is pressed minutes after it was
    /// posted and the sampler has flushed since: the `Episode` that was offered no longer exists, and
    /// the same stretch of work is now longer. Backdating is free — `SessionFromEpisode` reads the
    /// block's own measured start, so the session begins where the work did.
    ///
    /// - Returns: `false` when the stretch is no longer on the timeline, so the caller can decline to
    ///   open a sheet about a block that is not there rather than opening an empty one.
    @discardableResult
    public func labelOutstandingBlock() -> Bool {
        guard let key = outstandingOffer, let onLabelBlock else { return false }
        guard let episode = timeline().episode(matching: key) else {
            outstandingOffer = nil
            return false
        }
        outstandingOffer = nil
        onLabelBlock(episode.id)
        return true
    }

    /// *Not this one* — the cheap, final answer.
    ///
    /// Nothing is written and nothing is undone. The block was already recorded as asked when the
    /// notification was posted, so this is final by construction: dismissal and the passage of time
    /// produce exactly the same outcome, which is what makes ignoring a banner safe.
    public func dismissOutstandingBlock() {
        outstandingOffer = nil
        gate.cancel(.unlabelledBlock)
    }

    /// *Stop asking* — switches this kind off for good, from the notification itself.
    ///
    /// The same switch the Alerts pane moves, so the pane shows what the banner did. Nothing is
    /// re-enabled by anything, ever; the user turns it back on in Settings or not at all.
    public func stopAsking(about kind: NotificationKind) async {
        outstandingOffer = nil
        await gate.setEnabled(false, for: kind)
        refreshForSwitchChange()
    }

    /// *Label them* — opens the review queue.
    public func openReview() {
        gate.cancel(.endOfDayReview)
        onOpenReview?()
    }

    // MARK: - The queue the review opens

    /// Today's unlabelled blocks, recomputed now.
    ///
    /// Recomputed rather than carried from the notification: minutes have passed, the user may have
    /// declared something in the meantime, and a queue that offers a block a session now accounts for
    /// would be the sheet arguing with the record. Safe to call whether or not anything was ever
    /// notified — `Report.nothing` is a valid answer and the sheet renders it as "nothing left".
    public func currentReport() -> UnlabelledWork.Report {
        UnlabelledWork.report(for: timeline(), policy: policy)
    }

    // MARK: - Memory

    private func remember(_ key: UnlabelledWork.BlockKey, at instant: Date) {
        offeredBlocks.insert(key)
        let day = dayStamp(for: instant)
        offeredDay = day
        defaults.set(day, forKey: Self.offeredDayKey)
        defaults.set(offeredBlocks.map(\.storageKey).sorted(), forKey: Self.offeredBlocksKey)
    }

    /// Empties the day's memory when the day changes.
    ///
    /// Without this the set grows for the life of the install, and the review would never be offered
    /// again after the first day it fired.
    private func rollOverIfNeeded(at instant: Date) {
        let day = dayStamp(for: instant)
        guard offeredDay != day else { return }
        offeredDay = day
        offeredBlocks = []
        outstandingOffer = nil
        defaults.set(day, forKey: Self.offeredDayKey)
        defaults.set([String](), forKey: Self.offeredBlocksKey)
    }

    /// `2026-07-25`, from the calendar in force.
    ///
    /// Assembled from components rather than through a `DateFormatter`, because a formatter reads the
    /// process locale and this string is an identity, not something anybody reads.
    private func dayStamp(for instant: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: instant)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }
}
