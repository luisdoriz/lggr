# Lggr — Architecture and Folder Structure

> Deliverable 3 of the Phase 1 design set. Read `CONSTRAINTS.md` first — every decision here lives
> inside those verified limits. Xcode is not installed; SwiftData macros, `#Predicate` and
> `#Preview` cannot compile on this machine. That is settled and not revisited below.

---

## 1. Architecture in one paragraph

Lggr is a three-target Swift package. **`LggrKit`** is a pure Foundation-only domain library that
owns every value type, every calculation and the single persistence protocol; it compiles and is
fully unit-tested today. **`LggrApp`** is the executable: SwiftUI views, `@Observable` state, and a
handful of `@MainActor` services that wrap AppKit and system APIs. **`LggrPersistence`** is a thin,
Xcode-only SwiftData adapter that conforms to the same persistence protocol. The app runs today on a
durable `JSONFileStore` shipped inside `LggrKit`; when Xcode is present, `LGGR_SWIFTDATA=1` swaps in
`SwiftDataStore` and **not a single view or domain file changes**. There is no Clean Architecture,
no DI container, no Combine, and no abstraction that does not have at least two real implementations.

---

## 2. Module / target graph

```
                    ┌──────────────────────┐
                    │      LggrKit         │   library
                    │  Foundation only     │   no SwiftUI, no AppKit, no SwiftData
                    │  Sendable value types│
                    │  pure logic          │
                    │  LggrStore protocol  │
                    │  JSONFileStore       │
                    │  InMemoryStore       │
                    │  PreviewFixtures     │
                    └──────────┬───────────┘
                               │
             ┌─────────────────┼──────────────────────────┐
             │                 │                          │
             ▼                 ▼                          ▼
   ┌───────────────────┐  ┌──────────────────┐   ┌───────────────────┐
   │  LggrKitTests     │  │  LggrPersistence │   │     LggrApp       │
   │  swift-testing    │  │  SwiftData       │   │  executable       │
   │  test target      │  │  Xcode-only      │   │  SwiftUI + AppKit │
   └───────────────────┘  └────────┬─────────┘   └─────────┬─────────┘
                                   │                       │
                                   └───────────────────────┘
                                    LggrApp → LggrPersistence
                                    ONLY when LGGR_SWIFTDATA=1
```

**Dependency direction is strictly one-way and acyclic:**

```
LggrKitTests    →  LggrKit
LggrPersistence →  LggrKit
LggrApp         →  LggrKit
LggrApp         →  LggrPersistence      (conditional, compile-time)
LggrKit         →  (nothing but Foundation)
```

`LggrKit` never imports `SwiftUI`, `AppKit`, `SwiftData` or `LggrApp`. `LggrPersistence` never
imports `SwiftUI` or `LggrApp`. `LggrApp` is the only place that knows both worlds, and only in one
file (`App/StoreBootstrap.swift`).

### 2.1 What belongs in each target, and why

#### `LggrKit` — pure domain library

Contains:

- **Domain value types** — `Project`, `WeeklyOutcome`, `FocusSession`, `ActivityEvent`,
  `Interruption`, `Accomplishment`, `ClassificationRule`, `UserPreferences`. All `struct`, all
  `Codable`, all `Sendable`, all `Identifiable` by `UUID`. Relationships are expressed as `UUID`
  foreign keys, not object references — this is what lets the same types round-trip through JSON
  today and SwiftData tomorrow.
- **All business logic** — timer/pause arithmetic, activity aggregation, context-switch counting,
  planned-vs-reactive, rule matching, private-app redaction, session summary generation, daily
  digest, weekly insights, Markdown/CSV rendering. Every one of these is a pure function or a
  `struct` with no I/O.
- **The `LggrStore` protocol** and its two in-package implementations (`JSONFileStore`,
  `InMemoryStore`).
- **`PreviewFixtures`** — the sample data used by the dev gallery, the Xcode-only previews, and the
  tests.

Why: this is 70% of the codebase, it is where every bug that matters lives, and it compiles and is
tested **today** with `swift test`. Keeping AppKit and SwiftData out of it is what makes that true.

#### `LggrApp` — SwiftUI executable

Contains: `@main` scene graph, `MenuBarExtra`, the main window, `Settings`, every `View`, the design
tokens, the `@Observable` view state, and the `@MainActor` services that wrap `NSWorkspace`,
`CGEventSource`, `UNUserNotificationCenter`, `AXIsProcessTrusted`, `NSSavePanel`, `ServiceManagement`
and Carbon hot keys. Views bind to `@Observable` stores and to `LggrStore` — never to a persistence
class. No `@Model`, no `#Preview`, no `#Predicate`.

Why an executable target rather than a library + shim: SPM builds it directly, `Scripts/make-app.sh`
drops the resulting binary into a hand-assembled `Lggr.app`, and it runs.

#### `LggrPersistence` — SwiftData adapter (Xcode-only)

Contains: the `@Model` classes (`StoredProject`, `StoredFocusSession`, …) exactly as the spec's data
model requires, the value-type ⇄ `@Model` mapping, and `SwiftDataStore: LggrStore`. It is the *only*
place in the repository where `@Model`, `@Relationship`, `@Attribute`, `@ModelActor` and `#Predicate`
may appear. It is added to `Package.swift` only when `LGGR_SWIFTDATA=1`, so `swift build` stays green
on this machine.

Why a separate target rather than `#if` inside `LggrApp`: a whole target can be excluded from the
package manifest; scattered `#if`s cannot, and they rot. The `Stored*` prefix on the `@Model` types
removes any ambiguity in mapping code.

#### `LggrKitTests` — the only test target

swift-testing (`import Testing`) against `LggrKit`. Covers exactly the spec's testing list: timer
behaviour, pause/resume, session completion, activity aggregation, context switches,
planned-vs-reactive, rule matching, private-app handling, weekly summary generation, Markdown export,
CSV export, plus `JSONFileStore` durability.

There is deliberately **no `LggrAppTests`**. The app layer holds no logic worth testing — services
are thin adapters over system APIs, and the visual layer is verified through the dev gallery. Adding
a second test target would mostly test SwiftUI.

### 2.2 Layering enforcement

`Scripts/check-layering.sh` greps `Sources/LggrKit` for `import SwiftUI|import AppKit|import
SwiftData` and `Sources/LggrApp` for `@Model|#Predicate|#Preview`, and fails the build if it finds
any. It runs at the top of `make-app.sh`. Twelve lines of shell that make the constraint mechanical
instead of aspirational.

---

## 3. Complete folder structure

Phase markers: **`[P2]`** = the vertical slice we build now. `[P3]`–`[P6]` = later phases; the file
does not exist until that phase starts. `[P1]` = design docs, already written. Unmarked
infrastructure files are Phase 2.

