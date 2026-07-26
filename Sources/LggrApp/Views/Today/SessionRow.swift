import AppKit
import LggrKit
import SwiftUI

/// One finished focus session, as it appears in Today's list. See `04-screens.md` § 4.1 and § 4.2.
///
/// The hierarchy is the one § 4.2 fixes, and it is not a table:
///
///   1. the intended outcome, `Type.rowTitle` — the thing the user is actually scanning for, and the
///      one string in the row that never truncates;
///   2. the result, glyph *and* word, trailing;
///   3. project · work type · time range · duration, all demoted to `Type.secondary`.
///
/// The result is rendered in `.secondary`, never in colour. A blocked session is information, not a
/// failure, and red exists in exactly one place in this application: the confirm button of a delete
/// alert (`04-screens.md` § 2.4).
///
/// A session that finished without an answer to "What happened?" shows a `Review` button where the
/// result would be. That is the recovery path for "the app quit before I answered" — a finished
/// session is never lost because a sheet was dismissed.
public struct SessionRow: View {

    private let session: FocusSession
    private let project: Project?
    private let onReview: (() -> Void)?
    private let onAddAccomplishment: (() -> Void)?
    private let onEditTimes: (() -> Void)?
    private let onDelete: (() -> Void)?

    @State private var isHovered = false
    @State private var isConfirmingDelete = false

    public init(
        session: FocusSession,
        project: Project?,
        onReview: (() -> Void)? = nil,
        onAddAccomplishment: (() -> Void)? = nil,
        onEditTimes: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.session = session
        self.project = project
        self.onReview = onReview
        self.onAddAccomplishment = onAddAccomplishment
        self.onEditTimes = onEditTimes
        self.onDelete = onDelete
    }

    public var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(session.intendedOutcome)
                    .font(Type.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                metadata
            }

            Spacer(minLength: Space.m)

