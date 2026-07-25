import Foundation

/// The kind of work a focus session is intended to be.
///
/// Raw values are written out explicitly: a Swift-level rename must never silently invalidate
/// sessions already on disk.
public enum WorkType: String, Codable, CaseIterable, Sendable, Identifiable {
    case deepWork
    case codeReview
    case management
    case communication
    case planning
    case incident
    case meeting
    case administrative

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepWork: "Deep work"
        case .codeReview: "Code review"
        case .management: "Management"
        case .communication: "Communication"
        case .planning: "Planning"
        case .incident: "Incident"
        case .meeting: "Meeting"
        case .administrative: "Administrative"
        }
    }

    public var symbolName: String {
        switch self {
        case .deepWork: "brain.head.profile"
        case .codeReview: "arrow.triangle.pull"
        case .management: "person.2"
        case .communication: "bubble.left.and.bubble.right"
        case .planning: "map"
        case .incident: "exclamationmark.triangle"
        case .meeting: "video"
        case .administrative: "tray.full"
        }
    }

    /// Duration the start panel pre-selects, so the common case needs no interaction at all:
    /// 50 minutes for work that deserves a long runway, 25 for work that is inherently bursty.
    public var suggestedDuration: TimeInterval {
        switch self {
        case .deepWork, .codeReview, .incident, .planning: 50 * 60
        case .communication, .administrative, .management, .meeting: 25 * 60
        }
    }

    /// Seeds `FocusSession.isReactive`. Reactive work is work that arrived rather than work that was
    /// chosen — the distinction the weekly review is built on. Always overridable by the user.
    public var isReactiveByDefault: Bool {
        switch self {
        case .incident, .communication, .meeting, .administrative: true
        case .deepWork, .codeReview, .management, .planning: false
        }
    }
}
