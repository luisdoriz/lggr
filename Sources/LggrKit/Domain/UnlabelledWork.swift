import Foundation

// Deciding whether Lggr has anything worth saying. See docs/_design/INTELLIGENCE.md §1 and §4
// Phase 2, and docs/_design/SPEC.md § Notifications.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THIS FILE EXISTS TO BE ABLE TO ANSWER "NOTHING"
//
//  Two prompts sit on top of it: a quiet offer while a long stretch of undeclared work is still
//  going on, and one end-of-day offer to label what the day left unlabelled. Both are the highest-
//  risk copy in the product, because macOS grants **one** notification authorisation for the whole
//  application: a single prompt that lands as a nag gets Lggr switched off in System Settings, and
//  the useful notifications — your fifty minutes are up, shall I trim this session — die with it,
//  silently and permanently, where the app cannot ask again.
//
//  So the interesting output of every function below is the *negative* one. An afternoon with
//  nothing worth labelling must produce silence rather than a congratulation, and a day the user
//  declared properly must produce no notification at all. Nothing here fires because the clock
//  reached a number; the clock only decides when Lggr is allowed to *look*, and what it finds is
//  what decides whether anything is sent.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// Four decisions are recorded here rather than in a document.
//
// ## 1. The unit is the block, not the application run
//
// `EpisodeBuilder` already turns six hundred activations into eight or ten blocks a person
// recognises, and it already decided that a five-second cmd-tab to Slack and back is an
// `interjection` rather than a context switch. Asking "has one application been frontmost
// continuously for fifteen minutes" against the raw activation stream would restart the clock on
// every glance, so the prompt would almost never fire for a real user — and when it did, it would be
// offering to label a stretch narrower than the one the timeline shows. The block is the thing the
// user can label, so the block is the thing this file measures. Nothing here re-segments anything.
//
// ## 2. Twenty minutes, and the reason it is a constant rather than a setting
//
// `INTELLIGENCE.md` §2 rejected `switchRateZ`/`appSetEntropy` in favour of *"the boring version
// first: an undeclared block worth asking about is one longer than 20 minutes not covered by a
// session. One rule, explainable in a sentence, works on day one, never fires on a flight."* That is
// the threshold for the day's report. The live offer uses a shorter one (fifteen minutes) because it
// is asking about work that is still happening, where the answer is in the user's head right now.
//
// Neither is exposed in the UI, for the reason `SegmentationWeights` is not: a user who has to tune
// the threshold below which their work is not worth mentioning has been handed our problem.
//
// ## 3. There is no count and no total anywhere in this type's *display* surface
//
// `INTELLIGENCE.md` §3.4 removed the "3 undeclared blocks" badge and the "Not in a session today —
// 2h 51m" total four separate times: a number on the default screen that grows when you fail to
// comply with the app and falls when you perform triage is a streak counter run in reverse. A count
// is available here because a *queue* needs to know how long it is and a *notification* has to state
// the size of the offer it is making — "3 blocks from today aren't labelled — about 2 minutes" is
// what makes the offer answerable. It is stated once, in the thing the user chose to receive, and it
// is never rendered on a screen they did not ask for.
//
// ## 4. Every silence has a name
//
// `PromptDecision` is an enum with one `.offer` case and nine reasons not to. Written that way so
// that "silent while a session is running, while tracking is paused, while the screen is locked, and
// outside the hours the user set" is nine tests over a pure function rather than nine `guard`s
// scattered through a service that only runs on a real machine.
//
// Pure, static, no clock, no I/O — the same shape as `EpisodeBuilder`, `SessionAutoClose` and
// `SessionFromEpisode`, and for the same reason: every case below is provable against a fixture on a
// machine with no Xcode, no permissions and nothing running.

// MARK: - Hours

