import Foundation
import Testing

@testable import LggrKit

/// A duration in seconds, written in minutes.
///
/// The explicit `Double` return is load-bearing: `#expect` compares an `Optional<Double>` against an
/// integer-literal expression by type as well as by value, and reports a failure even when the
/// numbers are identical.
private func minutes(_ count: Double) -> TimeInterval { count * 60 }

/// 2024-01-15 00:00:00 UTC, so a failure reproduces identically on any machine in any timezone.
private let dayStart = Date(timeIntervalSinceReferenceDate: 727_051_200)

private func at(_ hour: Int, _ minute: Int) -> Date {
    dayStart.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
}

private enum App {
    static let xcode = (bundle: "com.apple.dt.Xcode", name: "Xcode")
    static let banking = (bundle: "com.acme.BankingVault", name: "Acme Banking Vault")
    static let therapy = (bundle: "com.example.TherapyNotes", name: "Therapy Notes")
    static let passwords = (bundle: "com.1password.1password", name: "1Password")
}

private func observation(
    _ app: (bundle: String, name: String),
    from start: Date,
    minutes span: Double,
    isIdle: Bool = false
) -> ActivityObservation {
    ActivityObservation(
        bundleIdentifier: app.bundle,
        displayName: app.name,
        start: start,
        end: start.addingTimeInterval(minutes(span)),
        monotonicDuration: minutes(span),
        isIdle: isIdle,
        idleConfidence: isIdle ? .high : .low,
        tzOffsetMinutes: -480
    )
}

// MARK: - The three dispositions

@Test func anUnlistedApplicationIsRecordedUnderItsOwnName() {
    let redactor = PrivacyRedactor(
        excludedApplications: [App.passwords.bundle], privateApplications: [App.banking.bundle])
    #expect(redactor.disposition(for: App.xcode.bundle) == .recorded)

    guard let activity = redactor.redact(observation(App.xcode, from: at(9, 0), minutes: 25)) else {
        Issue.record("an unlisted application was not recorded")
        return
    }
    #expect(activity.identity == .application(bundleIdentifier: App.xcode.bundle, displayName: App.xcode.name))
    #expect(!activity.isPrivate)
    #expect(activity.interval.displayName == "Xcode")
    #expect(activity.interval.monotonicDuration == minutes(25))
}

/// SPEC §4: an excluded application produces no record at all. Not a redacted one — none.
@Test func anExcludedApplicationProducesNoRecordAtAll() {
    let redactor = PrivacyRedactor(excludedApplications: [App.passwords.bundle])
    #expect(redactor.disposition(for: App.passwords.bundle) == .excluded)
    #expect(redactor.redact(observation(App.passwords, from: at(9, 0), minutes: 12)) == nil)
    #expect(redactor.intervals(for: [observation(App.passwords, from: at(9, 0), minutes: 12)]).isEmpty)
}

/// SPEC §4: *"store only 'Private activity'. Do not store the title or bundle information."* The
/// time is real and stays on the timeline; the identity does not survive the call.
@Test func aPrivateApplicationKeepsItsTimeAndLosesItsName() {
    let redactor = PrivacyRedactor(privateApplications: [App.banking.bundle])
    #expect(redactor.disposition(for: App.banking.bundle) == .redacted)

    guard let activity = redactor.redact(observation(App.banking, from: at(14, 0), minutes: 37)) else {
        Issue.record("a private application produced no record; its time has vanished from the day")
        return
    }
    #expect(activity.identity == .privateActivity)
    #expect(activity.isPrivate)
    #expect(activity.monotonicDuration == minutes(37))
    #expect(activity.start == at(14, 0))
    #expect(activity.interval.displayName == "Private activity")
    #expect(activity.interval.bundleIdentifier == PrivacyRedactor.privateBundleIdentifier)
}

/// The structural claim, checked the way an attacker would: encode what actually gets written and
/// look for the application in it. `.privateActivity` carries no associated values, so there is no
/// field the identity could be hiding in and no later code path that could reveal it.
@Test func nothingWrittenForAPrivateApplicationNamesIt() throws {
    let redactor = PrivacyRedactor(privateApplications: [App.banking.bundle])
    guard let activity = redactor.redact(observation(App.banking, from: at(14, 0), minutes: 37)) else {
        Issue.record("a private application produced no record")
        return
    }

    let data = try JSONEncoder().encode(activity.interval)
    guard let json = String(data: data, encoding: .utf8)?.lowercased() else {
        Issue.record("the encoded interval was not readable")
        return
    }
    #expect(!json.contains("acme"))
    #expect(!json.contains("banking"))
    #expect(!json.contains("vault"))
    #expect(json.contains("private activity"))
}

