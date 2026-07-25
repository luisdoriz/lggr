import LggrKit
import SwiftUI

// The Weekly Review, `⌘4`. See docs/_design/SPEC.md § 8 and § 9, and docs/_design/04-screens.md § 4.4.
//
// This is the screen the product exists for: the user opens it on Friday and sees evidence of what
// they delivered. Four rules hold everywhere in this file, and each of them is a thing that would be
// easy to get wrong.
//
//   1. **Nothing is computed here.** Every figure comes off `WeeklyReview`, every sentence off
//      `InsightGenerator`, every percentage off `PercentageAllocation`, every duration off
//      `DurationFormatting`. This file arranges and labels; it does not do arithmetic about a week.
//      That is what makes the screen and the exported Markdown agree by construction.
//   2. **Observations are quotations.** They are the domain's sentences, rendered verbatim, with the
//      evidence each one rests on underneath it. When the generator stays silent because the week was
//      too sparse to support a claim, the screen shows fewer of them. It never writes one of its own,
//      and it never pads the list to look busy.
//   3. **Two charts, no more.** The allocation bar in `TimeAllocationView` and the per-day
//      context-switch bars below. Everything else is a number inside a sentence, including planned
//      versus reactive, which is two `Rectangle`s and a line of text.
//   4. **A thin week is a fact, not a shortfall.** No section says how much is missing, nothing is
//      compared against a target, a previous week or an average, and there is no headline that
//      behaves like a score — `INTELLIGENCE.md` § 3.4 removed every one of those on purpose. A week
//      spent in incident response reads as a week spent in incident response.

/// What the Weekly Review can do. Every one of these is wired by the host; the view owns no behaviour
/// and reaches for no store.
///
/// The genuinely optional capabilities are optional here too, and their affordance is absent when the
/// handler is: a control that cannot do anything must not sit on the screen implying that it can.
public struct WeeklyReviewActions {
    public var showPreviousWeek: () -> Void
    public var showNextWeek: () -> Void
    public var showCurrentWeek: () -> Void
    public var addOutcome: (OutcomePriority) -> Void
    public var editOutcome: (WeeklyOutcome) -> Void
    public var setOutcomeStatus: ((WeeklyOutcome, OutcomeStatus) -> Void)?
    public var deleteOutcome: ((WeeklyOutcome) -> Void)?
    /// Writing the review to a file. Absent until there is a save panel behind it; the screen's own
    /// Copy action needs nothing from the host and is always available.
    public var exportReview: (() -> Void)?

    public init(
        showPreviousWeek: @escaping () -> Void = {},
        showNextWeek: @escaping () -> Void = {},
        showCurrentWeek: @escaping () -> Void = {},
        addOutcome: @escaping (OutcomePriority) -> Void = { _ in },
        editOutcome: @escaping (WeeklyOutcome) -> Void = { _ in },
        setOutcomeStatus: ((WeeklyOutcome, OutcomeStatus) -> Void)? = nil,
        deleteOutcome: ((WeeklyOutcome) -> Void)? = nil,
        exportReview: (() -> Void)? = nil
    ) {
        self.showPreviousWeek = showPreviousWeek
        self.showNextWeek = showNextWeek
        self.showCurrentWeek = showCurrentWeek
        self.addOutcome = addOutcome
        self.editOutcome = editOutcome
        self.setOutcomeStatus = setOutcomeStatus
        self.deleteOutcome = deleteOutcome
        self.exportReview = exportReview
    }
}

/// The week, answered.
@MainActor
public struct WeeklyReviewView: View {

    private let review: WeeklyReview
    private let observations: [WeeklyObservation]
    private let projects: [Project]
    private let isCurrentWeek: Bool
    private let isLoading: Bool
    private let recordNotice: String?
    private let actions: WeeklyReviewActions

    @State private var didCopy = false
    @State private var showsEveryAccomplishment = false
    @State private var isSteppingWeeks = false
    @State private var showsProgressIndicator = false

    /// `⌘⇧E` is the keyboard map's "Export the current screen" (`04-screens.md` § 7.1). On this screen
    /// the export that exists is the Markdown document, and copying it to the clipboard is how it
    /// leaves the app today, so that is what the shortcut does.
    private static let copyShortcut = KeyboardShortcut("e", modifiers: [.command, .shift])

