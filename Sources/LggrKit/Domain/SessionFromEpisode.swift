import Foundation

// Turning a block the app reconstructed into a session.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE RECORD IS PRIMARY; A SESSION IS A LABEL APPLIED TO PART OF IT
//
//  Every tracker that needs the user to remember to press start measures their discipline rather
//  than their work. Lggr already captures the whole day passively — `EpisodeBuilder` reconstructs it
//  into blocks a person recognises — so the one thing still missing is the gesture that says *"that
//  block was the receipt deduplication PR"*. This file is that gesture's arithmetic.
//
//  The consequence, and it is the whole point: **forgetting costs a label, never the time.** The
//  times on the session below were measured while the user was working, whether or not they
//  announced anything.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// Three decisions are recorded here rather than in a document, because each one is a claim the
// weekly review will repeat for months and none of them is obvious.
//
// ## 1. Provenance is a field of its own, and `editedAt` is not it
//
// `editedAt` means one specific thing, and its own documentation settles it: *"when the user last
// corrected this session's times by hand."* Nobody typed these times — they were observed — so
// stamping `editedAt` would have the app claim the user's authorship for its own reading, and would
// make "did you type this, or did we?" unanswerable at exactly the moment somebody is deciding
// whether to believe the number. Same argument, same conclusion, as `autoClosedAt` (see
// `SessionAutoClose.applyAutoClose`).
//
// But a reconstructed session is not a declared one either, and the difference matters more than the
// difference an edit makes. **Work the user labelled afterwards is not the same evidence as work
// they committed to in advance**, and `PlannedVsReactive` — the one analysis this product exists to
// produce — must never conflate the two. A session declared at 09:00 carries an *intent*; a block
// labelled at 16:00 carries a *description*. No reconstruction can infer intent, and pretending
// otherwise would let the app inflate planned time by exactly as much as the user forgot to declare.
//
// So a third field: `FocusSession.reconstructedAt`, with `provenance` derived from it. It is an
// instant rather than a flag for the reason `autoClosedAt` is one — *when* the label was applied is
// the difference between labelling this morning's block this afternoon and labelling it next
// Thursday — and it is `Optional` so that a session written by an earlier build still decodes.
//
// Two consequences are enforced here rather than left to a caller:
//
//   * **`isReactive` is forced true**, whatever the work type's default says. `INTELLIGENCE.md` §4
//     Phase 2 requires it and its acceptance criterion 2 is the test: *"weekly planned vs reactive
//     is unchanged by reconstruction — reconstruction adds reactive time only."* A reconstructed
//     `.deepWork` block is still reactive, because the reaction is the labelling.
//   * **`weeklyOutcomeID` is always `nil`.** `PlannedVsReactive.origin` reads it to split planned
//     time into committed and chosen, and attaching a weekly outcome to a block found after the fact
//     would file it as work the user committed to in advance — which is the exact conflation above,
//     one field further down.
//
// ## 2. A reconstructed session is complete in the same gesture, and lands `.madeProgress`
//
// It has no review, and it must not acquire one. A finished session with `resultStatus == nil` is
// `.awaitingReview`: it grows a *Review* button, `SessionManager.loadUnreviewedSession` adopts it at
// launch, and the menu bar turns to `questionmark.circle`. Labelling three morning blocks would then
// leave three unanswered questions behind it — a decision queue, which is `INTELLIGENCE.md` §7's
// risk 9 exactly: *"a decision queue is data entry with the typing removed."* The whole value of
// this feature is that it costs almost nothing, and a second sheet costs more than the first one
// saved.
//
// So it lands answered. `.madeProgress` and not `.completed`, for two reasons that agree:
// `SessionResultStatus.countsAsCompleted` feeds the weekly *focus sessions completed* count, which
// §4 Phase 2 requires reconstructed sessions to be excluded from; and the user typed a description
// of what a stretch of time *was*, which is not an assertion that the outcome landed. `.madeProgress`
// claims time was spent toward something named and claims nothing else. It also reports
// `needsFollowUp == false`, so nothing offers to chase it.
//
// `resultSummary` is deliberately left empty rather than generated. `SessionSummaryBuilder` states
// durations and application names, which would be true here — but it is written for a session the
// user watched end, and a sentence nobody asked for on a record nobody reviewed is one more thing to
// read. The block's own evidence is on the timeline, one row above.
//
// ## 3. Overlap is trimmed, not refused — and double-counted time is impossible
//
// A block can overlap a session that already exists: the user declared the last twenty minutes and
// worked the first forty without saying so. Refusing outright would make the feature fail precisely
// when somebody has been partly diligent, which punishes the behaviour the product wants. So the
// claim is trimmed to measured time no session already accounts for.
//
// The rules that keep that safe:
//
//   * **It can only ever shrink.** No branch below moves a bound outward, so no branch can invent
//     time. Trimming is computed against the sessions the caller hands over, and time already inside
//     one is never claimed twice.
//   * **A session in the middle splits the block, and one gesture writes one record.** The longest
//     surviving stretch is claimed and the rest is reported as dropped, so the sheet can say so. Two
//     sessions from one keystroke would be the app deciding something it was not asked to decide.
//   * **A running session claims everything from its start to the end of the block.** It has no
//     `endedAt` and this function has no clock, so the conservative reading is the only honest one:
//     it under-claims, and under-claiming is the only acceptable failure direction.
//   * **Nothing left means nothing written.** A block wholly inside an existing session is refused,
//     with a sentence that says which fact the record already holds.
//
// ## Idle time inside the block is recorded as paused, not as focus
//
// `Episode.wallClockSpan` places the block; `Episode.activeDuration` is what was actually measured
// in an application. The difference is idle, and crediting it as focus would be the one thing this
// whole design is arranged to avoid. `FocusSession` already has the mechanism — `pausedDuration`
// is subtracted from the span to give `effectiveDuration` — so the block's idle becomes the
// session's paused time and the session reports the measured figure.
//
// After a trim, *where* in the block the idle fell is unknown. The full amount is carried over
// anyway (clamped into the shortened span), which under-claims when the idle sat in the part that
// was trimmed away. That is the direction the error is allowed to run in.
//
// Pure, static, no clock and no I/O — the same shape as `EpisodeBuilder` and `SessionAutoClose`, and
// for the same reason: every case below is provable against a fixture on a machine with no Xcode, no
// permissions and nothing running.

