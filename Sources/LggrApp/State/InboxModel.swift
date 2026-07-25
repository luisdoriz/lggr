import Foundation
import LggrKit

// The interruption inbox: what happens after ⌘⇧I. See SPEC.md § 3 and § 7, 04-screens.md § 5.4.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHY THIS OBJECT EXISTS AT ALL
//
//  Capture is the cheap half. Something arrives, one line is written down, the session keeps
//  running. The expensive half is everything after: a list that only ever grows is a guilt pile,
//  and a guilt pile is the reason people stop capturing. So this object is built around three
//  properties, in order of how easily they are lost:
//
//    1. **Capture cannot fail silently.** The write is awaited and reports a Bool. The capture
//       panel keeps the user's sentence on screen until the write actually landed
//       (`04-screens.md` § 5.4's error rule), because retyping it is the one cost that would make
//       people stop.
//    2. **Processing is one action per row.** Convert to a session, log what it turned into, file
//       it under a project, or dismiss it. Four verbs, each of which empties the row.
//    3. **Dismissing is reversible and is not a failure.** `InterruptionStatus.dismissed` is
//       documented in `LggrKit` as an outcome, not a defeat — "deciding something does not need
//       doing is an outcome" — so every processed row stays in `processed` for the rest of the
//       session and can be put back. There is no confirmation dialogue: a decision you can undo
//       does not need to be defended first.
//
//  Interface first, disk second — the same rule `SessionManager` follows. Every mutation moves the
//  list in memory, then persists; a failed write puts the row back where it was and states one
//  sentence. Nothing here throws and nothing here crashes: losing the ability to record work is
//  worse than any error.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// The parts of a running session the inbox needs, as three functions.
///
/// A value of closures rather than a reference to `SessionManager` for the same reason
/// `TrackingControls` is: it lets the inbox be exercised, and rendered in the gallery, with no
/// session machinery at all — and it keeps the one piece of session *state* the inbox is allowed to
/// touch (`interruptionCount`) behind the object that owns it.
@MainActor
public struct InboxSessionContext {

    /// The session that is running right now, so a capture is filed against it. `nil` outside a
    /// session, which is a supported case: `⌘⇧I` is never unavailable (`04-screens.md` § 5.4).
    public var activeSessionID: () -> UUID?

    /// Increments the running session's `interruptionCount`. Called only when a capture landed.
    public var noteInterruption: () -> Void

    /// Starts a focus session on the interruption's own words.
    public var startSession: (StartSessionRequest) -> Void

    /// Files an accomplishment the interruption turned into.
    public var logAccomplishment: (Accomplishment) -> Void

    public init(
        activeSessionID: @escaping () -> UUID? = { nil },
        noteInterruption: @escaping () -> Void = {},
        startSession: @escaping (StartSessionRequest) -> Void = { _ in },
        logAccomplishment: @escaping (Accomplishment) -> Void = { _ in }
    ) {
        self.activeSessionID = activeSessionID
        self.noteInterruption = noteInterruption
        self.startSession = startSession
        self.logAccomplishment = logAccomplishment
    }

    /// The real thing.
    public static func live(
        manager: SessionManager,
        startSession: @escaping (StartSessionRequest) -> Void
    ) -> InboxSessionContext {
        InboxSessionContext(
            activeSessionID: { manager.activeSession?.id },
            noteInterruption: { manager.noteInterruption() },
            startSession: startSession,
            logAccomplishment: { accomplishment in
                Task { await manager.addAccomplishment(accomplishment) }
            }
        )
    }

    /// Nothing is wired: no session, no start, no log. Capture still works — it saves with
    /// `focusSessionID == nil`, which is exactly what a capture outside a session is.
    public static let detached = InboxSessionContext()
}

/// Everything the interruption inbox holds, and the only writer of it.
@MainActor
@Observable
public final class InboxModel {

    // MARK: - Published state

