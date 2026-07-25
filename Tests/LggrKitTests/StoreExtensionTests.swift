import Foundation
import Testing

@testable import LggrKit

// MARK: - Backends

/// The conformers of `LggrStore` that this suite runs every test against.
///
/// Parameterising rather than writing two suites is the point. The last time interruption-free
/// behaviour was described twice — once for the fake, once for the file — the two descriptions
/// disagreed, the fake was what the unit tests exercised, and the suite was green about semantics
/// production did not have. A test written here cannot assert anything one backend does not do.
// Not `private`: a parameterised `@Test` puts the argument type in the method signature, and a
// private type there would force every test in the suite to be private too.
enum StoreBackend: String, CaseIterable, Sendable, CustomStringConvertible {
    case inMemory
    case jsonFile

    var description: String { rawValue }
}

/// A store of the given kind, plus the ability to see the same data as a fresh process would.
@MainActor
private final class StoreHarness {

    let store: any LggrStore

    private let backend: StoreBackend
    private let directory: URL

    init(_ backend: StoreBackend) throws {
        self.backend = backend
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreExtensionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        switch backend {
        case .inMemory:
            self.store = InMemoryStore()
        case .jsonFile:
            self.store = JSONFileStore(fileURL: directory.appendingPathComponent("store.json"))
        }
    }