/// Why a session exists: because the user declared it in advance, or because they labelled a block
/// the app had already measured.
///
/// Not the same distinction as `editedAt`, and not a subset of it. An edit corrects a number; this
/// says the number was never announced. `PlannedVsReactive` depends on being able to tell the two
/// apart — see the reasoning at the top of `SessionFromEpisode.swift`.
public enum SessionProvenance: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {

    /// The user started this session before doing the work, and named an intended outcome first.
    case declared

    /// The user labelled a block Lggr had already reconstructed. The times were measured; the label
    /// arrived afterwards.
    case reconstructed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .declared: "Declared"
        case .reconstructed: "Labelled afterwards"
        }
    }

    /// A fact about the record, in one clause. Never about the person: no case here says "you forgot".
    public var recordNote: String {
        switch self {
        case .declared: "started before the work"
        case .reconstructed: "labelled from time Lggr had already measured"
        }
    }

    public var symbolName: String {
        switch self {
        case .declared: "play.circle"
        case .reconstructed: "clock.arrow.circlepath"
        }
    }

    /// This session carries an intent the user stated in advance.
    ///
    /// Read by anything that needs planned work to mean *chosen ahead of time*. A reconstruction
    /// cannot infer intent, so it never answers `true` here.
    public var statesIntent: Bool { self == .declared }
}

/// Builds a `FocusSession` out of one reconstructed block.
///
/// Two entry points, deliberately: `claim(for:existingSessions:)` answers *"can this block become a
/// session, and over what span"* with no label at all, so a sheet can open — or refuse to open — the
/// instant a row is clicked; `session(for:label:existingSessions:at:)` produces the record. Both run
/// the same geometry, so what the sheet shows and what the store receives cannot disagree. It is the
/// dry-run/apply pairing `SessionEditing` uses, for the same reason.
public enum SessionFromEpisode {