/// The window of the day in which Lggr may offer to label something.
///
/// A prompt outside working hours is the same mechanism as a prompt on a schedule: it arrives because
/// of the clock rather than because of the work. The hours do not *cause* anything — they only bound
/// when a cause is allowed to be acted on — and they are the user's own, so an evening person is not
/// interrupted at nine in the morning and a morning person is left alone at eleven at night.
public struct PromptHours: Codable, Hashable, Sendable {

    /// Local hour, 0–23, at which offers become permissible.
    public let startHour: Int
    /// Local hour, 0–23, after which they stop. Equal to `startHour` means the whole day; less than
    /// it means the window crosses midnight.
    public let endHour: Int

    public init(startHour: Int = 9, endHour: Int = 18) {
        self.startHour = Self.clamp(startHour)
        self.endHour = Self.clamp(endHour)
    }

    private static func clamp(_ hour: Int) -> Int { min(23, max(0, hour)) }

    /// Nine to six, which is a guess — and it is only ever a *narrowing* guess. A user whose day
    /// starts at seven gets silence rather than a badly timed offer, which is the direction the error
    /// is allowed to run in.
    public static let `default` = PromptHours()

    /// The whole day, for a user who says so explicitly.
    public static let allDay = PromptHours(startHour: 0, endHour: 0)

    /// The window covers every hour, so there is no "outside" to be silent in.
    public var isAllDay: Bool { startHour == endHour }

    /// The window runs past midnight — 22:00 to 02:00, say.
    public var wrapsMidnight: Bool { endHour < startHour }

    /// Whether this instant falls inside the window.
    ///
    /// The calendar is supplied rather than read from `.current`, because a pure function that reads
    /// the process's locale is not reproducible in a test that runs in another timezone.
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard !isAllDay else { return true }
        let hour = calendar.component(.hour, from: date)
        if wrapsMidnight { return hour >= startHour || hour < endHour }
        return hour >= startHour && hour < endHour
    }

    /// How the Alerts pane names the window: "09:00 to 18:00".
    ///
    /// Deliberately not localised through `DateFormatter`: `LggrKit` has no locale opinion and the
    /// two hours here are integers the user picked from a menu, not instants.
    public var rangeText: String {
        isAllDay
            ? "any time of day"
            : String(format: "%02d:00 to %02d:00", startHour, endHour)
    }
}

// MARK: - Unlabelled work

/// What of the day is worth offering to label, and whether it is worth saying anything at all.
public enum UnlabelledWork {

    // MARK: - Policy

    /// Every constant the two prompts stand on, with its reasoning attached. Not exposed in the UI.
    public struct Policy: Equatable, Sendable {

        /// The shortest block the end-of-day review will offer. `INTELLIGENCE.md` §2's boring rule.
        public var minimumBlockDuration: TimeInterval

        /// How long a stretch of undeclared work has to run before the live offer appears.
        ///
        /// Shorter than `minimumBlockDuration` because the question is easier: the user is doing the
        /// work as they read it, so recall costs nothing. Long enough that a quarter of an hour of
        /// genuine focus has gone by — the offer must never arrive during the first minute of
        /// something, when the answer is still forming.
        public var openStretchDuration: TimeInterval

        /// How stale the newest block may be before the live offer treats the stretch as over.
        ///
        /// The sampler republishes its open interval on each flush, so a block that stopped growing
        /// means the user moved on — and an offer to label "what you are working on" about work that
        /// finished ten minutes ago is asking the wrong question. Two flush cadences.
        public var stretchStaleness: TimeInterval

        /// The longest queue the end-of-day review will assemble.
        ///
        /// *"Nobody labels one thing, most people will label eight in two minutes."* Past that it
        /// stops being a two-minute offer and becomes a backlog, and a backlog is the decision queue
        /// `INTELLIGENCE.md` §7 risk 9 warns about. Blocks past the cap are not lost — they stay on
        /// the timeline, labellable there, and age out silently into neutral tracked time.
        public var maximumBlocks: Int

        /// The estimate the notification quotes, per block. Half a minute each: a block whose
        /// evidence is on screen and whose outcome is usually one already used today.
        public var secondsPerBlock: TimeInterval