    /// Everything still waiting, newest first. Not date-bounded — see
    /// `LggrStore.loadPendingInterruptions()`: the inbox is the one list whose whole purpose is that
    /// nothing falls out of it.
    public private(set) var pending: [Interruption] = []

    /// Rows processed since the app launched, newest first.
    ///
    /// Held in memory rather than re-read, because its only job is `Put back` — regret happens
    /// within seconds of the decision, and a "Processed" list that survived a relaunch would be a
    /// second inbox with none of the first one's purpose.
    public private(set) var processed: [Interruption] = []

    /// One plain sentence about the last failed write. Never a code, never a stack trace.
    public private(set) var failure: String?

    /// True once the first load has come back, so a screen can tell "empty" from "not read yet".
    public private(set) var hasLoaded = false

    public var pendingCount: Int { pending.count }

    // MARK: - Collaborators

    @ObservationIgnored private let store: any LggrStore
    @ObservationIgnored private let clock: any DateProviding

    /// Assignable so the composition root can hand over the session manager after both exist.
    @ObservationIgnored public var session: InboxSessionContext

    public init(
        store: any LggrStore,
        clock: any DateProviding = SystemClock(),
        // Optional rather than defaulted to `.detached`: a default argument is evaluated in a
        // nonisolated context and `InboxSessionContext` is main-actor isolated.
        session: InboxSessionContext? = nil
    ) {
        self.store = store
        self.clock = clock
        self.session = session ?? .detached
    }

    // MARK: - Loading

    public func load() async {
        do {
            pending = try await store.loadPendingInterruptions()
            failure = nil
        } catch {
            failure = "Couldn't load your inbox. Nothing has been lost."
        }
        hasLoaded = true
    }

    // MARK: - Capture

    /// Writes one captured line down and files it against whatever session is running.
    ///
    /// - Returns: whether it is on disk. `false` keeps the capture panel open with the text intact;
    ///   the panel never clears a sentence it has not saved.
    ///
    /// The running session is untouched apart from its `interruptionCount`. Nothing here pauses,
    /// finishes or otherwise disturbs it — that is the entire point of the feature.
    @discardableResult
    public func capture(_ text: String, source: InterruptionSource = .other) async -> Bool {
        let interruption = Interruption(
            focusSessionID: session.activeSessionID(),
            description: text,
            source: source,
            timestamp: clock.now
        )
        guard let normalized = interruption.normalizedDescription else { return false }

        var record = interruption
        record.description = normalized

        do {
            try await store.saveInterruption(record)
        } catch {
            failure = Self.saveFailure
            return false
        }

        pending.insert(record, at: 0)
        failure = nil
        // Only after the write. A count that climbed on a failed capture would describe a session
        // by an interruption that was never recorded.
        if record.interruptedASession { session.noteInterruption() }
        return true
    }

    // MARK: - Processing

    /// Turns the row into a running focus session on its own words, and marks it converted.
    ///
    /// The work type comes from the source, so the session is reactive by construction
    /// (`WorkType.isReactiveByDefault`) — work that arrived rather than work that was chosen, which
    /// is the distinction the weekly review is built on.
    public func convertToSession(_ interruption: Interruption, projectID: UUID? = nil) async {
        let workType = Self.workType(for: interruption.source)
        session.startSession(
            StartSessionRequest(
                projectID: projectID,
                intendedOutcome: interruption.description,
                workType: workType,
                plannedDuration: workType.suggestedDuration
            )
        )
        await settle(interruption) { $0.convert(toProjectID: projectID) }
    }

    /// The accomplishment this interruption became, pre-filled for the editor.
    ///
    /// The model produces the seed and does not save it: the user still gets to say what kind of
    /// thing it was, and a row filed as "Other" because nobody asked is a row nobody trusts.
    public func accomplishmentSeed(for interruption: Interruption) -> Accomplishment {
        Accomplishment(
            projectID: interruption.convertedProjectID,
            type: Self.accomplishmentType(for: interruption.source),
            title: interruption.description,
            timestamp: clock.now
        )
    }

