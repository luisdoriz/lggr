import Foundation

// MARK: - Match type

/// The axis a rule matches on. One rule matches on exactly one axis.
///
/// `SPEC.md` §5 lists five: application, window title text, browser domain, project, work type.
/// Raw values are explicit because they are written to disk.
///
/// A rule cannot combine two axes ("Claude, but only inside the Payments project"). That is a
/// deliberate omission rather than an oversight: a composite matcher needs a precedence story, a
/// partial-match story and an editor that can express both, and the same outcome is already
/// reachable with a `.project` rule at a higher priority. The one place SPEC asks for it — *"Claude
/// → Research or Coding, depending on the active project"* — is served exactly that way.
public enum RuleMatchType: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    /// The frontmost application's bundle identifier, compared case-insensitively.
    case application = "application"
    /// Text the user typed, looked for inside the window title that was in front of them.
    ///
    /// This is the only match type that touches an observed title, and it survives
    /// `INTELLIGENCE.md` §3.3 — which bans writing titles to disk — for one reason: **the stored
    /// string is one the user authored.** The title itself is read in memory, tested against this
    /// value, and released. It is never stored, never returned from the engine, and never derived
    /// into a new rule (see `ClassificationEngine.suggestedRule`).
    case windowTitleContains = "windowTitleContains"
    /// A registrable domain such as `github.com`, matched against the host and its subdomains.
    case browserDomain = "browserDomain"
    /// The project the running focus session is filed under.
    case project = "project"
    /// The work type the running focus session was started with.
    case workType = "workType"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .application: "Application"
        case .windowTitleContains: "Window title contains"
        case .browserDomain: "Browser domain"
        case .project: "Project"
        case .workType: "Work type"
        }
    }

    /// How narrow a match on this axis is, lower being narrower.
    ///
    /// Used only to break a priority tie, so that two rules the user gave the same weight resolve the
    /// way a person would expect — `meet.google.com → Meeting` beats `Chrome → Research` — instead of
    /// resolving by whichever `UUID` happened to sort first.
    public var specificity: Int {
        switch self {
        case .windowTitleContains: 0
        case .browserDomain: 1
        case .application: 2
        case .project: 3
        case .workType: 4
        }
    }

    /// The rule's `matchValue` would have to come from text the app observed rather than text the
    /// user typed.
    ///
    /// Read by the correction flow, which refuses to author such a rule: a rule derived from an
    /// observed title would put that title into `matchValue`, and `matchValue` is written to disk.
    /// That is the exact leak §3.3 exists to prevent, arriving through the back door.
    public var wouldCaptureObservedText: Bool { self == .windowTitleContains }
}

// MARK: - Rule

/// One user-visible instruction: *when this is in front of me, call it that.*
///
/// Rules are plain data. The engine that applies them holds no hard-coded knowledge of Xcode, Slack
/// or YouTube — the shipped behaviour `SPEC.md` §5 asks for is `ClassificationRule.defaults`, a
/// literal array the user can read, edit, reorder, disable and delete. That is what makes the
/// judgment-shaped categories acceptable: nothing the app concludes about a person's time comes from
/// anywhere but a row they can open and change.
///
/// ## `matchValue` versus `projectID`
///
/// SPEC's model lists both `matchValue` and `project` on this entity, which reads ambiguously. Here
/// they are on opposite sides of the rule:
///
/// - `matchValue` is the **condition** — what is compared against the activity. For a `.project`
///   rule it holds the matched project's `UUID` string; for a `.workType` rule, a `WorkType` raw
///   value.
/// - `projectID` is an **outcome** alongside `category` — the project the matched activity is filed
///   under. Usually `nil`; a rule that only assigns a category leaves it alone.
public struct ClassificationRule: Identifiable, Codable, Hashable, Sendable {

