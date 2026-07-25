import Foundation
import LggrKit

// The wiring layer for ambient capture. See docs/_design/02-architecture.md § 5.1.
//
// Every piece of Phase 1 capture was written to be composed from outside itself: the sampler takes a
// flush handler rather than a log, `PrivacyModel.controls` is assignable so the sampler can be
// handed over after the model exists, and `TimelineModel.apply(_:)` takes batches rather than
// reading the disk. That is a good arrangement and it has exactly one cost — until something
// actually performs the composition, the whole subsystem compiles, tests green, and records
// nothing. This file is that something, and it is the only place that knows how the four objects
// fit together.
//
// The order below is load-bearing and is stated here rather than left to be rediscovered:
//
//   1. the log, because both the privacy model and the flush handler need it;
//   2. the privacy model, because the sampler's initial configuration is its two lists — a sampler
//      started with an empty exclusion list records the applications the user has already said are
//      private, for as long as it takes the first list change to arrive;
//   3. the heartbeat, which the sampler drives its flush cadence from;
//   4. the sampler;
//   5. the back-references — `controls` and `onApplicationListsChanged` — which cannot be set
//      before the sampler exists.

/// Owns the ambient capture subsystem and the objects it is composed from.
///
/// Constructing this is inert: nothing is observed, no timer is armed and nothing is written until
/// `start()` is called. That matters because `AppEnvironment.shared` is built during process start,
/// including in the snapshot and gallery passes, which must not record anything.
@MainActor
public final class ActivityCapture {

    /// Where the day files are written. The same directory the privacy pane names on screen.
    public let log: any ActivityLog

    /// The forty bytes that make a crash recoverable.
    public let heartbeat: ActivityHeartbeat

    /// The ambient record itself.
    public let sampler: ActivitySampler

    /// The switch, the lists, the retention period and the delete buttons.
    public let privacy: PrivacyModel

    /// `nil` when Application Support could not be opened, in which case the log is in memory and
    /// the pane says so rather than naming a path that does not exist.
    public let directoryURL: URL?

    /// True when the log is the in-memory fallback: nothing recorded this run reaches the disk.
    public let isDurable: Bool

    @ObservationIgnored private let timeline: TimelineModel
    private var hasStarted = false

    public init(
        // Optional rather than defaulted to `.shared`, for the reason `PrivacyModel.controls`
        // carries the same shape: a default argument is evaluated in a nonisolated context, and
        // `TimelineModel.shared` is main-actor isolated. Resolving it in the body — which *is*
        // isolated — is the difference between a warning today and an error under Swift 6.
        timeline: TimelineModel? = nil,
        clock: any DateProviding = SystemClock(),
        defaults: UserDefaults = .standard
    ) {
        let timeline = timeline ?? .shared
        let directory = try? FileActivityLog.defaultDirectoryURL()

        // Falls back rather than throwing, for the same reason `StoreBootstrap` does: a machine
        // whose Application Support directory cannot be opened has a much larger problem than an
        // empty timeline, and the rest of the app keeps working. What is *not* acceptable is
        // pretending the fallback is durable, which is what `isDurable` exists to prevent.
        let log: any ActivityLog
        let durable: Bool
        if let file = try? FileActivityLog() {
            log = file
            durable = true
        } else {
            log = InMemoryActivityLog()
            durable = false
        }

        let privacy = PrivacyModel(
            defaults: defaults,
            activityLog: log,
            activityDirectoryURL: durable ? directory : nil,
            clock: clock
        )

        // The heartbeat lives beside the day files. When the directory is unknown there is nowhere
        // durable to put it; a path under the temporary directory keeps the object total rather
        // than optional, and a beat nobody can read back is exactly as useful as no beat at all —
        // which is the case the launch recovery already handles.
        let heartbeatURL =
            (try? ActivityHeartbeat.defaultFileURL())
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("lggr-heartbeat", isDirectory: false)

        let heartbeat = ActivityHeartbeat(fileURL: heartbeatURL, clock: clock)

        // Every batch is persisted and then folded into the timeline in memory. The write is first:
        // the screen may claim only what the disk already holds, and `apply(_:)` is what keeps
        // Today moving without a re-read.
        //
        // `try?` on both calls, deliberately. This runs from a timer or a notification with no user
        // in front of it; the failure the user needs to hear about is surfaced by the privacy pane
        // through `quarantineNotice`, and an alert on every flush would be worse than the fault.
        let flushHandler: ActivityFlushHandler = { batches in
            for batch in batches {
                guard let day = batch.dayKey() else { continue }
                try? await log.append(
                    intervals: batch.intervals,
                    gaps: batch.gaps,
                    to: day
                )
            }
            // One flush covers every batch, so the strongest promise any batch asked for is the one
            // the whole flush keeps. A sleep that happens to straddle midnight must not have the
            // yesterday half written with the weaker guarantee.
            let durability: FileDurability =
                batches.contains { $0.durability == .deviceSynced } ? .deviceSynced : .buffered
            try? await log.flush(durability: durability)
            timeline.apply(batches)
        }

        let lists = privacy.lists
        let sampler = ActivitySampler(
            configuration: ActivitySampler.Configuration(
                excludedApplications: lists.excluded,
                privateApplications: lists.privateActivity
            ),
            clock: clock,
            heartbeat: heartbeat,
            onFlush: flushHandler
        )

        self.log = log
        self.directoryURL = durable ? directory : nil
        self.isDurable = durable
        self.privacy = privacy
        self.heartbeat = heartbeat
        self.sampler = sampler
        self.timeline = timeline

        // The back-references. Both are why the pane is a control rather than a display: the glyph
        // reads `sampler.state` through `controls`, and a list edit reaches the running sampler
        // immediately instead of at the next activation.
        privacy.controls = .sampler(sampler)
        privacy.onApplicationListsChanged = { [weak sampler] lists in
            guard let sampler else { return }
            sampler.updateConfiguration(
                ActivitySampler.Configuration(
                    excludedApplications: lists.excluded,
                    privateApplications: lists.privateActivity
                )
            )
        }
    }

