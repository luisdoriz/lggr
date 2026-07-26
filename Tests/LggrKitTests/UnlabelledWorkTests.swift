import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing rather than decoration, for the reason its twins in
/// `SessionFromEpisodeTests` and `SessionAutoCloseTests` give: `#expect` compares an `Optional<Double>`
/// against an integer-literal expression by type as well as by value.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

// The two prompts that catch a user who never opens the app, pinned as tests.
//
// This file is the reason those prompts can ship. They are the highest-risk notifications in the
// product — macOS grants one authorisation for the whole application, so a prompt that lands as a nag
// costs Lggr every useful notification it will ever send, permanently, in a place it cannot ask again.
// The rules that keep that from happening are not conventions in a service; they are cases of an enum
// in a pure function, and each of them has a test below.
//
// The suite is organised around the five claims the feature makes:
//
//   1. It is willing to say **nothing**, and does so for a day with nothing worth labelling.
//   2. It asks **once** per stretch of work, and can still identify that stretch after it has grown.
//   3. It is silent while a session runs, while tracking is paused, while the screen is locked, and
//      outside the hours the user set.
//   4. It never offers a gap, a sliver, or a block the record already accounts for.
//   5. The end-of-day time is permission to *look*, never a cause to send.

@Suite("Unlabelled work")
struct UnlabelledWorkTests {

    /// 2024-01-15 09:00:00 UTC — the same instant every other domain suite anchors to, so a failure
    /// here reads against one wall clock.
    static let nineAM = Date(timeIntervalSinceReferenceDate: 727_083_600)
    static let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

