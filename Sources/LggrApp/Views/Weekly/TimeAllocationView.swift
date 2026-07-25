import LggrKit
import SwiftUI

// Where the week's time went. See docs/_design/04-screens.md § 4.4 and § 2.5.
//
// **This is one of the two charts in the entire application.** `SPEC.md` bans unnecessary charts and
// § 4.4 spends the whole budget deliberately: a stacked proportion bar here, a per-day context-switch
// bar on the same screen, and every other number in Lggr is a figure inside a sentence. A proportion
// is the one thing genuinely faster to see than to read, and this is the one place the review states
// a proportion.
//
// It is one bar with three lenses rather than three bars. `SPEC.md` § 9 asks for time by project, by
// work type and by application category; drawn as three charts that is a dashboard, and a dashboard
// is what this app refuses to be. Drawn as one control the user switches, it is a single question —
// *how did the week divide?* — asked three ways.
//
// The two measurements behind those lenses are different measurements and are never blended. Project
// and work type are **declared session time**; activity is **observed application time**, which
// includes hours no session covered. They will not add up to each other, so the caption under the bar
// says which one you are looking at rather than leaving the user to assume they are comparable.

/// The stacked allocation bar and its legend.
///
/// Takes a `WeeklyReview` and reads it. Nothing here sums a duration, computes a share or decides an
/// order: `WeeklyReviewBuilder` did all three, and `PercentageAllocation` turns the durations into
/// whole percentages that total 100 without this file rounding anything itself.
@MainActor
public struct TimeAllocationView: View {

