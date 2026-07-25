import SwiftUI

// The main window's sidebar. See docs/_design/04-screens.md § 1.2.
//
// Three decisions this file exists to hold still:
//
//   • **No per-section tint.** A seven-colour sidebar is the single fastest way to look like
//     enterprise software. Selection is the system highlight and nothing else.
//   • **No live number.** When a session is running the Today row shows one 6pt dot. The counting
//     digits live in exactly two places — the menu bar and Today itself. A sidebar that reprints
//     itself once a second is the opposite of calm.
//   • **No custom row height.** `.listStyle(.sidebar)` already knows what a sidebar row is.

/// The 6pt filled circle on the Today row while a session is in flight (`04-screens.md` § 1.2).
///
/// Not in `Layout` because it appears once, in this file, and a token used in one place is a lookup
/// with no payoff. It does not pulse, does not animate in, and does not count down.
private let runningIndicatorSize: CGFloat = 6

/// The seven sections, as a selectable list.
///
/// Takes its selection as a `Binding` and the running flag as a plain `Bool`, so it renders in the
/// gallery against nothing at all.
public struct Sidebar: View {

    @Binding private var selection: SidebarSection
    private let isSessionRunning: Bool

    public init(selection: Binding<SidebarSection>, isSessionRunning: Bool = false) {
        self._selection = selection
        self.isSessionRunning = isSessionRunning
    }

    public var body: some View {
        List(selection: listSelection) {
            ForEach(SidebarSection.allCases) { section in
                SidebarRow(
                    section: section,
                    // The dot belongs to Today because Today is where the session lives.
                    isRunning: section == .today && isSessionRunning
                )
                .tag(section)
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Sections")
    }

    /// `List` selection is optional; ours is not — there is always a selected room.
    ///
    /// Clearing the selection (⌘-click on the selected row) therefore leaves it where it was rather
    /// than emptying the detail column, which has nothing useful to show.
    private var listSelection: Binding<SidebarSection?> {
        Binding(
            get: { selection },
            set: { newValue in
                guard let newValue else { return }
                selection = newValue
            }
        )
    }
}

// MARK: - Row

/// `⟨18pt symbol⟩  Title                    ●`
///
/// The symbol sits in a fixed-width column so the labels align even though the glyphs differ.
struct SidebarRow: View {

    let section: SidebarSection
    let isRunning: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: section.symbolName)
                .imageScale(.medium)
                .frame(width: Layout.symbolColumnWidth, alignment: .center)
                .accessibilityHidden(true)

            Text(section.title)
                .lineLimit(1)

            Spacer(minLength: Space.s)

            if isRunning {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: runningIndicatorSize, height: runningIndicatorSize)
                    .help("A focus session is running")
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(section.title)
        .accessibilityValue(isRunning ? "A focus session is running" : "")
    }
}
