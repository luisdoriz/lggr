import Foundation
import LggrKit

/// A single timestamp on disk, rewritten once a minute, that says "Lggr was alive at this instant".
///
/// It is forty bytes and it is the most important forty bytes in Phase 1. Without it, a force-quit
/// at 14:30 followed by a relaunch at 16:10 leaves an interval that was open when the process died,
/// and the only honest thing to do with that interval is guess — which in practice means recording
/// a hundred-minute block of whatever application happened to be frontmost. Acceptance criteria 1
/// and 3 are both this file: the open interval is closed **at the last heartbeat**, never at launch
/// time, and the span between them becomes a `.appNotRunning` gap.
///
/// `willSleepNotification` cannot do this job. It is not delivered on power loss, on a kernel panic,
/// or on `kill -9`, which are three of the four ways an interval is left open. The heartbeat needs
/// no notification to be delivered; it simply stops being written.
///
/// ## Why it is its own file, and not a field in `store.json`
///
/// `JSONFileStore` rewrites its whole document on every save. A heartbeat in there is 1,440
/// full-document rewrites a day, growing with the store, for a value that is never read except at
/// launch. It is not in the day file either, for the same reason at smaller scale. One tiny file,
/// written atomically, is the whole mechanism.
@MainActor
public final class ActivityHeartbeat {

    /// How often the timestamp is rewritten. The flush cadence rides on this same beat, so the whole
    /// capture subsystem needs only two timers — this one and `IdleMonitor`'s.
    public static let period: TimeInterval = 60
    /// Generous, because nothing depends on the beat landing on time — only on it landing.
    public static let leeway: TimeInterval = 10

    /// How far the last heartbeat may lag a launch before the app is presumed to have been absent.
    ///
    /// One period plus its leeway plus room for a machine that was busy at the moment the beat was
    /// due. Below this, the gap would be indistinguishable from an ordinary quit-and-relaunch, and a
    /// gap the user cannot recognise is noise on a timeline whose whole value is that it is
    /// recognisable.
    public nonisolated static let absenceThreshold: TimeInterval = 90

    public let fileURL: URL

    /// The last instant successfully handed to the writer. Not read at launch — the file is.
    public private(set) var lastBeat: Date?

    private var timer: (any DispatchSourceTimer)?
    private var isSuspended = false
    private let clock: any DateProviding
    private var onBeat: ((Date) -> Void)?

    public init(fileURL: URL, clock: any DateProviding = SystemClock()) {
        self.fileURL = fileURL
        self.clock = clock
    }

    // MARK: - Locations

    /// `~/Library/Application Support/Lggr/activity/`.
    ///
    /// Activity lives in its own directory, one file per day, because that is what makes retention
    /// pruning and "delete all activity history" file deletions rather than row surgery — faster,
    /// and far easier for a user to verify by looking.
    public static func defaultDirectoryURL() throws -> URL {
        do {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return
                base
                .appendingPathComponent("Lggr", isDirectory: true)
                .appendingPathComponent("activity", isDirectory: true)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not locate the Application Support directory: \(error.localizedDescription)"
            )
        }
    }

    public static func defaultFileURL() throws -> URL {
        try defaultDirectoryURL().appendingPathComponent("heartbeat", isDirectory: false)
    }

    // MARK: - Format

    /// ISO 8601 with fractional seconds, in UTC.
    ///
    /// A text timestamp rather than a binary one so that the file answers its own question when a
    /// user `cat`s it — this is an app that asks to be checked rather than trusted, and forty
    /// readable bytes cost nothing.
    private nonisolated static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Reads the timestamp left by the previous run. `nil` on a first launch, and `nil` on a file
    /// that cannot be parsed — an unreadable heartbeat must never be mistaken for a recent one.
    public nonisolated static func readBeat(at url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return makeFormatter().date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func readLastBeatFromDisk() -> Date? {
        Self.readBeat(at: fileURL)
    }

    // MARK: - Lifecycle

    /// Starts beating, and beats once immediately so a crash in the first minute still leaves a
    /// usable anchor.
    public func start(onBeat: @escaping (Date) -> Void) {
        self.onBeat = onBeat
        beatNow()
        installTimer()
    }

    /// Stands the beat down. Called on sleep: the process is frozen anyway, and an armed timer is
    /// one more thing the kernel has to think about at wake.
    public func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        timer?.cancel()
        timer = nil
    }

    /// Resumes, writing immediately.
    ///
    /// The immediate write matters on wake: it re-anchors "alive" to now, so a crash five minutes
    /// later produces a five-minute `.appNotRunning` gap rather than one that reaches back across
    /// the whole night and collides with the sleep gap.
    public func resume() {
        guard isSuspended else { return }
        isSuspended = false
        beatNow()
        installTimer()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isSuspended = false
        onBeat = nil
    }

    /// Writes the current instant now, off the beat.
    public func beatNow() {
        let now = clock.now
        lastBeat = now
        write(now)
        onBeat?(now)
    }

    /// Writes the current instant and does not return until the bytes are on disk.
    ///
    /// **The terminate path, and only that path.** Everywhere else `beatNow()` is right: it hands the
    /// write to a detached task so the main actor is never blocked on `F_FULLFSYNC`, and it can
    /// afford to lose one write because another beat is sixty seconds away.
    ///
    /// At quit there is no next beat, and the consequence of skipping this is not a missing forty
    /// bytes — it is a *stale* forty bytes. The sampler closes its open interval and flushes at the
    /// instant of the quit, so without a matching beat the file's last interval ends up to a minute
    /// later than the last heartbeat. The next launch reads that difference as a stretch where Lggr
    /// was not running, and writes an `.appNotRunning` gap straight across intervals the very same
    /// day file records. A record that contradicts itself is worse than one that admits ignorance,
    /// and this is the cheapest place to make the two agree.
    ///
    /// Call it *after* the final flush, never before: the beat has to be at least as late as the
    /// last thing recorded, or it reintroduces the overlap it exists to remove.
    public func beatNowAwaitingWrite() async {
        let now = clock.now
        lastBeat = now
        onBeat?(now)

        let url = fileURL
        guard let data = Self.makeFormatter().string(from: now).data(using: .utf8) else { return }
        await Task.detached(priority: .userInitiated) {
            try? AtomicFileWriter.write(data, to: url)
        }.value
    }

    private func installTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + Self.period,
            repeating: Self.period,
            leeway: .seconds(Int(Self.leeway))
        )
        source.setEventHandler {
            MainActor.assumeIsolated { [weak self] in self?.beatNow() }
        }
        source.resume()
        timer = source
    }

    /// Off the main actor: `AtomicFileWriter` ends in `F_FULLFSYNC`, which can block for tens of
    /// milliseconds on a busy disk, and the main actor is where the menu bar clock redraws.
    ///
    /// A failed write is silent by design. The heartbeat's only consumer is the next launch, where a
    /// missing beat is already handled as "the app was not running" — which, from the timeline's
    /// point of view, is exactly what a disk that will not accept writes amounts to. Surfacing an
    /// alert once a minute would be worse than the failure.
    private func write(_ instant: Date) {
        let url = fileURL
        guard let data = Self.makeFormatter().string(from: instant).data(using: .utf8) else { return }
        Task.detached(priority: .utility) {
            try? AtomicFileWriter.write(data, to: url)
        }
    }
}

