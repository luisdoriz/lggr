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
/// insets, which is a real loss — a snapshot of this container proves the copy, the row order, the
/// wrapping and the states, not the chrome. That is still infinitely more than grey.
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
