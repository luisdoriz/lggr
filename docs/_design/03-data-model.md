# Lggr — Data Model (keystone)

This document is the **single source of truth for every type name, field name, and signature** in
Lggr. Later agents copy these declarations verbatim. If an implementation disagrees with this file,
this file wins until it is deliberately amended here.

Field names were cross-checked against `SPEC.md` § *Data model*. Where a name deviates from the
spec, the deviation is called out inline with a reason.

## 0. Where each type lives

| Layer | Target | Contents | Compiles today? |
|---|---|---|---|
| Domain | `Sources/LggrKit/Model/` | enums + value structs | ✅ yes |
| Domain | `Sources/LggrKit/Store/` | `LggrStore` protocol, `StoreError`, `InMemoryStore` | ✅ yes |
| Domain | `Sources/LggrKit/Store/JSONFileStore.swift` | default durable backend | ✅ yes |
| Persistence | `Sources/LggrPersistence/Models/` | `@Model` classes (`SD*`) | ❌ Xcode-only |
| Persistence | `Sources/LggrPersistence/Mapping/` | `toDomain()` / `apply(_:in:)` | ❌ Xcode-only |

Rule from `CONSTRAINTS.md`: **no `@Model`, `#Predicate` or `#Preview` may appear in `LggrKit` or
`LggrApp`.** `#Predicate` *is* allowed inside `LggrPersistence` because that target only ever builds
under Xcode.

### Why value types reference each other by `UUID`, not by object graph

> Domain relationships are plain `UUID` fields (`projectID: UUID?`) rather than nested objects
> because the same value types must round-trip through JSON, through SwiftData, and into SwiftUI
> `Equatable` diffing — an object graph would make them non-`Sendable`, force retain cycles between
> `FocusSession` and `Project`, and make every partial update rewrite unrelated records.

Object-graph traversal is the *persistence layer's* job (`SDFocusSession.project`); the domain
resolves IDs against already-loaded collections, which is cheap at this data volume (a heavy year is
on the order of a few thousand sessions and a few hundred thousand activity events).

---

## 1. Domain enums

All enums are `String`-backed with **explicit** raw values so that a Swift-level rename can never
silently invalidate persisted JSON. All are `Codable`, `CaseIterable`, `Sendable`, and `Identifiable`
(`id == rawValue`) so they drop straight into `Picker(selection:)` and `ForEach`.

`File: Sources/LggrKit/Model/Enums.swift` (may be split one-enum-per-file if it grows).