        /// Whether blocks recorded as a private application may be offered.
        ///
        /// **False, and it is not a privacy nicety — it is an honesty one.** A private block carries
        /// no application name, so the prompt would be asking "what was this?" while showing the user
        /// nothing they could recognise it by. An unrecognisable block gets a guess or a dismissal,
        /// and a guessed label on a record of the past is exactly what §1 is arranged to prevent.
        public var includesPrivateApplications: Bool

        /// The placeholder bundle identifier `ActivitySampler` records private activity under.
        ///
        /// A value rather than a literal so `LggrKit` does not have to know that `LggrApp` exists;
        /// the app passes its own constant and a fixture passes whatever it likes.
        public var privateBundleIdentifiers: Set<String>

        public init(
            minimumBlockDuration: TimeInterval = 20 * 60,
            openStretchDuration: TimeInterval = 15 * 60,
            stretchStaleness: TimeInterval = 150,
            maximumBlocks: Int = 8,
            secondsPerBlock: TimeInterval = 30,
            includesPrivateApplications: Bool = false,
            privateBundleIdentifiers: Set<String> = ["com.lggr.private"]
        ) {
            self.minimumBlockDuration = Self.sane(minimumBlockDuration)
            self.openStretchDuration = Self.sane(openStretchDuration)
            self.stretchStaleness = Self.sane(stretchStaleness)
            self.maximumBlocks = max(1, maximumBlocks)
            self.secondsPerBlock = Self.sane(secondsPerBlock)
            self.includesPrivateApplications = includesPrivateApplications
            self.privateBundleIdentifiers = privateBundleIdentifiers
        }

        private static func sane(_ value: TimeInterval) -> TimeInterval {
            value.isFinite ? max(0, value) : 0
        }

        public static let `default` = Policy()
    }

    // MARK: - A stable name for a stretch of work

    /// Identifies a block across the rebuilds that happen while it is still growing.
    ///
    /// `Episode.id` is derived from the block's own bounds, which is exactly right for a sealed day
    /// and exactly wrong here: the newest block's `end` moves forward on every flush of the sampler,
    /// so its identifier changes once a minute. Keying "we have already offered this one" on it would
    /// re-offer the same stretch of work every minute — which is the nag that costs the
    /// authorisation, and the one rule in this feature that has no acceptable failure.
    ///
    /// The start of a block does not move while the block grows, and the dominant application does
    /// not either, so the two together name the stretch for as long as it lasts. Whole seconds,
    /// because a `Date` round-tripped through JSON is not bit-identical to the one that went in.
    public struct BlockKey: Hashable, Codable, Sendable {

        public let bundleIdentifier: String
        /// Whole seconds since the reference date.
        public let startSecond: Int

        public init(bundleIdentifier: String, startSecond: Int) {
            self.bundleIdentifier = bundleIdentifier
            self.startSecond = startSecond
        }

        public init(_ episode: Episode) {
            self.init(
                bundleIdentifier: episode.dominantApp?.bundleIdentifier ?? "",
                startSecond: Int(episode.start.timeIntervalSinceReferenceDate.rounded(.down))
            )
        }

        /// A form that survives `UserDefaults`, so a relaunch in the middle of a block does not
        /// produce a second offer for it.
        public var storageKey: String { "\(startSecond)|\(bundleIdentifier)" }

        public init?(storageKey: String) {
            let parts = storageKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let second = Int(parts[0]) else { return nil }
            self.init(bundleIdentifier: String(parts[1]), startSecond: second)
        }
    }

    // MARK: - The day's report

    /// What the day left unlabelled, and how big an offer that is.
    ///
    /// Willing to be empty, and an empty one is the common case for a diligent day. Nothing that
    /// reads a `Report` may treat emptiness as an error or as an occasion for a sentence.
    public struct Report: Equatable, Sendable {

        /// The blocks worth offering, oldest first — the order a queue should walk them in, because
        /// it is the order the day happened in.
        public let blocks: [Episode]

