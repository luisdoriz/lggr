import Foundation
import Testing

@testable import LggrKit

private enum Bundle {
    static let xcode = "com.apple.dt.Xcode"
    static let terminal = "com.apple.Terminal"
    static let chrome = "com.google.Chrome"
    static let slack = "com.tinyspeck.slackmacgap"
    static let linear = "com.linear"
    static let unknownApp = "com.example.unheardof"
}

private func browsing(_ domain: String, title: String? = nil) -> ActivityContext {
    ActivityContext(
        bundleIdentifier: Bundle.chrome,
        displayName: "Chrome",
        domain: domain,
        windowTitle: title
    )
}

private func app(_ bundleIdentifier: String, title: String? = nil) -> ActivityContext {
    ActivityContext(bundleIdentifier: bundleIdentifier, windowTitle: title)
}

// MARK: - The category set

@Test func categorySetIsTheElevenSpecNames() {
    #expect(ActivityCategory.allCases.count == 11)
    #expect(
        Set(ActivityCategory.allCases.map(\.rawValue)) == [
            "coding", "testing", "codeReview", "communication", "planning", "research",
            "meeting", "documentation", "administrative", "distraction", "unknown",
        ])
}

/// Raw values reach the user's disk. A Swift-level rename must not silently reclassify a recorded
/// day, so the strings are asserted rather than assumed.
@Test func categoryRawValuesAreStable() {
    #expect(ActivityCategory.codeReview.rawValue == "codeReview")
    #expect(ActivityCategory.distraction.rawValue == "distraction")
    #expect(ActivityCategory.unknown.rawValue == "unknown")
}

@Test func everyCategoryHasADisplayNameAndSymbol() {
    for category in ActivityCategory.allCases {
        #expect(!category.displayName.isEmpty)
        #expect(!category.symbolName.isEmpty)
    }
}

@Test func categoriesRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(ActivityCategory.allCases)
    #expect(try JSONDecoder().decode([ActivityCategory].self, from: data) == ActivityCategory.allCases)
}

@Test func fallbackIsUnknown() {
    #expect(ActivityCategory.fallback == .unknown)
    #expect(Classification.unmatched.category == .unknown)
    #expect(Classification.unmatched.source == .defaultCategory)
}

// MARK: - Defaults ship as data

@Test func shippedDefaultsCoverTheExamplesInTheSpec() {
    let engine = ClassificationEngine.default

    #expect(engine.classify(app(Bundle.xcode)).category == .coding)
    #expect(engine.classify(app(Bundle.terminal)).category == .coding)
    #expect(engine.classify(browsing("github.com")).category == .codeReview)
    #expect(engine.classify(app(Bundle.slack)).category == .communication)
    #expect(engine.classify(app(Bundle.linear)).category == .planning)
    #expect(engine.classify(browsing("linear.app")).category == .planning)
    #expect(engine.classify(browsing("meet.google.com")).category == .meeting)
    #expect(engine.classify(browsing("youtube.com")).category == .distraction)
    #expect(engine.classify(browsing("claude.ai")).category == .research)
}

/// Nothing about Xcode, Slack or YouTube is compiled into the engine: hand it an empty rule set and
/// every one of them is `.unknown`. That is what makes the shipped behaviour something a user can
/// open and change rather than something they have to accept.
@Test func defaultsAreDataAndNotCode() {
    let empty = ClassificationEngine(rules: [])
    for context in [app(Bundle.xcode), app(Bundle.slack), browsing("youtube.com")] {
        #expect(empty.classify(context).category == .unknown)
        #expect(empty.classify(context).source == .defaultCategory)
    }
}

@Test func defaultRuleIdentifiersAreStableAndDistinct() {
    let first = ClassificationRule.defaults.map(\.id)
    let second = ClassificationRule.defaults.map(\.id)
    #expect(first == second)
    #expect(Set(first).count == first.count)
}

@Test func everyDefaultRuleIsWellFormed() {
    for rule in ClassificationRule.defaults {
        #expect(rule.isWellFormed)
        #expect(rule.priority == ClassificationRule.shippedPriority)
    }
}

