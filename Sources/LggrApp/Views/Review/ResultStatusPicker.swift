import SwiftUI
import LggrKit

// The one required field of the review sheet. See docs/_design/04-screens.md § 5.3 and § 8.2.
//
// Five options, all visible, all one keystroke away. Not a `Picker`, not a menu, not a segmented
// control: this is the question the sheet exists to ask, and hiding four fifths of the answer behind
// a disclosure triangle to save 30 points of height would be the wrong trade.
//
// **None of the five is coloured differently from the others.** A red "Blocked" next to a green
// "Completed" turns an honest report into a grade, and people stop reporting accurately about two
// days after they notice. Selection is the accent colour whichever option is chosen.

/// The five `SessionResultStatus` options as chips.
///
/// Keyboard, per § 5.3 and § 7.1: `1`–`5` selects an option directly, `←`/`→` moves the selection.
/// Two keystrokes — a digit and `⌘⏎` — complete the entire review, which is the whole reason the
/// sheet is not a form.
///
/// Selection is optional because the sheet opens with no answer and `Save` stays disabled until there
/// is one. Disabled is a quieter fill, never a red asterisk (§ 5.2).
public struct ResultStatusPicker: View {

    @Binding private var selection: SessionResultStatus?

    /// Which chip the mouse is over. Hover and keyboard selection use different fills on purpose
    /// (§ 8.6), so the two inputs can never contradict each other on screen.
    @State private var hovered: SessionResultStatus?

    private static let options = SessionResultStatus.allCases
    private static let digits = CharacterSet(charactersIn: "12345")

    public init(selection: Binding<SessionResultStatus?>) {
        self._selection = selection
    }

    public var body: some View {
        // § 8.3: five across, then three plus two, then one per line. The layout degrades before the
        // text does, because the option names are the content.
        ViewThatFits(in: .horizontal) {
            row(Self.options)

            VStack(alignment: .leading, spacing: Space.s) {
                row(Array(Self.options.prefix(3)))
                row(Array(Self.options.dropFirst(3)))
            }

            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Self.options) { chip($0) }
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: move(by: -1)
            case .right: move(by: 1)
            default: break
            }
        }
        .onKeyPress(characters: Self.digits, phases: .down) { press in
            guard
                let character = press.characters.first,
                let index = Int(String(character)),
                Self.options.indices.contains(index - 1)
            else { return .ignored }
            select(Self.options[index - 1])
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What happened")
    }

    // MARK: - Pieces

    private func row(_ options: [SessionResultStatus]) -> some View {
        HStack(spacing: Space.s) {
            ForEach(options) { chip($0) }
        }
    }

    private func chip(_ status: SessionResultStatus) -> some View {
        let isSelected = selection == status
        let isHovered = hovered == status

        return Button {
            select(status)
        } label: {
            HStack(spacing: Space.xs) {
                Image(systemName: status.symbolName)
                    .imageScale(.small)
                Text(status.displayName)
                    .lineLimit(1)
            }
            .font(Type.secondary)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(fill(isSelected: isSelected, isHovered: isHovered), in: Theme.chipShape)
            .overlay(
                Theme.chipShape.strokeBorder(
                    isSelected ? Color.accentColor : Stroke.card,
                    lineWidth: Layout.hairline
                )
            )
            .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                hovered = status
            } else if hovered == status {
                hovered = nil
            }
        }
        .lggrAnimation(Motion.tap, value: isSelected)
        .lggrAnimation(Motion.tap, value: isHovered)
        .accessibilityLabel(status.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Resting chips carry a hairline and no fill. Boxes before colour, and colour only for the one
    /// that has been chosen (`04-screens.md` § 2).
    private func fill(isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected { return Surface.selected }
        return isHovered ? Surface.hover : Color.clear
    }

    // MARK: - Selection

    private func select(_ status: SessionResultStatus) {
        selection = status
    }

    /// `←`/`→` changes the value directly, which is what § 7.1 specifies for every segmented control
    /// in the application. Carrying a separate highlight that `Space` then commits would make this
    /// the one control in Lggr where the arrow keys do not change anything.
    private func move(by offset: Int) {
        guard let current = selection, let index = Self.options.firstIndex(of: current) else {
            selection = offset < 0 ? Self.options.last : Self.options.first
            return
        }
        let next = index + offset
        guard Self.options.indices.contains(next) else { return }
        selection = Self.options[next]
    }
}