        /// Qualifying blocks beyond `Policy.maximumBlocks`, left on the timeline.
        ///
        /// Reported so a caller can say the queue is not everything, and deliberately **not**
        /// rendered as a backlog count anywhere.
        public let setAside: Int

        /// The estimate the copy quotes, carried so the sentence and the sheet cannot disagree.
        public let secondsPerBlock: TimeInterval

        public init(blocks: [Episode], setAside: Int = 0, secondsPerBlock: TimeInterval = 30) {
            self.blocks = blocks
            self.setAside = max(0, setAside)
            self.secondsPerBlock = max(0, secondsPerBlock.isFinite ? secondsPerBlock : 0)
        }

        /// Nothing is worth saying. **The correct output for a well-declared day**, and the thing
        /// every caller must be able to act on by doing nothing at all.
        public static let nothing = Report(blocks: [])

        public var isEmpty: Bool { blocks.isEmpty }
        public var count: Int { blocks.count }

        /// Measured application time across the queue. Idle inside a block is excluded, exactly as
        /// it is everywhere else in the product.
        public var measuredDuration: TimeInterval {
            blocks.reduce(0) { $0 + $1.activeDuration }
        }

        /// How long the review is likely to take, rounded up to a whole minute.
        ///
        /// Rounded **up** rather than to nearest: an offer that under-promises the cost and then
        /// takes longer is the last time the user accepts one.
        public var estimatedDuration: TimeInterval {
            guard !isEmpty else { return 0 }
            let raw = Double(count) * secondsPerBlock
            return max(60, (raw / 60).rounded(.up) * 60)
        }

        /// "about a minute" / "about 2 minutes". Never a range, never a countdown.
        public var estimateText: String {
            let minutes = Int((estimatedDuration / 60).rounded())
            return minutes <= 1 ? "about a minute" : "about \(minutes) minutes"
        }

        /// *"3 blocks from today aren't labelled — about 2 minutes."*
        ///
        /// The whole offer in one line: what the record shows, and what answering costs. It reports
        /// and it does not imply anybody failed — there is no *forgot*, no *missed*, no *should*, and
        /// the subject of the sentence is the blocks rather than the person. Empty for an empty
        /// report, because there is no sentence to say about a day with nothing in it.
        public var sentence: String {
            switch count {
            case 0: ""
            case 1: "One block from today isn't labelled — \(estimateText)."
            default: "\(count) blocks from today aren't labelled — \(estimateText)."
            }
        }

        /// One line for the review sheet's header, stating position in the queue.
        public func progressText(at index: Int) -> String {
            guard !isEmpty else { return "" }
            let position = min(max(1, index + 1), count)
            return "Block \(position) of \(count)"
        }
    }

    /// The blocks of this day worth offering to label.
    ///
    /// Three conditions, and the first two are the whole rule:
    ///
    ///   * **Nobody declared anything over it.** `Episode.isUnlabelled` — no session lent it a name,
    ///     and it holds measured time.
    ///   * **It is long enough to matter.** `Policy.minimumBlockDuration` of *measured* time, not
    ///     wall-clock span, so a block that is mostly idle is not offered as though it were work.
    ///   * **There is something to recognise it by** — see `Policy.includesPrivateApplications`.
    ///
    /// Gaps cannot appear here by construction: a `DayTimeline` keeps its absences in a separate
    /// collection and this reads `episodes` only. An hour of sleep is not an unlabelled block and
    /// must never be offered as one.
    ///
    /// - Returns: `.nothing` when the day holds no such block. That is the answer that stops a
    ///   prompt from firing on an empty afternoon, and it is a result rather than a failure.
    public static func report(for timeline: DayTimeline, policy: Policy = .default) -> Report {
        let qualifying =
            timeline
            .unlabelledEpisodes
            .filter { isWorthOffering($0, policy: policy) }
            .sorted { $0.start < $1.start }

        guard !qualifying.isEmpty else { return .nothing }

        return Report(
            blocks: Array(qualifying.prefix(policy.maximumBlocks)),
            setAside: max(0, qualifying.count - policy.maximumBlocks),
            secondsPerBlock: policy.secondsPerBlock
        )
    }

