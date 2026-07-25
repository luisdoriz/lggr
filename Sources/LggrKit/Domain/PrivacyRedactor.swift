import Foundation

// MARK: - Input

/// One stretch of activity as the sampler saw it, before any privacy decision has been made.
///
/// This is the only shape in which an unredacted identity exists, and it exists for the length of
/// one function call. It is **not `Codable`** and never will be: the type that can be written to
/// disk is `ActivityInterval`, and the only way to obtain one from an observation is to hand the
/// observation to `PrivacyRedactor`.
public struct ActivityObservation: Sendable, Hashable {
    public let id: UUID
    public let bundleIdentifier: String
    public let displayName: String
    public let start: Date
    public let end: Date
    /// Measured by a clock that cannot be stepped. See `ActivityInterval.monotonicDuration`.
    public let monotonicDuration: TimeInterval
    public let isIdle: Bool
    public let idleConfidence: IdleConfidence
    public let tzOffsetMinutes: Int

    public init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        start: Date,
        end: Date,
        monotonicDuration: TimeInterval,
        isIdle: Bool = false,
        idleConfidence: IdleConfidence = .low,
        tzOffsetMinutes: Int = 0
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.start = start
        self.end = max(start, end)
        self.monotonicDuration = monotonicDuration.isFinite ? max(0, monotonicDuration) : 0
        self.isIdle = isIdle
        self.idleConfidence = idleConfidence
        self.tzOffsetMinutes = tzOffsetMinutes
    }
}

// MARK: - Output

/// An observation that has been through the redactor, and can no longer be un-redacted.
///
/// The identity is a closed enum whose private case **carries no associated values**. That is the
/// whole design: there is no field to read the original bundle identifier back out of, no optional
/// that happens to be `nil` today, and no initialiser outside this module that can put one back. A
/// later view, exporter or debug dump cannot decide to reveal what a private app was, because by the
/// time the value reaches them the information is not in the process any more — it was dropped one
/// function after it was read.
///
/// This is deliberately the opposite of redacting at display time. Redaction at display time keeps
/// the truth on disk and hides it in one code path, so every *other* path — the CSV export, the
/// Markdown summary, the crash log, the JSON a user opens in a text editor — leaks by default and
/// has to be fixed one at a time, forever.
public struct RedactedActivity: Sendable, Hashable {

    /// Who the activity belonged to, or the fact that this may not be said.
    public enum Identity: Sendable, Hashable {
        case application(bundleIdentifier: String, displayName: String)
        /// A private application. Carries nothing, and can carry nothing.
        case privateActivity
    }

    public let id: UUID
    public let identity: Identity
    public let start: Date
    public let end: Date
    public let monotonicDuration: TimeInterval
    public let isIdle: Bool
    public let idleConfidence: IdleConfidence
    public let tzOffsetMinutes: Int

    /// Internal on purpose. Only `PrivacyRedactor` may mint one of these, so there is no route from
    /// a raw observation to a stored interval that skips the privacy lists.
    init(
        id: UUID,
        identity: Identity,
        start: Date,
        end: Date,
        monotonicDuration: TimeInterval,
        isIdle: Bool,
        idleConfidence: IdleConfidence,
        tzOffsetMinutes: Int
    ) {
        self.id = id
        self.identity = identity
        self.start = start
        self.end = end
        self.monotonicDuration = monotonicDuration
        self.isIdle = isIdle
        self.idleConfidence = idleConfidence
        self.tzOffsetMinutes = tzOffsetMinutes
    }

    public var isPrivate: Bool { identity == .privateActivity }

    public var bundleIdentifier: String {
        switch identity {
        case .application(let bundleIdentifier, _): bundleIdentifier
        case .privateActivity: PrivacyRedactor.privateBundleIdentifier
        }
    }

    public var displayName: String {
        switch identity {
        case .application(_, let displayName): displayName
        case .privateActivity: PrivacyRedactor.privateDisplayName
        }
    }

    /// The storable form. The time is real and stays real; only the name is gone.
    public var interval: ActivityInterval {
        ActivityInterval(
            id: id,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            start: start,
            end: end,
            monotonicDuration: monotonicDuration,
            isIdle: isIdle,
            idleConfidence: idleConfidence,
            tzOffsetMinutes: tzOffsetMinutes
        )
    }
}

// MARK: - Redactor

