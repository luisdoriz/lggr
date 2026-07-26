import LggrKit
import SwiftUI

// The end-of-day review: today's unlabelled blocks, one at a time.
// See docs/_design/INTELLIGENCE.md §4 Phase 2 and docs/_design/04-screens.md § 10.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  BATCH IS WHAT MAKES THIS SURVIVABLE
//
//  Nobody labels one thing. Most people will label eight in two minutes — but only if the eight
//  arrive as one gesture with the evidence already on screen and the answer usually one they have
//  already given today. So this is a queue, not eight sheets: one panel, ⌘⏎ files and advances, ⌘→
//  skips, and the whole thing is closable at any point with nothing half-done left behind.
//
//  Every block filed here is written by exactly the arithmetic `LabelBlockSheet` uses —
//  `SessionFromEpisode` — so a block labelled in the queue and the same block labelled from the
//  timeline produce the identical record. There is no second definition of what labelling means.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// Five decisions this file holds:
//
//   * **The field is empty and the roster is its placeholder.** `INTELLIGENCE.md` §2: propose as
//     ghost text, never as inserted text, so a wrong proposal costs zero keystrokes. "Xcode,
//     Terminal" is what Lggr saw, which is evidence; it is not a sentence anybody would write, so it
//     is never what gets saved. The single keystroke that resolves a block is one of the *user's own*
//     recent outcomes — `⌥1`–`⌥3` — because most unlabelled blocks are more of something already
//     named today.
//   * **Skipping is a first-class answer with a button of its own.** A queue that can only be
//     completed is a decision queue, which is `INTELLIGENCE.md` §7's risk 9. A skipped block stays on
//     the timeline, labellable there, and ages out silently into neutral tracked time.
//   * **The progress line counts down the offer, not the user.** "Block 2 of 5" describes the queue.
//     There is no total of untracked time, no count of consecutive days, no score — §3.4 removed all
//     three, four separate times.
//   * **The end of the queue is a fact, not a congratulation.** "Nothing else from today is
//     unlabelled." No praise: `INTELLIGENCE.md` §2 is explicit that "Perfect focus!" and shame are the
//     same mechanism.
//   * **A block the record already accounts for states so and offers only Skip.** The same refusal
//     `LabelBlockSheet` prints, in the same words, because it is the same fact.
//
// The sheet touches no store: the host computed every claim before this opened, and `onFile` hands
// back the block and the three fields the user supplied.

/// "Today's record" — the queue of blocks nobody declared anything over.
///
/// Renders from plain values, so it photographs against `PreviewFixtures` with no store and no clock.
@MainActor
public struct EndOfDayReviewSheet: View {

    /// One block in the queue, with everything needed to file it already resolved.
    ///
    /// The claim is computed by the host against the day's declared sessions, exactly as
    /// `LabelBlockSheet`'s is, so the queue and the timeline cannot disagree about what a block may
    /// claim.
    public struct Item: Identifiable {
        public let episode: Episode
        public let claim: Result<SessionFromEpisode.Claim, SessionFromEpisode.Refusal>
        /// From a rule **the user wrote**, and `nil` otherwise. Never inference: `INTELLIGENCE.md`
        /// §3.8 refuses project inference until there is evidence to infer from.
        public let suggestedProjectID: UUID?
        public let suggestedWorkType: WorkType

        public var id: UUID { episode.id }

        public init(
            episode: Episode,
            claim: Result<SessionFromEpisode.Claim, SessionFromEpisode.Refusal>,
            suggestedProjectID: UUID? = nil,
            suggestedWorkType: WorkType = .deepWork
        ) {
            self.episode = episode
            self.claim = claim
            self.suggestedProjectID = suggestedProjectID
            self.suggestedWorkType = suggestedWorkType
        }
    }

    /// `⌘⏎` — file this block and advance. The same combination every other sheet saves with.
    static let fileShortcut = KeyboardShortcut(.return, modifiers: .command)
    /// `⌘→` — leave this block alone and advance. "Next", which is what it does.
    static let skipShortcut = KeyboardShortcut(.rightArrow, modifiers: .command)
    /// How many of the user's recent outcomes get a one-chord shortcut. Three, for the reason
    /// `OutcomeField` shows three: a list longer than a glance is slower than typing.
    static let quickChoiceLimit = 3

    private let items: [Item]
    private let projects: [Project]
    private let recentOutcomes: [String]
    private let estimateText: String
    private let setAside: Int
    private let onFile: (Episode, SessionFromEpisode.Label) -> Void
    private let onSkip: (Episode) -> Void
    private let onClose: () -> Void

    @State private var index: Int
    @State private var text: String = ""
    @State private var projectID: UUID?
    @State private var workType: WorkType = .deepWork
    @State private var showsEmptyHint = false
    @State private var filed = 0
    @State private var skipped = 0

    @FocusState private var focus: StartPanelField?