/// "Terminal → Coding or Testing" can only be told apart by a window title, so the title half ships
/// switched off: Lggr matching titles against a string the user never wrote is the thing
/// `INTELLIGENCE.md` §3.3 draws its line around.
@Test func theShippedTitleRuleIsDisabledUntilTheUserEnablesIt() {
    let titleRules = ClassificationRule.defaults.filter { $0.matchType == .windowTitleContains }
    #expect(!titleRules.isEmpty)
    #expect(titleRules.allSatisfy { !$0.isEnabled })

    let engine = ClassificationEngine.default
    #expect(engine.classify(app(Bundle.terminal, title: "swift test --filter Rule")).category == .coding)

    guard var rule = titleRules.first else { return }
    rule.isEnabled = true
    rule.priority = 5
    let enabled = engine.adding(rule)
    #expect(enabled.classify(app(Bundle.terminal, title: "swift test --filter Rule")).category == .testing)
}

// MARK: - Matching

@Test func applicationMatchingIsCaseInsensitiveAndTrimmed() {
    let engine = ClassificationEngine.default
    #expect(engine.classify(app("COM.APPLE.DT.XCODE")).category == .coding)
    #expect(engine.classify(app("  com.apple.dt.xcode  ")).category == .coding)
}

@Test func domainRuleMatchesSubdomains() {
    let engine = ClassificationEngine.default
    #expect(engine.classify(browsing("github.com")).category == .codeReview)
    #expect(engine.classify(browsing("gist.github.com")).category == .codeReview)
    #expect(engine.classify(browsing("www.github.com")).category == .codeReview)
}

/// An unanchored suffix test would make `evilgithub.com` a code review and `myyoutube.com` a
/// distraction. A matcher that silently over-reaches is worse than one that misses.
@Test func domainRuleDoesNotMatchASuffixImpostor() {
    let engine = ClassificationEngine.default
    #expect(engine.classify(browsing("notgithub.com")).category == .unknown)
    #expect(engine.classify(browsing("myyoutube.com")).category == .unknown)
    #expect(engine.classify(browsing("github.com.example.net")).category == .unknown)
}

@Test func domainMatchingNormalizesCaseAndTrailingDot() {
    let engine = ClassificationEngine.default
    #expect(engine.classify(browsing("GitHub.com")).category == .codeReview)
    #expect(engine.classify(browsing("github.com.")).category == .codeReview)
    #expect(engine.classify(browsing("  youtube.com ")).category == .distraction)
}

@Test func titleRuleMatchesCaseInsensitiveSubstring() {
    let rule = ClassificationRule(
        matchType: .windowTitleContains, matchValue: "Deduplication", category: .coding)
    let engine = ClassificationEngine(rules: [rule])
    #expect(engine.classify(app(Bundle.chrome, title: "receipt deduplication PR")).category == .coding)
    #expect(engine.classify(app(Bundle.chrome, title: "receipts")).category == .unknown)
}

/// Accessibility denied, or the frontmost application on the shipped deny list: there is no title,
/// so title rules simply do not fire. There is no degraded guess.
@Test func titleRuleDoesNotFireWithoutATitle() {
    let rule = ClassificationRule(
        matchType: .windowTitleContains, matchValue: "review", category: .codeReview)
    #expect(ClassificationEngine(rules: [rule]).classify(app(Bundle.chrome)).category == .unknown)
}

@Test func projectRuleMatchesTheSessionProject() {
    let projectID = UUID()
    let rule = ClassificationRule(
        matchType: .project, matchValue: projectID.uuidString, category: .documentation)
    let engine = ClassificationEngine(rules: [rule])

    let inProject = ActivityContext(bundleIdentifier: Bundle.unknownApp, projectID: projectID)
    #expect(engine.classify(inProject).category == .documentation)
    #expect(engine.classify(inProject).source == .projectRule)

    let elsewhere = ActivityContext(bundleIdentifier: Bundle.unknownApp, projectID: UUID())
    #expect(engine.classify(elsewhere).category == .unknown)
    #expect(engine.classify(app(Bundle.unknownApp)).category == .unknown)
}

@Test func workTypeRuleMatchesTheSessionWorkType() {
    let rule = ClassificationRule(
        matchType: .workType, matchValue: WorkType.meeting.rawValue, category: .meeting)
    let engine = ClassificationEngine(rules: [rule])

    let inMeeting = ActivityContext(bundleIdentifier: Bundle.unknownApp, workType: .meeting)
    #expect(engine.classify(inMeeting).category == .meeting)
    #expect(engine.classify(inMeeting).source == .workTypeRule)

    let deepWork = ActivityContext(bundleIdentifier: Bundle.unknownApp, workType: .deepWork)
    #expect(engine.classify(deepWork).category == .unknown)
}

