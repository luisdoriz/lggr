import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing rather than decoration, for the reason its twins in
/// `SessionAutoCloseTests` and `SessionEditingTests` give: `#expect` compares an `Optional<Double>`
/// against an integer-literal expression by type as well as by value, so `41 * 60` fails against an
/// identical `Double`.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// Labelling a block the app reconstructed is the gesture that makes Lggr tolerate a normal human, and
/// it is also the one place where a record appears that nobody watched being made. Every claim it
/// makes is pinned here rather than left to the sheet.
///
/// The suite is organised around the three decisions `SessionFromEpisode` records in its own header,
/// plus the two ways this feature could do harm: counting time twice, and quietly inflating the
/// planned side of the one analysis the product exists to produce.
@Suite("Session from a reconstructed block")
struct SessionFromEpisodeTests {

    /// 2024-01-15 09:00:00 UTC — the same instant `SessionClockTests`, `SessionEditingTests` and
    /// `SessionAutoCloseTests` use, so a failure in any of them reads against one wall clock.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)

    /// When the label is applied: 16:00, seven hours after the block began. Deliberately far from the
    /// block, because "labelled this afternoon" is the ordinary case and the arithmetic must not care.
    static let fourPM = nineAM.addingTimeInterval(minutes(420))

    private static func at(_ offsetMinutes: Double) -> Date {
        nineAM.addingTimeInterval(offsetMinutes * 60)
    }

    /// A block from 09:00 to 09:50 with 41 minutes measured in two applications.
    ///
    /// Nine idle minutes inside a fifty-minute span, on purpose: the gap between the wall clock and
    /// the measurement is what the session has to record as paused rather than as focus, and a fixture
    /// with none of it would let that go untested.
    private static func block(
        start: Double = 0,
        end: Double = 50,
        active: TimeInterval = minutes(41),
        sessionID: UUID? = nil
    ) -> Episode {
        Episode(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000E1") ?? UUID(),
            start: at(start),
            end: at(end),
            apps: [
                Episode.AppShare(
                    bundleIdentifier: "com.apple.dt.Xcode",
                    displayName: "Xcode",
                    duration: active * 0.75,
                    visitCount: 12
                ),
                Episode.AppShare(
                    bundleIdentifier: "com.apple.Terminal",
                    displayName: "Terminal",
                    duration: active * 0.25,
                    visitCount: 9
                ),
            ],
            interjections: 3,
            label: "Xcode, Terminal",
            labelConfidence: .appRoster,
            sessionID: sessionID,
            intervalCount: 34
        )
    }

    private static let label = SessionFromEpisode.Label(
        intendedOutcome: "Finish the receipt deduplication PR",
        workType: .deepWork
    )

    /// A finished session over an arbitrary span.
    private static func session(from: Double, to: Double?) -> FocusSession {
        FocusSession(
            intendedOutcome: "Something already declared",
            startedAt: at(from),
            endedAt: to.map(at)
        )
    }

    private func expectSuccess(
        _ result: Result<SessionFromEpisode.Reconstruction, SessionFromEpisode.Refusal>
    ) throws -> SessionFromEpisode.Reconstruction {
        switch result {
        case .success(let value): return value
        case .failure(let refusal):
            Issue.record("Expected a session, got \(refusal).")
            throw refusal
        }
    }

    // MARK: - The measured bounds are the session's bounds

    @Suite("The times are the block's, not the moment of labelling")
    struct Bounds {

        @Test("The session starts and ends exactly where the block was measured")
        func boundsAreTheBlocks() throws {
            let episode = SessionFromEpisodeTests.block()
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: episode,
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.startedAt == episode.start)
            #expect(made.session.endedAt == episode.end)
        }