```swift
import Foundation

// MARK: - WorkType

/// The kind of work a focus session is intended to be. SPEC § 2.
public enum WorkType: String, Codable, CaseIterable, Sendable, Identifiable {
    case deepWork = "deepWork"
    case codeReview = "codeReview"
    case management = "management"
    case communication = "communication"
    case planning = "planning"
    case incident = "incident"
    case meeting = "meeting"
    case administrative = "administrative"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepWork: return "Deep work"
        case .codeReview: return "Code review"
        case .management: return "Management"
        case .communication: return "Communication"
        case .planning: return "Planning"
        case .incident: return "Incident"
        case .meeting: return "Meeting"
        case .administrative: return "Administrative"
        }
    }

    public var symbolName: String {
        switch self {
        case .deepWork: return "brain.head.profile"
        case .codeReview: return "arrow.triangle.pull"
        case .management: return "person.2"
        case .communication: return "bubble.left.and.bubble.right"
        case .planning: return "map"
        case .incident: return "exclamationmark.triangle"
        case .meeting: return "video"
        case .administrative: return "tray.full"
        }
    }

    /// Duration pre-selected by the start sheet. SPEC § 2 "Intelligent defaults":
    /// 50 minutes for deep work, 25 minutes for communication or administrative work.
    public var suggestedDuration: TimeInterval {
        switch self {
        case .deepWork, .codeReview, .incident, .planning: return 50 * 60
        case .communication, .administrative, .management, .meeting: return 25 * 60
        }
    }

    /// Work types that are reactive by nature; seeds `FocusSession.isReactive`.
    /// The user can always override the stored flag.
    public var isReactiveByDefault: Bool {
        switch self {
        case .incident, .communication, .meeting, .administrative: return true
        case .deepWork, .codeReview, .management, .planning: return false
        }
    }
}

// MARK: - SessionResultStatus

/// Answer to "What happened?" on the completion sheet. SPEC § 6. Required field.
public enum SessionResultStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case completed = "completed"
    case madeProgress = "madeProgress"
    case blocked = "blocked"
    case interrupted = "interrupted"
    case reprioritized = "reprioritized"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .madeProgress: return "Made progress"
        case .blocked: return "Blocked"
        case .interrupted: return "Interrupted"
        case .reprioritized: return "Reprioritized"
        }
    }

    public var symbolName: String {
        switch self {
        case .completed: return "checkmark.circle"
        case .madeProgress: return "arrow.forward.circle"
        case .blocked: return "hand.raised"
        case .interrupted: return "bell.badge"
        case .reprioritized: return "arrow.triangle.branch"
        }
    }

    /// Counts toward "focus sessions completed" in the weekly review.
    public var countsAsCompleted: Bool { self == .completed }

    /// Counts toward "sessions interrupted" in the weekly review.
    public var countsAsInterrupted: Bool { self == .interrupted }

    /// True when the intended outcome did not land; used to surface a follow-up prompt.
    /// Never rendered in red or with judgmental copy (SPEC § Design direction).
    public var needsFollowUp: Bool {
        self == .blocked || self == .interrupted || self == .reprioritized
    }
}

// MARK: - ActivityCategory

/// Classification of a tracked activity interval. SPEC § 5.
public enum ActivityCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case coding = "coding"
    case testing = "testing"
    case codeReview = "codeReview"
    case communication = "communication"
    case planning = "planning"
    case research = "research"
    case meeting = "meeting"
    case documentation = "documentation"
    case administrative = "administrative"
    case distraction = "distraction"
    case unknown = "unknown"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .coding: return "Coding"
        case .testing: return "Testing"
        case .codeReview: return "Code review"
        case .communication: return "Communication"
        case .planning: return "Planning"
        case .research: return "Research"
        case .meeting: return "Meeting"
        case .documentation: return "Documentation"
        case .administrative: return "Administrative"
        case .distraction: return "Distraction"
        case .unknown: return "Unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .testing: return "checkmark.diamond"
        case .codeReview: return "arrow.triangle.pull"
        case .communication: return "bubble.left.and.bubble.right"
        case .planning: return "map"
        case .research: return "magnifyingglass"
        case .meeting: return "video"
        case .documentation: return "doc.text"
        case .administrative: return "tray.full"
        case .distraction: return "play.rectangle"
        case .unknown: return "questionmark.circle"
        }
    }

    /// Contributes to "Focused time" on Today. SPEC § 7.
    public var countsAsFocusedTime: Bool {
        switch self {
        case .coding, .testing, .codeReview, .planning, .research, .documentation: return true
        case .communication, .meeting, .administrative, .distraction, .unknown: return false
        }
    }

    /// Contributes to "Reactive time" on Today. SPEC § 7.
    public var countsAsReactiveTime: Bool {
        switch self {
        case .communication, .meeting, .administrative: return true
        default: return false
        }
    }

    public var isDistraction: Bool { self == .distraction }
}

// MARK: - AccomplishmentType

/// The 11 accomplishment types. SPEC § 10, in spec order.
public enum AccomplishmentType: String, Codable, CaseIterable, Sendable, Identifiable {
    case featureCompleted = "featureCompleted"
    case pullRequestOpened = "pullRequestOpened"
    case pullRequestReviewed = "pullRequestReviewed"
    case decisionMade = "decisionMade"
    case personUnblocked = "personUnblocked"
    case incidentResolved = "incidentResolved"
    case customerIssueResolved = "customerIssueResolved"
    case documentWritten = "documentWritten"
    case riskIdentified = "riskIdentified"
    case workDeprioritized = "workDeprioritized"
    case other = "other"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .featureCompleted: return "Feature completed"
        case .pullRequestOpened: return "Pull request opened"
        case .pullRequestReviewed: return "Pull request reviewed"
        case .decisionMade: return "Decision made"
        case .personUnblocked: return "Person unblocked"
        case .incidentResolved: return "Incident resolved"
        case .customerIssueResolved: return "Customer issue resolved"
        case .documentWritten: return "Document written"
        case .riskIdentified: return "Risk identified"
        case .workDeprioritized: return "Work intentionally deprioritized"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .featureCompleted: return "shippingbox"
        case .pullRequestOpened: return "arrow.triangle.branch"
        case .pullRequestReviewed: return "arrow.triangle.pull"
        case .decisionMade: return "signpost.right"
        case .personUnblocked: return "person.crop.circle.badge.checkmark"
        case .incidentResolved: return "flame"
        case .customerIssueResolved: return "person.badge.shield.checkmark"
        case .documentWritten: return "doc.text"
        case .riskIdentified: return "exclamationmark.shield"
        case .workDeprioritized: return "arrow.down.circle"
        case .other: return "circle"
        }
    }

    /// Types counted under "people or workstreams unblocked" in the weekly review. SPEC § 9.
    public var countsAsUnblockingOthers: Bool {
        self == .personUnblocked || self == .pullRequestReviewed
    }
}

// MARK: - OutcomePriority

/// SPEC § 8: one primary outcome, up to two secondary, plus operational responsibilities.
public enum OutcomePriority: String, Codable, CaseIterable, Sendable, Identifiable {
    case primary = "primary"
    case secondary = "secondary"
    case operational = "operational"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case .operational: return "Operational"
        }
    }

    public var symbolName: String {
        switch self {
        case .primary: return "star"
        case .secondary: return "circle.hexagongrid"
        case .operational: return "gearshape"
        }
    }

    /// Soft cap enforced by the weekly-outcome editor. `nil` means unlimited.
    /// Exceeding it is a gentle inline hint, never a blocking error.
    public var maximumPerWeek: Int? {
        switch self {
        case .primary: return 1
        case .secondary: return 2
        case .operational: return nil
        }
    }

    /// Display order in lists.
    public var sortOrder: Int {
        switch self {
        case .primary: return 0
        case .secondary: return 1
        case .operational: return 2
        }
    }
}

// MARK: - OutcomeStatus

public enum OutcomeStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case notStarted = "notStarted"
    case inProgress = "inProgress"
    case atRisk = "atRisk"
    case achieved = "achieved"
    case carriedOver = "carriedOver"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .notStarted: return "Not started"
        case .inProgress: return "In progress"
        case .atRisk: return "At risk"
        case .achieved: return "Achieved"
        case .carriedOver: return "Carried over"
        }
    }

    public var symbolName: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .atRisk: return "exclamationmark.circle"
        case .achieved: return "checkmark.circle.fill"
        case .carriedOver: return "arrow.uturn.forward.circle"
        }
    }

    public var isTerminal: Bool { self == .achieved || self == .carriedOver }
}

// MARK: - InterruptionStatus

/// Lifecycle of an item in the interruption inbox. SPEC § 3 / § 7.
public enum InterruptionStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case inbox = "inbox"
    case converted = "converted"
    case resolved = "resolved"
    case dismissed = "dismissed"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .converted: return "Converted"
        case .resolved: return "Resolved"
        case .dismissed: return "Dismissed"
        }
    }

    public var symbolName: String {
        switch self {
        case .inbox: return "tray"
        case .converted: return "arrow.right.circle"
        case .resolved: return "checkmark.circle"
        case .dismissed: return "xmark.circle"
        }
    }

    /// Still needs the user's attention — drives the inbox badge count on Today.
    public var isOpen: Bool { self == .inbox }
}

// MARK: - InterruptionSource

/// Where the interruption came from. Powers "most common interruption sources". SPEC § 9.
public enum InterruptionSource: String, Codable, CaseIterable, Sendable, Identifiable {
    case person = "person"
    case chat = "chat"
    case email = "email"
    case meeting = "meeting"
    case incident = "incident"
    case notification = "notification"
    case selfInitiated = "selfInitiated"
    case other = "other"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .person: return "Person"
        case .chat: return "Chat"
        case .email: return "Email"
        case .meeting: return "Meeting"
        case .incident: return "Incident"
        case .notification: return "Notification"
        case .selfInitiated: return "Self-initiated"
        case .other: return "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .person: return "person"
        case .chat: return "bubble.left"
        case .email: return "envelope"
        case .meeting: return "video"
        case .incident: return "exclamationmark.triangle"
        case .notification: return "bell"
        case .selfInitiated: return "arrow.uturn.backward"
        case .other: return "circle"
        }
    }
}

// MARK: - RuleMatchType

/// What field of an activity event a classification rule matches against. SPEC § 5.
///
/// SPEC lists "Application, Window title text, Browser domain, Project, Work type" as rule inputs.
/// Project and work type are *scopes* on `ClassificationRule` (`projectID`, `workType`) rather than
/// match subjects, because they qualify a rule rather than identify an activity — this is what makes
/// "Claude → Research or Coding, depending on the active project" expressible with two rules.
public enum RuleMatchType: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Case-insensitive exact match against `ActivityEvent.bundleIdentifier`.
    case application = "application"
    /// Case-insensitive exact match against `ActivityEvent.applicationName`.
    case applicationName = "applicationName"
    /// Case-insensitive substring match against `ActivityEvent.windowTitle`.
    case windowTitleContains = "windowTitleContains"
    /// Case-insensitive exact-or-suffix match against `ActivityEvent.domain`
    /// (`github.com` matches `gist.github.com`).
    case domain = "domain"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .application: return "Application bundle ID"
        case .applicationName: return "Application name"
        case .windowTitleContains: return "Window title contains"
        case .domain: return "Browser domain"
        }
    }

    public var symbolName: String {
        switch self {
        case .application: return "app.badge"
        case .applicationName: return "app"
        case .windowTitleContains: return "text.magnifyingglass"
        case .domain: return "globe"
        }
    }

    /// Placeholder text for the rule editor's value field.
    public var valuePlaceholder: String {
        switch self {
        case .application: return "com.apple.dt.Xcode"
        case .applicationName: return "Xcode"
        case .windowTitleContains: return "Pull request"
        case .domain: return "github.com"
        }
    }
}

// MARK: - ClassificationSource

/// How an `ActivityEvent` got its category. Manual always outranks automatic.
public enum ClassificationSource: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Matched a rule shipped with the app.
    case defaultRule = "defaultRule"
    /// Matched a rule the user created or edited.
    case userRule = "userRule"
    /// The user corrected the category directly on the timeline.
    case manual = "manual"
    /// No rule matched; category is `.unknown`.
    case unclassified = "unclassified"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .defaultRule: return "Default rule"
        case .userRule: return "Your rule"
        case .manual: return "Set by you"
        case .unclassified: return "Unclassified"
        }
    }

    public var symbolName: String {
        switch self {
        case .defaultRule: return "sparkles"
        case .userRule: return "slider.horizontal.3"
        case .manual: return "hand.point.up.left"
        case .unclassified: return "questionmark"
        }
    }

    /// Re-running the classifier must never overwrite a manual correction.
    public var isLockedFromReclassification: Bool { self == .manual }
}

// MARK: - SessionState

/// Derived lifecycle state of a `FocusSession`. Never stored — see `FocusSession.state`.
public enum SessionState: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Clock is advancing.
    case running = "running"
    /// Clock is held; `pauseStartedAt` is non-nil.
    case paused = "paused"
    /// `endedAt` is set but the user has not chosen a `resultStatus` yet.
    case awaitingReview = "awaitingReview"
    /// Ended and reviewed.
    case completed = "completed"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .running: return "Running"
        case .paused: return "Paused"
        case .awaitingReview: return "Awaiting review"
        case .completed: return "Completed"
        }
    }

    /// Menu bar icon. The icon communicates state without being distracting (SPEC § 1).
    public var symbolName: String {
        switch self {
        case .running: return "timer"
        case .paused: return "pause.circle"
        case .awaitingReview: return "questionmark.circle"
        case .completed: return "checkmark.circle"
        }
    }

    public var isActive: Bool { self == .running || self == .paused }
}
```

---

## 2. Domain value types

All are `Identifiable` (`id: UUID`), `Codable`, `Hashable`, `Sendable`. Explicit `public init`s are
mandatory — a synthesised memberwise initialiser is internal and unusable from `LggrApp`.

`id` and `createdAt` are `let`; everything a user can change is `var`.

### 2.1 Project

