import Foundation

// Correcting a session after the fact.
//
// The everyday case is "I forgot to press stop and it recorded four hours". Until a number like that
// can be fixed, it does not just misreport one session: it teaches the user not to believe the
// weekly review at all. So editing is a first-class domain operation, not a store detail.
//
// Two rules shape everything below.
//
// 1. An edit is *labelled*. `editedAt` is stamped on every applied reschedule, so the weekly review
//    and the session list can tell a hand-entered time from an observed one and say so quietly.
//
// 2. An edit that changes real data *says so before it happens*. `pausedDuration` can be larger than
//    a newly shortened span. Clamping it silently would make active time appear out of nowhere — a
//    45-minute session with 15 minutes paused, shrunk to a 20-minute span, would report 20 minutes of
//    focus where 5 of those minutes had been recorded as a pause. So the reduction is computed,
//    returned, and offerable as a dry run (`rescheduleResult(start:end:)`) that the UI can put in
//    front of the user *before* the mutation is applied.
//
// Neither operation here relaxes anything in `SessionClock`. Durations stay clamped at zero, `endedAt`
// is still never before `startedAt`, and both operations remain total: they leave the session in a
// valid state for every input, including inverted dates and a clock that has moved backwards.

/// What a reschedule would do, or did do — including the parts the user did not ask for.
///
/// Returned by both the dry run and the mutation, so the sheet that warns and the call that saves are
/// reasoning about the same value rather than two implementations of the same arithmetic.
public struct SessionRescheduleResult: Equatable, Sendable {

    /// The start the session had before the edit.
    public let previousStart: Date
    /// The end the session had before the edit, clamped as `wallClockInterval` clamps it.
    public let previousEnd: Date
    /// Paused time the session held before the edit, including a pause left open on the record.
    public let previousPausedDuration: TimeInterval

    /// The start that will be, or has been, written.
    public let start: Date
    /// The end that will be, or has been, written. Never earlier than `start`.
    public let end: Date
    /// The paused time that fits inside the new span. Never negative, never greater than the span.
    public let pausedDuration: TimeInterval

    /// The requested end was before the requested start, so it was pulled up to `start`, exactly as
    /// `finish(at:)` does with a backwards clock. The result is a zero-length session, never a
    /// negative one.
    public let endClampedToStart: Bool

    /// The record carried a pause that was never closed — a session force-quit mid-pause. It was
    /// folded into `previousPausedDuration` at the old end rather than discarded, which is how
    /// `totalPausedDuration(at:)` already reads such a record, and `pauseStartedAt` was cleared.
    public let closedAnOpenPause: Bool

    /// Wall-clock length of the new span, pauses included.
    public var span: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// Active time the session will report once this is applied.
    public var effectiveDuration: TimeInterval { max(0, span - pausedDuration) }

    /// How much recorded pause the new span cannot hold. Zero when the pauses still fit.
    public var pausedDurationReduction: TimeInterval {
        max(0, previousPausedDuration - pausedDuration)
    }

    /// Decision B in one property: the thing the UI must tell the user about before saving.
    public var reducesPausedDuration: Bool { pausedDurationReduction > 0 }

    /// The requested edit is the times the session already has. Applying it still stamps `editedAt`,
    /// because the user did enter these numbers by hand — but nothing else about the session moves,
    /// so a confirmation sheet has nothing to warn about.
    public var changesNothing: Bool {
        previousStart == start && previousEnd == end
            && previousPausedDuration == pausedDuration && !closedAnOpenPause
    }
}

extension FocusSession {

    // MARK: - Provenance

    /// This session's times were corrected by hand at least once.
    ///
    /// Read by the session list and the weekly review to label the number, never to discount it.
    public var wasEdited: Bool { editedAt != nil }

    // MARK: - Rescheduling a finished session

