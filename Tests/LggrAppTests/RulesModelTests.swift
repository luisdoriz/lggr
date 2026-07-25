import Foundation
import Testing

@testable import LggrApp
@testable import LggrKit

/// `RulesModel` — the rule list, and the correction loop SPEC §5 asks for.
///
/// Everything below is asserted rather than read off the code, because three of these properties are
/// promises the product makes in prose and would break silently:
///
///   * the shipped window-title rule arrives **disabled** (`INTELLIGENCE.md` §3.3);
///   * a correction never *creates* a rule, it only ever offers one (SPEC §5);
///   * an offer can never be a window-title rule, however the misclassification arose.

// MARK: - Helpers

/// A fresh model over an empty store, with its own defaults suite so the one-shot seed flag cannot
/// leak between tests or into the developer's real preferences.
@MainActor
private func makeModel(
    rules: [ClassificationRule] = [],
    seeded: Bool = false
) -> (RulesModel, InMemoryStore) {
    let store = InMemoryStore(classificationRules: rules)
    let suite = UserDefaults(suiteName: "com.lggr.tests.rules.\(UUID().uuidString)") ?? .standard
    suite.set(seeded, forKey: "com.lggr.rules.seeded")
    return (RulesModel(store: store, defaults: suite), store)
}

private let slack = "com.tinyspeck.slackmacgap"

@MainActor
private func slackContext(name: String = "Slack") -> ActivityContext {
    ActivityContext(bundleIdentifier: slack, displayName: name)
}

// MARK: - Loading and seeding

@Suite("RulesModel — loading")
@MainActor
struct RulesModelLoadingTests {

    @Test("A first launch seeds every rule Lggr ships with")
    func firstLaunchSeedsDefaults() async throws {
        let (model, store) = makeModel()
        await model.load()

        #expect(model.phase == .ready)
        #expect(model.rules.count == ClassificationRule.defaults.count)
        #expect(store.classificationRules.count == ClassificationRule.defaults.count)
        #expect(model.userRules.isEmpty)
        #expect(model.builtInRules.count == ClassificationRule.defaults.count)
    }

    /// `INTELLIGENCE.md` §3.3: a title rule matches against a string the user typed. Lggr switching one
    /// on by itself would be the app matching titles against a string nobody wrote, so the shipped
    /// example arrives off and seeding must not quietly change that.
    @Test("The shipped window-title rule arrives switched off")
    func shippedTitleRuleArrivesDisabled() async throws {
        let (model, _) = makeModel()
        await model.load()

        let titleRules = model.rules.filter { $0.matchType == .windowTitleContains }
        #expect(!titleRules.isEmpty)
        #expect(titleRules.allSatisfy { !$0.isEnabled })
    }

    /// The store's own documentation makes this a requirement: substituting the defaults for an empty
    /// set would make "delete every rule" impossible.
    @Test("Deleting every rule survives the next load")
    func anEmptyRuleSetIsNotReseeded() async throws {
        let (model, store) = makeModel(seeded: true)
        await model.load()

        #expect(model.rules.isEmpty)
        #expect(store.classificationRules.isEmpty)
        #expect(model.phase == .ready)
    }

    @Test("Rules the user made are told apart from the ones Lggr ships")
    func userRulesAreDistinguishedFromBuiltIns() async throws {
        let mine = ClassificationRule(
            matchType: .browserDomain, matchValue: "figma.com", category: .planning, priority: 20)
        let (model, _) = makeModel(rules: ClassificationRule.defaults + [mine], seeded: true)
        await model.load()

        #expect(model.userRules == [mine])
        #expect(model.builtInRules.count == ClassificationRule.defaults.count)
        #expect(RulesModel.isBuiltIn(mine) == false)
    }
}

// MARK: - The correction loop

@Suite("RulesModel — the correction loop")
@MainActor
struct RulesModelCorrectionTests {

    @Test("A correction is offered, never applied")
    func aCorrectionIsOfferedAndNothingIsWritten() async throws {
        let (model, store) = makeModel()
        await model.load()

        let offer = try #require(model.offerRule(for: slackContext(), as: .planning))

        #expect(offer.rule.matchType == .application)
        #expect(offer.rule.matchValue == slack)
        #expect(offer.rule.category == .planning)
        #expect(model.offer == offer)
        // The whole point: nothing reached the store, and the rule list is unchanged.
        #expect(store.classificationRules.count == ClassificationRule.defaults.count)
        #expect(model.userRules.isEmpty)
    }