            trailing
        }
        .padding(.vertical, Space.m)
        .padding(.horizontal, Space.s)
        .background(isHovered ? Surface.hover : Color.clear, in: Theme.cardShape)
        .contentShape(Theme.cardShape)
        // The hover fill bleeds `Space.s` past the text column on both sides so that the text stays
        // aligned with the section heading above it. A row that indents on hover is a row that moves.
        .padding(.horizontal, -Space.s)
        .onHover { isHovered = $0 }
        .lggrAnimation(Motion.tap, value: isHovered)
        .contextMenu { actionItems }
        .alert("Delete this session?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Session", role: .destructive) { onDelete?() }
        } message: {
            // 04-screens.md § 10.10 names the activity records this also removes; Phase 2 does not
            // capture any, so saying so would be untrue. This is the honest Phase 2 wording.
            Text("This removes the session and its summary. Accomplishments you logged stay where they are.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(session.intendedOutcome)
        .accessibilityValue(spokenDetail)
    }

    // MARK: - Metadata

    /// Assembled as one `Text` after the badge rather than as five siblings, so the whole line
    /// truncates as a unit and the interpuncts never end up orphaned on a wrap.
    private var metadata: some View {
        HStack(spacing: Space.xs) {
            ProjectBadge(project: project, variant: .compact)
            Text(verbatim: "·")
                .font(Type.secondary)
                .foregroundStyle(.tertiary)
            Text(metadataText)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let editedAt = session.editedAt {
                EditedMark(editedAt: editedAt)
            }
        }
        .accessibilityHidden(true)
    }

    private var metadataText: String {
        var parts = [session.workType.displayName]
        if let range = timeRange { parts.append(range) }
        if let duration = session.effectiveDuration {
            parts.append(DurationFormatting.compact(duration))
        }
        return parts.joined(separator: " · ")
    }

    private var timeRange: String? {
        guard let endedAt = session.endedAt else { return nil }
        let start = session.startedAt.formatted(date: .omitted, time: .shortened)
        let end = endedAt.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    // MARK: - Trailing

    private var trailing: some View {
        HStack(spacing: Space.s) {
            result
            RowMoreMenu(isVisible: isHovered) { actionItems }
        }
    }

    @ViewBuilder private var result: some View {
        if let status = session.resultStatus {
            Label(status.displayName, systemImage: status.symbolName)
                .font(Type.secondary)
                .foregroundStyle(.secondary)
                .imageScale(.medium)
                .lineLimit(1)
                .fixedSize()
        } else if let onReview {
            Button("Review", action: onReview)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    // MARK: - Actions

    /// One list, rendered both as the context menu and as the hover menu, so the two can never drift.
    @ViewBuilder private var actionItems: some View {
        if session.resultStatus == nil, let onReview {
            Button("Review", action: onReview)
        }
        if let onAddAccomplishment {
            Button("Add accomplishment", action: onAddAccomplishment)
        }
        if let onEditTimes {
            Button("Correct times…", action: onEditTimes)
        }
        Button("Copy outcome") { Pasteboard.copy(session.intendedOutcome) }
        if let summary = session.resultSummary, !summary.isEmpty {
            Button("Copy summary") { Pasteboard.copy(summary) }
        }
        if onDelete != nil {
            Divider()
            Button("Delete Session", role: .destructive) { isConfirmingDelete = true }
        }
    }

    // MARK: - VoiceOver

    /// The row's own text is combined into one element; this is the sentence it reads.
    private var spokenDetail: String {
        var parts: [String] = []
        if let name = project?.normalizedName { parts.append(name) }
        parts.append(session.workType.displayName)
        if let range = timeRange { parts.append(range) }
        if let duration = session.effectiveDuration {
            parts.append(DurationFormatting.compact(duration))
        }
        parts.append(session.resultStatus?.displayName ?? "Not reviewed")
        if session.wasEdited { parts.append(EditedMark.spoken) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Shared row affordances

/// The mark a session carries once its times were corrected by hand. See `FocusSession.editedAt`.
///
/// **Provenance, not a warning.** `.tertiary`, the ordinary pencil, no colour and no triangle; the
/// date arrives on hover rather than taking a column of its own. Lggr's claim is that it is
/// trustworthy evidence of your day, which means a number the user typed is never presented as one the
/// app observed — the same honesty the timeline already applies to a gap it cannot explain. Nothing
/// reads this as a fault and no total is discounted because of it.
struct EditedMark: View {

    let editedAt: Date

    var body: some View {
        Image(systemName: Icon.edit)
            .imageScale(.small)
            .foregroundStyle(.tertiary)
            .help(Self.help(editedAt))
            // The row combines its own children and speaks `spoken` as part of its sentence, so a
            // second element here would say "edited" twice.
            .accessibilityHidden(true)
    }

    /// The tooltip: what happened, and when. Not "you edited this".
    static func help(_ editedAt: Date) -> String {
        "Times corrected by hand on "
            + editedAt.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// What VoiceOver reads as part of a row's own sentence.
    static let spoken = "times corrected by hand"
}

/// The trailing `⋯` button a row reveals on hover.
///
/// It stays in the layout at zero opacity rather than being inserted, because a row that changes
/// width when the pointer crosses it is a row that moves — and nothing in Lggr moves that the user
/// did not move. Hit testing follows the opacity so the invisible control cannot be clicked.
struct RowMoreMenu<Items: View>: View {
    let isVisible: Bool
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: Icon.more)
                .imageScale(.medium)
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .lggrAnimation(Motion.tap, value: isVisible)
        .accessibilityLabel("More actions")
    }
}

/// Copying to the clipboard.
///
/// AppKit, because SwiftUI has no pasteboard API on macOS outside of drag-and-drop and the
/// `.copy` command in a focused text view. `NSPasteboard` is the only way to fulfil a
/// "Copy summary" menu item.
enum Pasteboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
