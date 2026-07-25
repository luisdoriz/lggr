import LggrKit
import SwiftUI

// One weekly outcome, with what it actually received. See docs/_design/SPEC.md § 8 and
// docs/_design/04-screens.md § 4.4.
//
// Despite the file name this is **not** a `Card`. A card in Lggr means "this container has its own
// primary action", and there are exactly two of them in the application (see `Card`). An outcome is a
// headed block on the bare canvas, and the three emphases below differ by type size and by how much
// evidence they carry — not by chrome.
//
// The two numbers on an outcome are reported side by side and never reconciled:
//
//   * **Progress** is the user's own figure. Lggr does not infer it, adjust it, or check it.
//   * **Tracked time** is Lggr's figure. Time spent is not progress made, and a rule that turned one
//     into the other would invent the one thing the user is best placed to know.
//
// There is no score here, no grade, no comparison with last week and no target. `INTELLIGENCE.md`
// § 3.4 removed every headline number that behaved like one, and an outcome is where the temptation
// is strongest.

/// One outcome: its title, the status the user set, and the evidence of what it received.
///
/// Takes plain values, so it renders in full from a fixture with no store and no clock. Every action
/// is optional and the affordance is absent when the handler is — a menu item that cannot do anything
/// is worse than one that is not offered.
@MainActor
public struct OutcomeCard: View {

    /// How much room the outcome gets, which follows its seat in the week.
    ///
    /// Three levels rather than a size parameter: the primary outcome is the one thing the week was
    /// for and reads like it, a secondary outcome is a row, and an operational responsibility is a
    /// line. Making these separate cases is what stops a screen of six identical blocks — which is
    /// the task list `SPEC.md` § 8 asks us not to encourage.
    public enum Emphasis: Sendable {
        case primary
        case secondary
        case operational
    }

    private let outcome: WeeklyOutcome
    private let progress: WeeklyReview.OutcomeProgress?
    private let accomplishments: [Accomplishment]
    private let emphasis: Emphasis
    private let onEdit: (() -> Void)?
    private let onSetStatus: ((OutcomeStatus) -> Void)?
    private let onDelete: (() -> Void)?

    @State private var isHovered = false
    @State private var isConfirmingRemoval = false

