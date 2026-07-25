import Foundation

/// How much of the week an outcome is entitled to.
///
/// Three levels, not a number. A rank would invite reordering a list of fifteen; three levels make
/// the shape of the week visible at a glance and make a fourth "important" item obviously homeless.
public enum OutcomePriority: String, Codable, CaseIterable, Sendable, Identifiable, Comparable {
    /// The one thing the week is for. At most one.
    case primary
    /// Worth naming, but not what the week is about. At most two.
    case secondary
    /// Recurring responsibility rather than an outcome: on-call, review load, one-to-ones.
    case operational

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: "Primary"
        case .secondary: "Secondary"
        case .operational: "Operational"
        }
    }

    private var rank: Int {
        switch self {
        case .primary: 0
        case .secondary: 1
        case .operational: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Where an outcome ended up.
///
/// There is no "failed". An outcome that did not land was blocked, carried over, or dropped — three
/// different things that a single failure state would flatten into a verdict.
public enum OutcomeStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case notStarted
    case inProgress
    case blocked
    case achieved
    /// Still wanted, moving to next week.
    case carriedOver
    /// Deliberately let go. §10 treats deprioritising work as an accomplishment, and so does this.
    case dropped

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .blocked: "Blocked"
        case .achieved: "Achieved"
        case .carriedOver: "Carried over"
        case .dropped: "Dropped"
        }
    }

    public var symbolName: String {
        switch self {
        case .notStarted: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "hand.raised"
        case .achieved: "checkmark.circle"
        case .carriedOver: "arrow.uturn.forward"
        case .dropped: "arrow.down.circle"
        }
    }

    /// Still live at the end of the week.
    public var isOpen: Bool {
        switch self {
        case .notStarted, .inProgress, .blocked: true
        case .achieved, .carriedOver, .dropped: false
        }
    }
}

/// One thing the week is supposed to produce.
///
/// Links point the other way: a `FocusSession` and an `Accomplishment` each carry a
/// `weeklyOutcomeID`, so an outcome can be deleted without orphaning the record of work already
/// done, and the weekly review resolves the relationship by scanning the week it already loaded.
/// `projectIDs` is the one exception, because a project has no reason to know about a week.
public struct WeeklyOutcome: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var details: String?
    public var priority: OutcomePriority
    public var status: OutcomeStatus
    /// Self-reported, 0…1. Clamped at construction, so no caller has to defend against a stored 1.4.
    public var progress: Double
    /// Midnight at the start of the week this outcome belongs to, in the user's calendar.
    public var weekStartDate: Date
    public var projectIDs: [UUID]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        details: String? = nil,
        priority: OutcomePriority = .secondary,
        status: OutcomeStatus = .notStarted,
        progress: Double = 0,
        weekStartDate: Date,
        projectIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priority = priority
        self.status = status
        self.progress = WeeklyOutcome.clampedProgress(progress)
        self.weekStartDate = weekStartDate
        self.projectIDs = projectIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// A stored `NaN` would otherwise propagate through every percentage in the review and render as
    /// "nan%", so it resolves to zero rather than to a comparison that is false in both directions.
    static func clampedProgress(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

extension WeeklyOutcome {

    public var normalizedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var isPrimary: Bool { priority == .primary }

    /// Progress as the review renders it: whole percent.
    public var progressPercent: Int { Int((progress * 100).rounded()) }
}

/// A week's outcomes in the shape §8 describes: one primary, at most two secondary, and however many
/// operational responsibilities there are.
///
/// The cap is a property of this type rather than a rule the UI is asked to remember, because the
/// spec's instruction — *avoid encouraging the user to create a large task list* — is not something a
/// disabled button enforces once outcomes can also arrive from an import, a carry-over from last
/// week, or a second window.
///
/// Nothing is ever discarded to make the shape fit. Outcomes that do not have a seat are surfaced in
/// `unseated`, so the answer to "where did my fourth outcome go" is visible rather than silent.
public struct WeeklyOutcomeSet: Hashable, Sendable {

    public static let secondaryCapacity = 2

    public let weekStart: Date
    public let primary: WeeklyOutcome?
    /// At most `secondaryCapacity`, in declaration order.
    public let secondary: [WeeklyOutcome]
    /// Uncapped: operational load is observed, not chosen, and hiding some of it would understate
    /// the week rather than simplify it.
    public let operational: [WeeklyOutcome]
    /// Declared outcomes the shape has no room for. Never dropped.
    public let unseated: [WeeklyOutcome]

    /// Seats `outcomes` into the shape.
    ///
    /// Candidates are ordered by `createdAt`, ties broken by `id`, so the same set always seats the
    /// same way regardless of what order it came out of the store. The first outcome declared primary
    /// takes the primary seat; any further primaries compete with the secondaries for the two
    /// secondary seats rather than being thrown away, because a second outcome someone called primary
    /// is real work whatever the shape says.
    public init(weekStart: Date, outcomes: [WeeklyOutcome] = []) {
        self.weekStart = weekStart

        let ordered = outcomes.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.createdAt < rhs.createdAt
        }

        var seatedPrimary: WeeklyOutcome?
        var contenders: [WeeklyOutcome] = []
        var operational: [WeeklyOutcome] = []

        for outcome in ordered {
            switch outcome.priority {
            case .primary where seatedPrimary == nil:
                seatedPrimary = outcome
            case .primary, .secondary:
                contenders.append(outcome)
            case .operational:
                operational.append(outcome)
            }
        }

        self.primary = seatedPrimary
        self.secondary = Array(contenders.prefix(WeeklyOutcomeSet.secondaryCapacity))
        self.operational = operational
        self.unseated = Array(contenders.dropFirst(WeeklyOutcomeSet.secondaryCapacity))
    }

    // MARK: - Access

    /// Everything the set holds, in seating order.
    public var all: [WeeklyOutcome] {
        (primary.map { [$0] } ?? []) + secondary + operational + unseated
    }

    /// The outcomes the week is supposed to be about, primary first.
    public var focus: [WeeklyOutcome] {
        (primary.map { [$0] } ?? []) + secondary
    }

    public var isEmpty: Bool { all.isEmpty }

    public var hasPrimary: Bool { primary != nil }

    public var remainingSecondarySlots: Int {
        max(0, WeeklyOutcomeSet.secondaryCapacity - secondary.count)
    }

    public var canAddSecondary: Bool { remainingSecondarySlots > 0 }

    public var hasUnseated: Bool { !unseated.isEmpty }

    public func outcome(id: UUID) -> WeeklyOutcome? {
        all.first { $0.id == id }
    }

    public func contains(id: UUID) -> Bool { outcome(id: id) != nil }
}