    @Test("The offer names what the user calls the application, not its bundle identifier")
    func theOfferIsWordedForAPerson() async throws {
        let (model, _) = makeModel()
        await model.load()

        let offer = try #require(model.offerRule(for: slackContext(), as: .planning))

        #expect(offer.subject == "Slack")
        #expect(offer.question == "Always classify Slack as Planning?")
        #expect(offer.replacedCategory == .communication)
        #expect(offer.explanation.contains("Planning"))
        // The user is told the rule reaches backwards, because categories are derived on every draw.
        #expect(offer.explanation.contains("days already recorded"))
    }

    @Test("Accepting writes exactly one rule; Not now writes none")
    func acceptingWritesTheRuleAndDecliningWritesNothing() async throws {
        let (model, store) = makeModel()
        await model.load()
        let shipped = store.classificationRules.count

        _ = model.offerRule(for: slackContext(), as: .planning)
        model.declineOffer()
        #expect(model.offer == nil)
        #expect(store.classificationRules.count == shipped)

        _ = model.offerRule(for: slackContext(), as: .planning)
        await model.acceptOffer()

        #expect(model.offer == nil)
        #expect(store.classificationRules.count == shipped + 1)
        #expect(model.userRules.count == 1)
        #expect(model.category(for: slackContext()) == .planning)
    }

    /// The correction happens to land on an axis a shipped rule already covers, which is the common
    /// case. §4.6 forbids editing a built-in in place, so accepting makes a rule of the user's own and
    /// switches the shipped one off — recoverable in one action, and legible as the user's decision.
    @Test("A correction over a shipped rule shadows it instead of rewriting it")
    func aCorrectionShadowsAShippedRule() async throws {
        let (model, _) = makeModel()
        await model.load()

        let shipped = try #require(model.builtInRules.first { $0.matchValue == slack })
        let offer = try #require(model.offerRule(for: slackContext(), as: .planning))

        #expect(offer.shadowedBuiltIn == shipped)
        #expect(offer.replacesExistingRule == false)
        #expect(offer.rule.id != shipped.id)
        #expect(offer.explanation.contains("switches off in favour of yours"))

        await model.acceptOffer()

        #expect(model.userRules.count == 1)
        #expect(model.rules.first { $0.id == shipped.id }?.isEnabled == false)
        #expect(model.canResetBuiltInRules)
        #expect(model.category(for: slackContext()) == .planning)
    }

    @Test("There is nothing to offer when the rules already say so")
    func noOfferWhenTheRulesAlreadyAgree() async throws {
        let (model, _) = makeModel()
        await model.load()

        #expect(model.category(for: slackContext()) == .communication)
        #expect(model.offerRule(for: slackContext(), as: .communication) == nil)
        #expect(model.offer == nil)
    }

    /// The one that must never regress. A title rule's `matchValue` is written to disk; deriving one
    /// from a title Lggr read would put that title in a file, which is the exact leak
    /// `INTELLIGENCE.md` §3.3 exists to prevent — arriving through the back door.
    @Test("An offer is never a window-title rule, even when a title rule caused the mistake")
    func anOfferIsNeverATitleRule() async throws {
        let titleRule = ClassificationRule(
            matchType: .windowTitleContains,
            matchValue: "invoice",
            category: .administrative,
            priority: 50
        )
        let (model, _) = makeModel(rules: [titleRule], seeded: true)
        await model.load()

        let context = ActivityContext(
            bundleIdentifier: "com.apple.dt.Xcode",
            displayName: "Xcode",
            windowTitle: "Quarterly invoice reconciliation.swift"
        )
        #expect(model.category(for: context) == .administrative)

        let offer = try #require(model.offerRule(for: context, as: .coding))
        #expect(offer.rule.matchType == .application)
        // Normalised, because that is the form the engine compares — and the point stands either way:
        // the value is the application, and nothing from the title reached it.
        #expect(offer.rule.matchValue == "com.apple.dt.xcode")
        #expect(offer.rule.matchValue.lowercased().contains("invoice") == false)
    }

    @Test("An accepted rule outranks the rules it was correcting")
    func anAcceptedRuleActuallyWins() async throws {
        let broad = ClassificationRule(
            matchType: .application, matchValue: slack, category: .communication, priority: 90)
        let (model, _) = makeModel(rules: [broad], seeded: true)
        await model.load()

        let offer = try #require(model.offerRule(for: slackContext(), as: .meeting))
        await model.acceptOffer()

        #expect(offer.rule.priority > broad.priority || offer.replacesExistingRule)
        #expect(model.category(for: slackContext()) == .meeting)
    }
}

// MARK: - Built-in rules

