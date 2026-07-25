import AppKit
import Foundation
import LggrKit
import UniformTypeIdentifiers

// The state behind Settings → Privacy, and behind the menu bar's tracking glyph.
//
// Lggr keeps a quiet record of which application is in front of you, all day, whether or not you
// asked it to start. That is the whole of Phase 1 and it is the reason this file exists: an app that
// records without being asked owes the person using it a switch, a list, a retention period, a
// delete button, and a plain statement of what is on disk. Everything here is one of those five.
//
// Two properties this file is built to hold, and which a later change must not quietly drop:
//
//   1. **Redaction happens before the write, never at display time.** An application marked private
//      reaches `ActivitySampler` as a configuration value, and the sampler replaces its identity
//      *before* the interval is handed to anything. There is no code path in which the real bundle
//      identifier is written and then hidden, so no later rendering bug can surface what was
//      discarded.
//   2. **The lists are the sampler's input, not a filter over its output.** Every mutation publishes
//      the whole pair through `onApplicationListsChanged`, and `ActivitySampler.updateConfiguration`
//      re-reads the frontmost application at once — so excluding the application you are looking at
//      takes effect while you are looking at it, rather than at the next activation an hour later.

// MARK: - An application, as the user sees it

/// One application in a list the user manages.
///
/// Identity is the bundle identifier; the display name travels alongside it so a list entry still
/// reads as "Messages" after the application has been renamed, moved or uninstalled. The same
/// arrangement `ShapeOfWork.App` uses, for the same reason.
public struct TrackedApplication: Identifiable, Hashable, Sendable, Codable, Comparable {

    public let bundleIdentifier: String
    public var displayName: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, displayName: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmed.isEmpty ? bundleIdentifier : trimmed
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }

    /// Alphabetical by the name on screen, with the identifier as a total tie-break so two
    /// applications that share a name never swap places between launches.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let left = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if left != .orderedSame { return left == .orderedAscending }
        return lhs.bundleIdentifier < rhs.bundleIdentifier
    }

    /// Reads an application bundle the user picked from disk.
    ///
    /// `nil` for anything without a bundle identifier — a shell script, a folder named `.app`, a
    /// bundle with a broken `Info.plist`. An entry with no identifier could never match anything the
    /// sampler sees, and a list row that silently does nothing is worse than a refusal.
    public init?(applicationAt url: URL) {
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else {
            return nil
        }
        let info = bundle.localizedInfoDictionary ?? bundle.infoDictionary
        let name =
            (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        self.init(bundleIdentifier: identifier, displayName: name)
    }
}

/// What Lggr does about an application.
///
/// Two rules and no third. "Record it normally" is the absence of a rule rather than a case, so the
/// lists on screen contain only the applications the user has said something about.
public enum ApplicationRule: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {

    public var id: String { rawValue }


    /// The interval is kept so the day still adds up; the identity is dropped before anything is
    /// written. The timeline shows the time as private activity and cannot show more, because there
    /// is nothing more on disk.
    case privateActivity

    /// Nothing is recorded at all. The time becomes a typed absence on the timeline —
    /// `GapReason.excludedApplication` — which is visible as an absence rather than silently missing.
    case excluded

    /// Facts about the record, never about the person.
    public var title: String {
        switch self {
        case .privateActivity: "Private"
        case .excluded: "Not recorded"
        }
    }
}

/// The two sets `ActivitySampler.Configuration` needs, published together so they can never be
/// applied half-updated.
public struct ApplicationLists: Hashable, Sendable {
    public var excluded: Set<String>
    public var privateActivity: Set<String>

    public init(excluded: Set<String> = [], privateActivity: Set<String> = []) {
        self.excluded = excluded
        self.privateActivity = privateActivity
    }
}

/// Receives the lists whenever they change, so the running sampler follows the screen.
public typealias ApplicationListsHandler = @MainActor (ApplicationLists) -> Void

// MARK: - Retention

/// How long activity is kept.
///
/// The four choices `04-screens.md` § 4.7 draws, and no free-text field: a retention period a user
/// has to type is a retention period they get wrong once and never check again.
public enum RetentionPeriod: Hashable, Sendable, Identifiable {
    case days(Int)
    /// Nothing expires. Not a default — a choice, and stated as one.
    case forever