    /// How many accomplishments the list shows before "Show all". `mainAccomplishments` orders them by
    /// what the user tied them to, not by a judgment about which mattered.
    private static let accomplishmentPreview = 5

    /// - Parameters:
    ///   - observations: `InsightGenerator`'s sentences, passed in rather than generated here so the
    ///     screen shows exactly what the export would contain.
    ///   - isCurrentWeek: retires the "next week" step and the "This week" shortcut.
    ///   - isLoading: a week is being read. It only changes what is drawn while there is nothing yet —
    ///     see `loadingWeek` — because a week already on screen is better than a spinner over it.
    ///   - recordNotice: a sentence about the *record* — a day of activity that could not be read, for
    ///     instance. Never about the user, and never a claim that the week was empty.
    public init(
        review: WeeklyReview,
        observations: [WeeklyObservation],
        projects: [Project] = [],
        isCurrentWeek: Bool = true,
        isLoading: Bool = false,
        recordNotice: String? = nil,
        actions: WeeklyReviewActions = WeeklyReviewActions()
    ) {
        self.review = review
        self.observations = observations
        self.projects = projects
        self.isCurrentWeek = isCurrentWeek
        self.isLoading = isLoading
        self.recordNotice = recordNotice
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)

            if isWeekEmpty {
                // "Nothing recorded this week" is a claim, and it must not be made while the week is
                // still being read. Until the read lands, the space stays quiet.
                if isLoading {
                    loadingWeek
                } else {
                    emptyWeek
                }
            } else {
                content
            }

