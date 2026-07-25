import AppKit
import Foundation
import LggrKit
import SwiftUI

// The composition root. See docs/_design/02-architecture.md § 5.1.
//
// One object, built once, holding the store, the ambient capture subsystem, and the pieces of state
// every scene needs. There is still no classification, no notifications and no permissions service,
// so none of them are declared here: an environment full of `nil` collaborators is a promise the app
// cannot keep, and every one of them arrives with the phase that gives it something to do.
//
// Phase 1 capture is composed in `ActivityCapture` rather than inline here, because the order the
// four objects have to be built in is a fact worth writing down once — see that file.

/// Everything the application is made of, assembled once.
@MainActor
@Observable
public final class AppEnvironment {

    // Everything here is a constant, so none of it is observable and all of it is marked as such —
    // the same convention `SessionManager` and `AppModel` use for their collaborators.

    /// The persistence boundary. Only the terminate-time flush touches it directly; everything else
    /// goes through `SessionManager`.
    @ObservationIgnored public let store: any LggrStore

    /// Which backend actually opened, and why it might not be the preferred one.
    @ObservationIgnored public let storage: StorageSummary

    @ObservationIgnored public let clock: any DateProviding
    @ObservationIgnored public let sessionManager: SessionManager
    @ObservationIgnored public let appModel: AppModel

    /// The two Phase 2 settings, and the only writer of them.
    @ObservationIgnored public let preferences: AppPreferences

    /// Ambient capture: the sampler, its heartbeat, the day files it writes, and the privacy model
    /// that governs all three. Inert until `bootstrap()` starts it.
    @ObservationIgnored public let capture: ActivityCapture

    /// The interruption inbox: what `⌘⇧I` writes into, and where it is processed.
    ///
    /// Owned here rather than by a view for the same reason capture is: `⌘⇧I` works with every window
    /// closed, so the object it writes into cannot belong to a window's lifetime.
    @ObservationIgnored public let inbox: InboxModel

    /// The four exports, as a clipboard and a save panel over `LggrKit/Export/`.
    ///
    /// Owned here rather than by a window for the same reason capture and the inbox are: `File ▸
    /// Export` is a menu command, and a menu command is available with every window closed.
    @ObservationIgnored public let exportService: ExportService

    @ObservationIgnored private var hasBootstrapped = false

    public init(
        store: any LggrStore,
        storage: StorageSummary,
        clock: any DateProviding,
        preferences: AppPreferences,
        appModel: AppModel,
        capture: ActivityCapture? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.storage = storage
        self.clock = clock
        self.preferences = preferences
        self.appModel = appModel
        let sessionManager = SessionManager(store: store, clock: clock)
        self.sessionManager = sessionManager
        // Defaulted rather than required so a test or the gallery can build an environment without
        // one. Constructing it records nothing; only `bootstrap()` does.
        let capture = capture ?? ActivityCapture(clock: clock, defaults: defaults)
        self.capture = capture
        self.inbox = InboxModel(store: store, clock: clock)

        // Reads the same day files the sampler writes and the same privacy lists Settings edits, so
        // the daily summary can name an application exactly as far as the user has allowed and no
        // further. `TimelineModel.shared` is read through a closure rather than captured as a value:
        // the reconstructed day moves with every flush, and an export must use the one that exists at
        // the moment it is asked for.
        self.exportService = ExportService(
            store: store,
            activityLog: capture.log,
            clock: clock,
            projects: { [weak sessionManager] in sessionManager?.projects ?? [] },
            timeline: { TimelineModel.shared.timeline },
            redactor: { [weak capture] in
                guard let capture else { return .permissive }
                let lists = capture.privacy.lists
                return PrivacyRedactor(
                    excludedApplications: Array(lists.excluded),
                    privateApplications: Array(lists.privateActivity)
                )
            }
        )
        self.exportService.showMainWindow = { [weak appModel] in appModel?.showMainWindow() }

        // The back-reference, set after both objects exist. `startSession` goes through this object's
        // own `start(_:)` so an interruption becomes a session by exactly the path the start panel
        // uses — one place decides what starting a session means.
        self.inbox.session = InboxSessionContext.live(
            manager: sessionManager,
            startSession: { [weak self] request in self?.start(request) }
        )
    }

    // MARK: - Factories

