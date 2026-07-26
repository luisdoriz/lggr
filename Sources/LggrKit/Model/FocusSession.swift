import Foundation

/// What happened during a session, answered on the completion sheet.
public enum SessionResultStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case completed
    case madeProgress
    case blocked
    case interrupted
    case reprioritized

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .completed: "Completed"
        case .madeProgress: "Made progress"
        case .blocked: "Blocked"
        case .interrupted: "Interrupted"
        case .reprioritized: "Reprioritized"
        }
    }

    public var symbolName: String {
        switch self {
        case .completed: "checkmark.circle"
        case .madeProgress: "arrow.forward.circle"
        case .blocked: "hand.raised"
        case .interrupted: "bell.badge"
        case .reprioritized: "arrow.triangle.branch"
        }
    }

    /// Counts toward "focus sessions completed" in the weekly review.
    public var countsAsCompleted: Bool { self == .completed }

    /// Counts toward "sessions interrupted" in the weekly review.
    public var countsAsInterrupted: Bool { self == .interrupted }

    /// The intended outcome did not land, so a follow-up is worth offering. This never changes how
    /// the result is coloured or worded — a blocked session is information, not a failure.
    public var needsFollowUp: Bool {
        self == .blocked || self == .interrupted || self == .reprioritized
    }
}

/// Where a session is in its lifecycle. Derived, never stored.
public enum SessionState: String, Sendable, Hashable {
    case running
    case paused
    /// Finished, but "What happened?" has not been answered yet.
    case awaitingReview
    case completed
}