            // Outside the branch on purpose: a week whose activity could not be read may *look* empty,
            // and that is the case where saying so matters most.
            footnote
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Surface.canvas)
        .contextMenu { screenActions }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Weekly Review")
    }

    // MARK: - Chrome

    /// Renders immediately and is never gated on data (`04-screens.md` § 3.2). The week you are
    /// looking at is the one thing on this screen that must be legible before anything has loaded.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text("Weekly Review")
                    .font(Type.screenTitle)
                    .foregroundStyle(.primary)

                Spacer(minLength: Space.m)

                weekStepper

                if !isCurrentWeek {
                    Button("This week", action: actions.showCurrentWeek)
                        .buttonStyle(.borderless)
                        .font(Type.secondary)
                }

                // Withheld on a week with nothing in it, for the reason `WeeklyReviewActions` states
                // about its own optional handlers: a control that cannot do anything must not sit on
                // the screen implying that it can. The snapshot is what made this visible — an empty
                // week photographed with two accent-filled buttons on it, one of them offering to copy
                // a document with no facts in it, next to an empty state whose whole point is that
                // there is nothing to do here. `04-screens.md` § 3.1 allows the empty state one button;
                // this is the one. Copy stays in the context menu for a week that is genuinely empty
                // and wanted in a note anyway.
                if !isWeekEmpty || isLoading {
                    copyButton
                }
            }

            Text(weekRangeText)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
        }
    }

    /// `◀ Week of 21 July ▶`. One focus stop; `←` and `→` move a week, which is the row's entry in the
    /// keyboard map (§ 7.1, "week stepper").
    private var weekStepper: some View {
        HStack(spacing: Space.xs) {
            Button(action: actions.showPreviousWeek) {
                Image(systemName: Icon.previousWeek)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous week")

            Text(weekTitleText)
                .font(Type.secondary)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(minWidth: Layout.emptyStateMaxTextWidth / 3)
                .multilineTextAlignment(.center)

            Button(action: actions.showNextWeek) {
                Image(systemName: Icon.nextWeek)
                    .imageScale(.medium)
            }
            .buttonStyle(.plain)
            .disabled(isCurrentWeek)
            .help(isCurrentWeek ? "This is the current week." : "")
            .accessibilityLabel("Next week")
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xs)
        .background(isSteppingWeeks ? Surface.hover : Color.clear, in: Theme.chipShape)
        .focusable()
        .onMoveCommand(perform: step)
        .onHover { isSteppingWeeks = $0 }
        .lggrAnimation(Motion.tap, value: isSteppingWeeks)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Week")
        .accessibilityValue(weekTitleText)
    }

    private func step(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: actions.showPreviousWeek()
        case .right: guard !isCurrentWeek else { return }
            actions.showNextWeek()
        default: return
        }
    }

    /// The screen's one primary action. It renders the same document `WeeklyReviewMarkdown` writes for
    /// the file export, from the same function, with the observations already on screen — so what is
    /// pasted into a one-to-one is what was read here.
    private var copyButton: some View {
        Button(didCopy ? "Copied" : "Copy as Markdown", action: copyMarkdown)
            .buttonStyle(.lggrPrimary(shortcut: didCopy ? nil : Self.copyShortcut))
            .keyboardShortcut(Self.copyShortcut)
            .lggrAnimation(Motion.settle, value: didCopy)
    }

    private func copyMarkdown() {
        Pasteboard.copy(markdown)
        didCopy = true
        // The label is the confirmation. There is no toast in Lggr, and a copy that announces itself
        // in a banner costs more attention than the copy saved.
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            didCopy = false
        }
    }

    private var markdown: String {
        WeeklyReviewMarkdown.render(review, observations: observations)
    }

    @ViewBuilder private var screenActions: some View {
        Button("Copy Review as Markdown", action: copyMarkdown)
        if let exportReview = actions.exportReview {
            Button("Export Review…", action: exportReview)
        }
    }

    // MARK: - The week

    private var content: some View {
        // `ScrollingSection`, not `ScrollView`: identical in the app, and the difference is what makes
        // this screen visible to `LggrApp --snapshot`. See `ScrollingSection`.
        ScrollingSection {
            VStack(alignment: .leading, spacing: Space.xxl) {
                outcomesSection
                if TimeAllocationView.hasContent(review) {
                    TimeAllocationView(review: review, projects: projects)
                }
                plannedSection
                focusSection
                accomplishmentsSection
                supportSection
                interruptionsSection
                observationsSection
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A week with nothing in it and nothing declared. The copy is `04-screens.md` § 4.4's, verbatim,
    /// and the second line is the important one: an empty review is not a problem to be solved.
    private var emptyWeek: some View {
        EmptyStateView(
            symbol: Icon.emptyWeek,
            title: "Nothing recorded this week.",
            message: "Weekly Review fills in as you track. There's nothing to fix here.",
            actionTitle: "Set Weekly Outcome",
            action: { actions.addOutcome(.primary) }
        )
    }

    private var isWeekEmpty: Bool { review.isEmpty && review.outcomes.isEmpty }

    /// The one place in Lggr a `ProgressView` is allowed, and it waits 250ms before appearing
    /// (`04-screens.md` § 3.2): a week of activity is the single aggregation that might take long
    /// enough to notice, and a spinner that flashes for 40ms is worse than no spinner at all. There is
    /// no full-screen spinner and no shimmer — the latter would need `.repeatForever`, which § 2.8 bans.
    private var loadingWeek: some View {
        ProgressView()
            .controlSize(.small)
            .opacity(showsProgressIndicator ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                showsProgressIndicator = true
            }
            .accessibilityLabel("Reading this week")
    }

    // MARK: - Outcomes

    /// One primary, up to two secondary, and however many operational responsibilities the job
    /// carries. `SPEC.md` § 8's instruction — *avoid encouraging a large task list* — is carried by the
    /// shape rather than by a warning: there are three seats, they are visible, and when they are full
    /// the only thing left to add is an operational responsibility.
    @ViewBuilder private var outcomesSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Outcomes")

            if review.outcomes.isEmpty {
                noOutcomeState
            } else {
                focusOutcomes
                operationalOutcomes
                unseatedOutcomes
                if seating.isFocusFull {
                    Text("A week has room for one primary outcome and two secondary ones.")
                        .font(Type.caption)
                        .foregroundStyle(Ink.support)
                }
            }
        }
    }

    private var noOutcomeState: some View {
        EmptyStateView(
            symbol: OutcomeStatus.notStarted.symbolName,
            title: "No outcome set for this week.",
            message:
                "You can still review the time. Setting one makes the \u{201C}primary outcome\u{201D} "
                + "line meaningful.",
            actionTitle: "Set Weekly Outcome",
            action: { actions.addOutcome(.primary) }
        )
    }

    @ViewBuilder private var focusOutcomes: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let primary = review.outcomes.primary {
                card(for: primary, emphasis: .primary)
            } else {
                OutcomeSeat(
                    title: "Set the primary outcome",
                    action: { actions.addOutcome(.primary) }
                )
            }

            ForEach(review.outcomes.secondary) { outcome in
                card(for: outcome, emphasis: .secondary)
            }

            // One seat at a time. Two empty rows side by side would read as a form to fill in, which
            // is the task list § 8 asks us not to invite.
            if review.outcomes.canAddSecondary {
                OutcomeSeat(
                    title: "Add a secondary outcome",
                    action: { actions.addOutcome(.secondary) }
                )
            }
        }
    }

    /// Uncapped, and quieter than the outcomes above it. Operational load is observed rather than
    /// chosen — on-call, review load, one-to-ones — and hiding some of it would understate the week.
    @ViewBuilder private var operationalOutcomes: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Operational")
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                SectionAction(title: "Add", action: { actions.addOutcome(.operational) })
            }

            if review.outcomes.operational.isEmpty {
                Text("Recurring responsibilities go here — on-call, review load, one-to-ones.")
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(review.outcomes.operational) { outcome in
                        card(for: outcome, emphasis: .operational)
                    }
                }
            }
        }
        .padding(.top, Space.m)
    }

    /// Outcomes the shape has no room for. `WeeklyOutcomeSet` never discards one, so neither does this
    /// screen: the answer to "where did my fourth outcome go" is visible rather than silent.
    @ViewBuilder private var unseatedOutcomes: some View {
        if review.outcomes.hasUnseated {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Also declared")
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(review.outcomes.unseated) { outcome in
                        card(for: outcome, emphasis: .secondary)
                    }
                }

                Text("These have no seat this week. Change a priority to make room, or keep them as operational responsibilities.")
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Space.m)
        }
    }

    private func card(for outcome: WeeklyOutcome, emphasis: OutcomeCard.Emphasis) -> some View {
        OutcomeCard(
            outcome: outcome,
            progress: review.outcomeProgress.first { $0.outcomeID == outcome.id },
            accomplishments: review.accomplishments.filter { $0.weeklyOutcomeID == outcome.id },
            emphasis: emphasis,
            onEdit: { actions.editOutcome(outcome) },
            onSetStatus: actions.setOutcomeStatus.map { handler in
                { status in handler(outcome, status) }
            },
            onDelete: actions.deleteOutcome.map { handler in
                { handler(outcome) }
            }
        )
    }

    private var seating: OutcomeSeating {
        OutcomeSeating(set: review.outcomes)
    }

    // MARK: - Planned versus reactive

    /// Two `Rectangle`s and a sentence. This is not one of the two charts: a two-part split does not
    /// need axes, and § 4.4 spends the chart budget elsewhere.
    @ViewBuilder private var plannedSection: some View {
        let split = review.plannedVsReactive
        if split.trackedDuration > 0 {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Planned and reactive")

                let shares = PercentageAllocation.percentages(
                    of: [split.plannedDuration, split.reactiveDuration]
                )
                GeometryReader { proxy in
                    HStack(spacing: Layout.hairline) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: plannedWidth(in: proxy.size.width, split: split))
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.3))
                    }
                }
                .frame(height: Layout.allocationBarHeight)
                .clipShape(Theme.chipShape)
                .accessibilityHidden(true)

                Text(plannedText(split: split, shares: shares))
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if split.committedDuration > 0 {
                    Text(
                        "Of the planned time, "
                            + "\(DurationFormatting.compact(split.committedDuration)) "
                            + "was filed against a weekly outcome."
                    )
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func plannedWidth(in total: CGFloat, split: PlannedVsReactive) -> CGFloat {
        guard split.trackedDuration > 0 else { return 0 }
        let available = max(0, total - Layout.hairline)
        return available * CGFloat(split.plannedDuration / split.trackedDuration)
    }

    private func plannedText(split: PlannedVsReactive, shares: [Int]) -> String {
        guard shares.count == 2 else { return "" }
        let planned =
            "\(shares[0])% planned (\(DurationFormatting.compact(split.plannedDuration)), "
            + "\(split.plannedSessionCount) \(split.plannedSessionCount == 1 ? "session" : "sessions"))"
        let reactive =
            "\(shares[1])% reactive (\(DurationFormatting.compact(split.reactiveDuration)), "
            + "\(split.reactiveSessionCount) \(split.reactiveSessionCount == 1 ? "session" : "sessions"))"
        return "\(planned) · \(reactive)"
    }

    // MARK: - Focus

    @ViewBuilder private var focusSection: some View {
        if review.finishedSessionCount > 0 || !review.episodes.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Focus")

                if !focusCounts.isEmpty {
                    Text(focusCounts.joined(separator: " · "))
                        .font(Type.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }

                switchesChart
            }
        }
    }

    private var focusCounts: [String] {
        var parts: [String] = []
        let finished = review.finishedSessionCount
        if finished > 0 {
            parts.append("\(finished) finished \(finished == 1 ? "session" : "sessions")")
            parts.append("\(DurationFormatting.compact(review.trackedDuration)) tracked")
        }
        if review.sessionsCompleted > 0 {
            parts.append("\(review.sessionsCompleted) completed")
        }
        if review.sessionsInterrupted > 0 {
            parts.append("\(review.sessionsInterrupted) interrupted")
        }
        if review.sessionsWithCapturedInterruption > 0 {
            parts.append(
                "\(review.sessionsWithCapturedInterruption) recorded an interruption while running"
            )
        }
        return parts
    }

    /// The second and last chart in the application: context switches per day.
    ///
    /// It renders only when there are episodes to count them from. Seven empty bars would be a claim
    /// that Lggr watched all week and saw one unbroken block a day, and the usual reason for no
    /// episodes is that ambient capture was off — a fact about the record, not about the week.
    @ViewBuilder private var switchesChart: some View {
        if !review.episodes.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                Text("Context switches per day")
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .padding(.top, Space.s)

                HStack(alignment: .bottom, spacing: Space.s) {
                    ForEach(review.days) { day in
                        SwitchBar(
                            day: day,
                            peak: peakSwitches,
                            weekdayText: weekdayNarrow(day.start),
                            weekdayName: weekdayWide(day.start)
                        )
                    }
                }
                .frame(height: Space.hero, alignment: .bottom)

                Text(switchesCaption)
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Context switches per day")
        }
    }

    private var peakSwitches: Int {
        review.days.reduce(0) { max($0, $1.contextSwitches) }
    }

    private var switchesCaption: String {
        let total = review.contextSwitchTotal
        var sentence = "\(total) \(total == 1 ? "move" : "moves") between blocks of work this week."
        if let average = review.averageContextSwitchesPerActiveDay {
            sentence += " \(Int(average.rounded())) a day across days with recorded activity."
        }
        return sentence
    }

    private func weekdayNarrow(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.narrow))
    }

    private func weekdayWide(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    // MARK: - Accomplishments

    @ViewBuilder private var accomplishmentsSection: some View {
        if !review.accomplishments.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Accomplishments", count: review.accomplishments.count) {
                    if review.accomplishments.count > Self.accomplishmentPreview {
                        SectionAction(
                            title: showsEveryAccomplishment ? "Show fewer" : "Show all",
                            action: { showsEveryAccomplishment.toggle() }
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shownAccomplishments) { accomplishment in
                        WeeklyAccomplishmentRow(
                            accomplishment: accomplishment,
                            project: project(for: accomplishment.projectID)
                        )
                    }
                }
            }
            .lggrAnimation(Motion.reveal, value: showsEveryAccomplishment)
        }
    }

    /// Ordered by what the user tied them to — everything linked to the primary outcome first — which
    /// is `WeeklyReview.mainAccomplishments`' rule, not a judgment made here. No accomplishment type
    /// outranks another.
    private var shownAccomplishments: [Accomplishment] {
        showsEveryAccomplishment
            ? review.mainAccomplishments(limit: review.accomplishments.count)
            : review.mainAccomplishments(limit: Self.accomplishmentPreview)
    }

    // MARK: - Support work

    /// § 9's "what work remained invisible?". Review, management and incident work leaves no trace
    /// anywhere else, and the people-unblocked figure is an aggregate: who was unblocked stays in the
    /// app and never reaches an export — `INTELLIGENCE.md` § 3.7.
    @ViewBuilder private var supportSection: some View {
        if !supportLines.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Support work")

                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(supportLines, id: \.self) { line in
                        Text(line)
                            .font(Type.body)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("The part of the week that leaves no trace on a board or in a changelog.")
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var supportLines: [String] {
        var lines: [String] = []
        if review.supportDuration > 0, review.supportSessionCount > 0 {
            lines.append(
                "Code review, management and incident work took "
                    + "\(DurationFormatting.compact(review.supportDuration)) across "
                    + "\(review.supportSessionCount) "
                    + "\(review.supportSessionCount == 1 ? "session" : "sessions")."
            )
        }
        let unblocked = review.peopleUnblockedCount
        if unblocked > 0 {
            lines.append(
                "\(AccomplishmentPhrasing.phrase(.personUnblocked, count: unblocked)) this week."
            )
        }
        let reviewed = review.accomplishments.reduce(0) {
            $0 + ($1.type == .pullRequestReviewed ? 1 : 0)
        }
        if reviewed > 0 {
            lines.append(
                "\(AccomplishmentPhrasing.phrase(.pullRequestReviewed, count: reviewed))."
            )
        }
        return lines
    }

    // MARK: - Interruptions

    @ViewBuilder private var interruptionsSection: some View {
        if !review.interruptionSources.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Interruptions", count: review.interruptionCount)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(review.interruptionSources) { source in
                        HStack(spacing: Space.s) {
                            Image(systemName: source.source.symbolName)
                                .imageScale(.medium)
                                .foregroundStyle(.secondary)
                                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                                .accessibilityHidden(true)
                            Text(source.source.displayName)
                                .font(Type.body)
                                .foregroundStyle(.primary)
                            Spacer(minLength: Space.m)
                            Text(verbatim: "\(source.count)")
                                .font(Type.secondary)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, Space.xs)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(source.source.displayName)
                        .accessibilityValue("\(source.count)")
                    }
                }

                Text("Counted from the notes you captured, not from anything Lggr inferred.")
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
            }
        }
    }

    // MARK: - Observations

    /// Plain sentences from `InsightGenerator`: `Type.body`, `.primary`, one per line, **no bullets, no
    /// icons, no colour, no ranking**. They are evidence, and dressing evidence up as advice is how
    /// this screen would start to feel like a performance review.
    ///
    /// Each one carries the evidence it rests on underneath it, so a claim can be argued with rather
    /// than merely believed. When there are none, the section says what the threshold is — it does not
    /// invent a sentence to fill the space.
    @ViewBuilder private var observationsSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Observations")

            if observations.isEmpty {
                Text(
                    "Lggr writes an observation only when the week holds enough evidence to support "
                    + "one. This week does not yet."
                )
                .font(Type.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Space.m) {
                    ForEach(observations) { observation in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(observation.text)
                                .font(Type.body)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(observation.evidence)
                                .font(Type.caption)
                                .foregroundStyle(Ink.support)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("Copy") { Pasteboard.copy(observation.text) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(observation.text)
                        .accessibilityValue(observation.evidence)
                    }
                }
            }
        }
    }

    // MARK: - The record

    /// Lggr states its own blind spots on the screen where the numbers appear, rather than in a
    /// document nobody reads.
    @ViewBuilder private var footnote: some View {
        if let recordNotice {
            Text(recordNotice)
                .font(Type.caption)
                .foregroundStyle(Ink.support)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Dates

    private var weekTitleText: String {
        "Week of " + review.week.start.formatted(.dateTime.day().month(.wide))
    }

    /// The last instant inside the week rather than `week.end`, which is the following Monday's
    /// midnight and would print a range one day too long.
    private var weekRangeText: String {
        let lastMoment = review.week.end.addingTimeInterval(-1)
        let start = review.week.start.formatted(.dateTime.day().month(.abbreviated))
        let end = lastMoment.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) \u{2013} \(end)"
    }

    // MARK: - Lookups

    private func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }
}

