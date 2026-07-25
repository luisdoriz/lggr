import LggrKit
import SwiftUI

// The correction loop. See SPEC.md §5 and docs/_design/04-screens.md §4.6.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHY THIS IS A SHEET AND NOT A SILENT WRITE
//
//  SPEC §5 asks for two things in one sentence: the user can correct a classification, and the app
//  *offers* to create a reusable rule. The offer is the load-bearing word. Categories in Lggr are
//  derived, never stored — the rules are re-applied every time a day is drawn — so a rule is not a
//  preference that starts applying tomorrow, it is a change to how every day already recorded reads.
//  An app that wrote one from a single correction would be quietly rewriting the user's history on the
//  strength of a menu click.
//
//  So the flow is: the user picks a category from a menu, this sheet states exactly what the rule
//  would do and what it changes, and one click creates it. `Not now` writes nothing.
//
//  Nothing here can produce a window-title rule. `ClassificationEngine.suggestedRule` refuses to
//  derive one, because `matchValue` is written to disk and a value taken from a title Lggr observed
//  would put that title in a file — the one thing `INTELLIGENCE.md` §3.3 exists to prevent. Title
//  rules are typed by hand in `RuleEditor`, which says so on screen.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// MARK: - The sheet

/// *Always classify **Slack** as **Communication**?* — with what that means, and two ways out.
@MainActor
public struct ReclassifySheet: View {

    private let offer: RuleOffer
    private let projects: [Project]
    private let onCreate: () -> Void
    private let onNotNow: () -> Void

    public init(
        offer: RuleOffer,
        projects: [Project],
        onCreate: @escaping () -> Void,
        onNotNow: @escaping () -> Void
    ) {
        self.offer = offer
        self.projects = projects
        self.onCreate = onCreate
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(question)
                .font(Type.sectionTitle)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            // The rule itself, worded exactly as the Rules screen will word it. The user is agreeing
            // to a row they can go and find, not to a promise.
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Image(systemName: offer.rule.category.symbolName)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(RuleSentence.full(offer.rule, projects: projects))
                    .font(Type.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.sunken, in: Theme.panelShape)
            // The hairline, because `Surface.sunken` is the same colour as the canvas in light mode:
            // without it the panel is invisible in one appearance and a box in the other.
            .overlay(Theme.panelShape.strokeBorder(Stroke.card, lineWidth: Layout.hairline))
            .accessibilityElement(children: .combine)

            Text(offer.explanation)
                .font(Type.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.m) {
                Button("Not now", action: onNotNow)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: Space.m)
                Button("Create rule", action: onCreate)
                    .buttonStyle(.lggrPrimary(shortcut: Self.createShortcut))
                    .keyboardShortcut(Self.createShortcut)
            }
        }
        .padding(Space.xl)
        .frame(width: Layout.ruleOfferWidth)
        .background(Surface.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question)
    }

    private static let createShortcut = KeyboardShortcut(.return, modifiers: .command)

    /// §4.6's copy, verbatim. Built through `RuleOffer` so the sheet and any other surface asking the
    /// same question ask it in the same words.
    private var question: String { offer.question }
}

// MARK: - The menu that raises it

/// *Always classify Slack as ▸* — the submenu a timeline block offers.
///
/// The category currently in force is absent rather than shown and disabled: picking the answer you
/// already have is not an action, and a menu whose first item does nothing is a menu that has to be
/// read twice. `.unknown` is absent for the same reason — it is what an activity is called when no
/// rule matched, so choosing it as an outcome states nothing.
@MainActor
public struct ReclassifyMenu: View {

    private let subject: String
    private let current: ActivityCategory
    private let onPick: (ActivityCategory) -> Void

    public init(
        subject: String,
        current: ActivityCategory,
        onPick: @escaping (ActivityCategory) -> Void
    ) {
        self.subject = subject
        self.current = current
        self.onPick = onPick
    }

    public var body: some View {
        Menu("Always classify \(subject) as") {
            ForEach(options) { option in
                Button {
                    onPick(option)
                } label: {
                    Label(option.displayName, systemImage: option.symbolName)
                }
            }
        }
    }

