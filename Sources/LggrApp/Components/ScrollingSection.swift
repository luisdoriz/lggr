import SwiftUI

/// A `ScrollView` in the running app, and a plain stack when the build is photographing itself.
///
/// ### Why this type exists
///
/// `ImageRenderer` is the whole reason the visual design is reviewable on a machine without Xcode
/// (`SPIKE-menubar.md` § "Third spike", `CONSTRAINTS.md`): `#Preview` cannot compile here, so
/// `LggrApp --snapshot` renders each screen to a PNG instead. **`ImageRenderer` draws a `ScrollView`
/// as nothing at all.** Not a clipped viewport, not the first screenful — nothing. Measured
/// directly, same content, same 400×300 frame, ink counted off the resulting bitmap:
///
/// | Content                             | Ink |
/// |---|---|
/// | `VStack { rows }`                   | 1839 |
/// | `LazyVStack { rows }`               | 1712 |
/// | `ScrollView { VStack { rows } }`    | **0** |
/// | `ScrollView { … }.scrollDisabled(true)` | **0** |
/// | `ScrollView { … }.fixedSize(…)`     | **0** |
///
/// The renderer's white background is present in every case, so the view *was* rendered; the scroll
/// view simply contributes no drawing. No modifier on the outside fixes it, and a taller frame does
/// not either — the height is not what is missing. `LazyVStack` is not the culprit and needs no
/// change: lazy rows materialise fine.
///
/// So the container has to go away for the render, and that is all this type does. Snapshots want
/// the full content at its natural height anyway rather than one 720pt viewport of it, so removing
/// the scroll view is the *correct* rendering for a photograph, not a workaround grafted onto one.
///
/// Nothing about the running app changes: `isGalleryMode` is `false` everywhere except inside
/// `SnapshotMode`, so every user-facing surface gets the ordinary `ScrollView`.
///
/// ### The rest of what `ImageRenderer` cannot draw
///
/// Measured on this machine at the same time, and left alone deliberately. Each one renders as
/// SwiftUI's yellow "unsupported view" placeholder — visibly an artefact, unlike a blank screen,
/// which is why only the scroll view was worth designing around:
///
/// - `TextEditor` — the review sheet's Summary field.
/// - `.buttonStyle(.borderless)` and `.buttonStyle(.link)` — the quiet section and panel actions.
///   `.plain` and the default style render fine.
/// - `DatePicker`, in **every** style — the two pickers on `SessionEditSheet`. `.field` and
///   `.stepperField` were both measured and both come back as the placeholder; it is an AppKit control
///   rather than a composition of shapes. The rest of that sheet photographs, so its snapshots still
///   prove the copy, the layout and both of its notice states.
/// - `Menu` with `.menuStyle(.borderlessButton)` — the active session's `Set target` control.
///
/// All of them draw correctly in the running app; they need an AppKit host that `ImageRenderer` does
/// not provide. **Do not swap them out to make a snapshot prettier** — that would trade real
/// interface quality for a photograph of it. A reviewer reading a snapshot should know that a yellow
/// block means "the camera could not see this control", not "this control is broken".
@MainActor
struct ScrollingSection<Content: View>: View {

    @Environment(\.isGalleryMode) private var isGalleryMode

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if isGalleryMode {
            // `fixedSize` vertically, then top-aligned. Both halves are load-bearing.
            //
            // A `ScrollView` proposes its content an *unbounded* height, so every child takes its ideal
            // height and nothing stretches. A plain `.frame(maxHeight: .infinity)` proposes the whole
            // snapshot frame instead, and a `VStack` hands the surplus to whichever child is flexible.
            // Session detail showed exactly that: one 46-minute episode row whose 3pt leading rail —
            // a `Rectangle`, so infinitely flexible — was stretched 570pt down the page because the
            // frame was 600pt taller than the content. It read as a broken screen and was a broken
            // camera. `fixedSize` restores the scroll view's proposal; the outer frame then only
            // positions the result.
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView { content }
        }
    }
}
