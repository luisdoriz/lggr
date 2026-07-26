import LggrKit
import SwiftUI

// Correcting a finished session's times.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE NUMBER HAS TO BE FIXABLE, AND THE FIX HAS TO BE HONEST
//
//  Everything on this sheet follows from one everyday failure: "I forgot to press stop and it
//  recorded four hours." A wrong number that cannot be corrected does not merely misreport one
//  session — it teaches the user not to believe the weekly review at all. So:
//
//    • **Two pickers and one derived line.** The resulting active duration is shown live, under the
//      controls that change it, so the user is reading the answer rather than doing the subtraction.
//    • **An invalid edit cannot be saved, and says why.** The reason is one plain sentence in
//      `.secondary` — never red, never an alert, never phrased as if the user did something wrong.
//      The pickers are left unconstrained on purpose: a control that silently refuses to move is a
//      control with no explanation attached to it.
//    • **Shrinking a session below its recorded pauses changes real data, so the sheet says so
//      before it happens** (design decision B). Inline, above the buttons, in the same quiet voice —
//      not an alert. `SessionRescheduleResult` computes it, so the sentence the user reads and the
//      mutation that is applied come from one piece of arithmetic rather than two.
//    • **Saving marks the session as corrected by hand** (design decision A), and the sheet says
//      that too. A hand-entered number is never presented as an observed one.
//
//  The sheet touches no store and does no pause arithmetic of its own: it hands two dates to
//  `onSave` and the host writes them through `SessionManager.reschedule(session:start:end:)`.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Corrects the recorded start and end of a session that has already finished.
///
/// Renders from plain values, so it photographs against `PreviewFixtures` with no store and no clock:
///
/// ```swift
/// SessionEditSheet(
///     session: PreviewFixtures.finishedSessions[0],
///     now: PreviewFixtures.now,
///     onSave: { _, _ in }
/// )
/// ```
public struct SessionEditSheet: View {

    /// `⌘⏎`, the contextual "confirm" of `04-screens.md` § 7.2, the same combination every other
    /// panel in Lggr saves with. `Esc` arrives through `.cancelAction` on Cancel.
    static let saveShortcut = KeyboardShortcut(.return, modifiers: .command)

    private let session: FocusSession
    private let project: Project?
    private let now: Date
    private let onSave: (Date, Date) -> Void
    private let onCancel: () -> Void

    @State private var start: Date
    @State private var end: Date

    /// - Parameters:
    ///   - session: The finished session being corrected.
    ///   - project: Already resolved by the caller — a view never looks a project up for itself.
    ///   - now: The present, injected. It is what makes "that end is in the future" a testable
    ///     statement rather than one that depends on when the suite runs.
    ///   - draftEnd: the end the sheet opens on. `nil` — always, in the app — opens on the recorded
    ///     end. Set by the headless snapshot renderer, which has to photograph the sheet *after* a
    ///     picker has moved, because until one has it has nothing to say. The same seam
    ///     `InterruptionCaptureSheet.draft` is, for the same reason.
    ///   - onSave: The corrected start and end, in that order. The host applies them through
    ///     `SessionManager`, which is where `editedAt` is stamped and the pauses are refitted.
    public init(
        session: FocusSession,
        project: Project? = nil,
        now: Date,
        draftEnd: Date? = nil,
        onSave: @escaping (Date, Date) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.session = session
        self.project = project
        self.now = now
        self.onSave = onSave
        self.onCancel = onCancel
        _start = State(initialValue: session.startedAt)
        // `wallClockInterval`'s clamp, applied to the seed: a record whose end somehow precedes its
        // start opens on a zero-length span rather than on an inverted one the user has to untangle.
        _end = State(
            initialValue: max(
                session.startedAt,
                draftEnd ?? session.endedAt ?? session.startedAt
            )
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            headline
            pickers
            resultingDuration
            notices
            buttons
        }
        .padding(Space.xl)
        .frame(width: Layout.sessionEditWidth)
        .background(Surface.canvas)
        .lggrAnimation(Motion.settle, value: noticeKey)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Correct the times")
    }

    // MARK: - Headline

