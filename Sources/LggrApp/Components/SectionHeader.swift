import SwiftUI

/// A section heading on the bare canvas: `Type.sectionTitle`, an optional count, and an optional
/// trailing borderless action.
///
/// This is the alternative to a card. Sections on Today, Weekly Review and every list screen are
/// headed lists separated by `Space.xxl`, not boxes — see `Card`'s documentation for why.
///
/// The count renders as `Interruptions · 2`, matching the copy in `04-screens.md` § 4.
public struct SectionHeader<Accessory: View>: View {
    private let title: String
    private let count: Int?
    private let accessory: Accessory

    public init(_ title: String, count: Int? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.count = count
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(title)
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)
            if let count {
                Text(verbatim: "· \(count)")
                    .font(Type.sectionTitle)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: Space.s)
            accessory
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
}

extension SectionHeader where Accessory == EmptyView {
    /// A heading with no trailing action.
    public init(_ title: String, count: Int? = nil) {
        self.init(title, count: count) { EmptyView() }
    }
}

extension SectionHeader where Accessory == SectionAction {
    /// A heading with the one borderless action that belongs to the section — `Add`, `Review`,
    /// `Export`. One action, never two: a heading with a toolbar is a card that lost its border.
    public init(
        _ title: String,
        count: Int? = nil,
        actionTitle: String,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) {
        self.init(title, count: count) {
            SectionAction(title: actionTitle, shortcut: shortcut, action: action)
        }
    }
}

/// The borderless trailing button of a `SectionHeader`. Quiet by construction: it is a section's
/// action, not the screen's primary action.
public struct SectionAction: View {
    private let title: String
    private let shortcut: KeyboardShortcut?
    private let action: () -> Void

    public init(title: String, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Text(title)
                if let shortcut {
                    ShortcutHint(shortcut)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(Type.secondary)
        }
        .buttonStyle(.borderless)
        .lggrKeyboardShortcut(shortcut)
    }
}
