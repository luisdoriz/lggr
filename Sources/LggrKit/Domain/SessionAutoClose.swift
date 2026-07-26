import Foundation

// Closing a session the user forgot to close.
//
// This is the one defect in Lggr that writes wrong data rather than merely failing to write right
// data. A session left running through lunch, overnight, or across a quit does not simply go
// unreviewed: it records four hours of focus that nobody spent, and that number reaches the daily
// total, the weekly review, and the Markdown a manager reads. `SessionEditing` exists because of it
// and says so in its own first paragraph — but an edit is a repair the user has to notice and
// perform, and a tracker that needs the user to notice is the tracker this project is arguing
// against.
//
// So the correction is automatic, and it is arranged around one rule:
//
//   **Close the session at the last real activity, never at "now".**
//
// A session left running through lunch must record the work, not the lunch. Every case below is a
// different answer to "what was the last thing anybody witnessed", and the decision is always that
// instant — the app's job is to pick the right witness, not to pick a time.
//
// Three properties make this safe enough to run without asking.
//
// 1. **It only ever shortens.** No branch here can move an end later, so no branch can invent time.
//    `Decision.closeAt` is clamped into `startedAt...now`, and a decision that would change nothing
//    is not returned at all.
// 2. **It refuses to contradict the user.** A deliberately paused session is never auto-closed.
//    Pausing is the user saying "I am coming back", and an app that overrides an explicit
//    instruction has stopped being evidence and started being an opinion.
// 3. **It is provenance-stamped, never silent.** Applying a decision sets `autoClosedAt` and
//    `autoCloseReason`, so the number on screen can say where it came from. An app-adjusted time
//    presented as an observed one would be exactly the confidently-wrong record that
//    `INTELLIGENCE.md` §1 is organised around avoiding.
//
// Pure, static, no clock and no I/O — the same shape as `EpisodeBuilder` and for the same reason:
// every case below can be proved against a fixture on a machine with no Xcode, no permissions and
// no running app.

/// Why a session's end was set by the app rather than by the user.
///
/// Stored on the session, so the reason survives into next week's review rather than living only in
/// the notification that announced it.
///
/// Every case names a **witness** — something the app observed — because that is what makes the
/// resulting end defensible. Facts about the record, never about the person: no case here has the
/// user as its subject, and none of them says "you forgot".
public enum SessionAutoCloseReason: String, Codable, CaseIterable, Sendable, Hashable {

    /// Input stopped reaching the machine long enough that the session cannot be said to have
    /// continued. Closed at the last input Lggr saw.
    case idle

    /// The machine slept while the session was running. Closed at the instant it went to sleep.
    case machineAsleep

    /// Lggr was not running — a quit, a crash, a lost power cord. Closed at the last heartbeat,
    /// which is the same instant the timeline's `.appNotRunning` gap begins, so the two records
    /// agree instead of each inventing an answer.
    case appNotRunning

    /// The session was still open when the day it started in ended. Closed at that boundary: a
    /// session that spans two days is a fiction in every screen that groups by day.
    case dayBoundary

    /// What the app witnessed, as a phrase that completes "Ended at 12:04, …".
    ///
    /// One clause, no adjectives, and nothing that reads as a verdict.
    public var recordNote: String {
        switch self {
        case .idle: "the last input Lggr recorded"
        case .machineAsleep: "when the machine went to sleep"
        case .appNotRunning: "the last minute Lggr was running"
        case .dayBoundary: "the end of the day it started in"
        }
    }

    /// A short label for a badge beside a corrected time.
    public var displayName: String {
        switch self {
        case .idle: "Ended at last input"
        case .machineAsleep: "Ended at sleep"
        case .appNotRunning: "Ended at last heartbeat"
        case .dayBoundary: "Ended at end of day"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: "pause.circle"
        case .machineAsleep: "moon.zzz"
        case .appNotRunning: "bolt.slash"
        case .dayBoundary: "calendar"
        }
    }
}

/// Whether a running session should be closed, and at what instant.
///
/// A pure decision function. It reads no clock, touches no disk, and returns a value describing
/// *what* and *why* — so the caller can persist the change, the session list can label it, and a
/// notification can say "ended at 12:04, the last input Lggr recorded" rather than silently moving
/// a number the user is going to be asked to trust.
public enum SessionAutoClose {

