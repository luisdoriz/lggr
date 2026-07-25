import SwiftUI

/// A raised surface with a hairline: `Surface.raised`, `Radius.card`, `Stroke.card`.
///
/// **Use a card only where it improves hierarchy.** The rule, from `04-screens.md` § 2 and § 9:
/// space before lines, lines before boxes, boxes before colour. Reach for `Space.xxl` of air first,
/// a `Divider()` second, and a card only third.
///
/// Concretely, a card means *"this container has its own primary action"*. In the whole application
/// there are two of them:
///
///   * the active-session block on Today, whose primary action is Finish;
///   * the running-session block in the menu bar popover, same reason.
///
/// Everything else — Accomplishments, Time allocation, Day, Interruptions, every list on every other
/// screen — is a headed list on the bare canvas. A Today made of six cards is a dashboard, and a
/// dashboard is the thing we are explicitly not building. If you are reaching for a second card on a
/// screen, the answer is `SectionHeader` and more space.
///
/// The fill and the stroke are drawn on the *same* rounded rectangle, which is what keeps the
/// hairline crisp instead of blurring it across a half-pixel mismatch.
public struct Card<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    public init(padding: CGFloat = Space.l, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.raised, in: Theme.cardShape)
            .overlay(Theme.cardShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
    }
}