`File: Sources/LggrKit/Model/Project.swift` — SPEC: *id, name, color identifier, icon identifier,
isActive, createdAt, updatedAt*.

```swift
import Foundation

public struct Project: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// Token from `Project.colorIDs`. Stored as a string so the palette can grow without a migration.
    public var colorID: String
    /// SF Symbol name.
    public var iconID: String
    public var isActive: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        colorID: String = Project.defaultColorID,
        iconID: String = Project.defaultIconID,
        isActive: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorID = colorID
        self.iconID = iconID
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Project {
    public static let defaultColorID = "blue"
    public static let defaultIconID = "folder"

    /// The full palette offered by the project editor. `LggrApp` maps these to `Color`.
    public static let colorIDs: [String] = [
        "blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "graphite"
    ]

    /// Suggested icons in the project editor; any SF Symbol name is accepted.
    public static let iconIDs: [String] = [
        "folder", "hammer", "cube", "chart.bar", "person.2", "wrench.and.screwdriver",
        "cart", "server.rack", "paintbrush", "book"
    ]
}
```

### 2.2 WeeklyOutcome

`File: Sources/LggrKit/Model/WeeklyOutcome.swift` — SPEC: *id, title, details, priority, status,
progress, weekStartDate, createdAt, updatedAt* plus § 8's *linked projects*.

```swift
import Foundation

public struct WeeklyOutcome: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var details: String?
    public var priority: OutcomePriority
    public var status: OutcomeStatus
    /// 0.0 ... 1.0. Clamped on init; the UI binds a slider over the same range.
    public var progress: Double
    /// Midnight at the start of the week, in the user's calendar. Use `Calendar.weekStart(for:)`.
    public var weekStartDate: Date
    /// Forward links to projects (SPEC § 8). Linked focus sessions and accomplishments are
    /// back-references via `FocusSession.weeklyOutcomeID` / `Accomplishment.weeklyOutcomeID`.
    public var projectIDs: [UUID]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        details: String? = nil,
        priority: OutcomePriority = .primary,
        status: OutcomeStatus = .notStarted,
        progress: Double = 0,
        weekStartDate: Date,
        projectIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priority = priority
        self.status = status
        self.progress = min(max(progress, 0), 1)
        self.weekStartDate = weekStartDate
        self.projectIDs = projectIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension WeeklyOutcome {
    /// 0 ... 100, for the label next to the progress bar.
    public var progressPercent: Int { Int((min(max(progress, 0), 1) * 100).rounded()) }
}
```

### 2.3 FocusSession

`File: Sources/LggrKit/Model/FocusSession.swift` — SPEC: *id, project, weeklyOutcome,
intendedOutcome, workType, plannedDuration, startedAt, endedAt, pausedDuration, resultStatus,
resultSummary, blocker, nextStep, isReactive, interruptionCount*.

**One addition to the spec's field list:** `pauseStartedAt: Date?`. `pausedDuration` alone cannot
represent a pause that is currently *open* — without it, a paused session's clock keeps advancing
until resume. See § 3.

```swift
import Foundation

public struct FocusSession: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var weeklyOutcomeID: UUID?
    /// Required by SPEC § 2. Never empty for a persisted session.
    public var intendedOutcome: String
    public var workType: WorkType
    /// `nil` means open-ended (count up, no target). SPEC § 2 duration options.
    public var plannedDuration: TimeInterval?
    public let startedAt: Date
    public var endedAt: Date?
    /// Sum of all *closed* pause intervals, in seconds. Never negative. See § 3.
    public var pausedDuration: TimeInterval
    /// Start of the pause currently in effect, or `nil` when running. See § 3.
    public var pauseStartedAt: Date?
    /// `nil` until the completion sheet is answered.
    public var resultStatus: SessionResultStatus?
    public var resultSummary: String?
    public var blocker: String?
    public var nextStep: String?
    /// Started in response to something unplanned rather than from a weekly outcome.
    /// Seeded from `workType.isReactiveByDefault` / absence of `weeklyOutcomeID`; user-overridable.
    public var isReactive: Bool
    /// Denormalised count of `Interruption`s captured during this session. Maintained by
    /// `SessionManager` when an interruption is saved; recomputable from the interruption store.
    public var interruptionCount: Int

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        weeklyOutcomeID: UUID? = nil,
        intendedOutcome: String,
        workType: WorkType = .deepWork,
        plannedDuration: TimeInterval? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        pausedDuration: TimeInterval = 0,
        pauseStartedAt: Date? = nil,
        resultStatus: SessionResultStatus? = nil,
        resultSummary: String? = nil,
        blocker: String? = nil,
        nextStep: String? = nil,
        isReactive: Bool = false,
        interruptionCount: Int = 0
    ) {
        self.id = id
        self.projectID = projectID
        self.weeklyOutcomeID = weeklyOutcomeID
        self.intendedOutcome = intendedOutcome
        self.workType = workType
        self.plannedDuration = plannedDuration
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedDuration = max(0, pausedDuration)
        self.pauseStartedAt = pauseStartedAt
        self.resultStatus = resultStatus
        self.resultSummary = resultSummary
        self.blocker = blocker
        self.nextStep = nextStep
        self.isReactive = isReactive
        self.interruptionCount = max(0, interruptionCount)
    }
}
```

### 2.4 ActivityEvent

`File: Sources/LggrKit/Model/ActivityEvent.swift` — SPEC: *id, focusSession, applicationName,
bundleIdentifier, windowTitle, domain, category, startedAt, endedAt, isIdle, isPrivate,
classificationSource*.

```swift
import Foundation

public struct ActivityEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// `nil` for activity captured outside any focus session.
    public var focusSessionID: UUID?
    public var applicationName: String
    public var bundleIdentifier: String
    /// `nil` when Accessibility permission is unavailable or title tracking is disabled.
    public var windowTitle: String?
    /// Browser host, when it can be read safely.
    public var domain: String?
    public var category: ActivityCategory
    public let startedAt: Date
    /// `nil` while the interval is still open (this is the frontmost app right now).
    public var endedAt: Date?
    public var isIdle: Bool
    /// The application is on the user's private list. See `redacted` below.
    public var isPrivate: Bool
    public var classificationSource: ClassificationSource

    public init(
        id: UUID = UUID(),
        focusSessionID: UUID? = nil,
        applicationName: String,
        bundleIdentifier: String,
        windowTitle: String? = nil,
        domain: String? = nil,
        category: ActivityCategory = .unknown,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        isIdle: Bool = false,
        isPrivate: Bool = false,
        classificationSource: ClassificationSource = .unclassified
    ) {
        self.id = id
        self.focusSessionID = focusSessionID
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.domain = domain
        self.category = category
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isIdle = isIdle
        self.isPrivate = isPrivate
        self.classificationSource = classificationSource
    }
}

extension ActivityEvent {
    /// Display label for the timeline.
    public static let privatePlaceholder = "Private activity"

    public var isOpen: Bool { endedAt == nil }

    /// Seconds covered by this interval. For an open interval, measured against `now`.
    public func duration(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }

    public var displayName: String { isPrivate ? Self.privatePlaceholder : applicationName }

    /// SPEC § 4: "When an application is marked private, store only 'Private activity'.
    /// Do not store the title or bundle information."
    /// The tracker calls this **before handing the event to the store** — redaction happens at
    /// write time, never at read time, so private data is never on disk.
    public func redactedIfPrivate() -> ActivityEvent {
        guard isPrivate else { return self }
        var copy = self
        copy.applicationName = Self.privatePlaceholder
        copy.bundleIdentifier = ""
        copy.windowTitle = nil
        copy.domain = nil
        copy.category = .unknown
        copy.classificationSource = .unclassified
        return copy
    }
}
```

### 2.5 Interruption

`File: Sources/LggrKit/Model/Interruption.swift` — SPEC: *id, focusSession, description, source,
timestamp, status, convertedProject*.

**Deviation:** the spec's `description` is named **`note`**. A stored property called `description`
on a struct implicitly satisfies `CustomStringConvertible` and shadows the compiler-synthesised
description used by logging and test failure messages — a real trap for later agents. `note` also
matches the UI copy ("Add a note").

