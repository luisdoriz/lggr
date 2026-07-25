import LggrKit
import SwiftUI

// The two rows a reconstructed day is made of: a block, and an absence.
//
// They live in one file because the only thing that matters about either of them is how they read
// *next to* the other. A gap has to be quieter than a block and still legible as information — if
// the absence ever becomes invisible, the block beside it starts to look like it accounts for time
// it has no evidence for, which is the one failure this whole feature is arranged to avoid.
//
// Neither row owns behaviour. Phase 1 shows the day; turning a block into a session is Phase 2.

// MARK: - Time

/// Clock strings for the timeline. One place, so a block and the gap under it can never disagree
/// about how 9:04 is spelled.
enum TimelineClock {
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// `9:04–9:58`. The en dash and the absent spaces match `SessionRow`'s ranges exactly.
    static func range(from start: Date, to end: Date) -> String {
        "\(time(start))–\(time(end))"
    }

    /// The spoken form, because VoiceOver reads an en dash as a pause and loses the relationship.
    static func spokenRange(from start: Date, to end: Date) -> String {
        "\(time(start)) to \(time(end))"
    }
}

// MARK: - The rail

/// The 3pt leading rail that runs down the side of every timeline row.
///
/// This is where confidence lives, and it is the reason it is legible without being loud. Three
/// states, distinguished by *solidity* rather than by hue:
///
///   * **solid** — the block borrowed the user's own sentence from a session they declared;
///   * **dashed** — the app assembled the name from the applications it saw;
///   * **dotted, fainter** — an absence. Nothing was recorded here at all.
///
/// Colour is deliberately not the carrier. `04-screens.md` § 2.4 allows exactly two non-project
/// colours in the application and neither of them means "unsure", and `INTELLIGENCE.md` § 3.4 bans
/// anything that reads as a score or a warning. A line that is drawn through rather than drawn in a
/// different colour states the same thing and states it quietly — and because it is a shape, the
/// same distinction is carried into `accessibilityValue` as words rather than being lost.
struct TimelineRail: View {

    enum Style {
        /// The user's own words. Nothing was inferred.
        case declared
        /// Named from what was in front of the user, and claiming nothing beyond it.
        case observed
        /// An absence.
        case absent
    }

    let style: Style

    var body: some View {
        VerticalLine()
            .stroke(style: strokeStyle)
            .foregroundStyle(shade)
            .frame(width: Layout.timelineBarWidth)
            .frame(maxHeight: .infinity)
            .accessibilityHidden(true)
    }

    private var strokeStyle: StrokeStyle {
        let width = Layout.timelineBarWidth
        switch style {
        case .declared:
            return StrokeStyle(lineWidth: width, lineCap: .round)
        case .observed:
            // Long enough to read as a *dashed line* rather than as a column of dots — at 3pt the
            // two are easy to confuse, and confusing them costs the distinction its whole meaning.
            //
            // Short enough that a **one-line row still gets three dashes.** The pattern was
            // `[9, 4.5]`, a 13.5pt period, and a row with a title and no application list is about
            // 20pt tall: one dash, a gap, and a stub. In the day-timeline snapshot the four
            // app-named blocks came back looking like exclamation marks while the footnote underneath
            // promised a dashed edge. A 7.5pt period fits three, and a 4.5pt segment is still six
            // times the `absent` dot, so the three styles stay three styles.
            return StrokeStyle(lineWidth: width, lineCap: .round, dash: [width * 1.5, width])
        case .absent:
            return StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.5, width * 2])
        }
    }

    private var shade: HierarchicalShapeStyle {
        switch style {
        case .declared: return .secondary
        case .observed: return .tertiary
        case .absent: return .quaternary
        }
    }
}

/// A vertical line down the middle of its frame. `Divider()` cannot be dashed and a `Rectangle`
/// cannot be either, so the rail is drawn rather than filled.
private struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

// MARK: - Episode

/// One block of a reconstructed day.
///
/// ```
/// ▍ 9:04–9:58  Finish the receipt deduplication PR              46m
///              Xcode, Terminal, Simulator +2 more · 3 glances
/// ```
///
/// The time range leads because a person recognises a day by *when*, not by *what*; the label is the
/// only thing in the row set at `Type.rowTitle`; everything else is demoted metadata. The duration
/// is the time actually spent in an application, summed from the monotonic measurement — never the
/// wall-clock span, which would quietly count the idle minutes the timeline has already broken out
/// as their own gaps.
///
/// The roster is not repeated when it *is* the label. A block the builder could only name after its
/// applications would otherwise print `Xcode, Terminal` twice, two lines apart, which reads as a
/// rendering bug and costs the row its only line of real evidence.
public struct EpisodeRow: View {

    private let episode: Episode

    @State private var isHovered = false