@Suite("RulesModel — built-in rules")
@MainActor
struct RulesModelBuiltInTests {

    @Test("Editing a built-in makes a copy of the user's own and switches the original off")
    func shadowingABuiltInSwitchesItOff() async throws {
        let (model, _) = makeModel()
        await model.load()

        let original = try #require(model.builtInRules.first { $0.matchValue == slack })
        var shadow = model.shadowCopy(of: original)
        shadow.category = .meeting

        #expect(shadow.id != original.id)
        #expect(shadow.priority == original.priority + 5)

        await model.adoptShadow(shadow, replacing: original)

        #expect(model.userRules.contains { $0.id == shadow.id })
        #expect(model.rules.first { $0.id == original.id }?.isEnabled == false)
        #expect(model.category(for: slackContext()) == .meeting)
    }

    /// A shadow of the disabled title example must not arrive enabled: that would be Lggr switching
    /// title matching on for the user.
    @Test("A shadow of a disabled rule is disabled too")
    func aShadowInheritsTheDisabledState() async throws {
        let (model, _) = makeModel()
        await model.load()

        let disabled = try #require(model.rules.first { $0.matchType == .windowTitleContains })
        #expect(model.shadowCopy(of: disabled).isEnabled == false)
    }

    @Test("Reset puts the shipped rules back and leaves the user's own alone")
    func resetRestoresTheShippedRules() async throws {
        let mine = ClassificationRule(
            matchType: .browserDomain, matchValue: "figma.com", category: .planning, priority: 20)
        let (model, _) = makeModel()
        await model.load()
        await model.save(mine)

        let shipped = try #require(model.builtInRules.first { $0.matchValue == slack })
        var changed = shipped
        changed.category = .distraction
        changed.isEnabled = false
        await model.save(changed)
        #expect(model.canResetBuiltInRules)

        await model.resetBuiltInRules()

        #expect(model.canResetBuiltInRules == false)
        #expect(model.builtInRules.sorted { $0.priority < $1.priority }.isEmpty == false)
        #expect(model.rules.first { $0.id == shipped.id } == shipped)
        #expect(model.userRules == [mine])
        // Reset restores what Lggr ships, which includes the title rule's off state.
        #expect(model.rules.filter { $0.matchType == .windowTitleContains }.allSatisfy { !$0.isEnabled })
    }

    @Test("A duplicate arrives switched off")
    func aDuplicateArrivesDisabled() async throws {
        let (model, _) = makeModel()
        await model.load()

        let original = try #require(model.builtInRules.first { $0.matchValue == slack })
        await model.duplicate(original)

        let copy = try #require(model.userRules.first)
        #expect(copy.matchValue == original.matchValue)
        #expect(copy.isEnabled == false)
        #expect(copy.id != original.id)
    }
}

// MARK: - Priority

@Suite("RulesModel — priority")
@MainActor
struct RulesModelPriorityTests {

    @Test("Moving a rule up makes it win, and every rung stays above the shipped rules")
    func movingUpChangesWhoWins() async throws {
        let first = ClassificationRule(
            matchType: .application, matchValue: slack, category: .communication, priority: 10)
        let second = ClassificationRule(
            matchType: .application, matchValue: slack, category: .meeting, priority: 20)
        let (model, _) = makeModel(rules: ClassificationRule.defaults + [first, second], seeded: true)
        await model.load()

        #expect(model.canMoveUp(first) == false)
        #expect(model.canMoveDown(first))

        await model.moveUp(second)

        let ordered = model.userRules
        let top = try #require(ordered.first)
        let bottom = try #require(ordered.last)
        #expect(top.id == second.id)
        #expect(top.priority > bottom.priority)
        #expect(ordered.allSatisfy { $0.priority > ClassificationRule.shippedPriority })
        #expect(model.category(for: slackContext()) == .meeting)
    }

    @Test("Reorder by priority makes the list agree with the engine")
    func reorderByPriorityAlignsTheList() async throws {
        let low = ClassificationRule(
            matchType: .browserDomain, matchValue: "a.com", category: .research, priority: 5)
        let high = ClassificationRule(
            matchType: .browserDomain, matchValue: "b.com", category: .research, priority: 500)
        let (model, _) = makeModel(rules: [low, high], seeded: true)
        await model.load()

        #expect(model.userRules.first?.id == low.id)

        await model.reorderByPriority()

        let ordered = model.userRules
        let top = try #require(ordered.first)
        let bottom = try #require(ordered.last)
        #expect(top.id == high.id)
        #expect(top.priority > bottom.priority)
    }
}