```swift
import Foundation

public struct Interruption: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The session that was running when this was captured; `nil` if captured with no session.
    public var focusSessionID: UUID?
    /// SPEC calls this `description`. Renamed to avoid `CustomStringConvertible` shadowing.
    public var note: String
    public var source: InterruptionSource
    public var timestamp: Date
    public var status: InterruptionStatus
    /// Set when the user turns an inbox item into work on a project. SPEC's `convertedProject`.
    public var convertedProjectID: UUID?

    public init(
        id: UUID = UUID(),
        focusSessionID: UUID? = nil,
        note: String,
        source: InterruptionSource = .other,
        timestamp: Date = Date(),
        status: InterruptionStatus = .inbox,
        convertedProjectID: UUID? = nil
    ) {
        self.id = id
        self.focusSessionID = focusSessionID
        self.note = note
        self.source = source
        self.timestamp = timestamp
        self.status = status
        self.convertedProjectID = convertedProjectID
    }
}
```

### 2.6 Accomplishment

`File: Sources/LggrKit/Model/Accomplishment.swift` — SPEC: *id, project, weeklyOutcome,
focusSession, type, title, details, timestamp*.

```swift
import Foundation

public struct Accomplishment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var projectID: UUID?
    public var weeklyOutcomeID: UUID?
    /// Non-nil when generated from a completed session. SPEC § 10.
    public var focusSessionID: UUID?
    public var type: AccomplishmentType
    public var title: String
    public var details: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        weeklyOutcomeID: UUID? = nil,
        focusSessionID: UUID? = nil,
        type: AccomplishmentType = .other,
        title: String,
        details: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.weeklyOutcomeID = weeklyOutcomeID
        self.focusSessionID = focusSessionID
        self.type = type
        self.title = title
        self.details = details
        self.timestamp = timestamp
    }
}

extension Accomplishment {
    /// True when this row came out of a session rather than manual entry.
    public var isGeneratedFromSession: Bool { focusSessionID != nil }
}
```

### 2.7 ClassificationRule

`File: Sources/LggrKit/Model/ClassificationRule.swift` — SPEC: *id, matchType, matchValue, category,
project, priority, isEnabled*.

`workType` is added as a second optional scope so that SPEC § 5's five rule inputs (application,
window title, domain, project, work type) are all expressible.

```swift
import Foundation

public struct ClassificationRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var matchType: RuleMatchType
    public var matchValue: String
    public var category: ActivityCategory
    /// Scope: only apply when the running session belongs to this project. `nil` = any project.
    public var projectID: UUID?
    /// Scope: only apply when the running session has this work type. `nil` = any work type.
    public var workType: WorkType?
    /// Higher wins. Ties break toward the more specific rule (see `specificity`), then `id`.
    public var priority: Int
    public var isEnabled: Bool
    /// False for rules shipped with the app; drives `ClassificationSource` and the "Reset to
    /// defaults" action in Settings › Rules.
    public var isUserDefined: Bool

    public init(
        id: UUID = UUID(),
        matchType: RuleMatchType,
        matchValue: String,
        category: ActivityCategory,
        projectID: UUID? = nil,
        workType: WorkType? = nil,
        priority: Int = 0,
        isEnabled: Bool = true,
        isUserDefined: Bool = true
    ) {
        self.id = id
        self.matchType = matchType
        self.matchValue = matchValue
        self.category = category
        self.projectID = projectID
        self.workType = workType
        self.priority = priority
        self.isEnabled = isEnabled
        self.isUserDefined = isUserDefined
    }
}

extension ClassificationRule {
    /// Scoped rules beat unscoped ones at equal `priority`.
    public var specificity: Int {
        (projectID == nil ? 0 : 2) + (workType == nil ? 0 : 1)
    }

    public var source: ClassificationSource { isUserDefined ? .userRule : .defaultRule }

    /// Deterministic, pure, and unit-tested (SPEC § Testing requirements: "rule matching").
    /// `sessionProjectID` / `sessionWorkType` describe the session that was running when the
    /// event was captured; pass `nil` for activity outside a session.
    public func matches(
        _ event: ActivityEvent,
        sessionProjectID: UUID?,
        sessionWorkType: WorkType?
    ) -> Bool {
        guard isEnabled, !event.isPrivate else { return false }
        if let projectID, projectID != sessionProjectID { return false }
        if let workType, workType != sessionWorkType { return false }

        let needle = matchValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }

        switch matchType {
        case .application:
            return event.bundleIdentifier.lowercased() == needle
        case .applicationName:
            return event.applicationName.lowercased() == needle
        case .windowTitleContains:
            guard let title = event.windowTitle?.lowercased() else { return false }
            return title.contains(needle)
        case .domain:
            guard let host = event.domain?.lowercased() else { return false }
            return host == needle || host.hasSuffix("." + needle)
        }
    }
}
```

### 2.8 UserPreferences

`File: Sources/LggrKit/Model/UserPreferences.swift` — SPEC: *defaultSessionDuration, globalShortcut,
trackWindowTitles, idleThreshold, excludedApplications, privateApplications, dataRetentionDays,
launchAtLogin, showTimerInMenuBar*. The notification toggles (SPEC § Notifications), the tracking
pause switch (SPEC § 4) and `lastSelectedProjectID` (SPEC § 2 "Remember the last selected project")
are added because they are preference-shaped and have nowhere else to live.

```swift
import Foundation

/// A serialisable description of a global hot key. Deliberately framework-free so `LggrKit`
/// does not import AppKit; `LggrApp` converts it to an `NSEvent.ModifierFlags` + key equivalent.
public struct KeyboardShortcutSpec: Codable, Hashable, Sendable {
    /// The unmodified character, e.g. `" "` for Space, `"n"` for N.
    public var keyEquivalent: String
    /// Raw value of `NSEvent.ModifierFlags` restricted to command/shift/option/control.
    public var modifierFlags: UInt

    public init(keyEquivalent: String, modifierFlags: UInt) {
        self.keyEquivalent = keyEquivalent
        self.modifierFlags = modifierFlags
    }

    /// Command + Shift + Space. SPEC § 1 suggested default.
    /// 1 << 20 = command, 1 << 17 = shift (NSEvent.ModifierFlags raw values).
    public static let defaultStartSession = KeyboardShortcutSpec(
        keyEquivalent: " ",
        modifierFlags: (1 << 20) | (1 << 17)
    )
}

public struct UserPreferences: Identifiable, Codable, Hashable, Sendable {
    /// Fixed: preferences are a singleton. Present only so preferences satisfy the same
    /// `Identifiable` constraint as every other domain value type.
    public let id: UUID = UserPreferences.singletonID
    public static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")
        ?? UUID()

    // Sessions
    public var defaultSessionDuration: TimeInterval
    public var globalShortcut: KeyboardShortcutSpec?

    // Tracking + privacy
    public var trackWindowTitles: Bool
    /// Seconds of no input before activity is marked `isIdle`.
    public var idleThreshold: TimeInterval
    /// Bundle identifiers that are not tracked at all.
    public var excludedApplications: [String]
    /// Bundle identifiers stored only as "Private activity".
    public var privateApplications: [String]
    /// `nil` = keep forever. Otherwise activity older than this many days is purged.
    public var dataRetentionDays: Int?
    /// Master switch for the activity tracker. SPEC § 4 "Pause tracking".
    public var trackingPaused: Bool

    // System integration
    public var launchAtLogin: Bool
    public var showTimerInMenuBar: Bool

    // Notifications (SPEC § Notifications)
    public var notifyOnSessionCompleted: Bool
    public var notifyAtHalfway: Bool
    public var notifyOnLongIdle: Bool

    // Remembered UI state (SPEC § 2 "Intelligent defaults")
    public var lastSelectedProjectID: UUID?
    /// Set once onboarding has been completed, so it is never shown twice.
    public var hasCompletedOnboarding: Bool

    public init(
        defaultSessionDuration: TimeInterval = 50 * 60,
        globalShortcut: KeyboardShortcutSpec? = .defaultStartSession,
        trackWindowTitles: Bool = true,
        idleThreshold: TimeInterval = 5 * 60,
        excludedApplications: [String] = [],
        privateApplications: [String] = [],
        dataRetentionDays: Int? = 90,
        trackingPaused: Bool = false,
        launchAtLogin: Bool = false,
        showTimerInMenuBar: Bool = true,
        notifyOnSessionCompleted: Bool = true,
        notifyAtHalfway: Bool = false,
        notifyOnLongIdle: Bool = true,
        lastSelectedProjectID: UUID? = nil,
        hasCompletedOnboarding: Bool = false
    ) {
        self.defaultSessionDuration = defaultSessionDuration
        self.globalShortcut = globalShortcut
        self.trackWindowTitles = trackWindowTitles
        self.idleThreshold = idleThreshold
        self.excludedApplications = excludedApplications
        self.privateApplications = privateApplications
        self.dataRetentionDays = dataRetentionDays
        self.trackingPaused = trackingPaused
        self.launchAtLogin = launchAtLogin
        self.showTimerInMenuBar = showTimerInMenuBar
        self.notifyOnSessionCompleted = notifyOnSessionCompleted
        self.notifyAtHalfway = notifyAtHalfway
        self.notifyOnLongIdle = notifyOnLongIdle
        self.lastSelectedProjectID = lastSelectedProjectID
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

extension UserPreferences {
    public func isExcluded(bundleIdentifier: String) -> Bool {
        excludedApplications.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    public func isPrivate(bundleIdentifier: String) -> Bool {
        privateApplications.contains { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
    }

    /// Oldest activity timestamp worth keeping, or `nil` when retention is unlimited.
    public func retentionCutoff(from now: Date, calendar: Calendar = .current) -> Date? {
        guard let days = dataRetentionDays, days > 0 else { return nil }
        return calendar.date(byAdding: .day, value: -days, to: now)
    }
}
```

