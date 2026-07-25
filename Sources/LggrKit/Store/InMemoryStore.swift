import Foundation

/// One durable change, recorded so a test can assert that saving happened exactly once.
public enum StoreWrite: Hashable, Sendable {
    case projectSaved(UUID)
    case projectDeleted(UUID)
    case sessionSaved(UUID)
    case sessionDeleted(UUID)
    case accomplishmentSaved(UUID)
    case accomplishmentDeleted(UUID)
    case interruptionSaved(UUID)
    case interruptionDeleted(UUID)
    case weeklyOutcomeSaved(UUID)
    case weeklyOutcomeDeleted(UUID)
    case classificationRuleSaved(UUID)
    case classificationRuleDeleted(UUID)
}

/// The `LggrStore` that unit tests and preview fixtures run against.
///
/// It is held to the same contract as the file-backed store rather than to a convenient
/// approximation: upsert by `id` never duplicates, `deleteProject` never cascades, and deleting a
/// row that is not there succeeds silently. A fake that behaves differently from the real backend —
/// in either direction — is worse than no fake at all, because it green-lights code that breaks in
/// production, or forces call sites to handle errors production never raises.
///
/// Filtering and ordering are not reimplemented here: both stores call `StoreOrdering`, so the two
/// cannot drift. Interval filtering is half-open and ordering is newest-first with an `id`
/// tie-break; see that file for why.
///
/// Deliberate choices, each mirrored by the durable store:
/// - **Projects and classification rules keep insertion order**, and an upsert replaces in place
///   rather than moving the row to the end, so a list that the user is looking at does not reshuffle
///   when a project is renamed or a rule is switched off.
@MainActor
public final class InMemoryStore: LggrStore {

    /// When set, every method throws this instead of doing its work. Nothing is mutated and nothing
    /// is recorded, so the error paths of the UI can be driven without leaving the store dirty.
    public var failureToInject: StoreError?

    public private(set) var projects: [Project]
    public private(set) var sessions: [FocusSession]
    public private(set) var accomplishments: [Accomplishment]
    public private(set) var interruptions: [Interruption]
    public private(set) var weeklyOutcomes: [WeeklyOutcome]
    public private(set) var classificationRules: [ClassificationRule]

    /// Every durable change since the last `resetWrites()`, oldest first.
    public private(set) var writes: [StoreWrite] = []

    public init(
        projects: [Project] = [],
        sessions: [FocusSession] = [],
        accomplishments: [Accomplishment] = [],
        interruptions: [Interruption] = [],
        weeklyOutcomes: [WeeklyOutcome] = [],
        classificationRules: [ClassificationRule] = []
    ) {
        self.projects = projects
        self.sessions = sessions
        self.accomplishments = accomplishments
        self.interruptions = interruptions
        self.weeklyOutcomes = weeklyOutcomes
        self.classificationRules = classificationRules
    }

    // MARK: - Write log

    public var writeCount: Int { writes.count }

    public func resetWrites() {
        writes.removeAll()
    }

    private func record(_ write: StoreWrite) {
        writes.append(write)
    }

    private func checkFailure() throws {
        if let failureToInject { throw failureToInject }
    }

    // MARK: - Projects

    public func loadProjects() async throws -> [Project] {
        try checkFailure()
        return projects
    }

    public func saveProject(_ project: Project) async throws {
        try checkFailure()
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        record(.projectSaved(project.id))
    }

    public func deleteProject(id: UUID) async throws {
        try checkFailure()
        projects.removeAll { $0.id == id }

        // History outlives the project it was filed under: the rows stay, only the reference goes.
        for index in sessions.indices where sessions[index].projectID == id {
            sessions[index].projectID = nil
        }
        for index in accomplishments.indices where accomplishments[index].projectID == id {
            accomplishments[index].projectID = nil
        }
        // A converted interruption stays converted: turning it into tracked work is what happened,
        // and only the label that work was filed under is going away.
        for index in interruptions.indices where interruptions[index].convertedProjectID == id {
            interruptions[index].convertedProjectID = nil
        }
        for index in weeklyOutcomes.indices
        where weeklyOutcomes[index].projectIDs.contains(id) {
            weeklyOutcomes[index].projectIDs.removeAll { $0 == id }
        }
        record(.projectDeleted(id))
    }

    // MARK: - Focus sessions

