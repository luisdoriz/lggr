import SwiftUI

/// The empty-state anatomy every screen reuses. See `04-screens.md` § 3.1.
///
/// ```
///         ⟨28pt SF Symbol, .tertiary⟩
///
///            Title sentence            ← Type.rowTitle, .primary
///     One calm line of explanation.    ← Type.body, .secondary, max 2 lines
///         [ Primary action ⌘X ]        ← only when there is one obvious next step
/// ```
///
/// Centred in the available space, `Space.hero` of air above and below, text no wider than 340pt.
/// **No illustrations.** One symbol, two lines, at most one button.
///
/// All copy is a parameter, and the copy is warm, brief, factual, and never implies the user has
/// failed to do something. An empty screen in Lggr is a fact, not a scolding.
public struct EmptyStateView: View {
    private let symbol: String
    private let title: String
    private let message: String
    private let action: EmptyStateAction?

    public init(
        symbol: String,
        title: String,
        message: String,
        action: EmptyStateAction? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    /// Convenience for the common shape: a symbol, two lines, and one button.
    public init(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String,
        shortcut: KeyboardShortcut? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            symbol: symbol,
            title: title,
            message: message,
            action: EmptyStateAction(title: actionTitle, shortcut: shortcut, perform: action)
        )
    }

    public var body: some View {
        VStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: Layout.emptyStateSymbolSize, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
                .padding(.bottom, Space.xs)

            Text(title)
                .font(Type.rowTitle)
                .foregroundStyle(.primary)

            Text(message)
                .font(Type.body)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.lggrPrimary(shortcut: action.shortcut))
                    .lggrKeyboardShortcut(action.shortcut)
                    .padding(.top, Space.s)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: Layout.emptyStateMaxTextWidth)
        .padding(.vertical, Space.hero)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(message)
    }
}

/// The single, optional next step offered by an empty state.
///
/// There is never a second one: an empty state with two buttons has not decided what the user should
/// do, and deciding is the whole job of the screen.
public struct EmptyStateAction {
    public let title: String
    public let shortcut: KeyboardShortcut?
    public let perform: () -> Void

    public init(title: String, shortcut: KeyboardShortcut? = nil, perform: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.perform = perform
    }
}