> `id` is declared `public let id: UUID = ...` with an initial value, so it is not part of the
> memberwise init and `Codable` will simply ignore any decoded value for it. That is intended.

---

## 3. FocusSession timing — the exact pause arithmetic

This is the most bug-prone code in the app. It is deliberately expressed as **pure functions of
stored `Date`s** rather than as a mutable tick counter.

`File: Sources/LggrKit/Model/FocusSession+Timing.swift`

### 3.1 The model in words

A session occupies wall-clock time from `startedAt` to `endedAt ?? now`. Inside that span there are
zero or more **pause intervals**. `pausedDuration` is the sum of all pause intervals that have been
*closed*; `pauseStartedAt` marks the one pause interval that is still *open*, if any.

```
elapsed(now) = (endedAt ?? now) − startedAt  −  totalPausedDuration(now)

totalPausedDuration(now) = pausedDuration
                         + (pauseStartedAt.map { (endedAt ?? now) − $0 } ?? 0)
```

Every subtraction is clamped at zero, so a backwards clock adjustment can shorten but never
invert a duration.

### 3.2 Behaviour across multiple pause/resume cycles

`pause` opens an interval, `resume` closes it and folds its length into `pausedDuration`. Nothing
else mutates `pausedDuration`. Worked example, 50-minute plan:

| Wall clock | Action | `pausedDuration` | `pauseStartedAt` | `elapsed` |
|---|---|---|---|---|
| 09:00 | start | 0 | nil | 0:00 |
| 09:10 | — | 0 | nil | 10:00 |
| 09:10 | **pause** | 0 | 09:10 | 10:00 |
| 09:13 | — (still paused) | 0 | 09:10 | 10:00 *(frozen)* |
| 09:15 | **resume** | 300 | nil | 10:00 |
| 09:40 | — | 300 | nil | 35:00 |
| 09:40 | **pause** | 300 | 09:40 | 35:00 |
| 09:50 | **resume** | 900 | nil | 35:00 |
| 10:00 | **finish** | 900 | nil | 45:00, `remaining` 5:00 |

`endedAt = 10:00`, raw span 60:00, `totalPausedDuration = 900`, `elapsed = 2700 s`. Two cycles
accumulate additively; N cycles accumulate additively. Because `elapsed` is recomputed from dates,
a dropped timer tick, an app relaunch, or a display-sleep gap cannot drift the number.

### 3.3 Invariants

1. `pausedDuration >= 0` always.
2. `pauseStartedAt != nil` ⟹ the session is paused ⟹ `elapsed(at:)` is constant over `now`.
3. A finished session (`endedAt != nil`) has `pauseStartedAt == nil` — `finish` closes any open
   pause first. The computed properties still behave correctly if a corrupt record violates this,
   by closing the pause at `endedAt`.
4. For a finished session, `elapsed(at:)` returns the same value for every `now`.
5. `elapsed` is non-decreasing in `now` while running, and never exceeds
   `(endedAt ?? now) − startedAt`.
6. `elapsed` is **not** "focused time". Focused time is aggregated from `ActivityEvent`s (idle and
   category aware); `elapsed` is only the session clock. Machine sleep therefore inflates `elapsed`
   and does *not* inflate focused time — that difference is exactly the "idle time" reported on the
   completion sheet.
7. The UI never increments a counter. A 1 Hz `Timer` (or `TimelineView`) simply re-renders
   `elapsed(at: Date())`.

### 3.4 Code

```swift
import Foundation

extension FocusSession {

    // MARK: Derived state

    public var state: SessionState {
        if endedAt == nil {
            return pauseStartedAt == nil ? .running : .paused
        }
        return resultStatus == nil ? .awaitingReview : .completed
    }

    /// The clock is advancing right now.
    public var isRunning: Bool { endedAt == nil && pauseStartedAt == nil }

    public var isPaused: Bool { endedAt == nil && pauseStartedAt != nil }

    public var isFinished: Bool { endedAt != nil }

    /// No target duration: the timer counts up. SPEC § 2 "Open-ended".
    public var isOpenEnded: Bool { plannedDuration == nil }

    // MARK: Durations

    /// Total time spent paused, including any pause that is still open.
    public func totalPausedDuration(at now: Date) -> TimeInterval {
        guard let pauseStartedAt else { return max(0, pausedDuration) }
        let reference = endedAt ?? now
        return max(0, pausedDuration) + max(0, reference.timeIntervalSince(pauseStartedAt))
    }

    /// Active session time: wall clock since `startedAt`, minus every pause.
    /// Frozen while paused; constant once finished.
    public func elapsed(at now: Date) -> TimeInterval {
        let end = endedAt ?? now
        let span = max(0, end.timeIntervalSince(startedAt))
        return max(0, span - totalPausedDuration(at: now))
    }

    /// Time left against `plannedDuration`, floored at zero.
    /// `nil` for open-ended sessions — the UI shows a count-up instead of a countdown.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let plannedDuration else { return nil }
        return max(0, plannedDuration - elapsed(at: now))
    }

    /// Seconds run past `plannedDuration`. Zero when on time or open-ended.
    /// After the countdown hits zero the menu bar switches to `+M:SS` using this value.
    public func overrun(at now: Date) -> TimeInterval {
        guard let plannedDuration else { return 0 }
        return max(0, elapsed(at: now) - plannedDuration)
    }

    /// Fraction of the planned duration completed, 0...1. `nil` when open-ended.
    /// Drives the ring in the active-session view.
    public func progress(at now: Date) -> Double? {
        guard let plannedDuration, plannedDuration > 0 else { return nil }
        return min(1, max(0, elapsed(at: now) / plannedDuration))
    }

    /// Active duration of a **finished** session. Returns 0 while the session is still running,
    /// which forces live UI to use `elapsed(at:)` and keeps every aggregate deterministic.
    /// All weekly/daily totals use this, because they only ever aggregate finished sessions.
    public var effectiveDuration: TimeInterval {
        guard let endedAt else { return 0 }
        return elapsed(at: endedAt)
    }

    /// Wall-clock span, pauses included. Used to place the block on the day timeline.
    public var wallClockInterval: DateInterval? {
        guard let endedAt else { return nil }
        return DateInterval(start: startedAt, end: max(startedAt, endedAt))
    }

    // MARK: Transitions — pure, total, idempotent

    /// No-op if already paused or already finished.
    public mutating func pause(at date: Date) {
        guard endedAt == nil, pauseStartedAt == nil else { return }
        pauseStartedAt = max(date, startedAt)
    }

    /// Closes the open pause and folds it into `pausedDuration`.
    /// No-op if not paused or already finished. A backwards clock adds zero.
    public mutating func resume(at date: Date) {
        guard endedAt == nil, let openedAt = pauseStartedAt else { return }
        pausedDuration = max(0, pausedDuration) + max(0, date.timeIntervalSince(openedAt))
        pauseStartedAt = nil
    }

    /// Closes any open pause, then ends the session. No-op if already finished.
    /// `endedAt` is clamped so it can never precede `startedAt`.
    public mutating func finish(at date: Date, status: SessionResultStatus? = nil) {
        guard endedAt == nil else { return }
        resume(at: date)              // closes an open pause at `date`
        endedAt = max(date, startedAt)
        if let status { resultStatus = status }
    }

    /// Toggle bound to the Space key on the active session. SPEC § Keyboard experience.
    public mutating func togglePause(at date: Date) {
        isPaused ? resume(at: date) : pause(at: date)
    }
}
```