    // MARK: - Policy

    /// The one constant, with its reasoning attached.
    ///
    /// Not exposed in the UI, for the reason `SegmentationWeights` is not: a user who has to tune the
    /// threshold below which a labelled block is not worth recording has been handed our problem.
    public struct Policy: Equatable, Sendable {

        /// The shortest stretch worth a session of its own.
        ///
        /// Only ever reached after a trim. A block is at least `SegmentationWeights.minEpisode`
        /// long by construction, so this exists for the case where an existing session covers all
        /// but a sliver of one — and a forty-second session with a typed sentence attached to it is
        /// a record that costs more to read than it reports.
        public var minimumClaim: TimeInterval

        public init(minimumClaim: TimeInterval = 60) {
            self.minimumClaim = max(0, minimumClaim.isFinite ? minimumClaim : 0)
        }

        public static let `default` = Policy()
    }

    /// The status a reconstructed session lands with. See decision 2 at the top of this file.
    ///
    /// A named constant rather than a literal at the one call site, because *which* status is a
    /// design commitment with two separate consequences — it keeps the session out of the review
    /// queue and out of the weekly completed count — and a commitment that lives in one place can be
    /// tested in one place.
    public static let resultStatus: SessionResultStatus = .madeProgress

    // MARK: - What the user supplies

    /// The three things the user types or chooses. Everything else about the session is measured.
    public struct Label: Equatable, Sendable {

        /// What the block was. Required, exactly as it is when a session is declared: a record with
        /// no sentence on it is a row nobody can read next week.
        public var intendedOutcome: String
        /// `nil` is "No project", which is a fully supported way to work.
        public var projectID: UUID?
        public var workType: WorkType

        public init(intendedOutcome: String, projectID: UUID? = nil, workType: WorkType = .deepWork) {
            self.intendedOutcome = intendedOutcome
            self.projectID = projectID
            self.workType = workType
        }

        /// The outcome as it would be stored.
        public var trimmedOutcome: String {
            intendedOutcome.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Whether this label can produce a session. The sheet reads it to decide whether ⌘⏎ is ready.
        public var isComplete: Bool { !trimmedOutcome.isEmpty }
    }

    // MARK: - Refusals

    /// Why a block cannot become a session.
    ///
    /// Every case names a fact about the record, and none of them has the user as its subject. The
    /// sentences are what a sheet prints instead of a form, so each one says what is already true
    /// rather than what the user should have done.
    public enum Refusal: Error, Equatable, Sendable {

        /// The block has no measured time at all — a zero-length episode, which the builder should
        /// never produce and which is refused here rather than written as a zero-length session.
        case notMeasured

        /// The block already borrowed its name from a session, so it is already labelled. Caught by
        /// identity rather than by geometry, because it is the same fact stated more cheaply.
        case alreadyLabelled(sessionID: UUID)

        /// Sessions already account for this block, or for all but `remaining` of it.
        case alreadyAccounted(remaining: TimeInterval)

        /// No outcome was typed. Raised only by `session(for:label:…)`; `claim` never needs a label.
        case outcomeMissing

        /// One plain sentence. Facts about the record, never about the person.
        public var sentence: String {
            switch self {
            case .notMeasured:
                "Lggr measured no time in this block, so there is nothing to label."
            case .alreadyLabelled:
                "This block is already part of a session."
            case .alreadyAccounted:
                "Sessions already account for this block."
            case .outcomeMissing:
                "Add what this was to save it."
            }
        }

        /// True when an existing session is the reason. The sheet offers *Correct times…* on these
        /// two and on nothing else — that is where a span already inside a session gets changed.
        public var isCoveredByASession: Bool {
            switch self {
            case .alreadyLabelled, .alreadyAccounted: true
            case .notMeasured, .outcomeMissing: false
            }
        }
    }

    // MARK: - The claim

    /// Which part of a block a new session may claim, and what it gave up.
    ///
    /// Every duration here is a fact the sheet can state before anything is written, so the sentence
    /// the user reads and the record that is saved come from one piece of arithmetic.
    public struct Claim: Equatable, Sendable {