    /// Whether one block, on its own, is worth asking about.
    ///
    /// Separate from `report(for:)` so the live offer and the end-of-day review apply the same test
    /// to the same block. Two surfaces disagreeing about which blocks count is how a user gets asked
    /// twice about the same stretch of work by two different mechanisms.
    public static func isWorthOffering(
        _ episode: Episode,
        minimumDuration: TimeInterval? = nil,
        policy: Policy = .default
    ) -> Bool {
        guard episode.isUnlabelled else { return false }
        guard episode.activeDuration >= (minimumDuration ?? policy.minimumBlockDuration) else {
            return false
        }
        guard policy.includesPrivateApplications || !isPrivate(episode, policy: policy) else {
            return false
        }
        return true
    }

    /// Every application in the block is one the user marked private, so there is nothing to show
    /// them as evidence. A block that is *partly* private still has a name to recognise.
    private static func isPrivate(_ episode: Episode, policy: Policy) -> Bool {
        guard !episode.apps.isEmpty else { return true }
        return episode.apps.allSatisfy {
            policy.privateBundleIdentifiers.contains($0.bundleIdentifier)
        }
    }

    // MARK: - Why nothing was said

    /// Every reason a prompt does not appear, named.
    ///
    /// Exhaustive on purpose. A silence with no name is a silence nobody can test, and the failure
    /// this feature cannot survive — an offer arriving twice, or during a meeting, or at midnight —
    /// is a missing case in exactly this list.
    public enum Silence: String, CaseIterable, Sendable, Hashable {

        /// The user switched this prompt off. Checked first, and before anything is computed.
        case switchedOff

        /// This stretch of work has already been offered, or dismissed, once. **The rule with no
        /// acceptable failure:** asking twice makes it a nag, a nag gets switched off in System
        /// Settings, and switched off is permanent.
        case alreadyOffered

        /// A session is running, so the user has already said what they are doing. Asking would be
        /// the app failing to read its own record.
        case sessionRunning

        /// The user turned tracking off. Nothing is being recorded, so there is nothing to label and
        /// no standing to ask.
        case trackingPaused

        /// The screen is locked. A banner nobody is there to read is one that arrives as a pile
        /// later, which is how a useful notification becomes an annoying one.
        case screenLocked

        /// Outside the hours the user set.
        case outsideHours

        /// Nothing on the timeline is unlabelled — the ordinary output of a declared day.
        case nothingUnlabelled

        /// The stretch is real but has not run long enough to be worth interrupting for.
        case stretchTooShort

        /// The newest block stopped growing, so the user has moved on and "what are you working on"
        /// is no longer the right question.
        case stretchEnded

        /// The end-of-day review's hour has not arrived. The hour decides when Lggr may *look*; what
        /// it finds decides whether anything is sent.
        case notYetDue

        /// A fact about the record, for a log or a diagnostic. Never rendered to the user: the
        /// correct user-facing expression of every case here is nothing at all.
        public var note: String {
            switch self {
            case .switchedOff: "switched off"
            case .alreadyOffered: "already offered for this block"
            case .sessionRunning: "a session is running"
            case .trackingPaused: "tracking is paused"
            case .screenLocked: "the screen is locked"
            case .outsideHours: "outside the hours set for prompts"
            case .nothingUnlabelled: "nothing on the timeline is unlabelled"
            case .stretchTooShort: "the block is shorter than the threshold"
            case .stretchEnded: "the block is no longer growing"
            case .notYetDue: "the review time has not arrived"
            }
        }
    }

    // MARK: - The live offer

    /// What the app knows about itself at the moment the live offer is considered.
    ///
    /// A value rather than eight reads of eight services, so the decision is a pure function of
    /// stated facts and every branch of it is provable without a running machine.
    public struct Conditions: Equatable, Sendable {