    public let id: UUID
    public var matchType: RuleMatchType
    /// The condition. Compared case-insensitively after trimming; stored as the user typed it.
    public var matchValue: String
    /// The category assigned when this rule matches.
    public var category: ActivityCategory
    /// The project the matched activity is filed under, when the rule assigns one.
    public var projectID: UUID?
    /// Higher wins. Ties break on `matchType.specificity`, then on `id` — see
    /// `ClassificationEngine.evaluationOrder`.
    public var priority: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        matchType: RuleMatchType,
        matchValue: String,
        category: ActivityCategory,
        projectID: UUID? = nil,
        priority: Int = ClassificationRule.shippedPriority,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.matchType = matchType
        self.matchValue = matchValue
        self.category = category
        self.projectID = projectID
        self.priority = priority
        self.isEnabled = isEnabled
    }

    /// The priority every shipped default carries.
    ///
    /// Zero, so that a rule the user made — which the correction flow always gives a strictly greater
    /// priority — outranks anything Lggr shipped, without the user having to understand the number.
    public static let shippedPriority = 0

    /// `matchValue` reduced to the form comparisons use: trimmed and lowercased.
    public var normalizedMatchValue: String {
        matchValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A rule whose condition can never be true is inert, and an inert rule in the editor looks like
    /// a working one. The engine skips these; the editor can use it to refuse an empty save.
    public var isWellFormed: Bool { !normalizedMatchValue.isEmpty }

    // MARK: - Matching

    /// Whether this rule's condition holds for `context`. Says nothing about whether it *wins* —
    /// that is the engine's ordering.
    public func matches(_ context: ActivityContext) -> Bool {
        let value = normalizedMatchValue
        guard !value.isEmpty else { return false }

        switch matchType {
        case .application:
            return context.normalizedBundleIdentifier == value

        case .windowTitleContains:
            guard let title = context.windowTitle else { return false }
            return title.lowercased().contains(value)

        case .browserDomain:
            guard let domain = context.normalizedDomain else { return false }
            return Self.domain(domain, matches: value)

        case .project:
            guard let projectID = context.projectID else { return false }
            return projectID.uuidString.lowercased() == value

        case .workType:
            guard let workType = context.workType else { return false }
            return workType.rawValue.lowercased() == value
        }
    }

    /// `github.com` matches `github.com` and `gist.github.com`, and does not match `notgithub.com`.
    ///
    /// The suffix test is anchored to a label boundary rather than written as `hasSuffix(value)`,
    /// because the unanchored form makes `evilgithub.com` a code review and `myyoutube.com` a
    /// distraction — a matcher that silently over-reaches is worse than one that misses.
    static func domain(_ domain: String, matches value: String) -> Bool {
        domain == value || domain.hasSuffix("." + value)
    }
}

// MARK: - Shipped defaults

extension ClassificationRule {

    /// The rules `SPEC.md` §5 names, as data.
    ///
    /// Every one of these is an ordinary row in the rules editor: visible, editable, disableable,
    /// deletable. Their identifiers are fixed rather than freshly generated so that a user who edits
    /// or switches one off keeps that decision across launches, and so that a future build can add a
    /// default without disturbing the ones already on disk.
    public static let defaults: [ClassificationRule] = [
        ClassificationRule(
            id: stableID(1), matchType: .application, matchValue: "com.apple.dt.Xcode",
            category: .coding),
        ClassificationRule(
            id: stableID(2), matchType: .application, matchValue: "com.apple.Terminal",
            category: .coding),

        // SPEC says "Terminal → Coding or Testing". Which of the two it is can only be told from the
        // window title, so it ships **off**: a title rule Lggr switched on by itself would be the app
        // reading titles against a string the user never wrote, which is the distinction §3.3 rests
        // on. It sits in the editor as a worked example, one toggle away.
        ClassificationRule(
            id: stableID(3), matchType: .windowTitleContains, matchValue: "swift test",
            category: .testing, isEnabled: false),

        ClassificationRule(
            id: stableID(4), matchType: .browserDomain, matchValue: "github.com",
            category: .codeReview),
        ClassificationRule(
            id: stableID(5), matchType: .application, matchValue: "com.tinyspeck.slackmacgap",
            category: .communication),
        ClassificationRule(
            id: stableID(6), matchType: .application, matchValue: "com.linear",
            category: .planning),
        ClassificationRule(
            id: stableID(7), matchType: .browserDomain, matchValue: "linear.app",
            category: .planning),
        ClassificationRule(
            id: stableID(8), matchType: .browserDomain, matchValue: "meet.google.com",
            category: .meeting),

        // SPEC: "YouTube → Distraction, unless manually reclassified." Shipped because SPEC names it;
        // shipped as a row the user can delete in one action because `ActivityCategory.distraction`
        // documents what the app is not allowed to do with the result.
        ClassificationRule(
            id: stableID(9), matchType: .browserDomain, matchValue: "youtube.com",
            category: .distraction),

        // SPEC: "Claude → Research or Coding, depending on the active project." Research is the
        // safer half of that guess; a `.project` rule at a higher priority expresses the other half
        // for the projects where it is coding.
        ClassificationRule(
            id: stableID(10), matchType: .browserDomain, matchValue: "claude.ai",
            category: .research),
    ]

    /// A fixed, valid v4 `UUID` distinguished only by its last byte.
    ///
    /// Written as bytes rather than parsed from a string because `UUID(uuidString:)` is failable and
    /// there is no acceptable answer to a shipped constant failing to parse — a `??` fallback would
    /// hand two defaults the same identifier, and a force unwrap is banned.
    private static func stableID(_ index: UInt8) -> UUID {
        UUID(
            uuid: (
                0x16, 0x67, 0x4d, 0x0a, 0x11, 0x99, 0x40, 0x00,
                0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, index
            ))
    }
}