    /// The store as another launch would find it.
    ///
    /// For the durable backend this is a genuinely new object reading the file, which is the only way
    /// to prove a collection reached the disk. For the fake it is the same object, because "reopening"
    /// a fake means nothing — and a test that passes for the fake only because reopening was a no-op
    /// is exactly the kind of hollow assertion this suite exists to prevent.
    func reopened() -> any LggrStore {
        switch backend {
        case .inMemory:
            return store
        case .jsonFile:
            return JSONFileStore(fileURL: directory.appendingPathComponent("store.json"))
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Conformance suite

/// The persistence contract for interruptions, weekly outcomes and classification rules.
///
/// Everything asserted here is required of every conformer, so these tests read as the specification
/// both backends are held to rather than as tests of either one.
@Suite("Store conformance: interruptions, outcomes and rules")
@MainActor
struct StoreExtensionTests {

    /// Monday 2024-01-15 09:00:00 UTC. Fixed so a failure reproduces identically on any machine.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)
    /// Midnight at the start of that same Monday.
    static let weekStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

    private func at(_ minutes: Double) -> Date {
        Self.nineAM.addingTimeInterval(minutes * 60)
    }

    private var theHour: DateInterval {
        DateInterval(start: Self.nineAM, end: at(60))
    }

    private var theWeek: DateInterval {
        DateInterval(start: Self.weekStart, end: Self.weekStart.addingTimeInterval(7 * 86_400))
    }

    private var nextWeek: DateInterval {
        DateInterval(
            start: Self.weekStart.addingTimeInterval(7 * 86_400),
            end: Self.weekStart.addingTimeInterval(14 * 86_400)
        )
    }

    private func lowIDFirst() -> (UUID, UUID) {
        let low = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
        let high = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001") ?? UUID()
        return (low, high)
    }

    // MARK: - Interruptions

    @Test("An interruption round trips and upserting it replaces rather than duplicates",
          arguments: StoreBackend.allCases)
    func interruptionUpsertDoesNotDuplicate(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        var interruption = Interruption(
            description: "Omar asked about the dedup rollout",
            source: .person,
            timestamp: at(20)
        )
        try await harness.store.saveInterruption(interruption)

        interruption.description = "Omar asked about the dedup rollout date"
        try await harness.store.saveInterruption(interruption)

        let loaded = try await harness.reopened().loadInterruptions(in: theHour)
        #expect(loaded.count == 1)
        #expect(loaded.first == interruption)
    }

    @Test("Interval filtering for interruptions is half-open", arguments: StoreBackend.allCases)
    func interruptionFilteringIsHalfOpen(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let atStart = Interruption(description: "on the boundary", timestamp: Self.nineAM)
        let atEnd = Interruption(description: "the next window's", timestamp: at(60))
        try await harness.store.saveInterruption(atStart)
        try await harness.store.saveInterruption(atEnd)

        let loaded = try await harness.store.loadInterruptions(in: theHour)
        #expect(loaded.map(\.description) == ["on the boundary"])
    }

    /// The interesting case is not one boundary but two adjacent windows: a per-day breakdown of a
    /// week has to add up to the week, and a row stamped at exactly midnight is ordinary the moment a
    /// date picker defaults to it.
    @Test("Adjacent windows partition interruptions exactly once",
          arguments: StoreBackend.allCases)
    func adjacentWindowsPartitionInterruptions(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let midnight = Self.weekStart.addingTimeInterval(86_400)
        for offset in [-60.0, 0.0, 60.0] {
            try await harness.store.saveInterruption(
                Interruption(
                    description: "offset \(offset)",
                    timestamp: midnight.addingTimeInterval(offset)
                )
            )
        }

        let firstDay = DateInterval(start: Self.weekStart, end: midnight)
        let secondDay = DateInterval(start: midnight, end: midnight.addingTimeInterval(86_400))

        let first = try await harness.store.loadInterruptions(in: firstDay)
        let second = try await harness.store.loadInterruptions(in: secondDay)

        #expect(first.count == 1)
        #expect(second.count == 2)
        #expect(Set(first.map(\.id)).isDisjoint(with: Set(second.map(\.id))))
    }

    @Test("Interruptions load newest first, ties broken by id", arguments: StoreBackend.allCases)
    func interruptionOrderingIsStable(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let (lowID, highID) = lowIDFirst()
        let older = Interruption(description: "older", timestamp: at(10))
        let tiedLow = Interruption(id: lowID, description: "tied low id", timestamp: at(30))
        let tiedHigh = Interruption(id: highID, description: "tied high id", timestamp: at(30))

        for interruption in [older, tiedLow, tiedHigh] {
            try await harness.store.saveInterruption(interruption)
        }

        let loaded = try await harness.store.loadInterruptions(in: theHour)
        #expect(loaded.map(\.description) == ["tied high id", "tied low id", "older"])
    }

    /// The inbox is deliberately not date-bounded. An interruption captured on Friday and left
    /// unprocessed over the weekend is precisely the row that has to be waiting on Monday; a window
    /// would make the app quietly forget it.
    @Test("The inbox holds only pending interruptions, however old",
          arguments: StoreBackend.allCases)
    func pendingInterruptionsAreInboxOnlyAndNotDateBounded(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let longAgo = Self.nineAM.addingTimeInterval(-40 * 86_400)
        let stillPending = Interruption(description: "six weeks old", timestamp: longAgo)
        var converted = Interruption(description: "became a project", timestamp: at(10))
        converted.convert(toProjectID: UUID())
        var dismissed = Interruption(description: "decided against", timestamp: at(20))
        dismissed.dismiss()

        for interruption in [stillPending, converted, dismissed] {
            try await harness.store.saveInterruption(interruption)
        }

        let pending = try await harness.reopened().loadPendingInterruptions()
        #expect(pending.map(\.description) == ["six weeks old"])
    }

    @Test("Processing an interruption leaves the inbox without erasing the record",
          arguments: StoreBackend.allCases)
    func processingAnInterruptionKeepsIt(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let project = Project(name: "Receipt ingestion")
        try await harness.store.saveProject(project)

        var interruption = Interruption(description: "Duplicate receipts in prod", timestamp: at(15))
        try await harness.store.saveInterruption(interruption)
        interruption.convert(toProjectID: project.id)
        try await harness.store.saveInterruption(interruption)

        #expect(try await harness.store.loadPendingInterruptions().isEmpty)

        let history = try await harness.store.loadInterruptions(in: theHour)
        #expect(history.count == 1)
        #expect(history.first?.status == .converted)
        #expect(history.first?.convertedProjectID == project.id)
    }

    @Test("Deleting an interruption that is not there succeeds", arguments: StoreBackend.allCases)
    func deletingAbsentInterruptionIsIdempotent(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let interruption = Interruption(description: "Slack thread about the outage", timestamp: at(5))
        try await harness.store.saveInterruption(interruption)

        try await harness.store.deleteInterruption(id: UUID())
        #expect(try await harness.store.loadInterruptions(in: theHour).count == 1)

        try await harness.store.deleteInterruption(id: interruption.id)
        try await harness.store.deleteInterruption(id: interruption.id)
        #expect(try await harness.store.loadInterruptions(in: theHour).isEmpty)
    }

    /// A session is a container for time, not an owner of the notes taken during it. Deleting one
    /// must not take the interruptions with it, for the same reason deleting a project does not take
    /// the sessions.
    @Test("Deleting a session leaves the interruptions captured during it",
          arguments: StoreBackend.allCases)
    func deletingASessionKeepsItsInterruptions(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let session = FocusSession(intendedOutcome: "Dedup pass", startedAt: Self.nineAM)
        try await harness.store.saveSession(session)
        let interruption = Interruption(
            focusSessionID: session.id,
            description: "Pager went off",
            source: .incident,
            timestamp: at(12)
        )
        try await harness.store.saveInterruption(interruption)

        try await harness.store.deleteSession(id: session.id)

        let loaded = try await harness.store.loadInterruptions(in: theHour)
        #expect(loaded.count == 1)
        #expect(loaded.first?.description == "Pager went off")
    }

    // MARK: - Weekly outcomes

    @Test("A weekly outcome round trips and upserting it replaces rather than duplicates",
          arguments: StoreBackend.allCases)
    func weeklyOutcomeUpsertDoesNotDuplicate(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        var outcome = WeeklyOutcome(
            title: "Receipt deduplication in production",
            details: "Behind the flag is enough",
            priority: .primary,
            weekStartDate: Self.weekStart
        )
        try await harness.store.saveWeeklyOutcome(outcome)

        outcome.status = .inProgress
        outcome.progress = 0.5
        try await harness.store.saveWeeklyOutcome(outcome)

        let loaded = try await harness.reopened().loadWeeklyOutcomes(in: theWeek)
        #expect(loaded.count == 1)
        #expect(loaded.first == outcome)
        #expect(loaded.first?.status == .inProgress)
        #expect(loaded.first?.progressPercent == 50)
    }

    /// The week an outcome is *about*, not the day it was typed. Writing next week's outcomes down on
    /// Friday afternoon is the intended way to use the feature, and they must not turn up in this
    /// week's review because of when the row was created.
    @Test("Outcomes are filtered on the week they are for, not when they were created",
          arguments: StoreBackend.allCases)
    func outcomesFilterOnWeekStartNotCreatedAt(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let declaredOnFriday = Self.weekStart.addingTimeInterval(4 * 86_400)
        let thisWeek = WeeklyOutcome(
            title: "Ship the dedup pass",
            weekStartDate: Self.weekStart,
            createdAt: declaredOnFriday,
            updatedAt: declaredOnFriday
        )
        let planningAhead = WeeklyOutcome(
            title: "Draft the ingest rewrite proposal",
            weekStartDate: Self.weekStart.addingTimeInterval(7 * 86_400),
            createdAt: declaredOnFriday,
            updatedAt: declaredOnFriday
        )
        try await harness.store.saveWeeklyOutcome(thisWeek)
        try await harness.store.saveWeeklyOutcome(planningAhead)

        let current = try await harness.store.loadWeeklyOutcomes(in: theWeek)
        let ahead = try await harness.store.loadWeeklyOutcomes(in: nextWeek)

        #expect(current.map(\.title) == ["Ship the dedup pass"])
        #expect(ahead.map(\.title) == ["Draft the ingest rewrite proposal"])
    }

    /// Every outcome in a week carries the same `weekStartDate`, so the week alone cannot order them.
    @Test("Outcomes within one week order by when they were declared, then by id",
          arguments: StoreBackend.allCases)
    func outcomeOrderingIsStableWithinAWeek(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let (lowID, highID) = lowIDFirst()
        let monday = Self.weekStart
        let tuesday = Self.weekStart.addingTimeInterval(86_400)

        let declaredFirst = WeeklyOutcome(
            title: "declared Monday",
            weekStartDate: monday,
            createdAt: monday,
            updatedAt: monday
        )
        let tiedLow = WeeklyOutcome(
            id: lowID,
            title: "tied low id",
            weekStartDate: monday,
            createdAt: tuesday,
            updatedAt: tuesday
        )
        let tiedHigh = WeeklyOutcome(
            id: highID,
            title: "tied high id",
            weekStartDate: monday,
            createdAt: tuesday,
            updatedAt: tuesday
        )

        for outcome in [declaredFirst, tiedLow, tiedHigh] {
            try await harness.store.saveWeeklyOutcome(outcome)
        }

        let loaded = try await harness.store.loadWeeklyOutcomes(in: theWeek)
        #expect(loaded.map(\.title) == ["tied high id", "tied low id", "declared Monday"])
    }

    /// Deleting the week's declared intent must not delete the record of work done towards it. The
    /// reference goes; the session and the accomplishment stay, in full.
    @Test("Deleting an outcome keeps the work done towards it",
          arguments: StoreBackend.allCases)
    func deletingAnOutcomeKeepsTheWork(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let outcome = WeeklyOutcome(title: "Receipt dedup in production", weekStartDate: Self.weekStart)
        try await harness.store.saveWeeklyOutcome(outcome)

        var session = FocusSession(
            weeklyOutcomeID: outcome.id,
            intendedOutcome: "Split the dedup pass out of the ingest job",
            startedAt: Self.nineAM
        )
        session.finish(at: at(50), status: .completed)
        session.tangibleResult = "Opened PR #482"
        try await harness.store.saveSession(session)

        let accomplishment = Accomplishment(
            weeklyOutcomeID: outcome.id,
            type: .pullRequestOpened,
            title: "Opened PR #482",
            timestamp: at(50)
        )
        try await harness.store.saveAccomplishment(accomplishment)

        try await harness.store.deleteWeeklyOutcome(id: outcome.id)

        let store = harness.reopened()
        #expect(try await store.loadWeeklyOutcomes(in: theWeek).isEmpty)

        let loadedSession = try await store.loadSession(id: session.id)
        #expect(loadedSession?.weeklyOutcomeID == nil)
        #expect(loadedSession?.tangibleResult == "Opened PR #482")
        #expect(loadedSession?.resultStatus == .completed)

        let loadedAccomplishments = try await store.loadAccomplishments(in: theHour)
        #expect(loadedAccomplishments.count == 1)
        #expect(loadedAccomplishments.first?.weeklyOutcomeID == nil)
        #expect(loadedAccomplishments.first?.title == "Opened PR #482")
    }

    @Test("Deleting an outcome that is not there succeeds", arguments: StoreBackend.allCases)
    func deletingAbsentOutcomeIsIdempotent(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let outcome = WeeklyOutcome(title: "Ship the dedup pass", weekStartDate: Self.weekStart)
        try await harness.store.saveWeeklyOutcome(outcome)

        try await harness.store.deleteWeeklyOutcome(id: UUID())
        #expect(try await harness.store.loadWeeklyOutcomes(in: theWeek).count == 1)

        try await harness.store.deleteWeeklyOutcome(id: outcome.id)
        try await harness.store.deleteWeeklyOutcome(id: outcome.id)
        #expect(try await harness.store.loadWeeklyOutcomes(in: theWeek).isEmpty)
    }

    /// The store keeps every outcome it is given. The three-seat shape §8 describes is applied by
    /// `WeeklyOutcomeSet` when the week is read, so a fourth outcome is visible rather than lost.
    @Test("The store does not enforce the shape of a week", arguments: StoreBackend.allCases)
    func theStoreKeepsEveryOutcome(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        for index in 0..<4 {
            try await harness.store.saveWeeklyOutcome(
                WeeklyOutcome(
                    title: "Outcome \(index)",
                    priority: .primary,
                    weekStartDate: Self.weekStart,
                    createdAt: Self.weekStart.addingTimeInterval(Double(index) * 60),
                    updatedAt: Self.weekStart
                )
            )
        }

        let loaded = try await harness.store.loadWeeklyOutcomes(in: theWeek)
        #expect(loaded.count == 4)

        let seated = WeeklyOutcomeSet(weekStart: Self.weekStart, outcomes: loaded)
        #expect(seated.all.count == 4)
        #expect(seated.unseated.count == 1)
    }

    // MARK: - Classification rules

    /// No date applies to a rule, so no interval filters them and nothing sorts them: this is the
    /// list the rules editor shows, and a row must not move because the user edited it.
    @Test("Rules keep insertion order and an upsert replaces in place",
          arguments: StoreBackend.allCases)
    func rulesKeepInsertionOrder(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let first = ClassificationRule(
            matchType: .application, matchValue: "com.apple.dt.Xcode", category: .coding)
        var second = ClassificationRule(
            matchType: .browserDomain, matchValue: "github.com", category: .codeReview)
        let third = ClassificationRule(
            matchType: .browserDomain, matchValue: "meet.google.com", category: .meeting)

        for rule in [first, second, third] {
            try await harness.store.saveClassificationRule(rule)
        }

        second.priority = 5
        try await harness.store.saveClassificationRule(second)

        let loaded = try await harness.reopened().loadClassificationRules()
        #expect(loaded.map(\.matchValue) == ["com.apple.dt.Xcode", "github.com", "meet.google.com"])
        #expect(loaded.count == 3)
        #expect(loaded[1].priority == 5)
    }

    /// `SPEC.md` §5 ships a rule switched off, as a worked example the user can enable. If `isEnabled`
    /// did not survive a save, that rule would silently start classifying on the next launch.
    @Test("A rule the user switched off stays off", arguments: StoreBackend.allCases)
    func disabledRulesStayDisabled(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let rule = ClassificationRule(
            matchType: .windowTitleContains,
            matchValue: "swift test",
            category: .testing,
            isEnabled: false
        )
        try await harness.store.saveClassificationRule(rule)

        let loaded = try await harness.reopened().loadClassificationRules()
        #expect(loaded == [rule])
        #expect(loaded.first?.isEnabled == false)
    }

    /// A rule that also assigns a project is the shape SPEC's *"Claude → Research or Coding, depending
    /// on the active project"* resolves to, so the outcome half of a rule has to persist too.
    @Test("A rule that assigns a project round trips", arguments: StoreBackend.allCases)
    func ruleProjectAssignmentRoundTrips(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let project = Project(name: "Receipt ingestion")
        try await harness.store.saveProject(project)
        let rule = ClassificationRule(
            matchType: .project,
            matchValue: project.id.uuidString,
            category: .coding,
            projectID: project.id,
            priority: 3
        )
        try await harness.store.saveClassificationRule(rule)

        let loaded = try await harness.reopened().loadClassificationRules()
        #expect(loaded == [rule])
    }

    @Test("Deleting a rule that is not there succeeds", arguments: StoreBackend.allCases)
    func deletingAbsentRuleIsIdempotent(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let rule = ClassificationRule(
            matchType: .application, matchValue: "com.tinyspeck.slackmacgap",
            category: .communication)
        try await harness.store.saveClassificationRule(rule)

        try await harness.store.deleteClassificationRule(id: UUID())
        #expect(try await harness.store.loadClassificationRules().count == 1)

        try await harness.store.deleteClassificationRule(id: rule.id)
        try await harness.store.deleteClassificationRule(id: rule.id)
        #expect(try await harness.store.loadClassificationRules().isEmpty)
    }

    /// A store that substituted `ClassificationRule.defaults` for an empty result would make
    /// "delete every rule" impossible: the deleted rows would be back on the next read.
    @Test("An empty store has no rules rather than the shipped defaults",
          arguments: StoreBackend.allCases)
    func theStoreDoesNotSeedDefaults(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        #expect(try await harness.store.loadClassificationRules().isEmpty)

        for rule in ClassificationRule.defaults {
            try await harness.store.saveClassificationRule(rule)
        }
        for rule in ClassificationRule.defaults {
            try await harness.store.deleteClassificationRule(id: rule.id)
        }

        #expect(try await harness.reopened().loadClassificationRules().isEmpty)
    }

    // MARK: - Deleting a project

    /// Deleting a project clears the label and nothing else — across every collection that carries
    /// one, not just the two that had them in Phase 2.
    @Test("Deleting a project clears its label without deleting history",
          arguments: StoreBackend.allCases)
    func deletingAProjectClearsLabelsOnly(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let doomed = Project(name: "Receipt ingestion")
        let survivor = Project(name: "Ingest rewrite")
        try await harness.store.saveProject(doomed)
        try await harness.store.saveProject(survivor)

        var interruption = Interruption(
            description: "Duplicate receipts in prod",
            source: .incident,
            timestamp: at(15)
        )
        interruption.convert(toProjectID: doomed.id)
        try await harness.store.saveInterruption(interruption)

        let outcome = WeeklyOutcome(
            title: "Receipt dedup in production",
            weekStartDate: Self.weekStart,
            projectIDs: [doomed.id, survivor.id]
        )
        try await harness.store.saveWeeklyOutcome(outcome)

        try await harness.store.deleteProject(id: doomed.id)

        let store = harness.reopened()
        #expect(try await store.loadProjects().map(\.id) == [survivor.id])

        // Converting the interruption is what happened; only the label it was filed under is gone.
        let loadedInterruption = try await store.loadInterruptions(in: theHour).first
        #expect(loadedInterruption?.status == .converted)
        #expect(loadedInterruption?.convertedProjectID == nil)
        #expect(loadedInterruption?.description == "Duplicate receipts in prod")

        let loadedOutcome = try await store.loadWeeklyOutcomes(in: theWeek).first
        #expect(loadedOutcome?.projectIDs == [survivor.id])
        #expect(loadedOutcome?.title == "Receipt dedup in production")
    }

    // MARK: - Durability

    /// Every new collection has to reach the disk. Reading them back from a store that never saw the
    /// in-memory values is the only assertion that can tell "saved" from "still in a variable".
    @Test("All three new collections survive a reopen", arguments: StoreBackend.allCases)
    func newCollectionsSurviveAReopen(backend: StoreBackend) async throws {
        let harness = try StoreHarness(backend)
        defer { harness.tearDown() }

        let interruption = Interruption(
            description: "Omar asked about the rollout",
            source: .person,
            timestamp: at(20)
        )
        let outcome = WeeklyOutcome(
            title: "Receipt dedup in production",
            priority: .primary,
            status: .inProgress,
            progress: 0.25,
            weekStartDate: Self.weekStart
        )
        let rule = ClassificationRule(
            matchType: .browserDomain, matchValue: "github.com", category: .codeReview)

        try await harness.store.saveInterruption(interruption)
        try await harness.store.saveWeeklyOutcome(outcome)
        try await harness.store.saveClassificationRule(rule)

        let store = harness.reopened()
        #expect(try await store.loadInterruptions(in: theHour) == [interruption])
        #expect(try await store.loadPendingInterruptions() == [interruption])
        #expect(try await store.loadWeeklyOutcomes(in: theWeek) == [outcome])
        #expect(try await store.loadClassificationRules() == [rule])
    }
}

// MARK: - Schema compatibility

/// What happens when this build meets a document some other build wrote.
///
/// These use literal JSON rather than a round trip on purpose: a round trip only ever proves that
/// this build agrees with itself. The document a user already has on disk was written by the build
/// before this one, and the only way to test against it is to embed it.
@Suite("Store schema compatibility")
@MainActor
struct StoreSchemaCompatibilityTests {

    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)
    static let weekStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

    private var theDay: DateInterval {
        DateInterval(start: Self.weekStart, end: Self.weekStart.addingTimeInterval(86_400))
    }

    private var theWeek: DateInterval {
        DateInterval(start: Self.weekStart, end: Self.weekStart.addingTimeInterval(7 * 86_400))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreSchemaCompatibilityTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func quarantineFiles(in directory: URL) throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("store-corrupt-") }
    }

    /// A `store.json` exactly as the shipping build writes it: version 1, three collections, and no
    /// mention of the three that came later.
    private func versionOneDocument(
        projectID: UUID,
        sessionID: UUID,
        accomplishmentID: UUID
    ) -> String {
        """
        {
          "accomplishments" : [
            {
              "id" : "\(accomplishmentID.uuidString)",
              "projectID" : "\(projectID.uuidString)",
              "timestamp" : 727085400,
              "title" : "Reviewed the ingest PR",
              "type" : "pullRequestReviewed"
            }
          ],
          "projects" : [
            {
              "colorID" : "blue",
              "createdAt" : 727051200,
              "iconID" : "tray",
              "id" : "\(projectID.uuidString)",
              "isActive" : true,
              "name" : "Receipt ingestion",
              "updatedAt" : 727051200
            }
          ],
          "schemaVersion" : 1,
          "sessions" : [
            {
              "id" : "\(sessionID.uuidString)",
              "intendedOutcome" : "Finish the receipt deduplication PR",
              "interruptionCount" : 0,
              "isReactive" : false,
              "pausedDuration" : 0,
              "projectID" : "\(projectID.uuidString)",
              "startedAt" : 727083600,
              "workType" : "deepWork"
            }
          ]
        }
        """
    }

    @Test("A document written by the previous build still opens, with the new collections empty")
    func versionOneDocumentStillLoads() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let projectID = UUID()
        let sessionID = UUID()
        let accomplishmentID = UUID()
        try Data(
            versionOneDocument(
                projectID: projectID,
                sessionID: sessionID,
                accomplishmentID: accomplishmentID
            ).utf8
        ).write(to: url)

        let store = JSONFileStore(fileURL: url)

        #expect(try await store.loadProjects().map(\.name) == ["Receipt ingestion"])
        #expect(try await store.loadSessions(in: theDay).map(\.id) == [sessionID])
        #expect(try await store.loadAccomplishments(in: theDay).map(\.id) == [accomplishmentID])

        #expect(try await store.loadInterruptions(in: theDay).isEmpty)
        #expect(try await store.loadPendingInterruptions().isEmpty)
        #expect(try await store.loadWeeklyOutcomes(in: theWeek).isEmpty)
        #expect(try await store.loadClassificationRules().isEmpty)

        // Nothing was quarantined and nothing was refused: an ordinary open of an ordinary file.
        #expect(store.quarantineNotice == nil)
        #expect(try quarantineFiles(in: directory).isEmpty)
    }

