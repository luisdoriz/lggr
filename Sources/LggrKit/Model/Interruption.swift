import Foundation

/// Where an interruption came from.
///
/// The list is coarse on purpose. A finer taxonomy would ask the user to classify the thing that
/// just broke their concentration, at the exact moment they have least attention to spare, and the
/// weekly review only ever needs to say which channel recurred.
///
/// Raw values are written out explicitly so a Swift-level rename cannot invalidate records on disk.
public enum InterruptionSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case person
    case message
    case email
    case meeting
    case incident
    case notification
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .person: "Person"
        case .message: "Message"
        case .email: "Email"
        case .meeting: "Meeting"
        case .incident: "Incident"
        case .notification: "Notification"
        case .other: "Other"
        }
    }

    /// The form used inside a generated sentence: "Interruptions from messages were recorded in…".
    /// Kept beside `displayName` so observation text never has to lowercase or pluralise a label at
    /// the call site and get it wrong for one case.
    public var sentencePhrase: String {
        switch self {
        case .person: "people"
        case .message: "messages"
        case .email: "email"
        case .meeting: "meetings"
        case .incident: "incidents"
        case .notification: "notifications"
        case .other: "other sources"
        }
    }

    public var symbolName: String {
        switch self {
        case .person: "person"
        case .message: "bubble.left"
        case .email: "envelope"
        case .meeting: "video"
        case .incident: "exclamationmark.triangle"
        case .notification: "bell"
        case .other: "circle"
        }
    }
}

/// Where an interruption is in the inbox.
public enum InterruptionStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Captured and not yet dealt with.
    case inbox
    /// Turned into tracked work.
    case converted
    /// Handled, or decided against, without becoming tracked work. Not a failure state: deciding
    /// something does not need doing is an outcome, and §10 records it as one.
    case dismissed

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inbox: "Inbox"
        case .converted: "Converted"
        case .dismissed: "Dismissed"
        }
    }

    public var isPending: Bool { self == .inbox }
}

/// Something that arrived mid-session and was written down instead of acted on.
///
/// The capture action deliberately does not end, pause or otherwise disturb the running session —
/// that is the whole point of it. The note lands here, and the inbox is processed later, when
/// deciding what to do with it costs nothing.
///
/// Relationships are held as `UUID`s for the same reason `FocusSession` holds them that way: the
/// store is a flat set of collections, and deleting a project must not take the record of the
/// interruption with it.
public struct Interruption: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The session that was running when this was captured. `nil` when captured outside a session.
    public var focusSessionID: UUID?
    /// What the user typed. Named for the spec's data model; this type deliberately does not conform
    /// to `CustomStringConvertible`, so the property is only ever the user's sentence.
    public var description: String
    public var source: InterruptionSource
    public var timestamp: Date
    public var status: InterruptionStatus
    /// The project this became, when it was converted into tracked work.
    public var convertedProjectID: UUID?

    public init(
        id: UUID = UUID(),
        focusSessionID: UUID? = nil,
        description: String,
        source: InterruptionSource = .other,
        timestamp: Date = Date(),
        status: InterruptionStatus = .inbox,
        convertedProjectID: UUID? = nil
    ) {
        self.id = id
        self.focusSessionID = focusSessionID
        self.description = description
        self.source = source
        self.timestamp = timestamp
        self.status = status
        self.convertedProjectID = convertedProjectID
    }
}

extension Interruption {

    /// Trimmed text, or `nil` when only whitespace was typed. The capture field uses this to decide
    /// whether there is anything worth saving.
    public var normalizedDescription: String? {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var isPending: Bool { status.isPending }

    /// Captured while a session was running, which is what makes it evidence about that session
    /// rather than a standalone note.
    public var interruptedASession: Bool { focusSessionID != nil }

    // The two transitions are here rather than at the call site so `status` and `convertedProjectID`
    // cannot drift apart — a converted row without a project, or a project on a dismissed row, would
    // both make the weekly counts ambiguous.

    public mutating func convert(toProjectID projectID: UUID?) {
        status = .converted
        convertedProjectID = projectID
    }

    public mutating func dismiss() {
        status = .dismissed
        convertedProjectID = nil
    }

    public mutating func returnToInbox() {
        status = .inbox
        convertedProjectID = nil
    }
}