    /// - Parameters:
    ///   - items: the queue, oldest block first — the order the day happened in. An empty array is a
    ///     valid input and renders the closing panel: the notification that opened this may have been
    ///     answered ten minutes late, by which time the user had declared everything themselves.
    ///   - estimateText: "about 2 minutes", from `UnlabelledWork.Report`. Passed in rather than
    ///     recomputed so the sentence on the banner and the sentence on the sheet are one string.
    ///   - setAside: qualifying blocks beyond the queue's cap, still on the timeline.
    public init(
        items: [Item],
        projects: [Project] = [],
        recentOutcomes: [String] = [],
        estimateText: String = "",
        setAside: Int = 0,
        onFile: @escaping (Episode, SessionFromEpisode.Label) -> Void,
        onSkip: @escaping (Episode) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.items = items
        self.projects = projects
        self.recentOutcomes = recentOutcomes
        self.estimateText = estimateText
        self.setAside = max(0, setAside)
        self.onFile = onFile
        self.onSkip = onSkip
        self.onClose = onClose
        _index = State(initialValue: 0)
        _projectID = State(initialValue: items.first?.suggestedProjectID)
        _workType = State(initialValue: items.first?.suggestedWorkType ?? .deepWork)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            if let item = current {
                evidence(item)

                switch item.claim {
                case .success:
                    form
                case .failure(let refusal):
                    refusalNotice(refusal)
                }
            } else {
                closingNotice
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.reviewSheetWidth, alignment: .leading)
        .background(Surface.canvas)
        .defaultFocus($focus, StartPanelField.outcome)
        .onExitCommand(perform: onClose)
        .onChange(of: text) { _, _ in showsEmptyHint = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today's record")
    }

    // MARK: - Header

    /// The title, the position in the queue, and what answering costs.
    ///
    /// The estimate is here rather than only in the notification because the offer has to stay
    /// answerable after it is accepted: a user who opened this expecting two minutes and cannot see
    /// how far through they are will abandon it in the middle, and an abandoned queue is worse than
    /// one never opened.
    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text("Today's record")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's record")
        .accessibilityValue(subtitle)
    }

    /// "Block 2 of 5 · about 2 minutes". A description of the queue, never of the person.
    private var subtitle: String {
        guard !items.isEmpty else { return closingSentence }
        guard current != nil else { return closingSentence }
        var parts = ["Block \(index + 1) of \(items.count)"]
        if !estimateText.isEmpty, index == 0 { parts.append(estimateText) }
        return parts.joined(separator: " · ")
    }

    // MARK: - The block

    /// What Lggr measured, which is the reason the user can recognise the block at all.
    ///
    /// The range, the measured time, and the applications. Three facts, no adjectives. The duration is
    /// measured application time and never the wall-clock span, so idle minutes the timeline has
    /// already broken out are not quietly counted as work.
    private func evidence(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.xl) {
                fact("Measured", TimelineClock.range(from: claimedRange(item).start, to: claimedRange(item).end))
                fact("Time", DurationFormatting.compact(claimedDuration(item)))
            }

            Text(item.episode.appRosterText)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Applications")
                .accessibilityValue(item.episode.appRosterText)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(value)
                .font(Type.metricValue)
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: - The form

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            OutcomeField(
                text: $text,
                recentOutcomes: recentOutcomes,
                focus: $focus,
                showsEmptyHint: showsEmptyHint,
                // What Lggr saw, as ghost text. Evidence in the field, never inserted into it.
                placeholder: placeholderText,
                onSubmit: fileCurrent,
                onCancel: onClose
            )

            if !quickChoices.isEmpty { quickChoiceRow }

            HStack(spacing: Space.s) {
                ProjectPicker(projects: projects, selection: $projectID)
                Spacer(minLength: Space.s)
                WorkTypePicker(selection: $workType)
            }