// MARK: - One accomplishment

/// A week's accomplishment line.
///
/// Deliberately not `AccomplishmentRow`, which is Today's anatomy: it stamps the time of day, and
/// "11:04" with no weekday beside it is unreadable in a list that spans seven of them. § 4.4's own
/// sketch of this section is a plain line per thing delivered, which is what this is.
private struct WeeklyAccomplishmentRow: View {

    let accomplishment: Accomplishment
    let project: Project?

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(accomplishment.title)
                    .font(Type.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Space.xs) {
                    Text(accomplishment.timestamp.formatted(.dateTime.weekday(.wide)))
                        .font(Type.secondary)
                        .foregroundStyle(.secondary)
                    if project != nil {
                        Text(verbatim: "·")
                            .font(Type.secondary)
                            .foregroundStyle(.tertiary)
                        ProjectBadge(project: project, variant: .compact)
                    }
                }
                .accessibilityHidden(true)
            }

            Spacer(minLength: Space.m)
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .contextMenu {
            Button("Copy") { Pasteboard.copy(accomplishment.title) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accomplishment.title)
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        var parts = [
            accomplishment.type.displayName,
            accomplishment.timestamp.formatted(.dateTime.weekday(.wide)),
        ]
        if let name = project?.normalizedName { parts.append(name) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - One empty seat

/// An unfilled outcome seat.
///
/// A dashed outline rather than a filled button, borrowing the timeline's language for "this is not
/// something you declared". It is quiet on purpose: the seat exists so the shape of a week is legible,
/// not to ask the user to fill it in.
private struct OutcomeSeat: View {

    let title: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: Icon.add)
                    .imageScale(.medium)
                    .foregroundStyle(.tertiary)
                    .frame(width: Layout.symbolColumnWidth, alignment: .center)
                Text(title)
                    .font(Type.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.m)
            }
            .padding(.vertical, Space.m)
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
            .overlay(
                Theme.cardShape.strokeBorder(
                    Stroke.card,
                    style: StrokeStyle(lineWidth: Layout.hairline, dash: [Space.xs, Space.xs])
                )
            )
            .contentShape(Theme.cardShape)
        }
        .buttonStyle(.plain)
        .padding(.vertical, Space.xs)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .accessibilityLabel(title)
    }
}