    /// - Parameters:
    ///   - progress: what `WeeklyReviewBuilder` measured against this outcome. `nil` renders the
    ///     outcome with no figures rather than with zeros.
    ///   - accomplishments: the week's accomplishments filed under this outcome, used for the
    ///     "2 pull requests opened" part of the evidence line. Counted by `AccomplishmentPhrasing`,
    ///     the same helper the Markdown export uses.
    public init(
        outcome: WeeklyOutcome,
        progress: WeeklyReview.OutcomeProgress?,
        accomplishments: [Accomplishment] = [],
        emphasis: Emphasis,
        onEdit: (() -> Void)? = nil,
        onSetStatus: ((OutcomeStatus) -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.outcome = outcome
        self.progress = progress
        self.accomplishments = accomplishments
        self.emphasis = emphasis
        self.onEdit = onEdit
        self.onSetStatus = onSetStatus
        self.onDelete = onDelete
    }

    public var body: some View {
        content
            .padding(.vertical, emphasis == .primary ? Space.m : Space.s)
            .padding(.horizontal, Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
            .contentShape(Theme.cardShape)
            .padding(.horizontal, -Space.s)
            .onHover { isHovered = $0 }
            .lggrAnimation(Motion.tap, value: isHovered)
            .contextMenu { actionItems }
            .alert("Remove this outcome?", isPresented: $isConfirmingRemoval) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) { onDelete?() }
            } message: {
                Text(
                    "The sessions and accomplishments filed under it keep their history."
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(outcome.title)
            .accessibilityValue(spokenValue)
    }

    @ViewBuilder private var content: some View {
        switch emphasis {
        case .primary: primaryBody
        case .secondary: secondaryBody
        case .operational: operationalBody
        }
    }

    // MARK: - Primary

    private var primaryBody: some View {
        HStack(alignment: .top, spacing: Space.s) {
            statusGlyph

            VStack(alignment: .leading, spacing: Space.s) {
                // The outcome the week was for. It does not truncate, for the same reason the
                // intended outcome on Today does not: it is the user's own sentence.
                Text(outcome.title)
                    .font(Type.outcome)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if let details = outcome.details, !details.isEmpty {
                    Text(details)
                        .font(Type.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                progressBar
                    .padding(.top, Space.xxs)

                Text(evidenceText)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Space.m)

            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
    }

    /// Self-reported progress, and it says so on hover. The track is `.quaternary`, which § 2.4 allows
    /// for shapes and forbids for text; the fill is the user's system accent.
    private var progressBar: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * outcome.progress)
                }
            }
            .frame(height: Layout.progressCapsuleHeight)
            .clipShape(Theme.chipShape)
            .help("Progress you set yourself. Lggr never infers it from time.")
            .accessibilityHidden(true)

            Text(verbatim: "\(outcome.progressPercent)% · \(outcome.status.displayName)")
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
    }

    // MARK: - Secondary

    private var secondaryBody: some View {
        HStack(alignment: .top, spacing: Space.s) {
            statusGlyph

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(outcome.title)
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(secondaryMetadata)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer(minLength: Space.m)

            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
    }

    /// Status, the user's own percentage, and what the week actually filed against it. No bar: a
    /// second progress bar on the screen would make the primary outcome's one stop meaning anything.
    private var secondaryMetadata: String {
        var parts = [outcome.status.displayName, "\(outcome.progressPercent)%"]
        parts.append(contentsOf: trackedParts)
        return parts.joined(separator: " · ")
    }

    // MARK: - Operational

    /// One line. An operational responsibility is load the user carries, not an outcome they chose, so
    /// it gets no progress figure — a percentage on "on-call" would be a number about being available.
    private var operationalBody: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            statusGlyph

            Text(outcome.title)
                .font(Type.body)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Space.m)

            if let tracked = trackedText {
                Text(tracked)
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
    }

    // MARK: - Status

    /// The glyph comes from `OutcomeStatus.symbolName` in `LggrKit`, so "blocked" looks the same
    /// everywhere in the app.
    ///
    /// Colour: `.secondary` for every status except `blocked`, which is the one place `04-screens.md`
    /// § 2.4 permits `Palette.attention`. Nothing here is red, and a status is never a verdict — there
    /// is no "failed" in `OutcomeStatus` precisely because blocked, carried over and dropped are three
    /// different things.
    private var statusGlyph: some View {
        Image(systemName: outcome.status.symbolName)
            .imageScale(.medium)
            .foregroundStyle(
                outcome.status == .blocked
                    ? AnyShapeStyle(Palette.attention)
                    : AnyShapeStyle(.secondary)
            )
            .frame(width: Layout.symbolColumnWidth, alignment: .center)
            .accessibilityHidden(true)
    }

    // MARK: - Evidence

    /// "7 sessions · 8h 24m · 31% of tracked time · 2 pull requests opened".
    ///
    /// Every part is dropped when its number is zero, so a week that filed nothing against the
    /// outcome says so in one plain sentence instead of printing a row of noughts. Someone whose week
    /// went to an incident should read a fact here, not a shortfall.
    private var evidenceText: String {
        var parts = trackedParts
        if let share = progress?.shareOfTrackedTime, share > 0 {
            parts.append("\(Int((share * 100).rounded()))% of tracked time")
        }
        for (type, count) in AccomplishmentPhrasing.counts(accomplishments) {
            parts.append(AccomplishmentPhrasing.phrase(type, count: count))
        }
        guard !parts.isEmpty else { return "No sessions filed against this outcome." }
        return parts.joined(separator: " · ")
    }

    private var trackedParts: [String] {
        guard let progress else { return [] }
        var parts: [String] = []
        if progress.sessionCount > 0 {
            parts.append("\(progress.sessionCount) \(progress.sessionCount == 1 ? "session" : "sessions")")
        }
        if progress.trackedDuration > 0 {
            parts.append(DurationFormatting.compact(progress.trackedDuration))
        }
        return parts
    }

    private var trackedText: String? {
        guard let progress, progress.trackedDuration > 0 else { return nil }
        return DurationFormatting.compact(progress.trackedDuration)
    }

    // MARK: - Actions

    @ViewBuilder private var actionItems: some View {
        if let onEdit {
            Button("Edit…", action: onEdit)
        }
        if let onSetStatus {
            Menu("Status") {
                ForEach(OutcomeStatus.allCases) { status in
                    Toggle(
                        status.displayName,
                        isOn: Binding(
                            get: { outcome.status == status },
                            set: { isOn in
                                guard isOn, outcome.status != status else { return }
                                onSetStatus(status)
                            }
                        )
                    )
                }
            }
        }
        Button("Copy Title") { Pasteboard.copy(outcome.title) }
        if onDelete != nil {
            Divider()
            Button("Remove", role: .destructive) { isConfirmingRemoval = true }
        }
    }

    // MARK: - VoiceOver

    private var spokenValue: String {
        var parts = [outcome.priority.displayName, outcome.status.displayName]
        parts.append("\(outcome.progressPercent) percent, self-reported")
        parts.append(contentsOf: trackedParts)
        return parts.joined(separator: ", ")
    }
}
