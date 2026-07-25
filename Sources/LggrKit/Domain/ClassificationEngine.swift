import Foundation

// MARK: - Input

/// Everything the rules are allowed to look at, for one moment of activity.
///
/// **Deliberately not `Codable`.** A `Codable` context is one `encoder.encode(context)` away from a
/// window title in a file, and `INTELLIGENCE.md` §3.3 gives Lggr exactly one window-title story:
/// read in memory, matched, released. Nothing that can hold a title may also know how to serialise
/// itself. `ActivityInterval` — the type that *is* written to disk — has no title field and no
/// initialiser that takes one.
///
/// `windowTitle` is optional twice over: absent when Accessibility was never granted, and absent
/// when the frontmost application is on the shipped deny list. Rules simply do not fire in either
/// case; there is no degraded guess.
public struct ActivityContext: Sendable, Hashable {

    public let bundleIdentifier: String
    public let displayName: String
    /// The host of the page in front of the user, when the browser exposes one. A host, never a
    /// path and never a query string — the sensitive part of a URL is everything after the host.
    public let domain: String?
    /// The title in front of the user, in memory, for the length of this call.
    ///
    /// Passed so that a `.windowTitleContains` rule **the user wrote** can be evaluated. The engine
    /// returns a category and a source and never returns this string, never stores it, and never
    /// copies it into a rule it suggests.
    public let windowTitle: String?
    /// The project of the running focus session, if one is running.
    public let projectID: UUID?
    /// The work type of the running focus session, if one is running.
    public let workType: WorkType?

    public init(
        bundleIdentifier: String,
        displayName: String = "",
        domain: String? = nil,
        windowTitle: String? = nil,
        projectID: UUID? = nil,
        workType: WorkType? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.domain = domain
        self.windowTitle = windowTitle
        self.projectID = projectID
        self.workType = workType
    }

