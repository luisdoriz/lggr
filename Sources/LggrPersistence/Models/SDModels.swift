// SwiftData entities for Lggr.
//
// This target is EXCLUDED from the default build. The `@Model` macro is implemented by
// `libSwiftDataMacros.dylib`, which ships only inside Xcode — with Command Line Tools alone this
// file cannot compile at all. See docs/_design/CONSTRAINTS.md.
//
//   LGGR_SWIFTDATA=1 swift build     builds this target (requires Xcode)
//   swift build                      skips it; the app uses JSONFileStore instead
//
// These classes are a persistence detail and never leave the target. Everything above them speaks
// in the `LggrKit` value types, so the rest of the app cannot come to depend on SwiftData
// behaviour — object identity, faulting, or a `ModelContext` on the wrong actor.

import Foundation
import SwiftData

import LggrKit

@Model
public final class SDProject {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var colorID: String
    public var iconID: String
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    // No cascade, deliberately. A project is a label on work that was done, and deleting the label
    // must not delete the evidence — sessions and accomplishments outlive it with their reference
    // nulled. `.nullify` on both inverses is what enforces that at the store level rather than
    // relying on every call site to remember.
    @Relationship(deleteRule: .nullify, inverse: \SDFocusSession.project)
    public var sessions: [SDFocusSession] = []

    @Relationship(deleteRule: .nullify, inverse: \SDAccomplishment.project)
    public var accomplishments: [SDAccomplishment] = []

    public init(
        id: UUID,
        name: String,
        colorID: String,
        iconID: String,
        isActive: Bool,
        createdAt: Date,
        updatedAt: Date
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

@Model
public final class SDFocusSession {
    @Attribute(.unique) public var id: UUID
    public var project: SDProject?
    public var weeklyOutcomeID: UUID?
    public var intendedOutcome: String
    /// Stored as the enum's raw value. A future `WorkType` case that this build does not know about
    /// therefore round-trips as data rather than failing to decode.
    public var workTypeRaw: String
    public var plannedDuration: TimeInterval?
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedDuration: TimeInterval
    public var pauseStartedAt: Date?
    public var resultStatusRaw: String?
    public var resultSummary: String?
    public var tangibleResult: String?
    public var blocker: String?
    public var nextStep: String?
    public var isReactive: Bool
    public var interruptionCount: Int

    @Relationship(deleteRule: .nullify, inverse: \SDAccomplishment.focusSession)
    public var accomplishments: [SDAccomplishment] = []

    public init(
        id: UUID,
        intendedOutcome: String,
        workTypeRaw: String,
        startedAt: Date,
        pausedDuration: TimeInterval,
        isReactive: Bool,
        interruptionCount: Int
    ) {
        self.id = id
        self.intendedOutcome = intendedOutcome
        self.workTypeRaw = workTypeRaw
        self.startedAt = startedAt
        self.pausedDuration = pausedDuration
        self.isReactive = isReactive
        self.interruptionCount = interruptionCount
    }
}

@Model
public final class SDAccomplishment {
    @Attribute(.unique) public var id: UUID
    public var project: SDProject?
    public var weeklyOutcomeID: UUID?
    /// Nullified rather than cascaded: an accomplishment is a record of something that happened, and
    /// deleting the session it came out of does not un-happen it.
    public var focusSession: SDFocusSession?
    public var typeRaw: String
    public var title: String
    public var details: String?
    public var timestamp: Date

    public init(
        id: UUID,
        typeRaw: String,
        title: String,
        timestamp: Date
    ) {
        self.id = id
        self.typeRaw = typeRaw
        self.title = title
        self.timestamp = timestamp
    }
}

/// Something that arrived mid-session and was written down instead of acted on.
///
/// `focusSessionID` and `convertedProjectID` are plain identifiers rather than SwiftData
/// relationships, unlike `SDFocusSession.project`. A relationship would bring a delete rule with it,
/// and a delete rule is a second, invisible answer to "what happens to this row when its parent
/// goes" — one that only this backend would have. `JSONFileStore` and `InMemoryStore` clear these
/// references explicitly inside `deleteProject`, and `SwiftDataStore` does the same, so all three
/// behave identically instead of two agreeing by accident.
@Model
public final class SDInterruption {
    @Attribute(.unique) public var id: UUID
    public var focusSessionID: UUID?
    /// The domain property is `Interruption.description`. It is not called that here: `description`
    /// is a name Core Data reserves and Objective-C already defines, and the column has no reason to
    /// carry that risk when the mapping can rename it in one place.
    public var text: String
    public var sourceRaw: String
    public var timestamp: Date
    public var statusRaw: String
    public var convertedProjectID: UUID?

    public init(
        id: UUID,
        text: String,
        sourceRaw: String,
        timestamp: Date,
        statusRaw: String
    ) {
        self.id = id
        self.text = text
        self.sourceRaw = sourceRaw
        self.timestamp = timestamp
        self.statusRaw = statusRaw
    }
}

/// One thing a week is supposed to produce.
///
/// Sessions and accomplishments point *at* an outcome by id rather than being owned by it, so the
/// outcome can be deleted without taking the record of work already done with it.
@Model
public final class SDWeeklyOutcome {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var details: String?
    public var priorityRaw: String
    public var statusRaw: String
    public var progress: Double
    public var weekStartDate: Date
    public var projectIDs: [UUID]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID,
        title: String,
        priorityRaw: String,
        statusRaw: String,
        progress: Double,
        weekStartDate: Date,
        projectIDs: [UUID],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.priorityRaw = priorityRaw
        self.statusRaw = statusRaw
        self.progress = progress
        self.weekStartDate = weekStartDate
        self.projectIDs = projectIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One user-visible classification instruction.
///
/// `matchValue` holds text the *user* typed, including for a window-title rule. An observed title
/// never reaches this column: the engine tests titles in memory and releases them, and the
/// correction flow refuses to author a rule that would put one here. See `INTELLIGENCE.md` §3.3.
@Model
public final class SDClassificationRule {
    @Attribute(.unique) public var id: UUID
    public var matchTypeRaw: String
    public var matchValue: String
    public var categoryRaw: String
    public var projectID: UUID?
    public var priority: Int
    public var isEnabled: Bool
    /// Position in the rules editor. SwiftData has no inherent row order, and the other two backends
    /// preserve insertion order, so it is stored rather than hoped for.
    public var ordinal: Int

    public init(
        id: UUID,
        matchTypeRaw: String,
        matchValue: String,
        categoryRaw: String,
        projectID: UUID?,
        priority: Int,
        isEnabled: Bool,
        ordinal: Int
    ) {
        self.id = id
        self.matchTypeRaw = matchTypeRaw
        self.matchValue = matchValue
        self.categoryRaw = categoryRaw
        self.projectID = projectID
        self.priority = priority
        self.isEnabled = isEnabled
        self.ordinal = ordinal
    }
}

public enum LggrSchema {
    /// Every model the container manages. Activity samples are not here: they are appended thousands
    /// of times a day and pruned by date, so `ActivityLog` keeps them in one file per day instead.
    public static let models: [any PersistentModel.Type] = [
        SDProject.self,
        SDFocusSession.self,
        SDAccomplishment.self,
        SDInterruption.self,
        SDWeeklyOutcome.self,
        SDClassificationRule.self,
    ]
}