    public var id: Int {
        switch self {
        case .days(let days): days
        case .forever: 0
        }
    }

    /// What Settings offers, in the order it draws them.
    public static let offered: [RetentionPeriod] = [.days(30), .days(90), .days(365), .forever]

    public static let `default` = RetentionPeriod.days(90)

    public var title: String {
        switch self {
        case .days(let days) where days % 365 == 0 && days >= 365:
            let years = days / 365
            return years == 1 ? "1 year" : "\(years) years"
        case .days(let days):
            return days == 1 ? "1 day" : "\(days) days"
        case .forever:
            return "Keep everything"
        }
    }

    /// The oldest day that survives. Everything strictly before it is deleted.
    ///
    /// `nil` for `.forever`, which is the whole reason this returns an optional rather than a very
    /// large number: "keep everything" is a different statement from "keep a hundred years", and a
    /// sentinel that pretends otherwise is the kind of thing that eventually deletes something.
    public func earliestDayKept(from now: Date, in calendar: Calendar) -> ActivityDayKey? {
        guard case .days(let days) = self, days > 0 else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -(days - 1), to: today) else {
            return nil
        }
        return ActivityDayKey(date: cutoff, in: calendar)
    }

    fileprivate var storedValue: Int {
        switch self {
        case .days(let days): max(1, days)
        case .forever: 0
        }
    }

    fileprivate init(storedValue: Int) {
        self = storedValue <= 0 ? .forever : .days(storedValue)
    }
}

// MARK: - The tracking switch

/// Pause and resume, and the current answer — as three functions, so nothing here depends on the
/// sampler having been wired.
///
/// `currentState` is a function rather than a stored value on purpose. Called synchronously from a
/// SwiftUI `body` it reads `ActivitySampler.state` inside that body's observation scope, so the
/// glyph invalidates when the state moves. A snapshot passed down as a plain value would not, and
/// the menu bar would freeze on whatever it said at launch — the same trap `SPIKE-menubar.md`
/// documents for the timer.
@MainActor
public struct TrackingControls {

    public var currentState: () -> ActivityTrackingState
    public var setPaused: (Bool) -> Void

    public init(
        currentState: @escaping () -> ActivityTrackingState,
        setPaused: @escaping (Bool) -> Void
    ) {
        self.currentState = currentState
        self.setPaused = setPaused
    }

    /// The real thing.
    public static func sampler(_ sampler: ActivitySampler) -> TrackingControls {
        TrackingControls(
            currentState: { sampler.state },
            setPaused: { paused in
                if paused {
                    sampler.pause()
                } else {
                    sampler.resumeTracking()
                }
            }
        )
    }

    /// Nothing is wired. Reports `.suspended(.notStarted)` — "Not tracking" — which is the honest
    /// answer for a build with no sampler in it, and never a cheerful one.
    public static let unavailable = TrackingControls(
        currentState: { .suspended(.notStarted) },
        setPaused: { _ in }
    )

    /// A frozen state, for the light/dark gallery and the snapshot renderer.
    public static func fixed(_ state: ActivityTrackingState) -> TrackingControls {
        TrackingControls(currentState: { state }, setPaused: { _ in })
    }
}

// MARK: - The model

/// Everything Settings → Privacy shows, and the only writer of it.
///
/// Each setting lives under its own `UserDefaults` key — the same arrangement, and for the same
/// reason, as `AppPreferences`: `SessionManager` rewrites the whole `UserPreferences` blob whenever
/// it remembers a project, so a screen that wrote into the blob directly would have its changes
/// erased by the next session that started. The blob is mirrored, never treated as the source.
@MainActor
@Observable
public final class PrivacyModel {

    // MARK: Shipped defaults

