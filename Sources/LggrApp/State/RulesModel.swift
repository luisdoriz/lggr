import Foundation
import LggrKit

// The state behind Rules (`⌘6`) and behind the correction loop. See SPEC.md §5 and
// docs/_design/04-screens.md §4.6.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  WHAT THIS OBJECT IS FOR
//
//  `ClassificationEngine` already decides everything: which rule wins, how ties break, and what a
//  correction *would* need in order to stick. None of that is re-decided here. This object does the
//  three things the domain deliberately does not:
//
//    1. holds the rule list the screen renders, in the order the store returns it;
//    2. persists edits, one whole rule at a time, and tells the truth when a write fails;
//    3. turns a correction into an **offer** — and never into a rule until the user says yes.
//
//  Point 3 is the one worth guarding. Classification in Lggr is derived, not stored: an interval
//  carries no category, so the rules are re-applied every time a day is drawn. A rule therefore does
//  not only change tomorrow — it changes how every day already on disk reads. That is why
//  `acceptOffer()` exists and why nothing else in this file writes a rule the user did not read
//  first.
// ─────────────────────────────────────────────────────────────────────────────────────────────

// MARK: - The offer

/// A rule Lggr is *proposing*, with the sentences that explain it in full before it exists.
///
/// Built by `RulesModel.offerRule(for:as:)` from `ClassificationEngine.suggestedRule`, so the offer
/// and the eventual rule are the same value — there is no second code path that could drift from the
/// one the domain sanctioned. Two properties matter beyond the rule itself:
///
/// - `subject` is what the *user* would call the thing being classified — "Slack", "github.com" —
///   taken from the activity in front of them rather than from `matchValue`, which is a bundle
///   identifier and reads like plumbing.
/// - `replacedCategory` is what the rules say today, so the sheet can state the change rather than
///   only the destination.
public struct RuleOffer: Identifiable, Hashable, Sendable {

    /// The rule as it would be saved. Not saved yet.
    public let rule: ClassificationRule
    /// The name a person would use for what this rule matches.
    public let subject: String
    /// What the rules currently make of this activity.
    public let replacedCategory: ActivityCategory
    /// True when accepting rewrites a rule the user already made rather than adding one.
    public let replacesExistingRule: Bool
    /// The rule Lggr ships that this offer supersedes, when it supersedes one.
    ///
    /// A correction on an axis a shipped rule already covers does not edit the shipped row — §4.6 is
    /// explicit that a built-in is never edited in place. Accepting makes a rule of the user's own
    /// and switches the shipped one off, which is recoverable in one action from *Reset built-in
    /// rules* and, unlike an in-place rewrite, is visible as their decision rather than as Lggr's.
    public let shadowedBuiltIn: ClassificationRule?

    public var id: UUID { rule.id }

    public init(
        rule: ClassificationRule,
        subject: String,
        replacedCategory: ActivityCategory,
        replacesExistingRule: Bool,
        shadowedBuiltIn: ClassificationRule? = nil
    ) {
        self.rule = rule
        self.subject = subject
        self.replacedCategory = replacedCategory
        self.replacesExistingRule = replacesExistingRule
        self.shadowedBuiltIn = shadowedBuiltIn
    }

    /// `04-screens.md` §4.6, verbatim: *"Always classify **Slack** as **Communication**?"*
    public var question: String {
        "Always classify \(subject) as \(rule.category.displayName)?"
    }

    /// Exactly what accepting does, in the order it matters: the new behaviour, what it replaces,
    /// and the fact that it reaches backwards.
    ///
    /// The last clause is not a warning, it is the mechanism: categories are derived from the rules
    /// every time a day is drawn, so a rule accepted today is also how last Tuesday will read. A user
    /// who is not told that cannot meaningfully agree to it.
    public var explanation: String {
        var sentences: [String] = []
        if replacesExistingRule {
            sentences.append(
                "Your existing rule for \(subject) changes from "
                    + "\(replacedCategory.displayName) to \(rule.category.displayName).")
        } else {
            sentences.append(
                "Lggr will read \(subject) as \(rule.category.displayName) instead of "
                    + "\(replacedCategory.displayName), and this rule will outrank the others that "
                    + "match it.")
        }
        if shadowedBuiltIn != nil {
            sentences.append(
                "The rule Lggr ships for \(subject) switches off in favour of yours, and the ⋯ menu "
                    + "on Rules puts it back.")
        }
        sentences.append(
            "Categories are worked out from your rules each time a day is drawn, so days already "
                + "recorded will read this way too.")
        return sentences.joined(separator: " ")
    }
}