/// Both lists, one application. The stricter setting is the one the user's most recent worry
/// produced, so exclusion wins.
@Test func exclusionBeatsPrivacyWhenAnApplicationIsOnBothLists() {
    let redactor = PrivacyRedactor(
        excludedApplications: [App.banking.bundle], privateApplications: [App.banking.bundle])
    #expect(redactor.disposition(for: App.banking.bundle) == .excluded)
    #expect(redactor.redact(observation(App.banking, from: at(9, 0), minutes: 5)) == nil)
}

@Test func aRedactorWithNoListsRecordsEverything() {
    let redactor = PrivacyRedactor.permissive
    for app in [App.xcode, App.banking, App.passwords] {
        #expect(redactor.disposition(for: app.bundle) == .recorded)
    }
}

// MARK: - Matching the lists

/// macOS treats bundle identifiers case-insensitively, and a user who typed `com.acme.bankingvault`
/// did not mean *only if it is spelled like that*.
@Test func listMatchingIsCaseInsensitiveAndTrimmed() {
    let redactor = PrivacyRedactor(
        excludedApplications: ["  COM.1PASSWORD.1PASSWORD "],
        privateApplications: ["com.acme.bankingvault"])
    #expect(redactor.disposition(for: App.passwords.bundle) == .excluded)
    #expect(redactor.disposition(for: App.banking.bundle) == .redacted)
    #expect(redactor.disposition(for: "COM.ACME.BANKINGVAULT") == .redacted)
}

@Test func blankListEntriesAreIgnoredRatherThanMatchingEverything() {
    let redactor = PrivacyRedactor(excludedApplications: ["", "   "], privateApplications: [" "])
    #expect(redactor.disposition(for: App.xcode.bundle) == .recorded)
    #expect(redactor.disposition(for: "") == .recorded)
}

@Test func theRedactorCanBeBuiltFromPreferences() {
    var preferences = UserPreferences.default
    preferences.excludedApplications = [App.passwords.bundle]
    preferences.privateApplications = [App.banking.bundle, App.therapy.bundle]

    let redactor = PrivacyRedactor(preferences: preferences)
    #expect(redactor.disposition(for: App.passwords.bundle) == .excluded)
    #expect(redactor.disposition(for: App.therapy.bundle) == .redacted)
    #expect(redactor.disposition(for: App.xcode.bundle) == .recorded)
}

// MARK: - A day still adds up

/// The reason a private application keeps its duration: an afternoon that vanished would leave a
/// hole the timeline cannot explain, and a day that does not add up is a day nobody trusts.
@Test func redactionRemovesNamesWithoutRemovingTime() {
    let observations = [
        observation(App.xcode, from: at(9, 0), minutes: 50),
        observation(App.banking, from: at(9, 50), minutes: 20),
        observation(App.xcode, from: at(10, 10), minutes: 30),
    ]
    let redactor = PrivacyRedactor(privateApplications: [App.banking.bundle])
    let intervals = redactor.intervals(for: observations)

    #expect(intervals.count == 3)
    #expect(intervals.reduce(0) { $0 + $1.monotonicDuration } == minutes(100))
    #expect(intervals.map(\.displayName) == ["Xcode", "Private activity", "Xcode"])
}

/// Excluded time genuinely leaves the day. That is the difference the two controls exist to express,
/// and a user choosing exclusion is choosing the hole.
@Test func excludedTimeIsAbsentFromTheDayEntirely() {
    let observations = [
        observation(App.xcode, from: at(9, 0), minutes: 50),
        observation(App.passwords, from: at(9, 50), minutes: 10),
    ]
    let redactor = PrivacyRedactor(excludedApplications: [App.passwords.bundle])
    let intervals = redactor.intervals(for: observations)

    #expect(intervals.count == 1)
    #expect(intervals.reduce(0) { $0 + $1.monotonicDuration } == minutes(50))
}