### 3.5 Edge cases and the expected result

| Case | Result |
|---|---|
| `pause` twice in a row | second call is a no-op; one open interval |
| `resume` without a pause | no-op |
| `finish` while paused | pause closed at the finish instant, then `endedAt` set |
| `finish` twice | second call is a no-op; `endedAt` never moves |
| `resume` with `date < pauseStartedAt` (clock moved back) | adds `0`, pause closes |
| `finish` with `date < startedAt` | `endedAt = startedAt`, `elapsed == 0` |
| Machine sleeps 30 min mid-session | `elapsed` grows by 30 min; focused time (from activity events) does not; the delta shows as idle |
| App relaunches mid-session | `LggrStore.activeSession()` restores it; `elapsed` recomputes exactly, including a pause that was open at quit |
| Open-ended session | `remaining` and `progress` are `nil`; `overrun` is `0` |

---

## 4. Store protocol

### The choice

> **One protocol, `LggrStore`, covering all seven aggregates**, because Lggr only ever has one live
> backend (`JSONFileStore` today, `SwiftDataStore` under Xcode) plus one shared `InMemoryStore` fake
> — splitting it into seven protocols would multiply types that are never composed independently,
> while the single shared fake already makes every aggregate testable in isolation.

The protocol is `@MainActor` (SwiftData's `ModelContext` is main-actor bound and views own the
stores) and `async throws` (so `JSONFileStore` can hop to a background actor for encoding and atomic
writes without changing any call site).

`LggrApp` never touches `LggrStore` from a view. `@Observable` app-level stores (`SessionStore`,
`TodayStore`, …) sit on top of it and are injected through the SwiftUI environment.

`File: Sources/LggrKit/Store/LggrStore.swift`

```swift
import Foundation

public enum StoreError: Error, Sendable, Equatable {
    case notFound(UUID)
    case invalidData(String)
    case persistenceFailure(String)
}

/// Every method is an upsert-by-`id` or a load. There is no partial-update API: the domain owns
/// whole values, so callers mutate a value and save it back.
@MainActor
public protocol LggrStore: AnyObject {

    // MARK: Projects
    func loadProjects() async throws -> [Project]
    func saveProject(_ project: Project) async throws
    /// Never cascades. Sessions, accomplishments, rules and interruptions that referenced the
    /// project keep their history and have their `projectID` cleared.
    func deleteProject(id: UUID) async throws

    // MARK: Weekly outcomes
    func loadWeeklyOutcomes(weekStarting: Date) async throws -> [WeeklyOutcome]
    func loadWeeklyOutcomes(in interval: DateInterval) async throws -> [WeeklyOutcome]
    func saveWeeklyOutcome(_ outcome: WeeklyOutcome) async throws
    func deleteWeeklyOutcome(id: UUID) async throws

    // MARK: Focus sessions
    /// Sessions whose `startedAt` falls inside `interval`, newest first.
    func loadSessions(in interval: DateInterval) async throws -> [FocusSession]
    func loadSession(id: UUID) async throws -> FocusSession?
    /// The most recent session with `endedAt == nil`. Used for crash / relaunch recovery.
    func loadActiveSession() async throws -> FocusSession?
    func saveSession(_ session: FocusSession) async throws
    func deleteSession(id: UUID) async throws

    // MARK: Activity
    func loadActivityEvents(in interval: DateInterval) async throws -> [ActivityEvent]
    func loadActivityEvents(sessionID: UUID) async throws -> [ActivityEvent]
    /// Batched: the tracker flushes closed intervals in bursts.
    func saveActivityEvents(_ events: [ActivityEvent]) async throws
    /// Retention policy enforcement. SPEC § 4 "Define retention duration".
    func deleteActivityEvents(startedBefore date: Date) async throws
    /// SPEC § 4 "Delete activity history". Removes every `ActivityEvent` and nothing else.
    func deleteAllActivityEvents() async throws

    // MARK: Interruptions
    func loadInterruptions(in interval: DateInterval) async throws -> [Interruption]
    func loadInterruptions(status: InterruptionStatus) async throws -> [Interruption]
    func saveInterruption(_ interruption: Interruption) async throws
    func deleteInterruption(id: UUID) async throws

    // MARK: Accomplishments
    func loadAccomplishments(in interval: DateInterval) async throws -> [Accomplishment]
    func saveAccomplishment(_ accomplishment: Accomplishment) async throws
    func deleteAccomplishment(id: UUID) async throws

    // MARK: Classification rules
    func loadClassificationRules() async throws -> [ClassificationRule]
    func saveClassificationRule(_ rule: ClassificationRule) async throws
    func deleteClassificationRule(id: UUID) async throws
}
```

### Conformers

| Type | Target | Notes |
|---|---|---|
| `JSONFileStore` | `LggrKit` | Default. Atomic writes to `~/Library/Application Support/Lggr/`, one JSON file per aggregate. |
| `InMemoryStore` | `LggrKit` | The fake. Backs unit tests and `PreviewFixtures`. Optional `var failureToInject: StoreError?` to exercise error paths. |
| `SwiftDataStore` | `LggrPersistence` | Xcode-only. Wraps a `ModelContainer`; maps `SD*` ⇄ domain values. |

`UserPreferences` is deliberately **not** in this protocol — see § 7.

---

## 5. SwiftData `@Model` classes (`Sources/LggrPersistence/` only)

Xcode-only. Never import into `LggrKit` or `LggrApp` except behind `#if canImport(LggrPersistence)`.

Naming: the persistence classes are prefixed `SD` because `LggrPersistence` imports `LggrKit`, and
`Project` (struct) and `Project` (`@Model` class) cannot coexist in one file without qualification.

SwiftData requires `inverse:` to be declared on **exactly one** side of a relationship pair.
Declaring it on both sides is a runtime error. The convention here: the **to-many** side declares
`@Relationship(deleteRule:inverse:)`; the to-one side is a plain optional property whose behaviour is
governed by the rule on the other end.

> `#Index` is not used: it requires macOS 15 and the deployment target is macOS 14. Data volumes are
> small enough that in-memory sorting after a date-ranged fetch is fine.

`File: Sources/LggrPersistence/Models/SDProject.swift` (one type per file)

```swift
import Foundation
import SwiftData
import LggrKit

@Model
public final class SDProject {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var colorID: String
    public var iconID: String
    public var isActive: Bool
    public var createdAt: Date
    public var updatedAt: Date

    /// NULLIFY: deleting a project must never destroy work history. SPEC § "Ensure relationships
    /// and deletion behavior are safe."
    @Relationship(deleteRule: .nullify, inverse: \SDFocusSession.project)
    public var sessions: [SDFocusSession] = []

    /// NULLIFY: accomplishments are the durable record of delivered work.
    @Relationship(deleteRule: .nullify, inverse: \SDAccomplishment.project)
    public var accomplishments: [SDAccomplishment] = []

    /// NULLIFY: a project-scoped rule degrades to a global rule rather than vanishing.
    @Relationship(deleteRule: .nullify, inverse: \SDClassificationRule.project)
    public var classificationRules: [SDClassificationRule] = []

    /// NULLIFY: an interruption converted into this project stays in the inbox history.
    @Relationship(deleteRule: .nullify, inverse: \SDInterruption.convertedProject)
    public var convertedInterruptions: [SDInterruption] = []

    /// Many-to-many with weekly outcomes; the inverse is declared here, not on `SDWeeklyOutcome`.
    @Relationship(deleteRule: .nullify, inverse: \SDWeeklyOutcome.projects)
    public var weeklyOutcomes: [SDWeeklyOutcome] = []

    public init(
        id: UUID,
        name: String,
        colorID: String,
        iconID: String,
        isActive: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.colorID = colorID
        self.iconID = iconID
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

```swift
@Model
public final class SDWeeklyOutcome {
    @Attribute(.unique) public var id: UUID
    public var title: String
    public var details: String?
    public var priority: OutcomePriority
    public var status: OutcomeStatus
    public var progress: Double
    public var weekStartDate: Date
    public var createdAt: Date
    public var updatedAt: Date