    /// Opening an older document and then saving must upgrade it in place, keeping everything it
    /// already held. If the write kept version 1 while writing version 2 collections, the next build
    /// to read it would trust the number over the contents.
    @Test("Saving into an older document upgrades it without losing what it held")
    func savingUpgradesAVersionOneDocument() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let projectID = UUID()
        let sessionID = UUID()
        let accomplishmentID = UUID()
        try Data(
            versionOneDocument(
                projectID: projectID,
                sessionID: sessionID,
                accomplishmentID: accomplishmentID
            ).utf8
        ).write(to: url)

        let store = JSONFileStore(fileURL: url)
        try await store.saveWeeklyOutcome(
            WeeklyOutcome(title: "Receipt dedup in production", weekStartDate: Self.weekStart)
        )

        let root =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        #expect(root?["schemaVersion"] as? Int == 2)
        #expect(root?["interruptions"] != nil)
        #expect(root?["weeklyOutcomes"] != nil)
        #expect(root?["classificationRules"] != nil)

        let reopened = JSONFileStore(fileURL: url)
        #expect(try await reopened.loadProjects().map(\.id) == [projectID])
        #expect(try await reopened.loadSessions(in: theDay).map(\.id) == [sessionID])
        #expect(try await reopened.loadAccomplishments(in: theDay).map(\.id) == [accomplishmentID])
        #expect(try await reopened.loadWeeklyOutcomes(in: theWeek).count == 1)
    }

    @Test("A version 2 document decodes all three new collections")
    func versionTwoDocumentDecodesNewCollections() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let interruptionID = UUID()
        let outcomeID = UUID()
        let ruleID = UUID()
        let document = """
            {
              "accomplishments" : [],
              "classificationRules" : [
                {
                  "category" : "codeReview",
                  "id" : "\(ruleID.uuidString)",
                  "isEnabled" : false,
                  "matchType" : "browserDomain",
                  "matchValue" : "github.com",
                  "priority" : 2
                }
              ],
              "interruptions" : [
                {
                  "description" : "Omar asked about the rollout",
                  "id" : "\(interruptionID.uuidString)",
                  "source" : "person",
                  "status" : "inbox",
                  "timestamp" : 727084800
                }
              ],
              "projects" : [],
              "schemaVersion" : 2,
              "sessions" : [],
              "weeklyOutcomes" : [
                {
                  "createdAt" : 727051200,
                  "id" : "\(outcomeID.uuidString)",
                  "priority" : "primary",
                  "progress" : 0.25,
                  "projectIDs" : [],
                  "status" : "inProgress",
                  "title" : "Receipt dedup in production",
                  "updatedAt" : 727051200,
                  "weekStartDate" : 727051200
                }
              ]
            }
            """
        try Data(document.utf8).write(to: url)

        let store = JSONFileStore(fileURL: url)

        let interruptions = try await store.loadInterruptions(in: theDay)
        #expect(interruptions.map(\.id) == [interruptionID])
        #expect(interruptions.first?.source == .person)
        #expect(try await store.loadPendingInterruptions().map(\.id) == [interruptionID])

        let outcomes = try await store.loadWeeklyOutcomes(in: theWeek)
        #expect(outcomes.map(\.id) == [outcomeID])
        #expect(outcomes.first?.priority == .primary)
        #expect(outcomes.first?.progressPercent == 25)

        let rules = try await store.loadClassificationRules()
        #expect(rules.map(\.id) == [ruleID])
        #expect(rules.first?.isEnabled == false)
        #expect(rules.first?.matchType == .browserDomain)
    }

    /// A version this build has never heard of is intact data, not corrupt data. Refusing it leaves a
    /// file that updating Lggr opens completely; decoding it would drop every collection this build
    /// has no property for and write that loss back on the next save.
    @Test("A newer document is refused and left exactly where it was")
    func newerDocumentIsRefusedAndUntouched() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")

        let document = """
            {
              "accomplishments" : [],
              "classificationRules" : [],
              "interruptions" : [],
              "projects" : [],
              "schemaVersion" : \(StoreSnapshot.currentSchemaVersion + 1),
              "sessions" : [],
              "weeklyOutcomes" : [],
              "somethingThisBuildHasNeverHeardOf" : [ 1, 2, 3 ]
            }
            """
        let original = Data(document.utf8)
        try original.write(to: url)

        let store = JSONFileStore(fileURL: url)
        await #expect(throws: StoreError.self) {
            _ = try await store.loadInterruptions(in: theDay)
        }

        #expect(try Data(contentsOf: url) == original)
        #expect(try quarantineFiles(in: directory).isEmpty)
    }

    /// An empty snapshot has to encode every collection, including the new ones. A key that is
    /// missing on write is a key a reader has to guess about, and the version number stops being
    /// enough to tell the two formats apart.
    @Test("Every collection is written, even when empty")
    func everyCollectionIsWritten() throws {
        let data = try StoreSnapshot.makeEncoder().encode(StoreSnapshot())
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(root?.keys.sorted() == [
            "accomplishments",
            "classificationRules",
            "interruptions",
            "projects",
            "schemaVersion",
            "sessions",
            "weeklyOutcomes",
        ])
        #expect(root?["schemaVersion"] as? Int == StoreSnapshot.currentSchemaVersion)
    }

    @Test("A populated snapshot round trips unchanged across every collection")
    func populatedSnapshotRoundTrips() throws {
        let snapshot = StoreSnapshot(
            projects: [Project(name: "Receipt ingestion")],
            sessions: [FocusSession(intendedOutcome: "Morning block")],
            accomplishments: [Accomplishment(title: "Reviewed the ingest PR")],
            interruptions: [Interruption(description: "Omar asked about the rollout")],
            weeklyOutcomes: [
                WeeklyOutcome(title: "Receipt dedup in production", weekStartDate: Self.weekStart)
            ],
            classificationRules: ClassificationRule.defaults
        )

        let data = try StoreSnapshot.makeEncoder().encode(snapshot)
        let decoded = try StoreSnapshot.makeDecoder().decode(StoreSnapshot.self, from: data)

        #expect(decoded == snapshot)
    }
}
