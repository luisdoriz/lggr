import LggrKit
import SwiftUI

// One session, in full. Pushed from Focus Sessions. See docs/_design/04-screens.md § 4.2.
//
// § 4.2: *"the outcome as a title, the session's stats grid, the summary (editable in place), blocker
// and next step if present, the session's own timeline strip, its interruptions, and its
// accomplishments."* That is the order below, and everything in it is something the session actually
// recorded.
//
// Three rules this file holds:
//
//   * **Absent, never zeroed.** A section with nothing in it is not rendered. There is no "0
//     interruptions", no empty timeline strip and no "—" where a number would go: a number the app
//     cannot state is not a placeholder, it is a false claim about the user's day. The one exception is
//     the summary, which is an editable field and therefore has to exist before it has content.
//   * **An unreviewed session is offered, not flagged.** It gets a plain block that says what is
//     missing and one button that fixes it. No orange, no warning triangle, no "incomplete".
//   * **Editing is in place and explicit.** The four text fields write into a draft; `Save` appears
//     only once the draft differs from the record. Nothing is written as you type, and nothing is
//     lost by navigating away without pressing it — the record is unchanged, which is the honest
//     outcome of not having saved.
//
// The whole screen renders from plain values, so it photographs against `PreviewFixtures` with no
// store, no activity log and no clock.

/// What the detail screen can do.
public struct SessionDetailActions {
    public var back: () -> Void
    /// Offered only for a session with no result. `nil` removes the control rather than disabling it.
    public var review: (() -> Void)?
    /// Persists an edited session. `nil` makes the four fields read-only, which is the honest
    /// rendering when the host cannot save.
    public var save: ((FocusSession) -> Void)?
    /// Opens `SessionEditSheet` to correct the recorded times. Separate from `save` because the four
    /// fields are the user's words about work already done, while this changes the measurement itself —
    /// which is why it goes through a sheet that can warn before it writes.
    public var editTimes: (() -> Void)?
    public var addAccomplishment: () -> Void
    public var editAccomplishment: (Accomplishment) -> Void

    public init(
        back: @escaping () -> Void = {},
        review: (() -> Void)? = nil,
        save: ((FocusSession) -> Void)? = nil,
        editTimes: (() -> Void)? = nil,
        addAccomplishment: @escaping () -> Void = {},
        editAccomplishment: @escaping (Accomplishment) -> Void = { _ in }
    ) {
        self.back = back
        self.review = review
        self.save = save
        self.editTimes = editTimes
        self.addAccomplishment = addAccomplishment
        self.editAccomplishment = editAccomplishment
    }
}

/// One session, in full.
public struct SessionDetailView: View {

    /// `⌘S` — the one shortcut this screen adds. It is not in § 7.1's map because § 7.1 predates an
    /// editable record; it is the key every Mac user's hands already reach for, and it is claimed by
    /// nothing else in Lggr.
    static let saveShortcut = KeyboardShortcut("s", modifiers: .command)

    private let session: FocusSession
    private let project: Project?
    private let episodes: [Episode]
    private let interruptions: [Interruption]
    private let accomplishments: [Accomplishment]
    private let projects: [Project]
    private let actions: SessionDetailActions

    /// The four editable fields, held as a draft rather than written through. See `Draft`.
    @State private var draft: Draft
    /// The record the draft was seeded from, so "has anything changed" is a comparison rather than a
    /// flag somebody has to remember to set.
    @State private var seed: Draft

    public init(
        session: FocusSession,
        project: Project? = nil,
        episodes: [Episode] = [],
        interruptions: [Interruption] = [],
        accomplishments: [Accomplishment] = [],
        projects: [Project] = [],
        actions: SessionDetailActions = SessionDetailActions()
    ) {
        self.session = session
        self.project = project
        self.episodes = episodes
        self.interruptions = interruptions
        self.accomplishments = accomplishments
        self.projects = projects
        self.actions = actions
        let draft = Draft(session)
        self._draft = State(initialValue: draft)
        self._seed = State(initialValue: draft)
    }

