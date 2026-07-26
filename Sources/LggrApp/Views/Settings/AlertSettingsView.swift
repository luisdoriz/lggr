import AppKit
import LggrKit
import SwiftUI

// Settings ▸ Alerts. See docs/_design/04-screens.md § 4.7 and SPEC.md § Notifications.
//
// This pane was absent, and `SettingsView`'s own comment said why: it "would configure notifications
// that are not posted". They are posted now — `SessionManager` arms the completion and the halfway
// banner when a session starts and offers the trim when input stops — so the pane exists, and every
// row on it moves something.
//
// Three design rules, each of which is a consequence of the same mechanical fact: **macOS grants one
// notification authorisation for the whole app, and a user who is annoyed by one notification
// switches all of them off in System Settings, where Lggr cannot ask again.**
//
// 1. **Each row says what causes it.** Not "Session completed ☐" but a sentence naming the event.
//    Every notification Lggr sends is caused by something that happened, and a user deciding whether
//    to grant the one authorisation this app will ever ask for is entitled to know that before they
//    grant it — not after the first banner.
// 2. **There is no [Allow notifications] button.** § 4.7 draws one; it is not here, and the omission
//    is the point. A permission granted with every switch still off authorises nothing to happen, so
//    the button would spend the one ask on a state in which no notification could arrive. The switch
//    *is* the ask: turning one on is the explicit user action that authorises the prompt, and it is
//    the only thing in Lggr that requests a permission.
// 3. **A denial is stated once, with the only control that could help beside it, and never repeated.**
//    No banner in the review sheet, no line in the weekly review, no second prompt. `SPEC.md` §
//    Permissions — never repeatedly nag — and the whole app keeps working either way.
//
// Every kind § 4.7 names now has a row, including the two that concern work the user did not declare
// — the live offer to label a long stretch, and the end-of-day review. Both arrive with
// `ProactivePrompts`, which is what makes a row for them a control that moves something rather than
// the dead setting this project has shipped twice.
//
// Those two carry a second control each, and it is not decoration:
//
//   * **The prompt window.** These are the only notifications Lggr sends that are not about something
//     the user started, so they are the only ones that can arrive at a moment the user has no reason
//     to expect anything. Lggr cannot know a person's day, so the hours are theirs, and the pane says
//     plainly that nothing arrives outside them.
//   * **The review's time.** Which is *not* the hour the notification arrives, and the pane says so:
//     it is the hour Lggr is allowed to look at the day. A day with nothing unlabelled sends nothing.
//     Writing that on the screen is the only way the user can tell this apart from the daily-reminder
//     mechanism every other tracker ships, and it is the difference the whole design turns on.

/// The Alerts tab: one row per notification Lggr can actually send, and one honest line about macOS.
@MainActor
public struct AlertSettingsView: View {

    /// The switches and the authorisation, live.
    ///
    /// Not `@Bindable`: every toggle here goes through `setEnabled(_:for:)`, which is what requests
    /// the authorisation and withdraws anything pending. A two-way binding straight onto the stored
    /// value would write the switch and skip both.
    private let gate: NotificationGate

    /// When Lggr may offer to label something. `nil` in a host with no preferences behind it, in which
    /// case the two timing controls are absent rather than inert.
    @Bindable private var preferences: AppPreferences

    /// The scheduler, so a switch moved here starts or stops the one-minute evaluation immediately.
    ///
    /// Optional for the same reason `SettingsView.notifications` is: the gallery and the snapshot
    /// renderer draw this pane with no composition root. In those hosts nothing schedules anything at
    /// all, so a switch that reaches no scheduler is consistent with the rest of the host rather than
    /// a dead control in a live app.
    private let prompts: ProactivePrompts?

    /// Opens System Settings ▸ Notifications. Injected so the pane renders in the gallery and the
    /// snapshot renderer with nothing behind it, exactly as the reveal buttons on the other panes are.
    private let onOpenSystemSettings: (() -> Void)?

    public init(
        gate: NotificationGate,
        preferences: AppPreferences,
        prompts: ProactivePrompts? = nil,
        onOpenSystemSettings: (() -> Void)? = nil
    ) {
        self.gate = gate
        self.preferences = preferences
        self.prompts = prompts
        self.onOpenSystemSettings = onOpenSystemSettings
    }

    public var body: some View {
        SettingsForm {
            Section("Notifications") {
                ForEach(NotificationSwitches.switchableKinds, id: \.self) { kind in
                    row(for: kind)
                }
            }

            Section {
                systemStatus
            }
        }
        .frame(width: Layout.reviewSheetWidth)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }

    // MARK: - One notification

    private func row(for kind: NotificationKind) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Toggle(kind.displayName, isOn: binding(for: kind))

            Text(kind.causeDescription)
                .font(Type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The one case where a switch that is on does nothing, said next to the switch rather
            // than in a footer somebody has to connect to it themselves.
            if gate.switches.isEnabled(kind), !gate.authorization.isAllowed {
                Text(deniedNote)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Shown only while the kind is on: timing controls under a switched-off notification are
            // configuration for something that cannot happen.
            if gate.switches.isEnabled(kind) { timing(for: kind) }
        }
    }