    /// Every category except the one in force and the fallback, in the order `ActivityCategory`
    /// declares them.
    ///
    /// `.distraction` is in this list, unmarked and unstyled, sitting between Administrative and
    /// nothing at all. `ActivityCategory.distraction`'s own documentation is explicit about what the
    /// UI may not do with it: no warning glyph, no red, no framing that calls the user's afternoon a
    /// loss. It is a bucket a rule can put time into, and here it is a menu item like the other nine.
    private var options: [ActivityCategory] {
        ActivityCategory.allCases.filter { $0 != current && $0 != .unknown }
    }
}

// MARK: - Reaching the loop from a timeline block

/// What a surface showing classified activity needs in order to offer a correction: a way to ask what
/// the rules currently say, and a way to raise the offer.
///
/// Two closures rather than the model itself, so a timeline row depends on the *question* and not on
/// `RulesModel` — and so the whole flow can be driven from a test with two closures and no store.
@MainActor
public struct RuleCorrectionScope {

    /// What the rules make of this activity right now.
    public let category: (ActivityContext) -> ActivityCategory
    /// Raise the offer. Writes nothing on its own.
    public let offer: (ActivityContext, ActivityCategory) -> Void

    public init(
        category: @escaping (ActivityContext) -> ActivityCategory,
        offer: @escaping (ActivityContext, ActivityCategory) -> Void
    ) {
        self.category = category
        self.offer = offer
    }
}

private struct RuleCorrectionKey: EnvironmentKey {
    /// Optional, and `nil` by default, for the reason every reference-type key in
    /// `EnvironmentValues+Lggr.swift` is: `defaultValue` is read from a nonisolated context and there
    /// is no main-actor value to hand back. `nil` also means "nothing wired this up", which is what
    /// lets the context menu be *absent* rather than present and inert.
    static var defaultValue: RuleCorrectionScope? { nil }
}

extension EnvironmentValues {
    public var ruleCorrection: RuleCorrectionScope? {
        get { self[RuleCorrectionKey.self] }
        set { self[RuleCorrectionKey.self] = newValue }
    }
}

/// Adds *Always classify … as ▸* to a row that stands for time spent in one application.
///
/// Applied as a modifier rather than written into each row so that the three conditions under which
/// there is no menu — nothing wired up, no application to name, or an application the user marked
/// private — are decided in one place, and so the row itself gains no context menu at all in those
/// cases instead of gaining an empty one.
private struct ReclassifyContextMenu: ViewModifier {

    let bundleIdentifier: String
    let displayName: String

    @Environment(\.ruleCorrection) private var correction

    func body(content: Content) -> some View {
        if let correction, let context {
            content.contextMenu {
                ReclassifyMenu(
                    subject: subject,
                    current: correction.category(context),
                    onPick: { correction.offer(context, $0) }
                )
            }
        } else {
            content
        }
    }

    /// `nil` when there is nothing a rule could legally match.
    ///
    /// A private application is the case worth naming: its identity was replaced with the single word
    /// "Private" *before* the file was written, so there is no application here to write a rule about
    /// — and offering one would imply Lggr still knows which application it was.
    private var context: ActivityContext? {
        let identifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !identifier.isEmpty,
            identifier.lowercased() != ActivitySampler.privateBundleIdentifier
        else { return nil }
        return ActivityContext(bundleIdentifier: identifier, displayName: displayName)
    }

    private var subject: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? bundleIdentifier : name
    }
}

extension View {

    /// Offers the correction loop on a row that represents one application's time.
    public func reclassifiable(bundleIdentifier: String, displayName: String) -> some View {
        modifier(
            ReclassifyContextMenu(bundleIdentifier: bundleIdentifier, displayName: displayName))
    }

    /// Installs the correction loop for every row below this point in the tree.
    public func ruleCorrection(_ scope: RuleCorrectionScope?) -> some View {
        environment(\.ruleCorrection, scope)
    }
}