        /// The instant the label was applied is nowhere in the recorded times. A session that ended at
        /// four o'clock because that is when somebody typed would be exactly the wrong-number-nobody-
        /// watched failure the whole design is arranged around.
        @Test("The instant the label was applied never reaches the recorded times")
        func labellingInstantIsNotATime() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.endedAt != SessionFromEpisodeTests.fourPM)
            #expect(made.session.reconstructedAt == SessionFromEpisodeTests.fourPM)
        }

        /// Idle time inside the block becomes paused time, so the session reports the figure Lggr
        /// measured rather than the wall clock it sat inside.
        @Test("Idle minutes are recorded as paused, never as focus")
        func idleBecomesPaused() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.pausedDuration == minutes(9))
            #expect(made.session.effectiveDuration == minutes(41))
            #expect(made.claim.idleWithheld == minutes(9))
        }

        /// No target. Nobody set one, and recording the measured length as a plan would manufacture an
        /// intent that was met exactly, on every reconstructed session ever written.
        @Test("A reconstructed session has no planned duration")
        func noPlannedDuration() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.plannedDuration == nil)
        }

        @Test("The user's three fields are carried over, trimmed")
        func labelIsCarried() throws {
            let project = UUID()
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisode.Label(
                        intendedOutcome: "   Rebuild the ingest queue \n",
                        projectID: project,
                        workType: .codeReview
                    ),
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.intendedOutcome == "Rebuild the ingest queue")
            #expect(made.session.projectID == project)
            #expect(made.session.workType == .codeReview)
        }
    }

    // MARK: - Decision 1: provenance

    @Suite("Provenance: labelled afterwards is not declared, and is not an edit")
    struct Provenance {

        private func made() throws -> FocusSession {
            try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            ).session
        }

        /// The decision recorded at the top of `SessionFromEpisode`: these times were observed, so the
        /// app must not claim the user typed them.
        @Test("editedAt is not set — nobody typed these times")
        func doesNotClaimAHandEdit() throws {
            let session = try made()
            #expect(session.editedAt == nil)
            #expect(session.wasEdited == false)
        }

        /// Nor is it the app's own arithmetic. `autoClosedAt` means Lggr chose an end; here Lggr chose
        /// nothing — it measured both bounds while the user worked.
        @Test("autoClosedAt is not set either — the app chose no time here")
        func doesNotClaimAnAutoClose() throws {
            let session = try made()
            #expect(session.autoClosedAt == nil)
            #expect(session.autoCloseReason == nil)
        }

        @Test("provenance is derived from reconstructedAt and says which it is")
        func provenanceIsDerived() throws {
            let session = try made()
            #expect(session.wasReconstructed)
            #expect(session.provenance == .reconstructed)
            #expect(session.provenance.statesIntent == false)

            let declared = FocusSession(intendedOutcome: "Declared in advance")
            #expect(declared.provenance == .declared)
            #expect(declared.provenance.statesIntent)
            #expect(declared.wasReconstructed == false)
        }

        /// `INTELLIGENCE.md` §4 Phase 2, and the reason the field exists: reconstruction may only ever
        /// add reactive time. A deep-work block whose type defaults to planned is still reactive,
        /// because the reaction is the labelling.
        @Test("Reconstruction is always reactive, whatever the work type's default says")
        func alwaysReactive() throws {
            #expect(WorkType.deepWork.isReactiveByDefault == false)

            for workType in WorkType.allCases {
                let made = try SessionFromEpisodeTests().expectSuccess(
                    SessionFromEpisode.session(
                        for: SessionFromEpisodeTests.block(),
                        label: SessionFromEpisode.Label(
                            intendedOutcome: "Whatever this was",
                            workType: workType
                        ),
                        at: SessionFromEpisodeTests.fourPM
                    )
                )
                #expect(made.session.isReactive, "\(workType) should still be reactive")
                #expect(PlannedVsReactive.origin(of: made.session) == .arrived)
            }
        }

        /// The same rule one field further down: attaching a weekly outcome would file the block as
        /// work committed to in advance, which is the conflation the whole decision exists to prevent.
        @Test("No weekly outcome is ever attached")
        func neverCommitted() throws {
            let session = try made()
            #expect(session.weeklyOutcomeID == nil)
        }

        /// `INTELLIGENCE.md` §4 Phase 2, acceptance criterion 2, as an assertion: reconstruction adds
        /// reactive time and moves the planned side by nothing at all.
        @Test("Planned time is unchanged by any amount of labelling")
        func plannedTimeIsUntouched() throws {
            let declared = FocusSession(
                intendedOutcome: "Declared",
                workType: .deepWork,
                startedAt: SessionFromEpisodeTests.at(120),
                endedAt: SessionFromEpisodeTests.at(180)
            )
            let before = PlannedVsReactive(sessions: [declared])

            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )
            let after = PlannedVsReactive(sessions: [declared, made.session])

            #expect(after.plannedDuration == before.plannedDuration)
            #expect(after.committedDuration == before.committedDuration)
            #expect(after.reactiveDuration == minutes(41))
        }

        /// The app forcing `isReactive` is the app's policy, not evidence that the user disagreed with
        /// a default. Counting it would make the number climb every time somebody labelled a block.
        @Test("Forcing isReactive does not count as the user overriding a default")
        func doesNotInflateTheOverrideCount() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisode.Label(
                        intendedOutcome: "Deep work, labelled afterwards",
                        workType: .deepWork
                    ),
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(PlannedVsReactive(sessions: [made.session]).overriddenSessionCount == 0)

            // A declared session that really does disagree with its default is still counted, so the
            // guard narrows the number rather than emptying it.
            let overridden = FocusSession(
                intendedOutcome: "Chosen incident work",
                workType: .incident,
                startedAt: SessionFromEpisodeTests.at(200),
                endedAt: SessionFromEpisodeTests.at(230),
                isReactive: false
            )
            #expect(PlannedVsReactive(sessions: [overridden]).overriddenSessionCount == 1)
        }
    }

    // MARK: - Decision 2: it lands answered

    @Suite("It is complete in one gesture and never joins a review queue")
    struct Landing {

        @Test("It lands with a result, so it is completed rather than awaiting review")
        func landsAnswered() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.resultStatus == .madeProgress)
            #expect(made.session.state == .completed)
            #expect(made.session.isFinished)
        }

        /// The two consequences the status was chosen for, asserted through the properties the rest of
        /// the app reads rather than through the case name — so swapping the constant to `.completed`
        /// fails here, in the place that explains why it must not be.
        @Test("It counts as neither completed nor interrupted, and needs no follow-up")
        func staysOutOfTheWeeklyCounts() {
            let status = SessionFromEpisode.resultStatus
            #expect(status.countsAsCompleted == false)
            #expect(status.countsAsInterrupted == false)
            #expect(status.needsFollowUp == false)
        }

        /// A generated sentence on a record nobody reviewed is one more thing to read, and the block's
        /// evidence is already on the timeline one row above.
        @Test("No summary is generated")
        func noSummary() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )
            #expect(made.session.resultSummary == nil)
            #expect(made.session.tangibleResult == nil)
        }
    }

    // MARK: - Decision 3: overlap

    @Suite("Overlap is trimmed, and time is never counted twice")
    struct Overlap {

        /// The everyday partial case: the user declared the last twenty minutes and worked the first
        /// thirty without saying so. The label takes the thirty and leaves the twenty alone.
        @Test("A session over the tail trims the claim to the head")
        func trimsToTheHead() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    existingSessions: [SessionFromEpisodeTests.session(from: 30, to: 60)],
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.startedAt == SessionFromEpisodeTests.at(0))
            #expect(made.session.endedAt == SessionFromEpisodeTests.at(30))
            #expect(made.claim.overlapRemoved == minutes(20))
            #expect(made.claim.wasTrimmed)
        }

        @Test("A session over the head trims the claim to the tail")
        func trimsToTheTail() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    existingSessions: [SessionFromEpisodeTests.session(from: -30, to: 20)],
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.startedAt == SessionFromEpisodeTests.at(20))
            #expect(made.session.endedAt == SessionFromEpisodeTests.at(50))
            #expect(made.claim.overlapRemoved == minutes(20))
        }

        /// One gesture writes one record. A session in the middle leaves two free stretches; the longer
        /// one is claimed and the shorter is reported rather than silently kept or silently lost.
        @Test("A session in the middle claims the longer remainder and reports the other")
        func claimsTheLongerRemainder() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    existingSessions: [SessionFromEpisodeTests.session(from: 10, to: 20)],
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            // 09:20–09:50 is thirty minutes; 09:00–09:10 is ten.
            #expect(made.session.startedAt == SessionFromEpisodeTests.at(20))
            #expect(made.session.endedAt == SessionFromEpisodeTests.at(50))
            #expect(made.claim.overlapRemoved == minutes(10))
            #expect(made.claim.fragmentsDropped == minutes(10))
        }

        /// The property that matters more than any particular trim: whatever the arrangement, the new
        /// session's span shares no instant with a session that already exists.
        @Test("No claimed span ever overlaps an existing session")
        func neverDoubleCounts() throws {
            let arrangements: [[FocusSession]] = [
                [SessionFromEpisodeTests.session(from: 30, to: 60)],
                [SessionFromEpisodeTests.session(from: -30, to: 20)],
                [SessionFromEpisodeTests.session(from: 10, to: 20)],
                [
                    SessionFromEpisodeTests.session(from: 5, to: 10),
                    SessionFromEpisodeTests.session(from: 40, to: 45),
                ],
            ]

            for existing in arrangements {
                let made = try SessionFromEpisodeTests().expectSuccess(
                    SessionFromEpisode.session(
                        for: SessionFromEpisodeTests.block(),
                        label: SessionFromEpisodeTests.label,
                        existingSessions: existing,
                        at: SessionFromEpisodeTests.fourPM
                    )
                )
                for session in existing {
                    let overlap =
                        min(session.endedAt ?? .distantFuture, made.session.endedAt ?? .distantFuture)
                        .timeIntervalSince(max(session.startedAt, made.session.startedAt))
                    #expect(overlap <= 0, "claimed span overlaps \(session.startedAt)")
                }
            }
        }

        /// A block wholly inside a session is refused. Nothing is written, and the sentence says which
        /// fact the record already holds rather than what the user should have done.
        @Test("A block a session already covers is refused, not written")
        func refusesFullCover() {
            let refusal = SessionFromEpisode.claim(
                for: SessionFromEpisodeTests.block(),
                existingSessions: [SessionFromEpisodeTests.session(from: -10, to: 60)]
            )

            guard case .failure(let reason) = refusal else {
                Issue.record("A fully covered block must be refused.")
                return
            }
            #expect(reason == .alreadyAccounted(remaining: 0))
            #expect(reason.isCoveredByASession)
            #expect(reason.sentence.contains("already account"))
        }

        /// A session left running has no end and this function has no clock, so it claims everything
        /// from its start onwards. Under-claiming is the only acceptable failure direction.
        @Test("A running session claims the rest of the block")
        func runningSessionCoversTheRest() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    existingSessions: [SessionFromEpisodeTests.session(from: 25, to: nil)],
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.session.endedAt == SessionFromEpisodeTests.at(25))
        }

        /// A sliver is not a session. The floor exists so that a block all but covered by declared work
        /// does not become a forty-second record with a typed sentence attached to it.
        @Test("A remainder shorter than the floor is refused")
        func refusesASliver() {
            let refusal = SessionFromEpisode.claim(
                for: SessionFromEpisodeTests.block(),
                existingSessions: [SessionFromEpisodeTests.session(from: 0.5, to: 60)]
            )

            guard case .failure(let reason) = refusal else {
                Issue.record("A thirty-second remainder must be refused.")
                return
            }
            #expect(reason == .alreadyAccounted(remaining: 30))
        }

        /// Sessions elsewhere in the day are not overlap, and must not shrink anything.
        @Test("Sessions that do not touch the block change nothing")
        func untouchedByDistantSessions() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    existingSessions: [
                        SessionFromEpisodeTests.session(from: 120, to: 180),
                        SessionFromEpisodeTests.session(from: -180, to: -120),
                    ],
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            #expect(made.claim.wasTrimmed == false)
            #expect(made.claim.overlapRemoved == 0)
            #expect(made.session.effectiveDuration == minutes(41))
        }

        /// The same block and the same sessions produce the same session every time. A reconstruction
        /// that differed between two runs over identical evidence would be indistinguishable from a bug
        /// in a product whose whole claim is that days are reproducible.
        @Test("Two equal remainders resolve to the earlier one, deterministically")
        func tieGoesToTheEarlier() throws {
            // 09:00–09:20 and 09:30–09:50: two twenty-minute stretches either side of a session.
            let existing = [SessionFromEpisodeTests.session(from: 20, to: 30)]
            for _ in 0..<5 {
                let made = try SessionFromEpisodeTests().expectSuccess(
                    SessionFromEpisode.session(
                        for: SessionFromEpisodeTests.block(),
                        label: SessionFromEpisodeTests.label,
                        existingSessions: existing,
                        at: SessionFromEpisodeTests.fourPM
                    )
                )
                #expect(made.session.startedAt == SessionFromEpisodeTests.at(0))
                #expect(made.session.endedAt == SessionFromEpisodeTests.at(20))
            }
        }

        /// The block already wears a session's own sentence, so it is already labelled. Caught by
        /// identity, before any geometry.
        @Test("A block that borrowed a session's name is refused by identity")
        func refusesAnAlreadyNamedBlock() {
            let sessionID = UUID()
            let refusal = SessionFromEpisode.claim(
                for: SessionFromEpisodeTests.block(sessionID: sessionID)
            )

            guard case .failure(let reason) = refusal else {
                Issue.record("A block inside a session must be refused.")
                return
            }
            #expect(reason == .alreadyLabelled(sessionID: sessionID))
            #expect(reason.isCoveredByASession)
        }
    }

    // MARK: - Refusals that are not about overlap

    @Suite("What it will not write")
    struct Refusals {

        @Test("A block with no measured time cannot be labelled")
        func refusesAnEmptyBlock() {
            let empty = Episode(
                start: SessionFromEpisodeTests.at(0),
                end: SessionFromEpisodeTests.at(0),
                apps: [],
                label: "",
                labelConfidence: .appRoster
            )
            #expect(SessionFromEpisodeTests.block().isUnlabelled)
            #expect(empty.isUnlabelled == false)

            guard case .failure(let reason) = SessionFromEpisode.claim(for: empty) else {
                Issue.record("A zero-length block must be refused.")
                return
            }
            #expect(reason == .notMeasured)
            #expect(reason.isCoveredByASession == false)
        }

        /// The one required field, exactly as it is when a session is declared. A record with no
        /// sentence on it is a row nobody can read next week.
        @Test("An empty outcome is refused, and whitespace is empty")
        func refusesAnEmptyOutcome() {
            for text in ["", "   ", "\n\t "] {
                let result = SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisode.Label(intendedOutcome: text),
                    at: SessionFromEpisodeTests.fourPM
                )
                guard case .failure(let reason) = result else {
                    Issue.record("\"\(text)\" must not become a session.")
                    return
                }
                #expect(reason == .outcomeMissing)
            }
        }

        /// The geometry is answered before the label, so a user is told the record already accounts for
        /// a block *before* being asked to describe it rather than after typing a sentence.
        @Test("An already-accounted block is refused even with no outcome typed")
        func geometryIsCheckedFirst() {
            let result = SessionFromEpisode.session(
                for: SessionFromEpisodeTests.block(),
                label: SessionFromEpisode.Label(intendedOutcome: ""),
                existingSessions: [SessionFromEpisodeTests.session(from: -10, to: 60)],
                at: SessionFromEpisodeTests.fourPM
            )
            guard case .failure(let reason) = result else {
                Issue.record("Expected a refusal.")
                return
            }
            #expect(reason == .alreadyAccounted(remaining: 0))
        }

        /// Every refusal is a fact about the record. None of them has the user as its subject, and none
        /// says they forgot — `INTELLIGENCE.md`'s out-of-hours copy law applied to this surface.
        @Test("No refusal sentence blames the user")
        func refusalsNameTheRecord() {
            let refusals: [SessionFromEpisode.Refusal] = [
                .notMeasured,
                .alreadyLabelled(sessionID: UUID()),
                .alreadyAccounted(remaining: 0),
                .outcomeMissing,
            ]
            let banned = ["you forgot", "you didn't", "you did not", "should have", "failed"]

            for refusal in refusals {
                let sentence = refusal.sentence.lowercased()
                #expect(!sentence.isEmpty)
                for word in banned {
                    #expect(!sentence.contains(word), "\(refusal) says \"\(word)\"")
                }
            }
        }
    }

    // MARK: - Pre-filling

    @Suite("What the sheet can pre-fill, and what it refuses to")
    struct Suggestions {

        @Test("Each category that names a kind of work maps to one work type")
        func mapsCategoriesToWorkTypes() {
            #expect(SessionFromEpisode.suggestedWorkType(for: .codeReview) == .codeReview)
            #expect(SessionFromEpisode.suggestedWorkType(for: .communication) == .communication)
            #expect(SessionFromEpisode.suggestedWorkType(for: .planning) == .planning)
            #expect(SessionFromEpisode.suggestedWorkType(for: .meeting) == .meeting)
            #expect(SessionFromEpisode.suggestedWorkType(for: .administrative) == .administrative)
            for category in [
                ActivityCategory.coding, .testing, .research, .documentation,
            ] {
                #expect(SessionFromEpisode.suggestedWorkType(for: category) == .deepWork)
            }
        }

        /// It fails closed. A category the rules could not name must not become a work type the record
        /// asserts, and `.distraction` must never propose one either — that would have the app decide
        /// what kind of work a person's afternoon was after calling it a distraction.
        @Test("Unknown and distraction suggest nothing at all")
        func failsClosed() {
            #expect(SessionFromEpisode.suggestedWorkType(for: .unknown) == nil)
            #expect(SessionFromEpisode.suggestedWorkType(for: .distraction) == nil)
        }

        /// `.management` is unreachable on purpose: no category means "I was managing", and inferring
        /// it from a roster of applications would be the app guessing at a role.
        @Test("No category ever suggests Management")
        func neverSuggestsManagement() {
            for category in ActivityCategory.allCases {
                #expect(SessionFromEpisode.suggestedWorkType(for: category) != .management)
            }
        }
    }

    // MARK: - Finding the block to label

    @Suite("Which block one keystroke acts on")
    struct Finding {

        private static func timeline(_ episodes: [Episode]) -> DayTimeline {
            DayTimeline(
                dayStart: SessionFromEpisodeTests.nineAM,
                episodes: episodes,
                gaps: []
            )
        }

        @Test("The latest block nobody declared anything over is the one offered")
        func latestUnlabelled() {
            let morning = SessionFromEpisodeTests.block(start: 0, end: 50)
            let declared = SessionFromEpisodeTests.block(
                start: 60, end: 110, sessionID: UUID()
            )
            let afternoon = SessionFromEpisodeTests.block(start: 120, end: 170)

            let day = Self.timeline([morning, declared, afternoon])
            #expect(day.unlabelledEpisodes.count == 2)
            #expect(day.latestUnlabelledEpisode?.start == afternoon.start)
        }

        /// A day entirely declared offers nothing, which is what removes the menu bar row rather than
        /// dimming it.
        @Test("A fully declared day offers nothing")
        func nothingToOffer() {
            let day = Self.timeline([
                SessionFromEpisodeTests.block(start: 0, end: 50, sessionID: UUID())
            ])
            #expect(day.unlabelledEpisodes.isEmpty)
            #expect(day.latestUnlabelledEpisode == nil)
        }
    }

    // MARK: - The sentence the sheet prints

    @Suite("The trim note")
    struct TrimNote {

        @Test("A trimmed claim states what was already accounted for and what it records")
        func statesTheTrim() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    existingSessions: [SessionFromEpisodeTests.session(from: 30, to: 60)],
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            let note = made.claim.trimNote(overlapText: "20m", claimedRangeText: "9:00–9:30")
            #expect(note == "20m of this block is already inside a session, so this records 9:00–9:30.")
        }

        /// No trim, no sentence. A note that appeared on every block would be noise, and the ordinary
        /// case is a block nothing overlaps.
        @Test("An untrimmed claim prints nothing")
        func silentWhenNothingWasTrimmed() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )
            #expect(made.claim.trimNote(overlapText: "0m", claimedRangeText: "9:00–9:50") == nil)
        }
    }

    // MARK: - Round trip

    /// The field is new, so a session that predates it must still decode — and one that carries it
    /// must survive the store's own coders. Without this, provenance would be a claim that silently
    /// disappeared on the first save-and-reload cycle.
    @Suite("It survives the store")
    struct Persistence {

        @Test("reconstructedAt round-trips through the store's coders")
        func roundTrips() throws {
            let made = try SessionFromEpisodeTests().expectSuccess(
                SessionFromEpisode.session(
                    for: SessionFromEpisodeTests.block(),
                    label: SessionFromEpisodeTests.label,
                    at: SessionFromEpisodeTests.fourPM
                )
            )

            let data = try StoreSnapshot.makeEncoder().encode(made.session)
            let decoded = try StoreSnapshot.makeDecoder().decode(FocusSession.self, from: data)

            #expect(decoded == made.session)
            #expect(decoded.provenance == .reconstructed)
            #expect(decoded.reconstructedAt == SessionFromEpisodeTests.fourPM)
        }

        /// A session written before this field existed reads back as declared, which is what it was.
        @Test("A session with no provenance field decodes as declared")
        func decodesAnOlderSession() throws {
            let json = """
                {
                  "id": "11111111-1111-1111-1111-111111111111",
                  "intendedOutcome": "Written by an earlier build",
                  "workType": "deepWork",
                  "startedAt": 727083600,
                  "pausedDuration": 0,
                  "isReactive": false,
                  "interruptionCount": 0
                }
                """
            let decoded = try StoreSnapshot.makeDecoder()
                .decode(FocusSession.self, from: Data(json.utf8))

            #expect(decoded.reconstructedAt == nil)
            #expect(decoded.provenance == .declared)
        }
    }
}