    /// Writes through the gate, so turning a switch on is what asks macOS and turning it off is what
    /// withdraws anything already armed — and then tells the scheduler, so a kind switched off stops
    /// costing the user a wake-up a minute straight away rather than at the next launch.
    private func binding(for kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { gate.switches.isEnabled(kind) },
            set: { enabled in
                Task {
                    await gate.setEnabled(enabled, for: kind)
                    prompts?.refreshForSwitchChange()
                }
            }
        )
    }

    // MARK: - When

    /// The extra control the two undeclared-work prompts carry, and nothing for the other three.
    @ViewBuilder private func timing(for kind: NotificationKind) -> some View {
        switch kind {
        case .unlabelledBlock:
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    hourPicker(
                        "Between",
                        selection: Binding(
                            get: { preferences.promptSchedule.hours.startHour },
                            set: { setHours(startHour: $0) }
                        )
                    )
                    hourPicker(
                        "and",
                        selection: Binding(
                            get: { preferences.promptSchedule.hours.endHour },
                            set: { setHours(endHour: $0) }
                        )
                    )
                }

                Text(hoursNote)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.xs)

        case .endOfDayReview:
            VStack(alignment: .leading, spacing: Space.xxs) {
                hourPicker(
                    "Look at the day at",
                    selection: Binding(
                        get: { preferences.promptSchedule.endOfDayHour },
                        set: { hour in
                            var schedule = preferences.promptSchedule
                            schedule.endOfDayHour = hour
                            preferences.promptSchedule = schedule
                        }
                    )
                )

                // The sentence that distinguishes this from every daily reminder on the market. It is
                // on the screen where the time is chosen, because that is the only place the user can
                // form the wrong expectation.
                Text(
                    "This is when Lggr looks, not when it sends. Nothing arrives unless the day "
                        + "holds blocks with nothing declared for them."
                )
                .font(Type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.xs)

        case .sessionCompleted, .halfway, .longIdle:
            EmptyView()
        }
    }

    private func hourPicker(_ label: String, selection: Binding<Int>) -> some View {
        Picker(label, selection: selection) {
            ForEach(0..<24, id: \.self) { hour in
                Text(verbatim: String(format: "%02d:00", hour)).tag(hour)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
    }

    /// Facts about when nothing will arrive. Never a promise about how often something will.
    private var hoursNote: String {
        let hours = preferences.promptSchedule.hours
        if hours.isAllDay {
            return "Offered at any time of day, and at most once for each stretch of work."
        }
        return "Nothing is offered outside \(hours.rangeText), and at most once for each stretch "
            + "of work."
    }

    private func setHours(startHour: Int? = nil, endHour: Int? = nil) {
        var schedule = preferences.promptSchedule
        schedule.hours = PromptHours(
            startHour: startHour ?? schedule.hours.startHour,
            endHour: endHour ?? schedule.hours.endHour
        )
        preferences.promptSchedule = schedule
    }

    private var deniedNote: String {
        switch gate.authorization {
        case .denied:
            "Switched on here, and switched off for Lggr in System Settings, so nothing will arrive."
        case .unavailable:
            "This build of Lggr cannot post notifications."
        case .notRequested, .allowed:
            // Reachable for one frame while the request is in flight. A sentence rather than a
            // spinner: the switch is already where the user put it and nothing is waiting on this.
            "macOS has not answered yet."
        }
    }

    // MARK: - What macOS says

    private var systemStatus: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(statusSentence)
                .font(Type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if gate.authorization == .denied, let onOpenSystemSettings {
                Button("Open System Settings", action: onOpenSystemSettings)
                    .buttonStyle(.borderless)
                    .font(Type.secondary)
            }
        }
    }

    /// Facts about the state of the machine, never about the person. Nothing here asks for anything.
    private var statusSentence: String {
        switch gate.authorization {
        case .notRequested:
            "macOS will ask the first time you switch one of these on. Lggr requests nothing until "
                + "then, and everything else works whichever way you answer."
        case .allowed:
            "macOS is delivering notifications from Lggr. Lggr sends only the ones switched on above, "
                + "and each is sent because something happened — never on a schedule."
        case .denied:
            "Notifications from Lggr are switched off in System Settings. Lggr will not ask again."
        case .unavailable:
            "There is no notification centre available to this build, so nothing will be delivered."
        }
    }

    // MARK: - System Settings

    /// Opens the Notifications pane.
    ///
    /// AppKit, because SwiftUI cannot open a System Settings pane, and silent when the URL will not
    /// resolve: failing to open a settings pane is not worth an alert, and the sentence above it has
    /// already said what the user needs to know.
    static func openSystemNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications"
            )
        else { return }
        NSWorkspace.shared.open(url)
    }
}