    private var headline: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Correct the times")
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)

            // What is being corrected, so the sheet cannot be answered for the wrong session. It is
            // the second most important text here and it wraps rather than truncating.
            HStack(spacing: Space.xs) {
                ProjectBadge(project: project, variant: .compact)
                Text(verbatim: "·")
                    .font(Type.secondary)
                    .foregroundStyle(.tertiary)
                Text(session.intendedOutcome)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Session")
            .accessibilityValue(session.intendedOutcome)
        }
    }

    // MARK: - The two pickers

    /// Date *and* time on both rows. A forgotten stop time is very often a session that ran past
    /// midnight, and a time-only picker would make the commonest correction in the app impossible.
    ///
    /// `.stepperField`, because the everyday edit is "that should have been 10:40, not 14:12" and the
    /// steppers are what make nudging one component of it quick. A `DatePicker` of any style comes back
    /// as the yellow placeholder in a snapshot — see `ScrollingSection`, which lists what the camera
    /// cannot see and why none of it is swapped out to photograph better.
    private var pickers: some View {
        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: Space.l) {
            GridRow(alignment: .firstTextBaseline) {
                label("Started")
                    .gridColumnAlignment(.trailing)
                DatePicker(
                    "Started",
                    selection: $start,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .font(Type.body)
                .accessibilityLabel("Started")
            }

            GridRow(alignment: .firstTextBaseline) {
                label("Ended")
                DatePicker(
                    "Ended",
                    selection: $end,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .font(Type.body)
                .accessibilityLabel("Ended")
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(Type.body)
            .foregroundStyle(.secondary)
    }

    // MARK: - The answer

    /// The active duration these two dates produce, live, in the same shape the detail screen states
    /// it. This is the number the user came to fix, so it is the largest thing on the sheet after the
    /// title — and it is derived, never typed.
    @ViewBuilder private var resultingDuration: some View {
        if let preview {
            HStack(alignment: .top, spacing: Space.xl) {
                fact("Active", DurationFormatting.compact(preview.effectiveDuration))
                // A pause of under a minute is a rounding artefact of two pickers, not a fact worth a
                // column of its own.
                if preview.pausedDuration >= 60 {
                    fact("Paused", DurationFormatting.compact(preview.pausedDuration))
                }
            }
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Text(value)
                .font(Type.metricValue)
                .foregroundStyle(.primary)
                .lggrAnimation(Motion.none, value: value)
            Text(label)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }

    // MARK: - What the user needs to know before saving

    /// Every sentence this sheet can print, in one column, all in the same quiet voice.
    ///
    /// Order matters: what blocks the save comes first, what the save will cost comes second, and what
    /// the save will record about itself comes last.
    @ViewBuilder private var notices: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let blocker = blockingReason {
                notice(blocker)
            }
            if let cost = pausedTimeNotice {
                notice(cost)
            }
            if isDirty, blockingReason == nil {
                notice(
                    "Saving marks this session as corrected by hand, so your weekly review can tell a time you entered from one Lggr observed."
                )
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(Type.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Why the times cannot be saved yet, or `nil` when they can.
    ///
    /// Each sentence names the state and the move that fixes it. None of them names the user.
    private var blockingReason: String? {
        guard preview != nil else {
            return "Only a session that has finished can have its times corrected."
        }
        if end < start {
            return "The end is before the start. Move the end later than the start and this can be saved."
        }
        if end > now {
            return "That end is in the future. Lggr records time that has already passed, so the end can be now at the latest."
        }
        return nil
    }

    /// Design decision B, as a sentence: shrinking a session below its recorded pauses reduces real
    /// data, and the user reads that before it happens rather than discovering it afterwards.
    ///
    /// Absent while something is already blocking the save — one thing to fix at a time — and absent
    /// when the pauses still fit, which is the ordinary case.
    private var pausedTimeNotice: String? {
        guard blockingReason == nil, let preview, preview.reducesPausedDuration else { return nil }
        let recorded = DurationFormatting.compact(preview.previousPausedDuration)
        let kept = DurationFormatting.compact(preview.pausedDuration)
        let active = DurationFormatting.compact(preview.effectiveDuration)
        return "This session recorded \(recorded) paused, and these times only have room for \(kept). "
            + "Saving shortens the paused time to fit, and the session will report \(active) of focus."
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack(spacing: Space.m) {
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: Space.m)
            Button("Save", action: save)
                .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                .keyboardShortcut(Self.saveShortcut)
                .disabled(!canSave)
                .help("Save the corrected times")
        }
    }

    // MARK: - Derived

    /// What the domain says this edit would do, recomputed as the pickers move.
    ///
    /// Pure arithmetic over the session's own dates, so calling it from `body` costs nothing — and it
    /// is the *same* function the mutation runs, which is what stops the warning and the write from
    /// disagreeing about how much pause a span can hold.
    private var preview: SessionRescheduleResult? {
        session.rescheduleResult(start: start, end: end)
    }

    /// The times differ from the record. An edit that changes nothing still stamps `editedAt`, so the
    /// button is disabled rather than letting a stray `⌘⏎` label an untouched session as hand-entered.
    private var isDirty: Bool {
        start != session.startedAt || end != session.endedAt
    }

    private var canSave: Bool { isDirty && blockingReason == nil }

    /// Drives the one animation on this sheet: which sentences are showing. Animating on the strings
    /// themselves would re-run the transition on every keystroke inside a duration.
    private var noticeKey: String {
        [blockingReason == nil ? "ok" : "blocked", pausedTimeNotice == nil ? "fits" : "shrinks"]
            .joined(separator: "-")
    }

    private func save() {
        guard canSave else { return }
        onSave(start, end)
    }
}