// MARK: - One day of context switches

/// One bar of the per-day context-switch chart.
///
/// Every day of the week gets a column, including the ones with nothing in them: seven columns is the
/// week, and dropping the quiet days would make Tuesday look like the middle of it. The bar is not
/// coloured by size, there is no threshold line and the peak is not marked — a chart that flags its
/// own maximum has decided the maximum is bad.
private struct SwitchBar: View {

    let day: WeeklyReview.Day
    let peak: Int
    let weekdayText: String
    let weekdayName: String

    var body: some View {
        VStack(spacing: Space.xs) {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(day.contextSwitches > 0 ? Color.accentColor.opacity(0.65) : Color.clear)
                        .frame(height: height(in: proxy.size.height))
                }
                .frame(maxWidth: .infinity)
            }
            .background(alignment: .bottom) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: Layout.hairline)
            }
            .clipShape(Theme.chipShape)

            Text(weekdayText)
                .font(Type.caption)
                .foregroundStyle(Ink.support)
        }
        .help("\(weekdayName) · \(day.contextSwitches) \(day.contextSwitches == 1 ? "switch" : "switches")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(weekdayName)
        .accessibilityValue(
            "\(day.contextSwitches) \(day.contextSwitches == 1 ? "context switch" : "context switches")"
        )
    }

    private func height(in total: CGFloat) -> CGFloat {
        guard peak > 0, day.contextSwitches > 0 else { return 0 }
        let share = CGFloat(day.contextSwitches) / CGFloat(peak)
        return max(Layout.allocationBarHeight / 2, total * share)
    }
}