/// SPEC's Claude case — Research or Coding depending on the project — without a composite matcher.
@Test func aProjectRuleOverridesAnApplicationRuleForOneProject() {
    let payments = UUID()
    let engine = ClassificationEngine.default.adding(
        ClassificationRule(
            matchType: .project, matchValue: payments.uuidString, category: .coding, priority: 3))

    #expect(engine.classify(browsing("claude.ai")).category == .research)

    let inPayments = ActivityContext(
        bundleIdentifier: Bundle.chrome, domain: "claude.ai", projectID: payments)
    #expect(engine.classify(inPayments).category == .coding)
}

@Test func aBlankMatchValueNeverMatches() {
    let blank = ClassificationRule(matchType: .application, matchValue: "   ", category: .coding)
    #expect(!blank.isWellFormed)
    #expect(ClassificationEngine(rules: [blank]).classify(app(Bundle.xcode)).category == .unknown)
}

@Test func aDisabledRuleNeverMatches() {
    let rule = ClassificationRule(
        matchType: .application, matchValue: Bundle.xcode, category: .coding, isEnabled: false)
    let engine = ClassificationEngine(rules: [rule])
    #expect(engine.classify(app(Bundle.xcode)).category == .unknown)
    #expect(engine.matchingRules(for: app(Bundle.xcode)).isEmpty)
}

// MARK: - Ordering and determinism

@Test func higherPriorityWinsRegardlessOfInputOrder() {
    let low = ClassificationRule(
        matchType: .application, matchValue: Bundle.chrome, category: .research, priority: 1)
    let high = ClassificationRule(
        matchType: .application, matchValue: Bundle.chrome, category: .documentation, priority: 9)

    #expect(ClassificationEngine(rules: [low, high]).classify(app(Bundle.chrome)).category == .documentation)
    #expect(ClassificationEngine(rules: [high, low]).classify(app(Bundle.chrome)).category == .documentation)
}

/// Equal priority resolves the way a person expects — the narrower axis first — rather than by
/// whichever `UUID` happened to sort lower.
@Test func equalPriorityBreaksOnSpecificity() {
    let broad = ClassificationRule(
        matchType: .application, matchValue: Bundle.chrome, category: .research, priority: 4)
    let narrow = ClassificationRule(
        matchType: .browserDomain, matchValue: "meet.google.com", category: .meeting, priority: 4)

    let engine = ClassificationEngine(rules: [broad, narrow])
    #expect(engine.classify(browsing("meet.google.com")).category == .meeting)
    #expect(engine.classify(browsing("example.com")).category == .research)
}

/// The last tie-break. `Array.sorted` is not stable in Swift, so without it two equal rules of the
/// same match type could swap on relaunch — a classification that changes with no edit in between is
/// indistinguishable from a bug.
@Test func identicalPriorityAndTypeResolveDeterministically() {
    let a = ClassificationRule(
        id: UUID(uuidString: "00000000-0000-4000-A000-000000000001") ?? UUID(),
        matchType: .application, matchValue: Bundle.chrome, category: .research, priority: 2)
    let b = ClassificationRule(
        id: UUID(uuidString: "FFFFFFFF-0000-4000-A000-000000000002") ?? UUID(),
        matchType: .application, matchValue: Bundle.chrome, category: .planning, priority: 2)

    #expect(ClassificationEngine(rules: [a, b]).classify(app(Bundle.chrome)).category == .research)
    #expect(ClassificationEngine(rules: [b, a]).classify(app(Bundle.chrome)).category == .research)
}

@Test func shufflingTheRuleSetNeverChangesTheAnswer() {
    let contexts = [
        app(Bundle.xcode), app(Bundle.slack), browsing("github.com"),
        browsing("youtube.com"), browsing("meet.google.com"), app(Bundle.unknownApp),
    ]
    let expected = contexts.map { ClassificationEngine.default.classify($0) }

    for _ in 0..<25 {
        let engine = ClassificationEngine(rules: ClassificationRule.defaults.shuffled())
        #expect(contexts.map { engine.classify($0) } == expected)
    }
}

// MARK: - Provenance

