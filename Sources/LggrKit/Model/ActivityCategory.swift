import Foundation

/// What a stretch of activity was, as far as the rules can tell.
///
/// The eleven cases are `SPEC.md` §5 exactly. Raw values are written out rather than left to the
/// compiler: these strings reach a file on the user's disk, and a Swift-level rename must never
/// silently reclassify a day that was already recorded.
///
/// A category is a *label the user can change*, not a measurement. Nothing in this type ranks the
/// cases, scores them, or divides them into good and bad, and nothing may be added that does —
/// `INTELLIGENCE.md` §3.4 removed every number that behaved like a grade, and a category set with a
/// built-in polarity is the same thing wearing an enum.
public enum ActivityCategory: String, Codable, CaseIterable, Sendable, Identifiable, Hashable {
    case coding = "coding"
    case testing = "testing"
    case codeReview = "codeReview"
    case communication = "communication"
    case planning = "planning"
    case research = "research"
    case meeting = "meeting"
    case documentation = "documentation"
    case administrative = "administrative"

    /// Time the user themselves would call off-task.
    ///
    /// ## Why this case exists at all
    ///
    /// `SPEC.md` §5 names it and ships a rule for it (*"YouTube → Distraction, unless manually
    /// reclassified"*), so it exists. But the app calling a person's time a distraction is the app
    /// passing judgment, and the design direction bans exactly that: no gamification, no streaks, no
    /// score that shames the user. Those two pull against each other, and the resolution is that the
    /// **category is kept and the verdict is not**. `.distraction` is a bucket a rule can put time
    /// into, and the rule that does it is visible, editable and deletable data — never a conclusion
    /// the app reached on its own.
    ///
    /// ## What the UI may do with it
    ///
    /// - List it in the rules editor alongside the other ten, with the shipped rule shown, editable
    ///   and deletable like any other row.
    /// - Show its time in the same neutral by-category breakdown as every other category, drawn in
    ///   the same weight and the same palette family.
    /// - Offer one-action reclassification wherever it appears, because SPEC's own wording —
    ///   *"unless manually reclassified"* — makes the correction part of the feature.
    ///
    /// ## What the UI may not do with it
    ///
    /// - Total it into a headline, a badge, a counter or any number that stands alone. A figure that
    ///   grows when you enjoy your afternoon is a score with a loss condition (§3.4).
    /// - Colour it as a warning, mark it red, flag it, or give it an alert glyph.
    /// - Compare it against another day, another week, an average, or a target.
    /// - Name it as a cause in a generated sentence. *"42 minutes on youtube.com"* is a fact the user
    ///   can read; *"you lost 42 minutes to distractions"* is a verdict and must never be written.
    /// - Trigger a notification, an interruption, a nudge, or any UI the user did not ask for.
    /// - Withhold, qualify or annotate any other statistic because of it.
    ///
    /// It is never the fallback. An activity no rule matched is `.unknown`, and only a rule the user
    /// can see and switch off ever produces this case — enforced by `ClassificationEngine` and by
    /// `ClassificationEngineTests.distractionOnlyEverComesFromAVisibleRule`.
    case distraction = "distraction"

    /// No rule matched. Not a failure and not a judgment — most of a normal day starts here, and the
    /// honest label for time the app cannot describe is one that claims nothing.
    case unknown = "unknown"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .coding: "Coding"
        case .testing: "Testing"
        case .codeReview: "Code review"
        case .communication: "Communication"
        case .planning: "Planning"
        case .research: "Research"
        case .meeting: "Meeting"
        case .documentation: "Documentation"
        case .administrative: "Administrative"
        case .distraction: "Distraction"
        case .unknown: "Unknown"
        }
    }

    /// SF Symbol name.
    ///
    /// `.distraction` gets an ordinary navigational glyph on purpose. Every warning symbol in the
    /// system set — the triangle, the octagon, the filled exclamation mark — carries a verdict before
    /// a single word is read, and the one category that must not accuse the user is the one where
    /// that matters most.
    public var symbolName: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .testing: "checkmark.diamond"
        case .codeReview: "arrow.triangle.pull"
        case .communication: "bubble.left.and.bubble.right"
        case .planning: "map"
        case .research: "magnifyingglass"
        case .meeting: "video"
        case .documentation: "doc.text"
        case .administrative: "tray.full"
        case .distraction: "arrow.triangle.branch"
        case .unknown: "questionmark.circle"
        }
    }

    /// What an activity is called when no rule matched it.
    ///
    /// Deliberately a named constant rather than a literal at each call site: the fallback being
    /// `.unknown` and never `.distraction` is a design commitment, and a commitment that lives in one
    /// place can be tested in one place.
    public static let fallback: ActivityCategory = .unknown
}
