import Foundation

public enum StoreError: Error, Sendable, Equatable {
    case notFound(UUID)
    case invalidData(String)
    case persistenceFailure(String)
}

/// Persistence for everything Lggr records.
///
/// One protocol rather than one per aggregate: there is only ever a single live backend
/// (`JSONFileStore` today, a SwiftData-backed store once Xcode is available) plus a single shared
/// fake, and none of the aggregates are ever composed independently. Seven protocols would multiply
/// types without ever being mixed and matched.
///
/// Every method is a whole-value upsert keyed by `id`, or a load. There is no partial-update API:
/// the domain owns complete values, so a caller mutates a value and saves it back. That keeps the
/// backends honest — neither one can develop its own idea of what a partial write means.
///
/// The protocol is `@MainActor` because a SwiftData `ModelContext` is main-actor bound, and `async`
/// throughout so a file-backed implementation can hop to a background actor to encode and write
/// without any call site changing.
///
/// **Deletes are idempotent.** Deleting an id that is not present succeeds and does nothing; no
/// conformer may throw `notFound` from a delete. The caller's intent is that the record should not
/// exist, and after the call it does not. Reporting an error would mean a user who deletes a row
/// twice, or deletes from a list rendered before another change landed, sees a failure for an
/// operation that achieved exactly what they asked for.
///
/// **Deleting a parent never cascades into history.** Removing a project or a weekly outcome clears
/// the reference on the rows that pointed at it and leaves those rows otherwise untouched. A record
/// of work done is not the label's to take away.
///
/// Activity samples are the one thing that is not here: they arrive thousands of times a day and are
/// pruned by date, so they live in `ActivityLog`, one append-only file per day, rather than inside a
/// document that is rewritten whole on every save.
@MainActor
public protocol LggrStore: AnyObject {

    // MARK: - Projects

    func loadProjects() async throws -> [Project]
    func saveProject(_ project: Project) async throws
    /// Deleting a project never cascades. Sessions and accomplishments that referenced it keep their
    /// history and have their `projectID` cleared, because a record of work done is not the
    /// project's to take away.
    func deleteProject(id: UUID) async throws

    // MARK: - Focus sessions

    /// Sessions whose `startedAt` falls inside `interval`, newest first.
    func loadSessions(in interval: DateInterval) async throws -> [FocusSession]
    func loadSession(id: UUID) async throws -> FocusSession?
    /// The most recent session that never ended, used to restore state after a relaunch or a crash.
    func loadActiveSession() async throws -> FocusSession?
    /// The most recent session that ended but was never reviewed.
    ///
    /// Finishing a session and quitting before answering "What happened?" is ordinary behaviour —
    /// the sheet appears exactly when someone is getting up from their desk. Without this the
    /// session is stranded: it has an `endedAt`, so `loadActiveSession` will not return it, and
    /// nothing else ever offers it for review again.
    func loadUnreviewedSession() async throws -> FocusSession?
    func saveSession(_ session: FocusSession) async throws
    func deleteSession(id: UUID) async throws

    // MARK: - Accomplishments

    /// Accomplishments whose `timestamp` falls inside `interval`, newest first.
    func loadAccomplishments(in interval: DateInterval) async throws -> [Accomplishment]
    func saveAccomplishment(_ accomplishment: Accomplishment) async throws
    func deleteAccomplishment(id: UUID) async throws

    // MARK: - Interruptions

    /// Interruptions whose `timestamp` falls inside `interval`, newest first.
    func loadInterruptions(in interval: DateInterval) async throws -> [Interruption]
    /// Every interruption still in the inbox, newest first, whenever it was captured.
    ///
    /// Not date-bounded, and deliberately so. The inbox is the one list whose whole purpose is that
    /// nothing falls out of it: an interruption captured on Friday and not processed before the
    /// weekend is exactly the row the user needs to see on Monday, and a window would hide it. The
    /// list is bounded in practice by the user emptying it, not by the calendar.
    func loadPendingInterruptions() async throws -> [Interruption]
    func saveInterruption(_ interruption: Interruption) async throws
    func deleteInterruption(id: UUID) async throws

    // MARK: - Weekly outcomes

    /// Outcomes whose `weekStartDate` falls inside `interval`, newest week first.
    ///
    /// Filtering on `weekStartDate` rather than on `createdAt` is what makes an outcome declared on
    /// Wednesday still belong to the week it is about, and what lets next week's outcomes be written
    /// down on Friday afternoon without appearing in this week's review.
    func loadWeeklyOutcomes(in interval: DateInterval) async throws -> [WeeklyOutcome]
    func saveWeeklyOutcome(_ outcome: WeeklyOutcome) async throws
    /// Deleting an outcome never cascades. Sessions and accomplishments filed under it keep their
    /// history and have their `weeklyOutcomeID` cleared.
    func deleteWeeklyOutcome(id: UUID) async throws

    // MARK: - Classification rules

    /// Every stored rule, in the order it was added.
    ///
    /// No date applies to a rule, and no interval filters them. Insertion order is preserved rather
    /// than sorted: this is the list the rules editor shows, and a row must not move because the user
    /// renamed it. Which rule *wins* is a separate question that `ClassificationEngine` answers from
    /// `priority` and `matchType`, so the store never encodes an evaluation order of its own.
    ///
    /// An empty result means the user has no rules, not that Lggr has none: seeding
    /// `ClassificationRule.defaults` on first launch belongs to bootstrap, because a store that
    /// substituted the defaults for an empty set would make "delete every rule" impossible.
    func loadClassificationRules() async throws -> [ClassificationRule]
    func saveClassificationRule(_ rule: ClassificationRule) async throws
    func deleteClassificationRule(id: UUID) async throws
}