```
lggr/
├── Package.swift                                   [P2]  conditional LggrPersistence target
├── README.md                                       [P2]  build + run on a machine without Xcode
├── .gitignore                                      [P2]  .build/, build/, .DS_Store, .omc/
├── docs/
│   └── _design/
│       ├── CONSTRAINTS.md                          [P1]
│       ├── SPEC.md                                 [P1]
│       ├── 01-product.md                           [P1]
│       ├── 02-architecture.md                      [P1]  ← this file
│       ├── 03-data-model.md                        [P1]
│       ├── 04-screens.md                           [P1]
│       ├── 05-permissions.md                       [P1]
│       └── 06-checklist.md                         [P1]
├── Scripts/
│   ├── make-app.sh                                 [P2]  assemble + sign Lggr.app
│   ├── run.sh                                      [P2]  make-app.sh && open build/Lggr.app
│   ├── check-layering.sh                           [P2]  import/macro guard
│   ├── Info.plist                                  [P2]
│   ├── Lggr.entitlements                           [P2]
│   └── AppIcon.icns                                [P6]
├── Sources/
│   ├── LggrKit/
│   │   ├── Model/
│   │   │   ├── Project.swift                       [P2]  + ProjectColor identifier
│   │   │   ├── FocusSession.swift                  [P2]  + SessionResultStatus
│   │   │   ├── WorkType.swift                      [P2]
│   │   │   ├── Accomplishment.swift                [P2]  + AccomplishmentType
│   │   │   ├── UserPreferences.swift               [P2]
│   │   │   ├── ActivityEvent.swift                 [P3]  + ClassificationSource
│   │   │   ├── ActivityCategory.swift              [P3]
│   │   │   ├── ClassificationRule.swift            [P3]  + RuleMatchType
│   │   │   ├── Interruption.swift                  [P3]  + InterruptionSource, InterruptionStatus
│   │   │   └── WeeklyOutcome.swift                 [P5]  + OutcomePriority, OutcomeStatus
│   │   ├── Domain/
│   │   │   ├── SessionClock.swift                  [P2]  elapsed / remaining / pause arithmetic
│   │   │   ├── SessionLifecycle.swift              [P2]  start, pause, resume, finish transitions
│   │   │   ├── SessionSummaryBuilder.swift         [P2]  deterministic summary text (grows in P3)
│   │   │   ├── DurationFormatting.swift            [P2]  "50m", "1:23:45", "1 h 12 m"
│   │   │   ├── ActivityAggregator.swift            [P3]  totals by app and by category
│   │   │   ├── ActivityCoalescer.swift             [P3]  merge adjacent same-app intervals
│   │   │   ├── ContextSwitchCounter.swift          [P3]
│   │   │   ├── ClassificationEngine.swift          [P3]  rule matching, priority ordering
│   │   │   ├── PrivacyRedactor.swift               [P3]  private/excluded app handling
│   │   │   ├── SessionTimelineBuilder.swift        [P3]  grouped timeline blocks
│   │   │   ├── DailyDigest.swift                   [P4]  Today's metric rollup
│   │   │   ├── PlannedVsReactive.swift             [P5]
│   │   │   ├── WeeklyReviewBuilder.swift           [P5]
│   │   │   └── InsightGenerator.swift              [P5]  neutral, evidence-based observations
│   │   ├── Export/
│   │   │   ├── MarkdownRendering.swift             [P4]  shared helpers
│   │   │   ├── DailySummaryMarkdown.swift          [P4]
│   │   │   ├── AccomplishmentLogMarkdown.swift     [P4]
│   │   │   ├── WeeklyReviewMarkdown.swift          [P5]
│   │   │   └── SessionsCSVExporter.swift           [P5]
│   │   ├── Store/
│   │   │   ├── LggrStore.swift                     [P2]  the single persistence protocol
│   │   │   ├── StoreSnapshot.swift                 [P2]  Codable root + schemaVersion
│   │   │   ├── JSONFileStore.swift                 [P2]  actor, atomic writes, default backend
│   │   │   ├── AtomicFileWriter.swift              [P2]  write-temp + replaceItemAt
│   │   │   ├── InMemoryStore.swift                 [P2]  actor, previews + tests
│   │   │   └── StoreError.swift                    [P2]
│   │   ├── Support/
│   │   │   ├── DateProviding.swift                 [P2]  SystemClock + FixedClock
│   │   │   ├── CalendarWindows.swift               [P2]  day / week boundary helpers
│   │   │   └── Identified.swift                    [P2]  tiny [T] lookup-by-id helpers
│   │   └── Fixtures/
│   │       ├── PreviewFixtures.swift               [P2]  grows each phase
│   │       └── FixtureCalendar.swift               [P2]  deterministic fixture dates
│   │
│   ├── LggrApp/
│   │   ├── App/
│   │   │   ├── LggrMain.swift                      [P2]  @main, Scene graph
│   │   │   ├── AppEnvironment.swift                [P2]  composition root (live + fake)
│   │   │   ├── EnvironmentValues+Lggr.swift        [P2]  custom EnvironmentKeys (no @Entry)
│   │   │   ├── AppDelegate.swift                   [P2]  lifecycle, terminate flush
│   │   │   ├── StoreBootstrap.swift                [P2]  the ONLY #if LGGR_SWIFTDATA
│   │   │   └── AppCommands.swift                   [P2]  CommandGroup / keyboard menu items
│   │   ├── Services/
│   │   │   ├── SessionManager.swift                [P2]
│   │   │   ├── MenuBarManager.swift                [P2]
│   │   │   ├── TickTimer.swift                     [P2]  1 Hz, .common run-loop mode
│   │   │   ├── SleepWakeObserver.swift             [P2]  sleep/wake interval repair
│   │   │   ├── ApplicationMonitoringService.swift  [P3]  protocol + NSWorkspace impl + stub
│   │   │   ├── IdleDetectionService.swift          [P3]  protocol + CGEventSource impl + stub
│   │   │   ├── ActivityTrackingService.swift       [P3]  orchestrates monitor + idle + store
│   │   │   ├── WindowTitleReader.swift             [P3]  AX, gated on trust
│   │   │   ├── BrowserDomainReader.swift           [P3]  Apple Events, opt-in
│   │   │   ├── ClassificationService.swift         [P3]  rules cache over ClassificationEngine
│   │   │   ├── ExportService.swift                 [P4]  NSSavePanel + write
│   │   │   ├── NotificationService.swift           [P6]  protocol + UN impl + recording fake
│   │   │   ├── PermissionsService.swift            [P6]  protocol + system impl + stub
│   │   │   ├── GlobalShortcutService.swift         [P6]  Carbon RegisterEventHotKey
│   │   │   └── LaunchAtLoginService.swift          [P6]  SMAppService
│   │   ├── State/
│   │   │   ├── AppModel.swift                      [P2]  sidebar selection, sheet routing
│   │   │   ├── TodayModel.swift                    [P2]
│   │   │   ├── ProjectsModel.swift                 [P2]
│   │   │   ├── RulesModel.swift                    [P3]
│   │   │   ├── InboxModel.swift                    [P4]
│   │   │   └── WeeklyModel.swift                   [P5]
│   │   ├── DesignSystem/
│   │   │   ├── Theme.swift                         [P2]  spacing, radii, semantic surfaces
│   │   │   ├── Typography.swift                    [P2]
│   │   │   ├── Palette.swift                       [P2]  ProjectColor → Color
│   │   │   ├── Motion.swift                        [P2]  named animations, reduce-motion aware
│   │   │   └── Iconography.swift                   [P2]  SF Symbol names in one place
│   │   ├── Components/
│   │   │   ├── Card.swift                          [P2]
│   │   │   ├── SectionHeader.swift                 [P2]
│   │   │   ├── EmptyStateView.swift                [P2]
│   │   │   ├── PrimaryButtonStyle.swift            [P2]
│   │   │   ├── MetricTile.swift                    [P4]
│   │   │   └── ProjectBadge.swift                  [P2]
│   │   ├── Views/
│   │   │   ├── Root/
│   │   │   │   ├── RootWindow.swift                [P2]  NavigationSplitView
│   │   │   │   ├── Sidebar.swift                   [P2]
│   │   │   │   └── SidebarSection.swift            [P2]  enum + ⌘1–⌘7
│   │   │   ├── MenuBar/
│   │   │   │   ├── MenuBarLabel.swift              [P2]  icon + live time
│   │   │   │   ├── MenuBarContentView.swift        [P2]  switches idle/active
│   │   │   │   ├── MenuBarIdleView.swift           [P2]  6 entry actions
│   │   │   │   └── MenuBarActiveView.swift         [P2]  outcome, time, pause, finish
│   │   │   ├── Focus/
│   │   │   │   ├── StartSessionForm.swift          [P2]  the <5 s path
│   │   │   │   ├── ProjectPicker.swift             [P2]
│   │   │   │   ├── DurationPicker.swift            [P2]  25 / 50 / custom / open-ended
│   │   │   │   ├── WorkTypePicker.swift            [P2]  drives the duration default
│   │   │   │   ├── OutcomeField.swift              [P2]  required, recent suggestions
│   │   │   │   ├── ActiveSessionView.swift         [P2]
│   │   │   │   ├── TimerDisplay.swift              [P2]  visually dominant
│   │   │   │   ├── SessionControls.swift           [P2]  pause / finish
│   │   │   │   ├── LiveActivityStrip.swift         [P3]  current app + switch count
│   │   │   │   ├── SessionTimelineStrip.swift      [P3]
│   │   │   │   └── InterruptionCaptureSheet.swift  [P3]
│   │   │   ├── Review/
│   │   │   │   ├── SessionReviewSheet.swift        [P2]  "What happened?"
│   │   │   │   ├── ResultStatusPicker.swift        [P2]  5 options
│   │   │   │   ├── SummaryEditor.swift             [P2]  editable generated text
│   │   │   │   └── SessionStatsGrid.swift          [P3]  focused/idle/switches/categories
│   │   │   ├── Today/
│   │   │   │   ├── TodayView.swift                 [P2]
│   │   │   │   ├── TodayHeader.swift               [P2]  current-or-next session
│   │   │   │   ├── CompletedSessionRow.swift       [P2]
│   │   │   │   ├── TodayMetricsRow.swift           [P4]
│   │   │   │   ├── DailyTimelineView.swift         [P4]
│   │   │   │   ├── TimelineBlockView.swift         [P4]
│   │   │   │   └── InterruptionInboxView.swift     [P4]
│   │   │   ├── Accomplishments/
│   │   │   │   ├── AddAccomplishmentSheet.swift    [P2]  from a finished session
│   │   │   │   ├── AccomplishmentLogView.swift     [P4]
│   │   │   │   ├── AccomplishmentRow.swift         [P4]
│   │   │   │   └── AccomplishmentTypePicker.swift  [P4]
│   │   │   ├── Projects/
│   │   │   │   ├── ProjectsView.swift              [P2]
│   │   │   │   └── ProjectEditor.swift             [P2]  name, colour, icon
│   │   │   ├── Sessions/
│   │   │   │   ├── FocusSessionsView.swift         [P4]
│   │   │   │   └── FocusSessionDetailView.swift    [P4]
│   │   │   ├── Rules/
│   │   │   │   ├── RulesView.swift                 [P3]
│   │   │   │   ├── RuleEditor.swift                [P3]
│   │   │   │   └── ReclassifySheet.swift           [P3]  "make this a rule?"
│   │   │   ├── Weekly/
│   │   │   │   ├── WeeklyOutcomesView.swift        [P5]
│   │   │   │   ├── WeeklyOutcomeEditor.swift       [P5]
│   │   │   │   ├── WeeklyReviewView.swift          [P5]
│   │   │   │   ├── TimeAllocationChart.swift       [P5]  Swift Charts, restrained
│   │   │   │   └── InsightList.swift               [P5]
│   │   │   ├── Settings/
│   │   │   │   ├── SettingsWindow.swift            [P6]
│   │   │   │   ├── GeneralSettingsView.swift       [P6]
│   │   │   │   ├── TrackingSettingsView.swift      [P6]
│   │   │   │   ├── PrivacySettingsView.swift       [P6]
│   │   │   │   ├── ShortcutsSettingsView.swift     [P6]
│   │   │   │   └── NotificationsSettingsView.swift [P6]
│   │   │   └── Onboarding/
│   │   │       ├── OnboardingWindow.swift          [P6]
│   │   │       ├── OnboardingPage.swift            [P6]
│   │   │       └── PermissionExplainerView.swift   [P6]
│   │   ├── Dev/
│   │   │   ├── PreviewGallery.swift                [P2]  LGGR_GALLERY=1 window
│   │   │   └── GalleryEntry.swift                  [P2]  light/dark side-by-side wrapper
│   │   └── _XcodeOnly/                             [P2]  excluded in Package.swift
│   │       └── Previews.swift                      [P2]  the real #Preview macros
│   │
│   └── LggrPersistence/                            [P2, built only with LGGR_SWIFTDATA=1]
│       ├── Models/
│       │   ├── StoredProject.swift                 [P2]
│       │   ├── StoredFocusSession.swift            [P2]
│       │   ├── StoredAccomplishment.swift          [P2]
│       │   ├── StoredUserPreferences.swift         [P2]
│       │   ├── StoredActivityEvent.swift           [P3]
│       │   ├── StoredInterruption.swift            [P3]
│       │   ├── StoredClassificationRule.swift      [P3]
│       │   └── StoredWeeklyOutcome.swift           [P5]
│       ├── Mapping/
│       │   ├── ProjectMapping.swift                [P2]
│       │   ├── FocusSessionMapping.swift           [P2]
│       │   ├── AccomplishmentMapping.swift         [P2]
│       │   ├── PreferencesMapping.swift            [P2]
│       │   ├── ActivityEventMapping.swift          [P3]
│       │   ├── InterruptionMapping.swift           [P3]
│       │   ├── ClassificationRuleMapping.swift     [P3]
│       │   └── WeeklyOutcomeMapping.swift          [P5]
│       ├── SwiftDataStore.swift                    [P2]  @ModelActor, conforms to LggrStore
│       └── ModelContainerFactory.swift             [P2]  schema + container configuration
│
└── Tests/
    └── LggrKitTests/
        ├── SessionClockTests.swift                 [P2]
        ├── SessionLifecycleTests.swift             [P2]  pause/resume/finish
        ├── SessionSummaryBuilderTests.swift        [P2]
        ├── DurationFormattingTests.swift           [P2]
        ├── JSONFileStoreTests.swift                [P2]  durability + atomicity
        ├── StoreSnapshotCodableTests.swift         [P2]  schema round-trip
        ├── ActivityAggregatorTests.swift           [P3]
        ├── ActivityCoalescerTests.swift            [P3]
        ├── ContextSwitchCounterTests.swift         [P3]
        ├── ClassificationEngineTests.swift         [P3]
        ├── PrivacyRedactorTests.swift              [P3]
        ├── SessionTimelineBuilderTests.swift       [P3]
        ├── DailyDigestTests.swift                  [P4]
        ├── MarkdownExportTests.swift               [P4]
        ├── PlannedVsReactiveTests.swift            [P5]
        ├── WeeklyReviewBuilderTests.swift          [P5]
        ├── InsightGeneratorTests.swift             [P5]
        └── CSVExportTests.swift                    [P5]
```