    /// The real application: the best store `StoreBootstrap` can open, and the system clock.
    ///
    /// `preferences.applyToStoredPreferences()` runs **before** `SessionManager` is constructed, and
    /// the ordering is load-bearing — see `AppPreferences` for why.
    public static func live(defaults: UserDefaults = .standard) -> AppEnvironment {
        let preferences = AppPreferences(defaults: defaults)
        preferences.applyToStoredPreferences()

        let opened = StoreBootstrap.makeStore()
        return AppEnvironment(
            store: opened.store,
            storage: StorageSummary(
                backendName: opened.backend.displayName,
                degradedReason: opened.degradedReason,
                folderURL: (try? JSONFileStore.defaultFileURL())?.deletingLastPathComponent()
            ),
            clock: SystemClock(),
            preferences: preferences,
            appModel: AppModel(defaults: defaults),
            defaults: defaults
        )
    }

    /// The one instance the process has.
    ///
    /// A singleton rather than the `@State` of the `App` struct for one concrete reason: AppKit
    /// instantiates `AppDelegate` itself and there is no seam to hand it a dependency through, yet
    /// the delegate is where launch, reopen and terminate are answered. Every other consumer reads
    /// this through the SwiftUI environment.
    public static let shared = AppEnvironment.live()

    // MARK: - Lifecycle

