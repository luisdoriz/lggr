import SwiftUI

/// A grouped `Form` in the running app, and a plain stack when the build is photographing itself.
///
/// The same problem `ScrollingSection` solves, and the same shape of answer — read that type first for
/// the measurements and the reasoning. `ImageRenderer` draws `Form` with `.formStyle(.grouped)` as an
/// **empty grey rectangle**: not a placeholder, not partial content, just the window-grey backdrop at
/// the frame's full size.
///
/// That is worse than the `ScrollView` case, because grey passes for a rendered screen. It defeated
/// the `hasContent` guard in `SnapshotMode` when that guard compared brightness against the render's
/// own white or black backdrop — fifty-one thousand samples of window-grey all counted as content. So
/// Settings sat in the `unphotographable` list and became **the only screen in the project never
/// reviewed visually.** Predictably, it is the screen the user reported as looking wrong.
///
/// Nothing about the running app changes: `isGalleryMode` is `false` everywhere except inside
/// `SnapshotMode`, so every user-facing surface gets the ordinary grouped `Form` that
/// `04-screens.md` § 4.7 asks for. The photograph loses the grouped background and the platform
/// insets, which is a real loss — a snapshot of this container proves the copy, the row order and
/// the states, not the chrome. That is still infinitely more than grey.
///
/// ### What a snapshot of this container cannot tell you
///
/// **Do not judge responsive behaviour from it.** A `Section` inside the plain stack does not
/// constrain width the way it does inside a `Form`, so a narrow render of a Settings pane comes back
/// clipped on both edges whether or not the real window has any such problem. That was measured:
/// chasing a reported layout issue this way produced a convincingly broken 380pt image, and a
/// standalone probe then showed the same content wrapping correctly at the same width — the two
/// side-by-side hour pickers fit in 380pt with room to spare, and `ImageRenderer` honours the frame
/// and wraps `Text` exactly as it should.
///
/// So the clipping was this container, not the app. Width-sensitive layout in Settings has to be
/// judged from a screenshot of the running window; this type is for copy, ordering and state.
@MainActor
struct SettingsForm<Content: View>: View {

    @Environment(\.isGalleryMode) private var isGalleryMode

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if isGalleryMode {
            VStack(alignment: .leading, spacing: Space.l) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.l)
        } else {
            Form {
                content
            }
            .formStyle(.grouped)
        }
    }
}