**Phase 2 file count: ~74 source files.** That is the whole vertical slice — create a project, start
a session, live timer in window and menu bar, pause/resume, finish, pick a result, generate and edit
a summary, persist it, see it in Today, and log an accomplishment from it.

---

## 4. Service catalog

The spec's nine services, plus three that Phase 6 needs. "Protocol" means there is a real second
implementation (a stub used by the gallery and by manual testing); anything with only one
implementation is a concrete type, because a protocol with one conformer is dead weight.

| Service | Responsibility (one sentence) | Target | Shape | Isolation |
|---|---|---|---|---|
| **SessionManager** | Owns the one in-flight `FocusSession` and drives start/pause/resume/finish, delegating all arithmetic to `SessionClock`. | LggrApp | Concrete `@Observable final class` | `@MainActor` |
| **MenuBarManager** | Derives the menu-bar label (symbol + optional time string) and popover presentation state from `SessionManager` and preferences. | LggrApp | Concrete `@Observable final class` | `@MainActor` |
| **ActivityTrackingService** | Turns frontmost-app and idle signals into closed `ActivityEvent` intervals attached to the current session, and writes them to the store. | LggrApp | Concrete `@Observable final class` | `@MainActor` |
| **ApplicationMonitoringService** | Reports the frontmost application's bundle id and display name whenever it changes. | LggrApp | Protocol `ApplicationMonitoring` + `WorkspaceApplicationMonitor` + `StubApplicationMonitor` | `@MainActor` |
| **IdleDetectionService** | Reports seconds since the last HID event and emits idle-begin / idle-end above the configured threshold. | LggrApp | Protocol `IdleDetecting` + `HIDIdleDetector` + `StubIdleDetector` | `@MainActor` |
| **ClassificationService** | Holds the enabled rule set in memory and classifies an activity sample by delegating to the pure `ClassificationEngine`. | LggrApp (cache) over LggrKit (engine) | Concrete `@Observable final class` wrapping a `Sendable struct` | `@MainActor` wrapper, `nonisolated` engine |
| **NotificationService** | Schedules and delivers the four local notification kinds and honours the user's per-kind toggles. | LggrApp | Protocol `Notifying` + `UserNotificationService` + `RecordingNotifier` | `@MainActor` |
| **ExportService** | Presents `NSSavePanel` and writes the string produced by `LggrKit`'s Markdown/CSV renderers to disk. | LggrApp (I/O) over LggrKit (rendering) | Concrete `struct` | `@MainActor` |
| **PermissionsService** | Reports and requests Accessibility, Notifications and Automation authorisation, exactly once per user action. | LggrApp | Protocol `PermissionsProviding` + `SystemPermissionsService` + `StubPermissionsService` | `@MainActor` |
| **GlobalShortcutService** *(P6)* | Registers the configurable system-wide hot key and invokes a closure on the main actor. | LggrApp | Protocol `GlobalShortcutRegistering` + `CarbonHotKeyService` + `NoopShortcutService` | `@MainActor` |
| **LaunchAtLoginService** *(P6)* | Reads and writes the launch-at-login state via `SMAppService`. | LggrApp | Concrete `struct` | `@MainActor` |
| **LggrStore** | The single persistence boundary: async CRUD over domain value types. | Protocol in LggrKit; `JSONFileStore` + `InMemoryStore` in LggrKit; `SwiftDataStore` in LggrPersistence | Protocol + three actors | actor-isolated, `Sendable` |

