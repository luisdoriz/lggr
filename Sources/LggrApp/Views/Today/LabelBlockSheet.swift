import LggrKit
import SwiftUI

// Turning a block into a session, in one gesture. See docs/_design/INTELLIGENCE.md §4 Phase 2.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE WHOLE VALUE IS THAT IT COSTS ALMOST NOTHING
//
//  Lggr has already measured this stretch of time. The only thing missing is a sentence, so the only
//  thing this sheet asks for is a sentence — and it opens with the caret already in it, the project
//  and the work type already carrying the app's best reading, and ⌘⏎ ready. If labelling a block
//  ever takes longer than the block was worth, the feature has failed regardless of what it renders.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// Four decisions this file holds:
//
//   * **"This was…", past tense.** The start panel asks *"What are you working on?"* because it is
//     collecting an intent. This is collecting a description of time already spent, and a sheet that
//     borrowed the other question would be asking about the wrong tense of the same fact.
//   * **The measured time range is shown and is not editable here.** Correcting times is what
//     `SessionEditSheet` already does, and offering two ways to change one thing in one sheet is how
//     a form becomes confusing. The range is displayed as evidence — the reason the user can trust
//     the record they are about to label — with one quiet line saying where times get corrected.
//   * **What the save will record about itself is stated before it happens.** The session lands as
//     reactive and as labelled-afterwards, and both of those change how the weekly review reads. A
//     provenance the user is not told about is a provenance they cannot agree to. Same voice, same
//     position and same reasoning as `SessionEditSheet`'s "corrected by hand" notice.
//   * **A refusal is a sentence, not a disabled button.** A block the record already accounts for
//     opens this sheet and says so, with a way through to the session that accounts for it. A row
//     that silently does nothing is indistinguishable from one that is broken.
//
// The sheet touches no store and does no arithmetic of its own: `SessionFromEpisode` computed the
// claim before this opened, and `onSave` hands back the three fields the user supplied.

/// "This was…" — labels a block Lggr reconstructed, making it a real session.
///
/// Renders from plain values, so it photographs against `PreviewFixtures` with no store and no clock.
@MainActor
public struct LabelBlockSheet: View {

    /// `⌘⏎`, the contextual confirm of `04-screens.md` §7.2 — the same combination the start panel,
    /// the review sheet and `SessionEditSheet` all save with. `Esc` arrives through `.cancelAction`.
    static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    private let episode: Episode
    private let outcome: Result<SessionFromEpisode.Claim, SessionFromEpisode.Refusal>
    private let projects: [Project]
    private let recentOutcomes: [String]
    private let onSave: (SessionFromEpisode.Label) -> Void
    private let onCorrectTimes: (() -> Void)?
    private let onCancel: () -> Void

    @State private var text: String
    @State private var projectID: UUID?
    @State private var workType: WorkType
    @State private var showsEmptyHint = false

    /// Reuses the start panel's focus vocabulary rather than inventing a second one, because it
    /// reuses the start panel's `OutcomeField` — which is what gives this sheet the same `Recent`
    /// list, the same `↓`/`↑` browsing and the same two-stage `Escape` without a line of new keyboard
    /// code. Only `.outcome` is reachable here; there is no duration on this sheet.
    @FocusState private var focus: StartPanelField?

    /// - Parameters:
    ///   - episode: the block being labelled.
    ///   - outcome: what `SessionFromEpisode.claim(for:existingSessions:)` answered. Passed in rather
    ///     than computed here so the sheet, the row that opened it and the record that gets saved are
    ///     all reasoning about one piece of arithmetic.
    ///   - suggestedProjectID: pre-filled from a rule **the user wrote** that assigns a project to
    ///     one of these applications, and `nil` otherwise. Deliberately not the last project used:
    ///     `INTELLIGENCE.md` §3.8 refuses project inference until there is evidence to infer from,
    ///     and a plausible wrong project on a record of the past is worse than no project at all.
    ///   - suggestedWorkType: from the category the rules give this block's dominant application.
    ///   - recentOutcomes: the same list the start panel offers. Labelling a block is very often
    ///     labelling more of something already named today.
    ///   - onCorrectTimes: opens `SessionEditSheet` for the session that already accounts for this
    ///     block. Absent when the host cannot resolve one, in which case the sheet says the fact and
    ///     offers no button — never a control that cannot act.
    public init(
        episode: Episode,
        outcome: Result<SessionFromEpisode.Claim, SessionFromEpisode.Refusal>,
        projects: [Project] = [],
        suggestedProjectID: UUID? = nil,
        suggestedWorkType: WorkType = .deepWork,
        recentOutcomes: [String] = [],
        draftOutcome: String? = nil,
        onSave: @escaping (SessionFromEpisode.Label) -> Void,
        onCorrectTimes: (() -> Void)? = nil,
        onCancel: @escaping () -> Void = {}
    ) {
        self.episode = episode
        self.outcome = outcome
        self.projects = projects
        self.recentOutcomes = recentOutcomes
        self.onSave = onSave
        self.onCorrectTimes = onCorrectTimes
        self.onCancel = onCancel
        _text = State(initialValue: draftOutcome ?? "")
        _projectID = State(initialValue: suggestedProjectID)
        _workType = State(initialValue: suggestedWorkType)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            headline
            evidence

            switch outcome {
            case .success(let claim):
                form(claim)
            case .failure(let refusal):
                refusalNotice(refusal)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.startPanelSheetWidth, alignment: .leading)
        .background(Surface.canvas)
        .defaultFocus($focus, StartPanelField.outcome)
        .onExitCommand(perform: onCancel)
        .onChange(of: text) { _, _ in showsEmptyHint = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Label this block")
    }

    // MARK: - Headline

    /// Past tense, and it is the whole question. The block's own name sits under it as the app's
    /// reading of the same stretch — quoted rather than pre-filled into the field, because a name
    /// assembled from a roster of applications is not a sentence anybody would write, and dropping it
    /// into the field would make the user delete it before they could type.
    private var headline: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("This was…")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            Text(episode.label)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This was")
        .accessibilityValue(episode.label)
    }