// MARK: - Model

/// The rules, and the one place they are written.
///
/// Injectable from end to end: the screen takes this object, this object takes a store, and neither
/// reaches for a singleton. That is what lets the whole screen — including the correction sheet — be
/// exercised against an `InMemoryStore` with no files, no sampler and no window.
@MainActor
@Observable
public final class RulesModel {

    /// Where the rule list stands.
    ///
    /// `.failed` carries a sentence about the file rather than about the user, and it never invents a
    /// rule list to fill the screen with: showing `ClassificationRule.defaults` after a failed read
    /// would tell someone their own rules had been deleted.
    public enum Phase: Equatable, Sendable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    // MARK: Published state

    /// Every rule, in the order the store returned it — which is the order the screen shows and,
    /// after any move, the order the priorities agree with.
    public private(set) var rules: [ClassificationRule] = []

    public private(set) var phase: Phase = .idle

    /// A write that did not land. Surfaced inline by the screen; never an alert.
    public private(set) var lastError: String?

    /// The rule Lggr is offering to create. `nil` unless the user asked a question that has one.
    public private(set) var offer: RuleOffer?

    // MARK: Collaborators

    @ObservationIgnored private let store: any LggrStore
    @ObservationIgnored private let defaults: UserDefaults

    /// Sorted once per change rather than per classification: `ClassificationEngine.init` orders the
    /// rules, and the correction loop asks it a question on every menu that opens.
    @ObservationIgnored private var evaluator: ClassificationEngine = ClassificationEngine(rules: [])

    /// Written once, ever. Without it, "delete every rule" would be undone by the next launch —
    /// which is the exact behaviour `LggrStore.loadClassificationRules` documents as unacceptable.
    private static let seededKey = "com.lggr.rules.seeded"

