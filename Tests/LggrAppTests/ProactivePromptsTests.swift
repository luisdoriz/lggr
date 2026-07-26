import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

// The scheduler behind the two prompts about undeclared work.
//
// `UnlabelledWorkTests` proves the decisions. This file proves the wiring, and the wiring carries one
// rule the pure function cannot: **a block is recorded as asked at the moment the notification is
// posted, and the record survives a relaunch.** Everything else about this feature is recoverable. An
// offer that arrives twice is not: it reads as a nag, the user switches Lggr off in System Settings,
// and every useful notification the app will ever send dies with it in a place it cannot ask again.

private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 09:00:00 **UTC**, assembled from components rather than written as an epoch offset.
///
/// The other suites anchor to a literal `timeIntervalSinceReferenceDate` because they only ever use it
/// relatively. This file cannot: the end-of-day review is gated on an *hour of the day*, so the anchor
/// has to be an instant whose UTC hour is the one the comment claims. Falling back to `Date()` rather
/// than force-unwrapping keeps the layering rule; the components are valid in any Gregorian calendar,
/// so the fallback is unreachable.
private let nineAM: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar.date(from: DateComponents(year: 2024, month: 1, day: 15, hour: 9)) ?? Date()
}()

private let dayStart = nineAM.addingTimeInterval(-9 * 60 * 60)

private func at(_ offsetMinutes: Double) -> Date {
    nineAM.addingTimeInterval(offsetMinutes * 60)
}

/// 18:40 UTC on the fixture day, so the default review hour has passed.
///
/// File scope rather than a `static let` on the suite: a default argument cannot reference a
/// main-actor-isolated property from a nonisolated context.
private let evening = at(580)

/// A clock that answers whatever the test last set.
private final class StoppedClock: DateProviding, @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private func block(
    start: Double,
    end: Double,
    active: TimeInterval,
    sessionID: UUID? = nil
) -> Episode {
    Episode(
        start: at(start),
        end: at(end),
        apps: [
            Episode.AppShare(
                bundleIdentifier: "com.apple.dt.Xcode",
                displayName: "Xcode",
                duration: active,
                visitCount: 6
            )
        ],
        label: "Xcode",
        labelConfidence: .appRoster,
        sessionID: sessionID
    )
}

private func day(_ episodes: [Episode]) -> DayTimeline {
    DayTimeline(dayStart: dayStart, episodes: episodes, gaps: [])
}

/// UTC, so an hour-of-day assertion does not depend on where the machine is.
private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

/// A scratch preferences suite with the prompt keys cleared, so no test can inherit another's memory
/// or touch the real user's settings.
private func freshDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "com.lggr.tests.prompts.\(name)") ?? .standard
    for key in [
        "com.lggr.prompts.offeredBlocks",
        "com.lggr.prompts.offeredDay",
        "com.lggr.prompts.reviewedDay",
    ] {
        defaults.removeObject(forKey: key)
    }
    return defaults
}

@MainActor
private struct Harness {
    let service: RecordingNotificationService
    let gate: NotificationGate
    let clock: StoppedClock
    let prompts: ProactivePrompts
    /// Mutable so a test can move the day forward under the service, exactly as a flush does.
    let state: State

    @MainActor
    final class State {
        var timeline: DayTimeline = day([])
        var sessionRunning = false
        var trackingPaused = false
        var schedule = ProactivePrompts.Schedule(hours: .allDay, endOfDayHour: 18)
    }

    init(
        name: String,
        switches: NotificationSwitches,
        now: Date = at(88),
        defaults: UserDefaults? = nil
    ) {
        let service = RecordingNotificationService(authorization: .allowed)
        let gate = NotificationGate(service: service, switches: switches)
        let clock = StoppedClock(now)
        let state = State()
        self.service = service
        self.gate = gate
        self.clock = clock
        self.state = state
        self.prompts = ProactivePrompts(
            gate: gate,
            clock: clock,
            calendar: utc,
            defaults: defaults ?? freshDefaults(name),
            schedule: { state.schedule },
            timeline: { state.timeline },
            isSessionRunning: { state.sessionRunning },
            isTrackingPaused: { state.trackingPaused },
            // The real machine is never consulted: a test running while the developer's screen
            // happens to be locked would otherwise watch this correctly stay silent and call it a bug.
            sessionState: { SystemSessionState.Snapshot.active }
        )
    }