/// One deliberate block of work: what you meant to do, when you did it, and how it went.
///
/// Relationships to other records are held as `UUID`s rather than as nested objects. The store is a
/// flat set of collections, so a session can be decoded, compared and diffed without dragging a
/// whole object graph along, and a deleted project cannot take its history with it.
public struct FocusSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var weeklyOutcomeID: UUID?
    /// Required. The one sentence describing what this session is for.
    public var intendedOutcome: String
    public var workType: WorkType
    /// `nil` means open-ended: the timer counts up with no target.
    public var plannedDuration: TimeInterval?
    /// `var` rather than `let` only so that `reschedule(start:end:at:)` can correct a mistyped or
    /// forgotten stop time. Nothing else in the package writes it: every transition in
    /// `SessionClock` still treats it as the fixed origin of the clock and clamps against it.
    public var startedAt: Date
    public var endedAt: Date?
    /// Sum of every pause that has been closed. Never negative.
    public var pausedDuration: TimeInterval
    /// When the pause currently in effect began, or `nil` while running.
    ///
    /// This field is not in the original spec's list, and it is not optional in practice:
    /// `pausedDuration` alone can only describe pauses that already ended, so without it a paused
    /// session's clock would keep advancing until the user pressed resume.
    public var pauseStartedAt: Date?
    /// `nil` until the completion sheet is answered.
    public var resultStatus: SessionResultStatus?
    /// The narrative of what happened, generated and then editable.
    public var resultSummary: String?
    /// The thing that now exists because of this session — a merged PR, a written document, a
    /// decision. Distinct from `resultSummary`, which describes how the time was spent: this is the
    /// artefact, and it is what the weekly review can point at as evidence.
    public var tangibleResult: String?
    public var blocker: String?
    public var nextStep: String?
    /// Work that arrived rather than work that was chosen. Seeded from `workType`, user-overridable.
    public var isReactive: Bool
    /// Interruptions captured during this session. Denormalised so a session row can be rendered
    /// without querying the interruption store.
    public var interruptionCount: Int
    /// When the user last corrected this session's times by hand, or `nil` if every timestamp on it
    /// was observed.
    ///
    /// Provenance, not an error flag. Lggr's claim is that it is trustworthy evidence of your day,
    /// which means a hand-entered number must never be presented as an observed one — the same
    /// honesty the timeline already applies to gaps it cannot explain. The weekly review and the
    /// session list read this to say so quietly; nothing reads it as a warning, and no total is
    /// discounted because of it.
    ///
    /// Set by `reschedule(start:end:at:)` only. Changing `plannedDuration` does not set it: a target
    /// is intent, not evidence, and adjusting it leaves every recorded time exactly as observed.
    public var editedAt: Date?

    /// When Lggr closed this session itself, or `nil` when its end was pressed, hand-entered, or
    /// still to come.
    ///
    /// The sibling of `editedAt`, and deliberately not the same field. `editedAt` says *the user
    /// typed this number*; this says *the app chose this number, and can name the witness it chose
    /// it from*. Conflating them would have the app claim the user's authorship for its own
    /// arithmetic — and an app-adjusted time presented as an observed one is the confidently wrong
    /// record the whole design is arranged to avoid. `SessionAutoClose.applyAutoClose` carries the
    /// full reasoning.
    ///
    /// Set by `applyAutoClose(_:at:)` only. A session can carry this *and* `editedAt`: the app
    /// closed it at the last heartbeat and the user then corrected that, which is two facts and
    /// reads correctly as two.
    public var autoClosedAt: Date?

    /// Which witness `autoClosedAt`'s end came from. `nil` whenever `autoClosedAt` is.
    ///
    /// Stored rather than recomputed, because the evidence it was derived from — an idle reading, a
    /// heartbeat file — is gone by the time anybody reads the session back, and "ended at 12:04"
    /// with no reason attached is a number the user cannot check.
    public var autoCloseReason: SessionAutoCloseReason?

    /// When the user labelled a block Lggr had already measured, or `nil` for a session they
    /// declared before doing the work.
    ///
    /// The third provenance field, and the one that changes an aggregate rather than a caption.
    /// `editedAt` says *the user typed this number*; `autoClosedAt` says *the app chose this number*;
    /// this says *the times were measured and the label came afterwards*. Read `provenance` rather
    /// than this, and `SessionFromEpisode` for the full reasoning — the short version is that work
    /// somebody labelled at four o'clock is not the same evidence as work they committed to at nine,
    /// and `PlannedVsReactive` must never conflate them.
    ///
    /// An instant rather than a flag, for the reason `autoClosedAt` is one: *when* the label was
    /// applied is the difference between labelling this morning's block this afternoon and labelling
    /// it next Thursday. Set by `SessionFromEpisode.session(for:label:existingSessions:at:)` only,
    /// and nothing clears it — a reconstruction is marked forever, per `INTELLIGENCE.md` §4 Phase 2.
    /// A session can carry this *and* `editedAt`: the block was labelled and its times were then
    /// corrected, which is two facts and reads correctly as two.
    public var reconstructedAt: Date?

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        weeklyOutcomeID: UUID? = nil,
        intendedOutcome: String,
        workType: WorkType = .deepWork,
        plannedDuration: TimeInterval? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        pausedDuration: TimeInterval = 0,
        pauseStartedAt: Date? = nil,
        resultStatus: SessionResultStatus? = nil,
        resultSummary: String? = nil,
        tangibleResult: String? = nil,
        blocker: String? = nil,
        nextStep: String? = nil,
        isReactive: Bool? = nil,
        interruptionCount: Int = 0,
        editedAt: Date? = nil,
        autoClosedAt: Date? = nil,
        autoCloseReason: SessionAutoCloseReason? = nil,
        reconstructedAt: Date? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.weeklyOutcomeID = weeklyOutcomeID
        self.intendedOutcome = intendedOutcome
        self.workType = workType
        self.plannedDuration = plannedDuration
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedDuration = max(0, pausedDuration)
        self.pauseStartedAt = pauseStartedAt
        self.resultStatus = resultStatus
        self.resultSummary = resultSummary
        self.tangibleResult = tangibleResult
        self.blocker = blocker
        self.nextStep = nextStep
        self.isReactive = isReactive ?? workType.isReactiveByDefault
        self.interruptionCount = max(0, interruptionCount)
        self.editedAt = editedAt
        self.autoClosedAt = autoClosedAt
        // A reason with no instant beside it would be a claim with no provenance, and an instant
        // with no reason would be a number nobody can check. Neither half stands alone.
        self.autoCloseReason = autoClosedAt == nil ? nil : autoCloseReason
        self.reconstructedAt = reconstructedAt
    }
}
