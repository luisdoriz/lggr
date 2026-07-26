import LggrKit
import SwiftUI

// Settings. See docs/_design/04-screens.md § 4.7.
//
// § 4.7 draws five tabs. **This ships four**, because every control on them changes something the
// user can observe, and a pane full of switches wired to nothing is worse than a short pane: it
// teaches the user that this screen does not do anything.
//
//   • **General** — the default session duration, the menu bar timer, and where the work is kept.
//   • **Alerts** — the notifications Lggr can send, each individually switchable, and one honest line
//     about what macOS has said. `AlertSettingsView`.
//   • **Shortcuts** — the five global hot keys, each with a recorder, a reset and a way to switch it
//     off, and each registered the moment it is recorded. `ShortcutSettingsView`.
//   • **Privacy** — the tracking switch, the two application lists, the retention period, delete
//     history, and the plain statement of what is on disk. All of it `PrivacySettingsView`, which is
//     the whole of what makes an app that records without being asked acceptable.
//
// **Shortcuts used to be absent from this list, for the reason this comment used to give: it would
// have configured a global hot key that nothing registered.** `GlobalShortcutService` registers them
// now, `QuickActions` gives every one of them something to do, and the pane reports the registrations
// macOS refused — so the tab is here, and the condition it was waiting on is the condition it met.
//
// **Alerts arrived the same way, and only now.** It was absent because it "would configure
// notifications that are not posted"; `SessionManager` posts them, `NotificationGate` gates each kind
// individually, and the pane shows a row only for the kinds something actually schedules. The
// end-of-day review is a kind with no scheduler, so it has no row — the same test the other tabs had
// to pass.
//
// One tab § 4.7 draws is still absent, for the reason the other two were: **Tracking** would
// duplicate controls Privacy already owns.
//
// `UserPreferences.trackWindowTitles` is deliberately not surfaced anywhere. It governs a capability
// that does not exist: `ActivityInterval` has no field for a window title, Lggr never reads one, and
// `PrivacyModel.RecordFact.neverKept` says so on the Privacy tab as a fact about the record. A toggle
// over it would be a control the user could move that changed nothing — the exact thing this file
// exists to keep out — and phrasing it honestly ("this does nothing yet") would be an admission with
// no purpose beside a statement that is already true and already on screen.
//
// § 4.7's other rule is honoured exactly: this is the one screen in Lggr with no primary button. Its
// primary action *is* the control the user came here to change, and a `Done` button on an always-live
// pane is theatre.

/// § 4.7 gives no width for the pane. This matches the review sheet — the widest panel in the app —
/// so the settings window never reads as an afterthought beside it.
private let settingsPaneWidth: CGFloat = Layout.reviewSheetWidth

/// Enough that switching to the longer tab does not resize the window on every visit. The Privacy
/// tab's own `Form` scrolls past it.
private let settingsPaneMinHeight: CGFloat = 460

/// § 4.7's `( 25m ) (•50m) ( Custom  50 ▲▼ )`.
///
/// The presets and the custom bounds come from `DurationSelection`, which is what the start panel
/// itself offers — so Settings can never present a duration the panel would then round or refuse.
private enum DurationOption: Hashable {
    case preset(Int)
    case custom
}

/// One view, two hosts (`04-screens.md` § 1.2): the `Settings` scene opened by `⌘,`, and the
/// sidebar's own Settings row. The only difference is the screen title, which the window's title bar
/// already supplies.
@MainActor
public struct SettingsView: View {

    /// Where the pane is being rendered.
    public enum Host: Hashable, Sendable {
        /// The `Settings` scene. The window title says "Settings"; the pane must not repeat it.
        case window
        /// The detail column behind `⌘7`, where every other screen draws its own title.
        case detail
    }

    /// Which tab is showing. Not persisted: a settings window reopens on the thing the user came for,
    /// which is almost never the thing they left last week.
    private enum Tab: Hashable {
        case general
        case alerts
        case shortcuts
        case privacy
    }