    /// Many-to-many. Inverse is declared on `SDProject.weeklyOutcomes`.
    public var projects: [SDProject] = []

    /// NULLIFY: deleting a weekly outcome must not delete the sessions spent on it.
    @Relationship(deleteRule: .nullify, inverse: \SDFocusSession.weeklyOutcome)
    public var sessions: [SDFocusSession] = []

    /// NULLIFY: same reasoning — the accomplishment survives the outcome.
    @Relationship(deleteRule: .nullify, inverse: \SDAccomplishment.weeklyOutcome)
    public var accomplishments: [SDAccomplishment] = []

    public init(
        id: UUID,
        title: String,
        details: String?,
        priority: OutcomePriority,
        status: OutcomeStatus,
        progress: Double,
        weekStartDate: Date,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.priority = priority
        self.status = status
        self.progress = progress
        self.weekStartDate = weekStartDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
```

```swift
@Model
public final class SDFocusSession {
    @Attribute(.unique) public var id: UUID
    public var intendedOutcome: String
    public var workType: WorkType
    public var plannedDuration: TimeInterval?
    public var startedAt: Date
    public var endedAt: Date?
    public var pausedDuration: TimeInterval
    public var pauseStartedAt: Date?
    public var resultStatus: SessionResultStatus?
    public var resultSummary: String?
    public var blocker: String?
    public var nextStep: String?
    public var isReactive: Bool
    public var interruptionCount: Int

    /// To-one ends; delete rules live on the inverse declarations in `SDProject` /
    /// `SDWeeklyOutcome`, both `.nullify`.
    public var project: SDProject?
    public var weeklyOutcome: SDWeeklyOutcome?

    /// CASCADE — the only cascade in the schema. Activity events are components of the session:
    /// they are raw, private capture data with no meaning outside it, and leaving them orphaned
    /// after the user deletes a session would keep tracked window titles on disk that the user
    /// believes they deleted. Deleting a session therefore deletes its captured activity.
    @Relationship(deleteRule: .cascade, inverse: \SDActivityEvent.session)
    public var activityEvents: [SDActivityEvent] = []

    /// NULLIFY: interruption notes are user-authored inbox items and outlive the session.
    @Relationship(deleteRule: .nullify, inverse: \SDInterruption.session)
    public var interruptions: [SDInterruption] = []

    /// NULLIFY: accomplishments are the permanent "Done" log.
    @Relationship(deleteRule: .nullify, inverse: \SDAccomplishment.focusSession)
    public var accomplishments: [SDAccomplishment] = []

    public init(
        id: UUID,
        intendedOutcome: String,
        workType: WorkType,
        plannedDuration: TimeInterval?,
        startedAt: Date,
        endedAt: Date?,
        pausedDuration: TimeInterval,
        pauseStartedAt: Date?,
        resultStatus: SessionResultStatus?,
        resultSummary: String?,
        blocker: String?,
        nextStep: String?,
        isReactive: Bool,
        interruptionCount: Int
    ) {
        self.id = id
        self.intendedOutcome = intendedOutcome
        self.workType = workType
        self.plannedDuration = plannedDuration
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pausedDuration = pausedDuration
        self.pauseStartedAt = pauseStartedAt
        self.resultStatus = resultStatus
        self.resultSummary = resultSummary
        self.blocker = blocker
        self.nextStep = nextStep
        self.isReactive = isReactive
        self.interruptionCount = interruptionCount
    }
}
```

```swift
@Model
public final class SDActivityEvent {
    @Attribute(.unique) public var id: UUID
    public var applicationName: String
    public var bundleIdentifier: String
    public var windowTitle: String?
    public var domain: String?
    public var category: ActivityCategory
    public var startedAt: Date
    public var endedAt: Date?
    public var isIdle: Bool
    public var isPrivate: Bool
    public var classificationSource: ClassificationSource

    /// To-one end of the cascade declared on `SDFocusSession.activityEvents`.
    public var session: SDFocusSession?

    public init(
        id: UUID,
        applicationName: String,
        bundleIdentifier: String,
        windowTitle: String?,
        domain: String?,
        category: ActivityCategory,
        startedAt: Date,
        endedAt: Date?,
        isIdle: Bool,
        isPrivate: Bool,
        classificationSource: ClassificationSource
    ) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.domain = domain
        self.category = category
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.isIdle = isIdle
        self.isPrivate = isPrivate
        self.classificationSource = classificationSource
    }
}
```

```swift
@Model
public final class SDInterruption {
    @Attribute(.unique) public var id: UUID
    public var note: String
    public var source: InterruptionSource
    public var timestamp: Date
    public var status: InterruptionStatus

    /// To-one ends; both inverses declare `.nullify`.
    public var session: SDFocusSession?
    public var convertedProject: SDProject?

    public init(
        id: UUID,
        note: String,
        source: InterruptionSource,
        timestamp: Date,
        status: InterruptionStatus
    ) {
        self.id = id
        self.note = note
        self.source = source
        self.timestamp = timestamp
        self.status = status
    }
}
```

```swift
@Model
public final class SDAccomplishment {
    @Attribute(.unique) public var id: UUID
    public var type: AccomplishmentType
    public var title: String
    public var details: String?
    public var timestamp: Date

    /// To-one ends; all three inverses declare `.nullify`.
    public var project: SDProject?
    public var weeklyOutcome: SDWeeklyOutcome?
    public var focusSession: SDFocusSession?

    public init(
        id: UUID,
        type: AccomplishmentType,
        title: String,
        details: String?,
        timestamp: Date
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.details = details
        self.timestamp = timestamp
    }
}
```

```swift
@Model
public final class SDClassificationRule {
    @Attribute(.unique) public var id: UUID
    public var matchType: RuleMatchType
    public var matchValue: String
    public var category: ActivityCategory
    public var workType: WorkType?
    public var priority: Int
    public var isEnabled: Bool
    public var isUserDefined: Bool

    /// To-one end; inverse declares `.nullify`.
    public var project: SDProject?

    public init(
        id: UUID,
        matchType: RuleMatchType,
        matchValue: String,
        category: ActivityCategory,
        workType: WorkType?,
        priority: Int,
        isEnabled: Bool,
        isUserDefined: Bool
    ) {
        self.id = id
        self.matchType = matchType
        self.matchValue = matchValue
        self.category = category
        self.workType = workType
        self.priority = priority
        self.isEnabled = isEnabled
        self.isUserDefined = isUserDefined
    }
}
```

### 5.1 Delete rules at a glance

| Relationship | Rule | Why |
|---|---|---|
| `SDProject.sessions` | `.nullify` | Deleting a project must not erase where the time went. |
| `SDProject.accomplishments` | `.nullify` | The "Done" log is the product's whole point. |
| `SDProject.classificationRules` | `.nullify` | Scoped rule degrades to a global rule. |
| `SDProject.convertedInterruptions` | `.nullify` | Inbox history is user-authored. |
| `SDProject.weeklyOutcomes` | `.nullify` | Many-to-many link only. |
| `SDWeeklyOutcome.sessions` | `.nullify` | Sessions outlive the week's framing. |
| `SDWeeklyOutcome.accomplishments` | `.nullify` | Same. |
| `SDFocusSession.activityEvents` | **`.cascade`** | Raw private capture data belongs to the session; deleting the session must remove it from disk. |
| `SDFocusSession.interruptions` | `.nullify` | User-authored notes survive. |
| `SDFocusSession.accomplishments` | `.nullify` | The permanent record survives. |

`SwiftDataStore.deleteProject(id:)` calls `context.delete(project)` and relies on the nullify rules
— it must **not** loop over `sessions` deleting them. The `JSONFileStore` and `InMemoryStore`
implementations must reproduce the same behaviour explicitly (clear `projectID` on every referencing
record) so the two backends are observationally identical. That equivalence is a unit test.

### 5.2 Schema registration

```swift
public enum LggrSchema {
    public static let models: [any PersistentModel.Type] = [
        SDProject.self,
        SDWeeklyOutcome.self,
        SDFocusSession.self,
        SDActivityEvent.self,
        SDInterruption.self,
        SDAccomplishment.self,
        SDClassificationRule.self
    ]