    // MARK: - Policy

    /// The two constants, in one place, with their reasoning attached.
    ///
    /// Not exposed in the UI, for the reason `SegmentationWeights` is not: a user who has to tune
    /// the threshold at which their forgotten session is repaired has been handed our problem. They
    /// already set an idle threshold, and this is derived from it.
    public struct Policy: Equatable, Sendable {

        /// How many idle thresholds must pass before the session is closed rather than annotated.
        ///
        /// Greater than one on purpose. The idle threshold's job is to mark a stretch of the
        /// timeline as idle, which is reversible and costs nothing if it is wrong. Closing a session
        /// is neither, so it waits for evidence that the first reading was not a phone call the user
        /// took at their desk. Two thresholds, and never less than `minimumIdle`.
        public var idleFactor: Double

        /// The floor under `idleFactor`, whatever the threshold is set to.
        ///
        /// A user with a 60-second idle threshold has asked for a finely grained timeline; they have
        /// not asked for their session to end because they read a page for three minutes. Fifteen
        /// minutes is long enough that "the session is still running" has stopped being true and
        /// short enough that the recovered work is still recognisable.
        public var minimumIdle: TimeInterval

        public init(idleFactor: Double = 2, minimumIdle: TimeInterval = 15 * 60) {
            self.idleFactor = max(1, idleFactor.isFinite ? idleFactor : 1)
            self.minimumIdle = max(0, minimumIdle.isFinite ? minimumIdle : 0)
        }

        public static let `default` = Policy()

        /// How long input may be absent before a running session is closed.
        public func idleAllowance(for threshold: TimeInterval) -> TimeInterval {
            let sane = threshold.isFinite ? max(0, threshold) : 0
            return max(minimumIdle, sane * idleFactor)
        }
    }

    // MARK: - Absence

    /// A stretch the app could not witness at all, and the last instant before it that it could.
    ///
    /// Supplying one **is** the assertion that the absence happened: this type does not re-derive it
    /// from a heartbeat, because `ActivityLaunchRecovery` already computes that instant for the
    /// timeline and two independent answers to "when did Lggr stop being alive" is how a session's
    /// end and the gap beside it end up disagreeing by a minute. Hand over the answer the timeline
    /// is using.
    public struct Absence: Equatable, Sendable {

        /// Which absence it was. Only these two, because only these two have a witness to name.
        public enum Kind: Equatable, Sendable {
            /// The machine slept. `NSWorkspace.willSleepNotification`, or an unclosed
            /// `.systemSleep` gap found at launch.
            case machineAsleep
            /// Lggr was not running. `ActivityLaunchRecovery.Outcome.closeOpenIntervalsAt`.
            case appNotRunning

            public var reason: SessionAutoCloseReason {
                switch self {
                case .machineAsleep: .machineAsleep
                case .appNotRunning: .appNotRunning
                }
            }
        }

        /// The last instant the app is known to have been running — the last heartbeat, or the
        /// instant sleep was announced.
        public var lastWitnessedAt: Date
        public var kind: Kind

        public init(lastWitnessedAt: Date, kind: Kind) {
            self.lastWitnessedAt = lastWitnessedAt
            self.kind = kind
        }
    }

    // MARK: - Input

    /// Everything the decision is made from. No clock, so `now` is a parameter like every other.
    public struct Input: Equatable, Sendable {

        /// The session in flight. A finished or paused one produces no decision; see `decide(_:)`.
        public var session: FocusSession

        /// The last instant human input reached this machine, or `nil` when nothing is known.
        ///
        /// `nil` is not "no input" — it is "no reading", and it produces no idle decision at all.
        /// A missing signal must never be the reason a session ends.
        public var lastInputAt: Date?

        /// A stretch nobody witnessed, if the caller observed one. See `Absence`.
        public var absence: Absence?

        /// The end of the calendar day the session started in, exclusive.
        ///
        /// Passed in rather than computed here because a day is 23 hours twice a year and the
        /// calendar that knows it belongs to the caller (`CalendarWindows`). `nil` skips the rule.
        public var endOfDay: Date?

