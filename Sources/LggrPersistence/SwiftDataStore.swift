// Xcode-only. See Models/SDModels.swift for why this target is excluded from the default build.

import Foundation
import SwiftData

import LggrKit

/// A `LggrStore` backed by SwiftData.
///
/// The mapping in this file is the whole point of the target: SwiftData types stay behind it, and
/// callers keep working in `LggrKit` value types. Swapping this in for `JSONFileStore` changes no
/// view and no domain type.
@MainActor
public final class SwiftDataStore: LggrStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    /// Opens the on-disk container. `url` defaults to SwiftData's own location for the app.
    public convenience init(url: URL? = nil) throws {
        let configuration =
            url.map { ModelConfiguration(url: $0) } ?? ModelConfiguration()
        do {
            let container = try ModelContainer(
                for: Schema(LggrSchema.models),
                configurations: configuration
            )
            self.init(context: ModelContext(container))
        } catch {
            throw StoreError.persistenceFailure(
                "could not open the SwiftData store: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Projects

    public func loadProjects() async throws -> [Project] {
        let descriptor = FetchDescriptor<SDProject>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try fetch(descriptor).map(Self.toDomain)
    }

    public func saveProject(_ project: Project) async throws {
        let existing = try first(SDProject.self, id: project.id)
        let row = existing ?? SDProject(
            id: project.id,
            name: project.name,
            colorID: project.colorID,
            iconID: project.iconID,
            isActive: project.isActive,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
        row.name = project.name
        row.colorID = project.colorID
        row.iconID = project.iconID
        row.isActive = project.isActive
        row.updatedAt = project.updatedAt

        if existing == nil { context.insert(row) }
        try commit()
    }

    public func deleteProject(id: UUID) async throws {
        guard let row = try first(SDProject.self, id: id) else { return }
        // The `.nullify` delete rules clear `project` on the related rows; deleting the project
        // therefore leaves every session and accomplishment in place, minus its label.
        context.delete(row)

        // Interruptions and weekly outcomes hold plain identifiers rather than relationships, so
        // there is no delete rule to do this for them. Clearing them here is what keeps this backend
        // in step with the other two, which clear the same references in their own `deleteProject`.
        // A converted interruption stays converted: only the label goes.
        // Captured as an optional so both sides of the comparison have the same type: `#Predicate`
        // type-checks its expression rather than promoting one operand the way ordinary Swift does.
        let target: UUID? = id
        let interruptions = try fetch(
            FetchDescriptor<SDInterruption>(
                predicate: #Predicate { $0.convertedProjectID == target }
            )
        )
        for interruption in interruptions { interruption.convertedProjectID = nil }

        for outcome in try fetch(FetchDescriptor<SDWeeklyOutcome>())
        where outcome.projectIDs.contains(id) {
            outcome.projectIDs.removeAll { $0 == id }
        }

        try commit()
    }

    // MARK: - Focus sessions

    public func loadSessions(in interval: DateInterval) async throws -> [FocusSession] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<SDFocusSession>(
            predicate: #Predicate { $0.startedAt >= start && $0.startedAt < end },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return try fetch(descriptor).map(Self.toDomain)
    }

    public func loadSession(id: UUID) async throws -> FocusSession? {
        try first(SDFocusSession.self, id: id).map(Self.toDomain)
    }

    public func loadActiveSession() async throws -> FocusSession? {
        var descriptor = FetchDescriptor<SDFocusSession>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first.map(Self.toDomain)
    }

    public func loadUnreviewedSession() async throws -> FocusSession? {
        var descriptor = FetchDescriptor<SDFocusSession>(
            predicate: #Predicate { $0.endedAt != nil && $0.resultStatusRaw == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first.map(Self.toDomain)
    }

    public func saveSession(_ session: FocusSession) async throws {
        let existing = try first(SDFocusSession.self, id: session.id)
        let row = existing ?? SDFocusSession(
            id: session.id,
            intendedOutcome: session.intendedOutcome,
            workTypeRaw: session.workType.rawValue,
            startedAt: session.startedAt,
            pausedDuration: session.pausedDuration,
            isReactive: session.isReactive,
            interruptionCount: session.interruptionCount
        )
        row.project = try session.projectID.flatMap { try first(SDProject.self, id: $0) }
        row.weeklyOutcomeID = session.weeklyOutcomeID
        row.intendedOutcome = session.intendedOutcome
        row.workTypeRaw = session.workType.rawValue
        row.plannedDuration = session.plannedDuration
        row.endedAt = session.endedAt
        row.pausedDuration = session.pausedDuration
        row.pauseStartedAt = session.pauseStartedAt
        row.resultStatusRaw = session.resultStatus?.rawValue
        row.resultSummary = session.resultSummary
        row.tangibleResult = session.tangibleResult
        row.blocker = session.blocker
        row.nextStep = session.nextStep
        row.isReactive = session.isReactive
        row.interruptionCount = session.interruptionCount

        if existing == nil { context.insert(row) }
        try commit()
    }

    public func deleteSession(id: UUID) async throws {
        guard let row = try first(SDFocusSession.self, id: id) else { return }
        context.delete(row)
        try commit()
    }

    // MARK: - Accomplishments

    public func loadAccomplishments(in interval: DateInterval) async throws -> [Accomplishment] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<SDAccomplishment>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try fetch(descriptor).map(Self.toDomain)
    }

    public func saveAccomplishment(_ accomplishment: Accomplishment) async throws {
        let existing = try first(SDAccomplishment.self, id: accomplishment.id)
        let row = existing ?? SDAccomplishment(
            id: accomplishment.id,
            typeRaw: accomplishment.type.rawValue,
            title: accomplishment.title,
            timestamp: accomplishment.timestamp
        )
        row.project = try accomplishment.projectID.flatMap { try first(SDProject.self, id: $0) }
        row.weeklyOutcomeID = accomplishment.weeklyOutcomeID
        row.focusSession = try accomplishment.focusSessionID
            .flatMap { try first(SDFocusSession.self, id: $0) }
        row.typeRaw = accomplishment.type.rawValue
        row.title = accomplishment.title
        row.details = accomplishment.details
        row.timestamp = accomplishment.timestamp

        if existing == nil { context.insert(row) }
        try commit()
    }

    public func deleteAccomplishment(id: UUID) async throws {
        guard let row = try first(SDAccomplishment.self, id: id) else { return }
        context.delete(row)
        try commit()
    }

    // MARK: - Interruptions

    public func loadInterruptions(in interval: DateInterval) async throws -> [Interruption] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<SDInterruption>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try fetch(descriptor).map(Self.toDomain).sorted(by: RowOrdering.newestFirst)
    }

    public func loadPendingInterruptions() async throws -> [Interruption] {
        let inbox = InterruptionStatus.inbox.rawValue
        let descriptor = FetchDescriptor<SDInterruption>(
            predicate: #Predicate { $0.statusRaw == inbox },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try fetch(descriptor).map(Self.toDomain).sorted(by: RowOrdering.newestFirst)
    }

    public func saveInterruption(_ interruption: Interruption) async throws {
        let existing = try first(SDInterruption.self, id: interruption.id)
        let row = existing ?? SDInterruption(
            id: interruption.id,
            text: interruption.description,
            sourceRaw: interruption.source.rawValue,
            timestamp: interruption.timestamp,
            statusRaw: interruption.status.rawValue
        )
        row.focusSessionID = interruption.focusSessionID
        row.text = interruption.description
        row.sourceRaw = interruption.source.rawValue
        row.timestamp = interruption.timestamp
        row.statusRaw = interruption.status.rawValue
        row.convertedProjectID = interruption.convertedProjectID

        if existing == nil { context.insert(row) }
        try commit()
    }

    public func deleteInterruption(id: UUID) async throws {
        guard let row = try first(SDInterruption.self, id: id) else { return }
        context.delete(row)
        try commit()
    }

    // MARK: - Weekly outcomes

    public func loadWeeklyOutcomes(in interval: DateInterval) async throws -> [WeeklyOutcome] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<SDWeeklyOutcome>(
            predicate: #Predicate { $0.weekStartDate >= start && $0.weekStartDate < end },
            sortBy: [
                SortDescriptor(\.weekStartDate, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse),
            ]
        )
        return try fetch(descriptor).map(Self.toDomain).sorted(by: RowOrdering.newestFirst)
    }

    public func saveWeeklyOutcome(_ outcome: WeeklyOutcome) async throws {
        let existing = try first(SDWeeklyOutcome.self, id: outcome.id)
        let row = existing ?? SDWeeklyOutcome(
            id: outcome.id,
            title: outcome.title,
            priorityRaw: outcome.priority.rawValue,
            statusRaw: outcome.status.rawValue,
            progress: outcome.progress,
            weekStartDate: outcome.weekStartDate,
            projectIDs: outcome.projectIDs,
            createdAt: outcome.createdAt,
            updatedAt: outcome.updatedAt
        )
        row.title = outcome.title
        row.details = outcome.details
        row.priorityRaw = outcome.priority.rawValue
        row.statusRaw = outcome.status.rawValue
        row.progress = outcome.progress
        row.weekStartDate = outcome.weekStartDate
        row.projectIDs = outcome.projectIDs
        row.updatedAt = outcome.updatedAt

        if existing == nil { context.insert(row) }
        try commit()
    }

    /// The week's declared intent is gone; the work done towards it is not. Sessions and
    /// accomplishments keep every field except `weeklyOutcomeID`.
    public func deleteWeeklyOutcome(id: UUID) async throws {
        guard let row = try first(SDWeeklyOutcome.self, id: id) else { return }
        context.delete(row)

        // Optional on both sides — see `deleteProject`.
        let target: UUID? = id
        let sessions = try fetch(
            FetchDescriptor<SDFocusSession>(predicate: #Predicate { $0.weeklyOutcomeID == target })
        )
        for session in sessions { session.weeklyOutcomeID = nil }

        let accomplishments = try fetch(
            FetchDescriptor<SDAccomplishment>(
                predicate: #Predicate { $0.weeklyOutcomeID == target }
            )
        )
        for accomplishment in accomplishments { accomplishment.weeklyOutcomeID = nil }

        try commit()
    }

    // MARK: - Classification rules

    public func loadClassificationRules() async throws -> [ClassificationRule] {
        let descriptor = FetchDescriptor<SDClassificationRule>(
            sortBy: [SortDescriptor(\.ordinal, order: .forward)]
        )
        return try fetch(descriptor).map(Self.toDomain)
    }

    public func saveClassificationRule(_ rule: ClassificationRule) async throws {
        let existing = try first(SDClassificationRule.self, id: rule.id)
        // A new rule goes to the end of the editor's list; an upsert keeps the row where the user is
        // looking at it, which is the same choice `saveProject` makes.
        let ordinal: Int
        if let existing {
            ordinal = existing.ordinal
        } else {
            ordinal = try nextRuleOrdinal()
        }
        let row = existing ?? SDClassificationRule(
            id: rule.id,
            matchTypeRaw: rule.matchType.rawValue,
            matchValue: rule.matchValue,
            categoryRaw: rule.category.rawValue,
            projectID: rule.projectID,
            priority: rule.priority,
            isEnabled: rule.isEnabled,
            ordinal: ordinal
        )
        row.matchTypeRaw = rule.matchType.rawValue
        row.matchValue = rule.matchValue
        row.categoryRaw = rule.category.rawValue
        row.projectID = rule.projectID
        row.priority = rule.priority
        row.isEnabled = rule.isEnabled

        if existing == nil { context.insert(row) }
        try commit()
    }

    public func deleteClassificationRule(id: UUID) async throws {
        guard let row = try first(SDClassificationRule.self, id: id) else { return }
        context.delete(row)
        try commit()
    }

    private func nextRuleOrdinal() throws -> Int {
        var descriptor = FetchDescriptor<SDClassificationRule>(
            sortBy: [SortDescriptor(\.ordinal, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try fetch(descriptor).first?.ordinal ?? -1) + 1
    }

    // MARK: - Fetching

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do {
            return try context.fetch(descriptor)
        } catch {
            throw StoreError.persistenceFailure("fetch failed: \(error.localizedDescription)")
        }
    }

    private func first<T: PersistentModel>(_ type: T.Type, id: UUID) throws -> T? where T: Identified {
        var descriptor = FetchDescriptor<T>(predicate: T.matching(id: id))
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func commit() throws {
        do {
            try context.save()
        } catch {
            throw StoreError.persistenceFailure("save failed: \(error.localizedDescription)")
        }
    }
}

/// Lets `first(_:id:)` build an id predicate generically. `#Predicate` cannot close over a key path
/// chosen at runtime, so each model supplies its own.
public protocol Identified {
    static func matching(id: UUID) -> Predicate<Self>
}

extension SDProject: Identified {
    public static func matching(id: UUID) -> Predicate<SDProject> {
        #Predicate { $0.id == id }
    }
}

extension SDFocusSession: Identified {
    public static func matching(id: UUID) -> Predicate<SDFocusSession> {
        #Predicate { $0.id == id }
    }
}

extension SDAccomplishment: Identified {
    public static func matching(id: UUID) -> Predicate<SDAccomplishment> {
        #Predicate { $0.id == id }
    }
}

extension SDInterruption: Identified {
    public static func matching(id: UUID) -> Predicate<SDInterruption> {
        #Predicate { $0.id == id }
    }
}

extension SDWeeklyOutcome: Identified {
    public static func matching(id: UUID) -> Predicate<SDWeeklyOutcome> {
        #Predicate { $0.id == id }
    }
}

extension SDClassificationRule: Identified {
    public static func matching(id: UUID) -> Predicate<SDClassificationRule> {
        #Predicate { $0.id == id }
    }
}

// MARK: - Ordering

/// Mirrors `LggrKit.StoreOrdering`, which is internal to that module.
///
/// A `SortDescriptor` orders on one field and says nothing about what happens when two rows share
/// it, so without this a week's outcomes — which all carry the same `weekStartDate` by definition —
/// would come back in whatever order the fetch produced, and two interruptions captured in the same
/// second would swap places between runs. `StoreOrdering` breaks those ties on `id`; so does this.
/// The date sort stays in the fetch so the database still does the bulk of the work.
private enum RowOrdering {

    static func newestFirst(_ lhs: Interruption, _ rhs: Interruption) -> Bool {
        lhs.timestamp == rhs.timestamp
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.timestamp > rhs.timestamp
    }

    static func newestFirst(_ lhs: WeeklyOutcome, _ rhs: WeeklyOutcome) -> Bool {
        if lhs.weekStartDate != rhs.weekStartDate { return lhs.weekStartDate > rhs.weekStartDate }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

// MARK: - Mapping to domain values

extension SwiftDataStore {

    fileprivate static func toDomain(_ row: SDProject) -> Project {
        Project(
            id: row.id,
            name: row.name,
            colorID: row.colorID,
            iconID: row.iconID,
            isActive: row.isActive,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    fileprivate static func toDomain(_ row: SDFocusSession) -> FocusSession {
        FocusSession(
            id: row.id,
            projectID: row.project?.id,
            weeklyOutcomeID: row.weeklyOutcomeID,
            intendedOutcome: row.intendedOutcome,
            // An unrecognised raw value falls back rather than throwing: a session recorded by a
            // newer build should still be readable, just less precisely labelled.
            workType: WorkType(rawValue: row.workTypeRaw) ?? .deepWork,
            plannedDuration: row.plannedDuration,
            startedAt: row.startedAt,
            endedAt: row.endedAt,
            pausedDuration: row.pausedDuration,
            pauseStartedAt: row.pauseStartedAt,
            resultStatus: row.resultStatusRaw.flatMap(SessionResultStatus.init(rawValue:)),
            resultSummary: row.resultSummary,
            tangibleResult: row.tangibleResult,
            blocker: row.blocker,
            nextStep: row.nextStep,
            isReactive: row.isReactive,
            interruptionCount: row.interruptionCount
        )
    }

    fileprivate static func toDomain(_ row: SDInterruption) -> Interruption {
        Interruption(
            id: row.id,
            focusSessionID: row.focusSessionID,
            description: row.text,
            // An unrecognised raw value falls back rather than throwing, for the same reason
            // `workType` does: a row written by a newer build should still be readable.
            source: InterruptionSource(rawValue: row.sourceRaw) ?? .other,
            timestamp: row.timestamp,
            status: InterruptionStatus(rawValue: row.statusRaw) ?? .inbox,
            convertedProjectID: row.convertedProjectID
        )
    }

    fileprivate static func toDomain(_ row: SDWeeklyOutcome) -> WeeklyOutcome {
        WeeklyOutcome(
            id: row.id,
            title: row.title,
            details: row.details,
            priority: OutcomePriority(rawValue: row.priorityRaw) ?? .secondary,
            status: OutcomeStatus(rawValue: row.statusRaw) ?? .notStarted,
            // `WeeklyOutcome.init` clamps, so a stored value outside 0…1 cannot reach the review.
            progress: row.progress,
            weekStartDate: row.weekStartDate,
            projectIDs: row.projectIDs,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }

    fileprivate static func toDomain(_ row: SDClassificationRule) -> ClassificationRule {
        ClassificationRule(
            id: row.id,
            // An unrecognised axis falls back to the narrowest comparison that cannot accidentally
            // hold: a bundle identifier never equals a title fragment or a domain, so the rule stays
            // visible in the editor and inert in the engine. Dropping the row instead would look to
            // the user exactly like Lggr having deleted their rule.
            matchType: RuleMatchType(rawValue: row.matchTypeRaw) ?? .application,
            matchValue: row.matchValue,
            // `.unknown`, never a real category: a rule written by a newer build must not end up
            // filing time under a label the user did not choose.
            category: ActivityCategory(rawValue: row.categoryRaw) ?? .unknown,
            projectID: row.projectID,
            priority: row.priority,
            isEnabled: row.isEnabled
        )
    }

    fileprivate static func toDomain(_ row: SDAccomplishment) -> Accomplishment {
        Accomplishment(
            id: row.id,
            projectID: row.project?.id,
            weeklyOutcomeID: row.weeklyOutcomeID,
            focusSessionID: row.focusSession?.id,
            type: AccomplishmentType(rawValue: row.typeRaw) ?? .other,
            title: row.title,
            details: row.details,
            timestamp: row.timestamp
        )
    }
}