    /// The applications Lggr treats as private out of the box.
    ///
    /// Pre-populated rather than merely available, because a privacy list that starts empty protects
    /// nobody on day one, and day one is when a person decides whether to keep the app. Every entry
    /// here is an application whose mere presence on a timeline says something about a person's life
    /// rather than their work: their mail, their messages, their password vault, their photographs,
    /// their medical appointments, the book they are reading.
    ///
    /// Editable in both directions. The user can remove any of them, and a removal is remembered —
    /// see `retiredDefaults` — so an entry the user deliberately took out does not reappear at the
    /// next launch.
    public static let shippedPrivateApplications: [TrackedApplication] = [
        TrackedApplication(bundleIdentifier: "com.apple.mail", displayName: "Mail"),
        TrackedApplication(bundleIdentifier: "com.apple.MobileSMS", displayName: "Messages"),
        TrackedApplication(bundleIdentifier: "com.apple.Notes", displayName: "Notes"),
        TrackedApplication(bundleIdentifier: "com.1password.1password", displayName: "1Password"),
        TrackedApplication(bundleIdentifier: "com.agilebits.onepassword7", displayName: "1Password 7"),
        TrackedApplication(bundleIdentifier: "com.apple.keychainaccess", displayName: "Keychain Access"),
        TrackedApplication(bundleIdentifier: "com.apple.Preview", displayName: "Preview"),
        TrackedApplication(bundleIdentifier: "com.apple.Photos", displayName: "Photos"),
        TrackedApplication(bundleIdentifier: "com.apple.iCal", displayName: "Calendar"),
        TrackedApplication(bundleIdentifier: "com.apple.AddressBook", displayName: "Contacts"),
        TrackedApplication(bundleIdentifier: "com.apple.FaceTime", displayName: "FaceTime"),
        TrackedApplication(bundleIdentifier: "com.apple.iBooksX", displayName: "Books"),
    ]

    /// Bumped only when a later version adds to the shipped list. Anything already retired by the
    /// user stays retired across the bump.
    private static let shippedDefaultsVersion = 1

    /// How many recent days are read to populate the application picker.
    ///
    /// The picker is built from applications Lggr has actually seen, never from an enumeration of
    /// everything installed: walking `/Applications` at launch is a burst of disk work for a list
    /// nobody has asked for yet, and acceptance criterion 8 — no significant energy over an
    /// eight-hour battery day — is a Phase 1 gate. Two weeks is enough to contain everything a
    /// person reaches for regularly; anything rarer is one file picker away.
    public static let pickerDayLimit = 14

    // MARK: Keys

    private static let privateKey = "com.lggr.privacy.privateApplications"
    private static let excludedKey = "com.lggr.privacy.excludedApplications"
    private static let retiredKey = "com.lggr.privacy.retiredDefaults"
    private static let seededVersionKey = "com.lggr.privacy.seededDefaultsVersion"
    private static let retentionKey = "com.lggr.privacy.retentionDays"

    /// The blob `SessionManager` loads at launch, mirrored into for the benefit of anything that
    /// reads it. Duplicated from `AppPreferences` because the constant is private to that file; if
    /// one changes, so does the other.
    private static let storedPreferencesKey = "com.lggr.preferences"

    // MARK: Observable state

    /// Time kept, identity dropped. Sorted by the name on screen.
    public private(set) var privateApplications: [TrackedApplication]

    /// Nothing recorded at all. Sorted by the name on screen.
    public private(set) var excludedApplications: [TrackedApplication]

    /// How long activity files are kept. Changing this does **not** delete anything on its own —
    /// see `daysExpiring(under:)` and `applyRetention()`, which exist so the screen can name what a
    /// shorter period would remove before it removes it.
    public var retention: RetentionPeriod {
        get {
            access(keyPath: \.retention)
            return retentionStorage
        }
        set {
            guard newValue != retentionStorage else { return }
            withMutation(keyPath: \.retention) { retentionStorage = newValue }
            defaults.set(newValue.storedValue, forKey: Self.retentionKey)
            mirrorIntoStoredPreferences()
        }
    }

    /// Every day with a file on disk, oldest first. Empty until `refreshRecordedDays()` has run.
    public private(set) var recordedDays: [ActivityDayKey] = []

    /// Applications Lggr has seen recently, for the picker. Empty until `loadSeenApplications()`
    /// has run, which the picker does when it opens and never at launch.
    public private(set) var seenApplications: [TrackedApplication] = []

    /// A disk operation is in flight. The delete controls dim rather than disappear.
    public private(set) var isWorking = false

    /// What just happened, as a fact. Set by the delete and retention paths so the screen can state
    /// the outcome instead of the user having to infer it from a list that got shorter.
    public private(set) var lastOutcome: String?

    /// A disk operation failed, stated plainly. Never a stack trace, never a code.
    public private(set) var failure: String?