    public init(episode: Episode) {
        self.episode = episode
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            TimelineRail(style: episode.labelConfidence.isUserAuthored ? .declared : .observed)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text(TimelineClock.range(from: episode.start, to: episode.end))
                        .font(Type.secondary)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Text(episode.label)
                        .font(Type.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let detail {
                    Text(detail)
                        .font(Type.secondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: Space.m)

            Text(episode.durationText)
                .font(Type.secondary)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        // The hover fill bleeds past the text column on both sides so the row's text stays aligned
        // with the heading above it. A row that indents on hover is a row that moves.
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        // SPEC §5's correction loop, offered where the classification is actually visible. The menu is
        // absent — not disabled — when there is no application to write a rule about, which includes
        // any block whose identity was replaced with "Private" before it was written. See
        // `Views/Rules/ReclassifySheet.swift`.
        .reclassifiable(
            bundleIdentifier: episode.dominantApp?.bundleIdentifier ?? "",
            displayName: episode.dominantApp?.displayName ?? ""
        )
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(episode.label)
        .accessibilityValue(spokenDetail)
    }

    // MARK: - Metadata

    /// The roster, then the glances, both only when they say something the row does not already say.
    private var detail: String? {
        var parts: [String] = []
        if !rosterIsTheLabel, !episode.appRosterText.isEmpty {
            parts.append(episode.appRosterText)
        }
        if let glances { parts.append(glances) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// True when the builder named the block after its applications, so the metadata line would be
    /// a copy of the title.
    private var rosterIsTheLabel: Bool {
        episode.label == episode.appRosterText
    }

    /// Excursions short enough to have returned before they became a context switch.
    ///
    /// Shown from two upward, and the threshold is the point of it: one cmd-tab to Slack and back is
    /// not a pattern, and printing `1 glance` under every second block would turn an honest detail
    /// into visual noise — and, worse, into a number a person starts trying to get down.
    private var glances: String? {
        guard episode.interjections >= 2 else { return nil }
        return "\(episode.interjections) glances"
    }

    // MARK: - Provenance

    /// Where the name came from, in a sentence. The visual form of this is the rail; this is the
    /// form VoiceOver and the tooltip read, because a dash pattern is not information on its own.
    private var provenance: String {
        episode.labelConfidence.isUserAuthored
            ? "Named from the session you started."
            : "Named from the applications that were in front."
    }

    private var helpText: String {
        "\(TimelineClock.range(from: episode.start, to: episode.end)) · \(episode.durationText). "
            + provenance
    }

    private var spokenDetail: String {
        var parts = [TimelineClock.spokenRange(from: episode.start, to: episode.end)]
        parts.append(episode.durationText)
        if !rosterIsTheLabel, !episode.appRosterText.isEmpty {
            parts.append(episode.appRosterText)
        }
        if let glances { parts.append(glances) }
        parts.append(provenance)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Gap

/// One absence on a reconstructed day: time the app will not attribute to work.
///
/// ```
/// ⋮ ⏸  10:12–10:40 · Idle                                       28m
/// ⋮ 🌙  18:04–09:12 · Asleep                                     15h 8m
/// ⋮ ?  11:20–11:35 · Not accounted for                           15m
/// ```
///
/// This row is the honesty mechanism the whole design rests on, so it is rendered rather than
/// hidden even when — especially when — the reason is `.unexplained`. Quieter than a block in every
/// dimension that carries hierarchy: no `Type.rowTitle`, less vertical air, a fainter rail. Not
/// quiet enough to disappear, because a gap that vanishes is a gap the block beside it appears to
/// have covered.
///
/// The reason's wording comes from `GapReason.displayName` and is used verbatim. Every one of those
/// sentences is a fact about the record — *Lggr was not running*, *Not accounted for* — and none has
/// the user as its subject.
public struct TimelineGapRow: View {

    private let gap: Gap

    public init(gap: Gap) {
        self.gap = gap
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            TimelineRail(style: .absent)

            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: gap.reason.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                Text(verbatim: "\(range) · \(gap.reason.displayName)")
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: Space.m)

            Text(DurationFormatting.compact(gap.duration))
                .font(Type.secondary)
                .monospacedDigit()
                .foregroundStyle(Ink.support)
                .fixedSize()
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, Space.s)
        .padding(.horizontal, -Space.s)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(gap.reason.displayName)
        .accessibilityValue(spokenDetail)
    }

    private var range: String {
        TimelineClock.range(from: gap.start, to: gap.end)
    }

    /// One plain sentence per reason, and nothing implied beyond it. `.unexplained` says what it is
    /// rather than apologising for it: the alternative to admitting a hole is inventing a block.
    private var explanation: String {
        switch gap.reason {
        case .idle:
            return "An application was in front, and no input arrived."
        case .displayOff:
            return "The display was off."
        case .systemSleep:
            return "The machine was asleep."
        case .screenLocked:
            return "The screen was locked."
        case .fastUserSwitched:
            return "Another account was signed in, so nothing was recorded."
        case .appNotRunning:
            return "Lggr was not running, so nothing was recorded."
        case .trackingPaused:
            return "Tracking was off, so nothing was recorded."
        case .excludedApplication:
            return "The application in front is on the excluded list."
        case .unexplained:
            return "Lggr has no record for this time."
        }
    }

    private var helpText: String {
        "\(range) · \(DurationFormatting.compact(gap.duration)). \(explanation)"
    }

    private var spokenDetail: String {
        [
            TimelineClock.spokenRange(from: gap.start, to: gap.end),
            DurationFormatting.compact(gap.duration),
            explanation,
        ]
        .joined(separator: ", ")
    }
}