### 4.1 Two services that are *not* in the app target

`ClassificationEngine` and every Markdown/CSV renderer live in `LggrKit` as `Sendable` structs with
pure functions. The spec names them as "services"; they are pure computation, so they belong where
they can be unit-tested. The app-target `ClassificationService` and `ExportService` exist only to
hold mutable cache state and to touch the file system / present panels.

### 4.2 The `LggrStore` protocol shape

One protocol, not eight repositories. There is exactly one store object injected into the app, and
splitting it into per-entity repositories would multiply the fake-writing cost with no gain.

```swift
public protocol LggrStore: Sendable {
    // Projects — [P2]
    func allProjects() async throws -> [Project]
    func upsert(_ project: Project) async throws
    func deleteProject(id: UUID) async throws

    // Sessions — [P2]
    func sessions(in interval: DateInterval) async throws -> [FocusSession]
    func session(id: UUID) async throws -> FocusSession?
    func upsert(_ session: FocusSession) async throws

    // Accomplishments — [P2]
    func accomplishments(in interval: DateInterval) async throws -> [Accomplishment]
    func upsert(_ accomplishment: Accomplishment) async throws
    func deleteAccomplishment(id: UUID) async throws

    // Preferences — [P2]
    func preferences() async throws -> UserPreferences
    func save(_ preferences: UserPreferences) async throws

    // Activity — [P3]
    func activityEvents(sessionID: UUID) async throws -> [ActivityEvent]
    func activityEvents(in interval: DateInterval) async throws -> [ActivityEvent]
    func append(_ events: [ActivityEvent]) async throws
    func deleteActivity(before date: Date) async throws

    // Interruptions, rules — [P3]
    func interruptions(status: InterruptionStatus?) async throws -> [Interruption]
    func upsert(_ interruption: Interruption) async throws
    func allRules() async throws -> [ClassificationRule]
    func upsert(_ rule: ClassificationRule) async throws
    func deleteRule(id: UUID) async throws

    // Weekly outcomes — [P5]
    func outcomes(weekStarting: Date) async throws -> [WeeklyOutcome]
    func upsert(_ outcome: WeeklyOutcome) async throws

    // Lifecycle
    func flush() async throws
}
```