    public init(store: any LggrStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    /// A model already holding `rules`, for the snapshot pass that photographs each screen in light
    /// and dark (`SnapshotMode`).
    ///
    /// Backed by an in-memory store and its own defaults suite, so nothing it does can reach the
    /// user's data folder or their preferences — the gallery renders screens, it does not record.
    public static func gallery(rules: [ClassificationRule]) -> RulesModel {
        let model = RulesModel(
            store: InMemoryStore(classificationRules: rules),
            defaults: UserDefaults(suiteName: "com.lggr.gallery") ?? .standard
        )
        model.setRules(rules)
        model.phase = .ready
        return model
    }

    // MARK: - Identity

    /// The rules Lggr ships with, by identifier.
    ///
    /// `ClassificationRule.defaults` carries fixed identifiers precisely so this comparison is
    /// possible without a stored flag: a rule is built in when Lggr shipped that row, and a rule the
    /// user made has a fresh `UUID` that can never collide with one.
    @ObservationIgnored private static let builtInIDs = Set(ClassificationRule.defaults.map(\.id))

    public static func isBuiltIn(_ rule: ClassificationRule) -> Bool {
        builtInIDs.contains(rule.id)
    }

    /// The user's own rules, in display order.
    public var userRules: [ClassificationRule] {
        rules.filter { !Self.isBuiltIn($0) }
    }

    /// The rules Lggr ships with, in display order.
    public var builtInRules: [ClassificationRule] {
        rules.filter { Self.isBuiltIn($0) }
    }

    /// Whether any shipped rule differs from the value Lggr ships, or has been deleted outright.
    /// Drives whether *Reset built-in rules* is offered at all.
    public var canResetBuiltInRules: Bool {
        ClassificationRule.defaults.contains { shipped in
            rules.first { $0.id == shipped.id } != shipped
        }
    }

    /// The engine the screen uses to answer "what would this be called right now".
    public var engine: ClassificationEngine { evaluator }

    // MARK: - Loading

    /// Reads the rules, seeding the shipped defaults on the very first launch and never again.
    ///
    /// Idempotent and re-entrant-safe: it is called from the window's `.task`, and again by the
    /// *Try again* button after a failed read.
    public func load() async {
        guard phase != .loading else { return }
        phase = .loading
        do {
            var loaded = try await store.loadClassificationRules()
            if loaded.isEmpty, !defaults.bool(forKey: Self.seededKey) {
                // Seeded exactly as shipped, which includes the window-title rule arriving
                // **disabled** (`ClassificationRule.defaults`, and INTELLIGENCE.md §3.3): a title
                // rule Lggr switched on by itself would be the app matching titles against a string
                // nobody typed. It sits in the editor as a worked example, one toggle away.
                for rule in ClassificationRule.defaults {
                    try await store.saveClassificationRule(rule)
                }
                defaults.set(true, forKey: Self.seededKey)
                loaded = try await store.loadClassificationRules()
            }
            setRules(loaded)
            phase = .ready
        } catch {
            phase = .failed(
                "Your rules could not be read. Nothing has been changed or deleted — the file is "
                    + "still there.")
        }
    }

    public func dismissError() {
        lastError = nil
    }

    // MARK: - Editing

    /// Saves a rule, adding it or replacing the one that shares its identifier.
    ///
    /// The list updates first and the disk second, because the user is looking at the list. A failed
    /// write is corrected by re-reading rather than by leaving the optimistic row in place: a rule
    /// that appears to exist and does not is worse than an error message.
    public func save(_ rule: ClassificationRule) async {
        guard rule.isWellFormed else { return }
        setRules(upserting(rule))
        await write(rule, failure: "That rule could not be saved.")
    }

    public func delete(id: UUID) async {
        setRules(rules.filter { $0.id != id })
        do {
            try await store.deleteClassificationRule(id: id)
        } catch {
            lastError = "That rule could not be deleted."
            await reload()
        }
    }

    /// Toggling is its own method rather than a `save` at the call site so that the checkbox on a
    /// built-in row cannot accidentally rewrite anything else about a rule the user cannot edit.
    public func setEnabled(_ isEnabled: Bool, for rule: ClassificationRule) async {
        guard rule.isEnabled != isEnabled else { return }
        var updated = rule
        updated.isEnabled = isEnabled
        await save(updated)
    }

    /// A copy of `rule` under the user's ownership, ready for the editor.
    ///
    /// `04-screens.md` §4.6: a built-in rule can be toggled but not edited; editing one *creates a
    /// user rule that shadows it, with `priority` copied +5*, and switches the original off. The
    /// copy is returned rather than saved, so the shadow only exists if the user presses Save.
    ///
    /// `isEnabled` is copied rather than forced to `true`. The one shipped rule that arrives
    /// disabled is the window-title example, and a shadow that quietly switched it on would be the
    /// app enabling title matching on the user's behalf.
    public func shadowCopy(of rule: ClassificationRule) -> ClassificationRule {
        ClassificationRule(
            matchType: rule.matchType,
            matchValue: rule.matchValue,
            category: rule.category,
            projectID: rule.projectID,
            priority: rule.priority + 5,
            isEnabled: rule.isEnabled
        )
    }

    /// Saves a shadow and switches off the shipped rule it replaces, in that order.
    ///
    /// Order matters on a failed write: with the shadow saved first, the worst outcome is two rules
    /// saying the same thing, and the user's own one wins. Disabling first would risk a moment — or a
    /// launch — with neither.
    public func adoptShadow(_ shadow: ClassificationRule, replacing original: ClassificationRule) async {
        await save(shadow)
        guard lastError == nil, original.isEnabled else { return }
        await setEnabled(false, for: original)
    }

    /// Duplicates a rule as a new, disabled row directly below the original.
    ///
    /// Disabled on purpose: two enabled rules with the same condition and different answers is a
    /// rule set that cannot be read, and a duplicate exists to be edited before it does anything.
    public func duplicate(_ rule: ClassificationRule) async {
        let copy = ClassificationRule(
            matchType: rule.matchType,
            matchValue: rule.matchValue,
            category: rule.category,
            projectID: rule.projectID,
            priority: rule.priority,
            isEnabled: false
        )
        setRules(rules + [copy])
        await write(copy, failure: "That rule could not be duplicated.")
    }

    // MARK: - Priority

    /// Moves a user rule one place up the list and gives it the priority that position implies.
    public func moveUp(_ rule: ClassificationRule) async {
        await move(rule, by: -1)
    }

    public func moveDown(_ rule: ClassificationRule) async {
        await move(rule, by: 1)
    }

    public func canMoveUp(_ rule: ClassificationRule) -> Bool {
        guard let index = userRules.firstIndex(of: rule) else { return false }
        return index > 0
    }

    public func canMoveDown(_ rule: ClassificationRule) -> Bool {
        guard let index = userRules.firstIndex(of: rule) else { return false }
        return index < userRules.count - 1
    }

    /// Sorts the user's rules into the order the engine actually evaluates them, then renumbers so
    /// the list and the engine agree from then on. `04-screens.md` §4.6's `⋯` menu item.
    ///
    /// This exists because the two orders can legitimately diverge: the list is insertion order, and
    /// a hand-edited `priority` does not move a row. Rather than silently re-sorting the screen out
    /// from under someone, the alignment is an action they take.
    public func reorderByPriority() async {
        let ordered = ClassificationEngine(rules: userRules).rules
        await applyLadder(to: ordered)
    }

    /// Restores every shipped rule to the value Lggr ships, including the window-title rule's
    /// disabled state. The user's own rules are untouched.
    public func resetBuiltInRules() async {
        var next = rules.filter { !Self.isBuiltIn($0) }
        next.insert(contentsOf: ClassificationRule.defaults, at: 0)
        setRules(next)
        for rule in ClassificationRule.defaults {
            await write(rule, failure: "The built-in rules could not be restored.")
            if lastError != nil { break }
        }
    }

    // MARK: - The correction loop

    /// What the rules currently make of `context`.
    public func category(for context: ActivityContext) -> ActivityCategory {
        evaluator.classify(context).category
    }

    /// Prepares — and does not save — the rule that would make `category` stick.
    ///
    /// SPEC §5: *"The user should be able to correct a classification, and the app should offer to
    /// create a reusable rule."* This is the offering half, and the offer is all it is. Returns `nil`
    /// when there is nothing to learn: the rules already answer `category`, or the activity has no
    /// axis that may legally be written down.
    ///
    /// **The offer can never be a window-title rule.** `ClassificationEngine.suggestedRule` refuses
    /// to derive one, because `matchValue` is written to disk and a value derived from an observed
    /// title would put that title in a file (`INTELLIGENCE.md` §3.3). A title rule is something the
    /// user types into the editor, and this path cannot produce one no matter what misfired.
    @discardableResult
    public func offerRule(for context: ActivityContext, as category: ActivityCategory) -> RuleOffer? {
        let current = evaluator.classify(context)
        guard var suggested = evaluator.suggestedRule(for: context, correctedTo: category) else {
            offer = nil
            return nil
        }

        // The engine's suggestion edits whatever rule already states this axis, so that two rules
        // cannot end up making contradictory claims about the same condition. When that rule is one
        // Lggr ships, the edit becomes a rule of the user's own that outranks it and switches it off —
        // §4.6 does not allow a built-in to be changed in place, and a shipped row that quietly stopped
        // saying what it shipped saying would make *Reset built-in rules* the only way to find out.
        let existing = rules.first { $0.id == suggested.id }
        var shadowed: ClassificationRule?
        if let existing, Self.isBuiltIn(existing) {
            shadowed = existing
            suggested = ClassificationRule(
                matchType: suggested.matchType,
                matchValue: suggested.matchValue,
                category: suggested.category,
                projectID: suggested.projectID,
                priority: max(suggested.priority, existing.priority + 5),
                isEnabled: true
            )
        }

        let proposal = RuleOffer(
            rule: suggested,
            subject: Self.subject(of: suggested, in: context),
            replacedCategory: current.category,
            replacesExistingRule: existing != nil && shadowed == nil,
            shadowedBuiltIn: shadowed
        )
        offer = proposal
        return proposal
    }

    /// Writes the offered rule. The only path in this object that creates a rule from a correction,
    /// and it runs only from the sheet's *Create rule* button.
    public func acceptOffer() async {
        guard let offer else { return }
        self.offer = nil
        if let original = offer.shadowedBuiltIn {
            await adoptShadow(offer.rule, replacing: original)
        } else {
            await save(offer.rule)
        }
    }

    /// *Not now.* Nothing is written and nothing is remembered — the day the user was looking at
    /// keeps the category the rules give it, and they are not asked again unless they ask.
    public func declineOffer() {
        offer = nil
    }

    /// What a person calls the thing a rule matches.
    ///
    /// The activity's own display name is preferred for an application rule, because `matchValue` is
    /// a bundle identifier: *"Always classify com.tinyspeck.slackmacgap as Communication?"* is a
    /// question about plumbing, and the user is being asked about Slack.
    private static func subject(of rule: ClassificationRule, in context: ActivityContext) -> String {
        switch rule.matchType {
        case .application:
            let name = context.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? rule.matchValue : name
        case .browserDomain, .windowTitleContains, .project, .workType:
            return rule.matchValue
        }
    }

    // MARK: - Plumbing

    private func setRules(_ next: [ClassificationRule]) {
        rules = next
        evaluator = ClassificationEngine(rules: next)
    }

    private func upserting(_ rule: ClassificationRule) -> [ClassificationRule] {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else {
            return rules + [rule]
        }
        var next = rules
        next[index] = rule
        return next
    }

    private func write(_ rule: ClassificationRule, failure: String) async {
        do {
            try await store.saveClassificationRule(rule)
        } catch {
            lastError = failure
            await reload()
        }
    }

    /// Re-reads after a failed write, so the screen shows what is actually stored rather than what
    /// was attempted.
    private func reload() async {
        guard let loaded = try? await store.loadClassificationRules() else { return }
        setRules(loaded)
    }

    private func move(_ rule: ClassificationRule, by offset: Int) async {
        var ordered = userRules
        guard let index = ordered.firstIndex(of: rule) else { return }
        let destination = index + offset
        guard ordered.indices.contains(destination) else { return }
        ordered.swapAt(index, destination)
        await applyLadder(to: ordered)
    }

    /// Gives `ordered` a clean descending priority ladder — first row highest — and persists only the
    /// rules whose numbers actually changed.
    ///
    /// The ladder starts at 10 and steps by 10 for two reasons: every rung stays strictly above
    /// `ClassificationRule.shippedPriority`, so a rule the user made always outranks one Lggr
    /// shipped without anybody having to understand the number; and the gaps leave room to type a
    /// priority by hand in the editor without renumbering the world.
    private func applyLadder(to ordered: [ClassificationRule]) async {
        let step = 10
        var renumbered: [ClassificationRule] = []
        var changed: [ClassificationRule] = []

        for (index, rule) in ordered.enumerated() {
            var updated = rule
            updated.priority = (ordered.count - index) * step
            renumbered.append(updated)
            if updated.priority != rule.priority { changed.append(updated) }
        }

        // Display order is the user's rules in their new order, followed by the shipped ones. The
        // two groups are drawn as separate sections, so their relative position in the array is
        // presentation only — the engine reads `priority`, never this.
        setRules(renumbered + rules.filter { Self.isBuiltIn($0) })

        for rule in changed {
            await write(rule, failure: "The new order could not be saved.")
            if lastError != nil { break }
        }
    }
}