    public static func container(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: configuration)
    }
}
```

---

## 6. Mapping strategy

**Direction of truth:** domain value types are authoritative. `@Model` classes are a storage detail
and expose no behaviour — every computed property, every duration, every rule match lives on the
value type in `LggrKit` and is unit-tested today.

Two functions per entity, both in `Sources/LggrPersistence/Mapping/`:

- `func toDomain() -> T` — reads relationship objects and projects them down to `UUID`s.
- `func apply(_ value: T, in context: ModelContext) throws` — writes scalars and resolves each
  `UUID?` back to a managed object.

`id` is never rewritten by `apply` after insert; it is set once by the initialiser.

### Worked example — `SDFocusSession`

`File: Sources/LggrPersistence/Mapping/SDFocusSession+Mapping.swift`

```swift
import Foundation
import SwiftData
import LggrKit

extension SDFocusSession {

    func toDomain() -> FocusSession {
        FocusSession(
            id: id,
            projectID: project?.id,
            weeklyOutcomeID: weeklyOutcome?.id,
            intendedOutcome: intendedOutcome,
            workType: workType,
            plannedDuration: plannedDuration,
            startedAt: startedAt,
            endedAt: endedAt,
            pausedDuration: pausedDuration,
            pauseStartedAt: pauseStartedAt,
            resultStatus: resultStatus,
            resultSummary: resultSummary,
            blocker: blocker,
            nextStep: nextStep,
            isReactive: isReactive,
            interruptionCount: interruptionCount
        )
    }

    func apply(_ value: FocusSession, in context: ModelContext) throws {
        intendedOutcome = value.intendedOutcome
        workType = value.workType
        plannedDuration = value.plannedDuration
        endedAt = value.endedAt
        pausedDuration = value.pausedDuration
        pauseStartedAt = value.pauseStartedAt
        resultStatus = value.resultStatus
        resultSummary = value.resultSummary
        blocker = value.blocker
        nextStep = value.nextStep
        isReactive = value.isReactive
        interruptionCount = value.interruptionCount
        project = try ModelLookup.project(id: value.projectID, in: context)
        weeklyOutcome = try ModelLookup.weeklyOutcome(id: value.weeklyOutcomeID, in: context)
        // `id` and `startedAt` are immutable in the domain and set at insert time.
    }

    /// Insert-or-update by `id`. Every `save…` method in `SwiftDataStore` follows this shape.
    static func upsert(_ value: FocusSession, in context: ModelContext) throws {
        let targetID = value.id
        var descriptor = FetchDescriptor<SDFocusSession>(
            predicate: #Predicate { $0.id == targetID }
        )
        descriptor.fetchLimit = 1

        let model: SDFocusSession
        if let existing = try context.fetch(descriptor).first {
            model = existing
        } else {
            model = SDFocusSession(
                id: value.id,
                intendedOutcome: value.intendedOutcome,
                workType: value.workType,
                plannedDuration: value.plannedDuration,
                startedAt: value.startedAt,
                endedAt: value.endedAt,
                pausedDuration: value.pausedDuration,
                pauseStartedAt: value.pauseStartedAt,
                resultStatus: value.resultStatus,
                resultSummary: value.resultSummary,
                blocker: value.blocker,
                nextStep: value.nextStep,
                isReactive: value.isReactive,
                interruptionCount: value.interruptionCount
            )
            context.insert(model)
        }
        try model.apply(value, in: context)
    }
}

/// Shared `UUID` → managed-object resolution. The only place `#Predicate` appears for lookups.
enum ModelLookup {
    static func project(id: UUID?, in context: ModelContext) throws -> SDProject? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<SDProject>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func weeklyOutcome(id: UUID?, in context: ModelContext) throws -> SDWeeklyOutcome? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<SDWeeklyOutcome>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func focusSession(id: UUID?, in context: ModelContext) throws -> SDFocusSession? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<SDFocusSession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
```

**Round-trip guarantee.** For every entity, `model.toDomain() == value` must hold after
`upsert(value)`, with one documented exception: a `projectID` pointing at a project that does not
exist resolves to `nil` (a dangling reference is silently dropped rather than resurrected). The same
guarantee is asserted for `JSONFileStore` and `InMemoryStore`, so the three backends are
interchangeable. This is the shared conformance test suite `LggrStoreContractTests`, run against all
three (SwiftData variant only when `LGGR_SWIFTDATA=1`).

---

## 7. `UserPreferences` storage

**`UserPreferences` lives in `UserDefaults`, not SwiftData, and is not part of `LggrStore`.**

Reasons, in order of weight:

1. **It is needed before the store exists.** `launchAtLogin`, `showTimerInMenuBar` and
   `globalShortcut` are read during `applicationDidFinishLaunching`, before (and independently of)
   any `ModelContainer` being opened. A SwiftData failure must not cost the user their hot key.
2. **A single-row SwiftData entity is a liability.** Every read needs "fetch first, insert if
   missing", every write needs duplicate-row defence, and migrations for a settings blob buy
   nothing.
3. **`UserDefaults` is the platform-native home for settings** — it is what `@AppStorage`, the
   Settings scene, and `defaults delete com.lggr.app` all expect.
4. It removes the need for any preferences methods on `LggrStore`, keeping that protocol about work
   history only.

The whole struct is stored as one JSON blob under a single key, so the value type stays the single
source of truth and adding a field never needs a key migration.

`File: Sources/LggrKit/Store/PreferencesStore.swift`

```swift
import Foundation

@MainActor
public protocol PreferencesStoring: AnyObject {
    var preferences: UserPreferences { get set }
}

@MainActor
public final class UserDefaultsPreferencesStore: PreferencesStoring {
    public static let storageKey = "com.lggr.userPreferences.v1"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public var preferences: UserPreferences {
        didSet { persist() }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? decoder.decode(UserPreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = UserPreferences()
        }
    }

    private func persist() {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
```

An `InMemoryPreferencesStore` (a two-line class holding a `var preferences`) is the test fake.
Unknown-key tolerance: adding a field with a default value keeps old blobs decodable, because
`Codable` synthesis on an optional-or-defaulted property still requires the key — so **every new
`UserPreferences` field must be added with an explicit default in `init` *and* a custom
`decodeIfPresent` path if it is added after v1 ships**; alternatively bump `storageKey` to `v2`.
For the MVP, v1 is written fresh and this note is a forward warning only.

---

## 8. Consistency checklist for later agents

- Field names come from this file, not from memory. The two intentional deviations from `SPEC.md`
  are `Interruption.note` (spec: `description`) and the added `FocusSession.pauseStartedAt`.
- Relationships in the domain are `UUID`s; only `SD*` classes hold object references.
- Never call `elapsed(at: Date())` inside an aggregate — use `effectiveDuration`, which is defined
  only for finished sessions.
- Never mutate `FocusSession.pausedDuration` outside `resume(at:)`.
- Never re-classify an `ActivityEvent` whose `classificationSource == .manual`.
- Never write a private application's title or bundle ID to a store: call `redactedIfPrivate()`
  at capture time.
- Deleting a `Project` nullifies; only `FocusSession → ActivityEvent` cascades.
- `@Model`, `#Predicate`, `#Preview` appear in `Sources/LggrPersistence/` (and the excluded
  `Previews.swift`) and nowhere else.

### Unit tests this model must carry (SPEC § Testing requirements)

`Tests/LggrKitTests/`

| Test file | Covers |
|---|---|
| `FocusSessionTimingTests` | `elapsed`/`remaining`/`overrun`/`effectiveDuration`, single and multi-cycle pause, finish-while-paused, backwards clock, open-ended, idempotent transitions |
| `ClassificationRuleTests` | all four `matchType`s, case-insensitivity, domain suffix matching, project and work-type scoping, priority + specificity ordering, disabled rules, private events |
| `ActivityEventTests` | `duration(at:)` on open/closed intervals, `redactedIfPrivate()` erases name, bundle ID, title, domain and category |
| `UserPreferencesTests` | exclusion/private matching, `retentionCutoff`, JSON round-trip |
| `LggrStoreContractTests` | the same suite run against `InMemoryStore`, `JSONFileStore`, and (under `LGGR_SWIFTDATA=1`) `SwiftDataStore`: upsert-by-id, date-range queries, project delete nullifies without losing history, session delete removes its activity events |
| `CodableRoundTripTests` | every value type and every enum raw value survives encode/decode unchanged |