/// Enforces the excluded / private distinction at the moment of capture.
///
/// `SPEC.md` §4 asks for two different privacy controls and they are genuinely different:
///
/// - **Excluded** — no record at all. The application was never in front of the user as far as this
///   app is concerned, and the time it occupied is not on the timeline.
/// - **Private** — *"store only 'Private activity'. Do not store the title or bundle information."*
///   The interval survives; the identity does not.
///
/// The private case keeps the duration because the alternative is worse for the user than for their
/// privacy: an afternoon in a private app that vanished would leave a two-hour hole the timeline
/// cannot explain, and a day that does not add up is a day nobody trusts. Time is not the sensitive
/// part. *Which application* is.
///
/// Two consequences, stated rather than discovered later:
///
/// - Two different private applications are indistinguishable once redacted, so consecutive stretches
///   in them merge into one *Private activity* block. That is the point. A stable per-app token would
///   be a pseudonym that lives on disk, and a pseudonym derived from a bundle identifier is
///   recoverable by anyone who hashes the two hundred applications a person might plausibly own.
/// - Exclusion beats privacy when an application is on both lists. The stricter setting is the one
///   the user's most recent worry produced.
///
/// Pure and `Sendable`: matching two string sets, no clock and no I/O.
public struct PrivacyRedactor: Sendable {

    /// What happens to a given application's activity.
    public enum Disposition: String, Sendable, Hashable, CaseIterable {
        /// Recorded with its name.
        case recorded = "recorded"
        /// Recorded as *Private activity*, with the duration kept and the identity dropped.
        case redacted = "redacted"
        /// Not recorded at all.
        case excluded = "excluded"
    }

    /// The bundle identifier a redacted interval carries.
    ///
    /// Not shaped like a real reverse-DNS identifier, so it cannot collide with an application the
    /// user actually runs, and so that a person reading `store.json` sees immediately that this row
    /// is a redaction rather than an app called Private Activity.
    public static let privateBundleIdentifier = "lggr.private"
    public static let privateDisplayName = "Private activity"

    private let excluded: Set<String>
    private let redacted: Set<String>

    public init(excludedApplications: [String] = [], privateApplications: [String] = []) {
        self.excluded = Self.normalize(excludedApplications)
        self.redacted = Self.normalize(privateApplications)
    }

    public init(preferences: UserPreferences) {
        self.init(
            excludedApplications: preferences.excludedApplications,
            privateApplications: preferences.privateApplications
        )
    }

    /// Records everything under its own name. The state a user who has configured nothing is in.
    public static let permissive = PrivacyRedactor()

    public func disposition(for bundleIdentifier: String) -> Disposition {
        let key = Self.key(bundleIdentifier)
        if excluded.contains(key) { return .excluded }
        if redacted.contains(key) { return .redacted }
        return .recorded
    }

    /// The observation as it is allowed to be kept, or `nil` when the application is excluded and
    /// there is to be no record whatsoever.
    public func redact(_ observation: ActivityObservation) -> RedactedActivity? {
        let identity: RedactedActivity.Identity
        switch disposition(for: observation.bundleIdentifier) {
        case .excluded:
            return nil
        case .redacted:
            identity = .privateActivity
        case .recorded:
            identity = .application(
                bundleIdentifier: observation.bundleIdentifier,
                displayName: observation.displayName
            )
        }

        return RedactedActivity(
            id: observation.id,
            identity: identity,
            start: observation.start,
            end: observation.end,
            monotonicDuration: observation.monotonicDuration,
            isIdle: observation.isIdle,
            idleConfidence: observation.idleConfidence,
            tzOffsetMinutes: observation.tzOffsetMinutes
        )
    }

    /// Excluded observations are dropped; the order of the rest is preserved.
    public func redact(_ observations: [ActivityObservation]) -> [RedactedActivity] {
        observations.compactMap(redact)
    }

    /// The intervals that may be written for these observations.
    public func intervals(for observations: [ActivityObservation]) -> [ActivityInterval] {
        redact(observations).map(\.interval)
    }

    /// A private application's activity must not be classified either: a category is a description
    /// of what the user was doing, and *"Communication, 40 minutes, Private activity"* narrows the
    /// application down about as well as naming it would.
    public func classificationContext(for activity: RedactedActivity) -> ActivityContext? {
        guard case .application(let bundleIdentifier, let displayName) = activity.identity else {
            return nil
        }
        return ActivityContext(bundleIdentifier: bundleIdentifier, displayName: displayName)
    }

    /// Bundle identifiers are compared case-insensitively: macOS treats them that way, and a user who
    /// typed `com.apple.mail` into the private list did not mean *only if it is spelled like that*.
    private static func key(_ bundleIdentifier: String) -> String {
        bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func normalize(_ identifiers: [String]) -> Set<String> {
        Set(identifiers.map(key).filter { !$0.isEmpty })
    }
}