    var posted: [NotificationContent] { service.posted }

    func postedKinds() -> [NotificationKind] { service.posted.map(\.kind) }
}

// MARK: - The live offer

@Suite("Proactive prompts — the live offer")
@MainActor
struct ProactiveLiveOfferTests {

    private func harness(
        _ name: String,
        defaults: UserDefaults? = nil,
        now: Date = at(88)
    ) -> Harness {
        Harness(
            name: name,
            switches: NotificationSwitches(unlabelledBlock: true),
            now: now,
            defaults: defaults
        )
    }

    @Test("An eighteen-minute stretch with no session running is offered once, and then never again")
    func offeredOnce() async {
        let harness = harness("once")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])

        await harness.prompts.evaluate()
        #expect(harness.postedKinds() == [.unlabelledBlock])
        #expect(harness.posted.first?.title == "Xcode · 18m")

        // The same stretch, twenty minutes longer. Nothing is posted, and the pending banner is not
        // replaced either — the stretch has already been asked about.
        harness.clock.now = at(108)
        harness.state.timeline = day([block(start: 70, end: 108, active: minutes(38))])
        await harness.prompts.evaluate()
        #expect(harness.posted.count == 1)
        #expect(harness.prompts.lastLiveDecision?.silence == .alreadyOffered)
    }

    @Test("Once per block survives a relaunch")
    func offeredOnceAcrossRelaunch() async {
        // A user who restarts Lggr mid-block must not be asked a second time. The set of stretches
        // already asked about is persisted for exactly this.
        let defaults = freshDefaults("relaunch")
        let first = harness("relaunch", defaults: defaults)
        first.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await first.prompts.evaluate()
        #expect(first.posted.count == 1)

        let second = harness("relaunch", defaults: defaults, now: at(95))
        second.state.timeline = day([block(start: 70, end: 95, active: minutes(25))])
        await second.prompts.evaluate()
        #expect(second.posted.isEmpty)
        #expect(second.prompts.lastLiveDecision?.silence == .alreadyOffered)
    }

    @Test("A stretch is recorded as asked even if the user never sees the banner")
    func ignoringIsTheSameAsDismissing() async {
        // Marking after a user answer would make an ignored banner repeat once a minute. So the record
        // is written before the post, and dismissal and inaction produce the same outcome — which is
        // what makes ignoring a notification safe.
        let harness = harness("ignored")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await harness.prompts.evaluate()

        harness.prompts.dismissOutstandingBlock()
        #expect(harness.service.cancelled.contains(.unlabelledBlock))
        #expect(harness.prompts.outstandingOffer == nil)

        harness.clock.now = at(100)
        harness.state.timeline = day([block(start: 70, end: 100, active: minutes(30))])
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
    }

    @Test("Silent while a session runs, while tracking is paused, and outside the hours")
    func silences() async {
        let harness = harness("silences")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])

        harness.state.sessionRunning = true
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(harness.prompts.lastLiveDecision?.silence == .sessionRunning)

        harness.state.sessionRunning = false
        harness.state.trackingPaused = true
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(harness.prompts.lastLiveDecision?.silence == .trackingPaused)

        harness.state.trackingPaused = false
        // 09:00–09:30 UTC. The clock is at 10:28, so the window has closed.
        harness.state.schedule = ProactivePrompts.Schedule(
            hours: PromptHours(startHour: 8, endHour: 9),
            endOfDayHour: 18
        )
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(harness.prompts.lastLiveDecision?.silence == .outsideHours)
    }

    @Test("A switched-off kind is never posted, whatever the day looks like")
    func switchedOffPostsNothing() async {
        let harness = Harness(name: "off", switches: .allOff)
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(!harness.prompts.isRunning)

        // And nothing is watching, either: both kinds off means no evaluation timer at all.
        harness.prompts.start()
        #expect(!harness.prompts.isRunning)
    }

    @Test("Stop asking moves the same switch the Alerts pane moves, and stops the watching")
    func stopAsking() async {
        let harness = harness("stop")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await harness.prompts.evaluate()
        #expect(harness.posted.count == 1)

        await harness.prompts.stopAsking(about: .unlabelledBlock)
        #expect(!harness.gate.switches.isEnabled(.unlabelledBlock))
        #expect(harness.service.cancelled.contains(.unlabelledBlock))
        #expect(!harness.prompts.isRunning)

        // Switching it off never asks macOS for anything, and never posts again — not even for a
        // brand-new stretch that would otherwise have qualified.
        #expect(harness.service.authorizationRequests == 0)
        harness.clock.now = at(200)
        harness.state.timeline = day([block(start: 181, end: 200, active: minutes(19))])
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(harness.prompts.lastLiveDecision?.silence == .switchedOff)
    }

    @Test("Label this resolves the stretch as it now stands, not as it was when the banner was posted")
    func labelResolvesLate() async {
        let harness = harness("label")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await harness.prompts.evaluate()

        var opened: UUID?
        harness.prompts.onLabelBlock = { opened = $0 }

        // The sampler flushed; the block is longer and its identifier has changed with it.
        harness.clock.now = at(108)
        let grown = block(start: 70, end: 108, active: minutes(38))
        harness.state.timeline = day([grown])

        #expect(harness.prompts.labelOutstandingBlock())
        #expect(opened == grown.id)
        // And the offer is spent: pressing it twice cannot open two sheets.
        #expect(!harness.prompts.labelOutstandingBlock())
    }

    @Test("A stretch the segmenter no longer has opens nothing rather than an empty sheet")
    func labelDeclinesWhenTheBlockIsGone() async {
        let harness = harness("gone")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await harness.prompts.evaluate()

        var opened: UUID?
        harness.prompts.onLabelBlock = { opened = $0 }
        harness.state.timeline = day([block(start: 400, end: 440, active: minutes(38))])

        #expect(!harness.prompts.labelOutstandingBlock())
        #expect(opened == nil)
    }

    @Test("The day's memory empties itself when the day changes")
    func rollsOver() async {
        let harness = harness("rollover")
        harness.state.timeline = day([block(start: 70, end: 88, active: minutes(18))])
        await harness.prompts.evaluate()
        #expect(harness.posted.count == 1)

        // Tomorrow, same time. Without the roll-over the set would grow for the life of the install
        // and the review would never fire again after its first day.
        harness.clock.now = at(88 + 24 * 60)
        harness.state.timeline = day([
            block(start: 70 + 24 * 60, end: 88 + 24 * 60, active: minutes(18))
        ])
        await harness.prompts.evaluate()
        #expect(harness.posted.count == 1)
        #expect(harness.prompts.lastLiveDecision?.isOffer == true)
    }
}