@Test func batchRedactionPreservesOrder() {
    let observations = [
        observation(App.xcode, from: at(9, 0), minutes: 10),
        observation(App.passwords, from: at(9, 10), minutes: 10),
        observation(App.banking, from: at(9, 20), minutes: 10),
        observation(App.xcode, from: at(9, 30), minutes: 10),
    ]
    let redactor = PrivacyRedactor(
        excludedApplications: [App.passwords.bundle], privateApplications: [App.banking.bundle])
    let intervals = redactor.intervals(for: observations)

    #expect(intervals.map(\.start) == [at(9, 0), at(9, 20), at(9, 30)])
}

/// Two private applications are indistinguishable once redacted, so consecutive stretches in them
/// merge into one *Private activity* block. That is the point: a stable per-app token would be a
/// pseudonym on disk, recoverable by anyone who hashes the applications a person might own.
@Test func differentPrivateApplicationsAreIndistinguishable() {
    let redactor = PrivacyRedactor(
        privateApplications: [App.banking.bundle, App.therapy.bundle])
    let intervals = redactor.intervals(for: [
        observation(App.banking, from: at(11, 0), minutes: 10),
        observation(App.therapy, from: at(11, 10), minutes: 10),
    ])
    #expect(intervals.count == 2)
    #expect(Set(intervals.map(\.bundleIdentifier)).count == 1)
    #expect(Set(intervals.map(\.displayName)) == ["Private activity"])
}

/// The sentinel must not look like a real reverse-DNS identifier, so it cannot collide with an
/// application the user runs and a person reading the file sees a redaction rather than an app.
@Test func theRedactionSentinelCannotCollideWithARealApplication() {
    #expect(PrivacyRedactor.privateBundleIdentifier == "lggr.private")
    #expect(PrivacyRedactor.privateDisplayName == "Private activity")
    #expect(!PrivacyRedactor.privateBundleIdentifier.hasPrefix("com."))
}

// MARK: - Everything except the identity survives

@Test func timingAndIdleAnnotationsSurviveRedaction() {
    let source = observation(App.banking, from: at(16, 0), minutes: 12, isIdle: true)
    let redactor = PrivacyRedactor(privateApplications: [App.banking.bundle])

    guard let activity = redactor.redact(source) else {
        Issue.record("a private application produced no record")
        return
    }
    #expect(activity.id == source.id)
    #expect(activity.start == source.start)
    #expect(activity.end == source.end)
    #expect(activity.isIdle)
    #expect(activity.idleConfidence == .high)
    #expect(activity.tzOffsetMinutes == -480)
    #expect(activity.interval.tzOffsetMinutes == -480)
    #expect(activity.interval.isIdle)
}

@Test func anObservationCannotEndBeforeItBegins() {
    let backwards = ActivityObservation(
        bundleIdentifier: App.xcode.bundle,
        displayName: App.xcode.name,
        start: at(10, 0),
        end: at(9, 0),
        monotonicDuration: -60
    )
    #expect(backwards.end == at(10, 0))
    #expect(backwards.monotonicDuration == 0)
}

// MARK: - A private application is not classified either

/// A category is a description of what the user was doing. *"Communication, 40 minutes, Private
/// activity"* narrows the application down about as well as naming it would.
@Test func privateActivityIsNeverHandedToTheClassifier() {
    let redactor = PrivacyRedactor(privateApplications: [App.banking.bundle])
    guard let activity = redactor.redact(observation(App.banking, from: at(14, 0), minutes: 8)) else {
        Issue.record("a private application produced no record")
        return
    }
    #expect(redactor.classificationContext(for: activity) == nil)
}

@Test func recordedActivityCanBeClassified() {
    let redactor = PrivacyRedactor(privateApplications: [App.banking.bundle])
    guard let activity = redactor.redact(observation(App.xcode, from: at(9, 0), minutes: 8)),
        let context = redactor.classificationContext(for: activity)
    else {
        Issue.record("a recorded application produced no classification context")
        return
    }
    #expect(context.bundleIdentifier == App.xcode.bundle)
    #expect(ClassificationEngine.default.classify(context).category == .coding)
    #expect(context.windowTitle == nil)
}