    /// Set when a day file could not be read and was preserved under another name. Surfaced here
    /// because an unreadable day must never be indistinguishable from a day nobody worked.
    public var quarantineNotice: String? { activityLog?.quarantineNotice }

    // MARK: Collaborators

    @ObservationIgnored private var retentionStorage: RetentionPeriod
    @ObservationIgnored private var retiredDefaults: Set<String>
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let activityLog: (any ActivityLog)?
    @ObservationIgnored private let clock: any DateProviding
    @ObservationIgnored private let calendar: Calendar

    /// Where the day files are, for the sentence on screen that gives the real path. `nil` when
    /// nothing durable is wired, in which case the screen says so rather than naming a path that
    /// does not exist.
    @ObservationIgnored public let activityDirectoryURL: URL?

    /// Pause and resume. Assignable so the composition root can hand over the real sampler after
    /// this model is built.
    @ObservationIgnored public var controls: TrackingControls

    /// Called after every change to either list, with both lists.
    @ObservationIgnored public var onApplicationListsChanged: ApplicationListsHandler?

    public init(
        defaults: UserDefaults = .standard,
        activityLog: (any ActivityLog)? = nil,
        activityDirectoryURL: URL? = nil,
        // Optional rather than defaulted to `.unavailable`: a default argument is evaluated in a
        // nonisolated context, and `TrackingControls` is main-actor isolated because its closures
        // touch the sampler.
        controls: TrackingControls? = nil,
        clock: any DateProviding = SystemClock(),
        calendar: Calendar = .autoupdatingCurrent,
        onApplicationListsChanged: ApplicationListsHandler? = nil
    ) {
        self.defaults = defaults
        self.activityLog = activityLog
        self.activityDirectoryURL = activityDirectoryURL
        self.controls = controls ?? .unavailable
        self.clock = clock
        self.calendar = calendar
        self.onApplicationListsChanged = onApplicationListsChanged

        self.retiredDefaults = Set(defaults.stringArray(forKey: Self.retiredKey) ?? [])

        let storedRetention = defaults.object(forKey: Self.retentionKey) as? Int
        self.retentionStorage =
            storedRetention.map(RetentionPeriod.init(storedValue:)) ?? .default

        var loadedPrivate = Self.loadApplications(Self.privateKey, from: defaults)
        let loadedExcluded = Self.loadApplications(Self.excludedKey, from: defaults)

        // Seed the shipped list once. Anything the user has already excluded stays excluded — the
        // stronger rule wins, and an application cannot be on both lists.
        let seededVersion = defaults.integer(forKey: Self.seededVersionKey)
        if seededVersion < Self.shippedDefaultsVersion {
            let known = Set(loadedPrivate.map(\.bundleIdentifier))
                .union(loadedExcluded.map(\.bundleIdentifier))
                .union(retiredDefaults)
            loadedPrivate.append(
                contentsOf: Self.shippedPrivateApplications.filter {
                    !known.contains($0.bundleIdentifier)
                }
            )
            defaults.set(Self.shippedDefaultsVersion, forKey: Self.seededVersionKey)
        }

        self.privateApplications = loadedPrivate.sorted()
        self.excludedApplications = loadedExcluded.sorted()

        // Written straight back rather than only on the next edit: the seeded defaults have to be on
        // disk before the first application switch, or a crash in the first minute would record the
        // name of an application the shipped list says is private.
        persistApplications()
        mirrorIntoStoredPreferences()
    }

    // MARK: - Tracking

    public var trackingState: ActivityTrackingState { controls.currentState() }

    public var isPaused: Bool { trackingState == .paused }

    public func pauseTracking() { controls.setPaused(true) }

    public func resumeTracking() { controls.setPaused(false) }

    public func toggleTracking() { controls.setPaused(!isPaused) }

    // MARK: - The lists

    public var lists: ApplicationLists {
        ApplicationLists(
            excluded: Set(excludedApplications.map(\.bundleIdentifier)),
            privateActivity: Set(privateApplications.map(\.bundleIdentifier))
        )
    }