The protocol grows by phase; the `[Pn]` comments stay in the source file so it is obvious which
methods a phase must implement in all three conformers.

---

## 5. Dependency injection

Three mechanisms, each with a rule about when it applies. Nothing else. No container, no resolver,
no `@Injected`.

### 5.1 One composition root object in the SwiftUI Environment

`@Entry` is a SwiftUI macro and **cannot compile here**, and a `@MainActor` service cannot supply a
`static let defaultValue` for an `EnvironmentKey`. So all reference-type dependencies travel as a
single `@Observable` root object using SwiftUI's Observable-object environment API.

```swift
// App/AppEnvironment.swift
import Foundation
import LggrKit

@MainActor
@Observable
public final class AppEnvironment {
    public let store: any LggrStore
    public let clock: any DateProviding

    public let sessionManager: SessionManager
    public let menuBar: MenuBarManager
    public let activity: ActivityTrackingService          // [P3]
    public let classification: ClassificationService      // [P3]
    public let notifications: any Notifying               // [P6]
    public let permissions: any PermissionsProviding      // [P6]

    public init(
        store: any LggrStore,
        clock: any DateProviding,
        monitor: any ApplicationMonitoring,
        idle: any IdleDetecting,
        notifications: any Notifying,
        permissions: any PermissionsProviding
    ) {
        self.store = store
        self.clock = clock
        self.notifications = notifications
        self.permissions = permissions
        self.sessionManager = SessionManager(store: store, clock: clock)
        self.menuBar = MenuBarManager()
        self.classification = ClassificationService(store: store)
        self.activity = ActivityTrackingService(
            store: store, clock: clock, monitor: monitor,
            idle: idle, classification: classification
        )
    }
}
```

Two factories, side by side, so the fake is never an afterthought:

```swift
public extension AppEnvironment {
    /// Real system integrations, real durable store.
    static func live() -> AppEnvironment {
        AppEnvironment(
            store: StoreBootstrap.makeStore(),
            clock: SystemClock(),
            monitor: WorkspaceApplicationMonitor(),
            idle: HIDIdleDetector(),
            notifications: UserNotificationService(),
            permissions: SystemPermissionsService()
        )
    }

    /// Everything faked. Used by the dev gallery, by Xcode #Previews, and by manual UI checks.
    static func fake(
        store: any LggrStore = InMemoryStore(seed: PreviewFixtures.demoWeek),
        clock: any DateProviding = FixedClock(PreviewFixtures.referenceDate),
        monitor: any ApplicationMonitoring = StubApplicationMonitor(script: PreviewFixtures.appSwitches),
        idle: any IdleDetecting = StubIdleDetector(idleSeconds: 0),
        notifications: any Notifying = RecordingNotifier(),
        permissions: any PermissionsProviding = StubPermissionsService(accessibility: .granted)
    ) -> AppEnvironment {
        AppEnvironment(store: store, clock: clock, monitor: monitor,
                       idle: idle, notifications: notifications, permissions: permissions)
    }
}
```

Root wiring — injected once per scene:

```swift
// App/LggrMain.swift
import SwiftUI
import LggrKit

@main
struct LggrMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var env = AppEnvironment.live()
    @State private var app = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environment(env)
                .environment(app)
        } label: {
            MenuBarLabel(state: env.menuBar.labelState)
        }
        .menuBarExtraStyle(.window)

        Window("Lggr", id: WindowID.main) {
            RootWindow()
                .environment(env)
                .environment(app)
        }
        .defaultSize(width: 1_040, height: 720)
        .commands { AppCommands(app: app, env: env) }

        Settings {
            SettingsWindow()
                .environment(env)
        }
    }
}
```

Consuming it:

```swift
struct ActiveSessionView: View {
    @Environment(AppEnvironment.self) private var env
    ...
}
```

### 5.2 Custom `EnvironmentKey` for `Sendable` values with a sane default

Only for value-type dependencies that a leaf view might want to override without rebuilding the
whole environment — the clock, formatting locale, and dev flags.

```swift
// App/EnvironmentValues+Lggr.swift
import SwiftUI
import LggrKit

private struct ClockKey: EnvironmentKey {
    static let defaultValue: any DateProviding = SystemClock()
}
private struct GalleryModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var clock: any DateProviding {
        get { self[ClockKey.self] }
        set { self[ClockKey.self] = newValue }
    }
    var isGalleryMode: Bool {
        get { self[GalleryModeKey.self] }
        set { self[GalleryModeKey.self] = newValue }
    }
}
```

### 5.3 Plain `init` parameters for anything a view renders

**Rule: a view never fetches its own data.** Presentational views take already-resolved value types
as `let` properties. Only the handful of container views (`TodayView`, `ProjectsView`,
`WeeklyReviewView`, …) read the environment and hand data down.

```swift
struct CompletedSessionRow: View {
    let session: FocusSession
    let project: Project?
    let onAddAccomplishment: () -> Void
    ...
}
```

This is what makes the gallery — and, on a machine with Xcode, `#Preview` — trivial:

```swift
CompletedSessionRow(
    session: PreviewFixtures.finishedSession,
    project: PreviewFixtures.sorProject,
    onAddAccomplishment: {}
)
```

### 5.4 How a preview substitutes a fake

`Sources/LggrApp/Dev/PreviewGallery.swift` is a `Window` scene that only opens when the process
environment contains `LGGR_GALLERY=1`. It renders every registered view twice — once with
`.preferredColorScheme(.light)`, once with `.dark` — inside `.environment(AppEnvironment.fake())`.
This is our light/dark verification loop on a machine without Xcode, and it is a real, running
window, not a screenshot harness.

`Sources/LggrApp/_XcodeOnly/Previews.swift` holds the identical set as real `#Preview` macros and is
listed in `exclude:` in `Package.swift`, so it never reaches this toolchain.

### 5.5 How a test substitutes a fake

`LggrKitTests` never imports SwiftUI and never constructs `AppEnvironment`. It exercises pure
functions with literal inputs, and exercises store behaviour against `InMemoryStore` or a
`JSONFileStore` rooted at a temporary directory:

