import AppKit
import LggrKit
import SwiftUI

// Settings → Privacy. See docs/_design/04-screens.md § 4.7 and INTELLIGENCE.md § 4.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT THIS SCREEN IS FOR
//
//  Lggr keeps a record of which application is in front of you all day, whether or not you asked it
//  to start. Nobody agreed to that when they downloaded a focus timer. This pane is the whole of
//  what makes it acceptable, and it has five jobs and no others:
//
//    1. Turn it off, in one click, with the current state said out loud.
//    2. Leave an application alone entirely.
//    3. Keep an application's time without keeping its identity — and drop the identity **before
//       the file is written**, not when the timeline is drawn, so a later bug cannot reveal
//       something that was already discarded.
//    4. Decide how long any of it is kept, and delete it — a single day, or all of it.
//    5. Say exactly what is on disk, in words, with the real path. A privacy promise the user
//       cannot inspect is marketing.
//
//  COPY RULES, enforced by review and by taste rather than by a linter:
//    • Facts about the record, never about the person. No sentence here has the user's character as
//      its subject.
//    • No euphemism. The app does keep a continuous record and this screen says so.
//    • No alarm either. Nothing on this pane is red, nothing is a warning triangle, and the word
//      "protect" does not appear — the user is not under attack, they are making a decision.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Matches `SettingsView`'s pane width so the two do not read as different windows.
private let privacyPaneWidth: CGFloat = Layout.reviewSheetWidth

/// The privacy pane.
///
/// Everything is injected through `PrivacyModel`, so the pane renders in the light/dark gallery with
/// no store, no sampler and no files on disk.
@MainActor
public struct PrivacySettingsView: View {

    // A plain reference, not `@Bindable`: nothing here binds two-way to the model, and every read
    // below happens inside a view body, which is all Observation needs to invalidate the pane.
    private let model: PrivacyModel
    private let host: SettingsView.Host
    private let onRevealActivityFolder: (() -> Void)?

    /// Which list the picker is adding to, and therefore whether it is open.
    @State private var adding: ApplicationRule?
    /// The destructive action waiting on a confirmation.
    @State private var pending: PendingAction?
    /// The day the delete-one-day control is pointed at.
    @State private var selectedDay: ActivityDayKey?

    public init(
        model: PrivacyModel,
        host: SettingsView.Host = .window,
        onRevealActivityFolder: (() -> Void)? = nil
    ) {
        self.model = model
        self.host = host
        self.onRevealActivityFolder = onRevealActivityFolder
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if host == .detail {
                Text("Privacy")
                    .font(Type.screenTitle)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Space.xl)
                    .padding(.top, Space.xl)
            }

            SettingsForm {
                trackingSection
                privateSection
                excludedSection
                historySection
                recordSection
                noticeSection
            }
            .frame(width: host == .window ? privacyPaneWidth : nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .task { await model.refreshRecordedDays() }
        .sheet(item: $adding) { rule in
            ApplicationPicker(model: model, rule: rule) { adding = nil }
        }
        .confirmationDialog(
            pending?.question ?? "",
            isPresented: pendingBinding,
            titleVisibility: .visible,
            presenting: pending
        ) { action in
            Button(action.confirmTitle, role: .destructive) { perform(action) }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.detail)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Privacy settings")
    }

    // MARK: - Tracking