    public func loadSessions(in interval: DateInterval) async throws -> [FocusSession] {
        try checkFailure()
        return
            sessions
            .filter { StoreOrdering.contains($0.startedAt, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func loadSession(id: UUID) async throws -> FocusSession? {
        try checkFailure()
        return sessions.first { $0.id == id }
    }

    public func loadActiveSession() async throws -> FocusSession? {
        try checkFailure()
        return
            sessions
            .filter { $0.endedAt == nil }
            .sorted(by: StoreOrdering.newestFirst)
            .first
    }

    public func loadUnreviewedSession() async throws -> FocusSession? {
        try checkFailure()
        return
            sessions
            .filter { $0.endedAt != nil && $0.resultStatus == nil }
            .sorted(by: StoreOrdering.newestFirst)
            .first
    }

    public func saveSession(_ session: FocusSession) async throws {
        try checkFailure()
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        record(.sessionSaved(session.id))
    }

    public func deleteSession(id: UUID) async throws {
        try checkFailure()
        sessions.removeAll { $0.id == id }
        record(.sessionDeleted(id))
    }

    // MARK: - Accomplishments

    public func loadAccomplishments(in interval: DateInterval) async throws -> [Accomplishment] {
        try checkFailure()
        return
            accomplishments
            .filter { StoreOrdering.contains($0.timestamp, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func saveAccomplishment(_ accomplishment: Accomplishment) async throws {
        try checkFailure()
        if let index = accomplishments.firstIndex(where: { $0.id == accomplishment.id }) {
            accomplishments[index] = accomplishment
        } else {
            accomplishments.append(accomplishment)
        }
        record(.accomplishmentSaved(accomplishment.id))
    }

    public func deleteAccomplishment(id: UUID) async throws {
        try checkFailure()
        accomplishments.removeAll { $0.id == id }
        record(.accomplishmentDeleted(id))
    }

    // MARK: - Interruptions

    public func loadInterruptions(in interval: DateInterval) async throws -> [Interruption] {
        try checkFailure()
        return
            interruptions
            .filter { StoreOrdering.contains($0.timestamp, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func loadPendingInterruptions() async throws -> [Interruption] {
        try checkFailure()
        return
            interruptions
            .filter(\.isPending)
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func saveInterruption(_ interruption: Interruption) async throws {
        try checkFailure()
        if let index = interruptions.firstIndex(where: { $0.id == interruption.id }) {
            interruptions[index] = interruption
        } else {
            interruptions.append(interruption)
        }
        record(.interruptionSaved(interruption.id))
    }

    public func deleteInterruption(id: UUID) async throws {
        try checkFailure()
        interruptions.removeAll { $0.id == id }
        record(.interruptionDeleted(id))
    }

    // MARK: - Weekly outcomes

    public func loadWeeklyOutcomes(in interval: DateInterval) async throws -> [WeeklyOutcome] {
        try checkFailure()
        return
            weeklyOutcomes
            .filter { StoreOrdering.contains($0.weekStartDate, in: interval) }
            .sorted(by: StoreOrdering.newestFirst)
    }

    public func saveWeeklyOutcome(_ outcome: WeeklyOutcome) async throws {
        try checkFailure()
        if let index = weeklyOutcomes.firstIndex(where: { $0.id == outcome.id }) {
            weeklyOutcomes[index] = outcome
        } else {
            weeklyOutcomes.append(outcome)
        }
        record(.weeklyOutcomeSaved(outcome.id))
    }

    public func deleteWeeklyOutcome(id: UUID) async throws {
        try checkFailure()
        weeklyOutcomes.removeAll { $0.id == id }

        // The week's declared intent is gone; the work that was done towards it is not.
        for index in sessions.indices where sessions[index].weeklyOutcomeID == id {
            sessions[index].weeklyOutcomeID = nil
        }
        for index in accomplishments.indices where accomplishments[index].weeklyOutcomeID == id {
            accomplishments[index].weeklyOutcomeID = nil
        }
        record(.weeklyOutcomeDeleted(id))
    }

    // MARK: - Classification rules

    public func loadClassificationRules() async throws -> [ClassificationRule] {
        try checkFailure()
        return classificationRules
    }

    public func saveClassificationRule(_ rule: ClassificationRule) async throws {
        try checkFailure()
        if let index = classificationRules.firstIndex(where: { $0.id == rule.id }) {
            classificationRules[index] = rule
        } else {
            classificationRules.append(rule)
        }
        record(.classificationRuleSaved(rule.id))
    }

    public func deleteClassificationRule(id: UUID) async throws {
        try checkFailure()
        classificationRules.removeAll { $0.id == id }
        record(.classificationRuleDeleted(id))
    }

}