        /// The block's own measured bounds, untouched.
        public let measured: DateInterval
        /// The span the session will record. Never wider than `measured`.
        public let claimed: DateInterval
        /// Measured time an existing session already accounts for. Never claimed twice.
        public let overlapRemoved: TimeInterval
        /// Unclaimed time that survived the overlap but fell outside the stretch being claimed —
        /// what a session sitting in the middle of a block leaves on the other side of itself.
        public let fragmentsDropped: TimeInterval
        /// Time inside `claimed` with no measured application activity behind it. Recorded as paused,
        /// never as focus.
        public let idleWithheld: TimeInterval

        public init(
            measured: DateInterval,
            claimed: DateInterval,
            overlapRemoved: TimeInterval,
            fragmentsDropped: TimeInterval,
            idleWithheld: TimeInterval
        ) {
            self.measured = measured
            self.claimed = claimed
            self.overlapRemoved = max(0, overlapRemoved)
            self.fragmentsDropped = max(0, fragmentsDropped)
            self.idleWithheld = max(0, idleWithheld)
        }

        /// Wall-clock length of the claimed span, paused time included.
        public var span: TimeInterval { max(0, claimed.end.timeIntervalSince(claimed.start)) }

        /// What the session will report as focus.
        public var effectiveDuration: TimeInterval { max(0, span - idleWithheld) }

        /// The claim is narrower than the block. The sheet says so when it is.
        public var wasTrimmed: Bool { claimed != measured }

        /// Measured wall-clock time this session declines to record, for whatever reason.
        public var withheld: TimeInterval {
            max(0, measured.end.timeIntervalSince(measured.start) - span)
        }

        /// *"12m of this block is already inside a session, so this records 9:26–9:58."*
        ///
        /// The times themselves are formatted by the caller: `LggrKit` has no locale opinion, and
        /// every screen in the app already prints ranges its own way. Assembling the sentence here is
        /// what keeps the sheet and any future surface from wording the same fact two ways.
        ///
        /// - Returns: `nil` when nothing was trimmed, which is the ordinary case and needs no
        ///   sentence at all.
        public func trimNote(overlapText: String, claimedRangeText: String) -> String? {
            guard wasTrimmed else { return nil }
            return "\(overlapText) of this block is already inside a session, "
                + "so this records \(claimedRangeText)."
        }
    }

    /// A session that has not been saved yet, and the arithmetic behind it.
    public struct Reconstruction: Equatable, Sendable {
        public let session: FocusSession
        public let claim: Claim

        public init(session: FocusSession, claim: Claim) {
            self.session = session
            self.claim = claim
        }
    }

    // MARK: - Geometry

    /// Whether this block can become a session, and over what span — with no label required.
    ///
    /// Called the moment a timeline row is clicked, so the sheet either opens on a span it can
    /// justify or does not open at all. A refusal is not an error state: it is the honest answer for
    /// a block the record already accounts for.
    ///
    /// - Parameters:
    ///   - episode: The block, as `EpisodeBuilder` produced it.
    ///   - existingSessions: Everything already declared that could overlap. Passing more than
    ///     necessary is harmless; passing too few is what would double-count, so callers hand over
    ///     the day.
    public static func claim(
        for episode: Episode,
        existingSessions: [FocusSession] = [],
        policy: Policy = .default
    ) -> Result<Claim, Refusal> {
        // The block already wears a session's own sentence. Stated by identity because it is the
        // same fact the geometry below would find, one comparison instead of a subtraction.
        if let sessionID = episode.sessionID {
            return .failure(.alreadyLabelled(sessionID: sessionID))
        }

        let measured = DateInterval(start: episode.start, end: max(episode.start, episode.end))
        guard measured.duration > 0, episode.activeDuration > 0 else {
            return .failure(.notMeasured)
        }

        let free = unclaimed(within: measured, given: existingSessions)
        let freeTotal = free.reduce(0) { $0 + $1.duration }
        let overlapRemoved = max(0, measured.duration - freeTotal)

        // Longest first; on an exact tie the earlier one wins, so the same block and the same
        // sessions always produce the same session. A tie broken by dictionary order would make a
        // reconstruction that differs between two runs over identical evidence.
        let chosen = free.max { left, right in
            (left.duration, right.start) < (right.duration, left.start)
        }

        guard let chosen, chosen.duration >= policy.minimumClaim, chosen.duration > 0 else {
            return .failure(.alreadyAccounted(remaining: chosen?.duration ?? 0))
        }

        let idle = max(0, measured.duration - episode.activeDuration)

        return .success(
            Claim(
                measured: measured,
                claimed: chosen,
                overlapRemoved: overlapRemoved,
                fragmentsDropped: max(0, freeTotal - chosen.duration),
                // Clamped into the shortened span. The full amount is carried rather than scaled:
                // scaling would be a guess about where the idle sat, and this direction under-claims.
                idleWithheld: min(idle, chosen.duration)
            )
        )
    }