    var normalizedBundleIdentifier: String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Lowercased, trimmed, with the root label's trailing dot removed so `github.com.` and
    /// `GitHub.com` are the same host they look like.
    var normalizedDomain: String? {
        guard let domain else { return nil }
        var host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

// MARK: - Provenance

/// Why an activity carries the category it carries.
///
/// This — and not the rule's identifier — is what an interval stores. `INTELLIGENCE.md` §3.3 is
/// explicit that the rule identity is never persisted per interval: with a rule id on every row, a
/// timeline could be joined back against the rules table to reconstruct *"when was a window whose
/// title contained ACME in front of me"*, which reassembles the title trace the design just spent a
/// section deleting. A source says which **kind** of rule fired, which is what the UI needs to
/// explain itself, and leaks 3 bits instead of a sentence.
public enum ClassificationSource: String, Codable, CaseIterable, Sendable, Hashable {
    case applicationRule = "applicationRule"
    case titleRule = "titleRule"
    case domainRule = "domainRule"
    case projectRule = "projectRule"
    case workTypeRule = "workTypeRule"
    /// No rule matched. The category is `ActivityCategory.fallback`.
    case defaultCategory = "defaultCategory"
    /// The user set this one by hand, on this activity, and no rule may overrule it.
    case manual = "manual"

    public init(matchType: RuleMatchType) {
        switch matchType {
        case .application: self = .applicationRule
        case .windowTitleContains: self = .titleRule
        case .browserDomain: self = .domainRule
        case .project: self = .projectRule
        case .workType: self = .workTypeRule
        }
    }

    public var displayName: String {
        switch self {
        case .applicationRule: "Application rule"
        case .titleRule: "Window title rule"
        case .domainRule: "Domain rule"
        case .projectRule: "Project rule"
        case .workTypeRule: "Work type rule"
        case .defaultCategory: "No rule matched"
        case .manual: "Set by you"
        }
    }

    /// A rule produced this, so the UI can offer *"edit the rule"*.
    public var isRuleDerived: Bool {
        switch self {
        case .applicationRule, .titleRule, .domainRule, .projectRule, .workTypeRule: true
        case .defaultCategory, .manual: false
        }
    }
}

/// What the engine decided, and why.
///
/// **Not `Codable`, on purpose.** `category` and `source` are storable and `ruleID` is not; making
/// the whole result encodable would put the rule identity one synthesised conformance away from the
/// timeline. Callers persist the two fields they are allowed to persist, by hand.
public struct Classification: Sendable, Hashable {
    public let category: ActivityCategory
    public let source: ClassificationSource
    /// Which rule fired, for the UI in front of the user right now — *"classified by your rule
    /// github.com → Code review"*, with an edit action. **Never written to disk.**
    public let ruleID: UUID?
    /// The project the matching rule files this activity under, if it assigns one.
    public let projectID: UUID?

    public init(
        category: ActivityCategory,
        source: ClassificationSource,
        ruleID: UUID? = nil,
        projectID: UUID? = nil
    ) {
        self.category = category
        self.source = source
        self.ruleID = ruleID
        self.projectID = projectID
    }

    /// What an activity is when nothing matched it.
    public static let unmatched = Classification(
        category: .fallback, source: .defaultCategory)
}

// MARK: - Engine

/// Applies the rule set to an activity. Pure: no clock, no I/O, no state.
///
/// The same context and the same rules produce the same `Classification` on any machine at any hour,
/// forever — which is what makes *"why is this row labelled Planning?"* a question with one answer
/// the UI can show. Determinism is not free with user-editable rules: two rules can both match, and
/// two rules can carry the same priority. `evaluationOrder` settles both cases without consulting
/// anything outside the rules themselves.
///
/// The engine knows nothing about any particular application. Xcode, Slack and YouTube appear in
/// `ClassificationRule.defaults` and nowhere else, so every conclusion this type reaches traces back
/// to a row the user can open, edit or delete.
public struct ClassificationEngine: Sendable {

    /// The rule set, already in evaluation order.
    public let rules: [ClassificationRule]

    /// Rules are sorted once, at construction, rather than on every classification — a day's capture
    /// runs this thousands of times against a rule set that changes when a person edits it.
    public init(rules: [ClassificationRule] = ClassificationRule.defaults) {
        self.rules = Self.evaluationOrder(rules)
    }

    /// The engine a fresh install starts with.
    public static let `default` = ClassificationEngine()

    /// Highest priority first; then the narrower axis; then by identifier.
    ///
    /// The last clause is what makes the result stable rather than merely plausible. `Array.sorted`
    /// is not a stable sort in Swift, so two equal-priority rules of the same match type can swap
    /// order between runs — and a classification that changes on relaunch with no edit in between is
    /// indistinguishable from a bug, in a product whose whole claim is that the record is honest.
    static func evaluationOrder(_ rules: [ClassificationRule]) -> [ClassificationRule] {
        rules.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.matchType.specificity != rhs.matchType.specificity {
                return lhs.matchType.specificity < rhs.matchType.specificity
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: Classifying

    /// The category for `context`, and why.
    ///
    /// `manualCategory` is the correction the user already made for this specific activity. It wins
    /// outright and short-circuits the rules: having told the app what this was, being overruled by
    /// a rule on the next sample would be the app arguing with them.
    public func classify(
        _ context: ActivityContext,
        manualCategory: ActivityCategory? = nil
    ) -> Classification {
        if let manualCategory {
            return Classification(category: manualCategory, source: .manual)
        }
        guard let rule = firstMatch(for: context) else { return .unmatched }
        return Classification(
            category: rule.category,
            source: ClassificationSource(matchType: rule.matchType),
            ruleID: rule.id,
            projectID: rule.projectID
        )
    }

    /// The winning rule, or `nil` when none applies. First match in evaluation order.
    public func firstMatch(for context: ActivityContext) -> ClassificationRule? {
        rules.first { $0.isEnabled && $0.isWellFormed && $0.matches(context) }
    }

    /// Every enabled rule whose condition holds, in evaluation order. The first is the one that won;
    /// the rest are what the correction flow has to outrank.
    public func matchingRules(for context: ActivityContext) -> [ClassificationRule] {
        rules.filter { $0.isEnabled && $0.isWellFormed && $0.matches(context) }
    }

    // MARK: Editing

    /// The same engine with `rule` added, or replacing the rule that shares its identifier.
    public func adding(_ rule: ClassificationRule) -> ClassificationEngine {
        ClassificationEngine(rules: rules.filter { $0.id != rule.id } + [rule])
    }

    public func removing(ruleID: UUID) -> ClassificationEngine {
        ClassificationEngine(rules: rules.filter { $0.id != ruleID })
    }

    // MARK: - The correction loop

    /// The rule that would have produced `correctedCategory` for `context`, for SPEC §5's *"the user
    /// should be able to correct a classification, and the app should offer to create a reusable
    /// rule."*
    ///
    /// Returned, not applied. The engine never learns on its own: this is an offer the user accepts,
    /// and until they do, the correction stays a one-off `.manual` on that single activity. An app
    /// that quietly writes rules from behaviour ends up with a rule set nobody authored and nobody
    /// can explain.
    ///
    /// **The derived rule never contains observed text.** The narrowest available axis is used —
    /// the domain when there is one, otherwise the application — and `.windowTitleContains` is
    /// excluded outright even when a title rule is what actually misfired. `matchValue` is written
    /// to disk; deriving one from a title the app read would put that title in a file, which is
    /// precisely what `INTELLIGENCE.md` §3.3 forbids. A title rule remains something the user types.
    ///
    /// Returns `nil` when there is nothing to learn: the engine already answers `correctedCategory`,
    /// or `context` offers no axis that can be stored.
    public func suggestedRule(
        for context: ActivityContext,
        correctedTo correctedCategory: ActivityCategory
    ) -> ClassificationRule? {
        guard classify(context).category != correctedCategory else { return nil }
        guard let (matchType, matchValue) = storableAxis(for: context) else { return nil }

        // Strictly greater than every rule that currently matches, so the suggestion is guaranteed
        // to win rather than merely to exist — a rule the user accepted that then changes nothing is
        // worse than no offer at all.
        let contested = matchingRules(for: context).map(\.priority).max()
        let priority = (contested ?? ClassificationRule.shippedPriority) + 1

        // Editing the rule already stated on this axis, rather than stacking a second one over it.
        // Two rules with the same condition and different answers is a rule set that cannot be read.
        if let existing = rules.first(
            where: { $0.matchType == matchType && $0.normalizedMatchValue == matchValue })
        {
            var updated = existing
            updated.category = correctedCategory
            updated.isEnabled = true
            updated.priority = max(existing.priority, priority)
            return updated
        }

        return ClassificationRule(
            matchType: matchType,
            matchValue: matchValue,
            category: correctedCategory,
            priority: priority
        )
    }

    /// The narrowest axis of `context` that may legally become a rule's `matchValue`.
    ///
    /// Domain before application: correcting `youtube.com` inside Chrome should not relabel every
    /// browser tab the user opens for the rest of the year.
    private func storableAxis(for context: ActivityContext) -> (RuleMatchType, String)? {
        if let domain = context.normalizedDomain, !domain.isEmpty {
            return (.browserDomain, domain)
        }
        let bundleIdentifier = context.normalizedBundleIdentifier
        guard !bundleIdentifier.isEmpty else { return nil }
        return (.application, bundleIdentifier)
    }
}