// MARK: - The end-of-day review

@Suite("Proactive prompts — the end-of-day review")
@MainActor
struct ProactiveReviewTests {

    private func harness(_ name: String, now: Date = evening) -> Harness {
        Harness(
            name: name,
            switches: NotificationSwitches(endOfDayReview: true),
            now: now
        )
    }

    @Test("A day with unlabelled blocks is offered once, with the cost of answering in it")
    func offeredOnce() async {
        let harness = harness("review")
        harness.state.timeline = day([
            block(start: 0, end: 60, active: minutes(58)),
            block(start: 90, end: 150, active: minutes(55)),
            block(start: 200, end: 240, active: minutes(38)),
        ])

        await harness.prompts.evaluate()
        #expect(harness.postedKinds() == [.endOfDayReview])
        #expect(harness.posted.first?.body == "3 blocks from today aren't labelled — about 2 minutes.")

        await harness.prompts.evaluate()
        #expect(harness.posted.count == 1)
        #expect(harness.prompts.lastReviewDecision?.silence == .alreadyOffered)
    }

    @Test("A day with nothing unlabelled sends nothing at all")
    func silenceIsTheOutput() async {
        // Not a summary, not a congratulation, not a banner saying the day was fine. The hour arrived
        // and the record had nothing to say, so the correct output is nothing.
        let harness = harness("nothing")
        harness.state.timeline = day([
            block(start: 0, end: 60, active: minutes(58), sessionID: UUID())
        ])
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(harness.prompts.lastReviewDecision?.silence == .nothingUnlabelled)
    }