    public var body: some View {
        ScrollingSection {
            VStack(alignment: .leading, spacing: Space.xxl) {
                header
                resultBlock
                facts
                fields
                timelineSection
                interruptionsSection
                accomplishmentsSection

                // Absorbs any slack, so a screen taller than its content does not hand the extra
                // height to the timeline rail — which asks for `maxHeight: .infinity` in order to
                // match its own row and will happily take a thousand points of it.
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, Space.xl)
            .padding(.bottom, Space.hero)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Surface.canvas)
        // A pushed view is re-seeded when the record underneath it changes — a review filed from the
        // sheet, say — but never while the user has unsaved edits, because dropping typing on the
        // floor to accept a value from elsewhere is the one behaviour a text field must not have.
        .onChange(of: session) { _, updated in
            let refreshed = Draft(updated)
            guard draft == seed else {
                seed = refreshed
                return
            }
            draft = refreshed
            seed = refreshed
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session")
        .accessibilityValue(session.intendedOutcome)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Button(action: actions.back) {
                HStack(spacing: Space.xs) {
                    Image(systemName: Icon.previousWeek)
                        .imageScale(.small)
                    Text("Focus Sessions")
                }
                .font(Type.secondary)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Back to Focus Sessions")

            // The one string on this screen that never truncates: it is what the session was for.
            Text(session.intendedOutcome)
                .font(Type.screenTitle)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            metadata
            provenance
        }
    }

    /// Design decision A, in the one place there is room to say it in full: this session's times were
    /// entered by hand, and here is when.
    ///
    /// A plain caption in `.secondary` with the ordinary pencil — never a warning colour, never a
    /// triangle, and never phrased as if a correction were a mistake. The weekly review is only
    /// trustworthy if a number the user typed is distinguishable from one Lggr watched, and this is
    /// that distinction being kept rather than being hidden.
    @ViewBuilder private var provenance: some View {
        // Three facts, three lines, and one session can carry all of them: a block was labelled, the
        // app closed it, and the user then corrected that. They are drawn oldest-first, which is also
        // the order they happened in — reconstruction is how the record came to exist at all, the
        // automatic close is the app's own arithmetic on it, and a hand correction is the last word.
        if let reconstructedAt = session.reconstructedAt {
            provenanceLine(
                ReconstructedMark.help(reconstructedAt),
                symbol: Icon.labelBlock,
                spoken: ReconstructedMark.help(reconstructedAt)
            )
        }
        // The line the app owes the user: this end was not observed running out and nobody pressed
        // it, and here is the witness it came from. Stated on the record rather than only in the
        // notification that announced it — that notification is off on a fresh install, so without
        // this the number would simply have changed with nothing saying why.
        if let autoClosedAt = session.autoClosedAt {
            let sentence = AutoClosedMark.help(autoClosedAt, reason: session.autoCloseReason)
            provenanceLine(
                sentence,
                symbol: session.autoCloseReason?.symbolName ?? Icon.autoClosed,
                spoken: sentence
            )
        }
        if let editedAt = session.editedAt {
            provenanceLine(
                "Times corrected by hand on "
                    + editedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)),
                symbol: Icon.edit,
                spoken: EditedMark.help(editedAt)
            )
        }
    }

    private func provenanceLine(
        _ text: String,
        symbol: String,
        spoken: String
    ) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .font(Type.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Provenance")
            .accessibilityValue(spoken)
    }

    /// `● Receipt ingestion · Deep work · Monday 15 January · 9:00–9:50 · Planned`
    private var metadata: some View {
        HStack(spacing: Space.xs) {
            ProjectBadge(project: project)
            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
            Text(metadataText)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(project?.normalizedName ?? "No project")
        .accessibilityValue(metadataText)
    }

    private var metadataText: String {
        var parts = [session.workType.displayName]
        parts.append(session.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        if let range = timeRange { parts.append(range) }
        // The distinction the weekly review is built on, stated as a plain word rather than a badge.
        // Neither value is better than the other and neither is coloured.
        parts.append(session.isReactive ? "Reactive" : "Planned")
        return parts.joined(separator: " · ")
    }

    private var timeRange: String? {
        guard let endedAt = session.endedAt else { return nil }
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        let end = endedAt.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    // MARK: - Result

    /// The answer to "What happened?", or the way to give one.
    ///
    /// The unreviewed case is a `Card` because it is the one container on this screen with its own
    /// primary action — the rule `Card`'s own documentation sets. It is not a warning: the sentence is
    /// about the record, and the button is the whole remedy.
    @ViewBuilder private var resultBlock: some View {
        if let status = session.resultStatus {
            HStack(spacing: Space.s) {
                Image(systemName: status.symbolName)
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(status.displayName)
                    .font(Type.outcome)
                    .foregroundStyle(.primary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Result")
            .accessibilityValue(status.displayName)
        } else if let review = actions.review {
            Card {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("This session has no result yet.")
                        .font(Type.rowTitle)
                        .foregroundStyle(.primary)
                    Text("Answer what happened and it joins your log. Nothing about the session has been lost in the meantime.")
                        .font(Type.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Review", action: review)
                        .buttonStyle(.lggrPrimary)
                }
            }
        } else {
            Text("No result recorded.")
                .font(Type.body)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Facts

    /// What the session measured. Every one of these is arithmetic over the session's own stored
    /// dates, and each is omitted when there is nothing to say — a pause that never happened does not
    /// get a "0m paused" the eye has to skip.
    ///
    /// There is no focused/idle split and no context-switch count here: both come from the activity
    /// record, and the timeline section below is where that evidence belongs.
    @ViewBuilder private var facts: some View {
        let items = factItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                // The numbers and the way to correct them, together. A user who has just read "4h 12m"
                // and knows it is wrong should not have to go back to the list to fix it.
                if let editTimes = actions.editTimes {
                    SectionHeader("Session", actionTitle: "Correct times…", action: editTimes)
                } else {
                    SectionHeader("Session")
                }
                HStack(alignment: .top, spacing: Space.xl) {
                    ForEach(items, id: \.label) { item in
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(item.value)
                                .font(Type.metricValue)
                                .foregroundStyle(.primary)
                            Text(item.label)
                                .font(Type.secondary)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(item.label)
                        .accessibilityValue(item.value)
                    }
                }
            }
        }
    }

    private var factItems: [(label: String, value: String)] {
        var items: [(label: String, value: String)] = []
        let reference = session.endedAt ?? session.startedAt

        if let duration = session.effectiveDuration {
            items.append((label: "Active", value: DurationFormatting.compact(duration)))
        }
        let paused = session.totalPausedDuration(at: reference)
        if paused >= 60 {
            items.append((label: "Paused", value: DurationFormatting.compact(paused)))
        }
        if let planned = session.plannedDuration {
            items.append((label: "Planned", value: DurationFormatting.compact(planned)))
        } else {
            items.append((label: "Planned", value: "Open-ended"))
        }
        if session.interruptionCount > 0 {
            // Singular when there was one. The snapshot read "1 Interruptions", which is the sort of
            // thing that makes a screen feel generated rather than written.
            items.append(
                (
                    label: session.interruptionCount == 1 ? "Interruption" : "Interruptions",
                    value: "\(session.interruptionCount)"
                )
            )
        }
        return items
    }

    // MARK: - The four fields

    /// Summary, tangible result, blocker and next step — the four things a session records in the
    /// user's own words, editable where they are read.
    ///
    /// This is the only editor in Lggr for `tangibleResult`: the review sheet folds it into the summary
    /// sentence rather than storing it, so without this the field would be a column nothing could ever
    /// write. Editing here is what makes it real.
    private var fields: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            SectionHeader("In your words") {
                if isDirty, actions.save != nil {
                    Button("Save", action: save)
                        .buttonStyle(.lggrPrimary(shortcut: Self.saveShortcut))
                        .keyboardShortcut(Self.saveShortcut)
                }
            }

            field(
                "Summary",
                prompt: "What happened during this session?",
                text: $draft.summary,
                lines: 2...8
            )
            field(
                "Tangible result",
                prompt: "What exists now that didn't before?",
                text: $draft.tangibleResult,
                lines: 1...4
            )
            field(
                "Blocker",
                prompt: "What's in the way?",
                text: $draft.blocker,
                lines: 1...4
            )
            field(
                "Next step",
                prompt: "What's the next concrete step?",
                text: $draft.nextStep,
                lines: 1...4
            )

            if isDirty, actions.save == nil {
                Text("Editing needs a writable store, and this one is read-only.")
                    .font(Type.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The same field shape as the review sheet's, so the two never look like different applications.
    private func field(
        _ label: String,
        prompt: String,
        text: Binding<String>,
        lines: ClosedRange<Int>
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(label)
                .font(Type.caption)
                .foregroundStyle(.secondary)

            TextField(label, text: text, prompt: Text(prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .labelsHidden()
                .font(Type.body)
                .lineLimit(lines)
                .padding(Space.s)
                .background(Surface.sunken, in: Theme.chipShape)
                .overlay(Theme.chipShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
                .disabled(actions.save == nil)
                .accessibilityLabel(label)
        }
    }

    // MARK: - The reconstructed span

    /// What ambient capture recorded across this session's span, as the same rows Today draws.
    ///
    /// Absent when capture has nothing for it, which is the ordinary case for any session older than
    /// the sampler. An empty strip under a heading would read as "Lggr watched and found nothing",
    /// which is a claim about the record that is almost always false.
    @ViewBuilder private var timelineSection: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("What was in front of you", count: episodes.count)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode)
                    }
                }
                Text("Lggr sees one frontmost application at a time, so a second display or another browser tab is not in this.")
                    .font(Type.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            }
        }
    }

    // MARK: - Interruptions

    /// The notes the user wrote down mid-session instead of acting on them.
    @ViewBuilder private var interruptionsSection: some View {
        if !interruptions.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader("Captured during this session", count: interruptions.count)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(interruptions) { interruption in
                        InterruptionNoteRow(interruption: interruption)
                    }
                }
            }
        }
    }

    // MARK: - Accomplishments

    /// What this session put into the log. Always present, because logging one is a real action the
    /// user may want to take from here — and the section header is where its button belongs.
    private var accomplishmentsSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(
                "Delivered",
                count: accomplishments.isEmpty ? nil : accomplishments.count,
                actionTitle: "Add",
                action: actions.addAccomplishment
            )

            if accomplishments.isEmpty {
                Text("Nothing logged from this session.")
                    .font(Type.body)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(accomplishments) { accomplishment in
                        AccomplishmentRow(
                            accomplishment: accomplishment,
                            project: projects.first { $0.id == accomplishment.projectID },
                            onEdit: { actions.editAccomplishment(accomplishment) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Saving

    private var isDirty: Bool { draft != seed }

    private func save() {
        guard let handler = actions.save, isDirty else { return }
        var updated = session
        updated.resultSummary = draft.summary.trimmedOrNil
        updated.tangibleResult = draft.tangibleResult.trimmedOrNil
        updated.blocker = draft.blocker.trimmedOrNil
        updated.nextStep = draft.nextStep.trimmedOrNil
        seed = draft
        handler(updated)
    }

    // MARK: - Draft

    /// The four editable fields as plain strings.
    ///
    /// Strings rather than optionals so the text fields bind directly, and a separate type rather than
    /// four `@State`s so "is anything unsaved" is one `==` instead of four comparisons somebody has to
    /// remember to keep in step.
    struct Draft: Equatable {
        var summary: String
        var tangibleResult: String
        var blocker: String
        var nextStep: String

        init(_ session: FocusSession) {
            self.summary = session.resultSummary ?? ""
            self.tangibleResult = session.tangibleResult ?? ""
            self.blocker = session.blocker ?? ""
            self.nextStep = session.nextStep ?? ""
        }
    }
}

// MARK: - An interruption, as a note

/// One captured interruption, read back. See `04-screens.md` § 5.4.
///
/// The source glyph is `.secondary` and never tinted: seven tinted glyphs is a rainbow, and colour in
/// Lggr means "which project" or it means nothing. The status is printed only when it is no longer in
/// the inbox, because "Inbox" is the default and a row that says so is a row saying nothing.
struct InterruptionNoteRow: View {

    let interruption: Interruption

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: interruption.source.symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(interruption.normalizedDescription ?? "Untitled note")
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(metadataText)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Space.m)
        }
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(interruption.normalizedDescription ?? "Untitled note")
        .accessibilityValue(metadataText)
    }

    private var metadataText: String {
        var parts = [interruption.source.displayName]
        parts.append(interruption.timestamp.formatted(date: .omitted, time: .shortened))
        if !interruption.isPending {
            parts.append(interruption.status.displayName)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Text

extension String {
    /// Trimmed, or `nil` when only whitespace was typed. An empty optional field and a field holding
    /// three spaces must not be two different records.
    fileprivate var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
