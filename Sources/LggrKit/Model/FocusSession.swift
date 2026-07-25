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
    public let startedAt: Date
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
        interruptionCount: Int = 0
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
    }
}