@Test func theSourceNamesTheKindOfRuleThatFired() {
    let engine = ClassificationEngine.default
    #expect(engine.classify(app(Bundle.xcode)).source == .applicationRule)
    #expect(engine.classify(browsing("github.com")).source == .domainRule)
    #expect(engine.classify(app(Bundle.unknownApp)).source == .defaultCategory)

    for matchType in RuleMatchType.allCases {
        #expect(ClassificationSource(matchType: matchType).isRuleDerived)
    }
    #expect(!ClassificationSource.defaultCategory.isRuleDerived)
    #expect(!ClassificationSource.manual.isRuleDerived)
}

@Test func theRuleThatFiredIsIdentifiedForTheUIOnly() {
    let engine = ClassificationEngine.default
    let classification = engine.classify(browsing("youtube.com"))
    #expect(classification.ruleID != nil)
    #expect(engine.rules.contains { $0.id == classification.ruleID })

    // What an interval is allowed to persist is the source, which names a kind of rule and not a
    // rule — a stored rule id would let the timeline be joined back against the rules table.
    let encoded = try? JSONEncoder().encode(classification.source)
    #expect(encoded != nil)
    if let encoded, let json = String(data: encoded, encoding: .utf8) {
        #expect(json == "\"domainRule\"")
    }
}

@Test func nothingIsIdentifiedWhenNoRuleMatched() {
    let classification = ClassificationEngine.default.classify(app(Bundle.unknownApp))
    #expect(classification.ruleID == nil)
    #expect(classification.projectID == nil)
    #expect(classification.category == .unknown)
}

@Test func aManualCategoryOverridesEveryRule() {
    let engine = ClassificationEngine.default
    let classification = engine.classify(browsing("youtube.com"), manualCategory: .research)
    #expect(classification.category == .research)
    #expect(classification.source == .manual)
    #expect(classification.ruleID == nil)
}

@Test func aRuleCanFileActivityUnderAProject() {
    let projectID = UUID()
    let rule = ClassificationRule(
        matchType: .browserDomain, matchValue: "internal.example.com", category: .documentation,
        projectID: projectID, priority: 2)
    let classification = ClassificationEngine(rules: [rule]).classify(browsing("internal.example.com"))
    #expect(classification.projectID == projectID)
    #expect(classification.category == .documentation)
}

@Test func classificationSourcesRoundTripThroughJSON() throws {
    let data = try JSONEncoder().encode(ClassificationSource.allCases)
    #expect(
        try JSONDecoder().decode([ClassificationSource].self, from: data)
            == ClassificationSource.allCases)
}

// MARK: - Distraction stays a rule, never a verdict

/// Nothing is ever called a distraction because the app decided so. It takes a rule, the rule is in
/// the list the user can see, and switching it off removes the label entirely.
@Test func distractionOnlyEverComesFromAVisibleRule() {
    let engine = ClassificationEngine.default
    let youtube = browsing("youtube.com")
    #expect(engine.classify(youtube).category == .distraction)

    guard let ruleID = engine.classify(youtube).ruleID else {
        Issue.record("a distraction was produced by no rule at all")
        return
    }
    #expect(engine.rules.contains { $0.id == ruleID })
    #expect(engine.removing(ruleID: ruleID).classify(youtube).category == .unknown)
}

@Test func disablingTheRuleRemovesTheLabelWithoutDeletingIt() {
    let engine = ClassificationEngine.default
    guard var rule = engine.rules.first(where: { $0.category == .distraction }) else {
        Issue.record("the shipped distraction rule is missing")
        return
    }
    rule.isEnabled = false
    let disabled = engine.adding(rule)
    #expect(disabled.classify(browsing("youtube.com")).category == .unknown)
    #expect(disabled.rules.contains { $0.id == rule.id })
}

/// The fallback for time the app cannot describe is `.unknown`. Never `.distraction`: a default that
/// assumed the worst about unrecognised time would be the app passing judgment by omission.
@Test func unrecognisedActivityIsNeverCalledADistraction() {
    let engine = ClassificationEngine.default
    let strangers = [
        app(Bundle.unknownApp), app(""), browsing("example.com"),
        browsing("news.ycombinator.com"), app("com.apple.Music"),
    ]
    for context in strangers {
        #expect(engine.classify(context).category != .distraction)
    }
}