            provenanceNotice
            buttons
        }
    }

    /// The applications that were in front, as the field's ghost text.
    private var placeholderText: String {
        guard let roster = current?.episode.appRosterText, !roster.isEmpty else {
            return "What this was"
        }
        return roster
    }

    /// The user's own recent outcomes, each one keystroke away.
    ///
    /// This is what makes eight blocks take two minutes. The strings are the user's, typed on an
    /// earlier session today — so accepting one is quoting themselves rather than accepting a guess,
    /// which is why it can be a single chord with no confirmation.
    private var quickChoices: [String] {
        Array(recentOutcomes.prefix(Self.quickChoiceLimit))
    }

    private var quickChoiceRow: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Again")
                .font(Type.caption)
                .foregroundStyle(.tertiary)

            // Wrapped rather than a row of three fixed buttons: an outcome is a sentence and three of
            // them do not fit across a 520pt sheet.
            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(quickChoices.enumerated()), id: \.offset) { offset, outcome in
                    Button {
                        file(outcome: outcome)
                    } label: {
                        HStack(spacing: Space.s) {
                            Text(verbatim: "⌥\(offset + 1)")
                                .font(Type.caption)
                                .monospaced()
                                .foregroundStyle(.tertiary)
                            Text(outcome)
                                .font(Type.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(offset + 1)")),
                        modifiers: .option
                    )
                    .help("File this block as “\(outcome)”")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent outcomes")
    }

    /// What filing records about itself. The same statement, in the same voice and the same position,
    /// as `LabelBlockSheet`'s — because it is the same record.
    private var provenanceNotice: some View {
        Text(
            "Each of these is recorded as labelled afterwards and as reactive time, so your weekly "
                + "review can tell work you planned from work you recognised later. The measured "
                + "times do not change."
        )
        .font(Type.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: Space.m) {
            Button("Skip", action: skipCurrent)
                .buttonStyle(.bordered)
                .keyboardShortcut(Self.skipShortcut)
                .help("Leave this block unlabelled and move on")

            Button("Close", action: onClose)
                .buttonStyle(.borderless)
                .font(Type.secondary)
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: Space.m)

            // Not `.disabled()`, for the reason the start panel's button is not: a disabled button
            // swallows its own shortcut, and ⌘⏎ on an empty field has to return focus and say why.
            Button(isLast ? "Save Session" : "Save and Next", action: fileCurrent)
                .buttonStyle(.lggrPrimary(shortcut: Self.fileShortcut))
                .keyboardShortcut(Self.fileShortcut)
                .opacity(label.isComplete ? 1 : 0.55)
                .lggrAnimation(Motion.settle, value: label.isComplete)
                .accessibilityHint(label.isComplete ? "" : "Add what this was to save it.")
        }
    }

    // MARK: - A block that cannot be labelled

    private func refusalNotice(_ refusal: SessionFromEpisode.Refusal) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(refusal.sentence)
                .font(Type.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.m) {
                Button("Close", action: onClose)
                    .buttonStyle(.borderless)
                    .font(Type.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Space.m)
                Button(isLast ? "Done" : "Next", action: skipCurrent)
                    .buttonStyle(.lggrPrimary(shortcut: Self.skipShortcut))
                    .keyboardShortcut(Self.skipShortcut)
            }
        }
    }

    // MARK: - The end of the queue

    /// A fact, and a way out. No praise, and no number.
    private var closingNotice: some View {
        HStack(spacing: Space.m) {
            Spacer(minLength: Space.m)
            Button("Done", action: onClose)
                .buttonStyle(.lggrPrimary)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// *"Nothing else from today is unlabelled."* — or, when blocks were skipped, the honest version
    /// of the same fact.
    ///
    /// `INTELLIGENCE.md` §2 bans praise as firmly as it bans shame: they are the same mechanism. So
    /// there is no "Perfect!", no count of what was filed, and nothing at all if the user skipped
    /// everything — a skipped block is a legitimate answer, and a closing line that counted them would
    /// turn the queue into a scoreboard.
    private var closingSentence: String {
        if items.isEmpty {
            return "Nothing from today is unlabelled."
        }
        if skipped > 0 {
            return setAside > 0
                ? "The rest of today's blocks are on the timeline, and can be labelled there."
                : "The blocks left here are on the timeline, and can be labelled there."
        }
        return setAside > 0
            ? "Nothing else in this queue is unlabelled. Older blocks stay on the timeline."
            : "Nothing else from today is unlabelled."
    }

    // MARK: - Filing

    private var current: Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    private var isLast: Bool { index >= items.count - 1 }

    private var label: SessionFromEpisode.Label {
        SessionFromEpisode.Label(
            intendedOutcome: text,
            projectID: projectID,
            workType: workType
        )
    }

    private func fileCurrent() {
        guard let item = current, case .success = item.claim else { return }
        guard label.isComplete else {
            showsEmptyHint = true
            focus = .outcome
            return
        }
        onFile(item.episode, label)
        filed += 1
        advance()
    }

    /// One keystroke: file this block with an outcome the user has already used today.
    private func file(outcome: String) {
        guard let item = current, case .success = item.claim else { return }
        let trimmed = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onFile(
            item.episode,
            SessionFromEpisode.Label(
                intendedOutcome: trimmed,
                projectID: projectID,
                workType: workType
            )
        )
        filed += 1
        advance()
    }

    private func skipCurrent() {
        guard let item = current else { return }
        onSkip(item.episode)
        skipped += 1
        advance()
    }

    /// Moves to the next block and resets the three fields to that block's own pre-fills.
    ///
    /// Resetting is the point: carrying the previous block's typed sentence forward would file the
    /// wrong sentence on the next block with one keystroke, which is the single most damaging thing a
    /// queue can do. The project and the work type come from the new block's own rules.
    private func advance() {
        index += 1
        text = ""
        showsEmptyHint = false
        projectID = current?.suggestedProjectID
        workType = current?.suggestedWorkType ?? .deepWork
        if current != nil { focus = .outcome }
    }

    // MARK: - Derived

    private func claimedRange(_ item: Item) -> DateInterval {
        if case .success(let claim) = item.claim { return claim.claimed }
        return DateInterval(
            start: item.episode.start,
            end: max(item.episode.start, item.episode.end)
        )
    }

    private func claimedDuration(_ item: Item) -> TimeInterval {
        if case .success(let claim) = item.claim { return claim.effectiveDuration }
        return item.episode.activeDuration
    }
}