    /// The session this block becomes.
    ///
    /// - Parameters:
    ///   - label: what the user typed and chose. The only three fields that are not measured.
    ///   - at: when the label was applied. Stored as `reconstructedAt`, injected rather than read
    ///     from `Date()` so this stays a pure function of its inputs, like every other transition in
    ///     `LggrKit`.
    ///   - id: the new session's identifier. A parameter so a test can assert the whole value.
    public static func session(
        for episode: Episode,
        label: Label,
        existingSessions: [FocusSession] = [],
        at instant: Date,
        id: UUID = UUID(),
        policy: Policy = .default
    ) -> Result<Reconstruction, Refusal> {
        // Geometry first. A block the record already accounts for is refused whether or not the user
        // has typed anything, and being told that before being asked to type is the better order.
        let claimed: Claim
        switch claim(for: episode, existingSessions: existingSessions, policy: policy) {
        case .success(let value): claimed = value
        case .failure(let refusal): return .failure(refusal)
        }

        guard label.isComplete else { return .failure(.outcomeMissing) }

        let session = FocusSession(
            id: id,
            projectID: label.projectID,
            // Never a weekly outcome. Decision 1: a block found after the fact is not work the user
            // committed to in advance, and `PlannedVsReactive` reads this field to say which it was.
            weeklyOutcomeID: nil,
            intendedOutcome: label.trimmedOutcome,
            workType: label.workType,
            // No target. There was none — nobody set one — and recording the measured length as a
            // plan would manufacture an intent that was hit exactly, on every reconstructed session
            // ever written.
            plannedDuration: nil,
            startedAt: claimed.claimed.start,
            endedAt: claimed.claimed.end,
            // The block's idle, recorded as what it was. See the note at the top of this file.
            pausedDuration: claimed.idleWithheld,
            pauseStartedAt: nil,
            resultStatus: resultStatus,
            // Deliberately empty. Decision 2: a generated sentence on a record nobody reviewed is
            // one more thing to read, and the block's evidence is already on the timeline.
            resultSummary: nil,
            // Always reactive, whatever the work type's default says. `INTELLIGENCE.md` §4 Phase 2:
            // reconstruction adds reactive time only, so the planned/reactive split is unchanged by it.
            isReactive: true,
            // Not observed, not typed, and not the app's arithmetic either: the label arrived after
            // the times did, and that is its own fact.
            reconstructedAt: instant
        )

        return .success(Reconstruction(session: session, claim: claimed))
    }

    // MARK: - Pre-filling the two fields that are not typed

    /// The work type a category implies, or `nil` when it implies none.
    ///
    /// A table, not a model, and it fails closed: `.distraction` and `.unknown` suggest nothing at
    /// all rather than the nearest plausible answer. `INTELLIGENCE.md` §6 is explicit that every
    /// decision in this layer is a rule with a constant and a sentence that explains it, and the
    /// sentence for this one is that a category the rules could not name must not become a work type
    /// the record asserts.
    ///
    /// `.management` is deliberately unreachable: no category in `SPEC.md` §5 means "I was managing",
    /// and inferring it from a roster of applications would be the app guessing at a role.
    public static func suggestedWorkType(for category: ActivityCategory) -> WorkType? {
        switch category {
        case .codeReview: .codeReview
        case .communication: .communication
        case .planning: .planning
        case .meeting: .meeting
        case .administrative: .administrative
        // Coding, testing, research and documentation are all deep work as far as this product's
        // vocabulary goes. Four categories collapsing to one work type is honest — the work types
        // are how the user plans, and the categories are how the day reads.
        case .coding, .testing, .research, .documentation: .deepWork
        case .distraction, .unknown: nil
        }
    }