/// SPEC's own wording — "unless manually reclassified" — makes the correction part of the feature.
@Test func aDistractionCanBeReclassifiedInOneAction() {
    let engine = ClassificationEngine.default
    let youtube = browsing("youtube.com")
    guard let rule = engine.suggestedRule(for: youtube, correctedTo: .research) else {
        Issue.record("no reusable rule was offered for a corrected distraction")
        return
    }
    #expect(engine.adding(rule).classify(youtube).category == .research)
}

// MARK: - The correction loop

/// The property the whole feature rests on: whatever rule is offered, applying it produces the
/// answer the user gave.
@Test func theSuggestedRuleReproducesTheCorrection() {
    let engine = ClassificationEngine.default
    let cases: [(ActivityContext, ActivityCategory)] = [
        (browsing("youtube.com"), .research),
        (browsing("github.com"), .coding),
        (app(Bundle.slack), .administrative),
        (app(Bundle.unknownApp), .documentation),
        (browsing("figma.com"), .planning),
    ]

    for (context, corrected) in cases {
        guard let rule = engine.suggestedRule(for: context, correctedTo: corrected) else {
            Issue.record("no rule was derived for \(context.bundleIdentifier)")
            continue
        }
        let corrective = engine.adding(rule)
        #expect(corrective.classify(context).category == corrected)
        #expect(corrective.classify(context).ruleID == rule.id)
    }
}

/// Correcting one page must not relabel every browser tab for the rest of the year, so the domain is
/// preferred over the application whenever there is one.
@Test func theSuggestedRuleUsesTheNarrowestStorableAxis() {
    let engine = ClassificationEngine.default
    let rule = engine.suggestedRule(for: browsing("figma.com"), correctedTo: .planning)
    #expect(rule?.matchType == .browserDomain)
    #expect(rule?.matchValue == "figma.com")

    let appRule = engine.suggestedRule(for: app(Bundle.unknownApp), correctedTo: .documentation)
    #expect(appRule?.matchType == .application)
    #expect(appRule?.matchValue == Bundle.unknownApp.lowercased())
}

/// `matchValue` is written to disk. Deriving one from a title the app read would put that title in a
/// file, which is exactly what `INTELLIGENCE.md` §3.3 forbids — arriving through the back door of a
/// helpful suggestion. A title rule stays something the user types.
@Test func theSuggestedRuleNeverContainsObservedText() {
    let title = "Kaiser Permanente — Your test results"
    let engine = ClassificationEngine(rules: [
        ClassificationRule(
            matchType: .windowTitleContains, matchValue: "results", category: .research, priority: 5)
    ])
    let context = ActivityContext(
        bundleIdentifier: Bundle.chrome, displayName: "Chrome", domain: "kp.org", windowTitle: title)

    #expect(engine.classify(context).source == .titleRule)

    guard let suggested = engine.suggestedRule(for: context, correctedTo: .administrative) else {
        Issue.record("no rule was derived")
        return
    }
    #expect(suggested.matchType != .windowTitleContains)
    #expect(suggested.matchType.wouldCaptureObservedText == false)
    #expect(!suggested.matchValue.lowercased().contains("kaiser"))
    #expect(!suggested.matchValue.lowercased().contains("test results"))
    #expect(suggested.matchValue == "kp.org")
    #expect(engine.adding(suggested).classify(context).category == .administrative)
}

@Test func noRuleIsOfferedWhenTheEngineAlreadyAgrees() {
    let engine = ClassificationEngine.default
    #expect(engine.suggestedRule(for: browsing("youtube.com"), correctedTo: .distraction) == nil)
    #expect(engine.suggestedRule(for: app(Bundle.unknownApp), correctedTo: .unknown) == nil)
}

@Test func noRuleIsOfferedWhenThereIsNothingStorableToMatchOn() {
    let engine = ClassificationEngine.default
    let anonymous = ActivityContext(bundleIdentifier: "   ", windowTitle: "something")
    #expect(engine.suggestedRule(for: anonymous, correctedTo: .coding) == nil)
}

/// Two rules with the same condition and different answers is a rule set nobody can read, so the
/// existing row is edited rather than buried under a second one.
@Test func correctingAnAxisThatAlreadyHasARuleEditsThatRule() {
    let engine = ClassificationEngine.default
    guard let existing = engine.rules.first(where: { $0.matchValue == "youtube.com" }),
        let suggested = engine.suggestedRule(for: browsing("youtube.com"), correctedTo: .research)
    else {
        Issue.record("the shipped youtube.com rule is missing")
        return
    }
    #expect(suggested.id == existing.id)
    #expect(suggested.category == .research)
    #expect(engine.adding(suggested).rules.count == engine.rules.count)
}