    /// Loads projects, today, any session that was running when Lggr last stopped — and starts
    /// ambient capture.
    ///
    /// Idempotent, because it is called from `applicationDidFinishLaunching` *and* from the main
    /// window's `.task` — the window may never open (the user quit with it closed last time), and
    /// launch may finish before any scene appears. Whichever runs first wins and the other returns.
    ///
    /// Capture is started here rather than from a scene for the reason that defines Phase 1: the
    /// record runs from launch, whether or not a window is ever opened. A sampler started by a view
    /// would miss the entire morning of a user who works with the window closed — which is the exact
    /// morning the app exists to be able to show them.
    public func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await sessionManager.bootstrap()
        // Read early, because `load()` replaces the list wholesale: a capture that landed before the
        // first read came back would disappear from the screen — though never from the disk — until
        // something else reloaded it. `⌘⇧I` is live from the moment the menu bar exists.
        await inbox.load()
        await capture.start()
    }

    // MARK: - Starting a session

    /// The start panel's context, with the user's chosen default duration folded in.
    ///
    /// `StartSessionContext.live` reads `SessionManager.preferences`, which is loaded once at launch;
    /// `AppPreferences` is the value the user can change while the app is running, so it wins here.
    public func startSessionContext() -> StartSessionContext {
        var context = StartSessionContext.live(sessionManager)
        context.defaultDuration = preferences.defaultSessionDuration
        return context
    }

    /// Starts a session from a panel's request. Fire-and-forget on purpose: the interface has
    /// already moved on, and `SessionManager` reports any failure through `lastError`.
    public func start(_ request: StartSessionRequest) {
        Task {
            await self.sessionManager.startSession(
                projectID: request.projectID,
                intendedOutcome: request.intendedOutcome,
                workType: request.workType,
                plannedDuration: request.plannedDuration
            )
        }
    }

    /// Reveals the data folder in the Finder.
    ///
    /// AppKit, because SwiftUI has no way to reveal a file — `NSWorkspace` is the only API that
    /// does. Silent when the folder is unknown, which is the in-memory backend's case.
    public func revealDataFolder() {
        guard let url = storage.folderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Reveals the folder of day files the privacy pane names.
    ///
    /// A different folder from `revealDataFolder()`'s and deliberately so: sessions and
    /// accomplishments are one JSON file, activity is one plain-text file per day, and the whole point
    /// of the second arrangement is that the user can open the folder and count the days themselves.
    /// Silent when nothing durable is wired, which is the in-memory log's case.
    public func revealActivityFolder() {
        guard let url = capture.directoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Storage

/// What Settings says about where the work is kept. A plain value so the pane renders without a
/// store.
public struct StorageSummary: Hashable, Sendable {
    public let backendName: String
    /// Set when the preferred backend could not be opened. The user is told rather than left to
    /// discover it.
    public let degradedReason: String?
    public let folderURL: URL?

    public init(backendName: String, degradedReason: String? = nil, folderURL: URL? = nil) {
        self.backendName = backendName
        self.degradedReason = degradedReason
        self.folderURL = folderURL
    }
}

// MARK: - Preferences

/// The two preferences Phase 2 can actually honour, and the only object that writes them.
///
/// ### Why this exists rather than a setter on `SessionManager`
///
/// `SessionManager.preferences` is `private(set)`: it loads `UserPreferences` once at launch and
/// rewrites the whole value whenever it remembers a project or an outcome. If Settings wrote the
/// same blob directly, the next `startSession` would write the manager's launch-time copy back over
/// it and the user's choice would silently revert.
///
/// So each setting lives under its **own** `UserDefaults` key, which nothing else ever writes, and is
/// mirrored into the shared `UserPreferences` blob. The mirror is re-applied at launch *before*
/// `SessionManager` is constructed, so the manager reads the user's values rather than stale ones.
/// A change made while the app is running therefore survives a clobber and survives a relaunch; the
/// only thing it does not do is reach back into the manager's in-memory copy, which is why the menu
/// bar toggle carries a one-line note in the pane.
@MainActor
@Observable
public final class AppPreferences {

    /// Keys owned by this object alone.
    private static let durationKey = "com.lggr.settings.defaultSessionDuration"
    private static let menuBarTimerKey = "com.lggr.settings.showTimerInMenuBar"

    /// The `UserPreferences` blob `SessionManager` loads at launch. Duplicated here — and *only*
    /// here — because the constant is private to that file and there is no shared owner for it.
    /// If it ever changes, this is the one other place that has to change with it.
    private static let storedPreferencesKey = "com.lggr.preferences"

    /// Pre-selected duration in the start panel. Clamped to something a working day can contain.
    public var defaultSessionDuration: TimeInterval {
        get {
            access(keyPath: \.defaultSessionDuration)
            return durationStorage
        }
        set {
            let clamped = Self.clampDuration(newValue)
            guard clamped != durationStorage else { return }
            withMutation(keyPath: \.defaultSessionDuration) { durationStorage = clamped }
            defaults.set(clamped, forKey: Self.durationKey)
            applyToStoredPreferences()
        }
    }

    /// Whether the menu bar label shows counting digits alongside its symbol.
    public var showTimerInMenuBar: Bool {
        get {
            access(keyPath: \.showTimerInMenuBar)
            return timerStorage
        }
        set {
            guard newValue != timerStorage else { return }
            withMutation(keyPath: \.showTimerInMenuBar) { timerStorage = newValue }
            defaults.set(newValue, forKey: Self.menuBarTimerKey)
            applyToStoredPreferences()
        }
    }

    /// Written through `access`/`withMutation` above: the `@Observable` macro synthesises accessors
    /// for a stored property, and a property cannot have both those and a custom body.
    @ObservationIgnored private var durationStorage: TimeInterval
    @ObservationIgnored private var timerStorage: Bool
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // First run — or an install that predates these keys — inherits whatever the shared blob
        // already says, so nothing resets the moment this object is introduced.
        let stored = Self.loadStoredPreferences(from: defaults)
        let storedDuration = defaults.object(forKey: Self.durationKey) as? Double
        let storedTimer = defaults.object(forKey: Self.menuBarTimerKey) as? Bool

        self.durationStorage = Self.clampDuration(storedDuration ?? stored.defaultSessionDuration)
        self.timerStorage = storedTimer ?? stored.showTimerInMenuBar
    }

    // MARK: Mirroring

    /// Copies both values into the shared `UserPreferences` blob, preserving everything else in it.
    ///
    /// Load-modify-save rather than encode-from-scratch: the blob also carries the remembered
    /// project and the recent outcomes, and Settings has no business forgetting either.
    public func applyToStoredPreferences() {
        var stored = Self.loadStoredPreferences(from: defaults)
        guard
            stored.defaultSessionDuration != durationStorage
                || stored.showTimerInMenuBar != timerStorage
        else { return }

        stored.defaultSessionDuration = durationStorage
        stored.showTimerInMenuBar = timerStorage
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: Self.storedPreferencesKey)
    }

    private static func loadStoredPreferences(from defaults: UserDefaults) -> UserPreferences {
        guard
            let data = defaults.data(forKey: storedPreferencesKey),
            let decoded = try? JSONDecoder().decode(UserPreferences.self, from: data)
        else { return .default }
        return decoded
    }

    /// Clamped to `DurationSelection.customRange` — the same bounds the start panel enforces, so
    /// Settings can never store a default the panel would refuse to show.
    private static func clampDuration(_ duration: TimeInterval) -> TimeInterval {
        let range = DurationSelection.customRange
        guard duration.isFinite else { return TimeInterval(range.lowerBound) * 60 }
        let minutes = Int((duration / 60).rounded())
        return TimeInterval(min(max(minutes, range.lowerBound), range.upperBound)) * 60
    }
}