    /// What Lggr does about this application right now.
    public func rule(for bundleIdentifier: String) -> ApplicationRule? {
        if excludedApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return .excluded
        }
        if privateApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return .privateActivity
        }
        return nil
    }

    /// Sets, moves or clears an application's rule. `nil` returns it to being recorded normally.
    ///
    /// One entry point for all four transitions, so an application can never end up on both lists —
    /// a state in which the sampler's exclusion test would win and the private list would be a lie
    /// the screen was telling.
    public func setRule(_ rule: ApplicationRule?, for application: TrackedApplication) {
        privateApplications.removeAll { $0 == application }
        excludedApplications.removeAll { $0 == application }

        switch rule {
        case .privateActivity:
            privateApplications.append(application)
            retiredDefaults.remove(application.bundleIdentifier)
        case .excluded:
            excludedApplications.append(application)
            retiredDefaults.remove(application.bundleIdentifier)
        case nil:
            // A shipped default the user removed on purpose stays removed. Re-adding it at the next
            // launch would be the app overruling a decision the user made about their own machine.
            if Self.shippedPrivateApplications.contains(application) {
                retiredDefaults.insert(application.bundleIdentifier)
            }
        }

        privateApplications.sort()
        excludedApplications.sort()
        commitApplications()
    }

    public func remove(_ application: TrackedApplication) {
        setRule(nil, for: application)
    }

    /// Puts back every shipped default the user has removed. Nothing else is touched: an application
    /// the user added themselves keeps whatever rule they gave it.
    public func restoreShippedPrivateApplications() {
        let known = Set(privateApplications.map(\.bundleIdentifier))
            .union(excludedApplications.map(\.bundleIdentifier))
        let missing = Self.shippedPrivateApplications.filter { !known.contains($0.bundleIdentifier) }
        guard !missing.isEmpty else { return }

        privateApplications.append(contentsOf: missing)
        privateApplications.sort()
        for application in missing { retiredDefaults.remove(application.bundleIdentifier) }
        commitApplications()
    }

    /// True when at least one shipped default is absent, so the screen can offer to restore them
    /// only when there is something to restore.
    public var hasRemovedShippedDefaults: Bool {
        let known = Set(privateApplications.map(\.bundleIdentifier))
            .union(excludedApplications.map(\.bundleIdentifier))
        return Self.shippedPrivateApplications.contains { !known.contains($0.bundleIdentifier) }
    }

    public func isShippedDefault(_ application: TrackedApplication) -> Bool {
        Self.shippedPrivateApplications.contains(application)
    }

    private func commitApplications() {
        persistApplications()
        mirrorIntoStoredPreferences()
        onApplicationListsChanged?(lists)
    }

    // MARK: - Choosing an application

    /// Applications Lggr has recorded recently and that have no rule yet — the picker's contents.
    public var pickableApplications: [TrackedApplication] {
        seenApplications.filter { rule(for: $0.bundleIdentifier) == nil }
    }

    /// Reads the recent day files and collects the distinct applications in them.
    ///
    /// Called when the picker opens, never at launch. Days are read newest first and the private
    /// sentinel is dropped: an interval recorded as private carries no real identity, so offering
    /// "Private" as something to mark private would be offering a row that means nothing.
    public func loadSeenApplications() async {
        guard let activityLog else { return }
        do {
            let days = try await activityLog.availableDays().suffix(Self.pickerDayLimit)
            var found: [String: TrackedApplication] = [:]
            for day in days.reversed() {
                let record = try await activityLog.load(day)
                for interval in record.intervals
                where interval.bundleIdentifier != ActivitySampler.privateBundleIdentifier {
                    if found[interval.bundleIdentifier] == nil {
                        found[interval.bundleIdentifier] = TrackedApplication(
                            bundleIdentifier: interval.bundleIdentifier,
                            displayName: interval.displayName
                        )
                    }
                }
            }
            seenApplications = found.values.sorted()
            failure = nil
        } catch {
            seenApplications = []
            failure = Self.plainMessage(for: error)
        }
    }

    /// Opens a file picker so an application Lggr has never seen can still be listed.
    ///
    /// The counterpart to building the picker from what has been recorded: the list of seen
    /// applications is short and honest, and this is how the user reaches everything else without
    /// Lggr walking their disk to find it.
    @discardableResult
    public func chooseApplication(rule: ApplicationRule) -> TrackedApplication? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add"
        panel.message =
            rule == .excluded
            ? "Choose an application for Lggr to record nothing about."
            : "Choose an application for Lggr to record as private activity."

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let application = TrackedApplication(applicationAt: url) else {
            failure = "\(url.lastPathComponent) has no application identifier, so Lggr cannot list it."
            return nil
        }
        failure = nil
        setRule(rule, for: application)
        return application
    }

    // MARK: - History

    public func refreshRecordedDays() async {
        guard let activityLog else {
            recordedDays = []
            return
        }
        do {
            recordedDays = try await activityLog.availableDays()
            failure = nil
        } catch {
            failure = Self.plainMessage(for: error)
        }
    }

    /// The days a retention period would remove, computed from what is already loaded — no disk, so
    /// the screen can name the cost of a shorter period before the user commits to it.
    public func daysExpiring(under period: RetentionPeriod) -> [ActivityDayKey] {
        guard let earliest = period.earliestDayKept(from: clock.now, in: calendar) else { return [] }
        return recordedDays.filter { $0 < earliest }
    }

    /// Deletes everything older than the current retention period.
    @discardableResult
    public func applyRetention() async -> [ActivityDayKey] {
        guard let activityLog,
            let earliest = retention.earliestDayKept(from: clock.now, in: calendar)
        else { return [] }

        isWorking = true
        defer { isWorking = false }

        do {
            let removed = try await activityLog.pruneDays(before: earliest)
            await refreshRecordedDays()
            lastOutcome = removed.isEmpty ? nil : Self.removedMessage(removed.count)
            failure = nil
            return removed
        } catch {
            failure = Self.plainMessage(for: error)
            return []
        }
    }

    /// Deletes one day's file.
    public func deleteDay(_ day: ActivityDayKey) async {
        guard let activityLog else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await activityLog.delete(day)
            await refreshRecordedDays()
            lastOutcome = "Deleted the activity for \(day.rawValue)."
            failure = nil
        } catch {
            failure = Self.plainMessage(for: error)
        }
    }

    /// Deletes every day file.
    ///
    /// A file deletion rather than row surgery, which is most of why activity is stored one file per
    /// day: the user can open the folder afterwards and see for themselves that it is empty.
    public func deleteAllHistory() async {
        guard let activityLog else { return }
        let count = recordedDays.count
        isWorking = true
        defer { isWorking = false }
        do {
            try await activityLog.deleteAll()
            await refreshRecordedDays()
            lastOutcome = count == 0 ? "There was nothing to delete." : Self.removedMessage(count)
            failure = nil
        } catch {
            failure = Self.plainMessage(for: error)
        }
    }

    public func clearOutcome() {
        lastOutcome = nil
        failure = nil
    }

    private static func removedMessage(_ count: Int) -> String {
        count == 1 ? "Deleted 1 day of activity." : "Deleted \(count) days of activity."
    }

    /// A sentence, never a code.
    ///
    /// `StoreError` is a plain `Error` rather than a `LocalizedError`, so `localizedDescription`
    /// would render "The operation couldn't be completed" and throw away the message the store
    /// wrote for exactly this moment. The associated value is unwrapped instead.
    private static func plainMessage(for error: any Error) -> String {
        switch error {
        case StoreError.invalidData(let message), StoreError.persistenceFailure(let message):
            return message
        case StoreError.notFound:
            return "Lggr could not find that activity."
        default:
            return error.localizedDescription
        }
    }

    // MARK: - Persistence

    private static func loadApplications(
        _ key: String,
        from defaults: UserDefaults
    ) -> [TrackedApplication] {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([TrackedApplication].self, from: data)
        else { return [] }
        // Deduplicated on the way in: a file edited by hand, or written by two builds, must not be
        // able to put one application on a list twice and give the row a duplicate identity.
        var seen = Set<String>()
        return decoded.filter { seen.insert($0.bundleIdentifier).inserted }
    }

    private func persistApplications() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(privateApplications) {
            defaults.set(data, forKey: Self.privateKey)
        }
        if let data = try? encoder.encode(excludedApplications) {
            defaults.set(data, forKey: Self.excludedKey)
        }
        defaults.set(retiredDefaults.sorted(), forKey: Self.retiredKey)
    }

    /// Copies the lists into the shared `UserPreferences` blob, preserving everything else in it.
    ///
    /// Load-modify-save, exactly as `AppPreferences` does: the blob also carries the remembered
    /// project and the recent outcomes, and this screen has no business forgetting either.
    ///
    /// `retention` is mirrored only when it is a finite number of days. `dataRetentionDays` is an
    /// `Int` clamped to at least one day and therefore cannot represent "keep everything"; writing a
    /// large finite number in its place would put a claim in the user's file that the user never
    /// made. The key above is the source of truth for retention, and the blob's field is left as it
    /// was found.
    private func mirrorIntoStoredPreferences() {
        var stored = Self.loadStoredPreferences(from: defaults)
        let excluded = excludedApplications.map(\.bundleIdentifier)
        let privates = privateApplications.map(\.bundleIdentifier)
        var retentionDays = stored.dataRetentionDays
        if case .days(let days) = retentionStorage { retentionDays = days }

        guard stored.excludedApplications != excluded
            || stored.privateApplications != privates
            || stored.dataRetentionDays != retentionDays
        else { return }

        stored.excludedApplications = excluded
        stored.privateApplications = privates
        stored.dataRetentionDays = retentionDays
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storedPreferencesKey)
    }

    private static func loadStoredPreferences(from defaults: UserDefaults) -> UserPreferences {
        guard let data = defaults.data(forKey: storedPreferencesKey),
            let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else { return .default }
        return decoded
    }
}