    @Bindable private var preferences: AppPreferences
    private let storage: StorageSummary
    /// What the running `SessionManager` loaded at launch. Used only to decide whether the menu bar
    /// toggle needs to say when it takes effect.
    private let liveShowsTimerInMenuBar: Bool
    private let privacy: PrivacyModel
    /// The notification switches and the live authorisation.
    ///
    /// Optional for the same reason `shortcutService` is: the gallery and the snapshot renderer draw
    /// this pane with no composition root, and a tab that would configure nothing is not shown at all
    /// rather than shown inert.
    private let notifications: NotificationGate?
    /// The scheduler behind the two undeclared-work prompts, so switching one on or off here starts or
    /// stops it at once. Optional for the same reason `notifications` is.
    private let prompts: ProactivePrompts?
    /// The live hot-key registrations, so the Shortcuts tab can name the ones macOS refused.
    ///
    /// Optional for the same reason the reveal closures are: the gallery and the snapshot renderer draw
    /// this pane with no composition root behind it.
    private let shortcutService: GlobalShortcutService?
    private let onRevealDataFolder: (() -> Void)?
    private let onRevealActivityFolder: (() -> Void)?
    private let host: Host

    @State private var tab: Tab = .general
    @State private var usesCustomDuration: Bool
    @State private var customMinutes: Int

    /// Everything injected, so the pane renders in the gallery with no store and no environment.
    public init(
        preferences: AppPreferences,
        storage: StorageSummary,
        liveShowsTimerInMenuBar: Bool,
        privacy: PrivacyModel,
        notifications: NotificationGate? = nil,
        prompts: ProactivePrompts? = nil,
        shortcutService: GlobalShortcutService? = nil,
        onRevealDataFolder: (() -> Void)? = nil,
        onRevealActivityFolder: (() -> Void)? = nil,
        host: Host = .window
    ) {
        self.preferences = preferences
        self.storage = storage
        self.liveShowsTimerInMenuBar = liveShowsTimerInMenuBar
        self.privacy = privacy
        self.notifications = notifications
        self.prompts = prompts
        self.shortcutService = shortcutService
        self.onRevealDataFolder = onRevealDataFolder
        self.onRevealActivityFolder = onRevealActivityFolder
        self.host = host

        let minutes = Int((preferences.defaultSessionDuration / 60).rounded())
        let isPreset = DurationSelection.presetMinutes.contains(minutes)
        _usesCustomDuration = State(initialValue: !isPreset)
        _customMinutes = State(
            initialValue: isPreset ? DurationSelection.defaultCustomMinutes : minutes
        )
    }

    /// The live pane.
    public init(environment: AppEnvironment, host: Host = .window) {
        self.init(
            preferences: environment.preferences,
            storage: environment.storage,
            liveShowsTimerInMenuBar: environment.sessionManager.preferences.showTimerInMenuBar,
            privacy: environment.capture.privacy,
            notifications: environment.notifications,
            prompts: environment.prompts,
            shortcutService: environment.shortcutService,
            onRevealDataFolder: { environment.revealDataFolder() },
            onRevealActivityFolder: { environment.revealActivityFolder() },
            host: host
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if host == .detail {
                Text("Settings")
                    .font(Type.screenTitle)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.xl)
            }

            tabs
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings")
    }

