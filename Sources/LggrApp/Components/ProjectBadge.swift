import SwiftUI
import LggrKit

/// A project's colour dot, and its icon and name.
///
/// This component exists so that rule § 2.5 holds everywhere by construction: **every project dot is
/// followed by the project's name.** Colour is never the only carrier of "which project", so colour
/// blindness costs nothing and a screenshot still reads.
///
/// Two variants:
///   * `.standard` — dot, icon, name. Row metadata, the review sheet header, the start panel.
///   * `.compact` — dot and name only. Dense lists and the menu bar popover, where a second glyph
///     per row is noise.
///
/// A `nil` project renders "No project" with a hollow dot, so rows stay aligned in a list where some
/// sessions have a project and some do not. Starting a session without a project is fully supported
/// and is never flagged.
public struct ProjectBadge: View {
    public enum Variant {
        case standard
        case compact
    }

    private let project: Project?
    private let variant: Variant

    public init(project: Project?, variant: Variant = .standard) {
        self.project = project
        self.variant = variant
    }

    public var body: some View {
        HStack(spacing: Space.xxs) {
            ProjectDot(colorID: project?.colorID)

            if variant == .standard, let project {
                Image(systemName: project.iconID)
                    .imageScale(.small)
                    .foregroundStyle(Palette.project(project.colorID))
                    .padding(.leading, Space.xxs)
                    .accessibilityHidden(true)
            }

            // Both cases read at the same weight, and the hollow dot is what says "no project" — which
            // is what this type's own documentation says it is for. "No project" was `.tertiary`, and
            // the dark snapshot showed the consequence: a word that appears in a third of the rows in
            // Focus Sessions rendering at about 2.3:1 against the canvas. Dimming an absence below
            // legibility is a soft way of flagging it, and starting a session without a project is
            // supported rather than a lapse.
            Text(name)
                .font(Type.secondary)
                .foregroundStyle(Ink.support)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, Space.xs - Space.xxs)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project")
        .accessibilityValue(name)
    }

    private var name: String {
        project?.normalizedName ?? "No project"
    }
}

/// The 8pt filled circle that precedes a project's name.
///
/// The 0.5pt `Stroke.projectDot` inner ring is load-bearing rather than decorative: without it a
/// yellow or orange dot disappears against a light canvas. Fixing it here fixes it everywhere.
///
/// A `nil` colour id renders the ring alone — the "no project" case.
public struct ProjectDot: View {
    private let colorID: String?
    private let size: CGFloat

    public init(colorID: String?, size: CGFloat = Layout.projectDotSize) {
        self.colorID = colorID
        self.size = size
    }

    public init(project: Project?, size: CGFloat = Layout.projectDotSize) {
        self.init(colorID: project?.colorID, size: size)
    }

    public var body: some View {
        Circle()
            .fill(fill)
            .overlay(
                Circle().strokeBorder(Stroke.projectDot, lineWidth: Stroke.projectDotWidth)
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private var fill: Color {
        guard let colorID else { return .clear }
        return Palette.project(colorID)
    }
}