    // MARK: - Overlap

    /// The stretches of `measured` that no session accounts for, in timeline order.
    ///
    /// A running session claims from its start to the end of the block: it has no `endedAt`, this
    /// function has no clock, and the conservative reading is the only one that cannot double-count.
    private static func unclaimed(
        within measured: DateInterval,
        given sessions: [FocusSession]
    ) -> [DateInterval] {
        var free = [measured]

        // Sorted so the result is in timeline order and independent of the order the caller happened
        // to load the day in.
        let busy = sessions
            .map { session -> DateInterval in
                let start = min(session.startedAt, measured.end)
                let end = max(start, session.endedAt ?? measured.end)
                return DateInterval(start: start, end: end)
            }
            .filter { $0.end > measured.start && $0.start < measured.end }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }

        for span in busy {
            free = free.flatMap { subtracting(span, from: $0) }
            if free.isEmpty { break }
        }
        return free
    }

    /// `interval` minus `span`: nothing, one piece, or the two pieces either side of a hole.
    private static func subtracting(
        _ span: DateInterval,
        from interval: DateInterval
    ) -> [DateInterval] {
        guard span.end > interval.start, span.start < interval.end else { return [interval] }

        var remainder: [DateInterval] = []
        if span.start > interval.start {
            remainder.append(DateInterval(start: interval.start, end: span.start))
        }
        if span.end < interval.end {
            remainder.append(DateInterval(start: span.end, end: interval.end))
        }
        return remainder.filter { $0.duration > 0 }
    }
}

// MARK: - Reading it back

extension FocusSession {

    /// Whether this session was declared in advance or labelled from a block Lggr had measured.
    ///
    /// Derived rather than stored, so the flag and the instant it happened at can never disagree —
    /// the arrangement `wasAutoClosed` uses for the same reason.
    public var provenance: SessionProvenance {
        reconstructedAt == nil ? .declared : .reconstructed
    }

    /// This session is a label applied to time Lggr had already measured.
    ///
    /// Read to label the record, never to discount it — the same contract `wasEdited` and
    /// `wasAutoClosed` have. Nothing in Lggr discounts a duration because of where the label came
    /// from; a reconstructed hour is an hour.
    public var wasReconstructed: Bool { reconstructedAt != nil }
}

extension Episode {

    /// Nobody has declared anything over this block, so it is a candidate for a label.
    ///
    /// The cheap half of `SessionFromEpisode.claim(for:)`: it answers the question a timeline row
    /// needs in order to decide whether to offer the gesture at all, without the geometry. A block
    /// this returns `true` for can still be refused — a session may cover it without having lent it
    /// a name — which is why the offer opens a sheet that states the refusal rather than a row that
    /// silently does nothing.
    public var isUnlabelled: Bool { sessionID == nil && activeDuration > 0 }
}

extension DayTimeline {

    /// Blocks nobody has declared anything over, in timeline order.
    ///
    /// Deliberately not a count and deliberately not surfaced as one. `INTELLIGENCE.md` §3.4 removed
    /// the *"3 undeclared blocks"* badge four times over: a number on the default screen that grows
    /// when you fail to comply with the app and falls when you perform triage is a streak counter run
    /// in reverse. This is a list, for a caller that needs the most recent one.
    public var unlabelledEpisodes: [Episode] {
        episodes.filter(\.isUnlabelled)
    }

    /// The latest block nobody has declared anything over.
    ///
    /// What one keystroke from the menu bar acts on. The most recent is the right choice because it
    /// is the one the user still remembers: a label applied to something four hours old is a guess,
    /// and the timeline is where older blocks are labelled with their evidence in front of them.
    public var latestUnlabelledEpisode: Episode? {
        unlabelledEpisodes.max { $0.start < $1.start }
    }
}
