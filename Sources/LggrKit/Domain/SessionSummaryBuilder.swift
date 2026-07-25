import Foundation

/// Writes the suggested summary the completion sheet pre-fills.
///
/// The suggestion is always editable, so its job is to save typing, not to have an opinion. It is
/// therefore deterministic, factual and flat in tone: it states what was worked on, for how long,
/// and how the session was reported. It never congratulates, never grades, and never exclaims — a
/// blocked session reads exactly as calmly as a completed one.
///
/// Phase 2 has no activity tracking, so the only evidence available is what the session itself
/// knows. Phase 3 adds application and category evidence by appending further parameters with
/// defaults, which leaves every existing call site compiling unchanged.
public enum SessionSummaryBuilder {

    /// One or two sentences describing a finished session.
    ///
    /// - Parameters:
    ///   - intendedOutcome: What the user said the session was for, inserted as written.
    ///   - projectName: Resolved by the caller; `nil` for a session filed under no project.
    ///   - activeDuration: Time actually worked, excluding pauses.
    ///   - pauseCount: How many pause cycles the session went through.
    ///   - pausedDuration: Total time spent paused.
    ///   - resultStatus: The answer to "What happened?", or `nil` if it has not been given yet.
    public static func summary(
        intendedOutcome: String,
        projectName: String?,
        workType: WorkType,
        activeDuration: TimeInterval,
        pauseCount: Int = 0,
        pausedDuration: TimeInterval = 0,
        resultStatus: SessionResultStatus? = nil
    ) -> String {
        var sentences = [
            contextSentence(
                projectName: projectName,
                workType: workType,
                activeDuration: activeDuration,
                pauseCount: pauseCount,
                pausedDuration: pausedDuration
            )
        ]
        if let outcomeSentence = outcomeSentence(
            intendedOutcome: intendedOutcome,
            resultStatus: resultStatus
        ) {
            sentences.append(outcomeSentence)
        }
        return sentences.joined(separator: " ")
    }

    /// Convenience over a whole session. `pauseCount` is passed in because a `FocusSession` stores
    /// how long it was paused but not how many times.
    public static func summary(
        for session: FocusSession,
        projectName: String?,
        pauseCount: Int = 0,
        at now: Date
    ) -> String {
        summary(
            intendedOutcome: session.intendedOutcome,
            projectName: projectName,
            workType: session.workType,
            activeDuration: session.effectiveDuration ?? session.elapsed(at: now),
            pauseCount: pauseCount,
            pausedDuration: session.totalPausedDuration(at: now),
            resultStatus: session.resultStatus
        )
    }

    // MARK: - Sentences

    private static func contextSentence(
        projectName: String?,
        workType: WorkType,
        activeDuration: TimeInterval,
        pauseCount: Int,
        pausedDuration: TimeInterval
    ) -> String {
        var sentence = workType.displayName
        if let project = trimmed(projectName) {
            sentence += " on \(project)"
        }
        sentence += " for \(durationPhrase(activeDuration))"

        if pauseCount > 0 {
            sentence += ", paused \(pauseCountPhrase(pauseCount))"
            if wholeMinutes(pausedDuration) >= 1 {
                sentence += " for \(durationPhrase(pausedDuration))"
            }
        }
        return sentence + "."
    }

    /// `nil` when there is nothing to say: no outcome text and no result to report.
    private static func outcomeSentence(
        intendedOutcome: String,
        resultStatus: SessionResultStatus?
    ) -> String? {
        guard let text = trimmed(intendedOutcome) else {
            guard let resultStatus else { return nil }
            return "\(resultStatus.displayName)."
        }
        let outcome = strippingTrailingPeriod(text)

        switch resultStatus {
        case .completed: return "Completed \(outcome)."
        case .madeProgress: return "Made progress on \(outcome)."
        case .blocked: return "Blocked on \(outcome)."
        case .interrupted: return "Interrupted while working on \(outcome)."
        case .reprioritized: return "Set \(outcome) aside for other work."
        case nil: return "Worked on \(outcome)."
        }
    }

    // MARK: - Phrasing

    /// Durations are written out in words rather than as a clock, because the summary is prose. No
    /// formatter is involved, so the output cannot drift with the user's locale between runs.
    private static func durationPhrase(_ duration: TimeInterval) -> String {
        let totalMinutes = wholeMinutes(duration)
        guard totalMinutes >= 1 else { return "under a minute" }
        guard totalMinutes >= 60 else { return pluralized(totalMinutes, "minute") }

        let hours = pluralized(totalMinutes / 60, "hour")
        let remainder = totalMinutes % 60
        guard remainder > 0 else { return hours }
        return "\(hours) \(pluralized(remainder, "minute"))"
    }

    private static func pauseCountPhrase(_ count: Int) -> String {
        switch count {
        case 1: "once"
        case 2: "twice"
        default: "\(count) times"
        }
    }

    private static func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func wholeMinutes(_ duration: TimeInterval) -> Int {
        // `Int(_: Double)` is a trapping conversion: it precondition-fails on NaN, on infinity, and
        // on anything outside Int's range. Dates are stored as plain seconds, so a corrupted or
        // hand-edited `startedAt` can hand this an absurd interval — and this runs while restoring a
        // session at launch, which would turn a bad file into a crash on every start with no way out
        // but deleting it. A wrong sentence is always preferable to a trap.
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int((min(duration, TimeInterval(Int32.max)) / 60).rounded())
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    /// The outcome becomes part of a longer sentence, so a period the user typed at the end of it
    /// would land mid-sentence.
    private static func strippingTrailingPeriod(_ text: String) -> String {
        var result = text
        while result.hasSuffix(".") {
            result.removeLast()
        }
        return result.isEmpty ? text : result
    }
}