    /// Files an accomplishment the row turned into, and marks the row converted.
    public func convertToAccomplishment(
        _ interruption: Interruption,
        accomplishment: Accomplishment
    ) async {
        session.logAccomplishment(accomplishment)
        await settle(interruption) { $0.convert(toProjectID: accomplishment.projectID) }
    }

    /// Files the row under a project without starting anything: it was dealt with inside that work.
    public func fileUnderProject(_ interruption: Interruption, projectID: UUID?) async {
        await settle(interruption) { $0.convert(toProjectID: projectID) }
    }

    /// Takes the row out of the inbox without turning it into tracked work.
    ///
    /// Deliberately not called "ignore" and deliberately not confirmed. `LggrKit` documents this
    /// status as an outcome — handled, or decided against — and it is reversible for as long as the
    /// app is running.
    public func dismiss(_ interruption: Interruption) async {
        await settle(interruption) { $0.dismiss() }
    }

    /// Puts a processed row back. The one undo the inbox needs.
    public func returnToInbox(_ interruption: Interruption) async {
        var record = interruption
        record.returnToInbox()

        processed.removeAll { $0.id == record.id }
        pending.removeAll { $0.id == record.id }
        pending.insert(record, at: 0)
        pending.sort { $0.timestamp > $1.timestamp }

        do {
            try await store.saveInterruption(record)
            failure = nil
        } catch {
            failure = Self.saveFailure
            pending.removeAll { $0.id == record.id }
            processed.insert(interruption, at: 0)
        }
    }

    /// Removes the record entirely. Offered because a capture can be a typo, and a typo is the one
    /// thing in this list that is genuinely not evidence of anything.
    public func delete(_ interruption: Interruption) async {
        let index = pending.firstIndex { $0.id == interruption.id }
        pending.removeAll { $0.id == interruption.id }
        processed.removeAll { $0.id == interruption.id }

        do {
            try await store.deleteInterruption(id: interruption.id)
            failure = nil
        } catch {
            failure = "Couldn't remove that yet — try again."
            pending.insert(interruption, at: min(index ?? 0, pending.count))
        }
    }

    public func clearFailure() {
        failure = nil
    }

    // MARK: - Transitions

    /// One path for every "this row is done" transition: move it, write it, and put it back if the
    /// write failed. Keeping them in one place is what stops `status` and `convertedProjectID` from
    /// drifting apart across four call sites.
    private func settle(
        _ interruption: Interruption,
        _ transition: (inout Interruption) -> Void
    ) async {
        var record = interruption
        transition(&record)

        let index = pending.firstIndex { $0.id == record.id }
        pending.removeAll { $0.id == record.id }
        processed.removeAll { $0.id == record.id }
        processed.insert(record, at: 0)

        do {
            try await store.saveInterruption(record)
            failure = nil
        } catch {
            failure = Self.saveFailure
            processed.removeAll { $0.id == record.id }
            pending.insert(interruption, at: min(index ?? 0, pending.count))
        }
    }

    // MARK: - Mappings

    private static let saveFailure = "Couldn't save that yet — try again."

    /// Source → work type. Every one of these is reactive by default, which is correct: an
    /// interruption is the definition of work that arrived.
    static func workType(for source: InterruptionSource) -> WorkType {
        switch source {
        case .person, .message, .notification, .email: .communication
        case .meeting: .meeting
        case .incident: .incident
        case .other: .administrative
        }
    }

    /// Source → the most likely kind of accomplishment, as a starting point the user can change.
    ///
    /// `.person` maps to *Person unblocked* because that is what being interrupted by a colleague
    /// usually turns into, and it is exactly the work that otherwise leaves no trace.
    static func accomplishmentType(for source: InterruptionSource) -> AccomplishmentType {
        switch source {
        case .person: .personUnblocked
        case .incident: .incidentResolved
        case .meeting: .decisionMade
        case .message, .email, .notification, .other: .other
        }
    }
}