@Test func correctingReEnablesADisabledRuleOnTheSameAxis() {
    let disabled = ClassificationRule(
        matchType: .application, matchValue: Bundle.unknownApp, category: .coding, isEnabled: false)
    let engine = ClassificationEngine(rules: [disabled])

    guard let suggested = engine.suggestedRule(for: app(Bundle.unknownApp), correctedTo: .testing)
    else {
        Issue.record("no rule was derived")
        return
    }
    #expect(suggested.id == disabled.id)
    #expect(suggested.isEnabled)
    #expect(engine.adding(suggested).classify(app(Bundle.unknownApp)).category == .testing)
}

/// A rule the user accepted that then changes nothing is worse than no offer at all.
@Test func theSuggestedRuleOutranksEveryRuleThatCurrentlyMatches() {
    let engine = ClassificationEngine(rules: [
        ClassificationRule(
            matchType: .application, matchValue: Bundle.chrome, category: .research, priority: 12),
        ClassificationRule(
            matchType: .browserDomain, matchValue: "example.com", category: .planning, priority: 40),
    ])
    let context = browsing("example.com")

    guard let suggested = engine.suggestedRule(for: context, correctedTo: .documentation) else {
        Issue.record("no rule was derived")
        return
    }
    #expect(suggested.priority > 40)
    #expect(engine.adding(suggested).classify(context).category == .documentation)
}

/// The engine never learns on its own. `suggestedRule` returns an offer; accepting it is the user's
/// action, and until then the correction is a one-off `.manual` on that single activity.
@Test func suggestingARuleChangesNothing() {
    let engine = ClassificationEngine.default
    let before = engine.rules
    _ = engine.suggestedRule(for: browsing("youtube.com"), correctedTo: .research)
    #expect(engine.rules == before)
    #expect(engine.classify(browsing("youtube.com")).category == .distraction)
}

/// The point of a rule rather than a correction: it applies to the activity that has not happened yet.
@Test func anAcceptedRuleAppliesToLaterActivityOnTheSameAxis() {
    let engine = ClassificationEngine.default
    guard let rule = engine.suggestedRule(for: browsing("github.com"), correctedTo: .coding) else {
        Issue.record("no rule was derived")
        return
    }
    let corrective = engine.adding(rule)
    #expect(corrective.classify(browsing("gist.github.com")).category == .coding)
    #expect(corrective.classify(browsing("github.com")).category == .coding)
    #expect(corrective.classify(browsing("linear.app")).category == .planning)
}

// MARK: - Editing the rule set

@Test func addingARuleReplacesTheOneSharingItsIdentifier() {
    let engine = ClassificationEngine.default
    guard var rule = engine.rules.first(where: { $0.matchValue == "github.com" }) else {
        Issue.record("the shipped github.com rule is missing")
        return
    }
    rule.category = .coding
    let updated = engine.adding(rule)
    #expect(updated.rules.count == engine.rules.count)
    #expect(updated.classify(browsing("github.com")).category == .coding)
}

@Test func removingAnAbsentRuleChangesNothing() {
    let engine = ClassificationEngine.default
    #expect(engine.removing(ruleID: UUID()).rules == engine.rules)
}

@Test func matchingRulesAreReturnedInEvaluationOrder() {
    let engine = ClassificationEngine(rules: [
        ClassificationRule(
            matchType: .application, matchValue: Bundle.chrome, category: .research, priority: 1),
        ClassificationRule(
            matchType: .browserDomain, matchValue: "example.com", category: .planning, priority: 7),
        ClassificationRule(
            matchType: .browserDomain, matchValue: "other.com", category: .coding, priority: 99),
    ])
    let matches = engine.matchingRules(for: browsing("example.com"))
    #expect(matches.map(\.category) == [.planning, .research])
}

/// Classification is per sample and runs thousands of times a day; the guard is that it stays a
/// scan of the rule set and never grows a search over the day.
@Test func classifyingIsCheapEnoughToRunOnEverySample() {
    let engine = ClassificationEngine.default
    let context = browsing("github.com")
    var coded = 0
    for _ in 0..<20_000 where engine.classify(context).category == .codeReview { coded += 1 }
    #expect(coded == 20_000)
}