/// What the last run left behind, and what the timeline owes the user because of it.
///
/// Pure, static, and deliberately free of the store: it takes three dates and returns a decision, so
/// the precedence between "the machine slept" and "Lggr was not running" is one readable function
/// rather than a condition spread across a launch sequence.
///
/// That precedence is the whole point. `.systemSleep` and `.appNotRunning` collide every single
/// night — the app is not beating while the machine is asleep — and acceptance criterion 2 requires
/// that a lid closed at 18:00 and opened at 09:00 produce **one** sleep gap. Mislabelling the most
/// common event in the corpus as a crash would discredit the mechanism that exists to be believed.
public enum ActivityLaunchRecovery {

    public struct Outcome: Equatable, Sendable {
        /// Any interval still open in the previous run must be closed here — the last heartbeat,
        /// never the launch time. `nil` when nothing needs closing.
        public var closeOpenIntervalsAt: Date?
        /// The absence, typed. `nil` when the app was only away for an ordinary relaunch.
        public var gap: Gap?

        public static let nothingToDo = Outcome(closeOpenIntervalsAt: nil, gap: nil)
    }

    /// - Parameters:
    ///   - lastHeartbeat: the timestamp in `activity/heartbeat`, or `nil` on a first launch.
    ///   - lastRecordedEnd: the end of the last interval or gap in the activity files.
    ///   - unresolvedSleepSince: the start of a `.systemSleep` gap that was recorded but never
    ///     closed, meaning the previous run went to sleep and never came back. Supplying this is what
    ///     stops a normal night from being reported as a crash.
    ///   - launchedAt: now.
    public static func plan(
        lastHeartbeat: Date?,
        lastRecordedEnd: Date?,
        unresolvedSleepSince: Date? = nil,
        launchedAt: Date,
        absenceThreshold: TimeInterval = ActivityHeartbeat.absenceThreshold
    ) -> Outcome {
        // "Alive" is the latest thing the previous run is known to have done.
        let alive = [lastHeartbeat, lastRecordedEnd].compactMap { $0 }.max()
        guard let alive, alive < launchedAt else { return .nothingToDo }
        guard launchedAt.timeIntervalSince(alive) > max(0, absenceThreshold) else {
            return .nothingToDo
        }

        // Criterion 3, verbatim: close at the last heartbeat. When a flush landed after the last
        // beat, the beat is still the conservative choice — under-claiming is the acceptable failure
        // direction, and the alternative is claiming time nothing witnessed.
        let closeAt = lastHeartbeat ?? alive

        // Precedence. A sleep the previous run recorded and never closed accounts for the absence,
        // and the app not beating through it is a consequence of the sleep rather than a second
        // event. Ordering the sleep test first is what keeps the two gaps from ever both appearing.
        if let sleepStart = unresolvedSleepSince, sleepStart <= alive {
            return Outcome(
                closeOpenIntervalsAt: min(closeAt, sleepStart),
                gap: Gap(reason: .systemSleep, start: sleepStart, end: launchedAt)
            )
        }

        return Outcome(
            closeOpenIntervalsAt: closeAt,
            gap: Gap(reason: .appNotRunning, start: closeAt, end: launchedAt)
        )
    }
}