    @Test("Before the chosen hour, nothing is looked at and nothing is sent")
    func notYetDue() async {
        let harness = harness("early", now: at(88))
        harness.state.timeline = day([block(start: 0, end: 60, active: minutes(58))])
        await harness.prompts.evaluate()
        #expect(harness.posted.isEmpty)
        #expect(harness.prompts.lastReviewDecision?.silence == .notYetDue)
    }

    @Test("The queue the sheet opens is recomputed, not carried from the notification")
    func queueIsRecomputed() async {
        let harness = harness("queue")
        let labelled = UUID()
        harness.state.timeline = day([
            block(start: 0, end: 60, active: minutes(58)),
            block(start: 90, end: 150, active: minutes(55)),
        ])
        await harness.prompts.evaluate()
        #expect(harness.prompts.currentReport().count == 2)

        // The user declared one of them in the meantime. The queue must not offer it.
        harness.state.timeline = day([
            block(start: 0, end: 60, active: minutes(58), sessionID: labelled),
            block(start: 90, end: 150, active: minutes(55)),
        ])
        #expect(harness.prompts.currentReport().count == 1)
    }

    @Test("Opening the review withdraws its banner and asks the host for the sheet")
    func openingTheReview() async {
        let harness = harness("open")
        harness.state.timeline = day([block(start: 0, end: 60, active: minutes(58))])
        await harness.prompts.evaluate()

        var opened = 0
        harness.prompts.onOpenReview = { opened += 1 }
        harness.prompts.openReview()
        #expect(opened == 1)
        #expect(harness.service.cancelled.contains(.endOfDayReview))
    }

    @Test("At most one prompt is posted per evaluation, and the live offer wins")
    func oneAtATime() async {
        // Two banners at once for two flavours of the same fact is how one notification becomes two.
        // The live offer wins because it expires with the stretch; the review loses nothing by waiting.
        let harness = Harness(
            name: "both",
            switches: NotificationSwitches(endOfDayReview: true, unlabelledBlock: true),
            now: evening
        )
        harness.state.timeline = day([
            block(start: 0, end: 60, active: minutes(58)),
            block(start: 555, end: 580, active: minutes(24)),
        ])

        await harness.prompts.evaluate()
        #expect(harness.postedKinds() == [.unlabelledBlock])

        // Next minute: the stretch has been asked about, so the review gets its turn.
        harness.clock.now = at(581)
        harness.state.timeline = day([
            block(start: 0, end: 60, active: minutes(58)),
            block(start: 555, end: 581, active: minutes(25)),
        ])
        await harness.prompts.evaluate()
        #expect(harness.postedKinds().contains(.endOfDayReview))
    }
}

// MARK: - The schedule

@Suite("Prompt schedule")
struct PromptScheduleTests {

    @Test("The defaults are a narrowing guess, and the review sits inside them")
    func defaults() {
        let schedule = ProactivePrompts.Schedule.default
        #expect(schedule.hours == .default)
        #expect(schedule.endOfDayHour == 18)
        #expect(schedule.reviewIsInsideHours)
    }

    @Test("A nonsense hour is clamped rather than trusted")
    func clamped() {
        #expect(ProactivePrompts.Schedule(endOfDayHour: 99).endOfDayHour == 23)
        #expect(ProactivePrompts.Schedule(endOfDayHour: -3).endOfDayHour == 0)
    }

    @Test("A review time outside the prompt window is reported, never silently corrected")
    func contradictionIsVisible() {
        // Advisory: the two settings are independent and Lggr does not overrule the user. The pane can
        // say so; nothing here moves a value the user chose.
        let schedule = ProactivePrompts.Schedule(
            hours: PromptHours(startHour: 9, endHour: 17),
            endOfDayHour: 22
        )
        #expect(!schedule.reviewIsInsideHours)
        #expect(schedule.endOfDayHour == 22)
    }

    @Test("The schedule survives storage, so a relaunch keeps the hours the user chose")
    func codable() throws {
        let schedule = ProactivePrompts.Schedule(
            hours: PromptHours(startHour: 7, endHour: 20),
            endOfDayHour: 19
        )
        let data = try JSONEncoder().encode(schedule)
        #expect(try JSONDecoder().decode(ProactivePrompts.Schedule.self, from: data) == schedule)
    }
}