```swift
@Test func pausedTimeIsExcludedFromElapsed() {
    let start = FixtureCalendar.at(9, 0)
    var session = FocusSession.started(at: start, plannedDuration: .minutes(50))
    session = SessionLifecycle.pause(session, at: FixtureCalendar.at(9, 10))
    session = SessionLifecycle.resume(session, at: FixtureCalendar.at(9, 25))
    #expect(SessionClock.elapsed(session, now: FixtureCalendar.at(9, 30)) == .minutes(15))
}

@Test func sessionsSurviveAStoreRestart() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let store = JSONFileStore(directory: dir)
    try await store.upsert(PreviewFixtures.finishedSession)
    try await store.flush()
    let reopened = JSONFileStore(directory: dir)
    #expect(try await reopened.sessions(in: .today(FixtureCalendar.referenceDate)).count == 1)
}
```

Time is always injected. `SessionClock` and `SessionLifecycle` take `now:` explicitly and never call
`Date()` — that is the single most important testability decision in the codebase.

---

## 6. Threading and concurrency model

Swift language mode **v5** (per `CONSTRAINTS.md`) with `@MainActor` discipline applied by hand. This
is where macOS apps break, so the rules are absolute rather than case-by-case.

### 6.1 The three isolation domains

1. **`@MainActor` — the entire `LggrApp` target.** Every view, every `@Observable` state object,
   every service. This is not laziness: `NSWorkspace` notifications are delivered on the main thread,
   `MenuBarExtra`'s label must update on the main thread, and the data volume (a few thousand records
   per year) makes background work pointless. One domain means zero data races in the app layer by
   construction.
2. **Actor-isolated — the store.** `JSONFileStore`, `InMemoryStore` and `SwiftDataStore` are `actor`s.
   All file and database I/O happens off the main thread automatically, and the actor serialises
   concurrent writers with no lock code.
3. **`nonisolated` and `Sendable` — all of `LggrKit`'s domain and logic types.** Every domain type is
   a `struct` of `Sendable` members; every calculation is a `static func` or a method on a `Sendable`
   `struct`. They can be called from any isolation domain, which is what lets `SessionSummaryBuilder`
   run on the store actor during a save and on the main actor during a UI update.

Explicit annotations:

```swift
public struct FocusSession: Codable, Sendable, Identifiable, Hashable { ... }
public enum WorkType: String, Codable, Sendable, CaseIterable { ... }
public struct SessionClock: Sendable { public static func elapsed(...) -> TimeInterval }
public protocol LggrStore: Sendable { ... }
public actor JSONFileStore: LggrStore { ... }
@MainActor @Observable public final class SessionManager { ... }
```

### 6.2 The ticking timer

**The timer does not accumulate time. It only asks the UI to redraw.** Elapsed and remaining time are
always derived from stored `Date` values via `SessionClock`:

```swift
public struct SessionClock: Sendable {
    /// Wall-clock time between start and `now`, minus every completed pause and any pause in flight.
    public static func elapsed(_ s: FocusSession, now: Date) -> TimeInterval
    public static func remaining(_ s: FocusSession, now: Date) -> TimeInterval?
}
```

Consequences, all of which are bugs we simply never have: sleep/wake is correct, timer coalescing is
correct, a dropped tick is invisible, a clock change is self-correcting, and a session that spans a
lid close resumes with the right number.

```swift
// Services/TickTimer.swift
@MainActor
final class TickTimer {
    private var timer: Timer?

    func start(_ onTick: @escaping @MainActor () -> Void) {
        stop()
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { onTick() }
        }
        t.tolerance = 0.15
        // .common — NOT .default. In .default mode the timer stops firing while the
        // MenuBarExtra popover or any NSMenu is tracking, and while a window is resized.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }
}
```

`SessionManager` starts the tick when a session starts and stops it on pause, finish, or when no
session exists. Nothing ticks when nothing is running.

`MainActor.assumeIsolated` is safe here because `Timer` scheduled on `RunLoop.main` fires on the main
thread by definition; it is a documented invariant, not an assumption about ordering.

### 6.3 The `NSWorkspace` observer

Bridged as an `AsyncSequence` consumed by a `@MainActor` `Task`. This is cancellable, has no
`removeObserver` lifetime hazard, and never lets a non-`Sendable` `Notification` escape the main
actor.

```swift
// Services/ApplicationMonitoringService.swift
public struct FrontmostApp: Sendable, Equatable {
    public let bundleIdentifier: String
    public let localizedName: String
}

@MainActor
public protocol ApplicationMonitoring: AnyObject {
    var current: FrontmostApp? { get }
    func start(onChange: @escaping @MainActor (FrontmostApp) -> Void)
    func stop()
}

@MainActor
public final class WorkspaceApplicationMonitor: ApplicationMonitoring {
    public private(set) var current: FrontmostApp?
    private var task: Task<Void, Never>?

    public func start(onChange: @escaping @MainActor (FrontmostApp) -> Void) {
        stop()
        task = Task { @MainActor [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await note in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                // Everything non-Sendable is read and discarded inside this main-actor body.
                guard
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    let bundleID = app.bundleIdentifier
                else { continue }
                let front = FrontmostApp(
                    bundleIdentifier: bundleID,
                    localizedName: app.localizedName ?? bundleID
                )
                guard front != self?.current else { continue }
                self?.current = front
                onChange(front)
            }
        }
    }

    public func stop() { task?.cancel(); task = nil }
}
```

The critical detail: the `NSRunningApplication` object never leaves the loop body. Two `String`s are
extracted immediately and everything downstream operates on the `Sendable` `FrontmostApp` value.

### 6.4 Idle detection

`HIDIdleDetector` polls `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType:
.mouseMoved)` — plus the keyboard and scroll event types, taking the minimum — every 15 seconds from
a `@MainActor` timer. No Accessibility permission is required for this, which matters: idle detection
keeps working even when the user declines Accessibility. Crossing the threshold in either direction
calls back on the main actor; `ActivityTrackingService` closes the open interval and opens an
`isIdle: true` one.

### 6.5 Sleep, wake and app termination

`SleepWakeObserver` watches `NSWorkspace.willSleepNotification`, `didWakeNotification` and
`screensDidLockNotification` on the same `for await` pattern. On sleep, the open activity interval is
closed at the sleep timestamp; on wake, a fresh interval opens. A running focus session is *not*
auto-paused — the user decides — but the review sheet shows the sleep gap as idle time.

`AppDelegate.applicationWillTerminate` calls `Task { try? await env.store.flush() }` inside a
`RunLoop` drain, and `NSSupportsSuddenTermination` is `false` in `Info.plist` so macOS does not kill
us mid-write.

### 6.6 Hand-off from UI to store, and back

Writes are fire-and-forget into the store actor; the UI updates its own in-memory state
optimistically and never blocks on disk:

