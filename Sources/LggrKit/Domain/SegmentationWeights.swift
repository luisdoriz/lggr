import Foundation

/// The coarsest possible grouping of applications, used for two things only: deciding whether a
/// boundary between two applications is a real change of activity, and naming a block whose
/// applications all agree.
///
/// It is deliberately blunt. A finer taxonomy would be a classifier with a taste, and a classifier
/// that decides what counts as work is an opinion the user never asked for.
public enum AppCategory: String, Codable, CaseIterable, Sendable, Hashable {
    case development
    case communication
    case meetings
    case browsing
    /// No entry in the shipped table. Contributes no evidence in either direction.
    case unknown

    public var displayName: String {
        switch self {
        case .development: "Development"
        case .communication: "Communication"
        case .meetings: "Meetings"
        case .browsing: "Browsing"
        case .unknown: "Other"
        }
    }
}

/// Every constant the segmenter uses, in one struct with one documented default.
///
/// None of these is exposed in the UI, now or later. A user who has to tune a segmenter has been
/// handed our problem: the numbers are tuned once against the fixture days and then frozen, and a
/// disagreement about them is a disagreement about a fixture, argued in a pull request rather than in
/// a preferences pane.
///
/// This type is deliberately not `Codable`. It is configuration, never a record, and
/// `sessionBoundaryScore` is `.infinity` — which `JSONEncoder` refuses by default, so making it
/// persistable would mean either weakening the sentinel or shipping an encoder that can fail.
public struct SegmentationWeights: Hashable, Sendable {

    /// A set of applications that are one activity when they alternate.
    ///
    /// Shipped as data rather than as a `switch`, so a group can be added, argued with, or removed
    /// without touching the pipeline.
    public struct SatelliteGroup: Hashable, Sendable {
        public let name: String
        public let bundleIdentifiers: Set<String>

        public init(name: String, bundleIdentifiers: Set<String>) {
            self.name = name
            self.bundleIdentifiers = bundleIdentifiers
        }
    }

    // MARK: - Stage 0, normalise

    /// Intervals below this are sampling noise and fold into the following neighbour.
    ///
    /// Adjacent intervals merge only when they share a bundle identifier **and** an idle state.
    /// Merging across the idle boundary would erase the very evidence a gap is built from and turn a
    /// lunch break into work.
    public var minimumIntervalDuration: TimeInterval

    /// An excursion shorter than this that returns to the application it interrupted is a glance. It
    /// does not become an interval and it does not become a boundary; it increments `interjections`.
    /// This alone removes a large fraction of raw activations from a real day.
    public var glanceThreshold: TimeInterval

    // MARK: - Stage 1, evidence

    public var satelliteGroups: [SatelliteGroup]

    /// Bundle identifier to category. Absent means `.unknown`, which is a refusal to guess rather
    /// than a default bucket.
    public var categories: [String: AppCategory]

    // MARK: - Stage 2, boundary score

    /// Weight on the silence between two intervals.
    ///
    /// Set so that a fully saturated gap outscores every bonus combined: a recorded absence is
    /// structural evidence and must always cut, whatever the two applications on either side of it
    /// have in common. Without that property a lunch break between two Xcode stretches merges.
    public var gapWeight: Double

    /// The silence at which `gapScore` reaches 1. Anything longer scores the same, because the
    /// difference between five minutes away and fifty is a matter for the gap, not for the boundary.
    public var gapSaturation: TimeInterval

    /// Weight on `1 − jaccard` over the two evidence bags.
    public var evidenceWeight: Double

    /// Weight on the distance between the two categories.
    public var categoryWeight: Double

    /// An explicit session edge is ground truth and cuts unconditionally. A user who said "this is
    /// where the work started" outranks every heuristic in this struct.
    public var sessionBoundaryScore: Double

    /// Subtracted when both applications belong to the same satellite group.
    public var satelliteBonus: Double

    /// Subtracted when the stream returns to the earlier application inside `returnWindow`. Leaving
    /// and coming straight back is one activity being carried out, not two activities.
    public var returnBonus: Double

    public var returnWindow: TimeInterval

    /// θ. Cut when the score exceeds this.
    public var boundaryThreshold: Double

    // MARK: - Stage 3, absorb to a fixed point

    /// A segment shorter than this is not a block a person would recognise, so it merges into
    /// whichever neighbour shares more evidence — unless hard gaps bound it on both sides, in which
    /// case it is genuinely isolated and stands alone.
    public var minEpisodeDuration: TimeInterval

    /// Each pass strictly reduces the segment count, so absorption terminates on its own. The cap is
    /// there so that a future change which breaks that property fails loudly instead of hanging.
    public var maximumAbsorptionPasses: Int

    /// An unbroken idle run at least this long becomes an `.idle` gap. Shorter idle stays inside the
    /// block as ordinary time, because reading is not absence.
    ///
    /// Held equal to `gapSaturation` on purpose: every gap the timeline emits is then long enough
    /// that the boundary score agrees it is a boundary.
    public var idleGapThreshold: TimeInterval

    // MARK: - Stage 4, name

    /// A block must overlap a session by at least this fraction of its own span before it may borrow
    /// the session's intended outcome. Below it, the session describes some other work.
    public var sessionOverlapFraction: Double

    /// Applications named in a roster before the rest become "+N more".
    public var appRosterLimit: Int

    // MARK: - Default