    /// The three ways § 9 asks for the week to be divided.
    public enum Lens: String, CaseIterable, Identifiable, Sendable {
        case project
        case workType
        case activity

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .project: "By project"
            case .workType: "By work type"
            case .activity: "By activity"
            }
        }

        /// What the numbers in this lens are measurements *of*. Shown under the bar, because a share
        /// of declared time and a share of observed time are not the same claim.
        var provenance: String {
            switch self {
            case .project, .workType:
                "Time in sessions you started, split by what you filed them under."
            case .activity:
                "Time applications were in front of you, whether or not a session was running."
            }
        }
    }

    /// How many legend rows are shown before the tail is folded into *Other*. A twenty-line breakdown
    /// of a week is data, not a summary.
    private static let rowLimit = 6

    private let review: WeeklyReview
    private let projects: [Project]

    /// `nil` until the user picks one, so the section opens on whichever lens actually has data.
    @State private var chosenLens: Lens?
    @State private var hoveredSliceID: String?

    public init(review: WeeklyReview, projects: [Project]) {
        self.review = review
        self.projects = projects
    }

    /// Whether the section has anything to draw. The screen asks before rendering it: an allocation
    /// bar with no allocation in it is a claim that the week divided into nothing.
    public static func hasContent(_ review: WeeklyReview) -> Bool {
        !Lens.allCases.allSatisfy { slices(for: $0, review: review, projects: []).isEmpty }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader("Where the time went") {
                lensPicker
            }

            if slices.isEmpty {
                // Reachable only when the chosen lens is the empty one, which the picker prevents —
                // stated rather than crashed into an empty bar.
                Text("Nothing recorded under this view of the week.")
                    .font(Type.body)
                    .foregroundStyle(.secondary)
            } else {
                bar
                legend
                Text(lens.provenance)
                    .font(Type.caption)
                    .foregroundStyle(Ink.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lggrAnimation(Motion.settle, value: lens)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where the time went")
    }

    // MARK: - The lens

    private var lens: Lens {
        if let chosenLens, !Self.slices(for: chosenLens, review: review, projects: projects).isEmpty {
            return chosenLens
        }
        return availableLenses.first ?? .project
    }

    /// Only the lenses that have something in them. A week with no sessions still has an activity
    /// breakdown, and offering the two empty session lenses next to it would invite the user to click
    /// on nothing.
    private var availableLenses: [Lens] {
        Lens.allCases.filter { !Self.slices(for: $0, review: review, projects: projects).isEmpty }
    }

    /// Absent, not disabled, when the week only supports one lens: a segmented control with one
    /// segment is a label pretending to be a control.
    @ViewBuilder private var lensPicker: some View {
        let lenses = availableLenses
        if lenses.count > 1 {
            Picker("View", selection: lensBinding) {
                ForEach(lenses) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .accessibilityLabel("Divide the week")
        }
    }

    private var lensBinding: Binding<Lens> {
        Binding(
            get: { lens },
            set: { chosenLens = $0 }
        )
    }

    // MARK: - The bar

    /// 6pt tall, segments separated by a 1pt canvas-coloured gap (`04-screens.md` § 2.5), and the
    /// whole bar clipped once so the ends are round and the internal edges are square.
    private var bar: some View {
        GeometryReader { proxy in
            let segments = slices
            let widths = widths(in: proxy.size.width)
            HStack(spacing: Layout.hairline) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle()
                        .fill(segments[index].color)
                        .opacity(opacity(of: segments[index]))
                        .frame(width: widths.indices.contains(index) ? widths[index] : 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Layout.allocationBarHeight)
        .clipShape(Theme.chipShape)
        .lggrAnimation(Motion.tap, value: hoveredSliceID)
        .accessibilityHidden(true)
    }

    /// Segment widths that add up to the space available, with the remainder handed to the last
    /// segment rather than left as a visible sliver of canvas at the right-hand end.
    private func widths(in total: CGFloat) -> [CGFloat] {
        let gaps = Layout.hairline * CGFloat(max(0, slices.count - 1))
        let available = max(0, total - gaps)
        guard available > 0, !slices.isEmpty else { return slices.map { _ in 0 } }

        let durations = slices.reduce(0) { $0 + $1.duration }
        guard durations > 0 else {
            let even = available / CGFloat(slices.count)
            return slices.map { _ in even }
        }

        var widths: [CGFloat] = []
        var used: CGFloat = 0
        for (index, slice) in slices.enumerated() {
            if index == slices.count - 1 {
                widths.append(max(0, available - used))
            } else {
                let width = available * CGFloat(slice.duration / durations)
                widths.append(width)
                used += width
            }
        }
        return widths
    }

    /// Hovering a legend row lifts its segment and drops the others to 55% (`04-screens.md` § 4.4).
    private func opacity(of slice: Slice) -> Double {
        guard let hoveredSliceID else { return 1 }
        return slice.id == hoveredSliceID ? 1 : 0.55
    }

    // MARK: - The legend

    /// Rows carry **no hover fill** — hovering a row moves the *bar*, which is where the information
    /// is. `Surface.hover` here would make the legend look like a list of things to click.
    ///
    /// The duration and the share are one right-aligned string rather than two aligned columns. A
    /// `Grid` would align the columns, but a modifier on a `GridRow` applies to each cell rather than
    /// to the row, so the row's hover target and its VoiceOver element would both be triplicated. One
    /// trailing string is one hover target, one spoken element, and a right edge that lines up.
    private var legend: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(slices) { slice in
                HStack(spacing: Space.s) {
                    SliceSwatch(color: slice.color)
                    Text(slice.name)
                        .font(Type.secondary)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: Space.m)

                    Text(trailingText(slice))
                        .font(Type.secondary)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.vertical, Space.xs)
                .contentShape(Rectangle())
                .onHover { isHovering in
                    hoveredSliceID = isHovering ? slice.id : nil
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(slice.name)
                .accessibilityValue(
                    "\(DurationFormatting.compact(slice.duration)), \(slice.percent) percent"
                )
            }
        }
    }

    private func trailingText(_ slice: Slice) -> String {
        "\(DurationFormatting.compact(slice.duration)) · \(slice.percent)%"
    }

    // MARK: - Slices

    /// One row of the legend and one segment of the bar.
    private struct Slice: Identifiable {
        let id: String
        let name: String
        let duration: TimeInterval
        let percent: Int
        let color: Color
    }

    private var slices: [Slice] { Self.slices(for: lens, review: review, projects: projects) }

    /// The fold-in row, and the colour of anything that is not a project.
    ///
    /// A neutral grey rather than a tenth hue: colour in Lggr means "which project" or it means
    /// nothing (`04-screens.md` § 2.5), so the two lenses that are not about projects are drawn as a
    /// single accent shaded down its own opacity ramp, and *Other* is grey in every lens.
    private static let otherColor = Color.primary.opacity(0.18)

    private static let ramp: [Double] = [1.0, 0.78, 0.6, 0.46, 0.34, 0.24]

    private static func rampColor(_ index: Int) -> Color {
        Color.accentColor.opacity(ramp[min(index, ramp.count - 1)])
    }

    private static func slices(
        for lens: Lens,
        review: WeeklyReview,
        projects: [Project]
    ) -> [Slice] {
        switch lens {
        case .project:
            return folded(
                review.timeByProject.map { entry in
                    let colorID = projects.first { $0.id == entry.projectID }?.colorID
                    return Raw(
                        id: "project-\(entry.id)",
                        name: entry.name,
                        duration: entry.duration,
                        color: colorID.map(Palette.project) ?? otherColor
                    )
                }
            )
        case .workType:
            return folded(
                review.timeByWorkType.enumerated().map { index, entry in
                    Raw(
                        id: "workType-\(entry.id)",
                        name: entry.workType.displayName,
                        duration: entry.duration,
                        color: rampColor(index)
                    )
                }
            )
        case .activity:
            return folded(
                review.timeByCategory.enumerated().map { index, entry in
                    Raw(
                        id: "activity-\(entry.id)",
                        name: entry.category.displayName,
                        duration: entry.duration,
                        color: rampColor(index)
                    )
                }
            )
        }
    }

    /// A slice before it knows its percentage.
    private struct Raw {
        let id: String
        let name: String
        let duration: TimeInterval
        let color: Color
    }

    /// Percentages are apportioned across the **whole** breakdown before the tail is folded, so the
    /// visible rows still total 100 and *Other* is the true remainder rather than a rounding scrap.
    /// This is the same rule `WeeklyReviewMarkdown` follows, which is why the screen and the exported
    /// document print the same numbers.
    private static func folded(_ entries: [Raw]) -> [Slice] {
        let present = entries.filter { $0.duration > 0 && !$0.name.isEmpty }
        guard !present.isEmpty else { return [] }

        let percentages = PercentageAllocation.percentages(of: present.map(\.duration))
        guard percentages.count == present.count else { return [] }

        let head = present.count > rowLimit ? rowLimit - 1 : present.count
        var slices = present.indices.prefix(head).map { index in
            Slice(
                id: present[index].id,
                name: present[index].name,
                duration: present[index].duration,
                percent: percentages[index],
                color: present[index].color
            )
        }

        let tail = present.indices.dropFirst(head)
        if !tail.isEmpty {
            slices.append(
                Slice(
                    id: "other",
                    name: "Other",
                    duration: tail.reduce(0) { $0 + present[$1].duration },
                    percent: tail.reduce(0) { $0 + percentages[$1] },
                    color: otherColor
                )
            )
        }
        return slices
    }
}

// MARK: - Swatch

/// The legend's colour chip.
///
/// The same 0.5pt inner ring every project dot carries (`04-screens.md` § 2.5): without it a yellow
/// or orange project disappears against a light canvas, and the palest end of the accent ramp
/// disappears against a dark one. Fixing it here fixes it for all three lenses.
private struct SliceSwatch: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(Stroke.projectDot, lineWidth: Stroke.projectDotWidth))
            .frame(width: Layout.projectDotSize, height: Layout.projectDotSize)
            .accessibilityHidden(true)
    }
}