```swift
@MainActor
func finish(result: SessionResultStatus, summary: String) {
    guard var session = active else { return }
    session = SessionLifecycle.finish(session, at: clock.now, result: result, summary: summary)
    active = nil                         // UI updates immediately
    recentlyFinished.insert(session, at: 0)
    Task { try? await store.upsert(session) }   // hops to the actor
}
```

Reads are `async` and awaited in `.task { }` on container views. `JSONFileStore` coalesces writes:
each `upsert` marks the snapshot dirty and schedules a flush 500 ms later, so a burst of ticks or
edits produces one atomic file replacement rather than dozens.

### 6.7 What is deliberately *not* concurrent

No `DispatchQueue`, no `OperationQueue`, no custom global actors, no `@unchecked Sendable`, no locks,
no Combine publishers. If something feels like it needs a background queue, it is either store I/O
(already handled by the actor) or it is a sign the data model is wrong.

---

## 7. Build and run on this machine

### 7.1 `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription
import Foundation

// LggrPersistence needs SwiftData macros, which ship only with Xcode.
// With Command Line Tools, LGGR_SWIFTDATA is unset and the target simply does not exist.
let swiftData = ProcessInfo.processInfo.environment["LGGR_SWIFTDATA"] == "1"

let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]

var targets: [Target] = [
    .target(
        name: "LggrKit",
        path: "Sources/LggrKit",
        swiftSettings: mode
    ),
    .executableTarget(
        name: "LggrApp",
        dependencies: ["LggrKit"] + (swiftData ? [Target.Dependency("LggrPersistence")] : []),
        path: "Sources/LggrApp",
        exclude: ["_XcodeOnly"],
        swiftSettings: mode + (swiftData ? [.define("LGGR_SWIFTDATA")] : [])
    ),
    .testTarget(
        name: "LggrKitTests",
        dependencies: ["LggrKit"],
        path: "Tests/LggrKitTests",
        swiftSettings: mode
    ),
]

if swiftData {
    targets.append(
        .target(
            name: "LggrPersistence",
            dependencies: ["LggrKit"],
            path: "Sources/LggrPersistence",
            swiftSettings: mode
        )
    )
}

let package = Package(
    name: "Lggr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Lggr", targets: ["LggrApp"]),
        .library(name: "LggrKit", targets: ["LggrKit"]),
    ],
    targets: targets
)
```

The product is named `Lggr` so the built binary is `Lggr`, which is what
`Lggr.app/Contents/MacOS/Lggr` must be.

### 7.2 The single conditional in the app

```swift
// App/StoreBootstrap.swift
import Foundation
import LggrKit
#if LGGR_SWIFTDATA
import LggrPersistence
#endif

enum StoreBootstrap {
    static func makeStore() -> any LggrStore {
        let directory = URL.applicationSupportDirectory.appending(path: "Lggr", directoryHint: .isDirectory)
        #if LGGR_SWIFTDATA
        if let store = try? SwiftDataStore(directory: directory) { return store }
        #endif
        return JSONFileStore(directory: directory)
    }
}
```

That is the entire integration surface. Views, state objects and domain code are identical either
way.

### 7.3 `Scripts/make-app.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Lggr.app"
IDENTITY="${LGGR_SIGN_IDENTITY:--}"   # "-" = ad hoc; override with a self-signed identity

"$ROOT/Scripts/check-layering.sh"

swift build --package-path "$ROOT" -c "$CONFIG" --product Lggr
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/Lggr"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Lggr"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Scripts/AppIcon.icns" ] && cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --sign "$IDENTITY" \
         --entitlements "$ROOT/Scripts/Lggr.entitlements" \
         --timestamp=none \
         "$APP"
codesign --verify --verbose=2 "$APP"

echo "Built $APP"
```

`Scripts/run.sh` is `make-app.sh "$@" && open "$ROOT/build/Lggr.app"`.

**Never launch `.build/debug/Lggr` directly.** Outside a bundle there is no `Info.plist`, so there is
no activation policy, no bundle identifier, `UNUserNotificationCenter` fails to register, and TCC has
nothing to attribute permission to. Always run the assembled app.

### 7.4 `Scripts/Info.plist`

| Key | Value | Why |
|---|---|---|
| `CFBundleIdentifier` | `com.lggr.Lggr` | TCC identity; must never change once permissions are granted. |
| `CFBundleName` / `CFBundleDisplayName` | `Lggr` | |
| `CFBundleExecutable` | `Lggr` | Must match the SPM product name. |
| `CFBundlePackageType` | `APPL` | |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` | |
| `LSMinimumSystemVersion` | `14.0` | Matches `platforms: [.macOS(.v14)]`. |
| **`LSUIElement`** | **`false`** | See 7.6 — deliberate. |
| `LSApplicationCategoryType` | `public.app-category.productivity` | |
| `NSPrincipalClass` | `NSApplication` | Required for a SwiftUI/AppKit app bundle. |
| `NSHighResolutionCapable` | `true` | |
| `NSSupportsSuddenTermination` | `false` | We own unflushed state. |
| `NSSupportsAutomaticTermination` | `false` | A running timer must not be terminated. |
| **`NSAppleEventsUsageDescription`** | "Lggr asks Safari or Chrome for the domain of the frontmost tab so it can classify browser time. It never reads page contents." | Required from Phase 3 for browser-domain capture; the string is shown verbatim in the consent dialog. |
| `CFBundleIconFile` | `AppIcon` | Phase 6. |
| `ITSAppUsesNonExemptEncryption` | `false` | Harmless now, saves a step later. |

**There is no `NSAccessibilityUsageDescription` key.** Accessibility is not a usage-string
permission: `AXIsProcessTrustedWithOptions` shows a system-owned prompt and the user grants it in
System Settings → Privacy & Security → Accessibility. Adding a made-up key does nothing. Our
explanation lives in the onboarding screen instead, which is where it belongs.

### 7.5 `Scripts/Lggr.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Deliberately NOT sandboxed. See docs/_design/02-architecture.md §7.7. -->
    <key>com.apple.security.app-sandbox</key>
    <false/>

    <!-- Needed once we adopt the hardened runtime for notarised distribution,
         so that Apple Events to Safari/Chrome (browser domain, Phase 3) are permitted. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