    /// The switch, and the state it is currently in, at the top of the pane where a person looking
    /// for "make it stop" will look first.
    private var trackingSection: some View {
        Section("Tracking") {
            // Read here, in a view body, so the row follows the sampler rather than freezing on
            // whatever the state was when Settings opened.
            let state = model.trackingState

            LabeledContent("Right now") {
                HStack(spacing: Space.s) {
                    TrackingStateGlyph(state: state, size: .row)
                        .accessibilityHidden(true)
                    Text(state.displayName)
                        .font(Type.body)
                        .foregroundStyle(.secondary)
                }
            }

            Button(state.switchTitle) { model.toggleTracking() }
                .buttonStyle(.borderless)

            Text(
                state.isPausedByUser
                    ? "Nothing is being recorded. Your timeline shows this stretch as paused, so the "
                        + "hours are still accounted for."
                    : "Lggr is keeping a record of which application is in front of you and for how "
                        + "long. Pausing stops that at once."
            )
            .font(Type.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Private applications

    private var privateSection: some View {
        Section {
            if model.privateApplications.isEmpty {
                Text("No applications are marked private.")
                    .font(Type.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.privateApplications) { application in
                    ApplicationRow(
                        application: application,
                        rule: .privateActivity,
                        isShipped: model.isShippedDefault(application),
                        onMove: { model.setRule(.excluded, for: application) },
                        onRemove: { model.remove(application) }
                    )
                }
            }

            HStack(spacing: Space.m) {
                Button("Add an application…") { adding = .privateActivity }
                    .buttonStyle(.borderless)

                if model.hasRemovedShippedDefaults {
                    Button("Put back the ones Lggr ships with") {
                        model.restoreShippedPrivateApplications()
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Private applications")
        } footer: {
            Text(
                "Lggr keeps the time so your day still adds up, and replaces the name and the "
                    + "identifier with the single word “Private” before the file is written. Every "
                    + "private application gets the same word, so no two of them can be told apart "
                    + "later, by Lggr or by anyone reading the file.\n\n"
                    + "Lggr arrives with this list already filled in. Every row is yours to remove, "
                    + "and one you remove stays removed."
            )
            .font(Type.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Excluded applications

    private var excludedSection: some View {
        Section {
            if model.excludedApplications.isEmpty {
                Text("No applications are excluded.")
                    .font(Type.body)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.excludedApplications) { application in
                    ApplicationRow(
                        application: application,
                        rule: .excluded,
                        isShipped: model.isShippedDefault(application),
                        onMove: { model.setRule(.privateActivity, for: application) },
                        onRemove: { model.remove(application) }
                    )
                }
            }

            Button("Add an application…") { adding = .excluded }
                .buttonStyle(.borderless)
        } header: {
            Text("Applications Lggr leaves alone")
        } footer: {
            Text(
                "Nothing at all is recorded for these — no name, no identifier, no minutes. The "
                    + "time shows on your timeline as an absence with nothing attached to it, "
                    + "rather than going missing."
            )
            .font(Type.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Picker("Keep activity for", selection: retentionBinding) {
                ForEach(RetentionPeriod.offered) { period in
                    Text(period.title).tag(period)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("On disk") {
                Text(onDiskSummary)
                    .font(Type.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if !model.recordedDays.isEmpty {
                HStack(spacing: Space.m) {
                    Picker("Delete one day", selection: $selectedDay) {
                        Text("Choose a day").tag(ActivityDayKey?.none)
                        ForEach(model.recordedDays.reversed(), id: \.rawValue) { day in
                            Text(Self.dayTitle(day)).tag(ActivityDayKey?.some(day))
                        }
                    }

                    Button("Delete") {
                        guard let selectedDay else { return }
                        pending = .day(selectedDay)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedDay == nil || model.isWorking)
                }
            }

            // Not tinted. `Palette.destructive` is reserved for the confirm button of a destructive
            // alert and nothing else, and the confirmation this opens already carries it. A red
            // control on a settings pane is the app being alarmed on the user's behalf about a
            // thing the user came here to do.
            Button("Delete all activity history…") { pending = .everything }
                .buttonStyle(.borderless)
                .disabled(model.recordedDays.isEmpty || model.isWorking)
        } header: {
            Text("History")
        } footer: {
            Text(
                "Anything older than this is deleted. Each day is one file, so deleting a day is "
                    + "deleting a file — you can open the folder afterwards and see for yourself."
            )
            .font(Type.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var onDiskSummary: String {
        let days = model.recordedDays
        guard let first = days.first, let last = days.last else { return "Nothing yet" }
        let noun = days.count == 1 ? "day" : "days"
        if days.count == 1 { return "1 \(noun) · \(first.rawValue)" }
        return "\(days.count) \(noun) · \(first.rawValue) to \(last.rawValue)"
    }

    /// Applies a new period at once when nothing would be deleted, and asks first when something
    /// would. A segmented control is one mis-click wide, and a year of history is not recoverable.
    ///
    /// The count is read from the days already listed rather than from a fresh directory scan, so
    /// the dialog cannot stall the control it belongs to. Choosing a period never deletes anything
    /// on its own — only the confirmation, or the prune the app runs at launch, does — so a stale
    /// list can at worst mean the dialog does not appear, never that a day disappears unannounced.
    private var retentionBinding: Binding<RetentionPeriod> {
        Binding(
            get: { model.retention },
            set: { period in
                let expiring = model.daysExpiring(under: period)
                guard !expiring.isEmpty else {
                    model.retention = period
                    return
                }
                pending = .retention(period, days: expiring.count)
            }
        )
    }

    // MARK: - The record

    /// What is actually on disk, said in words, with the path.
    private var recordSection: some View {
        Section {
            ForEach(RecordFact.kept) { fact in
                RecordFactRow(fact: fact)
            }
            ForEach(RecordFact.neverKept) { fact in
                RecordFactRow(fact: fact)
            }

            Text(RecordFact.permissionsStatement)
                .font(Type.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let folder = model.activityDirectoryURL {
                LabeledContent("Kept in") {
                    HStack(spacing: Space.s) {
                        Text(folder.path(percentEncoded: false))
                            .font(Type.secondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)

                        if let onRevealActivityFolder {
                            Button("Show in Finder", action: onRevealActivityFolder)
                                .buttonStyle(.borderless)
                                .font(Type.secondary)
                        }
                    }
                }
            } else {
                Text("Nothing is being written to disk in this build.")
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("What Lggr keeps")
        } footer: {
            Text("One plain-text file per day, named for the day. Read them yourself.")
                .font(Type.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Notices

    /// The outcome of the last thing the user asked for, and anything that went wrong.
    ///
    /// Rendered as one calm line rather than an alert. A deletion that worked deserves a sentence
    /// saying so — a list that silently got shorter leaves the user wondering whether it worked.
    @ViewBuilder private var noticeSection: some View {
        if model.lastOutcome != nil || model.failure != nil || model.quarantineNotice != nil {
            Section {
                if let outcome = model.lastOutcome {
                    Text(outcome)
                        .font(Type.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let failure = model.failure {
                    Text(failure)
                        .font(Type.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let quarantine = model.quarantineNotice {
                    Text(quarantine)
                        .font(Type.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Dismiss") { model.clearOutcome() }
                    .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Destructive actions

    /// The three things on this pane that cannot be undone.
    ///
    /// `@MainActor` because its copy reads `dayTitle`, whose `DateFormatter` is main-actor state; a
    /// nested type does not inherit the outer type's isolation.
    @MainActor
    private enum PendingAction {
        case day(ActivityDayKey)
        case everything
        case retention(RetentionPeriod, days: Int)

        /// A question, so the confirm button can be an answer rather than a second guess.
        var question: String {
            switch self {
            case .day(let day): "Delete the activity for \(PrivacySettingsView.dayTitle(day))?"
            case .everything: "Delete all activity history?"
            case .retention: "Delete the activity that is already older than that?"
            }
        }

        /// The blast radius, named before the consent is asked for.
        var detail: String {
            switch self {
            case .day:
                return "One day's file is removed. Your focus sessions are not affected."
            case .everything:
                return
                    "Every day file is removed. Your focus sessions, projects and accomplishments "
                    + "stay exactly as they are."
            case .retention(let period, let days):
                let noun = days == 1 ? "day" : "days"
                return
                    "Keeping activity for \(period.title.lowercased()) means \(days) \(noun) "
                    + "already on disk are older than that. They are removed now."
            }
        }

        var confirmTitle: String {
            switch self {
            case .day: "Delete the day"
            case .everything: "Delete everything"
            case .retention: "Delete them"
            }
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { isPresented in if !isPresented { pending = nil } }
        )
    }

    private func perform(_ action: PendingAction) {
        pending = nil
        switch action {
        case .day(let day):
            selectedDay = nil
            Task { await model.deleteDay(day) }
        case .everything:
            selectedDay = nil
            Task { await model.deleteAllHistory() }
        case .retention(let period, _):
            model.retention = period
            Task { await model.applyRetention() }
        }
    }

    // MARK: - Formatting

    /// The day as a person reads it, with the file name it corresponds to still recoverable from it.
    ///
    /// Deliberately not a relative phrase — "Yesterday" changes meaning overnight, and a control
    /// that deletes a file should name the file it is about to delete.
    static func dayTitle(_ day: ActivityDayKey) -> String {
        var components = DateComponents()
        components.year = day.year
        components.month = day.month
        components.day = day.day
        let calendar = Calendar.autoupdatingCurrent
        guard let date = calendar.date(from: components) else { return day.rawValue }
        return "\(day.rawValue) · \(dayFormatter.string(from: date))"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .autoupdatingCurrent
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter
    }()
}

// MARK: - One application

/// A row in either list: the name, the identifier under it, and the two ways out of the list.
///
/// The bundle identifier is shown rather than hidden. It is the thing that actually matches, two
/// applications can share a display name, and a user checking whether they excluded the right
/// browser deserves to see what Lggr is comparing against.
@MainActor
private struct ApplicationRow: View {

    let application: TrackedApplication
    let rule: ApplicationRule
    let isShipped: Bool
    let onMove: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    private var otherRule: ApplicationRule {
        rule == .privateActivity ? .excluded : .privateActivity
    }

    private var moveTitle: String {
        rule == .privateActivity ? "Record nothing for it" : "Keep the time, drop the name"
    }

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.s) {
                    Text(application.displayName)
                        .font(Type.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isShipped {
                        Text("built in")
                            .font(Type.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(application.bundleIdentifier)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.s)

            // Always present, never only on hover: a control the user has to discover by waving the
            // mouse at a row is a control a keyboard user does not have.
            Button(action: onRemove) {
                Image(systemName: Icon.remove)
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .help("Remove \(application.displayName) from this list")
            .accessibilityLabel("Remove \(application.displayName)")
        }
        .padding(.vertical, Space.xxs)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .contextMenu {
            Button(moveTitle, action: onMove)
            Divider()
            Button("Remove from this list", action: onRemove)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(application.displayName), \(rule.title)")
        .accessibilityValue(application.bundleIdentifier)
    }
}

// MARK: - One line of the record

/// `✓ The application in front of you` / `✕ Window titles`, with the clause underneath.
@MainActor
private struct RecordFactRow: View {

    let fact: RecordFact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            // No colour on either symbol. A green tick and a red cross would turn a factual table
            // into a scorecard, and there is nothing here for the user to have scored well on.
            Image(systemName: fact.isKept ? Icon.selected : Icon.dismiss)
                .imageScale(.small)
                .foregroundStyle(fact.isKept ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(fact.subject)
                    .font(Type.body)
                    .foregroundStyle(fact.isKept ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(fact.detail)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Space.s)
        }
        .padding(.vertical, Space.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fact.subject), \(fact.isKept ? "kept" : "never kept")")
        .accessibilityValue(fact.detail)
    }
}

// MARK: - Adding an application

/// The picker.
///
/// Built from the applications Lggr has **actually recorded** over the last two weeks, plus a file
/// picker for everything else. It never enumerates what is installed: walking the disk at launch is
/// a burst of work for a list nobody has asked for, and acceptance criterion 8 — no significant
/// energy over an eight-hour battery day — is a Phase 1 gate rather than a later polish item.
///
/// The list is loaded when this sheet appears, which is the first moment anyone wants it.
@MainActor
private struct ApplicationPicker: View {

    let model: PrivacyModel
    let rule: ApplicationRule
    let onFinish: () -> Void

    @State private var query = ""
    @State private var isLoading = true

    private var matches: [TrackedApplication] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.pickableApplications }
        return model.pickableApplications.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
                || $0.bundleIdentifier.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var title: String {
        rule == .privateActivity ? "Mark an application private" : "Leave an application alone"
    }

    private var explanation: String {
        rule == .privateActivity
            ? "Its time is kept. Its name and identifier become the word “Private” before anything "
                + "is written."
            : "Nothing at all is recorded for it."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(title)
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            Text(explanation)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)

            list

            HStack(spacing: Space.m) {
                Button("Choose from the Finder…") {
                    if model.chooseApplication(rule: rule) != nil { onFinish() }
                }
                .buttonStyle(.borderless)

                Spacer(minLength: Space.s)

                Button("Done", action: onFinish)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.projectEditorWidth)
        .background(Surface.canvas)
        .task {
            await model.loadSeenApplications()
            isLoading = false
        }
    }

    @ViewBuilder private var list: some View {
        if isLoading {
            Text("Looking at what Lggr has recorded recently…")
                .font(Type.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        } else if matches.isEmpty {
            // Not an error and not a failure of the user's: on a fresh install Lggr has simply not
            // seen anything yet, and the Finder is right there.
            Text(
                model.pickableApplications.isEmpty
                    ? "Lggr has not recorded any other applications yet. You can still choose one "
                        + "from the Finder."
                    : "Nothing matches that."
            )
            .font(Type.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { application in
                        PickerRow(application: application) {
                            model.setRule(rule, for: application)
                        }
                    }
                }
            }
            .frame(height: 220)
            .background(Surface.sunken, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
        }
    }
}

/// One application offered by the picker. Clicking it adds it and leaves the sheet open, so a user
/// marking four applications private does not reopen the sheet four times.
@MainActor
private struct PickerRow: View {

    let application: TrackedApplication
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(application.displayName)
                    .font(Type.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(application.bundleIdentifier)
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? Surface.hover : .clear, in: Theme.chipShape)
            .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .accessibilityLabel(application.displayName)
        .accessibilityValue(application.bundleIdentifier)
    }
}