    /// The shipped constants.
    ///
    /// Provisional until the four fixture days pass, frozen the moment they do. Every value here is a
    /// claim about what a person recognises as one block, and each is falsifiable by a fixture.
    public static let `default` = SegmentationWeights()

    public init(
        minimumIntervalDuration: TimeInterval = 2,
        glanceThreshold: TimeInterval = 8,
        satelliteGroups: [SatelliteGroup] = SegmentationWeights.defaultSatelliteGroups,
        categories: [String: AppCategory] = SegmentationWeights.defaultCategories,
        gapWeight: Double = 2.0,
        gapSaturation: TimeInterval = 300,
        evidenceWeight: Double = 1.0,
        categoryWeight: Double = 0.6,
        sessionBoundaryScore: Double = .infinity,
        satelliteBonus: Double = 0.5,
        returnBonus: Double = 0.4,
        returnWindow: TimeInterval = 120,
        boundaryThreshold: Double = 0.9,
        minEpisodeDuration: TimeInterval = 4 * 60,
        maximumAbsorptionPasses: Int = 10,
        idleGapThreshold: TimeInterval = 300,
        sessionOverlapFraction: Double = 0.6,
        appRosterLimit: Int = 3
    ) {
        self.minimumIntervalDuration = minimumIntervalDuration
        self.glanceThreshold = glanceThreshold
        self.satelliteGroups = satelliteGroups
        self.categories = categories
        self.gapWeight = gapWeight
        self.gapSaturation = gapSaturation
        self.evidenceWeight = evidenceWeight
        self.categoryWeight = categoryWeight
        self.sessionBoundaryScore = sessionBoundaryScore
        self.satelliteBonus = satelliteBonus
        self.returnBonus = returnBonus
        self.returnWindow = returnWindow
        self.boundaryThreshold = boundaryThreshold
        self.minEpisodeDuration = minEpisodeDuration
        self.maximumAbsorptionPasses = maximumAbsorptionPasses
        self.idleGapThreshold = idleGapThreshold
        self.sessionOverlapFraction = sessionOverlapFraction
        self.appRosterLimit = appRosterLimit
    }

    // MARK: - Shipped tables

    /// Three groups, and only three. Each one is an alternation a person performs without
    /// experiencing a change of activity: editing and running, messaging, being in a call.
    public static let defaultSatelliteGroups: [SatelliteGroup] = [
        SatelliteGroup(
            name: "Development",
            bundleIdentifiers: [
                "com.apple.dt.Xcode",
                "com.apple.Terminal",
                "com.apple.iphonesimulator",
                "com.apple.dt.Instruments",
            ]
        ),
        SatelliteGroup(
            name: "Messaging",
            bundleIdentifiers: [
                "com.tinyspeck.slackmacgap",
                "com.apple.MobileSMS",
                "com.apple.mail",
            ]
        ),
        SatelliteGroup(
            name: "Meetings",
            bundleIdentifiers: [
                "us.zoom.xos",
                "com.microsoft.teams2",
                "com.apple.FaceTime",
            ]
        ),
    ]

    public static let defaultCategories: [String: AppCategory] = [
        "com.apple.dt.Xcode": .development,
        "com.apple.Terminal": .development,
        "com.apple.iphonesimulator": .development,
        "com.apple.dt.Instruments": .development,
        "com.microsoft.VSCode": .development,
        "com.tinyspeck.slackmacgap": .communication,
        "com.apple.MobileSMS": .communication,
        "com.apple.mail": .communication,
        "us.zoom.xos": .meetings,
        "com.microsoft.teams2": .meetings,
        "com.apple.FaceTime": .meetings,
        "com.apple.Safari": .browsing,
        "com.google.Chrome": .browsing,
        "org.mozilla.firefox": .browsing,
        "company.thebrowser.Browser": .browsing,
    ]

    // MARK: - Lookups

    public func category(of bundleIdentifier: String) -> AppCategory {
        categories[bundleIdentifier] ?? .unknown
    }

    public func satelliteGroup(of bundleIdentifier: String) -> SatelliteGroup? {
        satelliteGroups.first { $0.bundleIdentifiers.contains(bundleIdentifier) }
    }

    public func areSatellites(_ first: String, _ second: String) -> Bool {
        guard let group = satelliteGroup(of: first) else { return false }
        return group.bundleIdentifiers.contains(second)
    }

    /// The evidence bag for one application: itself, plus everything it is one activity with.
    public func evidenceBag(for bundleIdentifier: String) -> Set<String> {
        var bag: Set<String> = [bundleIdentifier]
        if let group = satelliteGroup(of: bundleIdentifier) {
            bag.formUnion(group.bundleIdentifiers)
        }
        return bag
    }

    /// 1 when the two categories are known and different, 0 otherwise.
    ///
    /// An unknown category never manufactures a boundary. Under-claiming is the only acceptable
    /// failure direction here: a missed cut produces one block that is too broad, which a person can
    /// read and correct, while a cut invented from ignorance produces a block that did not happen.
    public func categoryDistance(_ first: String, _ second: String) -> Double {
        let left = category(of: first)
        let right = category(of: second)
        guard left != .unknown, right != .unknown else { return 0 }
        return left == right ? 0 : 1
    }

    /// How much silence between two intervals counts, saturating at `gapSaturation`.
    public func gapScore(_ silence: TimeInterval) -> Double {
        guard silence > 0, gapSaturation > 0 else { return 0 }
        return min(1, silence / gapSaturation)
    }
}