    // MARK: - The measured time

    /// The range and the duration, side by side, as facts — and one line saying they are not typed
    /// here.
    ///
    /// This is the evidence the label is being attached to, so it is the largest thing on the sheet
    /// after the title. The duration is the time actually measured in an application, never the
    /// wall-clock span, which would quietly count idle minutes the timeline has already broken out.
    private var evidence: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.xl) {
                fact("Measured", TimelineClock.range(from: claimedRange.start, to: claimedRange.end))
                fact("Time", DurationFormatting.compact(claimedDuration))
            }

            // Said once, plainly, and only where it is true. The alternative — a disabled picker — is
            // a control that refuses to move with no explanation attached to it.
            Text(timesNote)
                .font(Type.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

    /// What the range means, and where it is changed. Two sentences at most: the trim, when there is
    /// one, and then the pointer to the sheet that owns times.
    private var timesNote: String {
        var sentences: [String] = []
        if case .success(let claim) = outcome,
            let note = claim.trimNote(
                overlapText: DurationFormatting.compact(claim.overlapRemoved),
                claimedRangeText: TimelineClock.range(
                    from: claim.claimed.start,
                    to: claim.claimed.end
                )
            )
        {
            sentences.append(note)
        }
        sentences.append(
            "Lggr measured these times, so they are not typed here. "
                + "Correct times… on the session changes them afterwards."
        )
        return sentences.joined(separator: " ")
    }

    // MARK: - The form

    /// One field and two menus, in the order the eye should hit them — the same order and the same
    /// controls as the start panel, because it is the same three facts about a session.
    @ViewBuilder private func form(_ claim: SessionFromEpisode.Claim) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            OutcomeField(
                text: $text,
                recentOutcomes: recentOutcomes,
                focus: $focus,
                showsEmptyHint: showsEmptyHint,
                onSubmit: attemptSave,
                onCancel: onCancel
            )

            HStack(spacing: Space.s) {
                // No `New Project…`: this sheet is opened from a timeline row and from the menu bar,
                // and neither host can present the project editor over it. A menu item that cannot
                // act is worse than one that is not offered.
                ProjectPicker(projects: projects, selection: $projectID)
                Spacer(minLength: Space.s)
                WorkTypePicker(selection: $workType)
            }

            provenanceNotice

            buttons(claim)
        }
    }

    /// What saving records about itself, in the quiet voice `SessionEditSheet` uses for the same kind
    /// of statement.
    ///
    /// Both halves change how the week reads, so both are said. Neither is an apology and neither is
    /// a warning: a reactive hour is an hour, and a label applied afterwards is still the user's own
    /// sentence about their own work.
    private var provenanceNotice: some View {
        Text(
            "Saving records this as labelled afterwards and as reactive time, so your weekly review "
                + "can tell work you planned from work you recognised later. The measured times do "
                + "not change."
        )
        .font(Type.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(_ claim: SessionFromEpisode.Claim) -> some View {
        HStack(spacing: Space.m) {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)

            Spacer(minLength: Space.m)

            // Deliberately *not* `.disabled()`, for the reason the start panel's Start Focus is not:
            // a disabled button swallows its own shortcut, and ⌘⏎ on an empty field has to return
            // focus to the field and say why. The reduced opacity is the "not ready" signal.
            Button("Save Session", action: attemptSave)
                .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                .keyboardShortcut(Self.saveShortcut)
                .opacity(label.isComplete ? 1 : 0.55)
                .lggrAnimation(Motion.settle, value: label.isComplete)
                .help("Save this block as a session")
                .accessibilityHint(label.isComplete ? "" : "Add what this was to save it.")
        }
    }

    // MARK: - A block that cannot be labelled

    /// The refusal, as a sentence and a way out.
    ///
    /// `SessionFromEpisode.Refusal` owns the wording — every case of it is a fact about the record
    /// with no subject — and the second line says what to do instead, which is different for the two
    /// kinds: a block already inside a session is corrected on that session, and a block with no
    /// measured time is nothing at all.
    private func refusalNotice(_ refusal: SessionFromEpisode.Refusal) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(refusal.sentence)
                .font(Type.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.m) {
                if refusal.isCoveredByASession, let onCorrectTimes {
                    Button("Correct times…", action: onCorrectTimes)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Spacer(minLength: Space.m)
                Button("Close", action: onCancel)
                    .buttonStyle(.lggrPrimary)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    // MARK: - Derived

    private var label: SessionFromEpisode.Label {
        SessionFromEpisode.Label(
            intendedOutcome: text,
            projectID: projectID,
            workType: workType
        )
    }

    /// The span the session would claim, which is the block's own span unless a session already
    /// covers part of it. On a refusal it is the block's measured span — the sheet is still stating a
    /// fact about the record, it just cannot label it.
    private var claimedRange: DateInterval {
        if case .success(let claim) = outcome { return claim.claimed }
        return DateInterval(start: episode.start, end: max(episode.start, episode.end))
    }

    /// Measured application time inside the claimed span. Idle is excluded — it is what the session
    /// will record as paused rather than as focus.
    private var claimedDuration: TimeInterval {
        if case .success(let claim) = outcome { return claim.effectiveDuration }
        return episode.activeDuration
    }

    private func attemptSave() {
        guard case .success = outcome else { return }
        guard label.isComplete else {
            showsEmptyHint = true
            focus = .outcome
            return
        }
        onSave(label)
    }
}
