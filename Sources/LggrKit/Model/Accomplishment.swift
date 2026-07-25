import Foundation

/// The kind of thing that got done.
///
/// The list is deliberately weighted toward the work that usually goes unrecorded — reviewing,
/// unblocking, deciding, and deliberately dropping something — because that is the work people
/// cannot account for on Friday afternoon.
public enum AccomplishmentType: String, Codable, CaseIterable, Sendable, Identifiable {
    case featureCompleted
    case pullRequestOpened
    case pullRequestReviewed
    case decisionMade
    case personUnblocked
    case incidentResolved
    case customerIssueResolved
    case documentWritten
    case riskIdentified
    case workDeprioritized
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .featureCompleted: "Feature completed"
        case .pullRequestOpened: "Pull request opened"
        case .pullRequestReviewed: "Pull request reviewed"
        case .decisionMade: "Decision made"
        case .personUnblocked: "Person unblocked"
        case .incidentResolved: "Incident resolved"
        case .customerIssueResolved: "Customer issue resolved"
        case .documentWritten: "Document written"
        case .riskIdentified: "Risk identified"
        case .workDeprioritized: "Work deprioritized"
        case .other: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .featureCompleted: "shippingbox"
        case .pullRequestOpened: "arrow.triangle.pull"
        case .pullRequestReviewed: "checkmark.rectangle.stack"
        case .decisionMade: "signpost.right"
        case .personUnblocked: "person.badge.shield.checkmark"
        case .incidentResolved: "bolt.shield"
        case .customerIssueResolved: "person.crop.circle.badge.checkmark"
        case .documentWritten: "doc.text"
        case .riskIdentified: "eye.trianglebadge.exclamationmark"
        case .workDeprioritized: "arrow.down.circle"
        case .other: "circle"
        }
    }

    /// Work done on behalf of someone else. The weekly review totals these separately, because it is
    /// the part of a manager's week that leaves no other trace.
    public var isSupportWork: Bool {
        switch self {
        case .pullRequestReviewed, .personUnblocked, .incidentResolved, .customerIssueResolved: true
        default: false
        }
    }
}

/// One thing that got done. The unit of evidence in the "Done" log.
public struct Accomplishment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var weeklyOutcomeID: UUID?
    /// Set when this row was generated from a completed session rather than entered by hand.
    public var focusSessionID: UUID?
    public var type: AccomplishmentType
    public var title: String
    public var details: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        weeklyOutcomeID: UUID? = nil,
        focusSessionID: UUID? = nil,
        type: AccomplishmentType = .other,
        title: String,
        details: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.weeklyOutcomeID = weeklyOutcomeID
        self.focusSessionID = focusSessionID
        self.type = type
        self.title = title
        self.details = details
        self.timestamp = timestamp
    }
}

extension Accomplishment {
    /// True when this came out of a session rather than manual entry.
    public var isGeneratedFromSession: Bool { focusSessionID != nil }

    public var normalizedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