    /// UTC throughout: an hour-of-day assertion that reads the machine's timezone passes in London and
    /// fails in Tokyo, which is the least useful kind of test failure there is.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    static func at(_ offsetMinutes: Double) -> Date {
        nineAM.addingTimeInterval(offsetMinutes * 60)
    }

    /// A block with `active` minutes measured across two applications.
    static func block(
        start: Double,
        end: Double,
        active: TimeInterval,
        sessionID: UUID? = nil,
        bundle: String = "com.apple.dt.Xcode",
        displayName: String = "Xcode"
    ) -> Episode {
        Episode(
            start: at(start),
            end: at(end),
            apps: [
                Episode.AppShare(
                    bundleIdentifier: bundle,
                    displayName: displayName,
                    duration: active * 0.7,
                    visitCount: 8
                ),
                Episode.AppShare(
                    bundleIdentifier: "com.apple.Terminal",
                    displayName: "Terminal",
                    duration: active * 0.3,
                    visitCount: 5
                ),
            ],
            label: "\(displayName), Terminal",
            labelConfidence: .appRoster,
            sessionID: sessionID
        )
    }

    /// A block whose only application is one the user marked private.
    static func privateBlock(start: Double, end: Double, active: TimeInterval) -> Episode {
        Episode(
            start: at(start),
            end: at(end),
            apps: [
                Episode.AppShare(
                    bundleIdentifier: "com.lggr.private",
                    displayName: "Private",
                    duration: active,
                    visitCount: 3
                )
            ],
            label: "Private",
            labelConfidence: .appRoster
        )
    }

    static func day(episodes: [Episode], gaps: [Gap] = []) -> DayTimeline {
        DayTimeline(dayStart: dayStart, episodes: episodes, gaps: gaps)
    }

    // MARK: - Saying nothing

    @Suite("Willing to say nothing")
    struct Silence {

        @Test("An empty day produces no report, which is the answer and not a failure")
        func emptyDayIsNothing() {
            let report = UnlabelledWork.report(for: UnlabelledWorkTests.day(episodes: []))
            #expect(report.isEmpty)
            #expect(report.count == 0)
            #expect(report.sentence.isEmpty)
            #expect(report == .nothing)
        }

        @Test("A day where every block was declared produces no report")
        func declaredDayIsNothing() {
            let session = UUID()
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 60, active: minutes(58), sessionID: session),
                UnlabelledWorkTests.block(start: 90, end: 150, active: minutes(55), sessionID: session),
            ])
            #expect(UnlabelledWork.report(for: day).isEmpty)
        }

        @Test("An afternoon of gaps and nothing else produces no report")
        func gapsAreNeverOffered() {
            // The mechanism: a `DayTimeline` keeps absences in their own collection and `report` reads
            // `episodes` only. An hour of sleep is not an unlabelled block, and offering to label one
            // would be the app asking the user to describe a night.
            let day = UnlabelledWorkTests.day(
                episodes: [],
                gaps: [
                    Gap(
                        reason: .systemSleep,
                        start: UnlabelledWorkTests.at(0),
                        end: UnlabelledWorkTests.at(600)
                    ),
                    Gap(
                        reason: .idle,
                        start: UnlabelledWorkTests.at(610),
                        end: UnlabelledWorkTests.at(700)
                    ),
                ]
            )
            let report = UnlabelledWork.report(for: day)
            #expect(report.isEmpty)
            #expect(report.sentence.isEmpty)
        }

        @Test("A day of short blocks produces no report")
        func shortBlocksAreNotWorthSaying() {
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 10, active: minutes(9)),
                UnlabelledWorkTests.block(start: 20, end: 38, active: minutes(17)),
            ])
            #expect(UnlabelledWork.report(for: day).isEmpty)
        }

        @Test("A block that is mostly idle is measured on what was measured, not on its span")
        func idleTimeIsNotWork() {
            // Two hours on the wall clock, eleven minutes in an application. Offering this as though
            // it were two hours of undeclared work would be the app crediting idle time as focus,
            // which is the one thing the whole design is arranged to avoid.
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 120, active: minutes(11))
            ])
            #expect(UnlabelledWork.report(for: day).isEmpty)
        }

        @Test("A block that is entirely a private application is never offered")
        func privateBlocksAreNotOffered() {
            // Not privacy politeness — honesty. There is no application name to show, so the prompt
            // would be asking "what was this?" while showing the user nothing to recognise it by, and
            // a guessed label on a record of the past is worse than no label.
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.privateBlock(start: 0, end: 60, active: minutes(58))
            ])
            #expect(UnlabelledWork.report(for: day).isEmpty)

            var permissive = UnlabelledWork.Policy.default
            permissive.includesPrivateApplications = true
            #expect(UnlabelledWork.report(for: day, policy: permissive).count == 1)
        }
    }

    // MARK: - The day's report

    @Suite("The day's report")
    struct Reporting {

        static func mixedDay() -> DayTimeline {
            UnlabelledWorkTests.day(episodes: [
                // Declared: has a session, so it is already labelled.
                UnlabelledWorkTests.block(
                    start: 0, end: 60, active: minutes(58), sessionID: UUID()),
                // Too short.
                UnlabelledWorkTests.block(start: 70, end: 78, active: minutes(7)),
                UnlabelledWorkTests.block(start: 90, end: 150, active: minutes(55)),
                UnlabelledWorkTests.block(start: 160, end: 200, active: minutes(38)),
                UnlabelledWorkTests.block(start: 210, end: 240, active: minutes(29)),
            ])
        }

        @Test("Only the blocks that qualify are offered, oldest first")
        func onlyQualifyingBlocks() {
            let report = UnlabelledWork.report(for: Self.mixedDay())
            #expect(report.count == 3)
            #expect(report.blocks.map(\.start) == [
                UnlabelledWorkTests.at(90),
                UnlabelledWorkTests.at(160),
                UnlabelledWorkTests.at(210),
            ])
        }

        @Test("The sentence states the record and the cost, and nothing about the person")
        func theSentence() {
            let report = UnlabelledWork.report(for: Self.mixedDay())
            #expect(report.sentence == "3 blocks from today aren't labelled — about 2 minutes.")

            let text = report.sentence.lowercased()
            for word in [
                "forgot", "missed", "should", "don't forget", "streak", "you have", "haven't",
                "failed", "only", "just",
            ] {
                #expect(!text.contains(word), "the sentence contains \(word): \(report.sentence)")
            }
            #expect(!report.sentence.contains("!"))
        }

        @Test("One block reads as one block, in words")
        func singularSentence() {
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 60, active: minutes(58))
            ])
            let report = UnlabelledWork.report(for: day)
            #expect(report.sentence == "One block from today isn't labelled — about a minute.")
        }

        @Test("The estimate is rounded up, never to nearest")
        func estimateIsGenerous() {
            // An offer that under-promises the cost and then takes longer is the last one the user
            // accepts. Three blocks at thirty seconds is ninety seconds, and it is quoted as two
            // minutes rather than as one.
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 30, active: minutes(28)),
                UnlabelledWorkTests.block(start: 40, end: 70, active: minutes(28)),
                UnlabelledWorkTests.block(start: 80, end: 110, active: minutes(28)),
            ])
            let report = UnlabelledWork.report(for: day)
            #expect(report.estimatedDuration == minutes(2))
            #expect(report.estimateText == "about 2 minutes")
        }

        @Test("The queue is capped, and what is left over is reported rather than lost")
        func queueIsCapped() {
            let blocks = (0..<12).map { index in
                UnlabelledWorkTests.block(
                    start: Double(index) * 40,
                    end: Double(index) * 40 + 30,
                    active: minutes(28)
                )
            }
            let report = UnlabelledWork.report(for: UnlabelledWorkTests.day(episodes: blocks))
            #expect(report.count == 8)
            #expect(report.setAside == 4)
            // The cap is on the offer, not on the day: the other four stay on the timeline.
            #expect(report.estimateText == "about 4 minutes")
        }

        @Test("The progress line describes the queue and clamps to it")
        func progressText() {
            let report = UnlabelledWork.report(for: Self.mixedDay())
            #expect(report.progressText(at: 0) == "Block 1 of 3")
            #expect(report.progressText(at: 2) == "Block 3 of 3")
            // Past the end, and before the start: a caller that walked off either edge gets a
            // sentence rather than a crash or a "Block 0 of 3".
            #expect(report.progressText(at: 9) == "Block 3 of 3")
            #expect(report.progressText(at: -4) == "Block 1 of 3")
            #expect(UnlabelledWork.Report.nothing.progressText(at: 0).isEmpty)
        }

        @Test("Measured time sums what was measured, and gaps contribute nothing")
        func measuredDuration() {
            let report = UnlabelledWork.report(for: Self.mixedDay())
            #expect(report.measuredDuration == minutes(55) + minutes(38) + minutes(29))
        }
    }

    // MARK: - Naming a stretch of work

    @Suite("Naming a stretch of work")
    struct Keys {

        @Test("A block keeps its key while it grows, though its identifier does not")
        func keySurvivesGrowth() {
            // This is the mechanism behind "once per block", and the reason it is not `Episode.id`:
            // the newest block's identifier is derived from its bounds, so it changes on every flush
            // of the sampler while the block is still open. Keying on it would re-ask once a minute.
            let atFifteen = UnlabelledWorkTests.block(start: 0, end: 15, active: minutes(15))
            let atForty = UnlabelledWorkTests.block(start: 0, end: 40, active: minutes(39))

            #expect(UnlabelledWork.BlockKey(atFifteen) == UnlabelledWork.BlockKey(atForty))
        }

        @Test("Two different stretches have different keys")
        func differentStretchesDiffer() {
            let morning = UnlabelledWorkTests.block(start: 0, end: 40, active: minutes(38))
            let afternoon = UnlabelledWorkTests.block(start: 300, end: 340, active: minutes(38))
            let otherApp = UnlabelledWorkTests.block(
                start: 0, end: 40, active: minutes(38),
                bundle: "com.google.Chrome", displayName: "Chrome"
            )

            #expect(UnlabelledWork.BlockKey(morning) != UnlabelledWork.BlockKey(afternoon))
            #expect(UnlabelledWork.BlockKey(morning) != UnlabelledWork.BlockKey(otherApp))
        }

        @Test("A key survives storage, so a relaunch mid-block does not ask twice")
        func keyRoundTrips() {
            let key = UnlabelledWork.BlockKey(
                UnlabelledWorkTests.block(start: 0, end: 40, active: minutes(38))
            )
            #expect(UnlabelledWork.BlockKey(storageKey: key.storageKey) == key)
            #expect(UnlabelledWork.BlockKey(storageKey: "nonsense") == nil)
            #expect(UnlabelledWork.BlockKey(storageKey: "") == nil)
        }

        @Test("A key finds its block again after the day has been rebuilt")
        func keyResolvesLate() {
            // What the notification's button does: the banner was posted minutes ago and the stretch
            // has grown since, so the `Episode` that was offered no longer exists.
            let key = UnlabelledWork.BlockKey(
                UnlabelledWorkTests.block(start: 0, end: 16, active: minutes(16))
            )
            let rebuilt = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 44, active: minutes(43))
            ])
            #expect(rebuilt.episode(matching: key)?.activeDuration == minutes(43))

            let elsewhere = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 200, end: 240, active: minutes(38))
            ])
            #expect(elsewhere.episode(matching: key) == nil)
        }
    }

    // MARK: - The live offer

    @Suite("The live offer")
    struct LiveOffer {

        /// A day whose newest block is an eighteen-minute stretch nobody declared.
        static func openStretch(active: TimeInterval = minutes(18)) -> DayTimeline {
            UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(
                    start: 0, end: 60, active: minutes(58), sessionID: UUID()),
                UnlabelledWorkTests.block(start: 70, end: 70 + active / 60, active: active),
            ])
        }

        static var now: Date { UnlabelledWorkTests.at(88) }

        static func decide(
            _ conditions: UnlabelledWork.Conditions,
            day: DayTimeline = openStretch(),
            now: Date = now
        ) -> UnlabelledWork.PromptDecision {
            UnlabelledWork.liveOffer(in: day, now: now, conditions: conditions)
        }

        @Test("Eighteen minutes of undeclared work with nothing in the way is offered, once")
        func offersTheStretch() {
            let decision = Self.decide(UnlabelledWork.Conditions())
            #expect(decision.isOffer)
            #expect(decision.offer?.duration == minutes(18))
            #expect(decision.offer?.episode.start == UnlabelledWorkTests.at(70))
        }

        @Test("The same stretch is never offered twice")
        func neverTwice() {
            // The rule with no acceptable failure: asking twice makes it a nag, a nag gets Lggr
            // switched off in System Settings, and switched off is permanent.
            let first = Self.decide(UnlabelledWork.Conditions())
            guard let offer = first.offer else {
                Issue.record("the first evaluation should offer")
                return
            }

            let second = Self.decide(UnlabelledWork.Conditions(offeredBlocks: [offer.key]))
            #expect(second.silence == .alreadyOffered)

            // And still not, twenty minutes later, when the very same stretch is longer.
            let later = Self.decide(
                UnlabelledWork.Conditions(offeredBlocks: [offer.key]),
                day: Self.openStretch(active: minutes(38)),
                now: UnlabelledWorkTests.at(108)
            )
            #expect(later.silence == .alreadyOffered)
        }

        @Test("Switched off costs nothing and says nothing")
        func switchedOff() {
            #expect(Self.decide(UnlabelledWork.Conditions(isEnabled: false)).silence == .switchedOff)
        }

        @Test("Silent while a session is running")
        func silentDuringASession() {
            // The user has already said what they are doing. Asking would be the app failing to read
            // its own record.
            #expect(
                Self.decide(UnlabelledWork.Conditions(isSessionRunning: true)).silence == .sessionRunning
            )
        }

        @Test("Silent while tracking is paused")
        func silentWhilePaused() {
            #expect(
                Self.decide(UnlabelledWork.Conditions(isTrackingPaused: true)).silence == .trackingPaused
            )
        }

        @Test("Silent while the screen is locked")
        func silentWhileLocked() {
            #expect(
                Self.decide(UnlabelledWork.Conditions(isScreenLocked: true)).silence == .screenLocked
            )
        }

        @Test("Silent outside the hours the user set")
        func silentOutsideHours() {
            #expect(
                Self.decide(UnlabelledWork.Conditions(isWithinHours: false)).silence == .outsideHours
            )
        }

        @Test("A stretch shorter than the threshold is not worth interrupting for")
        func tooShort() {
            let decision = Self.decide(
                UnlabelledWork.Conditions(),
                day: Self.openStretch(active: minutes(11)),
                now: UnlabelledWorkTests.at(81)
            )
            #expect(decision.silence == .stretchTooShort)
        }

        @Test("A stretch that stopped growing is over, and the question no longer applies")
        func stale() {
            // "What are you working on" about work that finished ten minutes ago is the wrong
            // question, and the sampler republishes an open interval on every flush — so a block that
            // stopped moving means the user moved on.
            let decision = Self.decide(
                UnlabelledWork.Conditions(),
                day: Self.openStretch(),
                now: UnlabelledWorkTests.at(120)
            )
            #expect(decision.silence == .stretchEnded)
        }

        @Test("A day with nothing undeclared is silent even with everything else permitting")
        func nothingToSay() {
            let declared = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(
                    start: 0, end: 60, active: minutes(58), sessionID: UUID())
            ])
            #expect(Self.decide(UnlabelledWork.Conditions(), day: declared).silence == .nothingUnlabelled)
        }

        @Test("A private stretch is not offered, and does not report the wrong reason either")
        func privateStretch() {
            let day = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.privateBlock(start: 70, end: 90, active: minutes(19))
            ])
            let decision = Self.decide(
                UnlabelledWork.Conditions(), day: day, now: UnlabelledWorkTests.at(91))
            #expect(decision.silence == .nothingUnlabelled)
        }

        @Test("Every silence has a name, and the enum is the specification")
        func everySilenceIsNamed() {
            // A silence with no name is a silence nobody can test, and the failure this feature
            // cannot survive is a missing case in exactly this list.
            #expect(UnlabelledWork.Silence.allCases.count == 10)
            for silence in UnlabelledWork.Silence.allCases {
                #expect(!silence.note.isEmpty)
            }
        }
    }

    // MARK: - Hours

    @Suite("Prompt hours")
    struct Hours {

        static func at(hour: Int) -> Date {
            UnlabelledWorkTests.utc.date(
                bySettingHour: hour, minute: 30, second: 0, of: UnlabelledWorkTests.nineAM
            ) ?? UnlabelledWorkTests.nineAM
        }

        @Test("An ordinary window includes its start hour and excludes its end hour")
        func ordinaryWindow() {
            let hours = PromptHours(startHour: 9, endHour: 18)
            let calendar = UnlabelledWorkTests.utc
            #expect(!hours.contains(Self.at(hour: 8), calendar: calendar))
            #expect(hours.contains(Self.at(hour: 9), calendar: calendar))
            #expect(hours.contains(Self.at(hour: 17), calendar: calendar))
            #expect(!hours.contains(Self.at(hour: 18), calendar: calendar))
            #expect(!hours.contains(Self.at(hour: 23), calendar: calendar))
        }

        @Test("A window that crosses midnight is not empty")
        func wrappingWindow() {
            let hours = PromptHours(startHour: 22, endHour: 2)
            let calendar = UnlabelledWorkTests.utc
            #expect(hours.wrapsMidnight)
            #expect(hours.contains(Self.at(hour: 23), calendar: calendar))
            #expect(hours.contains(Self.at(hour: 1), calendar: calendar))
            #expect(!hours.contains(Self.at(hour: 12), calendar: calendar))
        }

        @Test("Equal hours mean the whole day, which is a choice the user can make")
        func allDay() {
            let calendar = UnlabelledWorkTests.utc
            #expect(PromptHours.allDay.isAllDay)
            #expect(PromptHours.allDay.contains(Self.at(hour: 3), calendar: calendar))
            #expect(PromptHours.allDay.rangeText == "any time of day")
        }

        @Test("Nonsense hours are clamped rather than trusted")
        func clamped() {
            #expect(PromptHours(startHour: -6, endHour: 99).startHour == 0)
            #expect(PromptHours(startHour: -6, endHour: 99).endHour == 23)
        }

        @Test("The range reads as hours, in a form no locale can rearrange")
        func rangeText() {
            #expect(PromptHours(startHour: 9, endHour: 18).rangeText == "09:00 to 18:00")
        }
    }

    // MARK: - The end-of-day review

    @Suite("The end-of-day review")
    struct Review {

        static func day() -> DayTimeline {
            UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(start: 0, end: 60, active: minutes(58)),
                UnlabelledWorkTests.block(start: 90, end: 150, active: minutes(55)),
            ])
        }

        static func decide(
            _ conditions: UnlabelledWork.ReviewConditions,
            timeline: DayTimeline = Self.day()
        ) -> UnlabelledWork.ReviewDecision {
            UnlabelledWork.reviewOffer(for: timeline, conditions: conditions)
        }

        @Test("A day that holds unlabelled blocks is offered, once")
        func offered() {
            let decision = Self.decide(UnlabelledWork.ReviewConditions())
            #expect(decision.report?.count == 2)
            #expect(
                Self.decide(UnlabelledWork.ReviewConditions(hasAlreadyOffered: true)).silence
                    == .alreadyOffered
            )
        }

        @Test("A day with nothing unlabelled sends nothing — not even a congratulation")
        func silenceIsTheCorrectOutput() {
            // The single most important assertion in this file. `INTELLIGENCE.md` §2: praise and shame
            // are the same mechanism, so "all caught up" is the same interruption wearing a
            // compliment — and it would arrive because the clock reached a number, which is the one
            // thing no notification in Lggr may do.
            let declared = UnlabelledWorkTests.day(episodes: [
                UnlabelledWorkTests.block(
                    start: 0, end: 60, active: minutes(58), sessionID: UUID())
            ])
            let decision = Self.decide(UnlabelledWork.ReviewConditions(), timeline: declared)
            #expect(decision.silence == .nothingUnlabelled)
            #expect(decision.report == nil)
        }

        @Test("The chosen hour is permission to look, and on its own causes nothing")
        func theHourIsNotTheCause() {
            // Due, enabled, unlocked, nothing already offered — and still silent, because the record
            // holds nothing worth saying. That asymmetry is what separates this from every daily
            // reminder on the market.
            let empty = UnlabelledWorkTests.day(episodes: [])
            #expect(
                Self.decide(UnlabelledWork.ReviewConditions(isDue: true), timeline: empty).silence
                    == .nothingUnlabelled
            )
            #expect(Self.decide(UnlabelledWork.ReviewConditions(isDue: false)).silence == .notYetDue)
        }

        @Test("Switched off, locked, or mid-session: silent, and for the stated reason")
        func silences() {
            #expect(
                Self.decide(UnlabelledWork.ReviewConditions(isEnabled: false)).silence == .switchedOff)
            #expect(
                Self.decide(UnlabelledWork.ReviewConditions(isScreenLocked: true)).silence
                    == .screenLocked
            )
            // The review is a report about the whole day and nothing about it expires, so it waits
            // rather than interrupting work in progress.
            #expect(
                Self.decide(UnlabelledWork.ReviewConditions(isSessionRunning: true)).silence
                    == .sessionRunning
            )
        }

        @Test("The precedence is stated: already-offered beats not-yet-due beats everything else")
        func precedence() {
            let decision = Self.decide(
                UnlabelledWork.ReviewConditions(
                    isDue: false,
                    isScreenLocked: true,
                    isSessionRunning: true,
                    hasAlreadyOffered: true
                )
            )
            #expect(decision.silence == .alreadyOffered)
        }
    }

    // MARK: - Policy

    @Suite("Policy")
    struct PolicyTests {

        @Test("The thresholds are the boring rule INTELLIGENCE.md asked for")
        func defaults() {
            let policy = UnlabelledWork.Policy.default
            #expect(policy.minimumBlockDuration == minutes(20))
            #expect(policy.openStretchDuration == minutes(15))
            #expect(policy.maximumBlocks == 8)
            #expect(!policy.includesPrivateApplications)
        }

        @Test("Nonsense constants cannot produce a negative or infinite threshold")
        func sanitised() {
            let policy = UnlabelledWork.Policy(
                minimumBlockDuration: -1,
                openStretchDuration: .nan,
                stretchStaleness: .infinity,
                maximumBlocks: 0,
                secondsPerBlock: -30
            )
            #expect(policy.minimumBlockDuration == 0)
            #expect(policy.openStretchDuration == 0)
            #expect(policy.stretchStaleness == 0)
            #expect(policy.maximumBlocks == 1)
            #expect(policy.secondsPerBlock == 0)
        }

        @Test("One block's eligibility is decided in one place, by both surfaces")
        func oneTest() {
            // Two surfaces disagreeing about which blocks count is how a user gets asked twice about
            // the same stretch of work by two different mechanisms.
            let long = UnlabelledWorkTests.block(start: 0, end: 60, active: minutes(58))
            let short = UnlabelledWorkTests.block(start: 0, end: 10, active: minutes(9))
            let declared = UnlabelledWorkTests.block(
                start: 0, end: 60, active: minutes(58), sessionID: UUID())

            #expect(UnlabelledWork.isWorthOffering(long))
            #expect(!UnlabelledWork.isWorthOffering(short))
            #expect(!UnlabelledWork.isWorthOffering(declared))
            // The live offer's shorter threshold, applied to the same test.
            #expect(UnlabelledWork.isWorthOffering(short, minimumDuration: minutes(5)))
        }
    }
}