    /// What `reschedule(start:end:at:)` would do, without doing it.
    ///
    /// `nil` for a session that has not finished, for the reason given on `reschedule` itself.
    public func rescheduleResult(start: Date, end: Date) -> SessionRescheduleResult? {
        guard let endedAt else { return nil }

        // A pause left open on a finished record is closed at the old end, which is exactly how
        // `totalPausedDuration(at:)` interprets it. Reading it through that function rather than
        // taking `pausedDuration` raw means the edit starts from the paused total the user has been
        // looking at, not from a smaller one that would silently hand them extra focus time.
        let previousPaused = totalPausedDuration(at: endedAt)
        let previousEnd = max(startedAt, endedAt)

        let clamped = end < start
        let newEnd = max(start, end)
        let span = max(0, newEnd.timeIntervalSince(start))

        return SessionRescheduleResult(
            previousStart: startedAt,
            previousEnd: previousEnd,
            previousPausedDuration: previousPaused,
            start: start,
            end: newEnd,
            pausedDuration: min(previousPaused, span),
            endClampedToStart: clamped,
            closedAnOpenPause: pauseStartedAt != nil
        )
    }

    /// Corrects the times of a session that has already finished, and reports what that cost.
    ///
    /// - Parameters:
    ///   - start: The corrected start.
    ///   - end: The corrected end. Pulled up to `start` if it is earlier, so the session can be
    ///     shortened to nothing but never inverted.
    ///   - at: When the user made this edit. Stored as `editedAt`; injected rather than read from
    ///     `Date()` so the operation stays a pure function of its inputs, like every transition in
    ///     `SessionClock`.
    /// - Returns: What was changed, including any reduction to `pausedDuration`, or `nil` if the
    ///   session has not finished and nothing was touched.
    ///
    /// **On an unfinished session this is a no-op that reports itself, rather than a throw.**
    /// Two reasons for choosing that over refusing loudly. First, it matches the rest of the timing
    /// model: `pause`, `resume` and `finish` are total and idempotent precisely so the UI can fire
    /// them from a shortcut, a menu bar item and a notification action without coordinating, and an
    /// editing sheet left open while a session finishes in the background is the same race. Second,
    /// rescheduling a *running* session is a genuinely different operation — its end is not a stored
    /// value yet, and an open pause is still accumulating — so silently accepting one would have to
    /// invent an `endedAt`, which is how the pause arithmetic gets corrupted. Callers that want to
    /// change a running session's target use `adjustPlannedDuration(to:)`; callers that want to end it
    /// use `finish(at:)` and then edit. The `nil` return means the caller cannot mistake a refusal
    /// for a success, which a silent no-op alone would allow.
    @discardableResult
    public mutating func reschedule(
        start: Date,
        end: Date,
        at date: Date
    ) -> SessionRescheduleResult? {
        guard let result = rescheduleResult(start: start, end: end) else { return nil }

        startedAt = result.start
        endedAt = result.end
        pausedDuration = result.pausedDuration
        // A finished session has no pause in effect. Anything open was folded into
        // `previousPausedDuration` above, so clearing it here drops no recorded time.
        pauseStartedAt = nil
        editedAt = date

        return result
    }

    // MARK: - Adjusting the target

    /// Changes the target duration of a running, paused or finished session.
    ///
    /// Legal in every state, because a target is a statement of intent and revising it invalidates
    /// nothing that was observed. Deliberately it does **not** set `editedAt`: no recorded time moves,
    /// `elapsed` and `effectiveDuration` are untouched, and labelling this as a hand-edited *time*
    /// would spend the badge's meaning on something that is not one.
    ///
    /// - Parameter target: The new target, or `nil` to make the session open-ended so the timer counts
    ///   up with no goal. A negative value clamps to zero rather than being stored, so `overrun` can
    ///   never be inflated past the time actually worked.
    ///
    /// Setting a target already behind the elapsed time is allowed and needs no special case:
    /// `remaining(at:)` floors at zero and `overrun(at:)` starts reporting the difference, which is
    /// the truthful answer to "you meant to spend 25 minutes and you have spent 40".
    public mutating func adjustPlannedDuration(to target: TimeInterval?) {
        guard let target else {
            plannedDuration = nil
            return
        }
        plannedDuration = max(0, target)
    }
}
