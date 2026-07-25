import Foundation

/// The entire Lggr database as one value.
///
/// A single flat document rather than a file per aggregate: the whole store is a few thousand small
/// records per year, and one document means one atomic write, so the collections can never disagree
/// with each other on disk.
public struct StoreSnapshot: Codable, Sendable, Equatable {

    /// Version of the on-disk layout this build writes.
    ///
    /// A reader must be taught how to migrate every version below the current one; until it is, an
    /// older reader refuses the file rather than round-tripping it and dropping what it did not
    /// understand.
    ///
    /// Adding a collection needs a bump even though it is additive and optional on read. The
    /// direction that matters is the other one: this store writes the whole document on every save,
    /// so an older build that opened a newer file would decode the fields it knows, silently discard
    /// the collections it does not, and put that loss back on disk the first time the user started a
    /// session. Refusing the file instead loses nothing — updating Lggr opens it intact.
    ///
    /// - Version 1: projects, focus sessions and accomplishments (Phase 2).
    /// - Version 2: interruptions, weekly outcomes and classification rules.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var projects: [Project]
    public var sessions: [FocusSession]
    public var accomplishments: [Accomplishment]
    public var interruptions: [Interruption]
    public var weeklyOutcomes: [WeeklyOutcome]
    public var classificationRules: [ClassificationRule]

    public init(
        schemaVersion: Int = StoreSnapshot.currentSchemaVersion,
        projects: [Project] = [],
        sessions: [FocusSession] = [],
        accomplishments: [Accomplishment] = [],
        interruptions: [Interruption] = [],
        weeklyOutcomes: [WeeklyOutcome] = [],
        classificationRules: [ClassificationRule] = []
    ) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.sessions = sessions
        self.accomplishments = accomplishments
        self.interruptions = interruptions
        self.weeklyOutcomes = weeklyOutcomes
        self.classificationRules = classificationRules
    }

    public var isEmpty: Bool {
        projects.isEmpty && sessions.isEmpty && accomplishments.isEmpty && interruptions.isEmpty
            && weeklyOutcomes.isEmpty && classificationRules.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case projects
        case sessions
        case accomplishments
        case interruptions
        case weeklyOutcomes
        case classificationRules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)

        guard version >= 1 else {
            throw StoreError.invalidData("Store schema version \(version) is not a valid version.")
        }
        // Refusing a newer file is the whole point: a build that quietly decoded it would drop every
        // field it has no property for, and the next save would write that loss back to disk.
        guard version <= Self.currentSchemaVersion else {
            throw StoreError.invalidData(
                """
                Store schema version \(version) was written by a newer version of Lggr. \
                This build understands up to version \(Self.currentSchemaVersion). \
                Update Lggr to open this file.
                """
            )
        }

        self.schemaVersion = version
        // The collections are optional on read so a file written before a collection existed still
        // opens; they are always present on write.
        self.projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
        self.sessions = try container.decodeIfPresent([FocusSession].self, forKey: .sessions) ?? []
        self.accomplishments =
            try container.decodeIfPresent([Accomplishment].self, forKey: .accomplishments) ?? []
        self.interruptions =
            try container.decodeIfPresent([Interruption].self, forKey: .interruptions) ?? []
        self.weeklyOutcomes =
            try container.decodeIfPresent([WeeklyOutcome].self, forKey: .weeklyOutcomes) ?? []
        self.classificationRules =
            try container.decodeIfPresent([ClassificationRule].self, forKey: .classificationRules)
            ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(projects, forKey: .projects)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(accomplishments, forKey: .accomplishments)
        try container.encode(interruptions, forKey: .interruptions)
        try container.encode(weeklyOutcomes, forKey: .weeklyOutcomes)
        try container.encode(classificationRules, forKey: .classificationRules)
    }
}

extension StoreSnapshot {

    /// The on-disk format, defined once.
    ///
    /// The store that writes the file and anything that reads it back — tests, a future importer —
    /// must agree on every coder setting, so the settings live here rather than being restated at
    /// each site where a coder is made.
    ///
    /// Dates are written as seconds since the reference date, not as ISO-8601 strings. ISO-8601
    /// truncates to whole seconds, so every timestamp the app has ever recorded would lose its
    /// fractional part on the first save-and-reload cycle: a session would silently change length,
    /// and a value loaded from disk would no longer equal the value that was saved. Readability of a
    /// timestamp is worth less than not rewriting the user's data behind their back.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        // Sorted keys and indentation are not cosmetic: they make the store diffable, greppable and
        // recoverable by hand, which is the only backup story a local-first app has.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return decoder
    }
}
