import Foundation

/// A stream of work that sessions and accomplishments are filed under.
public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// A token from `Project.colorIDs`, stored as a string so the palette can gain entries without
    /// a data migration. `LggrApp` maps it to a `Color`.
    public var colorID: String
    /// SF Symbol name.
    public var iconID: String
    public var isActive: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorID: String = Project.defaultColorID,
        iconID: String = Project.defaultIconID,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorID = colorID
        self.iconID = iconID
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Project {
    public static let defaultColorID = "blue"
    public static let defaultIconID = "folder"

    /// The palette offered by the project editor.
    public static let colorIDs: [String] = [
        "blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "graphite",
    ]

    /// Suggested icons in the project editor. Any SF Symbol name is accepted.
    public static let iconIDs: [String] = [
        "folder", "hammer", "cube", "chart.bar", "person.2", "wrench.and.screwdriver",
        "cart", "server.rack", "paintbrush", "book",
    ]

    /// Trimmed name, or `nil` when the user has typed only whitespace. The project editor uses this
    /// to decide whether saving is allowed.
    public var normalizedName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