        /// The user's own idle threshold, in seconds. The policy derives its allowance from it.
        public var idleThreshold: TimeInterval

        /// The instant the decision is being made.
        public var now: Date

        public var policy: Policy

        public init(
            session: FocusSession,
            lastInputAt: Date? = nil,
            absence: Absence? = nil,
            endOfDay: Date? = nil,
            idleThreshold: TimeInterval = 3 * 60,
            now: Date,
            policy: Policy = .default
        ) {
            self.session = session
            self.lastInputAt = lastInputAt
            self.absence = absence
            self.endOfDay = endOfDay
            self.idleThreshold = idleThreshold
            self.now = now
            self.policy = policy
        }
    }

    // MARK: - Decision

    /// What to do, why, and what it costs — so nothing about the change has to be inferred later.
    public struct Decision: Equatable, Sendable {

        /// The instant the session should end. Always within `startedAt...now`.
        public var closeAt: Date
        public var reason: SessionAutoCloseReason

        /// Wall-clock time between `closeAt` and `now`: the span that would have been recorded had
        /// the session been closed at the moment this was noticed instead.
        ///
        /// This is the number worth stating, because it is the size of the error being avoided. It
        /// is a *wall-clock* span, deliberately: an open pause is impossible on a running session,
        /// so the two are the same here, and stating the simpler one keeps the sentence checkable.
        public var uncountedDuration: TimeInterval

        public init(closeAt: Date, reason: SessionAutoCloseReason, uncountedDuration: TimeInterval) {
            self.closeAt = closeAt
            self.reason = reason
            self.uncountedDuration = max(0, uncountedDuration)
        }

        /// "Ended at 12:04, the last input Lggr recorded."
        ///
        /// The time itself is formatted by the caller: `LggrKit` has no locale opinion, and every
        /// screen in the app already prints times its own way. Assembling the sentence here is what
        /// keeps the notification, the session row and the review sheet from wording the same fact
        /// three ways.
        public func sentence(closedAtText: String) -> String {
            "Ended at \(closedAtText), \(reason.recordNote)."
        }
    }

    // MARK: - The decision

    /// Whether this session should be closed, and where.
    ///
    /// - Returns: `nil` when the session should be left exactly as it is — which is the answer for
    ///   the ordinary case of somebody working, and for every case where the app would be guessing.
    ///
    /// ## The order of the tests, and why it is not the order of the rules
    ///
    /// Two of the three rules can fire at once — a session left running overnight is both idle and
    /// past the end of its day — so the rules are evaluated as *candidates* and the *earliest* one
    /// wins. That is the only ordering that keeps the promise at the top of this file: the last
    /// thing anybody witnessed is the earliest of the answers, and picking any other would record
    /// time between the true end and the chosen one.
    ///
    /// A worked example, because it is the case that motivated the shape. A session starts at 22:00,
    /// the user stops at 23:10, and the app is asked at 09:00 the next morning. The day-boundary
    /// rule says midnight; the idle rule says 23:10. Midnight would record fifty minutes of a night
    /// nobody was awake for. 23:10 wins, and the reason reported is `.idle`, which is the one the
    /// user can check against their own memory.
    public static func decide(_ input: Input) -> Decision? {
        let session = input.session

        // A finished session has nothing to close. Idempotent rather than a precondition, because
        // this is called from a tick, from a wake and from a launch, and two of those can race.
        guard session.endedAt == nil else { return nil }

        // **A deliberately paused session is never auto-closed.** The user said they are coming
        // back; the app does not get a vote. This is checked before every other rule so that no
        // later branch can be tempted to make an exception for one.
        guard session.pauseStartedAt == nil else { return nil }

        // A clock that has moved backwards is not a reason to end anything.
        guard input.now > session.startedAt else { return nil }

        var candidates: [Decision] = []

        // Rule 1 — input stopped, and stayed stopped.
        if let lastInputAt = input.lastInputAt {
            let allowance = input.policy.idleAllowance(for: input.idleThreshold)
            let silence = input.now.timeIntervalSince(lastInputAt)
            if silence >= allowance {
                candidates.append(make(closeAt: lastInputAt, reason: .idle, input: input))
            }
        }

        // Rule 2 — a stretch nobody witnessed. The caller has already established that it happened
        // and hands over the instant the timeline is using for it.
        if let absence = input.absence, absence.lastWitnessedAt < input.now {
            candidates.append(
                make(closeAt: absence.lastWitnessedAt, reason: absence.kind.reason, input: input)
            )
        }

        // Rule 3 — the day the session started in has ended.
        if let endOfDay = input.endOfDay, input.now >= endOfDay, endOfDay > session.startedAt {
            candidates.append(make(closeAt: endOfDay, reason: .dayBoundary, input: input))
        }

        // The earliest witness wins. On an exact tie the first candidate holds, which orders
        // observed evidence (idle, then absence) ahead of the derived boundary — the reason a user
        // can check against their own memory, rather than the one that is merely true.
        guard let decision = candidates.min(by: { $0.closeAt < $1.closeAt }) else { return nil }

        // A decision that moves nothing is not a decision. Returning one would stamp provenance on
        // a session whose times were never adjusted, which is the same lie in the other direction.
        guard decision.closeAt < input.now else { return nil }

        return decision
    }