        public var isEnabled: Bool
        public var isSessionRunning: Bool
        public var isTrackingPaused: Bool
        public var isScreenLocked: Bool
        /// Whether `now` falls inside `PromptHours`. Resolved by the caller, which owns the calendar.
        public var isWithinHours: Bool
        /// Block keys already offered or dismissed today.
        public var offeredBlocks: Set<BlockKey>

        public init(
            isEnabled: Bool = true,
            isSessionRunning: Bool = false,
            isTrackingPaused: Bool = false,
            isScreenLocked: Bool = false,
            isWithinHours: Bool = true,
            offeredBlocks: Set<BlockKey> = []
        ) {
            self.isEnabled = isEnabled
            self.isSessionRunning = isSessionRunning
            self.isTrackingPaused = isTrackingPaused
            self.isScreenLocked = isScreenLocked
            self.isWithinHours = isWithinHours
            self.offeredBlocks = offeredBlocks
        }
    }

    /// The offer, or the named reason there is not one.
    public enum PromptDecision: Equatable, Sendable {

        /// Offer to label this block, once. The key is what the caller records so it never asks again.
        case offer(Offer)
        case silent(Silence)

        public var offer: Offer? {
            if case .offer(let offer) = self { return offer }
            return nil
        }

        public var silence: Silence? {
            if case .silent(let silence) = self { return silence }
            return nil
        }

        public var isOffer: Bool { offer != nil }
    }

    /// One block, ready to be offered.
    public struct Offer: Equatable, Sendable {
        public let key: BlockKey
        /// The block as it stands. Its `id` is what a sheet route carries; resolve it late, because
        /// the next flush replaces it.
        public let episode: Episode
        /// Measured time so far.
        public var duration: TimeInterval { episode.activeDuration }

        public init(key: BlockKey, episode: Episode) {
            self.key = key
            self.episode = episode
        }
    }

    /// Whether to offer to label the stretch of work happening right now.
    ///
    /// The precedence is deliberate and is the specification:
    ///
    ///   1. `switchedOff` — before anything is read, so a user who turned this off costs the app zero
    ///      work as well as zero banners.
    ///   2. `sessionRunning`, `trackingPaused`, `screenLocked`, `outsideHours` — the four states in
    ///      which Lggr has nothing to say, checked before the timeline is consulted at all.
    ///   3. `nothingUnlabelled` — the day holds no undeclared block.
    ///   4. `alreadyOffered` — checked against the *block*, not the day, and checked before the
    ///      duration so that a block already answered can never be re-offered as it keeps growing.
    ///   5. `stretchEnded`, `stretchTooShort` — the stretch itself.
    ///
    /// - Parameters:
    ///   - timeline: the day as it stands. Read, never rebuilt.
    ///   - now: the instant being decided at. Supplied, because a pure function may not read a clock.
    public static func liveOffer(
        in timeline: DayTimeline,
        now: Date,
        conditions: Conditions,
        policy: Policy = .default
    ) -> PromptDecision {
        guard conditions.isEnabled else { return .silent(.switchedOff) }
        guard !conditions.isSessionRunning else { return .silent(.sessionRunning) }
        guard !conditions.isTrackingPaused else { return .silent(.trackingPaused) }
        guard !conditions.isScreenLocked else { return .silent(.screenLocked) }
        guard conditions.isWithinHours else { return .silent(.outsideHours) }

        // The newest block, and only the newest: an offer about something four hours old is a
        // memory test, and the timeline is where older blocks are labelled with their evidence in
        // front of them.
        guard let episode = timeline.latestUnlabelledEpisode else {
            return .silent(.nothingUnlabelled)
        }
        guard policy.includesPrivateApplications || !isPrivate(episode, policy: policy) else {
            return .silent(.nothingUnlabelled)
        }

        let key = BlockKey(episode)
        guard !conditions.offeredBlocks.contains(key) else { return .silent(.alreadyOffered) }

        guard now.timeIntervalSince(episode.end) <= policy.stretchStaleness else {
            return .silent(.stretchEnded)
        }
        guard episode.activeDuration >= policy.openStretchDuration else {
            return .silent(.stretchTooShort)
        }

        return .offer(Offer(key: key, episode: episode))
    }

