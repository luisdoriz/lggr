import LggrKit
import SwiftUI

// The day, read top to bottom. See docs/_design/04-screens.md § 4.1 ("Day") and
// docs/_design/INTELLIGENCE.md § 4.
//
// This is the visible payoff of ambient capture: the app goes from "empty unless you pressed start"
// to "there when you forgot". It is a strip of the day, not a chart of it — eight or ten rows a
// person can read in fifteen seconds, not six hundred activations and not a Gantt bar.
//
// Three decisions this file exists to hold:
//
//   * **Gaps are rows.** An absence is information and gets the same left edge, the same time range
//     and the same duration as a block. Nothing on this strip may silently absorb time it has no
//     evidence for — that is the single failure the whole reconstruction is arranged to avoid.
//   * **Confidence is legible and quiet.** A block named from the user's own session and a block
//     named from whatever was in front of them do not look the same (`TimelineRail`), and neither
//     one looks alarming. `INTELLIGENCE.md` § 3.4 bans the colour that would be the easy answer.
//   * **No score, no total, no percentage.** There is no tracked-time headline here, no block count
//     and no share-of-day. Every number on this strip belongs to one row and is a fact about that
//     row. A number that grows when you fail to use the app is the thing § 3.4 removed four times
//     over, and it is not coming back in as a subtitle.
//
// The strip owns no scroll view. It is a section inside Today's `ScrollingSection`, and a nested
// `ScrollView` renders as *nothing at all* under `ImageRenderer` — which is how every screen in this
// app is reviewed for light and dark on a machine with no Xcode. See `ScrollingSection`.

/// Today's reconstructed day: blocks and the honestly marked absences between them.
///
/// Takes a plain `DayTimeline`, so it renders in full from a fixture with no store, no sampler and
/// no clock.
public struct DayTimelineStrip: View {

    private let timeline: DayTimeline

    public init(timeline: DayTimeline) {
        self.timeline = timeline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            header

            if timeline.isEmpty {
                empty
            } else {
                rows
                if let footnote {
                    Text(footnote)
                        .font(Type.caption)
                        .foregroundStyle(Ink.support)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Space.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day")
    }

    // MARK: - Header

    /// The heading carries the span of the day and nothing else. Not a count of blocks, not a total:
    /// § 4.1's own sketch of this section is `Day    9:00 ──────── 18:00`, and the two ends of the
    /// day are a fact about the record rather than a measure of the person keeping it.
    private var header: some View {
        SectionHeader("Day") {
            if let span {
                Text(span)
                    .font(Type.caption)
                    .monospacedDigit()
                    .foregroundStyle(Ink.support)
                    .accessibilityLabel("From \(span)")
            }
        }
    }

    private var span: String? {
        guard let bounds = timeline.bounds else { return nil }
        return TimelineClock.range(from: bounds.start, to: bounds.end)
    }

    // MARK: - Rows

    /// A plain `VStack`, not a `LazyVStack`. A reconstructed day is a dozen or two rows by
    /// construction — the builder's whole job is that it is not six hundred — so laziness would buy
    /// nothing and cost the snapshot renderer every row that falls outside the viewport.
    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(timeline.entries) { entry in
                switch entry {
                case .episode(let episode):
                    EpisodeRow(episode: episode)
                case .gap(let gap):
                    TimelineGapRow(gap: gap)
                }
            }
        }
    }

    // MARK: - The blind spot

    /// Lggr states its own blind spots on the screen where they apply, rather than in a document
    /// nobody reads. Two sentences, both facts, neither about the user:
    ///
    ///   1. what a dashed edge means — only when there is a dashed edge on screen to explain;
    ///   2. what Lggr cannot see, always, because it is true of every block above it.
    ///
    /// This is `INTELLIGENCE.md` § 7's risks 6 and 7 honoured where the user meets them: one
    /// frontmost application, one display, and a browser counted as a single application.
    private var footnote: String? {
        var sentences: [String] = []
        if timeline.episodes.contains(where: { !$0.labelConfidence.isUserAuthored }) {
            sentences.append(
                "A dashed edge means the name came from the applications that were in front, "
                    + "not from anything you declared."
            )
        }
        sentences.append(
            "Lggr sees one frontmost application at a time, so a second display or another "
                + "browser tab is not in this."
        )
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }

    // MARK: - Empty

    /// A day with no evidence at all — before the first flush of a fresh install, or a day the app
    /// was never launched on.
    ///
    /// Two lines on the bare canvas rather than the full `EmptyStateView`: this is one section of
    /// Today, not the whole screen, and a centred symbol with `Space.hero` of air either side would
    /// out-shout the session card above it. The copy states what the record holds and what will fill
    /// it; it does not ask the user to do anything, because ambient capture needs nothing from them.
    private var empty: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Nothing recorded yet today.")
                .font(Type.body)
                .foregroundStyle(.secondary)
            Text("This fills itself in as applications come to the front, session or no session.")
                .font(Type.body)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Space.s)
        .accessibilityElement(children: .combine)
    }
}