// MARK: - What is on disk

/// One line of the "What Lggr keeps" table.
///
/// A promise a user cannot inspect is marketing, so the table is a value rather than a paragraph:
/// every claim is a row, every row is either kept or never kept, and a reviewer can check each one
/// against `ActivityInterval`'s stored properties in under a minute. `ActivityInterval` has no field
/// for a window title and is not permitted to gain one.
public struct RecordFact: Identifiable, Hashable, Sendable {
    public let subject: String
    public let isKept: Bool
    /// What it looks like on disk, or why it is not there. One short clause.
    public let detail: String

    public var id: String { subject }

    public init(subject: String, isKept: Bool, detail: String) {
        self.subject = subject
        self.isKept = isKept
        self.detail = detail
    }
}

extension RecordFact {

    /// Everything an activity file contains, field by field.
    ///
    /// Read straight off `ActivityInterval`'s stored properties, in their order. If a field is added
    /// to that type, a row belongs here in the same change.
    public static let kept: [RecordFact] = [
        RecordFact(
            subject: "The application in front of you",
            isKept: true,
            detail: "Its name and its identifier — “Xcode”, com.apple.dt.Xcode."
        ),
        RecordFact(
            subject: "When it came to the front, and for how long",
            isKept: true,
            detail: "Measured on a clock that a time change cannot stretch."
        ),
        RecordFact(
            subject: "Whether the keyboard and trackpad went quiet",
            isKept: true,
            detail: "How long they were quiet for, not what was typed."
        ),
        RecordFact(
            subject: "Time away from the machine",
            isKept: true,
            detail: "Sleep, a locked screen, a paused stretch — each with its reason."
        ),
        RecordFact(
            subject: "Your time zone offset",
            isKept: true,
            detail: "So a day still reads correctly after a flight."
        ),
    ]