    /// Clamps a candidate into the only range that cannot invent time.
    ///
    /// A witness earlier than the session's own start means the session records nothing at all —
    /// which is the honest outcome for a session started and then abandoned, and is still better
    /// than the hours the alternative writes.
    private static func make(
        closeAt: Date,
        reason: SessionAutoCloseReason,
        input: Input
    ) -> Decision {
        let clamped = min(max(closeAt, input.session.startedAt), input.now)
        return Decision(
            closeAt: clamped,
            reason: reason,
            uncountedDuration: input.now.timeIntervalSince(clamped)
        )
    }
}

// MARK: - Applying it

extension FocusSession {

    /// This session's end was set by the app rather than observed running out or pressed by hand.
    ///
    /// Read to label the number, never to discount it — the same contract `wasEdited` has.
    public var wasAutoClosed: Bool { autoClosedAt != nil }

    /// Ends the session at the decided instant and records that the app is the one who decided.
    ///
    /// ## Why this is a sibling of `editedAt` and not `editedAt` itself
    ///
    /// `editedAt` means one specific thing, and its own documentation is what settles this: *"When
    /// the user last corrected this session's times by hand."* The session list and the weekly
    /// review read it to say a number was hand-entered. An automatic close is the opposite
    /// provenance — nobody typed it, and the app owes the user an explanation for it rather than an
    /// acknowledgement that they typed one. Folding the two together would make the app claim the
    /// user's authorship for its own arithmetic, and would leave "did you type this, or did we?"
    /// unanswerable at exactly the moment somebody is deciding whether to believe the number.
    ///
    /// So: two fields, one concept. `wasEdited` still answers "by hand"; `wasAutoClosed` answers
    /// "by Lggr, and here is which witness". A session can carry both, and the pair reads correctly
    /// when it does: the app closed it at the last heartbeat and then the user corrected that.
    ///
    /// - Parameters:
    ///   - decision: what `SessionAutoClose.decide(_:)` returned for this session.
    ///   - instant: when the app made the adjustment. Stored as `autoClosedAt`, injected rather
    ///     than read from `Date()` so this stays a pure function of its inputs like every other
    ///     transition in `SessionClock`.
    /// - Returns: `false` when the session had already finished and nothing was touched, so a
    ///   caller cannot mistake a no-op for a close.
    @discardableResult
    public mutating func applyAutoClose(
        _ decision: SessionAutoClose.Decision,
        at instant: Date
    ) -> Bool {
        guard endedAt == nil else { return false }

        // `finish(at:)` rather than assigning `endedAt`: it is the one place that knows to close an
        // open pause and to clamp against `startedAt`, and reimplementing either here is how the
        // pause arithmetic gets corrupted. It is total and idempotent, so the guard above is about
        // the return value, not about safety.
        finish(at: decision.closeAt)

        autoClosedAt = instant
        autoCloseReason = decision.reason
        return true
    }
}