    /// Three tabs in both hosts, so `⌘,` and `⌘7` are the same screen rather than two arrangements of
    /// it. Every pane is rendered with `host: .window` — the tab already names the room, and a
    /// section title repeating the tab label above it is the sort of thing that makes a settings
    /// screen feel generated.
    private var tabs: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: SidebarSection.settings.symbolName) }
                .tag(Tab.general)

            // Shown only when there is a gate behind it. A tab of switches that configure nothing is
            // the failure this file exists to prevent, and the gallery is exactly the host that would
            // have one.
            if let notifications {
                AlertSettingsView(
                    gate: notifications,
                    preferences: preferences,
                    prompts: prompts,
                    onOpenSystemSettings: { AlertSettingsView.openSystemNotificationSettings() }
                )
                .tabItem { Label("Alerts", systemImage: Icon.notifications) }
                .tag(Tab.alerts)
            }

            ShortcutSettingsView(preferences: preferences, service: shortcutService)
                .tabItem { Label("Shortcuts", systemImage: Icon.shortcuts) }
                .tag(Tab.shortcuts)

            PrivacySettingsView(
                model: privacy,
                host: .window,
                onRevealActivityFolder: onRevealActivityFolder
            )
            .tabItem { Label("Privacy", systemImage: Icon.privacy) }
            .tag(Tab.privacy)
        }
        .frame(minHeight: settingsPaneMinHeight)
    }

    private var general: some View {
        Form {
            sessionsSection
            menuBarSection
            storageSection
        }
        .formStyle(.grouped)
        .frame(width: settingsPaneWidth)
        .background(Surface.canvas)
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        Section("Sessions") {
            Picker("Default duration", selection: durationOption) {
                ForEach(DurationSelection.presetMinutes, id: \.self) { minutes in
                    Text(verbatim: "\(minutes)m").tag(DurationOption.preset(minutes))
                }
                Text("Custom").tag(DurationOption.custom)
            }
            .pickerStyle(.segmented)

            if usesCustomDuration {
                Stepper(
                    value: customMinutesBinding,
                    in: DurationSelection.customRange,
                    step: 5
                ) {
                    Text(verbatim: customMinutes == 1 ? "1 minute" : "\(customMinutes) minutes")
                        .font(Type.body)
                        .monospacedDigit()
                }
            }

            Text("The start panel opens with this. You can still change it there.")
                .font(Type.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Reads the option out of the stored duration rather than out of a second copy of the truth, so
    /// the segments can never disagree with the value they describe.
    private var durationOption: Binding<DurationOption> {
        Binding(
            get: {
                guard !usesCustomDuration else { return .custom }
                return .preset(Int((preferences.defaultSessionDuration / 60).rounded()))
            },
            set: { option in
                switch option {
                case .preset(let minutes):
                    usesCustomDuration = false
                    preferences.defaultSessionDuration = TimeInterval(minutes) * 60
                case .custom:
                    usesCustomDuration = true
                    preferences.defaultSessionDuration = TimeInterval(customMinutes) * 60
                }
            }
        )
    }

    private var customMinutesBinding: Binding<Int> {
        Binding(
            get: { customMinutes },
            set: { minutes in
                customMinutes = minutes
                preferences.defaultSessionDuration = TimeInterval(minutes) * 60
            }
        )
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        Section("Menu bar") {
            Toggle("Show the timer in the menu bar", isOn: $preferences.showTimerInMenuBar)

            if preferences.showTimerInMenuBar != liveShowsTimerInMenuBar {
                // Shown only while the running label and the saved setting disagree, so the pane is
                // silent in the ordinary case and honest in the one case that matters.
                Text("Applies the next time Lggr opens.")
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Kept in") {
                Text(storage.backendName)
                    .font(Type.body)
                    .foregroundStyle(.secondary)
            }

            if let folder = storage.folderURL {
                LabeledContent("Location") {
                    HStack(spacing: Space.s) {
                        Text(folder.path(percentEncoded: false))
                            .font(Type.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)

                        if let onRevealDataFolder {
                            Button("Show in Finder", action: onRevealDataFolder)
                                .buttonStyle(.borderless)
                                .font(Type.secondary)
                        }
                    }
                }
            }

            if let reason = storage.degradedReason {
                // Stated plainly and once. Losing the ability to record work would be worse than
                // recording it somewhere unexpected, but the user still has to be told which.
                Text(reason)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