```

### 7.6 `LSUIElement`: false, with a runtime toggle

The obvious move for a menu-bar app is `LSUIElement = true`. We are not doing that, because
`LSUIElement` also removes the application's main menu, and the spec's keyboard requirements (`⌘N`,
`⌘⇧I`, `⌘⇧A`, `⌘1`–`⌘7`, and the standard text-editing shortcuts inside the summary editor) are menu
commands. An accessory-policy app has no menu bar to hang them on.

So: `LSUIElement = false` (regular app, Dock icon, real main menu, `MenuBarExtra` always present).
Phase 6 adds a "Hide Dock icon" preference that calls
`NSApp.setActivationPolicy(.accessory)` at runtime for users who want the menu-bar-only experience —
which loses the main menu but keeps the global hot key and the `MenuBarExtra`. That is a user
choice, not a build-time decision. The key is present in `Info.plist` with an explicit `false` so the
decision is visible rather than implied.

The menu bar experience works with the main window closed regardless of policy — that requirement is
satisfied by `MenuBarExtra`, not by the activation policy.

### 7.7 Sandboxing vs. Accessibility — the honest answer

The tension is real and it does not have a clean resolution.

**The facts:**

- A sandboxed app *can* be added to the Accessibility list and `AXIsProcessTrusted()` *can* return
  `true`. That part works.
- What does not work is the thing we actually need it for. Reading the focused window title of
  *another* application requires `AXUIElementCreateApplication(pid)` followed by
  `AXUIElementCopyAttributeValue(…, kAXFocusedWindowAttribute, …)`. Under App Sandbox those calls are
  denied for processes outside the sandbox container. Apple's position is that apps controlling or
  inspecting other applications are not sandboxable, which is why every app in this category (window
  managers, automation tools, time trackers with title capture) ships outside the Mac App Store.
- Browser domain capture is worse: it needs Apple Events to Safari/Chrome, which under the sandbox
  requires `com.apple.security.temporary-exception.apple-events` entries per target bundle — an
  App Store review flag, and brittle across browser versions.
- Everything else we do is sandbox-safe: `NSWorkspace.frontmostApplication` (bundle id + display
  name), `CGEventSource` idle time, `UNUserNotificationCenter`, `SMAppService`, and file I/O in our
  own container.

**The stance — decided:**

> **Ship Lggr unsandboxed, distributed outside the Mac App Store.** Window titles and browser domains
> are the difference between "you used Chrome for 42 minutes" and "you reviewed three PRs" — they are
> the product, not a nice-to-have. The spec says "sandboxed where practical"; with title capture in
> scope, it is not practical.

We pay for that by being unambiguous about privacy in ways a sandbox badge never proves anyway:

1. **Zero network code.** The app links no networking framework and makes no request. This is
   verifiable with `otool -L` and stated in the README.
2. **Local storage in a documented, user-visible location:**
   `~/Library/Application Support/Lggr/store.json`. The user can open it, read it, and delete it.
3. **Title and domain capture are opt-in**, off until the user enables them in onboarding, and each
   is independently switchable in Settings.
4. **Full degradation path.** If Accessibility is denied, the app tracks application name and bundle
   id only, classification falls back to app-level rules, and nothing else changes. Permission is
   requested exactly twice in the app's life: once during onboarding, once if the user toggles title
   tracking on in Settings. Never on launch, never on a timer.
5. **Hardened runtime + Developer ID notarisation** when there is a distributable build — that is the
   real trust signal for a non-App-Store app, and the entitlements file above is already shaped for
   it.

**One practical wrinkle you will hit immediately:** TCC keys the Accessibility grant to the code
signature. An ad-hoc signature (`--sign -`) produces a different identity on every rebuild, so macOS
forgets the grant every time `make-app.sh` runs. For day-to-day Phase 3 work, create a self-signed
code-signing certificate in the login keychain (Keychain Access → Certificate Assistant → Create a
Certificate, type "Code Signing") named e.g. `Lggr Dev`, and run
`LGGR_SIGN_IDENTITY="Lggr Dev" ./Scripts/make-app.sh`. The identity is then stable and the grant
persists across rebuilds. Ad hoc remains the default so a fresh clone builds with zero setup.

### 7.8 The daily loop

```bash
swift build                                   # fast compile check
swift test                                    # all of LggrKit
./Scripts/run.sh                              # assemble Lggr.app and launch it
LGGR_GALLERY=1 ./Scripts/run.sh               # open the light/dark view gallery
LGGR_SWIFTDATA=1 swift build                  # only on a machine with Xcode
```

---

## 8. What we are explicitly NOT doing

Listed so nobody adds them back in a later phase "for consistency".

**Architecture**

- No Clean Architecture, no use-case/interactor objects, no Coordinator, no VIPER, no MVVM-per-view.
  Views + `@Observable` state + services + pure domain functions. That is the whole vocabulary.
- No DI container, service locator, or property-wrapper injection. One `AppEnvironment`, constructed
  in one place.
- No repository per entity. One `LggrStore` protocol.
- No generic `Repository<T>`, no `AnyStore` type erasers beyond `any LggrStore`.
- No protocol for a type with a single implementation. `SessionManager`, `MenuBarManager`,
  `ActivityTrackingService`, `ExportService` and `LaunchAtLoginService` are concrete.
- No fourth target for the design system. It is a folder.
- No `.xcodeproj` checked in. SPM only; Xcode opens `Package.swift` natively.

**Frameworks and dependencies**

- No third-party packages at all — not swift-collections, not a snapshot-testing library, not a
  hot-key library.
- No Combine. Observation plus `async`/`await`.
- No Core Data alongside SwiftData. No SQLite.
- Carbon is used in exactly one file (`GlobalShortcutService`, Phase 6) because
  `RegisterEventHotKey` is still the only permission-free system hot key API. Nowhere else.

**Concurrency**

- No `DispatchQueue`, no `OperationQueue`, no `NSLock`, no `@unchecked Sendable`.
- No custom global actors. `@MainActor` for the app, `actor` for the store, `Sendable` for values.
- No background refresh, no daemon, no `XPC` helper, no login-item agent process.

**Product scope (MVP)**

- No authentication, teams, billing, cloud sync, CloudKit, iCloud Drive, or export-to-service.
- No analytics, telemetry, crash reporting, or update checker.
- No AI or LLM summarisation. `SessionSummaryBuilder` is deterministic string assembly, per the spec.
- No calendar, Jira, Linear, GitHub or Slack integrations.
- No streaks, scores, badges, or any gamification.
- No iOS, iPadOS, visionOS or Watch target.
- No localisation pipeline. English strings written inline; no `.xcstrings` catalogue in the MVP.

**Data**

- No migration framework. `StoreSnapshot` carries a `schemaVersion: Int`; the MVP refuses to load a
  newer version and logs a clear error. Real migrations arrive when there is a real installed base.
- No encryption at rest. The file lives in the user's home directory under standard POSIX
  permissions; FileVault is the platform's answer and we do not duplicate it.
- No caching layer, no fetch-result memoisation. `JSONFileStore` holds the whole snapshot in memory
  because the data is measured in hundreds of kilobytes per year.

**Testing**

- No `LggrAppTests` target, no UI tests, no snapshot tests. Domain logic is tested exhaustively; the
  visual layer is verified through the dev gallery and, where Xcode exists, `#Preview`.
- No mocking framework, no code generation. Fakes are hand-written types next to their protocol,
  typically under thirty lines.
