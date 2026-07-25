import LggrKit
import SwiftUI

// Settings. See docs/_design/04-screens.md § 4.7.
//
// § 4.7 draws five tabs. **This ships two**, because every control on them changes something the user
// can observe, and a pane full of switches wired to nothing is worse than a short pane: it teaches
// the user that this screen does not do anything.
//
//   • **General** — the default session duration, the menu bar timer, and where the work is kept.
//   • **Privacy** — the tracking switch, the two application lists, the retention period, delete
//     history, and the plain statement of what is on disk. All of it `PrivacySettingsView`, which is
//     the whole of what makes an app that records without being asked acceptable.
//
// Three tabs § 4.7 draws are absent, and each is absent for the same reason: **Shortcuts** would
// configure a global hot key that is not registered, **Notifications** would configure notifications
// that are not posted, and **Tracking** would duplicate controls Privacy already owns. None of them
// is a preference Lggr can honour today.
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
        case privacy
    }

    @Bindable private var preferences: AppPreferences
    private let storage: StorageSummary
    /// What the running `SessionManager` loaded at launch. Used only to decide whether the menu bar
    /// toggle needs to say when it takes effect.
    private let liveShowsTimerInMenuBar: Bool
    private let privacy: PrivacyModel
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
        onRevealDataFolder: (() -> Void)? = nil,
        onRevealActivityFolder: (() -> Void)? = nil,
        host: Host = .window
    ) {
        self.preferences = preferences
        self.storage = storage
        self.liveShowsTimerInMenuBar = liveShowsTimerInMenuBar
        self.privacy = privacy
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

    /// Two tabs in both hosts, so `⌘,` and `⌘7` are the same screen rather than two arrangements of
    /// it. Both panes are rendered with `host: .window` — the tab already names the room, and a
    /// section title repeating the tab label above it is the sort of thing that makes a settings
    /// screen feel generated.
    private var tabs: some View {
        TabView(selection: $tab) {
            general
                .tabItem { Label("General", systemImage: SidebarSection.settings.symbolName) }
                .tag(Tab.general)

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