    // MARK: - Lifecycle

    /// Begins recording, after accounting for whatever the previous run left open.
    ///
    /// Idempotent for the same reason `AppEnvironment.bootstrap()` is: it is reachable from launch
    /// and from the first scene, and only one of those is guaranteed to happen.
    public func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        // Read the day before the sampler publishes anything into it, so the first flush merges into
        // a loaded day rather than triggering a second read to find one.
        await timeline.load()

        let previous = await previousRunState()
        sampler.start(
            lastRecordedEnd: previous.lastRecordedEnd,
            unresolvedSleepSince: previous.unresolvedSleepSince
        )

        // Retention is applied at launch and never on a timer: it is the one promise in the privacy
        // pane that a user cannot verify by looking at the screen, only by looking at the folder.
        await privacy.refreshRecordedDays()
        _ = await privacy.applyRetention()
    }

    /// Closes the open interval, writes everything buffered, and stands the timers down.
    ///
    /// Awaited by `applicationShouldTerminate`, so the bytes are on disk before the process replies.
    /// Without this, quitting costs up to a full flush period of activity — and the heartbeat would
    /// make that loss look like a crash on the next launch.
    public func prepareForTermination() async {
        await sampler.prepareForTermination()
        // The last write of the run, and the one place the day file is worth a device sync: after
        // this the process is gone and there is no later flush to make good on a buffered write.
        try? await log.flush(durability: .deviceSynced)

        // Last, and the order is the whole point. The sampler has just closed its open interval at
        // the instant of the quit, so the heartbeat — which last fired up to sixty seconds ago — is
        // now behind the record. Left there, the next launch computes the absence from the stale
        // beat and writes an `.appNotRunning` gap over intervals this same file records.
        //
        // A crash still leaves a stale beat, and still under-claims, which is correct: nothing
        // witnessed that time. A clean quit is the one case where the app *does* know how long it
        // was alive, and this is where it says so.
        await heartbeat.beatNowAwaitingWrite()
    }

    // MARK: - What the last run left behind

    /// The end of the last thing recorded, and an unclosed sleep if there was one.
    ///
    /// Only the most recent day file is read. Anything older cannot be the tail of the previous run
    /// by definition, and reading the whole folder at launch to establish one date would be a burst
    /// of disk work against acceptance criterion 8.
    private func previousRunState() async -> (lastRecordedEnd: Date?, unresolvedSleepSince: Date?) {
        guard
            let days = try? await log.availableDays(),
            let mostRecent = days.last,
            let record = try? await log.load(mostRecent)
        else { return (nil, nil) }

        let ends = record.intervals.map(\.end) + record.gaps.map(\.end)
        guard let lastRecordedEnd = ends.max() else { return (nil, nil) }

        // A sleep the previous run recorded and never closed is still the last thing in the file:
        // the sampler republishes an open gap on every flush with its end moved forward, so the one
        // that was open when the process stopped is the one that reaches the end of the record.
        // Passing it is what keeps a lid closed overnight from being reported as a crash.
        let unresolvedSleepSince =
            record.gaps
            .filter { $0.reason == .systemSleep && $0.end >= lastRecordedEnd }
            .map(\.start)
            .min()

        return (lastRecordedEnd, unresolvedSleepSince)
    }
}