    // MARK: - The end-of-day offer

    /// What the app knows when the end-of-day review is considered.
    public struct ReviewConditions: Equatable, Sendable {

        public var isEnabled: Bool
        /// The user's chosen hour has arrived. **This is permission to look, not a cause to send.**
        public var isDue: Bool
        public var isScreenLocked: Bool
        /// A session is running. The review waits: it is a report about the whole day and nothing
        /// about it expires, so interrupting work in progress with it would buy nothing.
        public var isSessionRunning: Bool
        /// Whether today's review has already been offered. One per day, and never a second attempt.
        public var hasAlreadyOffered: Bool

        public init(
            isEnabled: Bool = true,
            isDue: Bool = true,
            isScreenLocked: Bool = false,
            isSessionRunning: Bool = false,
            hasAlreadyOffered: Bool = false
        ) {
            self.isEnabled = isEnabled
            self.isDue = isDue
            self.isScreenLocked = isScreenLocked
            self.isSessionRunning = isSessionRunning
            self.hasAlreadyOffered = hasAlreadyOffered
        }
    }

    /// The end-of-day review, or the named reason there is not one.
    public enum ReviewDecision: Equatable, Sendable {
        case offer(Report)
        case silent(Silence)

        public var report: Report? {
            if case .offer(let report) = self { return report }
            return nil
        }

        public var silence: Silence? {
            if case .silent(let silence) = self { return silence }
            return nil
        }

        public var isOffer: Bool { report != nil }
    }

    /// Whether to offer the end-of-day review of what today left unlabelled.
    ///
    /// **The hour is not the cause.** `SPEC.md` names four notifications and every one of them fires
    /// because something happened; a banner that arrives because the clock reached 18:00 is the
    /// re-engagement mechanism this product does not ship. So the user's chosen time only opens the
    /// window in which Lggr is permitted to *look at the record*, and the report is what decides
    /// whether anything is sent. A day with nothing unlabelled produces `.silent(.nothingUnlabelled)`
    /// — no notification, no summary, and **no congratulation**, which would be the same interruption
    /// wearing a compliment.
    public static func reviewOffer(
        for timeline: DayTimeline,
        conditions: ReviewConditions,
        policy: Policy = .default
    ) -> ReviewDecision {
        guard conditions.isEnabled else { return .silent(.switchedOff) }
        guard !conditions.hasAlreadyOffered else { return .silent(.alreadyOffered) }
        guard conditions.isDue else { return .silent(.notYetDue) }
        guard !conditions.isSessionRunning else { return .silent(.sessionRunning) }
        guard !conditions.isScreenLocked else { return .silent(.screenLocked) }

        let report = report(for: timeline, policy: policy)
        guard !report.isEmpty else { return .silent(.nothingUnlabelled) }
        return .offer(report)
    }
}

// MARK: - Finding a block again

extension DayTimeline {

    /// The block this key names, if it is still on the timeline.
    ///
    /// Needed because a notification's button is pressed minutes after the notification was posted,
    /// by which time the sampler has flushed and `EpisodeBuilder` has rebuilt the day — so the
    /// `Episode` that was offered is a value that no longer exists. Resolving by
    /// `UnlabelledWork.BlockKey` finds the same stretch of work at whatever length it has reached; if
    /// the segmentation genuinely changed and the key no longer resolves, the caller closes the sheet
    /// rather than labelling a block that is no longer there.
    public func episode(matching key: UnlabelledWork.BlockKey) -> Episode? {
        episodes.first { UnlabelledWork.BlockKey($0) == key }
    }
}
