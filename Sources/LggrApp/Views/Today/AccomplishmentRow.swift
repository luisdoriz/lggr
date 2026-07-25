import LggrKit
import SwiftUI

/// One thing that got done. See `04-screens.md` § 4.3.
///
/// Hierarchy: the title first, the type glyph second, the project badge and timestamp third.
///
/// **The glyph is never tinted by type.** There are eleven `AccomplishmentType` cases, and eleven
/// tinted glyphs is a rainbow; colour in Lggr means "which project" or it means nothing
/// (`04-screens.md` § 2.5). The type is still announced to VoiceOver, so nothing is lost by the glyph
/// being quiet.
///
/// `details` is deliberately not rendered here. A log you scan on Friday afternoon wants one line per
/// thing you delivered; the detail is one click away in the editor.
public struct AccomplishmentRow: View {

    private let accomplishment: Accomplishment
    private let project: Project?
    private let onEdit: (() -> Void)?
    private let onDelete: (() -> Void)?

    @State private var isHovered = false
    @State private var isConfirmingDelete = false

    public init(
        accomplishment: Accomplishment,
        project: Project?,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.accomplishment = accomplishment
        self.project = project
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: accomplishment.type.symbolName)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                // The glyph column is fixed width so every title in the list starts on the same
                // vertical, however wide the individual symbols happen to be.
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(accomplishment.title)
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                metadata
            }

            Spacer(minLength: Space.m)

            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .contextMenu { actionItems }
        .alert("Delete this accomplishment?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { onDelete?() }
        } message: {
            Text("It is removed from your log. The session it came from is untouched.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accomplishment.title)
        .accessibilityValue(spokenDetail)
    }

    // MARK: - Metadata

    private var metadata: some View {
        HStack(spacing: Space.xs) {
            ProjectBadge(project: project, variant: .compact)
            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
            Text(accomplishment.timestamp.formatted(date: .omitted, time: .shortened))
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .accessibilityHidden(true)
    }

    // MARK: - Actions

    @ViewBuilder private var actionItems: some View {
        if let onEdit {
            Button("Edit…", action: onEdit)
        }
        Button("Copy as Markdown") { Pasteboard.copy(markdown) }
        if onDelete != nil {
            Divider()
            Button("Delete", role: .destructive) { isConfirmingDelete = true }
        }
    }

    /// One list item. Assembled here rather than in `LggrKit` because `MarkdownRendering` is a `[P4]`
    /// file and a two-line clipboard string does not justify reaching into a phase that has not
    /// started; the real exporter replaces this when it arrives.
    private var markdown: String {
        var line = "- \(accomplishment.title)"
        if let details = accomplishment.details, !details.isEmpty {
            line += " — \(details)"
        }
        return line
    }

    // MARK: - VoiceOver

    private var spokenDetail: String {
        var parts = [accomplishment.type.displayName]
        if let name = project?.normalizedName { parts.append(name) }
        parts.append(accomplishment.timestamp.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: ", ")
    }
}