    /// The refusals. Every one of them is a thing at least one design proposal asked for and did not
    /// get, and each is a property of the code rather than a policy: there is no field to put them
    /// in and no API that reads them.
    public static let neverKept: [RecordFact] = [
        RecordFact(
            subject: "Window titles",
            isKept: false,
            detail: "Not for thirty days, not for a minute. Lggr never reads one."
        ),
        RecordFact(
            subject: "What you type, see, copy or send",
            isKept: false,
            detail: "No keystrokes, no clipboard, no screenshots."
        ),
        RecordFact(
            subject: "Documents, messages, mail and web addresses",
            isKept: false,
            detail: "Lggr cannot see inside an application, only which one is in front."
        ),
        RecordFact(
            subject: "Anything about an application you have excluded",
            isKept: false,
            detail: "The time shows on the timeline as an absence, with nothing attached."
        ),
        RecordFact(
            subject: "The name of an application you have marked private",
            isKept: false,
            detail:
                "Replaced with the single word “Private” before the file is written — the same word "
                + "for every one of them, so no two can be told apart afterwards."
        ),
    ]

    /// The permissions Lggr asks for. There are none, and stating the empty set is the claim.
    public static let permissionsStatement =
        "Lggr asks macOS for no permissions to do this — no Accessibility, no automation, no "
        + "calendar, no microphone, no screen recording. It does not send any of it anywhere."
}
