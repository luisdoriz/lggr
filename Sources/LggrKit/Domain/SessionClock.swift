import Foundation

// The session clock is expressed as pure functions of the stored dates, never as a counter that the
// UI increments. A dropped timer tick, a display sleep, a relaunch mid-session or a machine that
// slept for an hour all resolve to the same number, because the number is recomputed from
// `startedAt`, `endedAt` and the pause bookkeeping every time it is read.
//
// The model in one line:
//
//   elapsed(now) = (endedAt ?? now) − startedAt − pausedDuration − (open pause, if any)
//
// Every subtraction is clamped at zero, so a clock that moves backwards can shorten a duration but
// can never invert one.

extension FocusSession {

    // MARK: - Derived state

    public var state: SessionState {
        guard endedAt != nil else {
            return pauseStartedAt == nil ? .running : .paused
        }
        return resultStatus == nil ? .awaitingReview : .completed
    }

    /// The clock is advancing right now.
    public var isRunning: Bool { endedAt == nil && pauseStartedAt == nil }

    public var isPaused: Bool { endedAt == nil && pauseStartedAt != nil }

    public var isFinished: Bool { endedAt != nil }

    /// No target duration, so the timer counts up instead of down.
    public var isOpenEnded: Bool { plannedDuration == nil }

    // MARK: - Durations

    /// Time spent paused, including a pause that is still open.
    public func totalPausedDuration(at now: Date) -> TimeInterval {
        let closed = max(0, pausedDuration)
        guard let pauseStartedAt else { return closed }
        // A pause left open on a finished session is closed at `endedAt`, so a record that was
        // corrupted or force-quit mid-pause still yields a sane duration rather than one that grows
        // forever.
        let reference = endedAt ?? now
        return closed + max(0, reference.timeIntervalSince(pauseStartedAt))
    }

    /// Active time: wall clock since the session started, minus every pause.
    /// Frozen while paused, constant once finished.
    public func elapsed(at now: Date) -> TimeInterval {
        let end = endedAt ?? now
        let span = max(0, end.timeIntervalSince(startedAt))
        return max(0, span - totalPausedDuration(at: now))
    }

    /// Time left against the plan, floored at zero. `nil` for open-ended sessions.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let plannedDuration else { return nil }
        return max(0, plannedDuration - elapsed(at: now))
    }

    /// Seconds run past the plan. Zero when on time or open-ended.
    public func overrun(at now: Date) -> TimeInterval {
        guard let plannedDuration else { return 0 }
        return max(0, elapsed(at: now) - plannedDuration)
    }

    /// Fraction of the plan completed, clamped to 0...1. `nil` when open-ended.
    public func progress(at now: Date) -> Double? {
        guard let plannedDuration, plannedDuration > 0 else { return nil }
        return min(1, max(0, elapsed(at: now) / plannedDuration))
    }

    /// Active duration of a session that has finished.
    ///
    /// Returns `nil` while the session is still running, which is what makes every daily and weekly
    /// total deterministic: an aggregate can only be built from sessions whose duration has stopped
    /// changing. Live UI uses `elapsed(at:)` instead.
    public var effectiveDuration: TimeInterval? {
        guard let endedAt else { return nil }
        return elapsed(at: endedAt)
    }

    /// Wall-clock span including pauses, used to place the block on the day timeline.
    public var wallClockInterval: DateInterval? {
        guard let endedAt else { return nil }
        return DateInterval(start: startedAt, end: max(startedAt, endedAt))
    }

    // MARK: - Transitions

    // All four transitions are total and idempotent: calling them in the wrong order, twice, or with
    // a date that has moved backwards leaves the session in a valid state rather than throwing or
    // corrupting the arithmetic. The UI can therefore fire them from a keyboard shortcut, a menu bar
    // item and a notification action without coordinating.

    /// No-op if already paused or already finished.
    public mutating func pause(at date: Date) {
        guard endedAt == nil, pauseStartedAt == nil else { return }
        pauseStartedAt = max(date, startedAt)
    }

    /// Closes the open pause and folds its length into `pausedDuration`.
    /// No-op if not paused or already finished. A backwards clock contributes zero.
    public mutating func resume(at date: Date) {
        guard endedAt == nil, let openedAt = pauseStartedAt else { return }
        pausedDuration = max(0, pausedDuration) + max(0, date.timeIntervalSince(openedAt))
        pauseStartedAt = nil
    }

    /// Closes any open pause, then ends the session. No-op if already finished.
    public mutating func finish(at date: Date, status: SessionResultStatus? = nil) {
        guard endedAt == nil else { return }
        resume(at: date)
        endedAt = max(date, startedAt)
        if let status { resultStatus = status }
    }

    /// Bound to the Space key on the active session.
    public mutating func togglePause(at date: Date) {
        if isPaused {
            resume(at: date)
        } else {
            pause(at: date)
        }
    }
}
