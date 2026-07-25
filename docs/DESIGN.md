# Lggr — Design

> The authoritative design document for Lggr, a native macOS focus-tracking, time-tracking and
> accomplishment-logging application. It synthesises the Phase 1 design set
> (`docs/_design/01-product.md` … `06-checklist.md`) into one file. Where those documents
> contradicted each other, the contradiction is resolved here and recorded in
> **[Appendix A — Resolved conflicts](#appendix-a--resolved-conflicts)**.
>
> Two inputs are binding and are not relitigated: `docs/_design/CONSTRAINTS.md` (hard, empirically
> verified environment limits) and `docs/_design/SPEC.md` (the product specification, the source of
> truth for *what* to build).

> **This document describes the design as planned.** Where implementation contradicted it, the code
> is authoritative and the change is recorded with its reasoning in
> `docs/_design/DECISIONS.md` — eight decisions so far, each one taken because a defect or a
> contradiction forced it, and each enforced by a test. Read that file before trusting a detail here
> about persistence semantics.
>
> Two related documents: `docs/_design/REVIEW.md` is an adversarial critique of *this* document, so
> some of its findings describe code that was never written that way. `docs/_design/SPIKE-menubar.md`
> records three technical assumptions that were measured rather than assumed — the menu bar timer,
> the window lifecycle, and how the UI gets reviewed without `#Preview`.

---

## Build reality — read this first

**Xcode is not installed on this machine.** Only the Command Line Tools are present at
`/Library/Developer/CommandLineTools`. `xcodebuild` does not exist.

The compiler-plugin dylibs `libSwiftDataMacros.dylib` and `libSwiftUIMacros.dylib` ship **only inside
Xcode**. The CLT plugin directory contains only `libObservationMacros.dylib`, `libSwiftMacros.dylib`
and `testing/libTestingMacros.dylib`. Therefore the following produce a hard compile error here:

- `@Model`, `@Relationship`, `@Attribute` (SwiftData macros)
- `#Predicate`
- `#Preview`

The exact error, observed by running the compiler in this working tree:

```
error: external macro implementation type 'SwiftDataMacros.PersistentModelMacro' could not be
found for macro 'Model()'; plugin for module 'SwiftDataMacros' not found
```

Note that the **SwiftData framework itself is present in the SDK** and `import SwiftData` compiles
fine. Only the macros are unavailable.

**How the three-target split resolves it.** The package is split so that the maximum amount of code
compiles, runs and is unit-tested *today*, while still delivering the SwiftData model layer the spec
requires:

| Target | Contents | Compiles here? |
|---|---|---|
| **`LggrKit`** | Every domain value type, every enum, **all** business logic (timer/pause arithmetic, aggregation, context-switch counting, planned-vs-reactive, rule matching, redaction, summary generation, insights, Markdown/CSV rendering), the `LggrStore` protocol, `JSONFileStore`, `InMemoryStore`, `PreviewFixtures`. Foundation only. | ✅ **yes** — and it is fully unit-tested via `./Scripts/test.sh` |
| **`LggrApp`** | `@main` scene graph, `MenuBarExtra`, every view, the design system, `@Observable` state, and the `@MainActor` services that wrap AppKit and system APIs. | ✅ **yes** — and it runs, as a hand-assembled `build/Lggr.app` |
| **`LggrPersistence`** | The SwiftData `@Model` entities (`SD*`), the value-type ⇄ `@Model` mapping, and `SwiftDataStore: LggrStore`. The *only* place `@Model`, `@Relationship`, `@Attribute`, `@ModelActor` and `#Predicate` may appear. | ❌ **no** — added to `Package.swift` only when `LGGR_SWIFTDATA=1`, so `swift build` stays green here |

Two consequences a reader must not be confused by:

1. **The persistence layer looks indirect on purpose.** Domain value types are authoritative;
   SwiftData is a swappable backend behind one protocol. `JSONFileStore` — a durable,
   dependency-free, atomically-writing JSON backend inside `LggrKit` — is what ships and runs today,
   so the vertical slice genuinely persists across launches on this machine. With Xcode present,
   `LGGR_SWIFTDATA=1` swaps in `SwiftDataStore` and **not a single view or domain file changes**.
   `LggrStoreContractTests` runs the identical suite against every backend, so the swap is proven
   rather than hoped for.
2. **`#Preview` is replaced by a real window.** Preview data lives in `LggrKit`'s `PreviewFixtures`
   and every view takes injectable state. `LGGR_GALLERY=1 make run` opens `Dev/PreviewGallery.swift`,
   which renders every registered view twice side by side — `.preferredColorScheme(.light)` and
   `.dark` — against `AppEnvironment.fake()`. A documented Xcode-only file
   `Sources/LggrApp/_XcodeOnly/Previews.swift` (excluded from the SPM target) carries the real
   `#Preview` macros for a machine that has Xcode.

### Machine facts

- macOS 26.2 (build 25C56), Apple Silicon (arm64)
- Swift 6.2.1 (swiftlang-6.2.1.4.8), default target `arm64-apple-macosx26.0`
- macOS SDK 26.1 at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.1.sdk`
- Deployment target for this project: **macOS 14**

**What is verified to compile today:** SwiftUI (`App`, `Scene`, `WindowGroup`, `MenuBarExtra`,
`.menuBarExtraStyle(.window)`, `Settings`, `.windowStyle(.hiddenTitleBar)`, custom `EnvironmentKey`,
`.keyboardShortcut`); `@Observable` / `@Bindable`; AppKit, UserNotifications, ServiceManagement,
Charts; swift-testing and XCTest; SwiftPM `.executableTarget` / `.target` / `.testTarget`; `.app`
bundle assembly by hand plus `codesign`.

### Rules for every agent working in this repository

1. **Never** write `@Model`, `#Predicate` or `#Preview` into `Sources/LggrKit` or `Sources/LggrApp`.
   Those macros belong exclusively in `Sources/LggrPersistence/` and the excluded
   `Sources/LggrApp/_XcodeOnly/`.
2. `swift build` and `./Scripts/test.sh` must stay green at every step. **If you cannot compile it,
   do not claim it works.**
3. **`swift test` on its own silently runs nothing here.** With Command Line Tools, SwiftPM cannot
   locate `Testing.framework`; it prints `Build complete!`, exits `0`, and executes zero tests. Use
   `./Scripts/test.sh` (or `make test`), which fails if zero tests ran. A green exit code with no
   tests is worse than a red one.
4. **`ExistentialAny` is enabled.** Every protocol existential must be spelled `any LggrStore`,
   `any DateProviding`, `[any PersistentModel.Type]`. A bare `LggrStore` is a compile error.
5. **Never launch `.build/debug/LggrApp` directly.** Outside a bundle there is no `Info.plist`, so
   there is no activation policy, no bundle identifier, `UNUserNotificationCenter` traps, and TCC has
   nothing to attribute a permission to. Always `make run`.
6. No third-party dependencies. Apple frameworks only.
7. Avoid force unwraps (`!`) and `try!`. Handle errors explicitly.
8. Keep files small and focused; one primary type per file where practical.
9. Swift language mode v5 for pragmatism with AppKit and timer code, `@MainActor` discipline on UI
   and service types. Domain value types must be `Sendable`.

---

## Table of contents

- [Build reality — read this first](#build-reality--read-this-first)
- [1. Product definition and positioning](#1-product-definition-and-positioning)
  - [1.1 The product in one paragraph](#11-the-product-in-one-paragraph)
  - [1.2 The distinctive idea](#12-the-distinctive-idea)
  - [1.3 Who it is for](#13-who-it-is-for)
  - [1.4 The wedge](#14-the-wedge)
  - [1.5 What Lggr is explicitly not](#15-what-lggr-is-explicitly-not)
  - [1.6 Product principles](#16-product-principles)
- [2. The exact MVP scope](#2-the-exact-mvp-scope)
  - [2.1 Two framings](#21-two-framings)
  - [2.2 IN — the current build (Phase 2 vertical slice)](#22-in--the-current-build-phase-2-vertical-slice)
  - [2.3 OUT of the current build, returns inside the MVP](#23-out-of-the-current-build-returns-inside-the-mvp)
  - [2.4 OUT of the MVP entirely](#24-out-of-the-mvp-entirely)
  - [2.5 Success criteria](#25-success-criteria)
- [3. Architecture and folder structure](#3-architecture-and-folder-structure)
  - [3.1 Architecture in one paragraph](#31-architecture-in-one-paragraph)
  - [3.2 Module graph and dependency direction](#32-module-graph-and-dependency-direction)
  - [3.3 What belongs in each target, and why](#33-what-belongs-in-each-target-and-why)
  - [3.4 Layering enforcement](#34-layering-enforcement)
  - [3.5 Complete folder structure](#35-complete-folder-structure)
  - [3.6 Service catalog](#36-service-catalog)
  - [3.7 Dependency injection](#37-dependency-injection)
  - [3.8 Threading and concurrency model](#38-threading-and-concurrency-model)
  - [3.9 Build and run on this machine](#39-build-and-run-on-this-machine)
  - [3.10 What we are explicitly not doing](#310-what-we-are-explicitly-not-doing)
  - [3.11 Risk register](#311-risk-register)
- [4. The data model](#4-the-data-model)
  - [4.0 Where each type lives](#40-where-each-type-lives)
  - [4.1 Domain enums](#41-domain-enums)
  - [4.2 Domain value types](#42-domain-value-types)
  - [4.3 FocusSession timing — the exact pause arithmetic](#43-focussession-timing--the-exact-pause-arithmetic)
  - [4.4 The store protocol](#44-the-store-protocol)
  - [4.5 SwiftData `@Model` classes](#45-swiftdata-model-classes)
  - [4.6 Mapping strategy](#46-mapping-strategy)
  - [4.7 Consistency checklist for later agents](#47-consistency-checklist-for-later-agents)
- [5. The main screens and navigation](#5-the-main-screens-and-navigation)
  - [5.0 The feeling we are building for](#50-the-feeling-we-are-building-for)
  - [5.1 The navigation shell](#51-the-navigation-shell)
  - [5.2 Design tokens](#52-design-tokens)
  - [5.3 Shared components and shared policy](#53-shared-components-and-shared-policy)
  - [5.4 The seven sidebar screens](#54-the-seven-sidebar-screens)
  - [5.5 The four panels](#55-the-four-panels)
  - [5.6 Menu bar icon states](#56-menu-bar-icon-states)
  - [5.7 Keyboard map](#57-keyboard-map)
  - [5.8 Accessibility](#58-accessibility)
  - [5.9 What we deliberately avoid](#59-what-we-deliberately-avoid)
  - [5.10 Exact user-facing copy — Phase 2](#510-exact-user-facing-copy--phase-2)
  - [5.11 Key user flows](#511-key-user-flows)
- [6. Permissions and privacy strategy](#6-permissions-and-privacy-strategy)
  - [6.0 The stance in one paragraph](#60-the-stance-in-one-paragraph)
  - [6.1 Permission and entitlement inventory](#61-permission-and-entitlement-inventory)
  - [6.2 App Sandbox — the recommendation](#62-app-sandbox--the-recommendation)
  - [6.3 The permission ladder](#63-the-permission-ladder)
  - [6.4 The PermissionsService contract](#64-the-permissionsservice-contract)
  - [6.5 Onboarding](#65-onboarding)
  - [6.6 The re-ask policy, exactly](#66-the-re-ask-policy-exactly)
  - [6.7 Private and excluded applications](#67-private-and-excluded-applications)
  - [6.8 Data lifecycle](#68-data-lifecycle)
  - [6.9 Settings → Privacy](#69-settings--privacy)
  - [6.10 Verification checklist](#610-verification-checklist)
  - [6.11 The privacy statement](#611-the-privacy-statement)
- [7. The phased execution checklist](#7-the-phased-execution-checklist)
  - [7.0 How to read the checklist](#70-how-to-read-the-checklist)
  - [7.1 Ground truth about the repository today](#71-ground-truth-about-the-repository-today)
  - [7.2 Phase 1 — product and technical design](#72-phase-1--product-and-technical-design)
  - [7.3 Phase 2 — the smallest working vertical slice](#73-phase-2--the-smallest-working-vertical-slice)
  - [7.4 Definition of done — Phase 2](#74-definition-of-done--phase-2)
  - [7.5 Phase 3 — automatic application tracking](#75-phase-3--automatic-application-tracking)
  - [7.6 Phase 4 — daily experience](#76-phase-4--daily-experience)
  - [7.7 Phase 5 — weekly review](#77-phase-5--weekly-review)
  - [7.8 Phase 6 — product polish](#78-phase-6--product-polish)
  - [7.9 Unit test inventory](#79-unit-test-inventory)
  - [7.10 What could make Phase 2 slip](#710-what-could-make-phase-2-slip)
- [Appendix A — Resolved conflicts](#appendix-a--resolved-conflicts)
- [Appendix B — Deliberately deferred, and one thing to verify](#appendix-b--deliberately-deferred-and-one-thing-to-verify)

---

## 1. Product definition and positioning

### 1.1 The product in one paragraph

Lggr is a native macOS app that records, for every stretch of your working day, three things that
normally never sit next to each other: **what you meant to do, what you actually did, and what came
out of it.** Before you start working you spend five seconds saying your intent — "Finish the receipt
deduplication PR", 50 minutes, deep work, on the SOR project — and a timer starts in the menu bar.
While it runs, Lggr quietly reconstructs reality from the applications you were actually in, the
windows you actually had focused, and the moments you were idle or interrupted, and turns that into a
plain sentence: *"Worked primarily in Xcode and Terminal on receipt deduplication. Reviewed one GitHub
pull request and spent seven minutes in Slack."* When the timer ends it asks one question — completed,
made progress, blocked, interrupted, or reprioritized — and files the result in a running log of
delivered work. By Friday you are not reconstructing your week from memory, Git history and Slack
scrollback: you can see where the hours went, how often you were pulled off intent, how much of the
week was planned versus reactive, and a list of things you can point at and say *I did that*.
Everything stays on your Mac, in a file you can open, read, and delete.

### 1.2 The distinctive idea

Most time trackers record only reality (a wall of app usage), and most task managers record only
intent (a list of things you told yourself to do). Lggr's unit of value is the **gap between the two,
plus the evidence** — and it treats that gap as information, not as failure. A session that ended
`.blocked` is as useful a record as one that ended `.completed`, and the app never renders either one
in red.

### 1.3 Who it is for

| Audience | The specific pain Lggr removes |
|---|---|
| **Engineering managers** | Most of the job leaves no artifact. Reviewing three PRs, unblocking two engineers, killing a bad plan in a 20-minute call, and absorbing an incident produces zero commits. At review time, or in a 1:1 with your own manager, you have nothing to point at and you feel like you did nothing. Lggr makes the invisible work — code review, unblocking, decisions, deprioritisation — a first-class, countable `AccomplishmentType`. |
| **Developers** | You know you had a bad week but not *why*. Was it meetings? Was it fifteen small context switches an hour? Was it that the deep work only ever happened after 4 pm? Lggr answers with your own data: context switches per day, time by category, when your longest uninterrupted stretches actually occurred. |
| **Knowledge workers generally** | You start the day with a clear intent and end it unable to account for six of the eight hours. Lggr does not ask you to remember; it asks you to state intent once, and it reconstructs the rest. |

### 1.4 The wedge

The narrowest, sharpest version: **a senior IC or first-line engineering manager who, on Friday
afternoon, has to write down what they accomplished this week and cannot.** Everything else in the
product exists to make that Friday moment take two minutes and be honest.

### 1.5 What Lggr is explicitly not

- **Not a surveillance tool.** There is no employer, no admin, no dashboard anyone else can see, no
  export-to-manager, and no network code at all. The tracking exists to help *you* reconstruct
  *your* day; the design test for any tracking feature is "would I want this if I were the only
  person who would ever see it?" If the answer is no, it does not ship.
- **Not team analytics.** No accounts, no teams, no aggregate, no benchmarking against colleagues,
  no "your team averages 4.2 focus hours". One machine, one person.
- **Not a task manager.** Lggr does not hold your backlog. The interruption inbox exists to get an
  intrusive thought out of your head in four seconds so you can keep working — it is a capture
  surface, not a to-do list, and the weekly model deliberately caps you at one primary outcome and
  two secondary ones (`OutcomePriority.maximumPerWeek`) so it cannot degenerate into one.
- **Not a productivity scorer.** No streaks, no badges, no percentage-of-day-focused grade, no red.
  Insights are neutral and evidence-based ("Your longest uninterrupted sessions happened before
  11:00"), never judgmental ("You wasted 2.1 hours").
- **Not a Pomodoro purist tool.** 25 and 50 are defaults, not doctrine; custom and open-ended are
  first-class, and nothing scolds you for running past the timer.

### 1.6 Product principles

Taken from `SPEC.md` and binding on every decision below.

1. Starting a focus session must take fewer than five seconds.
2. The app should require minimal manual data entry.
3. Activity tracking should help reconstruct work, not surveil the user.
4. The interface should feel calm and focused, not like enterprise time-tracking software.
5. The user should be able to understand their day at a glance.
6. Every screen should have a clear primary action.
7. Use progressive disclosure instead of showing every option immediately.
8. Prefer keyboard shortcuts and native macOS interactions.
9. Store everything locally by default.
10. Do not include authentication, teams, billing, or cloud sync in the MVP.
11. Avoid unnecessary abstractions and overengineering.
12. Build the smallest polished vertical slice before adding advanced functionality.

---

## 2. The exact MVP scope

### 2.1 Two framings

**The current build** is Phase 2 — the smallest polished vertical slice that must compile, run and
persist before anything else is written (`SPEC.md` § *Implementation order*: *"This phase must compile
and work before continuing"*). **The MVP** is Phases 2 through 6. Everything past Phase 6 is not in
the MVP at all.

### 2.2 IN — the current build (Phase 2 vertical slice)

Ruthlessly, this and nothing else:

1. **Create, edit, deactivate and delete a project** — name, `colorID` from `Project.colorIDs`,
   `iconID` SF Symbol. `ProjectsView` + `ProjectEditor`.
2. **Start a focus session** — `StartSessionForm` with `OutcomeField` (required), `ProjectPicker`
   (pre-selected from `UserPreferences.lastSelectedProjectID`), `WorkTypePicker` (all eight
   `WorkType` cases), `DurationPicker` (25 / 50 / custom / open-ended, defaulting to
   `workType.suggestedDuration`). Primary action **Start Focus** (⌘↩); secondary **Start without
   timer** (open-ended). Recent-outcome suggestions from the last 30 days.
3. **Live timer in the main window** — `ActiveSessionView` + `TimerDisplay`, visually dominant,
   showing intended outcome, project badge, and elapsed or remaining, derived every tick from
   `FocusSession.elapsed(at:)` / `.remaining(at:)`. Progress ring driven by `.progress(at:)`.
   Overrun shown as `+M:SS` via `.overrun(at:)`.
4. **Live timer in the menu bar** — `MenuBarExtra` with `.menuBarExtraStyle(.window)`,
   `MenuBarLabel` (state symbol from `SessionState.symbolName` + `mm:ss`), `MenuBarIdleView` with
   the six idle entry points, `MenuBarActiveView` with outcome, time, project, pause, finish.
   Works with the main window closed.
5. **Pause and resume** — `SessionControls`, Space key, `FocusSession.togglePause(at:)`. Menu bar
   symbol changes to `pause.circle`. Elapsed is frozen while paused.
6. **Finish the session** — `finish(at:status:)`, closing any open pause first.
7. **Choose a result status** — `SessionReviewSheet` + `ResultStatusPicker`, all five
   `SessionResultStatus` cases; required.
8. **A deterministic suggested summary, editable** — `SessionSummaryBuilder` (Phase-2 form: intent,
   project, work type, duration) rendered in `SummaryEditor`. Optional `blocker` and `nextStep`
   behind a disclosure.
9. **Persist it** — `JSONFileStore` writing `~/Library/Application Support/Lggr/store.json`, atomic
   writes, crash-and-relaunch recovery of an in-flight session via `loadActiveSession()`.
   `UserPreferences` in `UserDefaults` via `UserDefaultsPreferencesStore`.
10. **See it in Today** — `TodayView` with `TodayHeader` (current or next session) and a list of
    `CompletedSessionRow`s for the day.
11. **Log an accomplishment from a finished session** — `AddAccomplishmentSheet`, all eleven
    `AccomplishmentType` cases, pre-filled from the session, linked by `focusSessionID`.
12. **The keyboard spine** — ⌘N new session, ⌘↩ start/confirm, Space pause/resume, Esc dismiss,
    ⌘1–⌘7 sidebar navigation, full tab order. Every Phase-2 flow completable without a mouse.
13. **The infrastructure that makes the above true** — `Package.swift` with the conditional
    `LggrPersistence` target, `Scripts/make-app.sh` (bundle + codesign), `Scripts/test.sh`,
    `Scripts/check-layering.sh`, `Scripts/run.sh`, the `LGGR_GALLERY=1` light/dark preview gallery,
    `PreviewFixtures`, and the Phase-2 test files listed in § 3.5.
14. **Light and dark mode, and empty states, for every Phase-2 screen.** A screen without a designed
    empty state is not done.

### 2.3 OUT of the current build, returns inside the MVP

| Deferred item | Returns in | Why it is not now |
|---|---|---|
| Frontmost-application tracking, `ActivityEvent`, idle detection, activity intervals | **Phase 3** | Needs a session to attach to. The slice must persist a session first. |
| Window title capture (`WindowTitleReader`, Accessibility) | **Phase 3** | Depends on a stable code-signing identity and the tracking pipeline existing. |
| Browser domain capture (`BrowserDomainReader`, Apple Events) | **Phase 3** | Most fragile input; nothing depends on it. |
| Classification rules, `ClassificationEngine`, `RulesView`, `ReclassifySheet` | **Phase 3** | Nothing to classify until activity exists. |
| Context-switch counting, `LiveActivityStrip`, `SessionTimelineStrip`, `SessionStatsGrid` | **Phase 3** | Derived from activity events. |
| Interruption capture, `Interruption`, the inbox, ⌘⇧I | **Phase 3** (capture) / **Phase 4** (inbox view) | Valuable, but a session that persists is the prerequisite for everything. |
| Privacy exclusions, private-app redaction, retention purge | **Phase 3** | Ships in the *same phase* as the tracking it protects — never later. |
| Today metrics row, daily timeline, `DailyDigest`, accomplishment log view | **Phase 4** | Needs a day's worth of real activity to be worth designing against. |
| Markdown export (daily, accomplishments), `ExportService`, `ActivityCSVExporter` | **Phase 4** | |
| Weekly outcomes, `WeeklyOutcome`, planned-vs-reactive, weekly review, insights, charts, CSV export | **Phase 5** | The largest surface; needs weeks of real data to tune. |
| Onboarding, permissions flow, global shortcut (⌘⇧Space), notifications, Settings window, launch at login, accessibility polish, app icon refinement | **Phase 6** | Polish over a working core, per principle 12. |

### 2.4 OUT of the MVP entirely

Not in Phases 2–6. Listed so no one adds them "while we're in there".

- **Authentication / user accounts** — never in a local-only single-user app. Would return only if
  sync ever shipped, which is post-MVP at the earliest.
- **Teams, sharing, multi-user, roles, manager views** — post-MVP, and only if the "not a
  surveillance tool" positioning can survive it. Current answer: no.
- **Billing, licensing, trials, in-app purchase, receipt validation** — post-MVP.
- **Cloud sync, CloudKit, iCloud Drive, multi-device** — post-MVP. The value types are `Codable` and
  relate by `UUID`, so the door is not nailed shut, but nothing in Phases 2–6 assumes it.
- **AI / LLM summaries, embeddings, semantic classification** — post-MVP, explicitly. SPEC:
  *"Rule-based classification engine before any AI"* and *"Do not implement advanced analytics or AI
  summaries until the core tracking workflow is functional, polished, persistent, and tested."*
  `SessionSummaryBuilder` is deterministic string assembly.
- **Calendar / Jira / Linear / GitHub / Slack integrations** — post-MVP. Each one is a network
  dependency, an auth flow, and a privacy story we are currently not required to tell.
- **Analytics, telemetry, crash reporting, update checker** — never. Zero network code is a
  verifiable product claim (§ 6.10) and we are not trading it away.
- **iOS / iPadOS / watchOS / visionOS targets** — post-MVP.
- **Localisation pipeline** — post-MVP. English strings inline; no `.xcstrings` catalogue.
- **Screenshots, keystroke logging, clipboard capture, document contents, message contents** —
  **never, in any phase.** This is a product boundary, not a scheduling one.
- **Streaks, scores, badges, gamification, shaming** — never.
- **Mac App Store distribution** — post-MVP and probably never, because it is incompatible with the
  Accessibility-based title capture that makes the product work (§ 6.2).
- **Data migration framework, encryption at rest, caching layer** — post-MVP; see § 3.10 and risk R7.
- **Retroactive per-application purge** — marking an app private or excluded applies going forward
  only. See § 6.7.5; the confirmation copy says so, so shipping without it is not misleading.

### 2.5 Success criteria

Observable, measurable, and checkable by one person on one machine.

**Speed — the five-second promise**

| Criterion | Measurement | Target |
|---|---|---|
| Time to start a session | Stopwatch, 10 consecutive cold starts, from keystroke to timer visible | **Median < 5 s, p95 < 8 s** |
| Interaction cost | Count of keystrokes beyond typing the outcome, with a remembered project | **≤ 2** |
| Time to capture an interruption | Stopwatch, keystroke to sheet dismissed | **< 4 s**, session never paused |
| Cold launch to interactive Today | `mach_absolute_time` at `applicationDidFinishLaunching` → first frame, with a year of fixture data | **< 500 ms** |
| Mouse-free operation | Every Phase-2 flow attempted with the trackpad physically unavailable | **12 / 12 completable** |

> Until `GlobalShortcutService` lands in Phase 6, the Phase-2 measurement starts from **⌘N with the
> app frontmost** (or a click on the menu bar item), not from ⌘⇧Space. See Appendix A, R-08.

**Correctness — the numbers must be trustworthy**

| Criterion | Measurement | Target |
|---|---|---|
| Test suite | `swift build && ./Scripts/test.sh` | **Green at every commit**, no skipped tests |
| Timing edge cases | `FocusSessionTimingTests` against § 4.3.5 | **All 9 cases covered and passing** |
| Backend equivalence | `LggrStoreContractTests` on `InMemoryStore` and `JSONFileStore` | **Identical observable behaviour** |
| Timer accuracy under stress | 50-min session with 2 pause cycles and a 10-min machine sleep | **`elapsed` within 1 s of hand-computed truth** |
| Crash durability | `kill -9` mid-session, relaunch | **Session restored, elapsed correct within 1 s** |
| Persistence durability | 100 launch/quit cycles with writes | **Zero lost records, zero corrupt files** |
| Layering | `./Scripts/check-layering.sh` | **`layering OK`; no `@Model`/`#Predicate`/`#Preview` outside `LggrPersistence` and `_XcodeOnly`** |

**Cost — it has to be invisible when idle**

| Criterion | Measurement | Target |
|---|---|---|
| Idle energy | Activity Monitor Energy Impact, no session running | **0.0**, no attributable idle wakeups in `powermetrics --samplers tasks` |
| Active CPU | 10-minute average with a session running and tracking on | **< 0.5%** |
| Memory | RSS with a year of fixture data loaded | **< 150 MB** |
| Main-thread responsiveness | No hitch when switching applications rapidly for 60 s | **No beachball; AX reads bounded by a 0.25 s messaging timeout** |

**Privacy — the claims must be verifiable, not asserted**

| Criterion | Measurement | Target |
|---|---|---|
| No network | `otool -L` on the built binary; full-day packet capture | **No networking framework linked; zero outbound connections** |
| Private-app redaction | Mark an app private, use it, inspect `store.json` by hand | **No title, no bundle ID, no domain on disk — only "Private activity"** |
| Excluded apps | Same, for an excluded app | **No event at all** |
| Deletion is real | Delete a session, inspect the file | **Its `ActivityEvent`s are gone from disk** |
| Retention purge | Set `dataRetentionDays = 7`, seed 30 days of fixtures, relaunch | **Only the last 7 days of activity remain; every session and accomplishment survives** |
| Permission etiquette | Deny Accessibility, then use the app for a full day | **Prompted at most twice ever; every screen renders; no error state** |
| Degraded tracking still useful | With Accessibility denied for a week | **Session, app-level activity, category totals and weekly review all still produce output** |

**Product — does it actually reconstruct the week?** Measured by one week of real, unprompted use.

| Criterion | Measurement | Target |
|---|---|---|
| The Friday test | Answer SPEC § 9's seven questions using only the app — no Git log, no Slack, no calendar | **7 / 7 answerable** |
| Summary usefulness | Fraction of finished sessions whose generated summary was accepted or lightly edited rather than replaced or emptied | **≥ 80%** |
| Evidence density | Accomplishments logged per working week | **≥ 5**, at least 2 of an "invisible work" type (`personUnblocked`, `pullRequestReviewed`, `decisionMade`, `workDeprioritized`) |
| Classification coverage | Share of tracked time not in `.unknown`, after the default rule set | **≥ 70% in week 1, ≥ 90% after one week of corrections** |
| Correction burden | Manual reclassifications per tracked hour, after week 2 | **< 1** |
| Capture rate | Focus sessions started per working day during the trial | **≥ 3**, without a reminder to do so |
| Honest retention | Consecutive working days of unprompted use, no spreadsheet fallback | **≥ 10** |

**Craft — the calm bar**

| Criterion | Measurement | Target |
|---|---|---|
| Light and dark | Every Phase-2 screen in the `LGGR_GALLERY=1` gallery, side by side | **No unreadable contrast, no missing separator, no hardcoded colour** |
| Empty states | Every list and dashboard with an empty store | **Every one has designed copy and a clear primary action — zero blank panes** |
| One primary action per screen | Design walkthrough of every screen | **Exactly one visually dominant action each** (Settings is the documented exception, § 5.4.7) |
| No dead affordances | Click every control | **Zero placeholder buttons that do nothing** |
| Tone | Grep the UI strings | **No "score", no "streak", no "wasted", no "you failed"; no red used for a normal outcome** |
| Accessibility | Full keyboard traversal; VoiceOver pass over Today and the active session | **Every control reachable and labelled** |

---

## 3. Architecture and folder structure

### 3.1 Architecture in one paragraph

Lggr is a three-target Swift package. **`LggrKit`** is a pure Foundation-only domain library that
owns every value type, every calculation and the persistence protocol; it compiles and is fully
unit-tested today. **`LggrApp`** is the executable: SwiftUI views, `@Observable` state, and a handful
of `@MainActor` services that wrap AppKit and system APIs. **`LggrPersistence`** is a thin, Xcode-only
SwiftData adapter that conforms to the same persistence protocol. The app runs today on a durable
`JSONFileStore` shipped inside `LggrKit`; when Xcode is present, `LGGR_SWIFTDATA=1` swaps in
`SwiftDataStore` and **not a single view or domain file changes**. There is no Clean Architecture, no
DI container, no Combine, and no abstraction that does not have at least two real implementations.

### 3.2 Module graph and dependency direction

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

### 3.3 What belongs in each target, and why

#### `LggrKit` — pure domain library

- **Domain value types** — `Project`, `WeeklyOutcome`, `FocusSession`, `ActivityEvent`,
  `ActivitySample`, `Interruption`, `Accomplishment`, `ClassificationRule`, `UserPreferences`. All
  `struct`, all `Sendable`, all `Identifiable` by `UUID`, all `Codable` (with one deliberate
  exception: `ActivitySample`, § 6.7.4). Relationships are expressed as `UUID` foreign keys, not
  object references — this is what lets the same types round-trip through JSON today and SwiftData
  tomorrow.
- **All business logic** — timer/pause arithmetic, activity aggregation, context-switch counting,
  planned-vs-reactive, rule matching, private-app redaction, domain extraction, session summary
  generation, daily digest, weekly insights, Markdown/CSV rendering. Every one of these is a pure
  function or a `struct` with no I/O.
- **The `LggrStore` protocol** and its two in-package implementations (`JSONFileStore`,
  `InMemoryStore`), plus `PreferencesStoring` / `UserDefaultsPreferencesStore`.
- **`PreviewFixtures`** — the sample data used by the dev gallery, the Xcode-only previews, and the
  tests.

Why: this is ~70% of the codebase, it is where every bug that matters lives, and it compiles and is
tested **today**. Keeping AppKit and SwiftData out of it is what makes that true.

#### `LggrApp` — SwiftUI executable

`@main` scene graph, `MenuBarExtra`, the main window, `Settings`, every `View`, the design tokens,
the `@Observable` view state, and the `@MainActor` services that wrap `NSWorkspace`,
`CGEventSource`, `UNUserNotificationCenter`, `AXIsProcessTrusted`, `NSSavePanel`, `ServiceManagement`
and Carbon hot keys. Views bind to `@Observable` state objects and to `any LggrStore` — never to a
persistence class. No `@Model`, no `#Preview`, no `#Predicate`.

Why an executable target rather than a library plus shim: SPM builds it directly,
`Scripts/make-app.sh` drops the resulting binary into a hand-assembled `build/Lggr.app`, and it runs.

#### `LggrPersistence` — SwiftData adapter (Xcode-only)

The `@Model` classes (`SDProject`, `SDFocusSession`, …), the value-type ⇄ `@Model` mapping, and
`SwiftDataStore: LggrStore`. It is added to `Package.swift` only when `LGGR_SWIFTDATA=1`, so
`swift build` stays green here.

Why a separate target rather than `#if` inside `LggrApp`: a whole target can be excluded from the
package manifest; scattered `#if`s cannot, and they rot. The `SD` prefix on the `@Model` types
removes any ambiguity in mapping code, where `Project` (struct) and `SDProject` (class) coexist.

#### `LggrKitTests` — the only test target

swift-testing (`import Testing`) against `LggrKit`. Covers exactly the spec's testing list plus the
suites the architecture requires (§ 7.9).

There is deliberately **no `LggrAppTests`**. The app layer holds no logic worth testing — services
are thin adapters over system APIs, and the visual layer is verified through the dev gallery. Adding
a second test target would mostly test SwiftUI.

### 3.4 Layering enforcement

`Scripts/check-layering.sh` is the mechanical guard. It fails the build if:

- `Sources/LggrKit` contains `import SwiftUI`, `import AppKit` or `import SwiftData`;
- `@Model`, `#Predicate` or `#Preview` appear anywhere under `Sources/LggrKit` or `Sources/LggrApp`
  except `Sources/LggrApp/_XcodeOnly/`;
- **[P3]** the argument label `windowTitle:` appears outside `ActivityEvent.swift`,
  `PrivacyRedactor.swift`, `ActivitySample.swift`, `PreviewFixtures.swift`,
  `Sources/LggrPersistence/Mapping/` and `Tests/`;
- **[P3]** `AXUIElementCopyAttributeValue` or `NSAppleScript` appear outside `WindowTitleReader.swift`
  and `BrowserDomainReader.swift`;
- **[P6]** a system permission prompt is fired outside the three sanctioned call sites (§ 6.6).

It prints `layering OK` and exits `0` on success, and it runs at the top of `make-app.sh`. A few
dozen lines of shell that make the constraint mechanical instead of aspirational.

### 3.5 Complete folder structure

Phase markers: **`[P2]`** = the vertical slice we build now. `[P3]`–`[P6]` = later phases; the file
does not exist until that phase starts. `[P1]` = design docs, already written.

```
lggr/
├── Package.swift                                   [P2]  conditional LggrPersistence target
├── Makefile                                        [P2]  build · test · app · run · gallery · check
├── README.md                                       [P2]  build + run on a machine without Xcode
├── .gitignore                                      [P2]  .build/, build/, .DS_Store, .omc/
├── docs/
│   ├── DESIGN.md                                   [P1]  ← this file (the authoritative design)
│   └── _design/
│       ├── CONSTRAINTS.md                          [P1]
│       ├── SPEC.md                                 [P1]
│       ├── 01-product.md … 06-checklist.md         [P1]  source documents, superseded by DESIGN.md
├── Resources/
│   ├── Info.plist                                  [P2]
│   ├── Lggr.entitlements                           [P2]
│   └── AppIcon.icns                                [P2]  generated by Scripts/make-icon.sh
├── Scripts/
│   ├── make-app.sh                                 [P2]  assemble + sign build/Lggr.app
│   ├── run.sh                                      [P2]  make-app.sh && open build/Lggr.app
│   ├── test.sh                                     [P2]  swift test + fails when zero tests ran
│   ├── check-layering.sh                           [P2]  import / macro / privacy guard
│   ├── make-icon.sh                                [P2]
│   └── IconGenerator.swift                         [P2]
├── Sources/
│   ├── LggrKit/
│   │   ├── Model/
│   │   │   ├── Enums.swift                         [P2]  ALL enums, appended each phase
│   │   │   ├── Project.swift                       [P2]
│   │   │   ├── FocusSession.swift                  [P2]
│   │   │   ├── FocusSession+Timing.swift           [P2]  elapsed / pause / resume / finish
│   │   │   ├── Accomplishment.swift                [P2]
│   │   │   ├── UserPreferences.swift               [P2]  + KeyboardShortcutSpec
│   │   │   ├── ActivityEvent.swift                 [P3]
│   │   │   ├── ActivitySample.swift                [P3]  raw capture; deliberately NOT Codable
│   │   │   ├── ClassificationRule.swift            [P3]
│   │   │   ├── Interruption.swift                  [P3]
│   │   │   └── WeeklyOutcome.swift                 [P5]
│   │   ├── Domain/
│   │   │   ├── DurationFormatting.swift            [P2]  "50m", "1:23:45", "+2:07"
│   │   │   ├── SessionSummaryBuilder.swift         [P2]  deterministic summary (grows in P3)
│   │   │   ├── ActivityAggregator.swift            [P3]  totals by app and by category
│   │   │   ├── ActivityCoalescer.swift             [P3]  merge adjacent same-app intervals
│   │   │   ├── ContextSwitchCounter.swift          [P3]
│   │   │   ├── ClassificationEngine.swift          [P3]  rule matching, priority ordering
│   │   │   ├── PrivacyRedactor.swift               [P3]  ActivitySample → ActivityEvent? policy
│   │   │   ├── DomainExtractor.swift               [P3]  URL string → host, nothing else
│   │   │   ├── SessionTimelineBuilder.swift        [P3]  grouped timeline blocks
│   │   │   ├── DailyDigest.swift                   [P4]  Today's metric rollup
│   │   │   ├── PlannedVsReactive.swift             [P5]
│   │   │   ├── WeeklyReviewBuilder.swift           [P5]
│   │   │   └── InsightGenerator.swift              [P5]  neutral, evidence-based observations
│   │   ├── Export/
│   │   │   ├── MarkdownRendering.swift             [P4]  shared helpers
│   │   │   ├── DailySummaryMarkdown.swift          [P4]
│   │   │   ├── AccomplishmentLogMarkdown.swift     [P4]
│   │   │   ├── ActivityCSVExporter.swift           [P4]  export-before-delete
│   │   │   ├── WeeklyReviewMarkdown.swift          [P5]
│   │   │   └── SessionsCSVExporter.swift           [P5]
│   │   ├── Store/
│   │   │   ├── LggrStore.swift                     [P2]  the single persistence protocol
│   │   │   ├── StoreError.swift                    [P2]
│   │   │   ├── StoreSnapshot.swift                 [P2]  Codable root + schemaVersion
│   │   │   ├── AtomicFileWriter.swift              [P2]  temp file + replaceItemAt, 0600
│   │   │   ├── JSONFileStore.swift                 [P2]  default backend, store.json
│   │   │   ├── InMemoryStore.swift                 [P2]  the fake: previews + tests
│   │   │   └── PreferencesStore.swift              [P2]  PreferencesStoring + UserDefaults impl
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
│   │   │   ├── BrowserDomainReader.swift           [P3]  Apple Events, opt-in, an `actor`
│   │   │   ├── ClassificationService.swift         [P3]  rules cache over ClassificationEngine
│   │   │   ├── ExportService.swift                 [P4]  NSSavePanel + write
│   │   │   ├── RetentionPruner.swift               [P4]  activity-only retention job
│   │   │   ├── NotificationService.swift           [P6]  protocol + UN impl + recording fake
│   │   │   ├── PermissionsService.swift            [P6]  protocol + system impl + stub (stub P3)
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
│   │   │   ├── Palette.swift                       [P2]  ProjectColor → Color, dynamic colours
│   │   │   ├── Motion.swift                        [P2]  named animations, reduce-motion aware
│   │   │   └── Iconography.swift                   [P2]  SF Symbol names in one place
│   │   ├── Components/
│   │   │   ├── Card.swift                          [P2]
│   │   │   ├── SectionHeader.swift                 [P2]
│   │   │   ├── EmptyStateView.swift                [P2]
│   │   │   ├── PrimaryButtonStyle.swift            [P2]
│   │   │   ├── ProjectBadge.swift                  [P2]
│   │   │   ├── ErrorBanner.swift                   [P2]
│   │   │   └── MetricTile.swift                    [P4]
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
│   │   │   │   ├── SettingsView.swift              [P6]  one view, two hosts (⌘, and ⌘7)
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
│   └── LggrPersistence/                            [P3, built only with LGGR_SWIFTDATA=1]
│       ├── Models/
│       │   ├── SDProject.swift
│       │   ├── SDWeeklyOutcome.swift
│       │   ├── SDFocusSession.swift
│       │   ├── SDActivityEvent.swift
│       │   ├── SDInterruption.swift
│       │   ├── SDAccomplishment.swift
│       │   └── SDClassificationRule.swift
│       ├── Mapping/
│       │   ├── SDProject+Mapping.swift
│       │   ├── SDWeeklyOutcome+Mapping.swift
│       │   ├── SDFocusSession+Mapping.swift
│       │   ├── SDActivityEvent+Mapping.swift
│       │   ├── SDInterruption+Mapping.swift
│       │   ├── SDAccomplishment+Mapping.swift
│       │   └── SDClassificationRule+Mapping.swift
│       ├── SwiftDataStore.swift                          conforms to LggrStore
│       └── ModelContainerFactory.swift                   schema + container configuration
│
└── Tests/
    └── LggrKitTests/
        ├── EnumsTests.swift                        [P2]
        ├── SupportTests.swift                      [P2]  clock, calendar windows, fixtures
        ├── FocusSessionTimingTests.swift           [P2]  ≥ 14 tests
        ├── DurationFormattingTests.swift           [P2]
        ├── SessionSummaryBuilderTests.swift        [P2]
        ├── CodableRoundTripTests.swift             [P2]
        ├── UserPreferencesTests.swift              [P2]
        ├── StoreSnapshotCodableTests.swift         [P2]
        ├── JSONFileStoreTests.swift                [P2]  durability + atomicity + 0600
        ├── LggrStoreContractTests.swift            [P2]  same suite × every backend
        ├── ActivityEventTests.swift                [P3]
        ├── ClassificationRuleTests.swift           [P3]
        ├── ClassificationEngineTests.swift         [P3]
        ├── ActivityAggregatorTests.swift           [P3]
        ├── ActivityCoalescerTests.swift            [P3]
        ├── ContextSwitchCounterTests.swift         [P3]
        ├── PrivacyRedactorTests.swift              [P3]
        ├── DomainExtractorTests.swift              [P3]
        ├── SessionTimelineBuilderTests.swift       [P3]
        ├── DailyDigestTests.swift                  [P4]
        ├── MarkdownExportTests.swift               [P4]
        ├── RetentionTests.swift                    [P4]
        ├── PlannedVsReactiveTests.swift            [P5]
        ├── WeeklyReviewBuilderTests.swift          [P5]
        ├── InsightGeneratorTests.swift             [P5]
        └── CSVExportTests.swift                    [P5]
```

**Phase 2 file count: ~74 source files.** That is the whole vertical slice — create a project, start
a session, live timer in window and menu bar, pause/resume, finish, pick a result, generate and edit
a summary, persist it, see it in Today, and log an accomplishment from it.

### 3.6 Service catalog

The spec's nine services, plus three that Phase 6 needs. "Protocol" means there is a real second
implementation (a stub used by the gallery and by manual testing); anything with only one
implementation is a concrete type, because a protocol with one conformer is dead weight.

| Service | Responsibility (one sentence) | Target | Shape | Isolation |
|---|---|---|---|---|
| **SessionManager** | Owns the one in-flight `FocusSession` and drives start/pause/resume/finish, delegating all arithmetic to `FocusSession+Timing`. | LggrApp | Concrete `@Observable final class` | `@MainActor` |
| **MenuBarManager** | Derives the menu-bar label (symbol + optional time string) and popover presentation state from `SessionManager` and preferences. | LggrApp | Concrete `@Observable final class` | `@MainActor` |
| **ActivityTrackingService** | Turns frontmost-app and idle signals into closed `ActivityEvent` intervals attached to the current session, and writes them to the store. | LggrApp | Concrete `@Observable final class` | `@MainActor` |
| **ApplicationMonitoringService** | Reports the frontmost application's bundle id and display name whenever it changes. | LggrApp | Protocol `ApplicationMonitoring` + `WorkspaceApplicationMonitor` + `StubApplicationMonitor` | `@MainActor` |
| **IdleDetectionService** | Reports seconds since the last HID event and emits idle-begin / idle-end above the configured threshold. | LggrApp | Protocol `IdleDetecting` + `HIDIdleDetector` + `StubIdleDetector` | `@MainActor` |
| **WindowTitleReader** | Reads the focused window title of the frontmost app, once per switch, gated on `AXIsProcessTrusted()`. | LggrApp | Concrete `struct` | `@MainActor` |
| **BrowserDomainReader** | Asks Safari/Chromium for the front tab's URL and returns only its host. | LggrApp | Concrete `actor` — the one documented exception to app-wide `@MainActor` | `actor` |
| **ClassificationService** | Holds the enabled rule set in memory and classifies an activity sample by delegating to the pure `ClassificationEngine`. | LggrApp (cache) over LggrKit (engine) | Concrete `@Observable final class` wrapping a `Sendable struct` | `@MainActor` wrapper, `nonisolated` engine |
| **NotificationService** | Schedules and delivers the three local notification kinds and honours the user's per-kind toggles. | LggrApp | Protocol `Notifying` + `UserNotificationService` + `RecordingNotifier` | `@MainActor` |
| **ExportService** | Presents `NSSavePanel` and writes the string produced by `LggrKit`'s Markdown/CSV renderers to disk. | LggrApp (I/O) over LggrKit (rendering) | Concrete `struct` | `@MainActor` |
| **RetentionPruner** | Deletes `ActivityEvent`s older than `dataRetentionDays`, and nothing else. | LggrApp | Concrete `final class` | `@MainActor` |
| **PermissionsService** | Reports and requests Accessibility, Automation and Notification authorisation, exactly once per user action. | LggrApp | Protocol `PermissionsProviding` + `SystemPermissionsService` + `StubPermissionsService` | `@MainActor` |
| **GlobalShortcutService** *(P6)* | Registers the configurable system-wide hot key and invokes a closure on the main actor. | LggrApp | Protocol `GlobalShortcutRegistering` + `CarbonHotKeyService` + `NoopShortcutService` | `@MainActor` |
| **LaunchAtLoginService** *(P6)* | Reads and writes the launch-at-login state via `SMAppService`. | LggrApp | Concrete `struct` | `@MainActor` |
| **LggrStore** | The single persistence boundary: `async throws` CRUD over domain value types. | Protocol in LggrKit; `JSONFileStore` + `InMemoryStore` in LggrKit; `SwiftDataStore` in LggrPersistence | Protocol + three `@MainActor final class`es | `@MainActor` |

**Two "services" that are not in the app target.** `ClassificationEngine` and every Markdown/CSV
renderer live in `LggrKit` as `Sendable` structs with pure functions. The spec names them as
"services"; they are pure computation, so they belong where they can be unit-tested. The app-target
`ClassificationService` and `ExportService` exist only to hold mutable cache state and to touch the
file system or present panels.

### 3.7 Dependency injection

Three mechanisms, each with a rule about when it applies. Nothing else. No container, no resolver,
no `@Injected`.

#### 3.7.1 One composition root object in the SwiftUI environment

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
    public let preferences: any PreferencesStoring
    public let clock: any DateProviding

    public let sessionManager: SessionManager
    public let menuBar: MenuBarManager
    public let activity: ActivityTrackingService          // [P3]
    public let classification: ClassificationService      // [P3]
    public let notifications: any Notifying               // [P6]
    public let permissions: any PermissionsProviding      // [P6]

    public init(
        store: any LggrStore,
        preferences: any PreferencesStoring,
        clock: any DateProviding,
        monitor: any ApplicationMonitoring,
        idle: any IdleDetecting,
        notifications: any Notifying,
        permissions: any PermissionsProviding
    ) {
        self.store = store
        self.preferences = preferences
        self.clock = clock
        self.notifications = notifications
        self.permissions = permissions
        self.sessionManager = SessionManager(store: store, clock: clock)
        self.menuBar = MenuBarManager(preferences: preferences)
        self.classification = ClassificationService(store: store)
        self.activity = ActivityTrackingService(
            store: store, preferences: preferences, clock: clock,
            monitor: monitor, idle: idle, classification: classification
        )
    }
}
```

> Phase 2 constructs only `store`, `preferences`, `clock`, `sessionManager` and `menuBar`. Phase 3+
> services are **absent from the Phase-2 type**, not stubbed — the property is added in the phase
> that adds the service.

Two factories, side by side, so the fake is never an afterthought:

```swift
public extension AppEnvironment {
    /// Real system integrations, real durable store.
    static func live() -> AppEnvironment {
        AppEnvironment(
            store: StoreBootstrap.makeStore(),
            preferences: UserDefaultsPreferencesStore(),
            clock: SystemClock(),
            monitor: WorkspaceApplicationMonitor(),
            idle: HIDIdleDetector(),
            notifications: UserNotificationService(),
            permissions: SystemPermissionsService()
        )
    }

    /// Everything faked. Used by the dev gallery, by Xcode #Previews, and by manual UI checks.
    static func fake(
        store: any LggrStore = InMemoryStore(seed: PreviewFixtures.demoDay),
        preferences: any PreferencesStoring = InMemoryPreferencesStore(),
        clock: any DateProviding = FixedClock(PreviewFixtures.referenceDate),
        monitor: any ApplicationMonitoring = StubApplicationMonitor(script: PreviewFixtures.appSwitches),
        idle: any IdleDetecting = StubIdleDetector(idleSeconds: 0),
        notifications: any Notifying = RecordingNotifier(),
        permissions: any PermissionsProviding = StubPermissionsService(accessibility: .granted)
    ) -> AppEnvironment {
        AppEnvironment(store: store, preferences: preferences, clock: clock,
                       monitor: monitor, idle: idle,
                       notifications: notifications, permissions: permissions)
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
            SettingsView()
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

#### 3.7.2 Custom `EnvironmentKey` for `Sendable` values with a sane default

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

#### 3.7.3 Plain `init` parameters for anything a view renders

**Rule: a view never fetches its own data.** Presentational views take already-resolved value types
as `let` properties. Only the handful of container views (`TodayView`, `ProjectsView`, `RootWindow`,
`MenuBarContentView`, later `WeeklyReviewView`) read the environment and hand data down.

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

#### 3.7.4 How a preview substitutes a fake

`Sources/LggrApp/Dev/PreviewGallery.swift` is a `Window` scene that only opens when the process
environment contains `LGGR_GALLERY=1`. It renders every registered view twice — once with
`.preferredColorScheme(.light)`, once with `.dark` — inside `.environment(AppEnvironment.fake())`.
This is our light/dark verification loop on a machine without Xcode, and it is a real, running
window, not a screenshot harness. **Every new view is added to the gallery in the same commit that
adds the view.**

`Sources/LggrApp/_XcodeOnly/Previews.swift` holds the identical set as real `#Preview` macros and is
listed in `exclude:` in `Package.swift`, so it never reaches this toolchain.

#### 3.7.5 How a test substitutes a fake

`LggrKitTests` never imports SwiftUI and never constructs `AppEnvironment`. It exercises pure
functions with literal inputs, and exercises store behaviour against `InMemoryStore` or a
`JSONFileStore` rooted at a temporary directory:

```swift
@Test func pausedTimeIsExcludedFromElapsed() {
    let start = FixtureCalendar.at(9, 0)
    var session = FocusSession(intendedOutcome: "x", plannedDuration: 50 * 60, startedAt: start)
    session.pause(at: FixtureCalendar.at(9, 10))
    session.resume(at: FixtureCalendar.at(9, 25))
    #expect(session.elapsed(at: FixtureCalendar.at(9, 30)) == 15 * 60)
}

@MainActor
@Test func sessionsSurviveAStoreRestart() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = JSONFileStore(directory: dir)
    try await store.saveSession(PreviewFixtures.finishedSession)
    try await store.flush()

    let reopened = JSONFileStore(directory: dir)
    let day = DateInterval.day(containing: FixtureCalendar.referenceDate)
    #expect(try await reopened.loadSessions(in: day).count == 1)
}
```

Time is always injected. Every timing function takes `at:` / `now:` explicitly and never calls
`Date()` — that is the single most important testability decision in the codebase.

### 3.8 Threading and concurrency model

Swift language mode **v5** with `@MainActor` discipline applied by hand. This is where macOS apps
break, so the rules are absolute rather than case-by-case.

#### 3.8.1 The isolation domains

1. **`@MainActor` — the entire `LggrApp` target, and the store.** Every view, every `@Observable`
   state object, every service, and every `LggrStore` conformer. This is not laziness: `NSWorkspace`
   notifications are delivered on the main thread, `MenuBarExtra`'s label must update on the main
   thread, SwiftData's `ModelContext` is main-actor bound, and the data volume (a few thousand
   records per year) makes background work pointless. One domain means zero data races in the app
   layer by construction.
2. **`nonisolated` and `Sendable` — all of `LggrKit`'s domain and logic types.** Every domain type is
   a `struct` of `Sendable` members; every calculation is a `static func` or a method on a `Sendable`
   `struct`. They can be called from any isolation domain.
3. **One documented exception: `BrowserDomainReader` is an `actor`.** `NSAppleScript.executeAndReturnError`
   is synchronous IPC that can block for seconds behind a consent sheet or a busy browser; running it
   on the main actor would freeze the timer and the menu bar. It owns one cached compiled
   `NSAppleScript` per browser, serialises calls, and returns a `Sendable String?`. This is the only
   exception, and it exists because it is provably necessary (§ 6.1.2).

**Where the file I/O goes.** `JSONFileStore` is `@MainActor`, but JSON encoding and the atomic write
happen inside a `nonisolated` helper that the store `await`s, so **no encoding and no file I/O runs
on the main actor**. This is how the `@MainActor` protocol keeps the "no disk work on the main
thread" intent that motivated the original `actor` design.

Explicit annotations:

```swift
public struct FocusSession: Codable, Sendable, Identifiable, Hashable { ... }
public enum WorkType: String, Codable, Sendable, CaseIterable { ... }
@MainActor public protocol LggrStore: AnyObject { ... }
@MainActor public final class JSONFileStore: LggrStore { ... }
@MainActor @Observable public final class SessionManager { ... }
public actor BrowserDomainReader { ... }                       // [P3], the one exception
```

#### 3.8.2 The ticking timer

**The timer does not accumulate time. It only asks the UI to redraw.** Elapsed and remaining time are
always derived from stored `Date` values (§ 4.3).

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

`SessionManager` starts the tick when a session starts or resumes and stops it on pause, finish, or
when no session exists. **Nothing ticks when nothing is running.**

`MainActor.assumeIsolated` is safe here because a `Timer` scheduled on `RunLoop.main` fires on the
main thread by definition; it is a documented invariant, not an assumption about ordering.

Consequences we get for free, all of which are bugs we simply never have: sleep/wake is correct,
timer coalescing is correct, a dropped tick is invisible, a clock change is self-correcting, and a
session that spans a lid close resumes with the right number.

#### 3.8.3 The `NSWorkspace` observer  [P3]

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

#### 3.8.4 Idle detection  [P3]

`HIDIdleDetector` polls `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType:)`
for mouse-moved, key-down and scroll-wheel, taking the minimum, **every 15 seconds** from a
`@MainActor` timer. No Accessibility permission is required for this, which matters: idle detection
keeps working even when the user declines Accessibility. Crossing the threshold in either direction
calls back on the main actor; `ActivityTrackingService` closes the open interval and opens an
`isIdle: true` one.

#### 3.8.5 Sleep, wake and app termination

`SleepWakeObserver` watches `NSWorkspace.willSleepNotification`, `didWakeNotification` and
`screensDidLockNotification` on the same `for await` pattern. On sleep the open activity interval is
closed at the sleep timestamp; on wake a fresh interval opens. A running focus session is **not**
auto-paused — the user decides — but the review sheet shows the sleep gap as idle time, which is
exactly invariant 6 in § 4.3.3.

`AppDelegate.applicationWillTerminate` flushes the store before returning, and
`applicationShouldTerminateAfterLastWindowClosed` returns `false` so closing the window leaves the
menu bar timer running. `NSSupportsSuddenTermination` and `NSSupportsAutomaticTermination` are both
`false` in `Info.plist` so macOS does not kill us mid-write.

#### 3.8.6 Hand-off from UI to store, and back

Writes are fire-and-forget into the store; the UI updates its own in-memory state optimistically and
never blocks on disk:

```swift
@MainActor
func finish(result: SessionResultStatus, summary: String) {
    guard var session = active else { return }
    session.finish(at: clock.now, status: result)
    session.resultSummary = summary
    active = nil                                     // UI updates immediately
    recentlyFinished.insert(session, at: 0)
    Task { try? await store.saveSession(session) }   // hops off, never blocks the frame
}
```

Reads are `async` and awaited in `.task { }` on container views. `JSONFileStore` coalesces writes:
each `save…` marks the snapshot dirty and schedules a flush 500 ms later, so a burst of ticks or
edits produces one atomic file replacement rather than dozens of disk wakeups.

#### 3.8.7 What is deliberately not concurrent

No `DispatchQueue`, no `OperationQueue`, no custom global actors, no `@unchecked Sendable`, no locks,
no Combine publishers. If something feels like it needs a background queue, it is either store I/O
(already handled by the `nonisolated` encode/write helper) or it is a sign the data model is wrong.

### 3.9 Build and run on this machine

#### 3.9.1 `Package.swift`

```swift
// swift-tools-version: 6.0
import PackageDescription
import Foundation

// LggrPersistence needs SwiftData macros, which ship only with Xcode.
// With Command Line Tools, LGGR_SWIFTDATA is unset and the target simply does not exist.
let swiftData = ProcessInfo.processInfo.environment["LGGR_SWIFTDATA"] == "1"

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("ExistentialAny"),
]

var targets: [Target] = [
    .target(
        name: "LggrKit",
        path: "Sources/LggrKit",
        swiftSettings: settings
    ),
    .executableTarget(
        name: "LggrApp",
        dependencies: ["LggrKit"] + (swiftData ? [Target.Dependency("LggrPersistence")] : []),
        path: "Sources/LggrApp",
        exclude: ["_XcodeOnly"],
        swiftSettings: settings + (swiftData ? [.define("LGGR_SWIFTDATA")] : [])
    ),
    .testTarget(
        name: "LggrKitTests",
        dependencies: ["LggrKit"],
        path: "Tests/LggrKitTests",
        swiftSettings: settings
    ),
]

if swiftData {
    targets.append(
        .target(
            name: "LggrPersistence",
            dependencies: ["LggrKit"],
            path: "Sources/LggrPersistence",
            swiftSettings: settings
        )
    )
}

let package = Package(
    name: "Lggr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LggrApp", targets: ["LggrApp"]),
        .library(name: "LggrKit", targets: ["LggrKit"]),
    ],
    targets: targets
)
```

The executable product is **`LggrApp`**, so the built binary is `LggrApp`, which is what
`build/Lggr.app/Contents/MacOS/LggrApp` and `CFBundleExecutable` must be. The manifest in the
repository also carries a Command Line Tools `Testing.framework` search-path workaround; keep it.

#### 3.9.2 The single conditional in the app

```swift
// App/StoreBootstrap.swift
import Foundation
import LggrKit
#if LGGR_SWIFTDATA
import LggrPersistence
#endif

enum StoreBootstrap {
    @MainActor
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
way. `check-layering.sh` asserts that `LGGR_SWIFTDATA` appears in no other file.

#### 3.9.3 `Scripts/make-app.sh`

The script in the repository is real and already does the right thing. Its shape:

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Lggr.app"
IDENTITY="${LGGR_SIGN_IDENTITY:--}"   # "-" = ad hoc; override with a self-signed identity

"$ROOT/Scripts/check-layering.sh"

swift build --package-path "$ROOT" -c "$CONFIG" --product LggrApp
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/LggrApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LggrApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"

codesign --force --sign "$IDENTITY" \
         --options runtime \
         --entitlements "$ROOT/Resources/Lggr.entitlements" \
         --timestamp=none \
         "$APP"
codesign --verify --verbose=2 "$APP"

echo "Built $APP"
```

`Scripts/run.sh` is `make-app.sh "$@" && open "$ROOT/build/Lggr.app"`.

> **Ad-hoc signing does not give a stable code identity.** An ad-hoc signature's cdhash changes
> whenever the binary changes, so macOS forgets the Accessibility grant on every rebuild. For
> Phase 3 work, create a self-signed *Code Signing* certificate in the login keychain (Keychain
> Access → Certificate Assistant → Create a Certificate, type "Code Signing") named `Lggr Dev` and
> build with `LGGR_SIGN_IDENTITY="Lggr Dev" ./Scripts/make-app.sh`. Ad hoc remains the default so a
> fresh clone builds with zero setup. Any comment in `make-app.sh` claiming otherwise is wrong and
> should be corrected.

#### 3.9.4 `Resources/Info.plist`

| Key | Value | Why |
|---|---|---|
| `CFBundleIdentifier` | `com.luisdoriz.lggr` | TCC identity. **Must never change once a permission has been granted.** |
| `CFBundleName` / `CFBundleDisplayName` | `Lggr` | |
| `CFBundleExecutable` | `LggrApp` | Must match the SPM product name. |
| `CFBundlePackageType` | `APPL` | |
| `CFBundleShortVersionString` / `CFBundleVersion` | `0.1.0` / `1` | |
| `LSMinimumSystemVersion` | `14.0` | Matches `platforms: [.macOS(.v14)]`. |
| **`LSUIElement`** | **`false`** | See § 3.9.6 — deliberate. |
| `LSApplicationCategoryType` | `public.app-category.productivity` | |
| `NSPrincipalClass` | `NSApplication` | Required for a SwiftUI/AppKit app bundle. |
| `NSHighResolutionCapable` | `true` | |
| `NSSupportsSuddenTermination` | `false` | We own unflushed state. |
| `NSSupportsAutomaticTermination` | `false` | A running timer must not be terminated. |
| **`NSAppleEventsUsageDescription`** | *"Lggr asks your browser for the domain of the active tab so that web activity can be grouped by site. Only the domain is stored, never the full URL or page contents."* | Required from Phase 3. **Without it the process is killed** on the first Apple Event. Shown verbatim in the consent dialog. |
| `NSHumanReadableCopyright` | *"Lggr. All data stays on this Mac."* | |
| `NSAccessibilityUsageDescription` | present, harmless | macOS has no such TCC key and ignores it. Kept as self-documentation for a reader of the bundle; the real explanation lives in onboarding. See Appendix A, C11. |
| `CFBundleIconFile` | `AppIcon` | |
| `ITSAppUsesNonExemptEncryption` | `false` | Harmless now, saves a step later. |

#### 3.9.5 `Resources/Lggr.entitlements`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Deliberately NOT sandboxed. See DESIGN.md § 6.2. -->
    <key>com.apple.security.app-sandbox</key>
    <false/>

    <!-- Required under the hardened runtime so Apple Events to Safari/Chrome
         (browser domain, Phase 3) are permitted at all. -->
    <key>com.apple.security.automation.apple-events</key>
    <true/>

    <!-- Declared false on purpose, as reviewable evidence that Lggr has no network code. -->
    <key>com.apple.security.network.client</key>
    <false/>
    <key>com.apple.security.network.server</key>
    <false/>
</dict>
</plist>
```

Verify what actually shipped: `codesign -d --entitlements - build/Lggr.app`.

#### 3.9.6 `LSUIElement`: false, with a runtime toggle

The obvious move for a menu-bar app is `LSUIElement = true`. We are not doing that, because
`LSUIElement` also removes the application's main menu, and the spec's keyboard requirements (⌘N,
⌘⇧I, ⌘⇧A, ⌘1–⌘7, and the standard text-editing shortcuts inside the summary editor) are menu
commands. An accessory-policy app has no menu bar to hang them on.

So: `LSUIElement = false` (regular app, Dock icon, real main menu, `MenuBarExtra` always present).
Phase 6 adds a **Hide Dock icon** preference that calls `NSApp.setActivationPolicy(.accessory)` at
runtime for users who want the menu-bar-only experience — which loses the main menu but keeps the
global hot key and the `MenuBarExtra`. That is a user choice, not a build-time decision, and its help
text says so. The key is present with an explicit `false` so the decision is visible rather than
implied.

The menu bar experience works with the main window closed regardless of policy — that requirement is
satisfied by `MenuBarExtra`, not by the activation policy.

#### 3.9.7 The daily loop

```bash
swift build                                   # fast compile check
./Scripts/test.sh                             # all of LggrKit — NEVER bare `swift test`
make app                                      # assemble + sign build/Lggr.app
make run                                      # assemble and launch
LGGR_GALLERY=1 make run                        # open the light/dark view gallery (= make gallery)
LGGR_PERMISSIONS=none make run                 # [P3] force a permission tier without touching TCC
LGGR_SWIFTDATA=1 swift build                   # only on a machine with Xcode
```

### 3.10 What we are explicitly not doing

Listed so nobody adds them back in a later phase "for consistency".

**Architecture**

- No Clean Architecture, no use-case/interactor objects, no Coordinator, no VIPER, no MVVM-per-view.
  Views + `@Observable` state + services + pure domain functions. That is the whole vocabulary.
- No DI container, service locator, or property-wrapper injection. One `AppEnvironment`, constructed
  in one place.
- No repository per entity. One `LggrStore` protocol.
- No generic `Repository<T>`, no type erasers beyond `any LggrStore`.
- No protocol for a type with a single implementation. `SessionManager`, `MenuBarManager`,
  `ActivityTrackingService`, `ExportService`, `RetentionPruner` and `LaunchAtLoginService` are
  concrete.
- No static-function façade over methods that already exist on a value type. Session arithmetic lives
  on `FocusSession`, not in a `SessionClock` namespace.
- No fourth target for the design system. It is a folder.
- No `.xcodeproj` checked in. SPM only; Xcode opens `Package.swift` natively.

**Frameworks and dependencies**

- No third-party packages at all — not swift-collections, not a snapshot-testing library, not a
  hot-key library.
- No Combine. Observation plus `async`/`await`.
- No Core Data alongside SwiftData. No SQLite of our own.
- Carbon is used in exactly one file (`GlobalShortcutService`, Phase 6) because `RegisterEventHotKey`
  is still the only permission-free system hot key API. Nowhere else.

**Concurrency**

- No `DispatchQueue`, no `OperationQueue`, no `NSLock`, no `@unchecked Sendable`.
- No custom global actors. `@MainActor` for the app and the store, `Sendable` for values, and exactly
  one `actor` (`BrowserDomainReader`).
- No background refresh, no daemon, no XPC helper, no login-item agent process.

**Data**

- No migration framework. `StoreSnapshot` carries a `schemaVersion: Int`; the MVP refuses to load a
  newer version and says so clearly. Real migrations arrive when there is a real installed base.
- No encryption at rest. The file lives in the user's home directory under owner-only POSIX
  permissions; FileVault is the platform's answer and we do not duplicate it with a homegrown scheme
  that adds a key-management failure mode without adding real protection. This is stated plainly in
  onboarding rather than papered over.
- No caching layer, no fetch-result memoisation. `JSONFileStore` holds the whole snapshot in memory
  because the data is measured in hundreds of kilobytes per year.

**Testing**

- No `LggrAppTests` target, no UI tests, no snapshot tests. Domain logic is tested exhaustively; the
  visual layer is verified through the dev gallery and, where Xcode exists, `#Preview`.
- No mocking framework, no code generation. Fakes are hand-written types next to their protocol,
  typically under thirty lines.

### 3.11 Risk register

Likelihood and impact are stated for the MVP as a whole. "Mitigation" means a specific, already-named
artifact — not a promise to be careful.

#### R1 — No Xcode on the build machine; SwiftData macros cannot compile

**Likelihood: certain (already happened). Impact: high** — the spec mandates SwiftData; a naïve
implementation does not compile a single file.

**Mitigation.** The three-target split. `LggrKit` is Foundation-only and holds ~70% of the code and
100% of the logic; `LggrPersistence` is added to `Package.swift` only under `LGGR_SWIFTDATA=1`;
`LggrApp` touches it through exactly one file, `App/StoreBootstrap.swift`. `JSONFileStore` is the
shipping backend today and is genuinely durable, so the vertical slice is real, not a stub.
`check-layering.sh` fails the build if the macros appear outside `Sources/LggrPersistence/` or
`_XcodeOnly/`. `LggrStoreContractTests` runs the identical suite against every backend, so the swap
is proven rather than hoped for. `#Preview` is replaced by the `LGGR_GALLERY=1` window, which is a
real running app.

**Residual risk:** `LggrPersistence` is written but never compiled here. It will not build first try
on a machine with Xcode. That is accepted and budgeted; it is a thin mapping layer with no logic, and
the contract tests define exactly what "correct" means for it.

#### R2 — App Sandbox versus Accessibility permission

**Likelihood: certain. Impact: high** — window titles are the difference between "you used Chrome for
42 minutes" and "you reviewed three PRs".

**The conflict, precisely.** A sandboxed app *can* appear in the Accessibility list and
`AXIsProcessTrusted()` *can* return true. What fails is the thing we need it for: reading another
application's focused window title requires `AXUIElementCreateApplication(pid)` plus
`AXUIElementCopyAttributeValue(…, kAXFocusedWindowAttribute, …)`, and those calls are denied under
App Sandbox for processes outside the container. Browser domain capture is worse — Apple Events to
Safari/Chrome under the sandbox require per-bundle
`com.apple.security.temporary-exception.apple-events` entries.

**Mitigation.** Ship unsandboxed, hardened runtime, Developer ID signed and notarised, distributed
outside the Mac App Store (§ 6.2). We buy back the trust a sandbox badge would have signalled with
things that are actually verifiable: zero networking frameworks linked, a documented user-readable
store path, title and domain capture that are independently switchable, and a full degradation path
if Accessibility is denied. The sandboxed configuration is kept *buildable* (one entitlement flip)
so the degraded mode is a real code path we can test.

#### R3 — Timer drift and sleep/wake handling

**Likelihood: high if implemented naïvely** (an accumulating tick counter is the obvious design and it
is wrong). **Impact: high** — a wrong duration poisons every downstream number. Users forgive a
missing feature; they do not forgive a timer that lies.

**Mitigation.** The timer never accumulates. Every duration is a pure function of stored `Date`s
(§ 4.3), with every subtraction clamped at zero. `TickTimer` is a 1 Hz `Timer` with `tolerance = 0.15`
on `RunLoop.main` in `.common` mode whose only job is to ask the UI to redraw. `SleepWakeObserver`
closes the open `ActivityEvent` at the sleep timestamp and opens a fresh one on wake; the focus
session is not auto-paused, and the sleep gap surfaces as idle time on the review sheet.
`FocusSessionTimingTests` covers all nine edge cases in § 4.3.5 with an injected `FixedClock`.

#### R4 — Menu bar timer battery cost

**Likelihood: medium. Impact: medium-high** — a menu bar app with visible energy impact gets deleted.

**Mitigation, as a budget rather than an intention.**

- Exactly one repeating timer exists in the whole app, at 1 Hz, `tolerance = 0.15`, and it runs
  **only while a session is running**. Paused, finished and no-session states run nothing.
- The tick is gated further: it runs only when the elapsed number is actually visible — i.e.
  `showTimerInMenuBar` is on, **or** the main window is on screen and not occluded.
- Idle detection polls every **15 s**, not every second.
- Application tracking is event-driven (`AsyncSequence` over `didActivateApplicationNotification`),
  not polled.
- Store writes are coalesced on a 500 ms debounce, so a burst of edits is one atomic file replacement.
- No background refresh, no daemon, no XPC helper, no login-item agent process.

**Measured acceptance:** with no session running, Activity Monitor Energy Impact reads 0.0 and
`powermetrics --samplers tasks` attributes no idle wakeups to Lggr; with a session running, average
CPU under 0.5% over a 10-minute sample. Checked once per phase.

#### R5 — Window titles across apps that do not expose `AXTitle`

**Likelihood: high** — Electron apps, some Chromium builds, full-screen apps, apps in secure input
mode. **Impact: medium** — classification quality degrades; nothing breaks.

**Mitigation.** `ActivityEvent.windowTitle` is `String?` and every consumer handles `nil`.
Classification degrades through a defined ladder: `windowTitleContains` → `domain` →
`applicationName` → `application` (bundle ID) → `.unknown`, and `.unknown` is a first-class
displayable category, not an error state. Concretely:

- Call `AXUIElementSetMessagingTimeout` (0.25 s) on every element we create. An unresponsive target
  app must never be able to hang the main actor — this is the single most likely beachball in the
  product.
- Attempt the read **once per application switch**, not on a timer. No retry loops.
- Skip title capture entirely while `IsSecureEventInputEnabled()` is true (a password field somewhere
  has focus) — a correctness *and* privacy mitigation.
- Ship a default rule set that is useful on bundle IDs alone (Xcode → Coding, Slack → Communication,
  Terminal → Coding, Zoom/Meet → Meeting), so the app is not dependent on titles to be worth using.

#### R6 — Browser domain extraction

**Likelihood: high fragility. Impact: low-medium.**

**Mitigation.** Treated as the most optional input in the system: opt-in, off until the user enables
it (`trackBrowserDomains` defaults to `false`), and requiring per-browser Automation consent. Safari
and the Chromium dictionary (Chrome, Edge, Brave, Arc, Chromium) are supported; Firefox exposes no
scriptable URL and yields `nil`. **We extract the host only**, immediately, and never store the path,
query string or fragment: `github.com`, never `github.com/acme/private-repo/pull/1234`. A denied or
failed Apple Event is cached as "unsupported for this bundle ID" so we never prompt or retry in a
loop. If the whole feature regresses on a future macOS, the app loses one classification input and
nothing else.

#### R7 — SwiftData migration once real data exists

**Likelihood: medium** (certain eventually). **Impact: high** — data loss in a "log of what you
accomplished" app is the one unrecoverable failure. The log *is* the product.

**Mitigation.** The architecture already removes most of the exposure: **the domain value types are
authoritative and SwiftData is a swappable backend**, so the canonical shape of the data is `Codable`
structs related by `UUID`, not a store schema. `StoreSnapshot` carries an explicit `schemaVersion: Int`;
the MVP refuses to load a snapshot newer than it understands and says so clearly rather than partially
decoding. There is deliberately **no migration framework** because there is no installed base. What
we build now, cheaply, so we can migrate later:

- `CodableRoundTripTests` asserts every value type and every enum **raw string** survives
  encode/decode unchanged — which is why every enum has an explicit raw value.
- `LggrStoreContractTests` proves the backends are observationally identical.
- Before any schema change ships: copy the store file to `store.<version>.backup.json` first, and
  ship an "Export everything" action. Recovery is re-import, not a migration plan that has to be
  right the first time.
- `UserPreferences` lives in `UserDefaults` under `com.lggr.userPreferences.v1`, so a store failure
  can never cost the user their hot key or their privacy settings. Note the forward warning in
  § 4.4.2: a field added after v1 ships needs an explicit `decodeIfPresent` path or a `v2` key bump.

#### R8 — Clock changes and DST

**Likelihood: medium. Impact: medium** — a negative duration or a 25-hour Tuesday makes the whole app
look broken.

**Mitigation.** Durations use absolute time (`Date`/`TimeInterval`), which is timezone- and
DST-independent by construction, and every subtraction is clamped at zero, so a backwards clock step
can shorten a duration but can never invert one. *Bucketing* is where DST actually bites, so all day
and week boundaries go through `Support/CalendarWindows.swift` using `Calendar.dateInterval(of:for:)`
in the user's current calendar and timezone — **never** `date + 86_400` and never a hardcoded
7 × 24 h week. A DST day is 23 or 25 hours long and the daily timeline must lay blocks out on the
real interval length. `WeeklyOutcome.weekStartDate` is stored as midnight-at-week-start in the user's
calendar and recomputed, not arithmetically derived. `FixtureCalendar` includes a DST-transition date
so the suite actually exercises this.

#### R9 — `MenuBarExtra(.window)` label redraw and keyboard focus

**Likelihood: medium-high. Impact: high** — it threatens principle 1 directly, and if the label does
not redraw at 1 Hz then SPEC Phase 2 item 4 cannot be delivered at all.

**Mitigation.** Spike `TickTimer` + `MenuBarManager` + `MenuBarLabel` (tasks P2-46, P2-48, P2-68) on
**day one**, before any other view work. The test is literally: does the menu bar count down for 60
uninterrupted seconds, and does it keep counting while the popover is open? Fallback: drop
`MenuBarExtra` for an AppKit `NSStatusItem` owned by `AppDelegate` — a contained change *if* nothing
else has been built on the `MenuBarExtra` scene, which is exactly why the spike goes first.

For keyboard focus: the guaranteed keyboard path is the main window's start sheet reached via ⌘N (a
real menu command on a real main menu — which is why `LSUIElement` is `false`), and the popover is
the mouse path. If the popover cannot hold first responder, the global shortcut opens the window
sheet instead of the popover; the five-second budget survives either way.

#### R10 — Activity event volume

**Likelihood: medium. Impact: medium** — `JSONFileStore` holds the entire snapshot in memory, and a
heavy year is a few thousand sessions but potentially a hundred thousand activity events.

**Mitigation.** `ActivityCoalescer` merges adjacent same-application intervals before they are
written, collapsing alt-tab noise by an order of magnitude. `dataRetentionDays` defaults to 90 with an
automatic purge (`deleteActivityEvents(startedBefore:)`). If the measured snapshot exceeds ~10 MB or
cold start exceeds 500 ms with a year of fixture data, that is the trigger to move activity events to
append-only per-month files — **not before**.

#### R11 — Crash or force-quit mid-session

**Likelihood: medium. Impact: medium** — losing an in-flight session is exactly the moment a user
stops trusting the app.

**Mitigation.** The session is written to the store at `start`, not at `finish`, so it exists on disk
from second one. `loadActiveSession()` returns the most recent session with `endedAt == nil` and
`elapsed(at:)` recomputes correctly including a pause that was open at quit.
`NSSupportsSuddenTermination` and `NSSupportsAutomaticTermination` are both `false`, and
`AppDelegate.applicationWillTerminate` flushes. Acceptance test: `kill -9` during a session,
relaunch, session restored with elapsed correct to within one second.

---

## 4. The data model

This section is the **single source of truth for every type name, field name and signature** in Lggr.
Later agents copy these declarations verbatim. If an implementation disagrees with this section, this
section wins until it is deliberately amended here.

Field names were cross-checked against `SPEC.md` § *Data model*. Where a name deviates from the spec,
the deviation is called out inline with a reason.

### 4.0 Where each type lives

| Layer | Path | Contents | Compiles today? |
|---|---|---|---|
| Domain | `Sources/LggrKit/Model/` | enums + value structs | ✅ yes |
| Domain | `Sources/LggrKit/Store/` | `LggrStore`, `StoreError`, `StoreSnapshot`, `InMemoryStore`, `JSONFileStore`, `PreferencesStore` | ✅ yes |
| Persistence | `Sources/LggrPersistence/Models/` | `@Model` classes (`SD*`) | ❌ Xcode-only |
| Persistence | `Sources/LggrPersistence/Mapping/` | `toDomain()` / `apply(_:in:)` / `upsert(_:in:)` | ❌ Xcode-only |

`#Predicate` *is* allowed inside `LggrPersistence`, because that target only ever builds under Xcode.

**Why value types reference each other by `UUID`, not by object graph.** Domain relationships are
plain `UUID` fields (`projectID: UUID?`) rather than nested objects because the same value types must
round-trip through JSON, through SwiftData, and into SwiftUI `Equatable` diffing — an object graph
would make them non-`Sendable`, force retain cycles between `FocusSession` and `Project`, and make
every partial update rewrite unrelated records. Object-graph traversal is the *persistence layer's*
job (`SDFocusSession.project`); the domain resolves IDs against already-loaded collections, which is
cheap at this data volume.

### 4.1 Domain enums

All enums are `String`-backed with **explicit** raw values so that a Swift-level rename can never
silently invalidate persisted JSON. All are `Codable`, `CaseIterable`, `Sendable`, and `Identifiable`
(`id == rawValue`) so they drop straight into `Picker(selection:)` and `ForEach`.

`File: Sources/LggrKit/Model/Enums.swift` — one file, appended in each phase.

```swift
import Foundation

// MARK: - WorkType   [P2]

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

// MARK: - SessionResultStatus   [P2]

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
    /// Never rendered in red or with judgmental copy.
    public var needsFollowUp: Bool {
        self == .blocked || self == .interrupted || self == .reprioritized
    }
}

// MARK: - SessionState   [P2]

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

// MARK: - AccomplishmentType   [P2]

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

// MARK: - ActivityCategory   [P3]

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

// MARK: - RuleMatchType   [P3]

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

// MARK: - ClassificationSource   [P3]

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

// MARK: - InterruptionStatus   [P3]

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

// MARK: - InterruptionSource   [P3]

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

// MARK: - OutcomePriority   [P5]

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

// MARK: - OutcomeStatus   [P5]

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
```

### 4.2 Domain value types

All are `Identifiable` (`id: UUID`), `Codable`, `Hashable`, `Sendable`. Explicit `public init`s are
mandatory — a synthesised memberwise initialiser is internal and unusable from `LggrApp`.

`id` and `createdAt` are `let`; everything a user can change is `var`.

#### 4.2.1 Project  [P2]

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

#### 4.2.2 FocusSession  [P2]

`File: Sources/LggrKit/Model/FocusSession.swift` — SPEC: *id, project, weeklyOutcome, intendedOutcome,
workType, plannedDuration, startedAt, endedAt, pausedDuration, resultStatus, resultSummary, blocker,
nextStep, isReactive, interruptionCount*.

**One addition to the spec's field list: `pauseStartedAt: Date?`.** `pausedDuration` alone cannot
represent a pause that is currently *open* — without it, a paused session's clock keeps advancing
until resume. See § 4.3.

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
    /// Sum of all *closed* pause intervals, in seconds. Never negative. See § 4.3.
    public var pausedDuration: TimeInterval
    /// Start of the pause currently in effect, or `nil` when running. See § 4.3.
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

#### 4.2.3 Accomplishment  [P2]

`File: Sources/LggrKit/Model/Accomplishment.swift` — SPEC: *id, project, weeklyOutcome, focusSession,
type, title, details, timestamp*.

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

#### 4.2.4 UserPreferences  [P2]

`File: Sources/LggrKit/Model/UserPreferences.swift` — SPEC: *defaultSessionDuration, globalShortcut,
trackWindowTitles, idleThreshold, excludedApplications, privateApplications, dataRetentionDays,
launchAtLogin, showTimerInMenuBar*. The notification toggles (SPEC § Notifications), the tracking
pause switch (SPEC § 4), `lastSelectedProjectID` (SPEC § 2 "Remember the last selected project") and
the permission-etiquette flags (§ 6.6) are added because they are preference-shaped and have nowhere
else to live. All of them are added **before v1 ships**, so no key migration is required.

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
    /// Preference switch for window-title capture. The *permission* is the gate; this is the
    /// switch. Nothing is captured until Accessibility is granted, so `true` means "work the
    /// moment the user grants it" — it does not mean "capture by default". Do not "fix" it.
    public var trackWindowTitles: Bool
    /// Master switch for browser-domain capture. Defaults to `false`, unlike `trackWindowTitles`,
    /// because the Automation prompt's wording is alarming enough to deserve an explicit yes first.
    public var trackBrowserDomains: Bool
    /// Bundle identifier → the user's intent for that browser, so a declined browser is never
    /// queried again and a browser installed later starts clean.
    public var browserAutomation: [String: Bool]
    /// Seconds of no input before activity is marked `isIdle`.
    public var idleThreshold: TimeInterval
    /// Bundle identifiers that are not tracked at all.
    public var excludedApplications: [String]
    /// Bundle identifiers stored only as "Private activity".
    public var privateApplications: [String]
    /// `nil` = keep forever. Otherwise **activity** older than this many days is purged.
    /// Sessions, accomplishments, interruptions and outcomes are never purged.
    public var dataRetentionDays: Int?
    /// Master switch for the activity tracker. SPEC § 4 "Pause tracking".
    public var trackingPaused: Bool
    /// Last successful retention prune, so the wake trigger can tell 6 hours from 6 minutes.
    public var lastPruneAt: Date?

    // System integration
    public var launchAtLogin: Bool
    public var showTimerInMenuBar: Bool
    public var hideDockIcon: Bool

    // Notifications (SPEC § Notifications)
    public var notifyOnSessionCompleted: Bool
    public var notifyAtHalfway: Bool
    public var notifyOnLongIdle: Bool

    // Permission etiquette — these four fields ARE the re-ask policy of § 6.6.
    // Without persistence, "once, ever" degrades to "once per launch", which is nagging.
    public var didRequestAccessibilityPrompt: Bool
    public var didRequestNotificationAuthorization: Bool
    public var didDismissAccessibilityBanner: Bool
    public var didDismissAutomationBanner: Bool

    // Remembered UI state (SPEC § 2 "Intelligent defaults")
    public var lastSelectedProjectID: UUID?
    /// Set once onboarding has been completed, so it is never shown twice.
    public var hasCompletedOnboarding: Bool

    public init(
        defaultSessionDuration: TimeInterval = 50 * 60,
        globalShortcut: KeyboardShortcutSpec? = .defaultStartSession,
        trackWindowTitles: Bool = true,
        trackBrowserDomains: Bool = false,
        browserAutomation: [String: Bool] = [:],
        idleThreshold: TimeInterval = 5 * 60,
        excludedApplications: [String] = [],
        privateApplications: [String] = [],
        dataRetentionDays: Int? = 90,
        trackingPaused: Bool = false,
        lastPruneAt: Date? = nil,
        launchAtLogin: Bool = false,
        showTimerInMenuBar: Bool = true,
        hideDockIcon: Bool = false,
        notifyOnSessionCompleted: Bool = true,
        notifyAtHalfway: Bool = false,
        notifyOnLongIdle: Bool = true,
        didRequestAccessibilityPrompt: Bool = false,
        didRequestNotificationAuthorization: Bool = false,
        didDismissAccessibilityBanner: Bool = false,
        didDismissAutomationBanner: Bool = false,
        lastSelectedProjectID: UUID? = nil,
        hasCompletedOnboarding: Bool = false
    ) {
        self.defaultSessionDuration = defaultSessionDuration
        self.globalShortcut = globalShortcut
        self.trackWindowTitles = trackWindowTitles
        self.trackBrowserDomains = trackBrowserDomains
        self.browserAutomation = browserAutomation
        self.idleThreshold = idleThreshold
        self.excludedApplications = excludedApplications
        self.privateApplications = privateApplications
        self.dataRetentionDays = dataRetentionDays
        self.trackingPaused = trackingPaused
        self.lastPruneAt = lastPruneAt
        self.launchAtLogin = launchAtLogin
        self.showTimerInMenuBar = showTimerInMenuBar
        self.hideDockIcon = hideDockIcon
        self.notifyOnSessionCompleted = notifyOnSessionCompleted
        self.notifyAtHalfway = notifyAtHalfway
        self.notifyOnLongIdle = notifyOnLongIdle
        self.didRequestAccessibilityPrompt = didRequestAccessibilityPrompt
        self.didRequestNotificationAuthorization = didRequestNotificationAuthorization
        self.didDismissAccessibilityBanner = didDismissAccessibilityBanner
        self.didDismissAutomationBanner = didDismissAutomationBanner
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
> memberwise init and `Codable` will ignore any decoded value for it. That is intended and is
> asserted by `UserPreferencesTests`.

#### 4.2.5 ActivityEvent and ActivitySample  [P3]

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
    /// Browser host, when it can be read safely. Host only — never a path, query or fragment.
    public var domain: String?
    public var category: ActivityCategory
    public let startedAt: Date
    /// `nil` while the interval is still open (this is the frontmost app right now).
    public var endedAt: Date?
    public var isIdle: Bool
    /// The application is on the user's private list. See `redactedIfPrivate` below.
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
    /// Idempotent: a no-op on an already-redacted event and on a non-private one.
    /// Called by the tracker AND re-applied by every store's `saveActivityEvents` (§ 6.7.4).
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

extension ActivityEvent: CustomDebugStringConvertible {
    /// Never prints the title or the domain. Without this, one `print(event)` in a debug session,
    /// or one swift-testing failure message, writes a window title into a log or a CI transcript.
    public var debugDescription: String {
        "ActivityEvent(\(displayName), \(startedAt)–\(endedAt.map(String.init(describing:)) ?? "open"), private: \(isPrivate))"
    }
}
```

`File: Sources/LggrKit/Model/ActivitySample.swift`

```swift
import Foundation

/// Raw, unredacted capture. **Deliberately not `Codable`** — it has no encoder, so it cannot be
/// written to a store, to `UserDefaults`, or to a JSON export. Never persisted, never leaves the
/// tracker. The only sanctioned conversion is `PrivacyRedactor.event(from:preferences:focusSessionID:)`.
public struct ActivitySample: Sendable, Hashable {
    public var applicationName: String
    public var bundleIdentifier: String
    public var windowTitle: String?
    public var domain: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var isIdle: Bool
}
```

#### 4.2.6 Interruption  [P3]

`File: Sources/LggrKit/Model/Interruption.swift` — SPEC: *id, focusSession, description, source,
timestamp, status, convertedProject*.

**Deviation:** the spec's `description` is named **`note`**. A stored property called `description`
on a struct implicitly satisfies `CustomStringConvertible` and shadows the compiler-synthesised
description used by logging and test failure messages — a real trap for later agents. `note` also
matches the UI copy.

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

#### 4.2.7 ClassificationRule  [P3]

`File: Sources/LggrKit/Model/ClassificationRule.swift` — SPEC: *id, matchType, matchValue, category,
project, priority, isEnabled*. `workType` is added as a second optional scope so that SPEC § 5's five
rule inputs are all expressible; `isUserDefined` is added to drive `ClassificationSource` and the
"Reset to defaults" action.

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
    /// False for rules shipped with the app.
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

#### 4.2.8 WeeklyOutcome  [P5]

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

### 4.3 FocusSession timing — the exact pause arithmetic

This is the most bug-prone code in the app. It is deliberately expressed as **pure functions of
stored `Date`s** rather than as a mutable tick counter. There is no `SessionClock` and no
`SessionLifecycle` namespace: two static-function façades over methods that already exist on the
value type would be exactly the "abstraction without two implementations" that § 3.10 forbids.

`File: Sources/LggrKit/Model/FocusSession+Timing.swift`

#### 4.3.1 The model in words

A session occupies wall-clock time from `startedAt` to `endedAt ?? now`. Inside that span there are
zero or more **pause intervals**. `pausedDuration` is the sum of all pause intervals that have been
*closed*; `pauseStartedAt` marks the one pause interval that is still *open*, if any.

```
elapsed(now) = (endedAt ?? now) − startedAt  −  totalPausedDuration(now)

totalPausedDuration(now) = pausedDuration
                         + (pauseStartedAt.map { (endedAt ?? now) − $0 } ?? 0)
```

Every subtraction is clamped at zero, so a backwards clock adjustment can shorten but never invert a
duration.

#### 4.3.2 Behaviour across multiple pause/resume cycles

`pause` opens an interval, `resume` closes it and folds its length into `pausedDuration`. Nothing else
mutates `pausedDuration`. Worked example, 50-minute plan:

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

`endedAt = 10:00`, raw span 60:00, `totalPausedDuration = 900`, `elapsed = 2700 s`. N cycles
accumulate additively. Because `elapsed` is recomputed from dates, a dropped timer tick, an app
relaunch, or a display-sleep gap cannot drift the number.

#### 4.3.3 Invariants

1. `pausedDuration >= 0` always.
2. `pauseStartedAt != nil` ⟹ the session is paused ⟹ `elapsed(at:)` is constant over `now`.
3. A finished session (`endedAt != nil`) has `pauseStartedAt == nil` — `finish` closes any open pause
   first. The computed properties still behave correctly if a corrupt record violates this, by
   closing the pause at `endedAt`.
4. For a finished session, `elapsed(at:)` returns the same value for every `now`.
5. `elapsed` is non-decreasing in `now` while running, and never exceeds `(endedAt ?? now) − startedAt`.
6. `elapsed` is **not** "focused time". Focused time is aggregated from `ActivityEvent`s (idle and
   category aware); `elapsed` is only the session clock. Machine sleep therefore inflates `elapsed`
   and does *not* inflate focused time — that difference is exactly the "idle time" reported on the
   completion sheet.
7. The UI never increments a counter. A 1 Hz `Timer` simply re-renders `elapsed(at: Date())`.

#### 4.3.4 Code

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

#### 4.3.5 Edge cases and the expected result

| Case | Result |
|---|---|
| `pause` twice in a row | second call is a no-op; one open interval |
| `resume` without a pause | no-op |
| `finish` while paused | pause closed at the finish instant, then `endedAt` set |
| `finish` twice | second call is a no-op; `endedAt` never moves |
| `resume` with `date < pauseStartedAt` (clock moved back) | adds `0`, pause closes |
| `finish` with `date < startedAt` | `endedAt = startedAt`, `elapsed == 0` |
| Machine sleeps 30 min mid-session | `elapsed` grows by 30 min; focused time (from activity events) does not; the delta shows as idle |
| App relaunches mid-session | `LggrStore.loadActiveSession()` restores it; `elapsed` recomputes exactly, including a pause that was open at quit |
| Open-ended session | `remaining` and `progress` are `nil`; `overrun` is `0` |

### 4.4 The store protocol

#### 4.4.1 `LggrStore`

> **One protocol, `LggrStore`, covering all seven aggregates**, because Lggr only ever has one live
> backend (`JSONFileStore` today, `SwiftDataStore` under Xcode) plus one shared `InMemoryStore` fake
> — splitting it into seven repositories would multiply types that are never composed independently,
> while the single shared fake already makes every aggregate testable in isolation.

The protocol is **`@MainActor` + `AnyObject`** (SwiftData's `ModelContext` is main-actor bound and the
app-level state objects own the store) and every method is `async throws`, so `JSONFileStore` can hop
to a `nonisolated` helper for encoding and the atomic write without changing any call site.

`LggrApp` never touches `LggrStore` from a presentational view. `@Observable` state objects
(`TodayModel`, `ProjectsModel`, …) sit on top of it and are reached through `AppEnvironment`.

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
///
/// The `[Pn]` markers stay in the source file so it is obvious which methods a phase must
/// implement in every conformer. In Phase 2 the later-phase methods are comments, not declarations.
@MainActor
public protocol LggrStore: AnyObject {

    // MARK: Projects   [P2]
    func loadProjects() async throws -> [Project]
    func saveProject(_ project: Project) async throws
    /// Never cascades. Sessions, accomplishments, rules and interruptions that referenced the
    /// project keep their history and have their `projectID` cleared.
    func deleteProject(id: UUID) async throws

    // MARK: Focus sessions   [P2]
    /// Sessions whose `startedAt` falls inside `interval`, newest first.
    func loadSessions(in interval: DateInterval) async throws -> [FocusSession]
    func loadSession(id: UUID) async throws -> FocusSession?
    /// The most recent session with `endedAt == nil`. Used for crash / relaunch recovery.
    func loadActiveSession() async throws -> FocusSession?
    func saveSession(_ session: FocusSession) async throws
    /// The only cascade in the model: this also deletes the session's `ActivityEvent`s.
    func deleteSession(id: UUID) async throws

    // MARK: Accomplishments   [P2]
    func loadAccomplishments(in interval: DateInterval) async throws -> [Accomplishment]
    func saveAccomplishment(_ accomplishment: Accomplishment) async throws
    func deleteAccomplishment(id: UUID) async throws

    // MARK: Lifecycle   [P2]
    /// Forces any coalesced writes to disk. Called from `applicationWillTerminate` and by tests.
    func flush() async throws

    // MARK: Activity   [P3]
    func loadActivityEvents(in interval: DateInterval) async throws -> [ActivityEvent]
    func loadActivityEvents(sessionID: UUID) async throws -> [ActivityEvent]
    /// Batched: the tracker flushes closed intervals in bursts.
    /// Every conformer re-applies `redactedIfPrivate()` on entry (§ 6.7.4).
    func saveActivityEvents(_ events: [ActivityEvent]) async throws
    /// Retention policy enforcement. SPEC § 4 "Define retention duration".
    func deleteActivityEvents(startedBefore date: Date) async throws
    /// SPEC § 4 "Delete activity history". Removes every `ActivityEvent` and nothing else.
    func deleteAllActivityEvents() async throws

    // MARK: Interruptions   [P3]
    func loadInterruptions(in interval: DateInterval) async throws -> [Interruption]
    func loadInterruptions(status: InterruptionStatus) async throws -> [Interruption]
    func saveInterruption(_ interruption: Interruption) async throws
    func deleteInterruption(id: UUID) async throws

    // MARK: Classification rules   [P3]
    func loadClassificationRules() async throws -> [ClassificationRule]
    func saveClassificationRule(_ rule: ClassificationRule) async throws
    func deleteClassificationRule(id: UUID) async throws

    // MARK: Scoped activity deletion   [P4]
    /// "Delete this day's activity" — § 6.8.4c.
    func deleteActivityEvents(in interval: DateInterval) async throws
    /// "Delete activity for this session, keep the session" — § 6.8.4b.
    func deleteActivityEvents(sessionID: UUID) async throws

    // MARK: Weekly outcomes   [P5]
    func loadWeeklyOutcomes(weekStarting: Date) async throws -> [WeeklyOutcome]
    func loadWeeklyOutcomes(in interval: DateInterval) async throws -> [WeeklyOutcome]
    func saveWeeklyOutcome(_ outcome: WeeklyOutcome) async throws
    func deleteWeeklyOutcome(id: UUID) async throws
}
```

**Conformers**

| Type | Target | Notes |
|---|---|---|
| `JSONFileStore` | `LggrKit` | Default. Holds one `StoreSnapshot` in memory; every `save…` mutates it, marks it dirty and schedules a coalesced flush 500 ms later. `flush()` awaits a `nonisolated` encode + `AtomicFileWriter.write` to `~/Library/Application Support/Lggr/store.json`. Missing file → empty snapshot, not an error. Corrupt file → `StoreError.invalidData`, and the bad file is left untouched on disk. |
| `InMemoryStore` | `LggrKit` | The fake. Backs unit tests and `PreviewFixtures`. Optional `var failureToInject: StoreError?` thrown by every method when set, to exercise error paths. |
| `SwiftDataStore` | `LggrPersistence` | Xcode-only. Wraps a `ModelContainer`; maps `SD*` ⇄ domain values. |

**On-disk layout: a single `store.json`** holding one `StoreSnapshot` root with an explicit
`schemaVersion: Int`. Decoding a snapshot with a *higher* version throws `StoreError.invalidData`
naming both versions rather than partially decoding; a lower or equal version decodes. Under Xcode
with `LGGR_SWIFTDATA=1`, `SwiftDataStore` replaces `store.json` with a SQLite store in the same
directory — the directory, its permissions and every delete operation in § 6.8 are identical either
way.

`UserPreferences` is deliberately **not** in this protocol.

#### 4.4.2 `PreferencesStoring`

**`UserPreferences` lives in `UserDefaults`, not in the store.** Reasons, in order of weight:

1. **It is needed before the store exists.** `launchAtLogin`, `showTimerInMenuBar`, `hideDockIcon`
   and `globalShortcut` are read during `applicationDidFinishLaunching`, before and independently of
   any store being opened. A store failure must not cost the user their hot key or their privacy
   settings.
2. **A single-row entity is a liability.** Every read needs "fetch first, insert if missing", every
   write needs duplicate-row defence, and migrations for a settings blob buy nothing.
3. **`UserDefaults` is the platform-native home for settings** — it is what `@AppStorage`, the
   Settings scene, and `defaults delete com.luisdoriz.lggr` all expect.
4. It keeps `LggrStore` about work history only.

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

`InMemoryPreferencesStore` (a two-line class holding a `var preferences`) is the test and gallery
fake.

> **Forward warning.** `Codable` synthesis on an optional-or-defaulted property still requires the
> key to be present, so **every `UserPreferences` field added after v1 ships needs an explicit
> `decodeIfPresent` path, or a bump of `storageKey` to `v2`.** Every field in § 4.2.4 is added
> before v1 ships, so no migration is required today.

### 4.5 SwiftData `@Model` classes

`Sources/LggrPersistence/` only. Xcode-only; never imported into `LggrKit` or `LggrApp` except
through `App/StoreBootstrap.swift`'s single `#if LGGR_SWIFTDATA`.

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

    /// NULLIFY: deleting a project must never destroy work history.
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

#### 4.5.1 Delete rules at a glance

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

`SwiftDataStore.deleteProject(id:)` calls `context.delete(project)` and relies on the nullify rules —
it must **not** loop over `sessions` deleting them. `JSONFileStore` and `InMemoryStore` must
reproduce the same behaviour explicitly (clear `projectID` on every referencing record) so the
backends are observationally identical. That equivalence is a contract test.

#### 4.5.2 Schema registration

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

### 4.6 Mapping strategy

**Direction of truth: domain value types are authoritative.** `@Model` classes are a storage detail
and expose no behaviour — every computed property, every duration, every rule match lives on the
value type in `LggrKit` and is unit-tested today.

Two functions per entity, both in `Sources/LggrPersistence/Mapping/SD<Entity>+Mapping.swift`:

- `func toDomain() -> T` — reads relationship objects and projects them down to `UUID`s.
- `func apply(_ value: T, in context: ModelContext) throws` — writes scalars and resolves each
  `UUID?` back to a managed object.

`id` is never rewritten by `apply` after insert; it is set once by the initialiser.

**Worked example — `SDFocusSession`.** Every `save…` method in `SwiftDataStore` follows this shape.

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

    /// Insert-or-update by `id`.
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
guarantee is asserted for `JSONFileStore` and `InMemoryStore`, so all three backends are
interchangeable. That is the shared `LggrStoreContractTests` suite, run against every available
backend (`SwiftDataStore` only when `LGGR_SWIFTDATA=1`). `SwiftDataStore.flush()` is
`try context.save()`.

### 4.7 Consistency checklist for later agents

- Field names come from this section, not from memory. The two intentional deviations from `SPEC.md`
  are `Interruption.note` (spec: `description`) and the added `FocusSession.pauseStartedAt`.
- Relationships in the domain are `UUID`s; only `SD*` classes hold object references.
- Never call `elapsed(at: Date())` inside an aggregate — use `effectiveDuration`, which is defined
  only for finished sessions.
- Never mutate `FocusSession.pausedDuration` outside `resume(at:)`.
- Never re-classify an `ActivityEvent` whose `classificationSource == .manual`.
- Never write a private application's title or bundle ID to a store: `PrivacyRedactor` at capture
  time, `redactedIfPrivate()` again at the write boundary.
- Deleting a `Project` nullifies; only `FocusSession → ActivityEvent` cascades.
- `@Model`, `#Predicate`, `#Preview` appear in `Sources/LggrPersistence/` and the excluded
  `_XcodeOnly/`, and nowhere else.
- Every timing function takes its `Date` as a parameter. No `Date()` inside `FocusSession+Timing.swift`.

---

## 5. The main screens and navigation

Written so an engineer can build from it without inventing anything. Where a number is given, it is
the number. Where copy is quoted, it is the string.

### 5.0 The feeling we are building for

| Reference | What we take |
|---|---|
| **Things** | Generous whitespace, one obvious action per screen, empty states that read like a person wrote them. |
| **Raycast** | The sub-five-second path: one keystroke, type, Return. No mouse anywhere in the critical flow. |
| **Linear** | Restraint in colour and chrome. Data is dense but never loud. Hairlines, not boxes. |
| **Craft** | Typography carries the hierarchy, not borders and not cards. |

And the thing none of them do, which is our whole product: **the app makes a claim about your day and
lets you correct it.** Every screen is evidence, never a score.

Three rules that resolve most detail arguments before they start:

1. **Space before lines, lines before boxes, boxes before colour.** Reach for 32pt of air first; a
   `Divider()` second; a card third; a tinted surface last and almost never.
2. **Colour means "which project", or it means nothing.** The only colour with semantic weight in the
   whole app is the project colour, and it is never the only carrier of that meaning.
3. **Nothing moves that the user did not move.** No pulsing, no shimmer, no attention-seeking.
   Numbers change; the layout holds still.

### 5.1 The navigation shell

#### 5.1.1 Scene graph

Three scenes, plus one dev-only window:

```
MenuBarExtra  ─ MenuBarContentView   ─ .menuBarExtraStyle(.window), 320pt wide
Window "Lggr" ─ RootWindow           ─ id: WindowID.main, default 1040 × 720
Settings      ─ SettingsView         ─ the same view the sidebar's Settings row renders
Window        ─ PreviewGallery       ─ only when LGGR_GALLERY=1
```

`RootWindow` is a two-column `NavigationSplitView`:

```swift
// Views/Root/RootWindow.swift
NavigationSplitView(columnVisibility: $app.columnVisibility) {
    Sidebar(selection: $app.section)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
} detail: {
    NavigationStack(path: $app.detailPath) {
        DetailContent(section: app.section)
    }
    .frame(minWidth: 640)
}
.navigationSplitViewStyle(.balanced)
```

The detail column owns a `NavigationStack` so Focus Sessions and Accomplishments can push a detail
view without a third column. A three-column split would leave the middle column empty on five of the
seven sections; two columns plus push is the calmer shape.

Window frame is persisted automatically by SwiftUI per scene `id`. Sidebar selection persists in
`UserDefaults` under `com.lggr.sidebar.section` via `AppModel`. **Sheet routing lives in `AppModel`,
not in views** — no view owns `@State private var showingXSheet`.

#### 5.1.2 Sidebar sections

`File: Views/Root/SidebarSection.swift`

```swift
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case today, sessions, accomplishments, weeklyReview, projects, rules, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today:           return "Today"
        case .sessions:        return "Focus Sessions"
        case .accomplishments: return "Accomplishments"
        case .weeklyReview:    return "Weekly Review"
        case .projects:        return "Projects"
        case .rules:           return "Rules"
        case .settings:        return "Settings"
        }
    }

    public var symbolName: String {
        switch self {
        case .today:           return "sun.max"
        case .sessions:        return "timer"
        case .accomplishments: return "checkmark.seal"
        case .weeklyReview:    return "chart.bar.xaxis"
        case .projects:        return "folder"
        case .rules:           return "slider.horizontal.3"
        case .settings:        return "gearshape"
        }
    }

    /// ⌘1 … ⌘7, in declaration order. The numbering never changes as later phases land.
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    /// Sections whose real content exists in the Phase 2 build.
    public var isAvailableInPhase2: Bool {
        self == .today || self == .projects || self == .settings
    }
}
```

**The shortcut map is therefore fixed for the life of the project:** ⌘1 Today · ⌘2 Focus Sessions ·
⌘3 Accomplishments · ⌘4 Weekly Review · ⌘5 Projects · ⌘6 Rules · ⌘7 Settings.

All seven symbols exist in SF Symbols 4 and render on macOS 14.

**Symbols stay in their outline variant, always.** The obvious Apple move is `.symbolVariant(.fill)`
on the selected row, but `timer` and `slider.horizontal.3` have no `.fill` variant, so selection
would change the shape of five rows and not two. Selection is carried entirely by the system
highlight. This is a real constraint, not a preference.

Sidebar row anatomy:

```
│  ⟨18pt symbol⟩  Today                    ● │
   └ 8pt gap ┘                      running dot
```

- Row height: system default for `.listStyle(.sidebar)`. Do not set a custom height.
- Symbol frame `width: 18, alignment: .center` so the labels align even though the glyphs differ.
- **No per-section tint.** A seven-colour sidebar is the fastest way to look like enterprise software.
- **Running indicator:** when `sessionManager.active != nil`, the *Today* row shows a trailing 6pt
  filled circle in `Color.accentColor`. It does not pulse, does not animate in, and does not show a
  countdown. The live number lives in two places only — the menu bar and Today itself. A sidebar
  that reprints itself every second is the opposite of calm.
- Section grouping: one flat list, no `Section` headers. Seven items do not need headings.
- **Sections that do not exist yet render an honest `EmptyStateView` naming the phase they arrive
  in** ("Weekly review arrives in Phase 5"), never a dead control. Hiding rows until their phase
  would renumber the ⌘-shortcuts three times over the project; stability wins.

`Settings` appears in the sidebar (required by `SPEC.md` § Navigation) **and** as a `Settings` scene
(⌘,). Both render the **same** `SettingsView` with `.formStyle(.grouped)`. One view, two hosts, zero
duplicated code.

#### 5.1.3 Behaviour when the main window is closed

| Event | Behaviour |
|---|---|
| ⌘W / clicking the close button | Window closes. **The app does not quit.** `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`. |
| A session is running | The `TickTimer` keeps running, the menu bar label keeps counting, activity tracking continues. Nothing about the session is coupled to a window. |
| Global shortcut ⌘⇧Space *(P6)* | Activates the app, opens the menu bar popover, and shows the **start panel inline in the popover** — the main window is *not* opened. Starting a session never forces a window at you. |
| ⌘N, ⌘⇧A, ⌘⇧I, ⌘1–⌘7 | Still work. `LSUIElement` is `false`, so the application menu bar survives with zero windows open. ⌘1–⌘7 open the window if it is closed, then select the section. |
| Clicking the Dock icon | `applicationShouldHandleReopen(_:hasVisibleWindows:)` calls `openWindow(id: WindowID.main)`. |
| Any "Open …" row in the popover | `openWindow(id: WindowID.main)`, then `NSApp.activate(ignoringOtherApps: true)`, then sets `app.section`. |
| A session finishes while the window is closed | **We do not force the window open.** The session enters `.awaitingReview`, the menu bar symbol becomes `questionmark.circle`, and the popover's top row becomes `Review last session`. The completion notification's default action opens the window with `SessionReviewSheet` presented. |
| Notifications | Delivered normally; `UNUserNotificationCenter` does not care about windows. |
| App quits with a session running | No confirmation dialog. On next launch `store.loadActiveSession()` restores it and `elapsed(at:)` recomputes exactly (§ 4.3.5). |

Phase 6 adds a **Hide Dock icon** preference which calls `NSApp.setActivationPolicy(.accessory)`.
That loses the application menu bar, so when it is enabled the popover grows a `Preferences…` row and
a `Quit Lggr` row, and the keyboard map degrades to popover-scoped shortcuts. This is documented in
the preference's help text, not discovered.

### 5.2 Design tokens

Five files in `Sources/LggrApp/DesignSystem/`: `Typography.swift`, `Theme.swift`, `Palette.swift`,
`Motion.swift`, `Iconography.swift`.

#### 5.2.0 The constraint that shapes all of this

`Lggr.app` is assembled by hand from `Scripts/make-app.sh`. **There is no asset catalog**, so there
is no `Color("CardBackground")` and no light/dark colour pair defined in Xcode. Every adaptive colour
must be constructed in code:

```swift
// DesignSystem/Palette.swift
import AppKit
import SwiftUI

extension NSColor {
    /// The only way to get a light/dark pair without an asset catalog.
    static func lggrDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
```

Everywhere else, prefer a **system semantic colour** (`.windowBackgroundColor`, `.separatorColor`,
`Color.primary`, `.secondary`, `Color.accentColor`) over a literal. A system colour is already correct
in light mode, dark mode, increased contrast, and under vibrancy. Hand-rolled greys are not. **No
hard-coded hex outside `Palette.swift`**, and there only inside `lggrDynamic`.

#### 5.2.1 Type ramp

`File: DesignSystem/Typography.swift`. Built from text styles so Dynamic Type works, with exactly
**one** hard-coded size in the entire app.

| Token | SwiftUI value | pt (macOS default) | Role |
|---|---|---|---|
| `Type.timerHero` | `.system(size: timerSize, weight: .medium, design: .rounded).monospacedDigit()` | 72, `@ScaledMetric(relativeTo: .largeTitle)` | The one dominant number: active session timer in the main window. Nowhere else. |
| `Type.screenTitle` | `.largeTitle.weight(.semibold)` | 26 | The detail column header — "Today", "Weekly Review". One per screen. |
| `Type.outcome` | `.title2.weight(.medium)` | 17 | The intended outcome. The second-most important text in the app; it sits directly under the timer and never truncates. |
| `Type.timerCompact` | `.title.weight(.medium).monospacedDigit()` | 22 | Timer inside the menu bar popover and the review sheet header. |
| `Type.sectionTitle` | `.title3.weight(.semibold)` | 15 | "Accomplishments", "Time allocation", "Day". |
| `Type.metricValue` | `.title2.weight(.medium).monospacedDigit()` | 17 | The number in a `MetricTile`. |
| `Type.rowTitle` | `.headline` | 13 semibold | Session titles, project names, accomplishment titles, rule descriptions. |
| `Type.body` | `.body` | 13 | Body copy, summary editor, form field contents, empty-state second line. |
| `Type.secondary` | `.subheadline` | 11 | Metadata: project name, time ranges, application lists, metric captions. |
| `Type.caption` | `.caption` | 10 | Timeline axis labels, keyboard hints, "built-in rule" tags. Nothing a user *must* read is set at this size. |
| `Type.menuBarTimer` | `.system(size: 12, weight: .regular, design: .rounded).monospacedDigit()` | 12 | The menu bar label only. Never inside a window. |
| `Type.mono` | `.system(.body, design: .monospaced)` | 13 | Markdown export preview. |

Rules:

- `.rounded` design is used for **numerals under a clock only** (`timerHero`, `menuBarTimer`). It
  makes a timer feel like an instrument rather than a spreadsheet. Everything else is the system face.
- `.monospacedDigit()` is mandatory on every number that changes over time. This is what stops the
  menu bar and the hero timer from jittering horizontally once per second.
- Weight is never used to create a fifth hierarchy level. Four levels — hero / title / row / body —
  plus `.secondary` foreground for everything demoted.
- No letter-spacing, no all-caps section headers, no small-caps. Uppercase tracked-out labels are the
  visual signature of the enterprise dashboard we are refusing to build.

#### 5.2.2 Spacing scale

4pt base. Eight steps, named, and that is the complete set.

```swift
// DesignSystem/Theme.swift
public enum Space {
    public static let xxs: CGFloat = 2    // symbol-to-text inside a badge
    public static let xs:  CGFloat = 4    // menu bar symbol → digits
    public static let s:   CGFloat = 8    // icon → label; chip padding
    public static let m:   CGFloat = 12   // between sibling cards; list row vertical padding
    public static let l:   CGFloat = 16   // card interior padding; form row spacing
    public static let xl:  CGFloat = 24   // detail column horizontal inset
    public static let xxl: CGFloat = 32   // between major sections on a screen
    public static let hero:CGFloat = 48   // above/below the hero timer; empty-state breathing room
}
```

| Situation | Value |
|---|---|
| Detail column leading/trailing inset | `Space.xl` (24) |
| Detail column top inset (below the title) | `Space.xl` (24) |
| Between two major sections | `Space.xxl` (32) |
| Section title → its first row | `Space.m` (12) |
| Card interior padding | `Space.l` (16) |
| List row vertical padding | `Space.m` (12) top and bottom |
| Icon → label in a row | `Space.s` (8) |
| Sheet interior padding | `Space.xl` (24) |
| Popover interior padding | `Space.m` (12) |
| Between the hero timer and the outcome | `Space.l` (16) |
| Above/below the hero timer block | `Space.hero` (48) |

Nothing uses a value that is not in this list. If a layout wants 18pt, it wants 16 or 20 and the
designer was guessing.

#### 5.2.3 Corner radii

```swift
public enum Radius {
    public static let chip:  CGFloat = 6    // duration segments, source chips, project badges
    public static let card:  CGFloat = 10   // cards, list rows with a hover fill, text fields
    public static let panel: CGFloat = 14   // sheets' inner panels, the popover's session block
}
```

Always `RoundedRectangle(cornerRadius:style: .continuous)`. Never the default `.circular` style —
continuous corners are what every native macOS surface uses and the difference is visible at 10pt.
`Capsule()` is used for exactly one thing: the progress ring's linear variant in the popover.

#### 5.2.4 Semantic colour roles

```swift
// DesignSystem/Palette.swift
public enum Surface {
    /// The detail column background. Sidebar background is left to the system.
    public static let canvas = Color(nsColor: .windowBackgroundColor)

    /// A raised card sitting on `canvas`. Lighter than the canvas in both modes.
    public static let raised = Color(nsColor: .lggrDynamic(
        light: .white,
        dark:  NSColor(white: 1.0, alpha: 0.055)   // composites over the dark window background
    ))

    /// A recessed well: text fields, the summary editor.
    public static let sunken = Color(nsColor: .controlBackgroundColor)

    /// Row hover. Also the pressed state at 1.5×.
    public static let hover = Color.primary.opacity(0.06)

    /// A selected, non-focused row (the focused one uses the system selection colour).
    public static let selected = Color.accentColor.opacity(0.14)
}

public enum Stroke {
    /// Structural separators. Always the system value; never a hand-mixed grey.
    public static let separator = Color(nsColor: .separatorColor)

    /// The hairline around a card.
    public static let card = Color(nsColor: .lggrDynamic(
        light: NSColor(white: 0.0, alpha: 0.07),
        dark:  NSColor(white: 1.0, alpha: 0.10)
    ))
}

public enum Palette {
    /// Overtime digits, and the "at risk" outcome status glyph. Nothing else.
    /// Never used as a fill, never as a background, never on more than ~20 characters at a time.
    public static let attention = Color(nsColor: .systemOrange)

    /// Destructive confirmation buttons only. There is no red anywhere else in Lggr.
    public static let destructive = Color(nsColor: .systemRed)
}
```

**Text** uses only `.primary`, `.secondary`, `.tertiary`. `.quaternary` is permitted for *shapes* (an
empty progress track) and forbidden for text.

**Accent** is `Color.accentColor` — the user's system accent, never a hardcoded blue. If the user's
Mac is set to Graphite, Lggr is graphite. That is a native app behaving natively.

**Red appears in exactly one place: the confirm button of a delete alert.** Not on blocked sessions,
not on distraction time, not on missed outcomes. The spec asks for this explicitly and it is the
easiest principle to violate by accident.

#### 5.2.5 Project colours

`Project.colorID` is a `String` token from `Project.colorIDs`. The app maps it to a system colour so
the palette is already correct in light mode, dark mode and under increased contrast:

```swift
public extension Palette {
    static func project(_ colorID: String) -> Color {
        switch colorID {
        case "blue":     return .blue
        case "purple":   return .purple
        case "pink":     return .pink
        case "red":      return .red
        case "orange":   return .orange
        case "yellow":   return .yellow
        case "green":    return .green
        case "teal":     return .teal
        case "graphite": return Color(nsColor: .systemGray)
        default:         return .blue          // unknown token from a future version
        }
    }
}
```

**Where a project colour may appear — the complete list:**

1. An 8pt filled circle immediately before a project name (`ProjectBadge`), with a
   `Color.primary.opacity(0.15)` 0.5pt inner stroke so yellow survives on white.
2. A 3pt full-height leading bar on a day-timeline block.
3. The tint of the project's own SF Symbol in `ProjectsView` and the project editor.
4. A segment fill in the Weekly Review's time-allocation bar, separated from its neighbours by a 1pt
   `Surface.canvas` gap.
5. The 9-swatch picker in the project editor (28pt circles, checkmark on the selected one).

**Where it may not appear:** as a card background, as text colour, as a border on anything other than
(2), in a gradient, or as the only signal of which project a row belongs to. Every project dot is
followed by the project's name, so colour blindness costs nothing.

#### 5.2.6 Materials

`.regularMaterial` and friends only where something genuinely floats. Three uses in the whole app:

| Surface | Material | Why |
|---|---|---|
| Menu bar popover background | System default for `.menuBarExtraStyle(.window)` | Do not override it. macOS gives the popover the correct vibrancy for the menu bar; anything we set fights it. |
| The "session running" strip pinned to the bottom of the detail column when a session runs and you are not on Today | `.thinMaterial` + a top `Divider()` | It overlaps scrolling content, so it must read as floating. |
| Sidebar background | System default via `.listStyle(.sidebar)` | Never set a background on a `NavigationSplitView` sidebar. |

Sheets get the system sheet background (opaque). Material over an opaque window is a grey rectangle
pretending to be interesting.

Under **Reduce transparency** the `.thinMaterial` strip becomes `Surface.raised`:

```swift
.background(reduceTransparency ? AnyShapeStyle(Surface.raised) : AnyShapeStyle(.thinMaterial))
```

#### 5.2.7 Separators

In priority order — reach for the first that works:

1. **32pt of space** (`Space.xxl`) between sections. This is the default answer.
2. **A `Divider()`** when two lists of equal weight abut with no heading between them, and at the top
   edge of the floating session strip.
3. **List row separators**: `.listRowSeparator(.visible)`, `.listRowSeparatorTint(Stroke.separator)`,
   and the leading inset aligned to the *text* column, not the row edge — 44pt when the row has a
   leading icon, `Space.l` when it does not.
4. **A card hairline**: `.strokeBorder(Stroke.card, lineWidth: 1)` drawn on the *same*
   `RoundedRectangle(cornerRadius: Radius.card, style: .continuous)` used for the fill, so the stroke
   is crisp instead of blurred by a half-pixel mismatch.

Never a 2pt rule, never a coloured rule, never a separator inside a card.

Under **Increase contrast** (`NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`):
`Stroke.card` opacity goes 0.07 → 0.22 (light) and 0.10 → 0.28 (dark); `Surface.hover` goes
0.06 → 0.12; the timeline's idle blocks go from 40% to 65% opacity.

#### 5.2.8 Motion vocabulary

Five named animations. There is no sixth.

```swift
// DesignSystem/Motion.swift
public enum Motion {
    /// Hover, press, focus ring. Must feel like the control is already there.
    public static let tap    = Animation.easeOut(duration: 0.12)
    /// Cross-fades, selection moves, count changes, section collapse.
    public static let settle = Animation.easeInOut(duration: 0.22)
    /// Something appearing: a disclosure opening, a row inserting, panel content swapping.
    public static let reveal = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// The progress ring advancing one tick. Linear so a second looks like a second.
    public static let ring   = Animation.linear(duration: 1.0)
    /// Explicitly no animation. Used on the timer digits.
    public static let none: Animation? = nil
}
```

Reduce-motion is handled in one place, not at every call site:

```swift
public extension View {
    /// `.lggrAnimation(.reveal, value: isExpanded)`
    func lggrAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(LggrAnimationModifier(animation: animation, value: value))
    }
}

private struct LggrAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.1) : animation, value: value)
    }
}
```

Fixed rules:

- **The timer never animates its layout.** Digits use `.contentTransition(.numericText(countsDown: true))`
  on the hero timer only, and `Motion.none` for everything else about it. The menu bar label uses no
  content transition at all — it redraws once per second and a transition there is a battery cost
  with no benefit.
- Nothing scales. No `.scaleEffect` on press; buttons change fill, not size.
- Nothing repeats. **`.repeatForever` does not appear in the codebase.** That single rule eliminates
  pulsing dots, breathing rings and shimmer placeholders.
- Sheet and popover presentation animation is the system's. We do not customise it.

#### 5.2.9 Light and dark

- **System semantic colours** adapt with zero code. This covers roughly 90% of the surface area.
- **The two hand-made colours** (`Surface.raised`, `Stroke.card`) go through
  `NSColor.lggrDynamic(light:dark:)`. They are the only two, deliberately.
- **Project colours** are the SwiftUI system colours, which are already the adaptive `systemBlue`
  family.
- **SF Symbols** are template images tinted by `.foregroundStyle`, so they follow text.
- **Materials** adapt themselves.

Verification loop on a machine with no Xcode: `LGGR_GALLERY=1 make run`. **Every new view is added to
the gallery in the same commit that adds the view.** That is the light/dark test, and it is a real
running window, not a promise.

Two dark-mode traps handled explicitly:

1. A white card on a dark canvas is a flashlight. `Surface.raised` in dark mode is a 5.5% white
   overlay — *slightly* lighter than the window, not brighter than the text around it.
2. Yellow and orange project dots vanish on a light canvas. The 0.5pt `Color.primary.opacity(0.15)`
   inner stroke on every project dot fixes this in one place.

#### 5.2.10 Iconography

`File: DesignSystem/Iconography.swift`. Every SF Symbol name used by `LggrApp` that is not already
supplied by a domain enum lives here as a `static let`. Domain symbols come from the enums in § 4.1
(`WorkType.symbolName`, `SessionResultStatus.symbolName`, `ActivityCategory.symbolName`,
`AccomplishmentType.symbolName`, `InterruptionSource.symbolName`, `SessionState.symbolName`) and are
**never re-declared** in the app target. `Image(systemName:)` never takes a literal outside this file.

```swift
public enum Icon {
    public static let startSession   = "play.circle"
    public static let quickTimer     = "bolt"
    public static let pause          = "pause.fill"
    public static let resume         = "play.fill"
    public static let finish         = "checkmark"
    public static let interruption   = "bell.badge"
    public static let addAccomplishment = "plus.circle"
    public static let export         = "square.and.arrow.up"
    public static let regenerate     = "arrow.clockwise"
    public static let more           = "ellipsis.circle"
    public static let search         = "magnifyingglass"
    public static let previousWeek   = "chevron.left"
    public static let nextWeek       = "chevron.right"
    public static let inbox          = "tray"
    public static let privacy        = "hand.raised"
    public static let accessibility  = "accessibility"
    public static let emptyToday     = "sun.max"
    public static let emptySessions  = "timer"
    public static let emptyDone      = "checkmark.seal"
    public static let emptyWeek      = "chart.bar.xaxis"
    public static let emptyProjects  = "folder"
    public static let emptyRules     = "slider.horizontal.3"
    public static let error          = "exclamationmark.triangle"
}
```

Symbols in body text use `.imageScale(.medium)` and inherit `.foregroundStyle`. Toolbar symbols use
the system default. Symbols never get a coloured circular background — no "icon chips".

### 5.3 Shared components and shared policy

`Sources/LggrApp/Components/`:

```swift
Card(padding:)                  // Surface.raised + Radius.card + Stroke.card hairline
SectionHeader(title:action:)    // Type.sectionTitle + optional trailing borderless button
EmptyStateView(symbol:title:message:action:)
PrimaryButtonStyle              // accent fill, Radius.chip, ⌘⏎ hint rendered inline at .caption
ProjectBadge(project:)          // 8pt dot + name, Type.secondary
ErrorBanner(message:actions:)   // § 5.3.3
MetricTile(value:label:)        // [P4] Type.metricValue over Type.secondary,
                                //      .accessibilityElement(children: .combine)
```

#### 5.3.1 Empty-state anatomy — the shape every screen reuses

```
        ⟨28pt SF Symbol, .tertiary⟩

           Title sentence          ← Type.rowTitle, .primary
    One calm line of explanation.  ← Type.body, .secondary, max 2 lines
        [ Primary action ⌘X ]      ← only when there is one obvious next step
```

Centred in the available space, `Space.hero` of air above and below, max text width 340pt. **No
illustrations.** One symbol, two lines, at most one button. Copy is warm, brief, factual, and never
implies the user has failed to do something.

#### 5.3.2 Loading policy — one rule for the whole app

The store is a local JSON file or a local SwiftData container; reads are measured in milliseconds.
Therefore:

1. **The chrome renders immediately.** Screen title, section headers and toolbar are never gated on
   data.
2. For the first **250 ms** a section renders its normal layout with fixture-shaped content and
   `.redacted(reason: .placeholder)`. This keeps the layout from jumping when data lands.
3. After 250 ms, and only then, a section may show a small centred `ProgressView().controlSize(.small)`.
4. **There is no full-screen spinner anywhere in Lggr**, and no skeleton shimmer (it would need
   `.repeatForever`, which is banned by § 5.2.8).

#### 5.3.3 Error policy — one rule for the whole app

Errors from `LggrStore` surface as an inline `ErrorBanner` at the top of the detail column, inside the
content inset, above everything else:

```
┌──────────────────────────────────────────────────────────────┐
│ ⚠  Couldn't load today. Your work is still on disk.          │
│    [ Try again ]   [ Show in Finder ]                        │
└──────────────────────────────────────────────────────────────┘
```

- Symbol `Icon.error` in `.secondary`, **not** red. `Stroke.card` hairline, `Surface.raised` fill.
- One sentence. It says what failed and reassures about data, in that order.
- Always at least one recovery action.
- The banner is dismissible (⌘. or a trailing `xmark` on hover) and returns on the next failure.
- `StoreError.persistenceFailure` while *saving* is the only case that gets an `Alert`, because the
  user is about to lose input.
- Alerts are used **only** for (a) unsaveable input and (b) destructive confirmation. Everything else
  is a banner.

### 5.4 The seven sidebar screens

Each block gives: primary action → wireframe → hierarchy → empty state → loading/error → hover and
context menus.

#### 5.4.1 Today  ⌘1

**Primary action:** **Start Focus** when nothing is running; **Finish** when a session is running.
One button, one place, it retitles.

```
┌────────────────────┬─────────────────────────────────────────────────────────┐
│ ☀ Today         ●  │  Today                     Thursday 24 July   [ ⤴ ⌄ ]   │
│ ⏱ Focus Sessions   │  ─────────────────────────────────────────────────────  │
│ ✓ Accomplishments  │  ┌───────────────────────────────────────────────────┐  │
│ ▥ Weekly Review    │  │ ● SOR engineering · Deep work                     │  │
│ 🗀 Projects        │  │ Finish the receipt deduplication PR               │  │
│ ⚙ Rules            │  │                                                   │  │
│ ⚙ Settings         │  │            32:41            ◔ 65%                 │  │
│                    │  │            remaining                              │  │
│                    │  │                                                   │  │
│                    │  │ Xcode · 4 switches · 1 interruption               │  │
│                    │  │ [ Pause ] [ Capture ⌘⇧I ]        [ Finish  ⌘⏎ ]   │  │
│                    │  └───────────────────────────────────────────────────┘  │
│                    │                                                         │
│                    │  Working toward                                         │
│                    │  ★ Improve receipt ingestion reliability   2h 10m today │
│                    │  ○ Unblock the mobile team                    35m today │
│                    │                                                         │
│                    │  Accomplishments                        [ Add   ⌘⇧A ]   │
│                    │  ✓ Opened the receipt deduplication PR          11:04   │
│                    │  ✓ Unblocked Omar on the ingestion retry        14:20   │
│                    │                                                         │
│                    │  Time allocation                                        │
│                    │  ┌────────┬────────┬────────┬────────┬────────┐         │
│                    │  │ 5h 12m │ 3h 40m │ 1h 05m │   4    │   17   │         │
│                    │  │tracked │focused │reactive│sessions│switches│         │
│                    │  └────────┴────────┴────────┴────────┴────────┘         │
│                    │  ▐coding 31%▐review 22%▐comms 19%▐mtg 14%▐other 14%▌    │
│                    │                                                         │
│                    │  Day                              9:00 ──────── 18:00   │
│                    │  ▐▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▓▓▓▓░░░▒▒▒▒▒▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▐        │
│                    │  9:00–9:52 · Receipt deduplication                      │
│                    │  Xcode, Terminal, GitHub · Completed                    │
│                    │                                                         │
│                    │  Interruptions · 2                       [ Review ]     │
│                    │  · Review Omar's blocked PR                     10:12   │
│                    │  · Reply to finance about the Q3 invoice        15:47   │
└────────────────────┴─────────────────────────────────────────────────────────┘
```

**Visual hierarchy, in priority order** (`SPEC.md` § 7's order, honoured exactly):

1. **Current or next focus session** — the only card on the screen. `Type.timerHero` for the number,
   `Type.outcome` for the intent. Everything else on Today is quieter than this by design. **[P2]**
2. **Working toward** — the week's outcomes with today's time against each. **[P5]**; in Phases 2–4
   this section is simply **absent**, not an empty placeholder.
3. **Accomplishments** — today's rows, newest last so the day reads top to bottom. **[P2]**
4. **Time allocation** — five `MetricTile`s plus one 6pt-tall stacked category bar, with the legend
   inline in its labels. No separate legend block, no pie chart. **[P4]**
5. **Activity timeline** — a horizontal day strip with grouped blocks, plus the selected block's
   detail underneath in the exact shape `SPEC.md` § 7 asks for. **[P4]**
6. **Interruption inbox** — last, compact, count in the heading. **[P4]**

The card is the *only* card. Sections 2–6 are headed lists on the bare canvas. **This is the single
most important layout decision on this screen: a Today made of six cards is a dashboard, and a
dashboard is what we are not building.**

**Timeline block grouping:** blocks come from `SessionTimelineBuilder` / `ActivityCoalescer` in
`LggrKit`, never from raw `ActivityEvent`s. A block is a contiguous run belonging to one session, or
a contiguous run of untracked-but-active time. Blocks shorter than 90 seconds are merged into their
neighbour. Idle time renders as a 40%-opacity version of the same fill. Clicking a block selects it
and updates the two lines beneath; ←/→ moves between blocks when the strip has focus.

**Empty states.** Nothing at all today:

> **Nothing tracked yet today.**
> Start a session and this fills itself in.
> `[ Start Focus  ⌘N ]`

Sessions exist but no accomplishments:

> **No accomplishments logged today.**
> Add one when something ships, or let a finished session suggest it.
> `[ Add  ⌘⇧A ]`

Empty interruption inbox: the section **hides entirely** rather than showing a state — an empty inbox
is good news and does not need a paragraph about it.

No timeline data because tracking is paused:

> **Tracking is paused.**
> Sessions and accomplishments still record; application activity does not.
> `[ Resume tracking ]`

No timeline data because Accessibility was declined — the strip still renders from application-level
data; a single `.caption` `.secondary` line sits under it: "Window titles are off, so blocks are
grouped by application." No button. It is not a problem, it is a fact.

**Loading:** § 5.3.2. The session card renders instantly from `SessionManager` (in memory); only the
lower sections redact. **Error:** § 5.3.3 banner. A failure to load history never hides a running
session — the card comes from memory, so the top of the screen keeps working.

**Hover:** accomplishment and interruption rows fill with `Surface.hover` over `Motion.tap` and reveal
a trailing `Icon.more` borderless button. Timeline blocks lift to 100% opacity from a resting 92% and
show a tooltip after 600 ms (`.help(…)`) with the exact time range.

**Context menus:**

- Session card: *Capture interruption* ⌘⇧I · *Add accomplishment* ⌘⇧A · *Copy outcome* ·
  *Change project ▸* · *Finish session* ⌘⏎
- Completed session row: *Add accomplishment* ⌘⇧A · *Edit summary…* · *Copy summary* ·
  *Change project ▸* · *Reveal in Focus Sessions* · — · *Delete session* (destructive, confirms)
- Accomplishment row: *Edit…* · *Copy as Markdown* · *Change type ▸* · *Change project ▸* · — ·
  *Delete* (destructive, confirms)
- Interruption row: *Convert to session* · *Convert to accomplishment* · *Mark resolved* · *Dismiss*
- Timeline block: *Reclassify ▸* (the eleven `ActivityCategory` cases) · *Make this a rule…* ·
  *Mark application private* · *Exclude this application*

#### 5.4.2 Focus Sessions  ⌘2   *(list view lands in Phase 4)*

**Primary action:** **New Focus Session** ⌘N.

```
┌─────────────────────────────────────────────────────────────────┐
│  Focus Sessions        [ 🔍 Search  ⌘F ]  [ All projects ⌄ ] [+]│
│  ───────────────────────────────────────────────────────────── │
│  Today                                                          │
│  ● Finish the receipt deduplication PR                          │
│    SOR engineering · Deep work · 9:00–9:52 · 52m   ✓ Completed  │
│  ● Review the ingestion retry design                            │
│    SOR engineering · Code review · 10:30–11:12 · 42m  ↷ Progress│
│                                                                 │
│  Yesterday                                                      │
│  ● Triage the duplicate commission report                       │
│    Incidents · Incident · 14:05–14:55 · 50m       ✋ Blocked     │
│  ● Weekly planning                                              │
│    — · Planning · 16:00–16:25 · 25m               ✓ Completed   │
└─────────────────────────────────────────────────────────────────┘
```

Selecting a row pushes `FocusSessionDetailView` onto the detail `NavigationStack`: the outcome as a
title, the session's stats grid, the summary (editable in place), blocker and next step if present,
the session's own timeline strip, its interruptions, and its accomplishments.

**Hierarchy:** 1. the intended outcome (`Type.rowTitle`) — this is what the user is scanning for.
2. the result status glyph + word, right-aligned. 3. project · work type · time range · duration, all
`Type.secondary`. Day headings are `Type.sectionTitle` and pinned while scrolling.

A session still `.awaitingReview` shows a `[ Review ]` button in place of the status. **This is the
recovery path for "the app quit before I answered".**

**Empty state:**

> **No focus sessions yet.**
> Your first one takes about five seconds to start.
> `[ New Focus Session  ⌘N ]`

Search with no matches:

> **Nothing matches "receipt".**
> Try a shorter phrase, or clear the project filter.

**Loading:** three redacted rows under each of two day headings. **Error:** § 5.3.3 banner.
**Hover:** row fills with `Surface.hover`, `Icon.more` appears trailing, a disclosure chevron fades
in. **Context menu:** *Open* · *Add accomplishment* ⌘⇧A · *Edit summary…* · *Copy summary* ·
*Change project ▸* · *Change work type ▸* · *Toggle reactive* · — · *Delete session* (destructive,
confirms; the confirm text names what else goes: "This also deletes the 214 activity records captured
during it.").

#### 5.4.3 Accomplishments  ⌘3   *(log view lands in Phase 4)*

**Primary action:** **Add Accomplishment** ⌘⇧A.

```
┌─────────────────────────────────────────────────────────────────┐
│  Accomplishments   [ 🔍 ⌘F ] [ All types ⌄ ] [ ⤴ Export ] [ + ] │
│  ───────────────────────────────────────────────────────────── │
│  This week                                                      │
│  ⤴ Opened the receipt deduplication PR                          │
│    ● SOR engineering · Thu 11:04                                │
│  ✓ Unblocked Omar on the ingestion retry                        │
│    ● SOR engineering · Thu 14:20                                │
│  🗎 Documented the new ingestion architecture                    │
│    ● SOR engineering · Wed 16:41                                │
│  ⚑ Resolved duplicate commission ingestion                      │
│    ● Incidents · Tue 09:30                                      │
│                                                                 │
│  Week of 14 July                                                │
└─────────────────────────────────────────────────────────────────┘
```

Grouped by week, then newest first inside the week. The leading glyph is
`AccomplishmentType.symbolName` in `.secondary` — **never tinted by type**, because eleven tinted
glyphs is a rainbow.

**Hierarchy:** 1. the title. 2. the type glyph. 3. project badge + timestamp.

**Empty state:**

> **Nothing logged yet.**
> This is the list you open on Friday to see what you actually delivered.
> `[ Add Accomplishment  ⌘⇧A ]`

**Context menu:** *Edit…* · *Copy as Markdown* · *Open source session* (only when
`isGeneratedFromSession`) · *Change type ▸* · *Change project ▸* · *Link to weekly outcome ▸* · — ·
*Delete* (destructive, confirms).

#### 5.4.4 Weekly Review  ⌘4   *(Phase 5)*

**Primary action:** **Export Review** ⌘⇧E.

```
┌─────────────────────────────────────────────────────────────────┐
│  Weekly Review    ◀  Week of 21 July  ▶   [ This week ] [ ⤴ ⌘⇧E ]│
│  ───────────────────────────────────────────────────────────── │
│  Primary outcome                                                │
│  Improve receipt ingestion reliability                          │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░  68% · In progress                  │
│  7 sessions · 8h 24m · 2 PRs opened · 3 PRs reviewed            │
│                                                                 │
│  Where the time went                                            │
│  ▐ SOR engineering 31% ▐ Code review 22% ▐ Comms 19% ▐ …  ▌     │
│  ● SOR engineering        8h 24m   31%                          │
│  ● Code review            5h 58m   22%                          │
│  ● Communication          5h 09m   19%                          │
│  ● Incidents              3h 47m   14%                          │
│  ● Planning               2h 26m    9%                          │
│  ● Other                  1h 21m    5%                          │
│                                                                 │
│  Planned vs reactive                                            │
│  ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 62% planned ▐░░░░░░░░░░ 38% reactive ▌       │
│                                                                 │
│  Focus                                                          │
│  18 sessions · 13 completed · 4 interrupted · 96 switches       │
│  Context switches per day                                       │
│  ▁▃▇▂▄  Mon Tue Wed Thu Fri                                     │
│                                                                 │
│  Accomplishments · 11                                           │
│  · Opened the receipt deduplication PR                          │
│  · Resolved duplicate commission ingestion                      │
│  · Reviewed three blocking pull requests                        │
│  … show all                                                     │
│                                                                 │
│  Observations                                                   │
│  Your longest uninterrupted sessions happened before 11:00.     │
│  Slack was the frontmost app at the start of 42% of the         │
│  interruptions you captured.                                    │
│  You spent 5h 09m reviewing and unblocking other engineers.     │
│  The primary outcome received 31% of tracked time.              │
└─────────────────────────────────────────────────────────────────┘
```

**Chart budget: two, for the entire application.** The stacked allocation bar and the
context-switches-per-day bar chart, both on this screen. Everything else — including planned vs
reactive — is a two-segment bar drawn with two `Rectangle`s, and everything else again is a number in
a sentence. Swift Charts appears in exactly one file, `Weekly/TimeAllocationChart.swift`.

**Hierarchy:** 1. primary outcome + progress. 2. where the time went. 3. planned vs reactive.
4. focus counts. 5. accomplishments. 6. observations.

**Observations** are plain sentences from `InsightGenerator`: `Type.body`, `.primary`, one per line,
`Space.s` apart, **no bullets, no icons, no colour, no ranking**. They are evidence, and dressing
evidence up as advice is how this screen would start to feel like a performance review. Language is
neutral and past tense; the generator never emits a comparative that implies failure.

**Empty state** (week with no data):

> **Nothing recorded this week.**
> Weekly Review fills in as you track. There's nothing to fix here.

Week with sessions but no weekly outcome set:

> **No outcome set for this week.**
> You can still review the time. Setting one makes the "primary outcome" line meaningful.
> `[ Set weekly outcome ]`

**Loading:** the week header renders immediately; all six sections redact. Aggregation over a week of
activity events is the one place that might exceed 250 ms, so the `ProgressView` rule of § 5.3.2
genuinely applies here. **Error:** § 5.3.3 banner with [ Try again ].

**Hover:** allocation legend rows highlight their bar segment to 100% while the rest drop to 55%
(`Motion.tap`). **Context menus:** on an allocation row — *Show these sessions* (pushes a filtered
Focus Sessions list); on an observation — *Copy*; on the whole screen — *Copy review as Markdown* ·
*Export review…* ⌘⇧E.

#### 5.4.5 Projects  ⌘5

**Primary action:** **New Project** ⌘N (when Projects is the selected section); ⌘⇧N anywhere.

```
┌─────────────────────────────────────────────────────────────────┐
│  Projects                                   [ Show inactive ] [+]│
│  ───────────────────────────────────────────────────────────── │
│  ● 🗀 SOR engineering                                            │
│      12 sessions · 8h 24m this week                             │
│  ● 🔧 Incidents                                                  │
│      4 sessions · 3h 47m this week                              │
│  ● 🗀 Mobile support                                             │
│      No sessions this week                                      │
└─────────────────────────────────────────────────────────────────┘

Editor sheet (420 wide):
┌──────────────────────────────────────────┐
│  New Project                             │
│                                          │
│  Name  ┌──────────────────────────────┐  │
│        │ SOR engineering              │  │
│        └──────────────────────────────┘  │
│                                          │
│  Colour  ● ● ● ● ● ● ● ● ●               │
│          blue purple pink red …          │
│                                          │
│  Icon    🗀 🔨 ▣ ▥ 👥 🔧 🛒 ▤ 🖌 📕        │
│                                          │
│  ☑ Active                                │
│                                          │
│  Cancel                    [ Save  ⌘⏎ ]  │
└──────────────────────────────────────────┘
```

**Hierarchy:** 1. project name with its colour dot and icon. 2. this week's usage. 3. the inactive
badge, when shown.

Inactive projects are hidden behind the `Show inactive` toggle and render at `.secondary` with the
word "Inactive" appended. They never disappear from history. **Save is disabled while the trimmed
name is blank**, and ⌘⏎ does nothing rather than shaking.

**Empty state:**

> **No projects yet.**
> Projects are optional — you can start a session without one — but they're how the weekly review
> splits your time.
> `[ New Project  ⌘N ]`

**Hover:** row fill, plus an inline `Active` toggle and `Icon.more` on the trailing edge. Colour
swatches in the editor scale their inner checkmark only (no bounce), `Motion.tap`.

**Context menu:** *Edit…* · *Start a session on this project* ⌘N · *Duplicate* ·
*Mark inactive* / *Mark active* · — · *Delete project* (destructive; the confirm text is exact about
consequences: "Sessions and accomplishments keep their history and lose the project label. Nothing is
deleted." — mirroring the `.nullify` rules in § 4.5.1).

#### 5.4.6 Rules  ⌘6   *(Phase 3)*

**Primary action:** **New Rule**.

```
┌─────────────────────────────────────────────────────────────────┐
│  Rules                                             [ ⋯ ]  [ + ] │
│  ───────────────────────────────────────────────────────────── │
│  Your rules                                                     │
│  ☑  Window title contains "Pull request"  →  Code review        │
│     Any project · Any work type · Priority 20                   │
│  ☑  Browser domain github.com             →  Code review        │
│     Any project · Any work type · Priority 10                   │
│  ☑  Application name Claude               →  Coding             │
│     SOR engineering only · Priority 30                          │
│                                                                 │
│  Built in                                                       │
│  ☑  Application com.apple.dt.Xcode        →  Coding             │
│  ☑  Application com.tinyspeck.slackmacgap  →  Communication     │
│  ☑  Browser domain youtube.com            →  Distraction        │
└─────────────────────────────────────────────────────────────────┘
```

**Hierarchy:** 1. the rule sentence, read left to right as `When … → Then …`. 2. its scope and
priority, `Type.secondary`. 3. the enabled checkbox.

Built-in rules (`isUserDefined == false`) render at `.secondary` and can be toggled but not edited;
editing one creates a user rule that shadows it (`priority` copied +5) and the original is switched
off. The `⋯` menu holds *Reset built-in rules* and *Reorder by priority*.

**Reclassify flow** (`Rules/ReclassifySheet.swift`, reached from any timeline block's context menu):
after the user picks a new category, a compact sheet offers "Always classify **Slack** as
**Communication**?" with `[ Not now ]` and `[ Create rule ]`. It is offered **once per distinct match
value per session**, never repeatedly. The sheet shows the exact evidence available to match on —
bundle ID, application name, window-title fragment, browser domain — and pre-selects the **most
specific field that is present**, with a one-line preview: *"Browser domain `github.com` → Code
review."* Two optional scope toggles narrow the rule into `projectID` and `workType`. On confirm the
event's `category` is set with `classificationSource = .manual` (and re-running the classifier may
never overwrite it), and a brief inline confirmation appears where the block was: **"Applied to 6
other blocks today. Undo."** — retroactive application covers only events whose
`classificationSource` is not `.manual`.

**Empty state** (no user rules — built-ins are always present):

> **No rules of your own yet.**
> Lggr ships with sensible defaults. Correct a category on the timeline and it will offer to make
> the correction permanent.

**Hover:** row fill; a drag handle appears on the leading edge for priority reordering (user rules
only). **Context menu:** *Edit…* · *Duplicate* · *Disable* / *Enable* · *Move up* / *Move down* · — ·
*Delete rule* (destructive; built-in rules offer *Reset to default* instead).

#### 5.4.7 Settings  ⌘7 (and ⌘,)   *(Phase 6)*

**Primary action: none — and this is deliberate.** Settings is the one screen in Lggr without a
primary button, because its primary action *is* the control the user came here to change. Adding a
`Done` button to an always-live settings pane is theatre. The "one clear thing" on this screen is the
tab you landed on.

```
┌─────────────────────────────────────────────────────────────────┐
│  Settings                                                       │
│  ( General ) ( Tracking ) ( Privacy ) ( Shortcuts ) ( Alerts )   │
│  ───────────────────────────────────────────────────────────── │
│  Sessions                                                       │
│    Default duration            ( 25m ) (•50m) ( Custom  50 ▲▼ ) │
│    Remember the last project                              ☑     │
│                                                                 │
│  System                                                         │
│    Launch at login                                        ☐     │
│    Show the timer in the menu bar                         ☑     │
│    Hide the Dock icon                                     ☐     │
│    Hiding the Dock icon also hides the menu bar commands.       │
│                                                                 │
│  Data                                                           │
│    ~/Library/Application Support/Lggr        [ Show in Finder ] │
│    Keep activity for            ( 30 ) ( 90 ) ( 365 ) ( Forever)│
│                                        [ Delete activity… ]     │
└─────────────────────────────────────────────────────────────────┘
```

Five tabs, all `Form` + `.formStyle(.grouped)`:

| Tab | Contents |
|---|---|
| **General** | Default duration, remember last project, launch at login, show timer in menu bar, hide Dock icon, data location, retention, delete activity. |
| **Tracking** | Pause tracking (master switch), idle threshold, track window titles, read browser domains, Accessibility status + [Open System Settings]. |
| **Privacy** | The full pane specified in § 6.9 — privacy statement, the three levels of control, excluded and private application lists, retention, data actions, danger zone. |
| **Shortcuts** | The global shortcut recorder, plus a read-only reference table of every in-app shortcut (§ 5.7). |
| **Alerts** | Session completed, halfway reminder, long idle. Each a plain toggle. Notification authorisation status with a single [Allow notifications] button that is never shown again once granted. |

**Empty state:** none — a settings screen with no settings is a bug. The excluded/private application
lists show an inline `.secondary` line instead of a full empty state: "No applications excluded." /
"No applications marked private."

**Loading:** preferences come from `UserDefaults` synchronously; there is no loading state.
**Error:** writes to `UserDefaults` do not fail meaningfully. Failures that *do* matter get inline
text next to the control that caused them, `.secondary`, one line: launch-at-login registration
("Couldn't add Lggr to your login items. Move Lggr to your Applications folder and try again.") and
hot-key registration ("⌘⇧Space is already taken by another app. Pick a different combination.").

**Hover:** rows in the application lists fill and reveal a trailing `–` button. **Context menu** on an
application row: *Remove* · *Move to private* / *Move to excluded* · *Show in Finder*.

### 5.5 The four panels

#### 5.5.1 The menu bar popover

`.menuBarExtraStyle(.window)`, fixed width **320**, `Space.m` interior padding, height fits content.
`Esc` dismisses. It has two states and two inline replacement modes (§ 5.5.2, § 5.5.4).

**Primary action, idle:** **Start Focus Session**. **Primary action, running:** **Finish**.

**Idle** (`MenuBarIdleView`) — the six rows are exactly the six `SPEC.md` § 1 requires, in that order:

```
┌────────────────────────────────────────┐
│  ▶  Start Focus Session      ⌘⇧Space   │  ← accent-tinted row, Type.rowTitle
│                                        │
│  ⚡ Quick Timer            25m   50m    │
│  ⊕  Add Accomplishment          ⌘⇧A    │
│  ⌁  Capture Interruption        ⌘⇧I    │
│  ────────────────────────────────────  │
│  ☀  Open Today                   ⌘1    │
│  ▥  Open Weekly Review           ⌘4    │
│  ────────────────────────────────────  │
│  Today · 3h 40m focused · 2 sessions   │  ← Type.caption, .secondary, not a button
└────────────────────────────────────────┘
```

Row height 28pt, `Radius.chip` hover fill, symbol in an 18pt frame, shortcut hint right-aligned at
`Type.caption` `.tertiary`. `Quick Timer`'s two durations are inline segments — a quick timer that
needs a submenu is not quick. It starts immediately with the last project, the last work type and an
empty outcome, and the active view's outcome line becomes an inline editable field reading "Add an
outcome" so nothing is lost.

> In the Phase 2 build, *Capture Interruption* and *Open Weekly Review* are **present but disabled,
> with a tooltip naming the phase they arrive in**. They are not dead buttons.

**Running** (`MenuBarActiveView`):

```
┌────────────────────────────────────────┐
│  ● SOR engineering · Deep work         │
│  Finish the receipt deduplication PR   │
│                                        │
│             32:41                      │  ← Type.timerCompact
│             remaining                  │  ← Type.caption, .secondary
│  ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░▌        │  ← 4pt Capsule track + accent fill
│                                        │
│  [   Pause   ]      [   Finish   ⌘⏎ ]  │
│  ────────────────────────────────────  │
│  ⌁  Capture Interruption        ⌘⇧I    │
│  ☀  Open Lggr                    ⌘1    │
└────────────────────────────────────────┘
```

Paused swaps `Pause` → `Resume` (`Icon.resume`), the progress fill drops to `.secondary`, and the
"remaining" caption becomes "paused". Overtime replaces `32:41 / remaining` with
`+4:12 / past 50 minutes`, digits in `Palette.attention`.

**Hierarchy:** 1. the timer. 2. the intended outcome. 3. Finish. 4. project and work type.
5. everything else.

**Empty state:** the idle view *is* the empty state; it never says "no session running".

**Loading:** the popover reads `SessionManager` from memory — instant, no state. The "Today · 3h 40m
focused" footer is the one async value; before it lands it renders as an empty string, not a spinner.
A spinner in a 320pt popover is noise. **Error:** if the last store read failed, the footer reads
"Today's totals are unavailable." at `Type.caption` `.secondary`. Nothing else in the popover depends
on the store.

**Keyboard:** on open, focus lands on the primary row (Start Focus Session / Pause). ↑/↓ moves between
rows, `Return` or `Space` activates, `Esc` dismisses. Every row also has its own `.keyboardShortcut`,
so the popover is fully operable without ever moving focus.

**Hover:** row fill `Surface.hover`, `Motion.tap`, `Radius.chip`. **Context menu: none** — a context
menu inside a popover is a trap. `Quit Lggr` lives in the application menu and, when the Dock icon is
hidden, in the popover's own footer.

#### 5.5.2 The session-start panel  ⌘N / ⌘⇧Space

`Focus/StartSessionForm.swift`. **One view, two hosts:** 460pt wide as a `.sheet` on the main window,
320pt wide rendered inline inside the popover (replacing `MenuBarIdleView`, because a
`.menuBarExtraStyle(.window)` popover **cannot present a sheet**). Layout is identical; only the frame
width differs. This is a real behavioural difference between the two hosts, and it exists because the
alternative — opening the main window to start a session — would break the "under five seconds, no
window required" promise.

**Primary action:** **Start Focus** ⌘⏎. This is the most important button in the product.

```
┌──────────────────────────────────────────────────────┐
│  What are you working on?                            │  Type.sectionTitle
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │ Finish the receipt deduplication PR            │  │  Type.outcome, focused on open
│  └────────────────────────────────────────────────┘  │
│    Recent                                            │  appears while the field is focused
│    ↳ Finish the receipt deduplication PR             │  and the query matches ≥1 recent
│    ↳ Review the ingestion retry design               │
│                                                      │
│  ● SOR engineering  ⌄        🧠 Deep work  ⌄         │
│                                                      │
│  ( 25m ) (● 50m ) ( Custom ) ( Open-ended )          │
│                                                      │
│  ⌄ Link to a weekly outcome                          │  collapsed; only if outcomes exist
│                                                      │
│  Start without timer  ⌘⌥⏎          [ Start Focus ⌘⏎ ]│
└──────────────────────────────────────────────────────┘
```

**Hierarchy:** 1. the outcome field — it is `Type.outcome` (17pt) while every other field is 13pt,
because it is the only required one. 2. Start Focus. 3. project and work type. 4. duration. 5. the
optional weekly-outcome link, collapsed by default.

**Intelligent defaults** (`SPEC.md` § 2, made exact):

| Field | Default |
|---|---|
| Project | `preferences.lastSelectedProjectID`; if it is missing or inactive, the most recently used active project; if there are none, "No project". |
| Work type | The work type of the user's most recent session; `.deepWork` on first run. |
| Duration | `workType.suggestedDuration` — 50m for deep work / code review / incident / planning, 25m for communication / administrative / management / meeting. |
| Outcome | Empty. Never prefilled — a prefilled intent is not an intent. |

**The one rule that makes the defaults feel intelligent instead of annoying:** the panel keeps a
`durationWasEdited` flag. Changing the work type re-applies `suggestedDuration` **only while that flag
is false**. Once the user touches the duration control, the app stops moving it.

**Keyboard focus order** — this is the mouse-free path and it is exact:

```
open ──▶ ① Outcome field  (@FocusState, .defaultFocus, text selected if prefilled)
          │  ⏎  → start immediately (this is the five-second path)
          │  ↓  → move into the Recent list; ↑/↓ to browse; ⏎ accepts and returns focus to the field
          │  ⎋  → if Recent is open, close it; otherwise cancel the panel
          ⇥
         ② Project menu    ␣ or ↓ opens · type-to-select · ⏎ commits · ⎋ closes
          ⇥
         ③ Work type menu  same behaviour
          ⇥
         ④ Duration segments  ←/→ change the selection · ␣ commits
          ⇥ (only when Custom is selected)
         ⑤ Minutes stepper  ↑/↓ by 5 · type a number directly · accepts 1–480
          ⇥ (only when at least one weekly outcome exists this week)
         ⑥ Link to a weekly outcome  ␣ expands, then the menu behaves like ②
          ⇥
         ⑦ Start without timer   ␣ or ⏎ activates
          ⇥
         ⑧ Start Focus           ␣ or ⏎ activates
          ⇥ wraps back to ①
```

⌘⏎ starts from anywhere in the panel, including from inside a menu. ⌘⌥⏎ starts without a timer
(`plannedDuration = nil`). ⎋ cancels and discards.

Tab-to-move requires the system's "Keyboard navigation" setting to include all controls, which we
cannot rely on. Therefore **every step above is also reachable without Tab**: the outcome field is
focused on open, ⏎ alone completes the flow, and the panel installs its own `@FocusState` chain so ⇥
works within the panel regardless of the system setting.

**Validation:** `Start Focus` is disabled while the trimmed outcome is empty — reduced opacity, no
red, no error text. If ⌘⏎ is pressed anyway, focus returns to the outcome field and a single
`Type.caption` `.secondary` line appears beneath it: "Add an outcome to start." It disappears on the
first keystroke. **Nothing shakes.**

**Empty states inside the panel:**

- No projects: the project menu reads "No project" and its menu contains a single item, "New
  Project…", which opens the project editor as a nested sheet and returns. Starting with no project
  is fully supported and is not flagged.
- No recent outcomes: the Recent list simply does not render. No "no suggestions" message.
- No weekly outcomes: the "Link to a weekly outcome" row is absent, not disabled.

**Loading:** the panel opens instantly with defaults from `UserPreferences` (synchronous). Projects
and recent outcomes arrive from the store within a frame or two; while they are missing, the project
menu shows the remembered project's name from preferences and the Recent list is absent. **The panel
is never blocked on I/O.** That is what makes five seconds achievable.

**Error:** if the store cannot be read, the panel **still starts sessions** — `SessionManager` holds
the session in memory and the write is retried on the next flush. A `Type.caption` `.secondary` line
sits above the buttons: "Projects couldn't be loaded. You can still start a session." Losing the
ability to start a session because a file is locked would be indefensible.

**Hover:** menus and segments take `Surface.hover`; Recent rows take `Surface.hover` and are also
navigable by keyboard, with the keyboard-highlighted row using `Surface.selected` so the two never
disagree. **Context menu: none.** A start panel with a context menu is a start panel that got away
from us.

#### 5.5.3 The session-completion review sheet

`Review/SessionReviewSheet.swift`. A `.sheet` on the main window, 520pt wide. Triggered by Finish, by
the completion notification, or by a `[ Review ]` button on an `.awaitingReview` session.

**Primary action:** **Save** ⌘⏎.

```
┌────────────────────────────────────────────────────────────┐
│  What happened?                                            │
│  Finish the receipt deduplication PR                       │  Type.outcome
│  ● SOR engineering · Deep work · 9:00–9:52                 │  Type.secondary
│                                                            │
│  ( ✓ Completed ) ( ↷ Made progress ) ( ✋ Blocked )         │
│  ( ⌁ Interrupted ) ( ⑂ Reprioritized )                     │
│                                                            │
│  52m active · 47m focused · 5m idle · 6 switches · 1 int.  │
│  Xcode 31m · Terminal 9m · Slack 7m · GitHub 5m            │
│                                                            │
│  Summary                                    ⟳ Regenerate ⌘R│
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Worked primarily in Xcode and Terminal on receipt    │  │
│  │ deduplication. Reviewed one GitHub pull request and  │  │
│  │ spent seven minutes in Slack.                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ▸ Add result, blocker or next step                        │
│                                                            │
│  Not now            [ Log accomplishment ]   [ Save  ⌘⏎ ]  │
└────────────────────────────────────────────────────────────┘
```

**Hierarchy:** 1. the five result options — the only required field. 2. the outcome being judged.
3. the generated summary. 4. the statistics. 5. the optional fields.

**Interaction detail:**

- The five options are focused first. ←/→ moves, `Space` selects, and pressing **`1`–`5`** selects
  directly. Answer-and-Return finishes the sheet in two keystrokes.
- `Save` is disabled until a status is chosen. Same treatment as § 5.5.2: opacity, no red.
- When the chosen status has `needsFollowUp == true`, the disclosure auto-expands with the relevant
  field focused — **Blocked** → *Blocker*, **Interrupted** and **Reprioritized** → *Next step*. No
  colour change, no warning icon, no "are you sure". The app asks a useful follow-up question and
  moves on.
- The summary is fully editable; ⌘R regenerates from `SessionSummaryBuilder`, and regenerating after
  an edit asks nothing — the previous text is restorable with ⌘Z because it is a normal `TextEditor`.
- `Log accomplishment` opens `AddAccomplishmentSheet` prefilled with the outcome as the title, the
  session's project, and a type guessed from the session's result status / dominant category
  (`.completed` → `.featureCompleted`). On save it returns and saves both records.
- **`Esc` and `Not now` do not discard the session.** They leave it `.awaitingReview`: the menu bar
  symbol becomes `questionmark.circle`, and the Today row and the Focus Sessions row grow a
  `[ Review ]` button. **A finished session is never lost because a sheet was dismissed.**

**Empty / degraded states:** with no activity data (Phase 2, or Accessibility denied, or tracking
paused), the statistics line collapses to `52m active` and the application list is replaced by one
`Type.caption` `.secondary` line: "No application activity was recorded for this session." The
generated summary falls back to the deterministic outcome-only form. Everything else is unchanged.

**Loading:** the sheet opens instantly with the session, the status picker and the fallback summary.
Statistics and the richer generated summary land when `ActivityAggregator` finishes; until then those
two blocks are redacted. **The user can answer and save before the statistics arrive** — the answer is
what matters and it is never gated on aggregation.

**Error:** a failed save is the one case in the app that gets an `Alert`, because the user's typed
summary is at risk: "Couldn't save this session." / "Try again, or copy the summary so you don't lose
it." / `[ Copy summary ]` `[ Try again ]`. The sheet stays open.

**Hover:** the application-time chips highlight and offer a tooltip with the exact duration.
**Context menu** on the summary editor: the standard text-editing menu plus *Regenerate* ⌘R and
*Copy as Markdown*.

#### 5.5.4 The interruption capture field  ⌘⇧I   *(Phase 3)*

`Focus/InterruptionCaptureSheet.swift`. **Primary action:** **Save** ⌘⏎. Two hosts, the same view: a
420pt `.sheet` from the main window, and an inline replacement of the popover body when triggered
from the menu bar.

```
┌────────────────────────────────────────────┐
│  What came up?                             │
│  ┌──────────────────────────────────────┐  │
│  │ Review Omar's blocked PR             │  │  focused on open
│  └──────────────────────────────────────┘  │
│  From  Other ⌄                             │  appears after the first character
│                                            │
│  Cancel                     [ Save  ⌘⏎ ]   │
└────────────────────────────────────────────┘
```

Everything about this is designed around one fact: **the session keeps running.** So:

- **No timer is shown here.** Showing the clock while capturing an interruption invites the user to
  end the session, which is the exact opposite of the intent.
- One field. The `From` menu (`InterruptionSource`, eight cases) is collapsed to a single menu
  defaulting to `.other` — or to `.chat` when the previously frontmost application classifies as
  `.communication` — and it does not appear until the user has typed a character. Eight chips on
  screen before the user has typed anything is a form; one menu after they have is a refinement.
- ⏎ in the field saves (`.onSubmit`). ⌘⏎ saves from anywhere. `Esc` cancels and discards.
- On save the panel dismisses immediately with `Motion.settle`. **There is no toast.** The Today
  interruption count increments and the popover's inbox row updates; that is the confirmation.
  Interruption capture must cost less attention than the interruption did.
- `interruptionCount` on the running `FocusSession` increments, and the new `Interruption` carries
  `focusSessionID` and `status: .inbox`. **The timer was never paused and `pauseStartedAt` was never
  set.**
- Captured with no session running, it saves with `focusSessionID == nil` and still lands in the
  inbox. **⌘⇧I is never unavailable.**

**Empty state:** none — it is a single empty field by definition. Save is disabled while the trimmed
note is empty. **Loading:** none; nothing is read. **Error:** if the write fails, the panel stays open
with one `Type.caption` `.secondary` line above the buttons: "Couldn't save that yet — try again." The
text is never cleared.

### 5.6 Menu bar icon states

The label is `Views/MenuBar/MenuBarLabel.swift`, driven by `MenuBarManager.labelState`.

```swift
struct MenuBarLabel: View {
    let state: MenuBarLabelState
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: state.symbolName)
            if let text = state.timeText {
                Text(text)
                    .font(Type.menuBarTimer)
                    .foregroundStyle(state.isPaused ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(.primary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lggr")
        .accessibilityValue(state.spokenValue)
    }
}
```

#### 5.6.1 The states

| State | SF Symbol | Trailing text | Notes |
|---|---|---|---|
| **Idle** — no session | `timer` | *(none)* | Symbol only. No dot, no badge, no colour. Indistinguishable in weight from any system menu extra. |
| **Running** — countdown | `timer` | `32:41` | Same symbol as idle. **The presence of digits is the state change, not a different glyph.** This is the subtlety mechanism. |
| **Running** — open-ended | `timer` | `1:12:04` | Counts up. |
| **Paused** | `pause.circle` | `32:41` | Digits frozen and rendered `.secondary`. The symbol carries the meaning; the dimmed digits confirm it. |
| **Overtime** | `timer` | `+4:12` | Digits in `Palette.attention`. Still `timer` — overtime is a display sub-state of `.running`, not a new lifecycle state. |
| **Awaiting review** | `questionmark.circle` | *(none)* | The session ended and has no `resultStatus`. Clicking opens the popover with `Review last session` as the top row. |

The symbols come from `SessionState.symbolName` (§ 4.1) used verbatim. `SessionState.completed`'s
`checkmark.circle` is **never shown in the menu bar** — a completed, reviewed session returns the
label to **Idle**. A permanent checkmark would be a reward, and rewards are gamification.

#### 5.6.2 Exact title format for the running timer

`DurationFormatting.menuBar(_:)` in `LggrKit`, unit-tested:

| Condition | Format | Examples |
|---|---|---|
| `< 1 hour` | `m:ss`, **no** leading zero on minutes | `0:07`, `9:07`, `32:41` |
| `>= 1 hour` | `H:mm:ss` | `1:02:00`, `1:12:04` |
| Overtime | `+` prefix, same rules as above | `+0:31`, `+4:12`, `+1:02:00` |
| `showTimerInMenuBar == false` | *(no text in any state)* | symbol only |

Countdown shows `remaining(at:)`; open-ended shows `elapsed(at:)`; overtime shows `overrun(at:)`. A
negative input never produces a `-` sign.

Companion formats, same file: `DurationFormatting.clock(_:)` → `"0:00"` / `"25:00"` / `"1:01:01"`;
`.compact(_:)` → `"0m"` / `"50m"` / `"1h 12m"`; `.overrun(_:)` → `"+2:07"`.

#### 5.6.3 How it stays subtle

Seven specific decisions, each of which prevents a real failure mode:

1. **`.monospacedDigit()`** — the label's width is stable between `10:00` and `59:59`, so the menu bar
   does not reflow every second. The single biggest contributor to "subtle".
2. **`.rounded` at 12pt regular** — visually the same weight as the system clock a few pixels away.
3. **The symbol does not change between idle and running.** Only the digits appear.
4. **No colour** except the overtime digits, and those are ~5 characters of orange.
5. **No animation, ever.** No content transition, no fade, no pulse. The label redraws once per second
   at `tolerance: 0.15` and that is all it does.
6. **No project name, no outcome text.** The menu bar is visible in every screen share and every
   over-the-shoulder glance. "Finish the receipt deduplication PR" is nobody else's business. Context
   lives in the popover, one click away.
7. **The `TickTimer` only exists while a session runs.** Idle Lggr does zero work per second.

#### 5.6.4 VoiceOver

`accessibilityLabel` is always `"Lggr"`. `accessibilityValue` is built by
`DurationFormatting.spokenDuration(_:)`:

| State | Spoken value |
|---|---|
| Idle | "No focus session running" |
| Running | "Focus session running, 32 minutes 41 seconds remaining, SOR engineering" |
| Running, open-ended | "Focus session running, 1 hour 12 minutes elapsed, SOR engineering" |
| Paused | "Focus session paused, 32 minutes 41 seconds remaining" |
| Overtime | "Focus session running, 4 minutes 12 seconds past the planned 50 minutes" |
| Awaiting review | "A finished focus session is waiting for your review" |

The project name is spoken because VoiceOver output is private to the user, unlike the visible label.

### 5.7 Keyboard map

#### 5.7.1 The complete map

**System-wide**

| Shortcut | Action |
|---|---|
| ⌘⇧Space *(P6)* | Start a focus session. Configurable in Settings → Shortcuts. Activates Lggr, opens the popover, shows the start panel inline. Does not open the main window. |

**Application-wide** — implemented as real menu commands in `App/AppCommands.swift`, so they work
from any window and are discoverable in the menu bar.

| Shortcut | Menu item | Action |
|---|---|---|
| ⌘N | File → New Focus Session | Opens the start panel as a sheet on the main window (opening the window first if needed). In Projects, ⌘N is New Project. |
| ⌘⇧N | File → New Project | Opens the project editor. |
| ⌘⏎ | Session → *(retitles)* | **Contextual.** "Start Focus" while the start panel is open; "Save Review" while the review sheet is open; "Finish Session" while a session runs and nothing is presented. One item, one shortcut, three titles — this is how `SPEC.md`'s "⌘Return: Start or confirm" is honoured without collisions. |
| ⌘⌥⏎ | Session → Start Without Timer | Starts with `plannedDuration == nil`. |
| Space | Session → Pause / Resume | Only when the Active Session card holds keyboard focus and no text field is editing. Retitles between Pause and Resume. |
| ⌘⇧I | Session → Capture Interruption | Always available, session or not. *(Registered but disabled with an explanatory tooltip until Phase 3 — it is not a dead button.)* |
| ⌘⇧A | File → Add Accomplishment | Always available. |
| ⌘1–⌘7 | View → *(section names)* | Selects the sidebar section; opens the main window if it is closed. |
| ⌘, | Lggr → Settings | Opens the Settings scene. |
| ⌘F | Edit → Find | Focuses the search field on Focus Sessions and Accomplishments. |
| ⌘⇧E | File → Export… | Exports the current screen (Today → daily Markdown, Weekly Review → weekly Markdown, Accomplishments → log Markdown, Focus Sessions → CSV). |
| ⌘R | Session → Regenerate Summary | Only inside the review sheet. |
| ⌘W | Window → Close | Closes the window. Does not quit. |
| ⌘Q | Lggr → Quit | Quits. A running session is restored on next launch. |
| Esc | — | Closes the frontmost popover, sheet or panel. Never destroys a finished session (§ 5.5.3). |
| ⌘. | — | Dismisses the error banner. |

**Contextual, within a screen or panel**

| Shortcut | Where | Action |
|---|---|---|
| ⇥ / ⇧⇥ | Every panel | Moves through the panel's own `@FocusState` chain. |
| ↑ / ↓ | Sidebar, lists, popover rows, Recent list | Moves selection. |
| ← / → | Segmented controls, timeline strip, week stepper | Changes value / block / week. |
| ⏎ | Outcome field, interruption field | Submits — the whole reason the flow is five seconds. |
| 1–5 | Review sheet | Selects the result status directly. |
| ⌘⌫ | Any list with a selection | Deletes the selected row after confirmation. |
| ⌘Z / ⌘⇧Z | Summary editor, all text fields | Standard text undo. Available because `LSUIElement` is `false` and the Edit menu exists. |

#### 5.7.2 Making mouse-free real, not aspirational

1. **⌘⏎ retitles rather than collides.** The alternative — three different shortcuts for start, finish
   and save — is what makes keyboard-first apps unlearnable.
2. **Tab is not load-bearing.** macOS ships with keyboard navigation limited to text boxes and lists
   unless the user changes a system setting. Every panel therefore installs an explicit `@FocusState`
   chain plus `.defaultFocus`, and every flow can be completed with ⏎ and arrow keys alone. **We never
   tell the user to go change a System Settings toggle.**
3. **The popover is keyboard-complete.** It opens with focus on its primary row; ↑/↓ moves; every row
   additionally carries its own `.keyboardShortcut`.
4. **Shortcuts are discoverable in two places** — the application menu bar (which exists because
   `LSUIElement` is `false`) and a read-only reference table in Settings → Shortcuts. There is no
   cheat-sheet overlay and no `?` key modal; a Mac app's shortcuts belong in its menus.
5. **Space-to-pause is scoped** so it never fights text input: the Active Session card must hold
   keyboard focus and no text field may be editing. In the popover, `Space` activates the focused
   Pause button, which produces the same result by a different mechanism. Typing a space inside the
   summary editor inserts a space and does **not** resume the session — that is an explicit
   acceptance test (task P2-84).

### 5.8 Accessibility

#### 5.8.1 Contrast

- All text is `.primary`, `.secondary` or `.tertiary`, which the system guarantees against
  `.windowBackgroundColor` in both appearances. `.quaternary` is used for shapes only, never text.
- The hero timer is `.primary` on `Surface.raised` — roughly 15:1. Body text on the same surface
  clears 4.5:1 in both modes; `Type.secondary` at 11pt clears 4.5:1 because `.secondary` on macOS is a
  ~60% alpha over a high-contrast base, not a light grey literal.
- Disabled controls use the system's disabled rendering. We never fake "disabled" with custom low
  opacity on text.
- The user's system accent is respected; we never assume blue, and never place text on an accent fill
  except in `PrimaryButtonStyle`, where the foreground is `Color.white` over the accent's own
  guaranteed-contrast fill (the same treatment as a native `.borderedProminent` button).
- **Colour is never the only signal.** Project colour always sits next to the project name; result
  status always shows a glyph *and* the word; overtime shows a `+` sign as well as orange; the
  allocation bar has a labelled legend.

#### 5.8.2 VoiceOver

| Element | Label | Value / hint |
|---|---|---|
| Hero timer | "Time remaining" (or "Time elapsed" when open-ended, "Time past plan" in overtime) | `DurationFormatting.spokenDuration` → "32 minutes 41 seconds". Trait `.updatesFrequently`. **We never post an `AccessibilityNotification.Announcement` on a tick** — only once, at session completion. |
| Progress ring | "Session progress" | "65 percent" |
| Menu bar item | "Lggr" | § 5.6.4 |
| `MetricTile` | `.accessibilityElement(children: .combine)` | Reads "Focused, 3 hours 40 minutes" as one element. |
| Day timeline strip | "Activity timeline for Thursday 24 July" | One container element with `.accessibilityChildren`, each block labelled "9:00 to 9:52, receipt deduplication, Xcode, Terminal, GitHub, completed". |
| Allocation bar | — | `.accessibilityRepresentation` of a plain `List` of "SOR engineering, 31 percent". **A chart is never exposed as a chart.** |
| Icon-only buttons | Explicit `.accessibilityLabel` — "More actions", "Regenerate summary", "Previous week" | — |
| Project colour swatch | The colour's name — "Teal" | `.isSelected` trait when chosen |
| Result status option | The `displayName` | `.isSelected` trait |
| Error banner | "Error" | The message text; the recovery buttons are separate elements. |

Every screen sets `.accessibilityLabel` on its detail-column root so VoiceOver's rotor lists the seven
sections by name.

#### 5.8.3 Dynamic Type

- Every font in § 5.2.1 derives from a text style, so all of them scale. The one fixed size — the hero
  timer — uses `@ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 72`.
- **No fixed row heights anywhere.** Rows are padding plus content, with
  `.fixedSize(horizontal: false, vertical: true)` on any multi-line text.
- `ViewThatFits` handles the three layouts that break first:
  - Today's five `MetricTile`s → 5 across → 3 + 2 → a vertical list.
  - The start panel's button row → side by side → `Start without timer` above `Start Focus`.
  - The review sheet's five status options → 3 + 2 → one per line.
- **Truncation policy:** the intended outcome never truncates — it wraps to at most three lines and the
  container grows. Project names truncate `.middle`. Application names in a statistics line truncate
  `.tail`. Nothing else truncates.
- The sidebar's minimum width of 180 is sized for "Accomplishments" at the default size; at larger
  sizes the sidebar can be dragged wider and the labels wrap to two lines rather than truncating.
- macOS has no per-app text-size control equivalent to iOS, so this is less testable here than "Dynamic
  Type where applicable" might imply. `LGGR_GALLERY=1` should grow a `.dynamicTypeSize(.accessibility3)`
  column so the `ViewThatFits` fallbacks are actually exercised.

#### 5.8.4 Reduce Motion, Reduce Transparency, Increase Contrast

`@Environment(\.accessibilityReduceMotion)`, funnelled through the single `.lggrAnimation` modifier in
§ 5.2.8, so there is one place to audit.

| Normally | Under Reduce Motion |
|---|---|
| `Motion.reveal` spring | 0.1 s ease-in-out |
| `Motion.settle` | 0.1 s ease-in-out |
| `Motion.ring` linear interpolation | discrete update per tick, no interpolation |
| `.contentTransition(.numericText())` on the hero timer | `.identity` |
| Disclosure expansion | instant |
| Any `.scaleEffect` / any repeating animation | *(there are none — § 5.2.8)* |

Sheet and window presentation animations belong to the system and already honour the setting.

**Reduce Transparency** → the floating session strip's `.thinMaterial` becomes `Surface.raised`. That
is the only material we own. **Increase Contrast** → the step-ups in § 5.2.7.

#### 5.8.5 Full keyboard navigation guarantees

- Every action reachable by mouse is reachable by keyboard.
- Every panel focuses its primary field or button on open, via `.defaultFocus` + `@FocusState`.
- Focus rings are the system's. **We never set `.focusEffectDisabled()`.**
- Focus order matches visual order in every panel.
- The keyboard-highlighted row and the hover-highlighted row use different fills (`Surface.selected`
  vs `Surface.hover`) so the two inputs never contradict each other on screen.
- No flow depends on the system's "Keyboard navigation: all controls" setting being enabled.

### 5.9 What we deliberately avoid

| We do not build | Because |
|---|---|
| **Streaks, badges, levels, XP, confetti** | The product's claim is that it reconstructs your work honestly. A streak makes the user optimise for the streak. |
| **A productivity score** | There is no number that summarises a week of knowledge work, and inventing one turns the weekly review into a performance review. |
| **Shaming copy** | These words never appear in Lggr: *wasted, distracted, failed, behind, only, should have, missed, unproductive*. Observations are past tense and neutral, and `InsightGeneratorTests` asserts it with a banned-lexicon test. |
| **Red as an information colour** | Red exists in exactly one place: the confirm button of a delete alert. Blocked sessions, distraction time and at-risk outcomes are never red. |
| **Gradients** | Zero gradients. Not on buttons, not on cards, not on charts, not behind the timer. (The single exception is the linear mask that fades the timeline strip at its scroll edges, which is a mask, not a fill.) |
| **Cards everywhere** | Exactly one card on Today, one in the popover. A card means "this container has its own primary action". Everything else is a headed list on the bare canvas. |
| **Dashboard clutter** | Hard budget: at most 5 metrics on Today, at most 2 charts in the entire application, both on Weekly Review, zero charts on every other screen. |
| **Unnecessary charts** | Planned-vs-reactive is two rectangles. Time by category is one stacked bar. If a number reads better as a sentence, it is a sentence. |
| **Tiny text** | Nothing below 10pt exists, and nothing a user *must* read is below 11pt. |
| **Modal dialogs for common actions** | Start, capture, add and review are panels and sheets that `Esc` dismisses with no loss. Alerts appear for exactly two reasons: unsaveable input, and destructive confirmation. |
| **Toasts, snackbars and "Saved!" banners** | The result of an action is visible in the data. Interruption capture increments a count; that is the receipt. |
| **Coach marks, tooltips-on-first-run, "Did you know?"** | Onboarding is six screens and then it is over. |
| **Repeated permission prompts** | Accessibility is requested at most twice in the application's lifetime (§ 6.6). |
| **Emoji and exclamation marks in UI copy** | Not one, anywhere. |
| **Empty-state illustrations** | One SF Symbol, two lines of text, at most one button. |
| **Generic web-app styling** | No custom shadows, no hand-mixed greys, no 4pt-radius rectangles pretending to be Material Design, no all-caps tracked-out labels. |
| **Notifications that interrupt to say nothing** | Three kinds, all optional, all configurable, none of them repeating. |

### 5.10 Exact user-facing copy — Phase 2

Every string the Phase 2 vertical slice renders. Concise, natural, no exclamation marks, no corporate
voice. English strings are written inline; there is no localisation catalogue in the MVP.

**Navigation and chrome**

| Key | String |
|---|---|
| Sidebar rows | `Today` · `Focus Sessions` · `Accomplishments` · `Weekly Review` · `Projects` · `Rules` · `Settings` |
| Window title | `Lggr` |
| Today header date | `Thursday 24 July` (`.dateTime.weekday(.wide).day().month(.wide)`) |

**Menu bar popover**

| Key | String |
|---|---|
| Idle primary row | `Start Focus Session` |
| Quick timer row | `Quick Timer` |
| Add accomplishment row | `Add Accomplishment` |
| Capture interruption row | `Capture Interruption` |
| Open today row | `Open Today` |
| Open weekly review row | `Open Weekly Review` |
| Idle footer, with data | `Today · 3h 40m focused · 2 sessions` |
| Idle footer, nothing yet | `Nothing tracked yet today` |
| Idle footer, store error | `Today's totals are unavailable` |
| Active: remaining caption | `remaining` |
| Active: elapsed caption (open-ended) | `elapsed` |
| Active: paused caption | `paused` |
| Active: overtime caption | `past 50 minutes` (the planned duration, formatted) |
| Pause / Resume buttons | `Pause` · `Resume` |
| Finish button | `Finish` |
| Open the app row | `Open Lggr` |
| Awaiting-review top row | `Review last session` |

**Start panel**

| Key | String |
|---|---|
| Title | `What are you working on?` |
| Outcome placeholder | `Finish the receipt deduplication PR` |
| Recent list heading | `Recent` |
| No-project menu label | `No project` |
| New project menu item | `New Project…` |
| Duration segments | `25m` · `50m` · `Custom` · `Open-ended` |
| Custom minutes suffix | `minutes` |
| Weekly outcome disclosure | `Link to a weekly outcome` |
| Primary button | `Start Focus` |
| Secondary button | `Start without timer` |
| Empty-outcome hint | `Add an outcome to start.` |
| Store-unavailable note | `Projects couldn't be loaded. You can still start a session.` |

**Active session**

| Key | String |
|---|---|
| Remaining label | `remaining` |
| Elapsed label | `elapsed` |
| Overtime label | `past 50 minutes` |
| Paused label | `paused` |
| Buttons | `Pause` · `Resume` · `Finish` · `Capture` |
| Live activity line | `Xcode · 4 switches · 1 interruption` |
| Live activity, no data | `No activity recorded yet` |
| Quick-timer outcome placeholder | `Add an outcome` |

**Review sheet**

| Key | String |
|---|---|
| Title | `What happened?` |
| Status options | `Completed` · `Made progress` · `Blocked` · `Interrupted` · `Reprioritized` |
| Stats line | `52m active · 47m focused · 5m idle · 6 switches · 1 interruption` |
| Stats, no activity data | `No application activity was recorded for this session.` |
| Summary heading | `Summary` |
| Regenerate button | `Regenerate` |
| Disclosure | `Add result, blocker or next step` |
| Field labels | `Tangible result` · `Blocker` · `Next step` |
| Field placeholders | `What exists now that didn't before?` · `What's in the way?` · `What's the next concrete step?` |
| Buttons | `Save` · `Log accomplishment` · `Not now` |
| Save failure alert title | `Couldn't save this session.` |
| Save failure alert body | `Try again, or copy the summary so you don't lose it.` |
| Save failure buttons | `Copy summary` · `Try again` |

**Interruption capture**

| Key | String |
|---|---|
| Title | `What came up?` |
| Placeholder | `Review Omar's blocked PR` |
| Source label | `From` |
| Buttons | `Save` · `Cancel` |
| Save failure | `Couldn't save that yet — try again.` |

**Add accomplishment**

| Key | String |
|---|---|
| Title (manual) | `Add an accomplishment` |
| Title (from session) | `Log what you delivered` |
| Field labels | `What happened` · `Type` · `Project` · `Details` |
| Details placeholder | `Optional` |
| Buttons | `Save` · `Cancel` |

**Today**

| Key | String |
|---|---|
| Section headings | `Working toward` · `Accomplishments` · `Time allocation` · `Day` · `Interruptions` |
| Metric labels | `tracked` · `focused` · `reactive` · `sessions` · `switches` |
| Add accomplishment button | `Add` |
| Empty — nothing today | **`Nothing tracked yet today.`** / `Start a session and this fills itself in.` / `Start Focus` |
| Empty — no accomplishments | **`No accomplishments logged today.`** / `Add one when something ships, or let a finished session suggest it.` / `Add` |
| Empty — tracking paused | **`Tracking is paused.`** / `Sessions and accomplishments still record; application activity does not.` / `Resume tracking` |
| Titles-off note | `Window titles are off, so blocks are grouped by application.` |
| Load error banner | `Couldn't load today. Your work is still on disk.` / `Try again` · `Show in Finder` |

**Projects**

| Key | String |
|---|---|
| Editor titles | `New Project` · `Edit Project` |
| Field labels | `Name` · `Colour` · `Icon` · `Active` |
| Name placeholder | `SOR engineering` |
| Usage line | `12 sessions · 8h 24m this week` |
| Usage line, none | `No sessions this week` |
| Inactive tag | `Inactive` |
| Show inactive toggle | `Show inactive` |
| Empty state | **`No projects yet.`** / `Projects are optional — you can start a session without one — but they're how the weekly review splits your time.` / `New Project` |
| Delete confirm title | `Delete "SOR engineering"?` |
| Delete confirm body | `Sessions and accomplishments keep their history and lose the project label. Nothing is deleted.` |
| Delete confirm buttons | `Cancel` · `Delete Project` |

**Focus Sessions**

| Key | String |
|---|---|
| Search placeholder | `Search outcomes` |
| Project filter | `All projects` |
| Review button | `Review` |
| Day headings | `Today` · `Yesterday` · `Tuesday 22 July` |
| Empty state | **`No focus sessions yet.`** / `Your first one takes about five seconds to start.` / `New Focus Session` |
| No search results | **`Nothing matches "receipt".`** / `Try a shorter phrase, or clear the project filter.` |
| Delete confirm title | `Delete this session?` |
| Delete confirm body | `This also deletes the 214 activity records captured during it.` |

**Accomplishments**

| Key | String |
|---|---|
| Search placeholder | `Search accomplishments` |
| Type filter | `All types` |
| Export button | `Export` |
| Group headings | `This week` · `Week of 14 July` |
| Empty state | **`Nothing logged yet.`** / `This is the list you open on Friday to see what you actually delivered.` / `Add Accomplishment` |

**Notifications** (Phase 2 sends none; Phase 6 sends the first)

| Key | String |
|---|---|
| Session completed — title | `Session finished` |
| Session completed — body | `Finish the receipt deduplication PR · 50 minutes` |
| Session completed — action | `Review` |

### 5.11 Key user flows

Phase markers indicate when each affordance actually exists.

#### Flow A — Start a focus session in under five seconds, from the keyboard

**Budget: two keystrokes plus the time it takes to type one sentence.**

1. **⌘⇧Space** anywhere in macOS. `GlobalShortcutService` activates Lggr and presents
   `StartSessionForm` inline in the popover. **[P6]** — *in Phase 2 this is **⌘N** from the main menu,
   or clicking `MenuBarLabel` → "Start Focus Session".*
2. The panel appears with **`OutcomeField` already focused**. Nothing else needs touching: the project
   is pre-selected from `lastSelectedProjectID`, the work type is on `.deepWork`, and the duration
   shows **50m** because `WorkType.deepWork.suggestedDuration` is 3000 s. **[P2]**
3. Type the intent — *"Finish the receipt deduplication PR"*. Up to three recent outcomes from the
   last 30 days appear beneath the field; **↓** then **↩** accepts one and skips the typing entirely.
   The field is required and the primary button stays disabled until it is non-empty. **[P2]**
4. *(Optional.)* **Tab** to the project menu and type-ahead; **Tab** to the work type — changing it
   re-suggests the duration unless you have already touched it; **Tab** to the duration segments.
   Linking to a weekly outcome lives behind a disclosure and is skipped by default. **[P2]**, outcome
   linking **[P5]**.
5. **⌘↩** triggers **Start Focus**. (**⌥⌘↩** triggers **Start without timer**.) **[P2]**
6. The panel dismisses. `SessionManager` writes the session to the store immediately (so a crash
   cannot lose it), starts `TickTimer`, and `MenuBarLabel` switches to the `timer` symbol plus
   **49:59** counting down. If the main window is open it shows `ActiveSessionView` with
   `TimerDisplay` dominant. **[P2]**

**Steps 1, 3 and 5 are the only mandatory ones.** Everything between them is a default that is already
correct on most days — that is what buys the five seconds.

#### Flow B — Capture an interruption without ending the session

The point of this flow is that it costs you less attention than the interruption already did.

1. **⌘⇧I** from anywhere in the app, or **"Capture interruption"** in `MenuBarActiveView` — reachable
   without leaving your current app. **[P3]**
2. `InterruptionCaptureSheet` appears: **one text field, already focused**. Nothing else. **[P3]**
3. Type the note — *"Review Omar's blocked PR."* **[P3]**
4. *(Optional.)* Pick an `InterruptionSource`. It defaults sensibly, so most of the time you leave it
   alone. **[P3]**
5. **⌘↩** saves. An `Interruption` is written with `status: .inbox` and `focusSessionID` set to the
   running session; `FocusSession.interruptionCount` increments. **[P3]**
6. The sheet dismisses. **The timer was never paused, `pauseStartedAt` was never set, and
   `MenuBarLabel` did not change.** You are back where you were. **[P3]**
7. Later, the item waits in `InterruptionInboxView` on Today with a badge count. Each item can be
   converted into a project, resolved, or dismissed — and it feeds "most common interruption sources"
   in the weekly review. **[P4]**

**Escape hatch:** **Esc** dismisses without saving, and the same sheet is available with no session
running (`focusSessionID` is `nil`) from `MenuBarIdleView`.

#### Flow C — Finish a session and review it

1. The countdown reaches zero. `NotificationService` posts "Session finished" **[P6]**, and
   `MenuBarLabel` switches to a `+M:SS` overrun reading. **Nothing auto-stops**; running past the
   timer is normal and is not treated as an error. **[P2]**
2. **Finish** — the primary button in `SessionControls`, or "Finish" in `MenuBarActiveView`, or the
   notification's action. `finish(at:)` closes any open pause first, sets `endedAt`, and the session
   enters `.awaitingReview`. **[P2]**
3. `SessionReviewSheet` appears, leading with **"What happened?"**; **1–5** select the status from the
   keyboard. This is the only required field. **[P2]**
4. Beneath it, `SessionStatsGrid` presents the evidence without commentary. **[P3]** — *in Phase 2
   this is duration and interruption count only.*
5. `SummaryEditor` is pre-filled by `SessionSummaryBuilder`. You accept it, tweak a word, or rewrite
   it. **[P2]** for the intent/duration form, **[P3]** for the activity-derived form.
6. *(Optional.)* An **"Add result, blocker or next step"** disclosure. Collapsed by default; expands
   automatically when the status `needsFollowUp`. **[P2]**
7. **⌘↩** saves. `SessionState` becomes `.completed`. **[P2]**
8. The sheet dismisses to `TodayView`, where the session is now a `CompletedSessionRow`, and — from
   Phase 4 — a block on `DailyTimelineView`. **[P2] / [P4]**
9. The row carries a single inline action, **"Add accomplishment"**, pre-filled from the session.
   **⌘↩** saves it to the Done log. **[P2]**

#### Flow D — Friday morning weekly review

1. Open Lggr — Dock icon, or `MenuBarIdleView` → **"Open Weekly Review"**. **[P2]** for the menu item,
   **[P5]** for the destination.
2. **⌘4** selects **Weekly Review**. It opens on the *current* week, with a week stepper for looking
   back. **[P5]**
3. Read top to bottom, in the order of § 5.4.4 — "what did I do" before "where did the time go".
4. The screen has **one primary action: "Export Review"** (⌘⇧E), producing the document shaped exactly
   like the example in `SPEC.md` § Export. **[P5]**
5. *(The second half of Friday morning.)* `WeeklyOutcomesView` for next week: one primary outcome, up
   to two secondary, plus operational responsibilities. Anything not achieved can be marked
   `.carriedOver` rather than silently rewritten, so next week starts honest. **[P5]**

#### Flow E — Reclassify an activity and create a rule from it

Correcting a mistake must take one interaction and must make the app permanently smarter — this is the
loop that replaces AI in the MVP. The full interaction is specified in § 5.4.6. **[P3]**

---

## 6. Permissions and privacy strategy

### 6.0 The stance in one paragraph

Lggr ships **unsandboxed**, signed with the **hardened runtime**, distributed outside the Mac App
Store. It requests exactly three system authorisations, all optional, all separately deniable:
**Accessibility** (window titles), **Automation** (browser domain, per browser), and
**Notifications**. It uses `SMAppService` for launch-at-login, which is a user setting rather than a
permission. It requests **nothing else** — no Screen Recording, no Input Monitoring, no Full Disk
Access, no network entitlement, no calendar or contacts. With every permission denied Lggr is still a
complete Toggl-plus-Pomodoro-plus-accomplishment-log with automatic per-application time tracking;
permissions only add resolution to a picture that is already useful. Data lives in one readable
directory in the user's home folder, activity capture is redacted **before it is read**, not before
it is displayed, and every destructive action offers an export first.

### 6.1 Permission and entitlement inventory

#### 6.1.1 Accessibility — window titles

| | |
|---|---|
| **Why** | SPEC § 4 lists *window title when permission is available*. The title is the difference between "Xcode, 42 minutes" and "receipt deduplication, 42 minutes". It is what makes `SessionSummaryBuilder` produce the spec's example sentence and what makes `RuleMatchType.windowTitleContains` rules possible. |
| **Framework** | `import ApplicationServices` |
| **Status check (never prompts)** | `AXIsProcessTrusted() -> Bool` |
| **Request (prompts)** | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)` |
| **Read** | `AXUIElementCreateApplication(pid)` → `AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)` → `AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)` |
| **Info.plist key** | **None** — macOS has no such TCC key (see note 1). |
| **Entitlement** | **None.** Incompatible with `com.apple.security.app-sandbox` — see § 6.2. |
| **User-visible prompt** | System-owned, not customisable: *"Lggr" would like to control this computer using accessibility features.* / *Grant access to this application in Privacy & Security settings, located in System Settings.* Buttons: **Open System Settings** · **Deny**. |
| **Grant location** | System Settings → Privacy & Security → Accessibility |
| **Without it** | `ActivityEvent.windowTitle` is always `nil`. Title-based rules never match. Session summaries name applications but not work items. **Nothing else changes** — application name, bundle identifier, timings, idle detection, context switches and every screen keep working. |
| **File** | `Sources/LggrApp/Services/WindowTitleReader.swift` [P3] |

Four properties of this API the implementation must respect:

1. **There is no `NSAccessibilityUsageDescription` on macOS.** It is not a TCC usage-string
   permission; the key changes nothing about the prompt. `Resources/Info.plist` currently carries it;
   it is kept as harmless self-documentation for a reader of the bundle (Appendix A, C11), and the
   real explanation lives in the onboarding screen, which is where it belongs.
2. **The prompt appears at most once per code identity.** After the user dismisses it, further calls
   to `AXIsProcessTrustedWithOptions(prompt: true)` return `false` silently and show nothing. The API
   cannot nag even if we misused it — but it also means the UI must switch from "Enable window
   titles" to **Open System Settings** once `didRequestAccessibilityPrompt` is set.
3. **Trust is revocable while the app runs.** Poll `AXIsProcessTrusted()` (cheap, no prompt) on
   `NSApplication.didBecomeActiveNotification` and once per activity-capture cycle. **Never cache the
   answer for the lifetime of the process.**
4. **Trust is keyed to the code signature**, and ad-hoc signing changes it on every rebuild. Use a
   self-signed `Lggr Dev` identity for Phase 3 work (§ 3.9.3).

Additional capture-time rules, from R5: set a 0.25 s `AXUIElementSetMessagingTimeout` on every element
we create; read once per application switch, never on a timer, never in a retry loop; and skip title
capture entirely while `IsSecureEventInputEnabled()` is true.

#### 6.1.2 Automation / Apple Events — browser domain

| | |
|---|---|
| **Why** | SPEC § 4: *browser domain when technically and securely possible*; SPEC § 5 wants `GitHub → Code review`, `YouTube → Distraction`. Without a domain, all browser time is one undifferentiated block. Window titles do **not** contain the URL in any major browser, so Apple Events is the only path. |
| **Frameworks** | `Foundation` (`NSAppleScript`, `NSAppleEventDescriptor`), `AppKit` |
| **Status check (never prompts)** | `AEDeterminePermissionToAutomateTarget(&targetDesc, typeWildCard, typeWildCard, false)` → `noErr` = granted, `errAEEventNotPermitted` (−1743) = denied, `errAEEventWouldRequireUserConsent` (−1744) = not determined, `procNotFound` (−600) = browser not running |
| **Request (prompts)** | the same call with `askUserIfNeeded: true`, or simply executing the first `NSAppleScript` against that target |
| **Info.plist key** | **`NSAppleEventsUsageDescription`** (required) |
| **Entitlement** | **`com.apple.security.automation.apple-events`** = `true` (required because we sign with `--options runtime`) |
| **User-visible prompt** | *"Lggr" wants access to control "Safari". Allowing control will provide access to documents and data in "Safari", and to perform actions within that app.* — followed by our usage string. Buttons: **Don't Allow** · **OK**. |
| **Grant location** | System Settings → Privacy & Security → Automation → Lggr → *(per target app)* |
| **Without the Info.plist key** | **The process is killed** by TCC on the first Apple Event with *"This app has crashed because it attempted to access privacy-sensitive data without a usage description."* A hard crash, not a denial. |
| **Without the entitlement** (hardened runtime on) | Every Apple Event fails with `errAEEventNotPermitted`; no prompt is ever shown. |
| **Without user consent** | `ActivityEvent.domain` is `nil`. `RuleMatchType.domain` rules never match. Browser time is attributed to the browser application only. Everything else is unaffected. |
| **File** | `Sources/LggrApp/Services/BrowserDomainReader.swift` [P3] |

Consent is granted **per (Lggr, target browser) pair**. Safari and Google Chrome are two separate
prompts, tracked separately in `UserPreferences.browserAutomation`.

Scripts used, and nothing else:

```applescript
-- Safari
tell application "Safari" to return URL of front document

-- Chromium family (Google Chrome, Brave Browser, Microsoft Edge, Arc, Chromium)
tell application "Google Chrome"
    if (mode of front window) is "incognito" then return ""
    return URL of active tab of front window
end tell
```

- **Firefox exposes no scriptable URL.** It is never queried; browser time in Firefox stays
  application-level. Documented, not worked around.
- **Chromium private windows are detected and skipped** via `mode of front window`. Safari and Firefox
  offer no equivalent property — Lggr cannot detect their private windows, and **says so in the
  privacy statement** rather than implying protection it does not have.
- **The full URL is never stored and never leaves the reader.** The returned string goes immediately
  into a pure `LggrKit` function and only its host survives:

  ```swift
  // Sources/LggrKit/Domain/DomainExtractor.swift  [P3]
  public struct DomainExtractor: Sendable {
      /// Returns the lowercased host with a leading "www." removed.
      /// Path, query, fragment, port, username and password are discarded and never returned.
      /// Returns nil for non-http(s) schemes, for `about:`/`chrome:`/`file:` URLs, and for
      /// anything that does not parse.
      public static func host(from urlString: String) -> String?
  }
  ```

  Unit-tested in `DomainExtractorTests`: query strings, credentials in the authority, IDN hosts,
  `file://`, `about:blank`, `chrome://newtab`, and the empty string.
- **Rate limit.** The browser is queried at most once per app activation, plus once every 15 seconds
  while it stays frontmost. Never when tracking is paused, never for a private or excluded browser,
  never when `trackBrowserDomains` is off.
- **Concurrency.** `NSAppleScript.executeAndReturnError` is synchronous IPC that can block for seconds
  if the target is busy or a consent sheet is up. `BrowserDomainReader` is therefore declared `actor`,
  not `@MainActor` — the single documented exception to § 3.8.1's app-wide main-actor rule. It owns
  one cached compiled `NSAppleScript` per browser, serialises calls, and returns a `Sendable String?`.

#### 6.1.3 Notifications

| | |
|---|---|
| **Why** | SPEC § Notifications: session completed, optional halfway reminder, long idle period. |
| **Framework** | `import UserNotifications` |
| **Status check** | `await UNUserNotificationCenter.current().notificationSettings().authorizationStatus` |
| **Request** | `try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` |
| **Info.plist key / entitlement** | **None.** Sandbox-compatible. |
| **User-visible prompt** | *"Lggr" Would Like to Send You Notifications.* Buttons: **Don't Allow** · **Allow**. |
| **Grant location** | System Settings → Notifications → Lggr |
| **Without it** | The three notification kinds are silently skipped. The menu bar icon still changes to `questionmark.circle` when a planned duration elapses, and the review sheet is presented the next time the popover or main window is opened. **No work is lost.** |
| **File** | `Sources/LggrApp/Services/NotificationService.swift` [P6] |

- `UNUserNotificationCenter.current()` **traps if the process is not a bundled application with a
  bundle identifier** — one of the reasons `.build/debug/LggrApp` must never be launched directly.
- `.badge` is **not** requested. Lggr never badges its Dock icon.
- **`.provisional` was considered and rejected.** Provisional authorisation delivers without a prompt,
  but only quietly into Notification Center. A "your 50 minutes are up" alert that never appears on
  screen is worse than no alert at all, and the silent grant is a worse consent story than one honest
  question asked once.
- Only three of SPEC's four notification kinds exist in the MVP, matching the three toggles in
  `UserPreferences`. *Planned session start* requires scheduled sessions, which are not in the data
  model.

#### 6.1.4 Launch at login

| | |
|---|---|
| **Why** | `UserPreferences.launchAtLogin`. A menu-bar timer that is not running has not tracked anything. |
| **Framework / API** | `ServiceManagement`; `SMAppService.mainApp.status`, `.register()`, `.unregister()` |
| **Info.plist key / entitlement** | **None** for the `mainApp` variant. |
| **User-visible prompt** | No prompt. macOS posts a system notification *"Lggr" was added.* and the row appears in System Settings → General → Login Items. |
| **Statuses to handle** | `.enabled`, `.notRegistered`, `.requiresApproval` (show *Enable in System Settings* and call `SMAppService.openSystemSettingsLoginItems()`), `.notFound` |
| **File** | `Sources/LggrApp/Services/LaunchAtLoginService.swift` [P6] |

`register()` throws (commonly when the app is unsigned, or running from a quarantined or temporary
location). The error is handled explicitly: the toggle reverts and an inline caption appears —
*Couldn't add Lggr to your login items. Move Lggr to your Applications folder and try again.*
Registering from `build/Lggr.app` inside the repository works but breaks the moment the folder moves;
the caption is not hypothetical.

#### 6.1.5 Global hot key — deliberately permission-free

`GlobalShortcutService` [P6] uses Carbon `RegisterEventHotKey` / `InstallEventHandler`. This is the
only system-wide hot key API that requires **no** authorisation.

The alternative, `NSEvent.addGlobalMonitorForEvents(matching:handler:)`, silently delivers nothing
unless the app is an Accessibility client. Using it would make ⌘⇧Space depend on Accessibility, which
would quietly turn an optional permission into a required one and destroy the permission ladder in
§ 6.3. **This is the entire justification for the one Carbon file in the codebase.**

#### 6.1.6 What Lggr never requests, and why that is a design decision

| Not requested | Would give us | Why we refuse |
|---|---|---|
| **Screen Recording** | Window titles via `CGWindowListCopyWindowInfo(_, kCGWindowName)` — a *working alternative* to Accessibility | It also grants pixel access to every window on the display. Asking for the ability to see the screen in order to read a string is disproportionate, and the prompt reads as surveillance. We take the narrower permission even though it is the harder one to explain. |
| **Input Monitoring** | `CGEvent.tapCreate` — keystroke and mouse event contents | SPEC § 4 explicitly forbids capturing keystrokes. Idle detection uses `CGEventSource.secondsSinceLastEventType`, which returns *how long since* an event, never the event, and needs no permission. |
| **Full Disk Access** | Reading other apps' data | No feature needs it. |
| **Network client / server** | Anything remote | Principles 9 and 10. Both keys are present in `Lggr.entitlements` and explicitly `false`, so the absence of networking is a reviewable property of the build rather than a claim. |
| **Calendar, Contacts, Reminders, Photos, Microphone, Camera, Location** | — | No feature needs any of them. **Lggr should never appear in those panes of System Settings.** |

Consolidated `Info.plist` and entitlement tables are in § 3.9.4 and § 3.9.5.

### 6.2 App Sandbox — the recommendation

**Recommendation: ship Lggr unsandboxed, with the hardened runtime, Developer ID signed and notarised,
distributed outside the Mac App Store.**

**What is sandbox-safe.** `NSWorkspace.frontmostApplication` and `didActivateApplicationNotification`;
`CGEventSource.secondsSinceLastEventType`; `UNUserNotificationCenter`; `SMAppService.mainApp`; Carbon
`RegisterEventHotKey`; all file I/O in our own container; `NSSavePanel` export with
`com.apple.security.files.user-selected.read-write`. That is the whole of Tier 0 in § 6.3 plus
notifications and launch-at-login.

**What is not.** Reading the focused-window title of *another* process requires
`AXUIElementCreateApplication(pid)` against a target outside our container. Apple's position is that
applications which inspect or control other applications are not sandboxable; the calls fail with
`kAXErrorAPIDisabled` / `kAXErrorCannotComplete` even when `AXIsProcessTrusted()` returns `true`.
Apple Events under the sandbox require a `com.apple.security.temporary-exception.apple-events` array
naming each target bundle identifier — a Mac App Store review flag, brittle across browser releases,
and impossible to extend to a browser we did not enumerate at build time.

**Why not sandbox and simply drop those two features.** Because they *are* the product. SPEC's own
example of a good summary is *"Worked primarily in Xcode and Terminal on receipt deduplication.
Reviewed one GitHub pull request"* — the work item comes from a window title and the *GitHub* comes
from a domain. Without them Lggr answers "which applications did I have open" instead of "what did I
work on", and SPEC's promise that the user can *"open the app on Friday and immediately see evidence
of what they delivered"* does not survive. SPEC says *"sandboxed where practical"*. With title capture
in scope, it is not practical.

**What we owe the user in exchange for the missing sandbox badge.** Five things, each verifiable:

1. **No network code at all.** No networking framework is linked and no request is made. Provable with
   `otool -L`, declared `false` in the entitlements, and stated in the README.
2. **A readable, documented, deletable storage location** (§ 6.8.1). No hidden database, no keychain
   items, no `/Library` writes, no launch agent, no helper process, no XPC service.
3. **Both high-risk captures are opt-in and independently switchable**, and neither is even *attempted*
   without both permission and preference (§ 6.7).
4. **A full degradation path** (§ 6.3) that leaves a genuinely useful app when everything is denied.
5. **Hardened runtime, Developer ID signature and notarisation** for any distributed build. For a
   non-App-Store utility that is the real trust signal, and it is what Gatekeeper actually checks.

**The sandboxed build is kept buildable, not shipped.** Flipping `com.apple.security.app-sandbox` to
`true` and adding `com.apple.security.files.user-selected.read-write` produces a build that is exactly
**Tier 0 + N + L** from § 6.3 — everything except window titles and browser domains. Keeping that
configuration one line away means the degraded mode is a real code path we can build and test, not a
paragraph.

### 6.3 The permission ladder

Read this table as: *everything above stays working when the row below is denied.* Denying a lower row
never disables an upper row. **There is no combination of denials that produces a broken app.**

| Tier | Requires | Unlocks | What is lost without it | Asked for when |
|---|---|---|---|---|
| **0 — Zero permissions** *(the default; a complete product)* | Nothing | • Projects, focus sessions, intended outcome, work type, 25/50/custom/open-ended durations<br>• Pause, resume, finish, result status, generated + editable summary<br>• Menu bar timer and popover, global hot key ⌘⇧Space, full keyboard workflow<br>• **Automatic per-application tracking**: frontmost app name + bundle id via `NSWorkspace`<br>• **Idle detection** via `CGEventSource` → focused vs idle time<br>• **Context switches** counted at application granularity<br>• Classification by `.application` and `.applicationName` rules<br>• Interruption inbox, accomplishment log, Today, weekly outcomes, weekly review, insights<br>• All exports; all data persisted | — | — |
| **1 — Accessibility** | System Settings → Privacy & Security → Accessibility | • `ActivityEvent.windowTitle` populated<br>• `windowTitleContains` rules match<br>• Timeline rows read *"Xcode — ReceiptDeduplication.swift"* instead of *"Xcode"*<br>• `SessionSummaryBuilder` can name the work item, not just the app | Titles are `nil`; title rules never match; summaries name applications only | Onboarding screen 3, **or** the Settings → Privacy toggle, **or** one dismissible banner. Never otherwise. |
| **2 — Automation** *(per browser)* | Automation consent for that specific browser | • `ActivityEvent.domain` populated for that browser<br>• `domain` rules match → *GitHub → Code review*, *YouTube → Distraction*<br>• Browser time splits by site in Today and the weekly review | Domains are `nil`; all browser time is one block attributed to the browser | Onboarding screen 4, **or** the Settings → Privacy per-browser toggle, **or** the same single banner. Never otherwise. |
| **N — Notifications** *(orthogonal)* | Notification authorisation | Session-completed, halfway and long-idle alerts | Alerts are skipped; the menu bar icon still changes state and the review sheet appears on next open | Onboarding screen 5, **or** the first session start if onboarding was skipped, **or** a Settings toggle. Once, ever. |
| **L — Launch at login** *(orthogonal)* | `SMAppService` registration | Lggr is running when the user starts working | The user launches it themselves | Only from the Settings toggle. |

Tier 2 depends on Tier 1 for *nothing*: a user may grant Automation and refuse Accessibility, and
domains will be captured while titles stay `nil`. The onboarding order is a narrative convenience, not
a dependency.

**Testing the ladder without touching TCC.** The app reads `LGGR_PERMISSIONS` from the process
environment in debug builds and, when present, injects `StubPermissionsService` with a forced tier:

```bash
LGGR_PERMISSIONS=none    ./Scripts/run.sh     # Tier 0
LGGR_PERMISSIONS=ax      ./Scripts/run.sh     # Tier 0 + 1
LGGR_PERMISSIONS=ax+ae   ./Scripts/run.sh     # Tier 0 + 1 + 2
LGGR_PERMISSIONS=all     ./Scripts/run.sh     # everything
```

For the real thing, reset actual grants between manual tests:

```bash
tccutil reset Accessibility com.luisdoriz.lggr
tccutil reset AppleEvents   com.luisdoriz.lggr
tccutil reset All           com.luisdoriz.lggr
defaults delete com.luisdoriz.lggr            # clears UserPreferences, re-arms onboarding
```

### 6.4 The PermissionsService contract

`File: Sources/LggrApp/Services/PermissionsService.swift` [P6, with `StubPermissionsService`
available from P2 so the gallery can render every permission state]

```swift
import Foundation

public enum PermissionStatus: String, Sendable, CaseIterable {
    /// Granted and usable right now.
    case granted
    /// The user has refused, or the system refuses on their behalf.
    case denied
    /// Never asked. Only this state may trigger a system prompt.
    case notDetermined
    /// Not applicable on this machine (e.g. the browser is not installed).
    case unavailable
}

@MainActor
public protocol PermissionsProviding: AnyObject {

    // Accessibility
    var accessibility: PermissionStatus { get }
    /// Non-prompting refresh. Safe to call on every app activation and every capture cycle.
    func refreshAccessibility()
    /// Shows the system prompt. MUST be called only from a control the user just pressed.
    func requestAccessibility()
    func openAccessibilitySettings()

    // Automation, per target browser bundle identifier
    func automation(forBundleIdentifier id: String) -> PermissionStatus
    /// Non-prompting: AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)
    func refreshAutomation(forBundleIdentifier id: String)
    /// Shows the system prompt for that one target. User-action only.
    func requestAutomation(forBundleIdentifier id: String) async -> PermissionStatus
    func openAutomationSettings()

    // Notifications
    var notifications: PermissionStatus { get }
    func refreshNotifications() async
    /// UNUserNotificationCenter.requestAuthorization. User-action only, at most once.
    func requestNotifications() async -> PermissionStatus
    func openNotificationSettings()
}
```

**Deriving `notDetermined` for Accessibility.** `AXIsProcessTrusted()` returns only `true` or `false`;
the API has no third state. `SystemPermissionsService` therefore reports:

```
AXIsProcessTrusted() == true                          → .granted
AXIsProcessTrusted() == false && !didRequestAXPrompt  → .notDetermined
AXIsProcessTrusted() == false &&  didRequestAXPrompt  → .denied
```

where `didRequestAXPrompt` is the persisted `UserPreferences.didRequestAccessibilityPrompt`. This
distinction is what lets the UI say *"Enable window titles"* the first time and *"Open System
Settings"* afterwards — which matters, because macOS will not show the prompt twice.

**System Settings deep links.** Stable across macOS 14–26 but undocumented. Every one is opened with
`NSWorkspace.shared.open(_:)` and its `Bool` result checked; on `false` we fall back to opening System
Settings at its top level and the caption reads *Open System Settings → Privacy & Security →
Accessibility.* No force unwraps, no silent failure.

| Target | URL |
|---|---|
| Accessibility | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| Automation | `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` |
| Notifications | `x-apple.systempreferences:com.apple.preference.notifications` |
| Login Items | `SMAppService.openSystemSettingsLoginItems()` (a real API, not a URL) |

### 6.5 Onboarding

Six screens in a single `OnboardingWindow` (`Sources/LggrApp/Views/Onboarding/` [P6]) — **560 × 460**,
`.hiddenTitleBar`, no sidebar, no Dock-level modality. Not a sheet: it is the first thing the user
sees, and it should own the screen rather than hover over an empty app. One idea per screen, **one
primary action per screen**, a visible **Skip** on every permission screen.

Shown once, gated on `UserPreferences.hasCompletedOnboarding`. Reachable again from **Help → Show
Welcome…**. Reaching the last screen sets the flag regardless of how much was skipped. Closing the
window early also sets it — a user who closes an onboarding window has told us something.

Screen 4 is **omitted entirely** if no scriptable browser is installed
(`NSWorkspace.urlForApplication(withBundleIdentifier:)` returns `nil` for all of Safari, Chrome,
Brave, Edge, Arc, Chromium). Never ask for something that cannot be used.

**Progress** is six 6pt dots. No numbers, no percentage, no "Step 2 of 6". ⌘↩ advances. **`Esc` on any
page is equivalent to `Skip setup` and asks nothing — onboarding you cannot escape from is a dark
pattern.**

#### Screen 1 — Welcome

> ### Lggr
> **A record of what you actually worked on.**
>
> Start a focus session in under five seconds, and Lggr fills in the rest — what you worked in, how
> long, how often you were pulled away, and what you finished.
>
> It takes about a minute to set up.

**Primary:** `Continue` · **Tertiary, bottom-left:** `Skip setup`

#### Screen 2 — What Lggr records

This screen requests nothing. It is the honest disclosure, and it comes *before* the first ask.

> ### Everything stays on this Mac
>
> **What Lggr records**
> - The application you're using, and when you switched
> - How long you were away from the keyboard
> - The focus sessions, notes and accomplishments you write yourself
> - Optionally, the title of your current window and the domain of your current browser tab — only
>   if you turn those on in the next two steps
>
> **What Lggr never records**
> - Keystrokes or passwords
> - Screenshots or screen contents
> - The contents of documents, messages or email
> - Your clipboard
> - Full web addresses — only the domain, never the page
>
> **Where it lives**
> One folder in your home directory: `~/Library/Application Support/Lggr`. Lggr has no account, no
> server and no network code. Nothing is uploaded, because there is nothing to upload to.
>
> **You stay in control**
> Pause tracking any time from the menu bar. Hide any app from tracking, or record it as
> "Private activity" with no name attached. Delete a session, a day, or everything — and export it
> first if you want to keep a copy.

**Primary:** `Continue`

#### Screen 3 — Window titles (Accessibility)

> ### See what you worked on, not just where
>
> With permission, Lggr reads the **title of the window you're working in** — the file in your editor,
> the pull request in your browser, the document you're writing.
>
> That's the difference between:
>
> > Chrome — 42 minutes
>
> and
>
> > Reviewed the receipt deduplication pull request — 42 minutes
>
> macOS calls this **Accessibility**. It's a broad-sounding permission with a narrow use here: Lggr
> reads one string, the title of the frontmost window. It does not read your keystrokes, your screen,
> or the contents of anything.
>
> You can turn this off at any time in Settings → Privacy, and revoke it in System Settings.

**Primary:** `Enable window titles` — calls `permissions.requestAccessibility()`, one of only three
places in the app where the system prompt is fired.
**Secondary:** `Not now` — advances. `trackWindowTitles` stays `true` so the feature turns itself on
if the permission is ever granted later; nothing is captured until it is.

*After the prompt is dismissed, the screen updates in place rather than advancing:*

- **Granted** → a `checkmark.circle` and *Window titles are on. You can turn them off in Settings →
  Privacy.* Primary becomes `Continue`.
- **Not granted** → *No problem — Lggr will track applications and timings without them.* Primary
  becomes `Continue`; a quiet secondary `Open System Settings…` appears. **We do not re-prompt, and we
  do not repeat the pitch.**

#### Screen 4 — Browser domains (Automation) *(only if a scriptable browser exists)*

> ### Tell your browser time apart
>
> Browser time is usually several different jobs wearing one icon. With permission, Lggr asks
> **Safari** and **Chrome** for the domain of the tab you're on, so that `github.com` can count as
> code review and `youtube.com` doesn't.
>
> **Only the domain is stored** — `github.com`, never the full address, never the page title from the
> tab, never the contents. Private and Incognito windows in Chrome are skipped entirely.
>
> macOS will ask you separately for each browser, and the wording it uses is broad. Lggr sends exactly
> one command to each: *what is the address of the front tab?*

**Primary:** `Enable for Safari` / `Enable for Chrome` — one button per installed browser, each firing
that browser's prompt on click, each showing its own result inline.
**Secondary:** `Not now`

*After each prompt:* granted → `checkmark.circle` next to that browser. Denied → *Skipped. Browser
time will be tracked as "Safari".* **Never re-asked.**

#### Screen 5 — Notifications

> ### A quiet nudge when time's up
>
> Lggr can let you know when a session finishes, when you've been away from the keyboard for a while,
> and — if you want it — at the halfway mark.
>
> Three notifications, all optional, all switchable in Settings. No badges, no streaks, no reminders
> to be more productive.

**Primary:** `Enable notifications` · **Secondary:** `Not now`

If skipped, the request is made once, later, **immediately after the user's first focus session has
already started** — so it can never sit between the user and the five-second start path — and never
again.

#### Screen 6 — Your first project

> ### One last thing
>
> Focus sessions belong to a project. Name the thing you spend most of your time on; you can add more
> later.

A single text field with the placeholder *e.g. Receipt ingestion*, the nine-colour picker from
`Project.colorIDs`, and the icon row from `Project.iconIDs`.

**Primary:** `Start using Lggr` (disabled until the field is non-empty)
**Secondary:** `Skip` — creates a project named **General**, so the user is never dropped into an app
with an empty required picker.

On completion: `hasCompletedOnboarding = true`, the window closes, the main window opens on Today.

**Error handling on this flow:** the shortcut recorder and project creation are the only failure
points; both show a `Type.caption` `.secondary` inline line and **leave the primary button enabled**,
because a hot-key conflict or a store hiccup must not block onboarding.

### 6.6 The re-ask policy, exactly

The rules below are absolute. Any code that prompts must be traceable to one of these.

1. **Never on launch. Never on a timer. Never on session start. Never on window focus. Never after an
   update.**
2. **A system prompt may only be fired from a control the user pressed in the same interaction.**
   Exactly three call sites exist in the app, and `Scripts/check-layering.sh` greps for them:
   - the `OnboardingPermissionScreen` primary button
   - the `PrivacySettingsView` toggle transitioning off → on
   - the `PermissionBanner` primary button (rule 4)
3. **Once per permission, ever, from the app's side.** After `requestAccessibility()` has been called
   once, `didRequestAccessibilityPrompt` is persisted and every subsequent affordance becomes *Open
   System Settings*, which navigates rather than prompts. Same for
   `didRequestNotificationAuthorization`. Automation is once **per browser**.
4. **Exactly one dismissible banner per permission, for the lifetime of the installation.** It appears
   at the top of the Today view — never as a modal, never in the menu bar popover, never during an
   active session — when **all** of these hold:
   - the permission is `.notDetermined` or `.denied`, **and**
   - the user has finished **at least three** focus sessions (they have enough context to judge), **and**
   - `didDismissAccessibilityBanner` / `didDismissAutomationBanner` is `false`, **and**
   - no other permission banner is currently visible.

   Accessibility banner copy:

   > Lggr is tracking applications and timings. Turning on window titles would let it name what you
   > worked on.
   > `Enable window titles`   `Not interested`

   `Not interested` sets the dismissal flag permanently. **The banner never returns.** Not on the next
   launch, not next week, not after twenty sessions. The only remaining route is Settings → Privacy,
   which the user goes to on purpose.
5. **A denial is a decision, not a state to be recovered from.** The word *"Denied"* never appears in
   the UI; the Settings row reads *Off* with a quiet *Open System Settings…* link. No red, no warning
   triangle, no "reduced functionality" nag.
6. **Detecting a grant made outside the app.** `refreshAccessibility()` runs on
   `NSApplication.didBecomeActiveNotification`. If the status flips to `.granted` while System Settings
   is open, the row animates to *On* and window-title capture begins on the next interval — no
   relaunch, no confirmation dialog, no toast.

### 6.7 Private and excluded applications

#### 6.7.1 Three levels of control, and the exact difference

This is the mental model the Settings screen teaches, in this order:

| Control | Recorded? | What the day shows |
|---|---|---|
| **Pause tracking** (`trackingPaused`) | Nothing, for any app | The whole period is absent. The session clock keeps running if a session is open. |
| **Excluded application** (`excludedApplications`) | No event at all for that app | A gap. Time appears under **Untracked**; the app's existence is never written to disk. |
| **Private application** (`privateApplications`) | An event with no identity | An anonymous **Private activity** block on the timeline with real start and end times. |

Said plainly for the Settings caption: *Pausing hides that you were working. Excluding an app hides
that you used it. Marking it private records that you were busy, without recording what you were
doing.*

#### 6.7.2 Excluded vs private, field by field

| | **Excluded** | **Private** |
|---|---|---|
| `ActivityEvent` created | **No** | Yes |
| Window title read from the AX API | **Never called** | **Never called** |
| Browser URL requested via Apple Events | **Never called** | **Never called** |
| `applicationName` on disk | — | `"Private activity"` (`ActivityEvent.privatePlaceholder`) |
| `bundleIdentifier` on disk | — | `""` |
| `windowTitle` on disk | — | `nil` |
| `domain` on disk | — | `nil` |
| `category` on disk | — | `.unknown` |
| `classificationSource` on disk | — | `.unclassified` |
| `startedAt` / `endedAt` / `isIdle` on disk | — | Preserved |
| Counts toward total tracked time | **No** | Yes |
| Counts toward focused / reactive / category totals | No | No (`.unknown` counts as neither) |
| Counts as a context switch | **No** | Yes |
| Classification rules evaluated | n/a | No — `ClassificationRule.matches` returns `false` for `event.isPrivate` |
| Appears on the timeline | No | Yes, unnamed |
| Reversible | Nothing was ever written | The original was never written |

**Precedence:** if a bundle identifier appears in both lists, **excluded wins.** It is the stronger
guarantee, and a user who put an app in both lists meant the stronger one.

**Both lists are empty by default.** Lggr ships with no opinion about which of the user's applications
are sensitive. The Settings screen offers a one-click *Suggest…* that proposes password managers,
banking apps and messaging apps found on the machine — as **checkboxes the user must tick**, never
pre-applied.

#### 6.7.3 The excluded-application gap, and the bug it would otherwise cause

The obvious implementation — "skip excluded apps" — silently attributes the excluded time to whichever
app was frontmost before, because the previous interval is still open. That would be both a wrong
number and a privacy failure. The rule:

> **When the frontmost application is excluded, the tracker closes the open interval at the switch
> instant and opens no new interval.** A new interval opens only when a non-excluded application
> becomes frontmost.

Worked example — 1Password is excluded:

```
09:00  Xcode becomes frontmost         → open interval A (Xcode, startedAt 09:00)
09:12  1Password becomes frontmost     → close A at 09:12.  No interval opened.
09:14  Xcode becomes frontmost         → open interval B (Xcode, startedAt 09:14)
09:30  session finished

Session elapsed         30:00     (09:00 → 09:30, no pauses)
Sum of activity         28:00     (A = 12:00, B = 16:00)
Untracked                2:00     shown as "Untracked" on Today — never added to Xcode
Context switches             0     Xcode → Xcode
```

Two consequences that must be preserved:

1. **`ActivityCoalescer` must not merge across a gap.** *Adjacent* means **touching**: merge A and B
   only when `B.startedAt - A.endedAt <= 2 seconds` (the switch-notification latency allowance).
   Merging across the 2-minute hole above would absorb the excluded application's time into Xcode and
   destroy the exclusion. Named unit test:
   `ActivityCoalescerTests.doesNotMergeAcrossAnExcludedGap`.
2. **Context switches are counted at 0, and that is deliberate.** Counting the round trip as two
   switches would put a number on screen that only makes sense if something happened in between —
   telling the user's screenshot, or anyone reading over their shoulder, that an unnamed application
   ran. Exclusion hides *what*; a gap in the timeline still reveals *that*. A user who wants to hide
   *that* pauses tracking. This trade-off is stated in the privacy statement rather than hidden.

#### 6.7.4 Redaction is enforced at capture — four mechanisms, in order

The requirement is that this must be *impossible to get wrong later*, not merely documented. Four
independent mechanisms, arranged so that any single one failing still yields a correct file on disk.

**Mechanism 1 — a separate capture type, so a title cannot reach the store by accident.**

`ActivityTrackingService` never constructs an `ActivityEvent`. It accumulates `ActivitySample`
(§ 4.2.5, deliberately not `Codable`), and the only sanctioned conversion is a pure function that
takes the preferences with it:

```swift
// Sources/LggrKit/Domain/PrivacyRedactor.swift  [P3]
public struct PrivacyRedactor: Sendable {

    /// The ONLY sanctioned way to turn captured data into a persistable event.
    /// Returns nil when the application is excluded — there is nothing to store.
    /// Returns a fully redacted event when the application is private.
    public static func event(
        from sample: ActivitySample,
        preferences: UserPreferences,
        focusSessionID: UUID?
    ) -> ActivityEvent?

    /// True when the tracker must not read a title or a URL for this bundle identifier.
    /// Consulted BEFORE the AX / Apple Event call, never after.
    public static func mustNotInspect(
        bundleIdentifier: String,
        preferences: UserPreferences
    ) -> Bool
}
```

**Mechanism 2 — a private application's title and URL are never read in the first place.**

This is the primary guarantee, and it is stronger than `redactedIfPrivate()` alone. Redaction is not
*capture then strip*; it is *do not capture*. The exact capture pipeline — **the order is the
mechanism**:

```
frontmost-app change, or idle threshold crossed
 1. close the open interval at t                              (always, even if paused)
 2. if preferences.trackingPaused                → stop. No new interval.
 3. if preferences.isExcluded(bundleID)          → stop. No new interval.      ← EXCLUSION FIRST
 4. open ActivitySample(app, bundleID, startedAt: t)
 5. if PrivacyRedactor.mustNotInspect(bundleID, preferences)
        → do NOT call WindowTitleReader
        → do NOT call BrowserDomainReader                                      ← NEVER READ
    else
        → if trackWindowTitles && permissions.accessibility == .granted
              && !IsSecureEventInputEnabled()
              sample.windowTitle = WindowTitleReader.focusedTitle(pid:)
        → if trackBrowserDomains && isBrowser && automation(for: bundleID) == .granted
              sample.domain = await BrowserDomainReader.host(for: bundleID)
 6. on close: PrivacyRedactor.event(from:preferences:focusSessionID:) → ActivityEvent?
 7. buffer; on flush, re-evaluate exclusion against the CURRENT preferences
 8. store.saveActivityEvents(events)
```

Step 7 gives **retroactive exclusion for anything still in the buffer**: a user who adds an app to the
excluded list mid-session drops the not-yet-written events for that app. Step 5 means a private app's
title never exists as a `String` in this process — it is not read, not held, not logged, not passed to
a formatter.

**Mechanism 3 — the write boundary re-asserts the invariant.**

Callers can be wrong; the last function before the bytes hit the disk cannot be. **Every** conformer
of `LggrStore` re-applies redaction on entry:

```swift
public func saveActivityEvents(_ events: [ActivityEvent]) async throws {
    // Idempotent: redactedIfPrivate() is a no-op on an already-redacted event and on a
    // non-private one. Applying it here means no code path in the application, present or
    // future, can write a private application's title or bundle identifier to disk.
    let safe = events.map { $0.redactedIfPrivate() }
    ...
}
```

Required in `JSONFileStore`, `InMemoryStore` **and** `SwiftDataStore`, and asserted by the shared
`LggrStoreContractTests`: construct an `ActivityEvent` with `isPrivate == true` and a populated
`windowTitle`, `bundleIdentifier`, `domain` and `category`; save it through each backend; read it
back; assert the title and domain are `nil`, the bundle identifier is `""`, the name is
`"Private activity"` and the category is `.unknown`.

**Mechanism 4 — mechanical guards, so review is not the safety net.**

- `check-layering.sh` fails the build on the two greps listed in § 3.4 (`windowTitle:` outside its
  permitted files; `AXUIElementCopyAttributeValue` / `NSAppleScript` outside their two readers).
- `ActivityEvent` conforms to `CustomDebugStringConvertible` printing
  `ActivityEvent(Xcode, 09:00–09:12, private: false)` and **never** the title or domain (§ 4.2.5).
- **No `os_log`, `print` or `NSLog` call ever takes `windowTitle` or `domain` as an argument**, at any
  level, public or private. There is no diagnostic value that justifies the risk.

#### 6.7.5 Changing the lists does not rewrite history — and we say so

Marking an application private or excluded applies **from the next captured interval onward**. Events
already on disk are not rewritten or deleted. The confirmation says exactly that:

> **Mark Slack as private?**
> From now on, time in Slack will be recorded as "Private activity" with no name and no window title.
> Records already saved are not changed. To remove them, use **Delete all activity history** in
> Settings → Privacy.
> `Cancel`   `Mark as private`

This is a deliberate MVP boundary (§ 2.4). A retroactive per-application purge would need a new store
method and a progress UI for a case that arises about once per install; the copy is written so that
shipping without it is not misleading.

### 6.8 Data lifecycle

#### 6.8.1 Where the store lives

Unsandboxed, so this is the real path with no container indirection:

```
~/Library/Application Support/Lggr/
└── store.json          ← one StoreSnapshot root, schemaVersion: Int
```

Under Xcode with `LGGR_SWIFTDATA=1`, `SwiftDataStore` replaces `store.json` with a SQLite store in the
same directory. The directory, the permission rules below, and every delete operation in this section
are identical either way.

Preferences are **not** here: `UserPreferences` is one JSON blob in `UserDefaults` under
`com.lggr.userPreferences.v1`, backed by `~/Library/Preferences/com.luisdoriz.lggr.plist`.

**File permissions are set explicitly, not left to the umask.** Unsandboxed, the default umask
produces `0755` directories and `0644` files, readable by every other local account on the Mac. That
is unacceptable for a file containing window titles:

- the directory is created with `[.posixPermissions: 0o700]`;
- `AtomicFileWriter` sets `[.posixPermissions: 0o600]` on the temporary file **before**
  `FileManager.replaceItemAt`, so the replacement inherits it and there is no window in which a
  world-readable copy exists.

Asserted in `JSONFileStoreTests.storeFilesAreOwnerReadableOnly`.

**Backups are honest, not hidden.** `~/Library/Application Support` is included in Time Machine. Lggr
does **not** set `NSURLIsExcludedFromBackupKey`, because losing the log to a disk failure is worse
than having it in a local backup the user controls. It is not synced by iCloud Drive. The privacy
statement says so.

**Settings → Privacy has a `Reveal Data Folder in Finder` button.** The user can open the file, read
it, copy it, and delete it without the app. Being inspectable is the main thing an unsandboxed app can
offer in place of a sandbox badge, and it is also the zero-code lossless backup path.

#### 6.8.2 Retention

`UserPreferences.dataRetentionDays: Int?` — default **90**, `nil` = keep forever. Settings offers
30 / 90 / 180 / 365 days / Keep everything, via
`retentionCutoff(from:calendar:)`.

**Retention prunes `ActivityEvent` and nothing else.** This is the most important sentence in this
section. Focus sessions, accomplishments, interruptions, weekly outcomes and projects are the user's
authored record and are **never** deleted automatically, at any retention setting, ever. It is why
`deleteActivityEvents(startedBefore:)` is the only date-based delete on `LggrStore`. A user who set
"90 days" three years ago and opens Lggr on a Friday still sees every accomplishment they ever logged;
what they lose is the minute-by-minute application trace behind them.

The Settings caption states the scope so nobody has to infer it:

> Activity records older than this are deleted automatically. Your sessions, accomplishments and
> notes are always kept.

#### 6.8.3 The pruning job

`File: Sources/LggrApp/Services/RetentionPruner.swift` [P4]

```swift
@MainActor
final class RetentionPruner {
    private var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor [weak self] in
            // Never on the launch critical path: the UI is up and the first frame is drawn first.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.pruneIfNeeded(reason: .scheduled)
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}
```

Runs on exactly four triggers:

1. **20 seconds after launch** — off the critical path, after the first frame.
2. **Every 6 hours** while the app runs.
3. **On wake** (`NSWorkspace.didWakeNotification`, via the existing `SleepWakeObserver`) if more than
   6 hours have passed since `lastPruneAt`. A Mac that sleeps every night would otherwise never reach
   trigger 2.
4. **Immediately** when the user *lowers* `dataRetentionDays` in Settings, after the confirmation.
   Raising it or choosing "Keep everything" prunes nothing.

Behaviour:

- `guard let cutoff = preferences.retentionCutoff(from: clock.now) else { return }` — `nil` means keep
  forever and the job is a no-op.
- `try await store.deleteActivityEvents(startedBefore: cutoff)`.
- The cutoff is applied to **`startedAt`**, matching the protocol's `startedBefore:` label. An interval
  that began before the cutoff and ended after it is deleted. At a 90-day boundary that is at most one
  interval; splitting an interval at midnight ninety days ago is complexity with no user-visible
  payoff.
- **Idempotent** and safe to run at any time. It cannot touch the currently open interval, which has
  `startedAt == now`.
- Runs whether or not a session is active.
- Writes `lastPruneAt` on success.
- **Failure is never surfaced.** Logged via `os_log` at `.error` with a count and a reason, and retried
  on the next trigger. A user does not need an alert about housekeeping.
- **Never runs during onboarding** — `hasCompletedOnboarding == false` short-circuits it.

#### 6.8.4 Deletion, at five granularities

Every one of these is available from the UI, and every one of them offers an export first (§ 6.8.5).

**a. One session** — `Focus Sessions` → row context menu → *Delete Session*, and the detail view's
toolbar. `store.deleteSession(id:)`. This is the schema's **only cascade**: deleting a session deletes
its `ActivityEvent`s. That is intentional and is exactly the privacy behaviour a user expects.
Accomplishments and interruptions created during it **survive** with their `focusSessionID` nullified,
because they are authored content.

> **Delete this session?**
> The session, its summary and its 1,204 activity records will be removed. The 2 accomplishments you
> logged from it are kept.
> `Cancel`   `Export…`   `Delete`

**b. One session's activity, keeping the session** — detail view → *Delete Activity for This Session*,
via `deleteActivityEvents(sessionID:)`. For the case "I don't want the window titles from that
afternoon, but I want the record of the work." The session keeps its duration, result, summary,
blocker, next step and `interruptionCount`; its timeline strip becomes an empty state reading
*Activity for this session was deleted.*

**c. One day** — Today, and any day in Focus Sessions → *Delete This Day's Activity*, via
`deleteActivityEvents(in:)` with that day's `DateInterval` from `CalendarWindows`. Sessions and
accomplishments for the day are untouched.

**d. All activity history** — Settings → Privacy → *Delete All Activity History*. This is SPEC § 4's
*Delete activity history*, and its scope is exactly its name: `deleteAllActivityEvents()` removes every
`ActivityEvent` and **nothing else**. The confirmation states the count, the span, and — importantly —
what is *lost* as well as what is kept, because "activity history" sounds harmless and the derived
metrics are not:

> **Delete all activity history?**
> This removes **41,208 activity records** covering **87 days**.
>
> **Kept:** every focus session, its summary and result; every accomplishment, interruption, project
> and weekly outcome.
>
> **Lost:** the timeline for past days, and the per-application, per-category and context-switch
> figures calculated from it. Those numbers will read zero for days before today.
>
> This cannot be undone.
> `Cancel`   `Export activity first…`   `Delete 41,208 records`

**e. Everything** — Settings → Privacy → *Delete All Lggr Data*, in a visually separated block at the
bottom of the pane. Removes the entire `~/Library/Application Support/Lggr/` directory, calls
`UserDefaults.standard.removePersistentDomain(forName: "com.luisdoriz.lggr")`, unregisters
`SMAppService.mainApp` if it was registered, and quits. It does **not** touch TCC grants — an app
cannot revoke its own permissions, and the sheet says so.

> **Delete all Lggr data?**
> Every project, session, accomplishment, note and setting will be removed from this Mac, and Lggr
> will quit. Nothing is kept anywhere else, because Lggr has never sent your data anywhere.
>
> The Accessibility and Automation permissions you granted stay in System Settings until you remove
> them there.
> `Cancel`   `Export everything first…`   `Delete everything and quit`

**Deletion order matters: files first, then defaults, then quit** — so an interrupted delete leaves an
app with no data rather than data with no app to read it.

#### 6.8.5 Export before delete

Every destructive confirmation carries an **Export…** button between Cancel and the destructive
action, so the safe path is the one your eye lands on first.

| Action | What Export… writes |
|---|---|
| Delete one session | That session as Markdown (`DailySummaryMarkdown` scoped to one session) |
| Delete a day's activity | That day's summary as Markdown + that day's activity as CSV |
| Delete all activity history | **Activity CSV** for the full range |
| Delete all Lggr data | A folder containing the four SPEC exports (daily summaries, weekly reviews, accomplishment log, sessions CSV) **plus a copy of the raw JSON store** |

`ActivityCSVExporter` (`Sources/LggrKit/Export/ActivityCSVExporter.swift` [P4]) is the one export not
named in SPEC § Export. It exists because it is the *only* export that captures what these dialogs are
about to destroy — offering "export first" and then handing back a file that omits the deleted data
would be a lie. Columns:
`startedAt, endedAt, durationSeconds, applicationName, bundleIdentifier, windowTitle, domain, category, classificationSource, isIdle, isPrivate, focusSessionID`.
Private rows export exactly as stored — `"Private activity"`, empty bundle identifier, empty title —
because there is nothing else to export.

For (e), the raw JSON copy is a plain `FileManager.copyItem`. It is lossless, costs nothing to
implement, and matches what the user could do themselves from *Reveal Data Folder*.

All exports go through `ExportService` → `NSSavePanel`. Unsandboxed, no entitlement is needed; the
sandboxed variant would need `com.apple.security.files.user-selected.read-write`.

#### 6.8.6 Durability around the lifecycle

- `NSSupportsSuddenTermination` = `false` and `NSSupportsAutomaticTermination` = `false` so macOS
  cannot kill the process mid-write.
- `AppDelegate.applicationWillTerminate` flushes the store.
- `JSONFileStore` coalesces writes on a 500 ms debounce and writes atomically via `AtomicFileWriter`
  (temp file + `replaceItemAt`), so a crash leaves either the previous complete file or the new
  complete file — never a truncated one.
- `StoreSnapshot.schemaVersion` guards against a newer file: the MVP refuses to load it and says so
  clearly rather than migrating or, worse, overwriting.

### 6.9 Settings → Privacy

`Sources/LggrApp/Views/Settings/PrivacySettingsView.swift` [P6]. Every control named in SPEC § 4
*Privacy controls*, in this order, so the destructive things are at the bottom:

1. **Tracking** — `Pause tracking` toggle (`trackingPaused`), mirrored in the menu bar popover.
2. **Window titles** — `trackWindowTitles` toggle, with a status row: *On* / *Off* /
   *Off — Accessibility permission needed* + `Enable…` or `Open System Settings…`.
3. **Browser domains** — `trackBrowserDomains` toggle plus one row per installed scriptable browser
   with its own Automation status and action.
4. **Idle threshold** — `idleThreshold`, 1 / 3 / 5 / 10 / 15 minutes.
5. **Private applications** — an editable list with an app picker and a `Suggest…` action.
6. **Excluded applications** — same, with the one-sentence difference restated inline.
7. **Data retention** — `dataRetentionDays` picker with the scope caption from § 6.8.2, and a
   read-only line: *Oldest activity record: 12 March 2026 · 41,208 records · 3.1 MB.*
8. **Your data** — `Reveal Data Folder in Finder`, `Export…`.
9. **Danger zone**, visually separated — `Delete All Activity History`, `Delete All Lggr Data`.

The privacy statement of § 6.11 sits at the top of the pane in a `Card`, above control 1. It is the
first thing on the screen, not a link to a document nobody opens.

### 6.10 Verification checklist

Runnable checks, not intentions.

```bash
# No networking is linked into the binary.
otool -L build/Lggr.app/Contents/MacOS/LggrApp | grep -iE 'CFNetwork|Network\.framework|libcurl'   # expect no output

# The entitlements that actually shipped.
codesign -d --entitlements - build/Lggr.app

# Info.plist is well-formed and carries the Apple Events usage string.
plutil -lint  build/Lggr.app/Contents/Info.plist
plutil -extract NSAppleEventsUsageDescription raw build/Lggr.app/Contents/Info.plist

# Exercise every denial path from a clean slate.
tccutil reset Accessibility com.luisdoriz.lggr
tccutil reset AppleEvents   com.luisdoriz.lggr
defaults delete com.luisdoriz.lggr

# Watch TCC decisions live while clicking through onboarding.
log stream --predicate 'subsystem == "com.apple.TCC"' --info

# Store files are not world-readable.
ls -le ~/Library/Application\ Support/Lggr/     # expect -rw------- and drwx------
```

Manual passes, each done twice — once at Tier 0, once fully granted:

- Complete onboarding declining **every** permission. Run a full session, finish it, log an
  accomplishment, open the weekly review, run all four exports. Nothing is disabled; nothing shows an
  error; **the word "denied" appears nowhere.**
- Grant Accessibility from System Settings **while the app is running**; confirm titles begin appearing
  on the next interval without a relaunch and without a dialog.
- Revoke Accessibility mid-session; confirm titles become `nil`, no crash, no prompt, no banner.
- Mark an app private, use it, quit the app, and `grep store.json` for that app's name, bundle
  identifier and a distinctive window title. **Zero hits is the pass condition.**
- Exclude an app, use it for two minutes inside a session, and confirm: the neighbouring app's total
  did not grow, `Untracked` shows two minutes, and context switches did not increase.
- Set retention to 30 days with older data present; confirm the prune runs, the store shrinks, and
  every session and accomplishment older than 30 days is still listed.
- Delete all activity history; confirm sessions, summaries and accomplishments are intact and the
  timeline is empty.

Unit tests this strategy adds to `Tests/LggrKitTests/`:

| Test file | Covers |
|---|---|
| `PrivacyRedactorTests` | excluded → `nil`; private → all six fields cleared; non-private untouched; excluded-beats-private precedence; case-insensitive bundle matching; `mustNotInspect` |
| `DomainExtractorTests` | host extraction, `www.` stripping, credentials and ports discarded, query/fragment discarded, `file:`/`about:`/`chrome:` → `nil`, malformed input |
| `ActivityCoalescerTests` | `doesNotMergeAcrossAnExcludedGap`, merges within the 2 s tolerance, never merges different bundle identifiers |
| `RetentionTests` | `retentionCutoff` at each setting and at `nil`; prune deletes only `ActivityEvent`; prune is idempotent; prune never touches an open interval |
| `LggrStoreContractTests` *(extended)* | a private event with a populated title cannot be persisted by any backend |
| `ActivityEventTests` *(extended)* | `debugDescription` contains neither `windowTitle` nor `domain` |

### 6.11 The privacy statement

Plain language, shown at the top of Settings → Privacy and reachable from Help → Privacy. No legal
register, no defined terms, no "we may".

> ### Your work log stays on your Mac
>
> Lggr has no account, no server, and no network code. Nothing you record is uploaded, because there
> is nowhere for it to go.
>
> **What Lggr records.** Which application is in front and when you switched. How long you were away
> from the keyboard. The projects, sessions, notes and accomplishments you write yourself. If you turn
> them on: the title of your current window, and the domain — not the address — of your current browser
> tab.
>
> **What Lggr never records.** Keystrokes. Passwords. Screenshots or anything on your screen. The
> contents of documents, messages or email. Your clipboard. Full web addresses.
>
> **Where it lives.** One folder you can open, read and delete:
> `~/Library/Application Support/Lggr`. It is readable only by your account, and it is included in
> your Time Machine backups.
>
> **What you control.** Pause tracking from the menu bar at any time. Hide an application completely,
> or record it as "Private activity" with no name and no title attached — for private applications,
> Lggr never even asks the system what the window is called. Delete a session, a day, or everything.
> Choose how long activity records are kept; your sessions and accomplishments are always kept.
>
> **What Lggr can't do.** It can't tell that a Safari or Firefox window is a private window; if that
> matters, add the browser to your private list. Hiding an application hides *what* you were doing, not
> *that* you were doing something — a gap still shows on the timeline. Pause tracking if you want the
> gap gone too. And Lggr can't remove the permissions you granted; those live in System Settings and
> only you can take them back.
>
> Lggr is meant to help you reconstruct your week, not to watch you.

### 6.12 Phase mapping for permissions work

| Phase | Permissions and privacy work |
|---|---|
| **P2** | Store directory created with `0700`; `AtomicFileWriter` writes `0600`. `NSSupportsSuddenTermination` / `NSSupportsAutomaticTermination` added to `Info.plist`. `StubPermissionsService` exists so the gallery can render every permission state. |
| **P3** | `ActivitySample`, `PrivacyRedactor`, `DomainExtractor` and their tests. `WindowTitleReader` gated on `AXIsProcessTrusted()`. `BrowserDomainReader` as an `actor`, gated on Automation status and `trackBrowserDomains`. Redaction re-asserted in all three `saveActivityEvents` implementations. `ActivityCoalescer` gap rule. `check-layering.sh` privacy guards. The sandbox-vs-AX empirical check recorded in `CONSTRAINTS.md` (Appendix B). |
| **P4** | `RetentionPruner`. Per-day and per-session activity deletion. `ActivityCSVExporter`. Export-before-delete on every destructive confirmation. |
| **P6** | `SystemPermissionsService`. Onboarding, all six screens with the copy above. `PrivacySettingsView`. The single-banner re-ask policy. `LaunchAtLoginService`. The privacy statement in the UI. |

---

## 7. The phased execution checklist

This turns `SPEC.md`'s six phases into tasks that can be assigned, executed and *verified*.

### 7.0 How to read the checklist

**Every row has five columns.**

| Column | Meaning |
|---|---|
| **ID** | `P<phase>-<nn>`. Stable forever. Never renumbered; a dropped task becomes `~~P2-31~~ withdrawn`. |
| **Task** | One unit of work, sized so a single agent finishes it in one sitting. |
| **Files** | Repo-relative paths, taken verbatim from § 3.5. `(new)` = create, `(edit)` = modify an existing file. |
| **Deps** | Task IDs that must be *accepted* first. `—` means it can start immediately. |
| **Acceptance** | A command whose exit status/output is checked, a named test that passes, or a numbered observable behaviour. **Never "works correctly".** |

**Three verification verbs are used, and they mean exactly these things:**

- **`$ <command>` → `<expected>`** — run it; stdout/exit status must match.
- **TEST `<name>` in `<file>`** — a `@Test` function that exists and passes under `./Scripts/test.sh`.
- **OBSERVE** — a numbered click/keystroke sequence against `build/Lggr.app` (or the gallery) with the
  exact expected on-screen result. Anyone can repeat it.

**The two commands you will run constantly:**

```bash
swift build          # compile check
./Scripts/test.sh    # NOT `swift test` — see § 7.1.2. `make test` is the same thing.
```

### 7.1 Ground truth about the repository today

Verified by running the toolchain in this working tree, not assumed.

#### 7.1.1 What already exists

| Path | State |
|---|---|
| `Package.swift` | Real. `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`, `swiftLanguageMode(.v5)`, `enableUpcomingFeature("ExistentialAny")`, conditional `LggrPersistence` on `LGGR_SWIFTDATA=1`, CLT `Testing.framework` search-path workaround. |
| `Makefile` | Real. `build`, `test`, `app`, `run`, `check`, `clean`, `help`. |
| `Scripts/make-app.sh` | Real. Builds, assembles `build/Lggr.app`, `plutil -lint`, `codesign` with the hardened runtime, `codesign --verify`. |
| `Scripts/test.sh` | Real. Wraps `swift test` and **fails if zero tests actually ran**. |
| `Scripts/make-icon.sh`, `Scripts/IconGenerator.swift` | Real. Produce `Resources/AppIcon.icns` (already generated). |
| `Resources/Info.plist`, `Resources/Lggr.entitlements`, `Resources/AppIcon.icns` | Real. |
| `Sources/LggrKit/_Scaffold.swift`, `Sources/LggrApp/_Scaffold.swift`, `Tests/LggrKitTests/_ScaffoldTests.swift` | Placeholders. Deleted by `P2-85`. |
| `.gitignore` | Real and sufficient. |
| Git | Repo initialised on `master`, **zero commits**. The first commit lands with `P2-06`. |

Baseline, confirmed green before any Phase 2 work:

```
$ swift build          → Build complete!
$ ./Scripts/test.sh    → OK: Test run with 1 test in 0 suites passed
```

#### 7.1.2 Four facts that will bite an agent who does not know them

1. **`swift test` alone silently runs nothing.** With Command Line Tools, SwiftPM cannot locate
   `Testing.framework`; it prints `Build complete!`, exits `0`, and executes zero tests. A green exit
   code with no tests is worse than a red one. **Always `./Scripts/test.sh` or `make test`.**
2. **`ExistentialAny` is on.** Every protocol existential must be spelled `any LggrStore`,
   `any DateProviding`, `[any PersistentModel.Type]`. Bare `LggrStore` is a compile error.
3. **The executable product is `LggrApp`, not `Lggr`.** The binary is
   `build/Lggr.app/Contents/MacOS/LggrApp` and `CFBundleExecutable` is `LggrApp`.
4. **Never launch `.build/debug/LggrApp` directly.** No `Info.plist` outside the bundle means no
   activation policy, no bundle identifier, no `MenuBarExtra` identity, and a trap in
   `UNUserNotificationCenter`. Always `make run`.

### 7.2 Phase 1 — product and technical design

Design only. No Swift.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P1-01 | Verify and record hard environment limits | `docs/_design/CONSTRAINTS.md` | — | **Done.** File exists and every claim in it was produced by running the compiler on this machine. |
| P1-02 | Reproduce the product specification verbatim | `docs/_design/SPEC.md` | — | **Done.** File exists. |
| P1-03 | Product definition + MVP boundary + risks | `docs/_design/01-product.md` | P1-01, P1-02 | **Done.** |
| P1-04 | Architecture and folder structure | `docs/_design/02-architecture.md` | P1-01 | **Done.** |
| P1-05 | Data model | `docs/_design/03-data-model.md` | P1-04 | **Done.** |
| P1-06 | Screens and navigation | `docs/_design/04-screens.md` | P1-04 | **Done.** |
| P1-07 | Permissions strategy | `docs/_design/05-permissions.md` | P1-04 | **Done.** |
| P1-08 | Execution checklist | `docs/_design/06-checklist.md` | P1-04, P1-05 | **Done.** |
| P1-09 | **Synthesise all six into one authoritative document, resolving every contradiction** | `docs/DESIGN.md` (new) | P1-03 … P1-08 | **Done** (this file). Contains, in order: product definition, MVP scope, architecture and folder structure, data model (domain + SwiftData), screens, permissions, phased checklist, and a *Resolved conflicts* appendix. |

**Phase 1 exit:** all nine rows accepted, and Appendix A is agreed by whoever owns the design set.
`DESIGN.md` supersedes `docs/_design/01-…06-` wherever they disagree.

### 7.3 Phase 2 — the smallest working vertical slice

> `SPEC.md` § *Implementation order*, Phase 2: create a project · start a focus session · timer in the
> main window · timer in the menu bar · pause and resume · finish the session · select the result
> status · persist the session · show the completed session in Today · add an accomplishment from the
> completed session. **"This phase must compile and work before continuing."**

86 tasks in eight stages. Stages A–D are pure `LggrKit` and can be executed by an agent with no UI
judgement; stages E–H are the app.

> **Ordering note (from § 7.10 risk 1 and risk 4):** do `P2-46` + `P2-48` + `P2-68` as a throwaway
> spike on **day one**, and build the gallery (`P2-80`/`P2-81`) **before** the view stage rather than
> after.

#### Stage A — build plumbing (P2-01 … P2-06)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-01 | Write the layering guard: fail if `Sources/LggrKit` imports SwiftUI/AppKit/SwiftData, or if `@Model`/`#Predicate`/`#Preview` appear anywhere under `Sources/LggrKit` or `Sources/LggrApp` except `Sources/LggrApp/_XcodeOnly/`. Print `layering OK` and exit 0 on success. | `Scripts/check-layering.sh` (new) | — | `$ ./Scripts/check-layering.sh` → `layering OK`, exit `0`. Then `$ printf 'import AppKit\n' > Sources/LggrKit/_probe.swift && ./Scripts/check-layering.sh; echo $?` → non-zero and names `_probe.swift`; delete the probe. |
| P2-02 | Call the guard from the app assembler, before `swift build`. Plumb `LGGR_SIGN_IDENTITY` while you are in the file. | `Scripts/make-app.sh` (edit) | P2-01 | `$ ./Scripts/make-app.sh release` → output contains `layering OK` **before** the build line, and still ends with `Built .../build/Lggr.app`. |
| P2-03 | Complete `Info.plist` per § 3.9.4: add `NSPrincipalClass=NSApplication`, `NSSupportsSuddenTermination=false`, `NSSupportsAutomaticTermination=false`, `LSApplicationCategoryType=public.app-category.productivity`, `ITSAppUsesNonExemptEncryption=false`. Leave `CFBundleExecutable`, `CFBundleIdentifier` and `NSAccessibilityUsageDescription` untouched. | `Resources/Info.plist` (edit) | — | `$ plutil -lint Resources/Info.plist` → `OK`. `$ for k in NSPrincipalClass NSSupportsSuddenTermination NSSupportsAutomaticTermination LSApplicationCategoryType ITSAppUsesNonExemptEncryption; do plutil -extract $k raw Resources/Info.plist; done` → prints 5 values, exit 0 each. |
| P2-04 | Add `exclude: ["_XcodeOnly"]` to the `LggrApp` target so the Xcode-only previews never reach this toolchain. | `Package.swift` (edit) | — | `$ mkdir -p Sources/LggrApp/_XcodeOnly && printf '#Preview { Text("x") }\n' > Sources/LggrApp/_XcodeOnly/_probe.swift && swift build` → `Build complete!`; delete the probe. |
| P2-05 | Add `Scripts/run.sh` (`make-app.sh "$@" && open build/Lggr.app`) and a `make gallery` target that runs the app with `LGGR_GALLERY=1`. | `Scripts/run.sh` (new), `Makefile` (edit) | P2-02 | `$ ./Scripts/run.sh release` → Lggr appears in the Dock. `$ make help` → lists a `gallery` target. |
| P2-06 | README: what Lggr is, the four build commands, the `swift test` trap, where data is stored, the "zero network code" claim with the `otool` check. Then make the first git commit. | `README.md` (new) | P2-01…P2-05 | `$ grep -c 'Scripts/test.sh' README.md` → ≥ 1. `$ grep -c 'Application Support/Lggr' README.md` → ≥ 1. `$ git log --oneline \| wc -l` → ≥ 1. |

#### Stage B — LggrKit domain types (P2-07 … P2-18)

All files: `Sendable`, `Codable`, `Hashable`, `Identifiable`, explicit `public init`, no force
unwraps. Copy declarations verbatim from § 4.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-07 | The four Phase 2 enums, verbatim from § 4.1: `WorkType` (8 cases + `displayName`, `symbolName`, `suggestedDuration`, `isReactiveByDefault`), `SessionResultStatus` (5 cases + `countsAsCompleted`/`countsAsInterrupted`/`needsFollowUp`), `AccomplishmentType` (11 cases + `countsAsUnblockingOthers`), `SessionState` (4 cases + `symbolName`, `isActive`). Explicit `String` raw values. | `Sources/LggrKit/Model/Enums.swift` (new) | — | `$ swift build` → `Build complete!`. TEST `workTypeSuggestedDurations` in `Tests/LggrKitTests/EnumsTests.swift`: `.deepWork.suggestedDuration == 3000`, `.communication.suggestedDuration == 1500`, and `WorkType.allCases.count == 8`, `SessionResultStatus.allCases.count == 5`, `AccomplishmentType.allCases.count == 11`. |
| P2-08 | `Project` + `defaultColorID`, `defaultIconID`, `colorIDs` (9), `iconIDs` (10). | `Sources/LggrKit/Model/Project.swift` (new) | P2-07 | TEST `projectDefaults` in `CodableRoundTripTests.swift`: `Project(name: "SOR").colorID == "blue"`, `Project.colorIDs.count == 9`, no duplicates. |
| P2-09 | `FocusSession` — all 16 stored properties including `pauseStartedAt`, with `pausedDuration` and `interruptionCount` clamped at 0 in `init`. | `Sources/LggrKit/Model/FocusSession.swift` (new) | P2-07 | TEST `negativeDurationsAreClamped` in `FocusSessionTimingTests.swift`: `FocusSession(intendedOutcome: "x", pausedDuration: -5, interruptionCount: -2)` yields `pausedDuration == 0` and `interruptionCount == 0`. |
| P2-10 | Timing extension, verbatim from § 4.3.4: `state`, `isRunning`, `isPaused`, `isFinished`, `isOpenEnded`, `totalPausedDuration(at:)`, `elapsed(at:)`, `remaining(at:)`, `overrun(at:)`, `progress(at:)`, `effectiveDuration`, `wallClockInterval`, `pause(at:)`, `resume(at:)`, `finish(at:status:)`, `togglePause(at:)`. Never call `Date()` inside. | `Sources/LggrKit/Model/FocusSession+Timing.swift` (new) | P2-09 | `$ grep -c 'Date()' Sources/LggrKit/Model/FocusSession+Timing.swift` → `0`. Full behaviour is covered by `P2-26`. |
| P2-11 | `Accomplishment` + `isGeneratedFromSession`. | `Sources/LggrKit/Model/Accomplishment.swift` (new) | P2-07 | TEST `accomplishmentFromSessionIsFlagged` in `CodableRoundTripTests.swift`: `focusSessionID: nil` → `false`; a UUID → `true`. |
| P2-12 | `KeyboardShortcutSpec` (+ `.defaultStartSession` = `" "`, `(1<<20)\|(1<<17)`) and `UserPreferences` with every field in § 4.2.4, `singletonID`, `isExcluded(bundleIdentifier:)`, `isPrivate(bundleIdentifier:)`, `retentionCutoff(from:calendar:)`. | `Sources/LggrKit/Model/UserPreferences.swift` (new) | P2-07 | Covered by `P2-30`. `$ grep -c 'C0DE' Sources/LggrKit/Model/UserPreferences.swift` → ≥ 1. |
| P2-13 | `DateProviding` protocol (`var now: Date`), `SystemClock`, `FixedClock` (mutable `now`, plus `advance(by:)`). | `Sources/LggrKit/Support/DateProviding.swift` (new) | — | TEST `fixedClockAdvances` in `SupportTests.swift`: a `FixedClock` at T, `advance(by: 60)`, `now == T + 60`; two reads of `SystemClock().now` are non-decreasing. |
| P2-14 | Day and week boundary helpers: `DateInterval.day(containing:calendar:)`, `DateInterval.week(containing:calendar:)`, `Calendar.weekStart(for:)`. Always `Calendar.dateInterval(of:for:)`; never `date + 86_400`. | `Sources/LggrKit/Support/CalendarWindows.swift` (new) | — | TEST `dayWindowCoversMidnightToMidnight` in `SupportTests.swift`: for 2026-03-08 14:30 local, `.day` starts at 00:00:00 and has `duration == 86_400` under a fixed-offset calendar; `weekStart` is ≤ the date and its weekday matches `calendar.firstWeekday`. |
| P2-15 | `[T]` lookup helpers for `Identifiable` collections: `first(id:)`, `upserted(_:)`, `removing(id:)`. | `Sources/LggrKit/Support/Identified.swift` (new) | — | TEST `upsertReplacesInPlace` in `SupportTests.swift`: upserting an edited element keeps `count` and index stable; upserting a new element appends. |
| P2-16 | Duration formatting: `DurationFormatting.clock(_:)` → `"25:00"` / `"1:23:45"`, `.compact(_:)` → `"50m"` / `"1h 12m"`, `.menuBar(_:)`, `.overrun(_:)` → `"+2:07"`, `.spokenDuration(_:)`. Pure, locale-independent digits. | `Sources/LggrKit/Domain/DurationFormatting.swift` (new) | — | Covered by `P2-27`. |
| P2-17 | Deterministic Phase 2 summary generator: `SessionSummaryBuilder.suggestedSummary(for:project:) -> String`. With no activity events (all of Phase 2) it composes from intended outcome, project name, work type and `effectiveDuration` — e.g. `"Spent 45m of deep work on receipt deduplication (SOR engineering)."` No AI, no randomness. Grows in Phase 3 to name applications. | `Sources/LggrKit/Domain/SessionSummaryBuilder.swift` (new) | P2-09, P2-10, P2-16 | Covered by `P2-28`. |
| P2-18 | Fixtures: `FixtureCalendar` (a fixed `referenceDate` + `at(_ hour:_ minute:)` in a fixed-offset calendar, **including a DST-transition date**) and `PreviewFixtures` (≥ 2 projects, 1 running session, 1 paused session, 1 finished-awaiting-review session, 3 completed sessions across today, 2 accomplishments, default preferences). Deterministic — no `Date()`, no fresh `UUID()`. | `Sources/LggrKit/Fixtures/FixtureCalendar.swift` (new), `Sources/LggrKit/Fixtures/PreviewFixtures.swift` (new) | P2-08…P2-12 | TEST `fixturesAreDeterministic` in `SupportTests.swift`: `PreviewFixtures.finishedSession.id` is equal across two accesses, and `FixtureCalendar.at(9, 0)` returns an identical `Date` on repeat calls. |

#### Stage C — LggrKit persistence (P2-19 … P2-25)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-19 | `StoreError` — `notFound(UUID)`, `invalidData(String)`, `persistenceFailure(String)`; `Error, Sendable, Equatable`. | `Sources/LggrKit/Store/StoreError.swift` (new) | — | `$ swift build` → `Build complete!`. TEST `storeErrorsAreEquatable` in `LggrStoreContractTests.swift`. |
| P2-20 | `LggrStore` protocol, Phase 2 subset only, `@MainActor` + `AnyObject`: `loadProjects`, `saveProject`, `deleteProject(id:)`, `loadSessions(in:)`, `loadSession(id:)`, `loadActiveSession()`, `saveSession`, `deleteSession(id:)`, `loadAccomplishments(in:)`, `saveAccomplishment`, `deleteAccomplishment(id:)`, `flush()`. Later-phase methods stay **commented** with their `[P3]`/`[P4]`/`[P5]` markers so the growth path is visible. | `Sources/LggrKit/Store/LggrStore.swift` (new) | P2-19 | `$ grep -c '@MainActor' Sources/LggrKit/Store/LggrStore.swift` → ≥ 1. `$ grep -cE '^\s*func (loadActivityEvents\|loadInterruptions\|loadWeeklyOutcomes)' Sources/LggrKit/Store/LggrStore.swift` → `0`. |
| P2-21 | `StoreSnapshot`: `Codable` root holding `schemaVersion: Int` (= 1), `projects`, `sessions`, `accomplishments`, plus `.empty`. Decoding a snapshot with a *higher* `schemaVersion` throws `StoreError.invalidData` with a message naming both versions; a lower or equal version decodes. | `Sources/LggrKit/Store/StoreSnapshot.swift` (new) | P2-08…P2-11, P2-19 | TEST `futureSchemaVersionIsRefused` in `StoreSnapshotCodableTests.swift`: hand-built JSON with `"schemaVersion": 99` throws `StoreError.invalidData`; with `1` it decodes and round-trips equal. |
| P2-22 | `AtomicFileWriter.write(_ data: Data, to url: URL) throws` — create the parent directory with `0o700`, write to a sibling temp file with `0o600`, `FileManager.replaceItemAt`. `nonisolated`/`Sendable`, no `try!`. | `Sources/LggrKit/Store/AtomicFileWriter.swift` (new) | P2-19 | TEST `atomicWriteLeavesNoTempFile` in `JSONFileStoreTests.swift`: after writing to a temp dir, that directory contains exactly one file and its contents equal the input bytes. TEST `storeFilesAreOwnerReadableOnly`: mode is `0600`, directory `0700`. |
| P2-23 | `InMemoryStore: LggrStore` — `@MainActor final class`, optional `var failureToInject: StoreError?` thrown by every method when set, `init(seed: StoreSnapshot = .empty)`. `deleteProject` **nullifies** `projectID` on referencing sessions and accomplishments rather than deleting them. | `Sources/LggrKit/Store/InMemoryStore.swift` (new) | P2-20, P2-21 | Covered by `P2-31`. |
| P2-24 | `JSONFileStore: LggrStore` — `@MainActor final class` over `~/Library/Application Support/Lggr/store.json` (directory injectable). Holds the snapshot in memory; `save…` mutates it, marks dirty and schedules a 500 ms coalesced flush; `flush()` awaits a `nonisolated` encode + `AtomicFileWriter.write`, so **no JSON encoding or file I/O runs on the main actor**. Missing file → empty snapshot, not an error. Corrupt file → throw `StoreError.invalidData` and leave the file untouched. | `Sources/LggrKit/Store/JSONFileStore.swift` (new) | P2-21, P2-22, P2-23 | Covered by `P2-31` and `P2-32`. Plus `$ grep -c 'nonisolated' Sources/LggrKit/Store/JSONFileStore.swift` → ≥ 1. |
| P2-25 | `PreferencesStoring` protocol + `UserDefaultsPreferencesStore` (single JSON blob under `com.lggr.userPreferences.v1`, injectable `UserDefaults`) + `InMemoryPreferencesStore` fake. | `Sources/LggrKit/Store/PreferencesStore.swift` (new) | P2-12 | TEST `preferencesSurviveAStoreRestart` in `UserPreferencesTests.swift`: against a `UserDefaults(suiteName:)` scratch domain, set `defaultSessionDuration = 1500`, construct a second store over the same suite, read `1500`. The suite is removed in teardown. |

#### Stage D — LggrKit tests (P2-26 … P2-32)

Every test injects time; **none calls `Date()`.**

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-26 | Timing suite. One `@Test` each: (a) elapsed with no pause; (b) the full worked table from § 4.3.2 — 09:00 start → pause 09:10 → resume 09:15 → pause 09:40 → resume 09:50 → finish 10:00 gives `pausedDuration == 900` and `elapsed == 2700`; (c) elapsed is frozen while paused; (d) `pause` twice is a no-op; (e) `resume` without a pause is a no-op; (f) `finish` while paused closes the pause then ends; (g) `finish` twice never moves `endedAt`; (h) backwards clock on `resume` adds 0; (i) `finish(at:)` before `startedAt` clamps to `startedAt` and `elapsed == 0`; (j) open-ended → `remaining == nil`, `progress == nil`, `overrun == 0`; (k) `overrun` after the planned duration; (l) `effectiveDuration == 0` while running; (m) `state` returns `.running`/`.paused`/`.awaitingReview`/`.completed` in the four situations; (n) `togglePause` alternates. | `Tests/LggrKitTests/FocusSessionTimingTests.swift` (new) | P2-10, P2-18 | `$ ./Scripts/test.sh --filter FocusSessionTiming` → all pass, run summary reports **≥ 14 tests**. |
| P2-27 | Formatting suite: `clock(0) == "0:00"`, `clock(59) == "0:59"`, `clock(1500) == "25:00"`, `clock(3661) == "1:01:01"`, `compact(3000) == "50m"`, `compact(4320) == "1h 12m"`, `compact(0) == "0m"`, `overrun(127) == "+2:07"`, and a negative input never produces a `-` sign. | `Tests/LggrKitTests/DurationFormattingTests.swift` (new) | P2-16 | `$ ./Scripts/test.sh --filter DurationFormatting` → all pass, ≥ 8 tests. |
| P2-28 | Summary suite: same session + same project produce byte-identical strings on repeat calls; the string contains the intended outcome, the project name and a formatted duration; a session with no project omits the parenthetical and contains no `"nil"`, no `"Optional"` and no double space. | `Tests/LggrKitTests/SessionSummaryBuilderTests.swift` (new) | P2-17, P2-18 | `$ ./Scripts/test.sh --filter SessionSummaryBuilder` → all pass, ≥ 4 tests. |
| P2-29 | Codable round-trip for `Project`, `FocusSession`, `Accomplishment`, `UserPreferences`, `StoreSnapshot`, and every case of all four Phase 2 enums. Also assert the *raw strings* (`"deepWork"`, `"madeProgress"`, `"pullRequestReviewed"`, …) so a Swift-level rename cannot silently invalidate stored JSON. | `Tests/LggrKitTests/CodableRoundTripTests.swift` (new) | P2-08…P2-12, P2-21 | `$ ./Scripts/test.sh --filter CodableRoundTrip` → all pass; the enum raw-value test asserts all 28 Phase 2 raw values explicitly. |
| P2-30 | Preferences suite: `isExcluded`/`isPrivate` are case-insensitive; `retentionCutoff` returns `now − days`; `dataRetentionDays == nil` or `0` → `nil` cutoff; JSON round-trip preserves `globalShortcut`; `id` always equals `singletonID` even when the decoded JSON carries a different `id`. | `Tests/LggrKitTests/UserPreferencesTests.swift` (new) | P2-12, P2-25 | `$ ./Scripts/test.sh --filter UserPreferences` → all pass, ≥ 6 tests. |
| P2-31 | **Store contract suite**, written once and run against every conformer via a `[() -> any LggrStore]` factory list (`InMemoryStore`, `JSONFileStore` in a fresh temp dir; `SwiftDataStore` added under `LGGR_SWIFTDATA=1` in `P3-12`). Cases: upsert-by-id updates rather than duplicates; `loadSessions(in:)` filters on `startedAt` and returns newest first; `loadActiveSession()` returns the one with `endedAt == nil` and `nil` when there is none; `deleteProject` nullifies `projectID` on sessions and accomplishments and deletes neither; `deleteSession` removes only that session; `loadAccomplishments(in:)` filters on `timestamp`; an injected `failureToInject` surfaces as a thrown `StoreError`. | `Tests/LggrKitTests/LggrStoreContractTests.swift` (new) | P2-23, P2-24 | `$ ./Scripts/test.sh --filter LggrStoreContract` → all pass; the suite reports **2 × N** tests (each case executed against both backends). |
| P2-32 | Durability suite for `JSONFileStore` only: write → `flush()` → construct a second store over the same directory → data is there; a missing file yields an empty store and no throw; a file containing `{` throws `StoreError.invalidData` and the bad file is still on disk afterwards; plus the atomic-write and permission tests from `P2-22`. | `Tests/LggrKitTests/JSONFileStoreTests.swift` (new) | P2-22, P2-24 | `$ ./Scripts/test.sh --filter JSONFileStore` → all pass, ≥ 4 tests. Each test uses `FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)` and removes it afterwards. |

#### Stage E — design system and components (P2-33 … P2-42)

Everything here is presentational, takes plain values, and appears in the gallery. No data access.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-33 | `Theme`: the `Space` scale (§ 5.2.2), `Radius` (§ 5.2.3), and semantic surfaces built from `Material` and semantic colours only — never a hard-coded hex that ignores appearance. | `Sources/LggrApp/DesignSystem/Theme.swift` (new) | — | `$ grep -cE '(Color\|NSColor)\(red:\|#[0-9a-fA-F]{6}' Sources/LggrApp/DesignSystem/Theme.swift` → `0`. |
| P2-34 | `Typography`: the named roles of § 5.2.1 built on text styles, with `.monospacedDigit()` on every timer role and `@ScaledMetric` on `timerHero`. | `Sources/LggrApp/DesignSystem/Typography.swift` (new) | — | `$ grep -c 'monospacedDigit' Sources/LggrApp/DesignSystem/Typography.swift` → ≥ 1. OBSERVE in the gallery: the running timer's width does not jitter as the seconds change. |
| P2-35 | `Palette`: `NSColor.lggrDynamic(light:dark:)`, `Surface`, `Stroke`, `Palette.attention`/`.destructive`, and `Palette.project(_:)` mapping all nine `Project.colorIDs` with a documented fallback for an unknown token. | `Sources/LggrApp/DesignSystem/Palette.swift` (new) | P2-08 | `$ grep -o '"[a-z]*"' Sources/LggrApp/DesignSystem/Palette.swift \| sort -u \| wc -l` → ≥ 9. OBSERVE: the gallery's swatch row shows nine visually distinct colours in both light and dark. |
| P2-36 | `Iconography`: every SF Symbol name used by the app, in one enum (§ 5.2.10). Domain symbols come from the enums and are never re-declared. | `Sources/LggrApp/DesignSystem/Iconography.swift` (new) | P2-07 | `$ grep -rn 'Image(systemName:' Sources/LggrApp/Views Sources/LggrApp/Components \| grep -v 'Iconography\.\|Icon\.\|symbolName' \| wc -l` → `0`. |
| P2-37 | `Motion`: the five named animations plus the single `.lggrAnimation(_:value:)` modifier that collapses them under `accessibilityReduceMotion`. | `Sources/LggrApp/DesignSystem/Motion.swift` (new) | — | `$ grep -c 'accessibilityReduceMotion' Sources/LggrApp/DesignSystem/Motion.swift` → ≥ 1. `$ grep -rc 'repeatForever' Sources/LggrApp` → `0`. OBSERVE: with Reduce motion **on**, pausing the session changes state with no scale or slide. |
| P2-38 | `Card` container — `Surface.raised` fill, `Radius.card`, `Stroke.card` hairline on the same shape, `Space.l` padding. | `Sources/LggrApp/Components/Card.swift` (new) | P2-33, P2-35 | OBSERVE in the gallery: `Card` renders with a legible border in both light and dark. |
| P2-39 | `SectionHeader` — title, optional trailing borderless action. | `Sources/LggrApp/Components/SectionHeader.swift` (new) | P2-33, P2-34 | OBSERVE in the gallery, both appearances. |
| P2-40 | `EmptyStateView` — 28pt `.tertiary` symbol, title, one-line explanation, optional primary button, max text width 340pt (§ 5.3.1). | `Sources/LggrApp/Components/EmptyStateView.swift` (new) | P2-33, P2-36 | OBSERVE in the gallery: renders with and without a button, both appearances. |
| P2-41 | `PrimaryButtonStyle` — the one prominent button per screen; visible focus ring; disabled state readable; inline `⌘⏎` hint at `.caption`. | `Sources/LggrApp/Components/PrimaryButtonStyle.swift` (new) | P2-33 | OBSERVE in the gallery: enabled, disabled and keyboard-focused variants are visually distinct in both appearances. |
| P2-42 | `ProjectBadge` — 8pt colour dot with the 0.5pt inner stroke, SF Symbol, name, from a `Project`. | `Sources/LggrApp/Components/ProjectBadge.swift` (new) | P2-35, P2-36 | OBSERVE in the gallery: badges for both `PreviewFixtures` projects render with the right colour and icon; a yellow dot is visible on white. |

#### Stage F — app shell, DI and services (P2-43 … P2-53)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-43 | `StoreBootstrap.makeStore() -> any LggrStore` — the **only** `#if LGGR_SWIFTDATA` in the repo. Returns `JSONFileStore` rooted at `~/Library/Application Support/Lggr/`. | `Sources/LggrApp/App/StoreBootstrap.swift` (new) | P2-24 | `$ grep -rn 'LGGR_SWIFTDATA' Sources/LggrApp --include=*.swift \| wc -l` → exactly the count inside this one file (≤ 3), and no other file appears in the output. |
| P2-44 | `AppEnvironment` — `@MainActor @Observable final class` holding `store`, `preferences`, `clock`, `sessionManager`, `menuBar`. Two factories: `.live()` and `.fake(...)` with `InMemoryStore(seed: PreviewFixtures.demoDay)` + `InMemoryPreferencesStore` + `FixedClock` defaults. Phase 3+ services are *absent*, not stubbed. | `Sources/LggrApp/App/AppEnvironment.swift` (new) | P2-43, P2-25, P2-47, P2-48 | `$ swift build` → `Build complete!`. OBSERVE: `AppEnvironment.fake()` drives the gallery and shows fixture data; `.live()` drives `LggrMain` and shows real data. |
| P2-45 | `EnvironmentValues+Lggr` — hand-written `EnvironmentKey`s for `clock` and `isGalleryMode`. No `@Entry` (SwiftUI macro; cannot compile here). | `Sources/LggrApp/App/EnvironmentValues+Lggr.swift` (new) | P2-13 | `$ grep -c '@Entry' Sources/LggrApp/App/EnvironmentValues+Lggr.swift` → `0`. `$ swift build` → `Build complete!`. |
| P2-46 | `TickTimer` — 1 Hz, `tolerance = 0.15`, added to `RunLoop.main` in **`.common`** mode, `MainActor.assumeIsolated` in the fire block, `stop()` invalidates. It only asks for a redraw; it accumulates nothing. | `Sources/LggrApp/Services/TickTimer.swift` (new) | — | `$ grep -c 'forMode: .common' Sources/LggrApp/Services/TickTimer.swift` → ≥ 1. OBSERVE: start a session, open the menu bar popover and **hold it open** for 10 s — the time in the popover advances every second while the popover is tracking. |
| P2-47 | `SessionManager` — `@MainActor @Observable final class`. `var active: FocusSession?`, `var awaitingReview: FocusSession?`, `var recentlyFinished: [FocusSession]`, `var tick: Date`. `start(project:outcome:workType:plannedDuration:)`, `pause()`, `resume()`, `togglePause()`, `finish()`, `applyReview(status:summary:blocker:nextStep:)`, `restoreActiveSession()`. All arithmetic delegates to `FocusSession+Timing` with `clock.now`; the session is written to the store **at start**, and writes are fire-and-forget after the in-memory state is already updated. Starts the tick on start/resume, stops it on pause/finish. | `Sources/LggrApp/Services/SessionManager.swift` (new) | P2-10, P2-20, P2-46 | `$ grep -cE '\bDate\(\)' Sources/LggrApp/Services/SessionManager.swift` → `0`. OBSERVE: with no session running, sampling the app for 5 s shows no repeating 1 Hz callback — nothing ticks when nothing runs. |
| P2-48 | `MenuBarManager` — derives `labelState` (`symbolName` from `SessionState`, plus an optional time string that is the countdown, or `+M:SS` after overrun, or the count-up when open-ended, or nothing when `showTimerInMenuBar` is false) from `SessionManager` and preferences. Also `spokenValue` per § 5.6.4. | `Sources/LggrApp/Services/MenuBarManager.swift` (new) | P2-47, P2-16, P2-25 | OBSERVE: (1) no session → `timer` symbol, no digits; (2) 25-min session → `24:59` within 2 s; (3) pause → symbol becomes `pause.circle` and the digits stop changing for 10 s; (4) let a 1-minute session overrun → the label switches to `+0:01`. |
| P2-49 | `SleepWakeObserver` — `for await` over `NSWorkspace.willSleepNotification` / `didWakeNotification`; in Phase 2 it only forces a redraw on wake so the timer is instantly correct. No non-`Sendable` value escapes the loop body. | `Sources/LggrApp/Services/SleepWakeObserver.swift` (new) | P2-47 | OBSERVE: start a 50-minute session, close the lid for ≥ 2 minutes, reopen — the timer shows the correct wall-clock-derived value within 1 s, with no catch-up animation. |
| P2-50 | `AppModel` — `@MainActor @Observable`: `section: SidebarSection` (persisted under `com.lggr.sidebar.section`), `columnVisibility`, `detailPath`, `presentedSheet: AppSheet?` (`.startSession`, `.review(FocusSession)`, `.addAccomplishment(FocusSession?)`, `.editProject(Project?)`). **Sheet routing lives here, not in views.** | `Sources/LggrApp/State/AppModel.swift` (new) | P2-54 | `$ grep -rn '@State private var.*[Ss]how.*Sheet' Sources/LggrApp/Views \| wc -l` → `0`. |
| P2-51 | `AppDelegate` — `applicationWillTerminate` flushes the store before returning; `applicationShouldTerminateAfterLastWindowClosed` returns `false`; `applicationShouldHandleReopen` opens the main window. | `Sources/LggrApp/App/AppDelegate.swift` (new) | P2-24 | OBSERVE: start a session, ⌘W → the app stays in the Dock and the menu bar timer keeps counting. Then ⌘Q → `~/Library/Application Support/Lggr/store.json` contains the session. |
| P2-52 | `LggrMain` — `@main App`. `MenuBarExtra { MenuBarContentView() } label: { MenuBarLabel(...) }` with `.menuBarExtraStyle(.window)`; `Window("Lggr", id: WindowID.main)` with `.defaultSize(width: 1040, height: 720)`; the `LGGR_GALLERY=1` gallery `Window`; a `Settings` scene. Injects `AppEnvironment.live()` and `AppModel` once per scene. | `Sources/LggrApp/App/LggrMain.swift` (new) | P2-44, P2-50, P2-56, P2-71 | `$ make run` → the app launches, one Dock icon, one menu bar item, one window sized ~1040×720. |
| P2-53 | `AppCommands` — `CommandGroup`s providing ⌘N (new focus session), ⌘⇧N (new project), ⌘⇧A (add accomplishment), and ⌘1–⌘7. ⌘⏎ and Esc come from the sheets via `.keyboardShortcut(.defaultAction)` / `.cancelAction`. ⌘⇧I is registered but **disabled with a tooltip** until Phase 3 — it is not a dead button. | `Sources/LggrApp/App/AppCommands.swift` (new) | P2-50, P2-52 | OBSERVE, with the main window frontmost: ⌘N opens the start sheet; Escape closes it; ⌘3 selects Accomplishments; ⌘5 selects Projects; ⌘⇧A opens the accomplishment sheet; the Session menu shows "Capture Interruption" greyed out with a tooltip. |

#### Stage G — views (P2-54 … P2-79)

**Rule: a view never fetches its own data.** Only `TodayView`, `ProjectsView`, `RootWindow` and
`MenuBarContentView` read the environment.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-54 | `SidebarSection` — the enum of § 5.1.2, all seven cases in fixed order, with `title`, `symbolName`, `shortcutNumber` 1–7 and `isAvailableInPhase2`. Numbering never changes as later phases land. | `Sources/LggrApp/Views/Root/SidebarSection.swift` (new) | P2-36 | `$ grep -c 'case ' Sources/LggrApp/Views/Root/SidebarSection.swift` → ≥ 7. OBSERVE: ⌘1 … ⌘7 each select a different row. |
| P2-55 | `Sidebar` — native `List` with `.sidebar` style, no per-section tint, outline symbols only, running dot on Today. Sections not yet built render their row normally but their detail is an honest `EmptyStateView` ("Weekly review arrives in Phase 5"). | `Sources/LggrApp/Views/Root/Sidebar.swift` (new) | P2-54, P2-40 | OBSERVE: selecting Weekly Review shows an empty state naming the phase; no row is a no-op; the Today row shows a 6pt accent dot only while a session runs. |
| P2-56 | `RootWindow` — `NavigationSplitView` with the sidebar (min 180 / ideal 220 / max 280) and a `NavigationStack` detail column (min 640); hosts the sheets routed by `AppModel`. | `Sources/LggrApp/Views/Root/RootWindow.swift` (new) | P2-55, P2-50 | OBSERVE: the window opens on Today (SPEC: "Today is selected by default"); the sidebar can be collapsed and restored. |
| P2-57 | `ProjectsModel` — `@Observable`; loads projects from the store, creates/updates/deletes, keeps `lastSelectedProjectID` in preferences fresh. | `Sources/LggrApp/State/ProjectsModel.swift` (new) | P2-20, P2-25 | Covered by `P2-59`. |
| P2-58 | `ProjectEditor` — sheet, 420pt, with name (required), colour picker over `Project.colorIDs`, icon picker over `Project.iconIDs`, Active toggle. Primary **Save** on ⌘⏎, disabled while the trimmed name is blank. | `Sources/LggrApp/Views/Projects/ProjectEditor.swift` (new) | P2-35, P2-36, P2-41 | OBSERVE: with an empty name, Save is disabled and ⌘⏎ does nothing; type a name → Save enables. |
| P2-59 | `ProjectsView` — list of projects with `ProjectBadge` and usage line, `Show inactive` toggle, `EmptyStateView` when there are none, one primary action **New Project**, native context menu with Edit and Delete (delete confirm copy from § 5.10). | `Sources/LggrApp/Views/Projects/ProjectsView.swift` (new) | P2-57, P2-58, P2-42, P2-40 | **SPEC item 1.** OBSERVE: fresh install → Projects shows the empty state; click New Project, name it `SOR engineering`, pick purple + `hammer`, Save → the row appears with a purple `hammer` badge; quit and relaunch → it is still there. |
| P2-60 | `WorkTypePicker` — all 8 `WorkType`s; changing it re-applies `suggestedDuration` **only while `durationWasEdited` is false**. | `Sources/LggrApp/Views/Focus/WorkTypePicker.swift` (new) | P2-07 | OBSERVE: open the start panel → Deep work / 50 min; switch to Communication → 25 min; type a custom 35 → switch to Planning → stays 35. |
| P2-61 | `DurationPicker` — 25 / 50 / Custom / Open-ended, keyboard-selectable with ←/→, custom accepts 1–480 minutes and rejects nothing silently. | `Sources/LggrApp/Views/Focus/DurationPicker.swift` (new) | — | OBSERVE: choosing Open-ended makes the active view count **up** from `0:00` and show no remaining time; choosing 25 makes it count **down** from `25:00`. |
| P2-62 | `ProjectPicker` — type-ahead list of active projects, preselecting `preferences.lastSelectedProjectID` per the rules in § 5.5.2, with an inline "New Project…" escape hatch and a "No project" option. | `Sources/LggrApp/Views/Focus/ProjectPicker.swift` (new) | P2-57, P2-25 | OBSERVE: start a session on `SOR engineering`, finish it, press ⌘N again → `SOR engineering` is already selected. |
| P2-63 | `OutcomeField` — required text field, autofocused via `@FocusState` + `.defaultFocus`, offering up to 3 recent distinct intended outcomes from the last 30 days, navigable with ↓/↑ and accepted with ⏎. | `Sources/LggrApp/Views/Focus/OutcomeField.swift` (new) | P2-20 | OBSERVE: press ⌘N and type immediately without clicking — the characters land in the outcome field. |
| P2-64 | `StartSessionForm` — the under-five-seconds path, laid out and focus-ordered exactly as § 5.5.2. Primary **Start Focus** (⌘⏎, disabled while the trimmed outcome is blank, with the "Add an outcome to start." hint); secondary **Start without timer** (⌥⌘⏎, open-ended). Esc cancels. Never blocked on I/O. | `Sources/LggrApp/Views/Focus/StartSessionForm.swift` (new) | P2-60…P2-63, P2-41, P2-47 | **SPEC item 2.** OBSERVE (timed, from a cold app with one existing project): ⌘N → type `Finish the receipt deduplication PR` → ⌘⏎. Session is running in **under 5 seconds**, mouse untouched. |
| P2-65 | `TimerDisplay` — visually dominant `Type.timerHero`, monospaced digits, progress ring for a planned duration and none when open-ended; after the countdown reaches zero it shows `+M:SS` in `Palette.attention`. Takes `session` and `now` as plain values. | `Sources/LggrApp/Views/Focus/TimerDisplay.swift` (new) | P2-34, P2-16 | **SPEC item 3.** OBSERVE: the timer's point size is the largest on the screen; the digits do not shift horizontally as they change; a 1-minute session shows `+0:01` one second after zero. |
| P2-66 | `SessionControls` — Pause/Resume (Space, scoped per § 5.7.2) and Finish. Two controls, nothing else. | `Sources/LggrApp/Views/Focus/SessionControls.swift` (new) | P2-47 | **SPEC item 5.** OBSERVE: press Space → the button reads Resume and the timer freezes for a 10 s count; press Space → it resumes from where it stopped, having lost exactly the paused seconds. |
| P2-67 | `ActiveSessionView` — intended outcome and timer dominant; project badge; the two controls. Deliberately **no** activity strip, switch count or timeline in Phase 2. | `Sources/LggrApp/Views/Focus/ActiveSessionView.swift` (new) | P2-65, P2-66, P2-42 | OBSERVE: the screen contains exactly one primary action (Finish) and shows **no** empty `Context switches: —` placeholder. |
| P2-68 | `MenuBarLabel` — `SessionState.symbolName` + optional time string from `MenuBarManager`, `Type.menuBarTimer`, no content transition, VoiceOver label/value per § 5.6.4. Redraws on `SessionManager.tick`. | `Sources/LggrApp/Views/MenuBar/MenuBarLabel.swift` (new) | P2-48 | **SPEC item 4.** OBSERVE: with the main window closed, the menu bar shows `24:59`, `24:58`, `24:57` on successive seconds and does not reflow. |
| P2-69 | `MenuBarIdleView` — the six idle entries of § 5.5.1 in SPEC order. Phase 2 wires Start Focus Session, Quick Timer (25/50 inline, last project, inline-editable outcome), Add Accomplishment and Open Today. Capture Interruption and Open Weekly Review are **disabled with a tooltip naming their phase**. | `Sources/LggrApp/Views/MenuBar/MenuBarIdleView.swift` (new) | P2-47, P2-50 | OBSERVE: all six rows are present; the four live ones each perform their action; the two disabled ones show a tooltip on hover and cannot be clicked. |
| P2-70 | `MenuBarActiveView` — intended outcome, remaining/elapsed/overtime time with its caption, project + work type, linear progress capsule, Pause, Finish, Open Lggr. | `Sources/LggrApp/Views/MenuBar/MenuBarActiveView.swift` (new) | P2-47, P2-48 | OBSERVE, with the main window **closed**: the popover shows the outcome and a ticking time; Pause works; Finish opens the review sheet in a window that comes to the front. |
| P2-71 | `MenuBarContentView` — switches between idle and active, hosts the inline start panel, 320pt wide, keyboard-complete per § 5.5.1. | `Sources/LggrApp/Views/MenuBar/MenuBarContentView.swift` (new) | P2-69, P2-70 | OBSERVE: quit, relaunch, ⌘W to close the window, then run a full start → pause → resume → finish cycle entirely from the menu bar. |
| P2-72 | `ResultStatusPicker` — the five `SessionResultStatus` options with their symbols, selectable with ←/→ and with the keys `1`–`5`. Neutral copy and neutral colour; nothing rendered in red. | `Sources/LggrApp/Views/Review/ResultStatusPicker.swift` (new) | P2-07 | **SPEC item 7.** OBSERVE: five options, `1`–`5` select directly; `$ grep -cE '\.red\b' Sources/LggrApp/Views/Review/*.swift` → `0`. |
| P2-73 | `SummaryEditor` — a `TextEditor` prefilled from `SessionSummaryBuilder`, freely editable, with ⌘R "Regenerate". | `Sources/LggrApp/Views/Review/SummaryEditor.swift` (new) | P2-17 | OBSERVE: the field is prefilled on open; edit it, press ⌘R → the generated text returns and ⌘Z restores the edit. |
| P2-74 | `SessionReviewSheet` — 520pt: "What happened?", the status picker, the summary editor, and a progressively disclosed *Tangible result* / *Blocker* / *Next step* (collapsed by default, auto-expanded when `needsFollowUp`; only the status is required). Primary **Save** (⌘⏎) disabled until a status is chosen. Esc/`Not now` leave the session `.awaitingReview`. | `Sources/LggrApp/Views/Review/SessionReviewSheet.swift` (new) | P2-72, P2-73, P2-47 | **SPEC items 6+7.** OBSERVE: Finish opens the sheet; Save is disabled until a status is picked; the three optional fields are behind one disclosure; Escape leaves the session `.awaitingReview` and the sheet reappears next time the app is opened. |
| P2-75 | `TodayModel` — `@Observable`; loads today's sessions and accomplishments via `DateInterval.day(containing: clock.now)`, exposes them newest-first, refreshes when a session finishes, and surfaces store errors for the banner. | `Sources/LggrApp/State/TodayModel.swift` (new) | P2-14, P2-20 | Covered by `P2-78`. |
| P2-76 | `CompletedSessionRow` — outcome, project badge, time range, duration, result status, and an **Add accomplishment** action. Pure `let` inputs plus one closure. | `Sources/LggrApp/Views/Today/CompletedSessionRow.swift` (new) | P2-42, P2-16 | `$ grep -c '@Environment' Sources/LggrApp/Views/Today/CompletedSessionRow.swift` → `0`. OBSERVE in the gallery: renders correctly for a session with a project and for one without. |
| P2-77 | `TodayHeader` — the current session card if one is running, otherwise the single primary action **Start Focus**; the date on the trailing edge. | `Sources/LggrApp/Views/Today/TodayHeader.swift` (new) | P2-65, P2-41 | OBSERVE: with no session, the header shows exactly one prominent button; with a session running it shows the live timer instead. |
| P2-78 | `TodayView` — header card, then today's completed sessions, then today's accomplishments; `EmptyStateView` for each empty region with the copy from § 5.10; `ErrorBanner` at the top on failure. **No metric tiles and no timeline in Phase 2.** | `Sources/LggrApp/Views/Today/TodayView.swift` (new) | P2-75, P2-76, P2-77, P2-40 | **SPEC item 9.** OBSERVE: finish a session → within 1 s it appears in Today with the correct duration and result status; quit and relaunch → it is still there. |
| P2-79 | `AddAccomplishmentSheet` — opened from a completed session row *and* from ⌘⇧A / the menu bar. Prefills the title from the session's intended outcome, type from the result status, project inherited; `focusSessionID` set when it came from a session. Primary **Save** on ⌘⏎. | `Sources/LggrApp/Views/Accomplishments/AddAccomplishmentSheet.swift` (new) | P2-11, P2-20, P2-50 | **SPEC item 10.** OBSERVE: from a completed row, Add accomplishment → the title is prefilled with the outcome → ⌘⏎ → it appears under Today's Accomplishments and survives relaunch. In `store.json` its `focusSessionID` equals that session's `id`. |

#### Stage H — integration and closeout (P2-80 … P2-86)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-80 | `GalleryEntry` — wrapper that renders one view twice side by side with `.preferredColorScheme(.light)` and `.dark`, labelled. | `Sources/LggrApp/Dev/GalleryEntry.swift` (new) | P2-33 | `$ grep -c 'preferredColorScheme' Sources/LggrApp/Dev/GalleryEntry.swift` → ≥ 2. |
| P2-81 | `PreviewGallery` — a `Window` scene present only when `LGGR_GALLERY=1`, registering every Phase 2 presentational view against `AppEnvironment.fake()`. This is the light/dark verification loop. | `Sources/LggrApp/Dev/PreviewGallery.swift` (new) | P2-80, P2-38…P2-42, P2-65, P2-76 | `$ make gallery` → a second window listing ≥ 12 entries, each shown light and dark. `$ make run` (without the variable) → **no** gallery window. |
| P2-82 | `Previews.swift` — the same registrations as real `#Preview` macros, for a machine with Xcode. Excluded from the SPM target by `P2-04`. | `Sources/LggrApp/_XcodeOnly/Previews.swift` (new) | P2-04, P2-81 | `$ swift build` → `Build complete!` **and** `$ grep -c '#Preview' Sources/LggrApp/_XcodeOnly/Previews.swift` → ≥ 12. `$ ./Scripts/check-layering.sh` → `layering OK` (the guard must exempt this directory). |
| P2-83 | Relaunch recovery: on launch, `SessionManager.restoreActiveSession()` calls `loadActiveSession()`; a session with `endedAt == nil` resumes with the correct elapsed time (including a pause that was open at quit); one with `endedAt != nil` and `resultStatus == nil` reopens the review sheet. | `Sources/LggrApp/Services/SessionManager.swift` (edit), `Sources/LggrApp/App/LggrMain.swift` (edit) | P2-47, P2-52, P2-74 | OBSERVE (a): start a 50-min session, wait 30 s, ⌘Q, relaunch → the timer reads ~`49:30`, not `50:00`. (b): start, pause, ⌘Q, wait 60 s, relaunch → still paused, elapsed unchanged. (c): finish a session, dismiss the review with Escape, ⌘Q, relaunch → the review sheet is presented again. |
| P2-84 | Keyboard-only pass: every Phase 2 action reachable without a mouse; visible focus rings; Escape closes every sheet; Space pauses **only** when no text field has focus. | all Phase 2 views (edit) | P2-53…P2-79 | OBSERVE: ignore the mouse and complete the full walkthrough in § 7.4.3 end to end. In particular, typing a space inside the summary editor inserts a space and does **not** resume the session. |
| P2-85 | Delete the three scaffold files and the scaffold `@main`. | `Sources/LggrKit/_Scaffold.swift`, `Sources/LggrApp/_Scaffold.swift`, `Tests/LggrKitTests/_ScaffoldTests.swift` (delete) | P2-52, P2-26…P2-32 | `$ ls Sources/LggrKit/_Scaffold.swift 2>&1` → `No such file or directory`. `$ swift build && ./Scripts/test.sh` → both green, and `moduleName()` no longer appears in the test output. |
| P2-86 | Run the whole Phase 2 definition of done (§ 7.4) and record the result in the commit message. | — | P2-01 … P2-85 | Every command in § 7.4.1 produces its stated output and every step of § 7.4.3 behaves as written, on a machine where `~/Library/Application Support/Lggr/` was deleted first. |

### 7.4 Definition of done — Phase 2

Phase 3 does not begin until all three subsections pass **in one sitting, in this order**, starting
from a clean tree.

#### 7.4.1 Commands

```bash
# 0. Clean slate
rm -rf .build build ~/Library/Application\ Support/Lggr
defaults delete com.luisdoriz.lggr 2>/dev/null || true
```

| # | Command | Expected result |
|---|---|---|
| 1 | `swift build` | Ends with `Build complete!`; exit `0`; **zero warnings** in the `LggrKit` and `LggrApp` compile lines. |
| 2 | `./Scripts/test.sh` | Ends with `OK: Test run with N tests in M suites passed`, **N ≥ 50**, exit `0`. (`swift test` on its own is not acceptable evidence — § 7.1.2.) |
| 3 | `./Scripts/check-layering.sh` | `layering OK`, exit `0`. |
| 4 | `grep -rn '@Model\|#Predicate\|#Preview' Sources/LggrKit Sources/LggrApp --include='*.swift' \| grep -v '_XcodeOnly'` | **No output**, exit `1`. |
| 5 | `grep -rn 'DispatchQueue\|OperationQueue\|NSLock\|@unchecked Sendable\|import Combine\|repeatForever' Sources --include='*.swift'` | **No output**, exit `1`. |
| 6 | `grep -rn 'try!\|as!' Sources --include='*.swift'` | **No output**, exit `1`. |
| 7 | `grep -rn 'import SwiftUI\|import AppKit\|import SwiftData' Sources/LggrKit --include='*.swift'` | **No output**, exit `1`. |
| 8 | `make app` | Ends with `Built .../build/Lggr.app`; the run includes `layering OK` and a successful `codesign --verify`. |
| 9 | `plutil -lint build/Lggr.app/Contents/Info.plist` | `... : OK` |
| 10 | `codesign --verify --strict --verbose=2 build/Lggr.app` | `valid on disk` and `satisfies its Designated Requirement`. |
| 11 | `otool -L build/Lggr.app/Contents/MacOS/LggrApp \| grep -icE 'CFNetwork\|/Network\.framework\|libcurl'` | `0` — the "zero network code" claim in the README is mechanically true. |
| 12 | `swift package dump-package \| python3 -c "import json,sys;print(json.load(sys.stdin)['dependencies'])"` | `[]` — no third-party dependencies. |
| 13 | `LGGR_SWIFTDATA=1 swift build` | **Not run on this machine.** Recorded as *deferred, Xcode required*; the acceptance evidence is that `Package.swift` contains the conditional target and `Sources/LggrPersistence/` is absent, so step 1 is unaffected. Runs for real in `P3-12`. |
| 14 | *(after § 7.4.3)* `python3 -c "import json;d=json.load(open('$HOME/Library/Application Support/Lggr/store.json'));print(d['schemaVersion'],len(d['projects']),len(d['sessions']),len(d['accomplishments']))"` | `1 1 1 1` — one project, one session and one accomplishment persisted at schema version 1. |
| 15 | `ls -le ~/Library/Application\ Support/Lggr/` | `drwx------` on the directory and `-rw-------` on `store.json`. |

#### 7.4.2 Test-count floor per file

`./Scripts/test.sh --filter <Name>` must report at least:

| Suite | Minimum tests |
|---|---|
| `FocusSessionTimingTests` | 14 |
| `LggrStoreContractTests` | 14 (7 cases × 2 backends) |
| `CodableRoundTripTests` | 8 |
| `DurationFormattingTests` | 8 |
| `UserPreferencesTests` | 6 |
| `JSONFileStoreTests` | 4 |
| `SessionSummaryBuilderTests` | 4 |
| `StoreSnapshotCodableTests`, `EnumsTests`, `SupportTests` | 2 each |

These are floors to stop a suite silently shrinking, not targets to pad toward.

#### 7.4.3 The manual walkthrough — all ten SPEC Phase 2 items, keyboard only

Run against `build/Lggr.app` after the clean slate. Twelve steps; every one has a stated expected
result. A failure at any step means Phase 2 is not done.

| # | Action | Expected result | SPEC item |
|---|---|---|---|
| 1 | `open build/Lggr.app` | Window opens ~1040×720 on **Today**; Today shows an empty state; the menu bar shows the `timer` symbol with no digits. | — |
| 2 | ⌘5, then the New Project action; type `SOR engineering`; pick purple + `hammer`; ⌘⏎ | The project appears in the list with a purple `hammer` badge. | **1. Create a project** |
| 3 | ⌘N; type `Finish the receipt deduplication PR`; ⌘⏎ — timed from the ⌘N keypress | The session is running in **under 5 seconds**. `SOR engineering` was preselected; work type Deep work; duration 50 minutes. | **2. Start a focus session** |
| 4 | Look at the main window | The timer is the largest element on screen, reading `49:5x` and decrementing once per second; the intended outcome is directly beneath it. | **3. Timer in the main window** |
| 5 | ⌘W to close the window; look at the menu bar; open the popover and hold it open for 10 s | The menu bar shows a decrementing `49:xx`, and it keeps decrementing while the popover is open (`.common` run-loop mode). | **4. Timer in the menu bar** |
| 6 | Press Space (or Pause in the popover); wait 15 s; press Space again | The symbol becomes `pause.circle`, the digits are frozen for the full 15 s, and on resume the clock continues from exactly where it stopped — 15 s were lost, not counted. | **5. Pause and resume** |
| 7 | Finish, from the popover | The main window comes to the front with the review sheet presented, asking **What happened?** | **6. Finish the session** |
| 8 | Press Escape, then ⌘Q, then relaunch | The review sheet is presented again — an unreviewed session is never lost. | — |
| 9 | Choose **Made progress**; leave the generated summary as-is; ⌘⏎ | The sheet dismisses. The generated summary mentions the intended outcome, the project and the duration. | **7. Select the result status** |
| 10 | ⌘Q, relaunch, ⌘1 | Today lists the completed session with the correct time range, duration and "Made progress". | **8. Persist the session** · **9. Show it in Today** |
| 11 | Tab to the session row's **Add accomplishment** action and activate it; ⌘⏎ | The sheet opens with the title prefilled from the intended outcome; on save the accomplishment appears under Today's Accomplishments. | **10. Add an accomplishment from the completed session** |
| 12 | ⌘Q, relaunch; then run § 7.4.1 command 14 | The accomplishment is still there and its `focusSessionID` matches the session's `id`. | — |

Plus two appearance checks:

- `make gallery` — every registered view is legible and correctly contrasted in **both** columns.
- Switch System Settings → Appearance between Light and Dark **while the app is running** — every
  screen re-renders correctly with no stale colours.

### 7.5 Phase 3 — automatic application tracking

Task-level granularity. Expanded to Phase-2 detail when Phase 2 is accepted.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P3-01 | Phase 3 model types: `ActivityEvent` (+ `redactedIfPrivate()`, `duration(at:)`, `debugDescription`), `ActivitySample`, `ClassificationRule` (+ `matches`, `specificity`), `Interruption`, and their enums appended to `Enums.swift`. | `Sources/LggrKit/Model/ActivityEvent.swift`, `ActivitySample.swift`, `ClassificationRule.swift`, `Interruption.swift`, `Enums.swift` (edit) | P2-86 | TEST `ActivityEventTests`, `ClassificationRuleTests` pass; every `redactedIfPrivate()` field assertion from § 4.2.5 is covered; `debugDescription` contains neither title nor domain. |
| P3-02 | Extend `LggrStore` with the `[P3]` methods in all conformers, including the redaction re-assertion in `saveActivityEvents`. | `Sources/LggrKit/Store/*.swift` (edit) | P3-01 | `LggrStoreContractTests` grows to cover activity, interruption and rule CRUD, still every case × every backend, plus "a private event with a populated title cannot be persisted". |
| P3-03 | `ApplicationMonitoring` protocol + `WorkspaceApplicationMonitor` + `StubApplicationMonitor`. | `Sources/LggrApp/Services/ApplicationMonitoringService.swift` | P2-86 | OBSERVE: switch between three apps; the live activity strip names each within 1 s. The `NSRunningApplication` type never escapes the `for await` body. |
| P3-04 | `IdleDetecting` protocol + `HIDIdleDetector` (CGEventSource, 15 s poll, no Accessibility needed) + `StubIdleDetector`. | `Sources/LggrApp/Services/IdleDetectionService.swift` | P2-86 | OBSERVE: with `idleThreshold` set to 60 s, do not touch the machine for 70 s — the timeline shows an idle block starting at ~60 s. |
| P3-05 | `ActivityTrackingService` — the exact capture pipeline of § 6.7.4, closed intervals attached to the session, batched writes, redaction at capture time, `SleepWakeObserver` closing intervals at the sleep timestamp. | `Sources/LggrApp/Services/ActivityTrackingService.swift`, `SleepWakeObserver.swift` (edit) | P3-02…P3-04 | TEST `PrivacyRedactorTests`; plus `$ grep -c 'PrivacyRedactor' Sources/LggrApp/Services/ActivityTrackingService.swift` → ≥ 1 on the write path, and the service never constructs an `ActivityEvent` directly. |
| P3-06 | Pure aggregation: `ActivityAggregator`, `ActivityCoalescer` (with the 2 s adjacency rule), `ContextSwitchCounter`, `SessionTimelineBuilder`. | `Sources/LggrKit/Domain/*.swift` | P3-01 | TEST `ActivityAggregatorTests`, `ActivityCoalescerTests` (incl. `doesNotMergeAcrossAnExcludedGap`), `ContextSwitchCounterTests`, `SessionTimelineBuilderTests` all pass. |
| P3-07 | `ClassificationEngine` (pure) + `ClassificationService` (cache) + the shipped default rule set (useful on bundle IDs alone). | `Sources/LggrKit/Domain/ClassificationEngine.swift`, `Sources/LggrApp/Services/ClassificationService.swift` | P3-01 | TEST `ClassificationEngineTests`: ordering is priority → specificity → id; a `.manual` event is never reclassified. |
| P3-08 | `WindowTitleReader` (AX, gated on `AXIsProcessTrusted()`, 0.25 s messaging timeout, skipped under secure input) and `BrowserDomainReader` (an `actor`, Apple Events, opt-in, host only) + `DomainExtractor`. | `Sources/LggrApp/Services/WindowTitleReader.swift`, `BrowserDomainReader.swift`, `Sources/LggrKit/Domain/DomainExtractor.swift` | P3-03 | TEST `DomainExtractorTests`. OBSERVE: with Accessibility **denied**, the app still records app names and never prompts twice; with it granted, window titles appear on the next interval without a relaunch. |
| P3-09 | `PrivacyRedactor` + the privacy exclusion UI + the `check-layering.sh` privacy guards. | `Sources/LggrKit/Domain/PrivacyRedactor.swift`, `Sources/LggrApp/Views/Settings/PrivacySettingsView.swift`, `Scripts/check-layering.sh` (edit) | P3-05, P3-07 | OBSERVE: mark an app private, use it, then `grep store.json` for that app's name, bundle id and a distinctive title — **zero hits**. Exclude an app and confirm the § 6.7.3 worked example exactly. |
| P3-10 | `LiveActivityStrip`, `SessionTimelineStrip`, `SessionStatsGrid`. | `Sources/LggrApp/Views/Focus/*`, `Views/Review/SessionStatsGrid.swift` | P3-06 | OBSERVE: the review sheet now shows total/focused/idle time, context-switch count and time by category, matching a hand-computed fixture. |
| P3-11 | `InterruptionCaptureSheet` + ⌘⇧I enabled, in both hosts. | `Sources/LggrApp/Views/Focus/InterruptionCaptureSheet.swift`, `App/AppCommands.swift` (edit) | P3-02 | OBSERVE: ⌘⇧I during a session saves a note to the inbox **without** ending or pausing the session and increments `interruptionCount`. Also decide and document whether `interruptionCount` is reconciled on load or trusted. |
| P3-12 | Ship the `LggrPersistence` target (`SD*` models + mappings + `SwiftDataStore`) and run the contract suite against it. | `Sources/LggrPersistence/**` | P3-02 | On a machine with Xcode: `LGGR_SWIFTDATA=1 swift build` → `Build complete!`, and `LGGR_SWIFTDATA=1 ./Scripts/test.sh --filter LggrStoreContract` → the suite runs against 3 backends with identical results. |
| P3-13 | **Empirically settle the sandbox-vs-Accessibility question** (Appendix B): build with the sandbox on, grant Accessibility, call `AXUIElementCopyAttributeValue` against Finder, record the exact `AXError` in `CONSTRAINTS.md`. | `docs/_design/CONSTRAINTS.md` (edit) | P3-08 | `CONSTRAINTS.md` gains a dated line naming the observed `AXError`. If it contradicts § 6.2, that section is revisited. |

### 7.6 Phase 4 — daily experience

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P4-01 | `DailyDigest` — the Today metric rollup (tracked/focused/reactive/meeting/communication time, session count, switches, completed outcomes, open inbox count). | `Sources/LggrKit/Domain/DailyDigest.swift` | P3-06 | TEST `DailyDigestTests` against a fixture day whose totals are computed by hand in the test. |
| P4-02 | `TodayMetricsRow`, `DailyTimelineView`, `TimelineBlockView` — grouped blocks, not one row per switch. | `Sources/LggrApp/Views/Today/*`, `Components/MetricTile.swift` | P4-01 | OBSERVE: a day with 40 app switches across 3 sessions renders ≤ 8 timeline blocks, each labelled like `SPEC.md` § 7's `9:00–9:52 / Receipt deduplication / Xcode, Terminal, GitHub / Completed`. |
| P4-03 | `AccomplishmentLogView`, `AccomplishmentRow`, `AccomplishmentTypePicker`. | `Sources/LggrApp/Views/Accomplishments/*` | P2-79 | OBSERVE: the log groups by week, filters by project and type, and all 11 accomplishment types are selectable. |
| P4-04 | `InterruptionInboxView` + inbox badge. | `Sources/LggrApp/Views/Today/InterruptionInboxView.swift`, `State/InboxModel.swift` | P3-11 | OBSERVE: capture 3 interruptions; the badge reads 3; resolving one drops it to 2 and the item leaves the inbox. The section hides entirely when empty. |
| P4-05 | `FocusSessionsView`, `FocusSessionDetailView`. | `Sources/LggrApp/Views/Sessions/*` | P3-10 | OBSERVE: ⌘2 lists sessions newest-first grouped by day; an `.awaitingReview` row shows `[ Review ]`; opening one shows its timeline and stats. |
| P4-06 | Markdown rendering: `MarkdownRendering`, `DailySummaryMarkdown`, `AccomplishmentLogMarkdown`, `ActivityCSVExporter`. | `Sources/LggrKit/Export/*` | P4-01 | TEST `MarkdownExportTests`: a fixture day renders to a byte-exact expected string held in the test; no `Optional(`, no `nil`, no trailing whitespace, one trailing newline. |
| P4-07 | `ExportService` — `NSSavePanel` + write; export-before-delete wired into every destructive confirmation. | `Sources/LggrApp/Services/ExportService.swift` | P4-06 | OBSERVE: File → Export writes a `.md` file whose contents equal `DailySummaryMarkdown`'s output for that day; every destructive sheet shows an `Export…` button between Cancel and the destructive action. |
| P4-08 | `RetentionPruner` + per-day and per-session activity deletion (`deleteActivityEvents(in:)`, `deleteActivityEvents(sessionID:)`). | `Sources/LggrApp/Services/RetentionPruner.swift`, `Sources/LggrKit/Store/*` (edit) | P4-07 | TEST `RetentionTests`. OBSERVE: set retention to 30 days with older data present → the prune runs, the store shrinks, and every session and accomplishment older than 30 days is still listed. |

### 7.7 Phase 5 — weekly review

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P5-01 | `WeeklyOutcome` + `OutcomePriority`/`OutcomeStatus`; store methods in all conformers. | `Sources/LggrKit/Model/WeeklyOutcome.swift`, `Store/*` (edit) | P4-08 | `LggrStoreContractTests` covers outcome CRUD and week-range queries on every backend. |
| P5-02 | `WeeklyOutcomesView`, `WeeklyOutcomeEditor`, `WeeklyModel`. | `Sources/LggrApp/Views/Weekly/*`, `State/WeeklyModel.swift` | P5-01 | OBSERVE: creating a second primary outcome shows a gentle inline hint and is **not** blocked — `maximumPerWeek` is a soft cap. |
| P5-03 | `PlannedVsReactive`. | `Sources/LggrKit/Domain/PlannedVsReactive.swift` | P5-01 | TEST `PlannedVsReactiveTests`: a fixture week of 6 sessions yields the hand-computed split; an explicit `isReactive` overrides `workType.isReactiveByDefault`; the two shares sum to the total tracked time. |
| P5-04 | `WeeklyReviewBuilder` — time by project / work type / category, sessions completed vs interrupted, switches per day, main accomplishments, unblocking count, primary-outcome share. | `Sources/LggrKit/Domain/WeeklyReviewBuilder.swift` | P5-03, P4-01 | TEST `WeeklyReviewBuilderTests`: every field asserted against a hand-computed fixture week; percentages sum to 100 ± 0.1. |
| P5-05 | `InsightGenerator` — neutral, evidence-based observations only. | `Sources/LggrKit/Domain/InsightGenerator.swift` | P5-04 | TEST `InsightGeneratorTests`: fixtures produce the `SPEC.md` § 9 sentence shapes; **and a lexicon test asserts no output contains any word from the banned judgmental list** (`should`, `only`, `wasted`, `failed`, `poor`, `bad`, `behind`, `missed`, `unproductive`, `distracted`). |
| P5-06 | `WeeklyReviewView`, `TimeAllocationChart`, `InsightList`. | `Sources/LggrApp/Views/Weekly/*` | P5-04, P5-05 | OBSERVE: ⌘4 shows the review in the § 5.4.4 order; Swift Charts appears in exactly one file; two charts on the screen and zero gradients. |
| P5-07 | `WeeklyReviewMarkdown`, `SessionsCSVExporter`. | `Sources/LggrKit/Export/*` | P5-04 | TEST `MarkdownExportTests` (weekly) reproduces `SPEC.md`'s example structure; TEST `CSVExportTests`: the header row is exact, embedded commas, quotes and newlines are escaped, and the file round-trips through a CSV parser. |

### 7.8 Phase 6 — product polish

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P6-01 | Onboarding — the six screens of § 6.5 with the copy verbatim. | `Sources/LggrApp/Views/Onboarding/*` | P5-07 | OBSERVE: shown exactly once (`hasCompletedOnboarding`); explicitly lists what is never collected; `Esc` skips; relaunching does not show it again. |
| P6-02 | `PermissionsService` — the § 6.4 contract; requests fired only from the three sanctioned call sites; the single-banner re-ask policy of § 6.6. | `Sources/LggrApp/Services/PermissionsService.swift`, `Components/PermissionBanner.swift` | P6-01 | OBSERVE: deny Accessibility, then use the app for 10 minutes across two launches — **zero further prompts**, tracking degrades to app-name-only, and the word "denied" appears nowhere. `check-layering.sh` finds no prompt call outside the three sites. |
| P6-03 | `GlobalShortcutService` — Carbon `RegisterEventHotKey`, default ⌘⇧Space, configurable, opening the start panel inline in the popover. | `Sources/LggrApp/Services/GlobalShortcutService.swift`, `Views/Settings/ShortcutsSettingsView.swift` | P6-02 | OBSERVE: with Lggr in the background and another app frontmost, ⌘⇧Space brings up the start panel without opening the main window; rebinding to ⌥⇧F5 works after the rebind and after a relaunch; a taken combination shows the inline caption, not an alert. |
| P6-04 | `NotificationService` + the three notification kinds. | `Sources/LggrApp/Services/NotificationService.swift`, `Views/Settings/NotificationsSettingsView.swift` | P6-02 | OBSERVE: a 1-minute session posts a completion notification whose default action opens the review sheet; with the toggle off it posts none. `RecordingNotifier` asserts the same in the gallery. |
| P6-05 | Settings — one `SettingsView` hosted by both the `Settings` scene (⌘,) and the sidebar row (⌘7); the five tabs of § 5.4.7 including the full Privacy pane of § 6.9. | `Sources/LggrApp/Views/Settings/*` | P6-03, P6-04 | OBSERVE: ⌘, and ⌘7 show the same content; every `UserPreferences` field is reachable; "Delete All Activity History" empties activity and nothing else, with the § 6.8.4d copy. |
| P6-06 | `LaunchAtLoginService` (`SMAppService`), handling all four statuses. | `Sources/LggrApp/Services/LaunchAtLoginService.swift` | P6-05 | OBSERVE: toggling it on registers the login item and the state survives a relaunch; a throwing `register()` reverts the toggle and shows the inline caption. |
| P6-07 | Hide-Dock-icon preference via `NSApp.setActivationPolicy(.accessory)`, with the popover growing `Preferences…` and `Quit Lggr` rows when it is on. | `Sources/LggrApp/App/AppDelegate.swift` (edit) | P6-05 | OBSERVE: toggling it hides the Dock icon at runtime with no relaunch; the `MenuBarExtra` and the global hot key keep working; the help text warns that the menu commands go away. |
| P6-08 | Empty and error states everywhere; store failures surface as inline, recoverable messages per § 5.3.3. | all views (edit) | P6-05 | OBSERVE: with `store.json` made read-only, saving a session shows the § 5.5.3 alert naming the recovery actions and the session is not silently lost; every list shows its designed empty state. |
| P6-09 | Accessibility pass — VoiceOver labels per § 5.8.2, contrast, Dynamic Type, `ViewThatFits` fallbacks. | all views (edit) | P6-08 | OBSERVE: VoiceOver reads a meaningful label for every control on Today, the start panel and the review sheet; at the largest Dynamic Type size no text is clipped in any screen. |
| P6-10 | Light/dark refinement pass across the whole gallery. | `Sources/LggrApp/DesignSystem/*` (edit) | P6-09 | OBSERVE: every gallery entry passes a side-by-side review; no hard-coded hex outside `Palette.swift`. |
| P6-11 | Icon + version metadata for a distributable build; hardened runtime, Developer ID, notarisation. | `Resources/*` (edit), `Scripts/make-app.sh` (edit) | P6-10 | `$ codesign --verify --strict build/Lggr.app` passes; `CFBundleShortVersionString` is bumped; `Scripts/make-icon.sh` regenerates the icon reproducibly; `spctl -a -vv build/Lggr.app` accepts the notarised build. |

### 7.9 Unit test inventory

`SPEC.md` names ten behaviours. Each is listed with the **phase in which it first becomes testable**,
the file it lives in, and what "passing" means.

| # | SPEC behaviour | First testable | File | Passing means |
|---|---|---|---|---|
| 1 | **Timer behaviour** | **P2** (`P2-26`) | `FocusSessionTimingTests.swift` | `elapsed`/`remaining`/`overrun`/`progress`/`effectiveDuration` against injected `Date`s; open-ended returns `nil` remaining; `elapsed` never exceeds the wall-clock span; a finished session returns the same `elapsed` for every `now`. |
| 2 | **Pause and resume calculations** | **P2** (`P2-26`) | same file | The exact worked table in § 4.3.2 (two cycles → `pausedDuration == 900`, `elapsed == 2700`); frozen clock while paused; double-pause, orphan-resume, backwards-clock and finish-while-paused all behave as § 4.3.5 states. |
| 3 | **Session completion** | **P2** (`P2-26`, `P2-28`) | `FocusSessionTimingTests` + `SessionSummaryBuilderTests` | `finish` is idempotent and clamps `endedAt ≥ startedAt`; `state` moves `running → awaitingReview → completed` as `resultStatus` is set; the generated summary is deterministic and contains no `Optional`/`nil`. |
| 4 | **Activity aggregation** | **P3** (`P3-06`) | `ActivityAggregatorTests` (+ `ActivityCoalescerTests`) | Totals by application and by category over a fixture day match hand-computed values; adjacent same-app intervals coalesce within 2 s and never across a gap; open intervals are measured against an injected `now`; idle intervals are excluded from focused time. |
| 5 | **Context-switch calculation** | **P3** (`P3-06`) | `ContextSwitchCounterTests` | A → B → A counts 2; A → A counts 0; an idle interval between two A intervals does not create a switch; an excluded-app gap between two A intervals counts 0; switches are counted per session and per day. |
| 6 | **Planned versus reactive calculation** | **P5** (`P5-03`) | `PlannedVsReactiveTests` | A fixture week splits into planned/reactive seconds matching hand-computed values; an explicit `isReactive` overrides `workType.isReactiveByDefault`; the two shares sum to the total tracked time. |
| 7 | **Rule matching** | **P3** (`P3-01`, `P3-07`) | `ClassificationRuleTests` (+ `ClassificationEngineTests`) | All four `RuleMatchType`s; case-insensitivity; `domain` matches exactly and by suffix (`github.com` matches `gist.github.com` but not `notgithub.com`); project and work-type scoping; disabled rules never match; a private event never matches; ordering is priority → specificity → id; a `.manual` event is never reclassified. |
| 8 | **Private application handling** | **P3** (`P3-01`, `P3-09`) | `PrivacyRedactorTests` (+ `ActivityEventTests`) | `redactedIfPrivate()` sets `applicationName == "Private activity"`, empties `bundleIdentifier`, nils `windowTitle` and `domain`, sets category `.unknown` and source `.unclassified`; excluded → `nil` event; excluded beats private; the redacted value is what reaches the store, asserted by writing through every backend and reading back; `debugDescription` leaks nothing. |
| 9 | **Weekly summary generation** | **P5** (`P5-04`, `P5-05`) | `WeeklyReviewBuilderTests` (+ `InsightGeneratorTests`) | Every weekly field matches a hand-computed fixture week; percentages sum to 100 ± 0.1; generation is deterministic; no insight string contains a word from the banned judgmental lexicon. |
| 10 | **Markdown export** | **P4** for daily + accomplishment log (`P4-06`); **P5** for the weekly review (`P5-07`) | `MarkdownExportTests` | Byte-exact comparison against an expected document held in the test; heading levels and bullet order match `SPEC.md`'s example; no `Optional(`, no `nil`, no trailing whitespace, one trailing newline. |

**Supporting suites that the spec does not name but the architecture requires:**

| Suite | Phase | Covers |
|---|---|---|
| `LggrStoreContractTests` | P2 (grows every phase) | The same cases run against `InMemoryStore`, `JSONFileStore` and — under `LGGR_SWIFTDATA=1` from `P3-12` — `SwiftDataStore`. Upsert-by-id, range queries, `loadActiveSession`, project-delete nullification, session-delete cascade equivalence, private-event redaction at the write boundary. **This is what makes the three backends interchangeable.** |
| `CodableRoundTripTests` | P2 | Every value type and every enum **raw string** survives encode/decode, so a Swift rename cannot silently invalidate stored JSON. |
| `StoreSnapshotCodableTests` | P2 | `schemaVersion` policy: a newer version is refused with a clear error; an equal version round-trips. |
| `JSONFileStoreTests` | P2 | Durability across a restart, atomic writes leaving no temp file, `0600`/`0700` permissions, missing file → empty store, corrupt file → `invalidData` with the bad file preserved. |
| `DurationFormattingTests` | P2 | Every format the timer and menu bar render, including overrun and the zero case. |
| `UserPreferencesTests` | P2 | Exclusion/private matching, `retentionCutoff`, `UserDefaults` round-trip in a scratch suite, `id == singletonID`. |
| `EnumsTests`, `SupportTests` | P2 | Case counts, `suggestedDuration` defaults, `FixedClock`, calendar windows including a DST transition, fixture determinism. |
| `DomainExtractorTests` | P3 | Host-only extraction and every malformed input. |
| `SessionTimelineBuilderTests` | P3 | Grouped timeline blocks: contiguous same-session intervals merge; blocks under 90 s merge into a neighbour; block labels list the top 3 applications. |
| `DailyDigestTests`, `RetentionTests` | P4 | Today's rollup against a hand-computed fixture day; retention prunes activity only, idempotently, never the open interval. |
| `CSVExportTests` | P5 | Exact header row; commas, quotes and newlines inside fields are escaped and survive a round-trip parse. |

### 7.10 What could make Phase 2 slip

Ordered by *expected days lost* = likelihood × cost. Each has a tripwire (how you find out early) and
a fallback (what you do instead).

**1. `MenuBarExtra`'s label does not redraw at 1 Hz — high likelihood, 1–3 days.** The label of a
`MenuBarExtra` is not a normal view: it is hosted by the system, rebuilt on its own schedule, and a
well-known source of "my timer freezes in the menu bar" reports. If it does not observe
`SessionManager.tick` in a way SwiftUI honours, **SPEC Phase 2 item 4 cannot be delivered at all**,
and it is easy not to notice until the end of the phase.
*Tripwire:* do `P2-46` + `P2-48` + `P2-68` as a throwaway spike **on day one**. Does the menu bar count
down for 60 uninterrupted seconds, and does it keep counting while the popover is open?
*Fallback:* drop `MenuBarExtra` for an AppKit `NSStatusItem` owned by `AppDelegate`, whose
`button.title` is set directly from the tick. Contained to two files *if* nothing else has been built
on the `MenuBarExtra` scene — which is exactly why the spike goes first.

**2. A false-green test suite — medium likelihood, unbounded cost.** `swift test` exits `0` having run
**nothing** on this machine. Any agent that reports "tests pass" from a raw `swift test` has reported
nothing at all, and the error compounds silently across every subsequent task.
*Tripwire:* `./Scripts/test.sh` already fails on a missing `Test run with N tests` line. The residual
risk is an agent bypassing it.
*Fallback:* none needed — enforce it. Every acceptance criterion names `./Scripts/test.sh`, never
`swift test`, and the README's first code block does too.

**3. Store-shape churn — medium likelihood, 1–2 days.** The source documents described two
incompatible `LggrStore`s. If two agents pick differently, every call site in stages E–G has to be
rewritten.
*Tripwire:* it is resolved in Appendix A, C1. `P2-20` is a hard dependency of everything in stages C, F
and G, so a wrong choice is visible on the very next task rather than at integration.
*Fallback:* if `@MainActor` store access ever stutters the UI (it should not at hundreds of KB), the
change is confined to `JSONFileStore.swift` — move more work into the `nonisolated` encode helper. No
call site changes, because `async throws` already allows the hop.

**4. Design churn from having no `#Preview` — medium likelihood, 1–2 days.** Twenty-six view tasks with
no live preview canvas means a full `make app` cycle for every visual tweak, and light/dark problems
that surface only at the end.
*Tripwire:* build `P2-80`/`P2-81` (the gallery) **before** the view stage, not after — reorder them
ahead of `P2-38` if there is any doubt. Register each component the moment it is written.
*Fallback:* accept a slightly rougher visual pass in Phase 2 and schedule refinement into `P6-10`,
which exists for exactly this. Do **not** let visual polish block the ten functional spec items.

**5. Sheet routing across the menu bar / main window boundary — medium likelihood, 0.5–1 day.**
Finishing a session from the popover with the main window closed must open the window, bring the app to
the front, and present the review sheet. Each of `openWindow`, `NSApp.activate` and sheet presentation
has its own timing quirk, and getting it wrong loses a completed session behind a window nobody sees.
*Tripwire:* step 7 of § 7.4.3 exercises exactly this path; run it as soon as `P2-70` and `P2-74` exist.
*Fallback:* `P2-83`'s relaunch recovery is the safety net — an unreviewed session is re-offered on the
next launch, so the data is never lost even if the presentation is briefly wrong.

**6. Scope creep from Phase 3 into the review sheet and Today — medium likelihood, 1–3 days.** SPEC § 6
and § 7 describe rich screens (focused/idle time, context switches, time by category, timeline,
metrics). **None of that is computable in Phase 2** because there are no `ActivityEvent`s. The
temptation to "just add the stats grid" pulls the whole activity tracker forward.
*Tripwire:* `P2-67`'s and `P2-78`'s acceptance criteria explicitly assert the *absence* of those
elements.
*Fallback:* none — this is a discipline item. The phase markers in § 3.5 are the contract.

**7. `ExistentialAny` and Swift 6 strictness churn — medium likelihood, 0.5 day.** Every bare protocol
type is a compile error, and `@MainActor` `@Observable` classes in an executable target produce
isolation diagnostics that are easy to "fix" by scattering `@preconcurrency` or `nonisolated` in the
wrong places.
*Tripwire:* `swift build` after **every** task. The § 7.4.1 zero-warning requirement catches
accumulated papering-over.
*Fallback:* the isolation rules in § 3.8.1 are absolute. If a fix requires `@unchecked Sendable` or a
`DispatchQueue`, the design is wrong; § 7.4.1 commands 5 and 6 fail the build rather than let it in.

**8. Space-to-pause fighting text input — low likelihood, 0.5 day.** Bound naively it makes the summary
editor and the outcome field unusable.
*Tripwire:* `P2-84`'s acceptance explicitly types a space into the summary editor.
*Fallback:* scope the shortcut to `ActiveSessionView` only and gate it on `@FocusState`; if that is
still ambiguous, move it to ⌘P and record the deviation from the spec here.

**9. Ad-hoc signature identity churn — low likelihood in Phase 2, 0 days now.** Every `make-app.sh` run
produces a new code identity, so macOS forgets TCC grants. Phase 2 requests no permissions, so this
costs nothing now — but it will dominate Phase 3 debugging if not set up in advance.
*Fallback:* create a self-signed `Lggr Dev` code-signing certificate and export `LGGR_SIGN_IDENTITY`
before starting `P3-08`. The variable is already plumbed by `P2-02`.

**10. Fixture non-determinism leaking into tests — low likelihood, 0.5 day.** `PreviewFixtures` using
`Date()` or fresh `UUID()`s produces tests that pass locally and fail an hour later or in a different
time zone.
*Tripwire:* `P2-18`'s acceptance asserts repeat-call identity; `P2-10`'s asserts zero `Date()` calls in
the timing file.
*Fallback:* all fixture dates come from `FixtureCalendar` with a fixed-offset calendar, and all fixture
UUIDs are `static let` constants.

---

## Appendix A — Resolved conflicts

The six source documents disagreed in the places below. Each is resolved once, here, so no agent
decides it twice. The governing rule: `03-data-model.md` was the declared authority for *type names,
field names and signatures*; `02-architecture.md` for *targets, folders, build and concurrency*;
`06-checklist.md` for *what is actually on disk today*; and where none of those settled it, the
product principles in `SPEC.md` did.

| # | Topic | The disagreement | **Resolution applied throughout this document** |
|---|---|---|---|
| **C1** | `LggrStore` isolation and method names | `02` § 4.2: `protocol LggrStore: Sendable`, `actor` conformers, `allProjects()` / `upsert(_:)` / `sessions(in:)`. `03` § 4: `@MainActor protocol LggrStore: AnyObject`, `loadProjects()` / `saveProject(_:)` / `loadSessions(in:)` / `loadActiveSession()`. These cannot both be implemented. | **`03` wins.** `@MainActor` + `AnyObject`, `load*`/`save*`/`delete*` naming (§ 4.4.1). SwiftData's `ModelContext` is main-actor bound, so this is the shape SwiftData forces, and `loadActiveSession()` is required by the relaunch-recovery behaviour. `02`'s real intent — no file I/O on the main thread — is preserved by doing encode + atomic write inside a `nonisolated` helper that `JSONFileStore` `await`s (§ 3.8.1, task P2-24). |
| **C2** | `flush()` | `02` depends on it for 500 ms write coalescing and calls it from `applicationWillTerminate`; `03`'s protocol has no such method. | **Added to the protocol** as `func flush() async throws`. It is a lifecycle method, not a query; `SwiftDataStore` implements it as `try context.save()`. |
| **C3** | Where `UserPreferences` lives | `02`: `preferences()` / `save(_:)` on `LggrStore`. `03` § 7: `UserDefaults` behind `PreferencesStoring`, explicitly *not* on `LggrStore`. | **`03` wins** (§ 4.4.2). A store failure must never cost the user their hot key or their privacy settings, and preferences are read before any store is opened. `Sources/LggrKit/Store/PreferencesStore.swift` is added to the Phase 2 file list, which `02`'s tree omitted. |
| **C4** | `AppEnvironment` has no preferences store | `03` moved preferences out of `LggrStore`, but `02` § 5.1's `AppEnvironment` never constructed one — yet `StartSessionForm` needs `lastSelectedProjectID` and `MenuBarManager` needs `showTimerInMenuBar` on the first frame. | **`public let preferences: any PreferencesStoring` added** to `AppEnvironment` and to both factories (§ 3.7.1). |
| **C5** | Session timing API | `02`: `Domain/SessionClock.swift` + `Domain/SessionLifecycle.swift`, static funcs taking `now:`. `03`: `mutating` methods and computed properties on `FocusSession`, in `Model/FocusSession+Timing.swift`. | **`03` wins.** `SessionClock.swift` and `SessionLifecycle.swift` are **not created**. Two static-function façades over methods that already exist on the value type would be exactly the "abstraction without two implementations" that `02` § 8 itself forbids. Consequently the test file is one `FocusSessionTimingTests.swift`, not `SessionClockTests` + `SessionLifecycleTests`. |
| **C6** | SwiftData class prefix and mapping filenames | `02`: `StoredProject`, `Mapping/ProjectMapping.swift`. `03`: `SDProject`, `Mapping/SDFocusSession+Mapping.swift`. | **`03` wins.** `SD*` prefix, `Models/SD<Entity>.swift`, `Mapping/SD<Entity>+Mapping.swift` (§ 3.5, § 4.5). |
| **C7** | Enum file layout | `02`: `Model/WorkType.swift`, enums beside their struct. `03`: one `Model/Enums.swift`. | **`03` wins.** One `Model/Enums.swift`, appended each phase. `Model/WorkType.swift` and `Model/ActivityCategory.swift` are not created. |
| **C8** | JSON on-disk layout | `02` § 7.7: one `StoreSnapshot` root at `…/Lggr/store.json` with `schemaVersion`. `03` § 4 (and `05` § 7.1): "one JSON file per aggregate", listing seven files. | **`02` wins.** A single `store.json` with one `StoreSnapshot` root and an explicit `schemaVersion: Int` (§ 4.4.1, § 6.8.1). `02` has a dedicated file for it and a stated version policy; `03` mentioned it only in passing. `05`'s seven-file directory listing is corrected here, and the onboarding copy and *Reveal Data Folder* affordance name the real layout. |
| **C9** | State-object names | `02` § 3: `AppModel`, `TodayModel`, `ProjectsModel`. `03` § 4 prose: `TodayStore`, `SessionStore`. | **`02` wins** — those are the names in the folder tree, and "Store" is already taken by the persistence boundary. |
| **C10** | `PrivacyRedactor` vs `redactedIfPrivate()` | `02`'s tree listed `Domain/PrivacyRedactor.swift`; `03` § 2.4 put redaction on the value type. Duplicating the erasure logic in two places would be worse than either. | **Both, with distinct jobs** (§ 6.7.4). `PrivacyRedactor` is the *policy* layer — it reads `UserPreferences`, decides excluded/private, and converts the non-`Codable` `ActivitySample` into an `ActivityEvent?`. `redactedIfPrivate()` is the idempotent *erasure* on the value type, applied at capture **and re-applied by every store's `saveActivityEvents`** as a defence-in-depth write boundary. |
| **C11** | `NSAccessibilityUsageDescription` | `02` § 7.4 and `05` § 12: the key is not a macOS TCC key, remove it. `06` C11: keep it as harmless self-documentation. | **Keep it** (§ 3.9.4, § 6.1.1 note 1). `02` and `05` are factually right that macOS ignores it, and that fact is now stated wherever the key is mentioned — but removing it changes no behaviour, and `P2-03` is written to leave it alone. The real explanation lives in the onboarding screen. |
| **C12** | `trackWindowTitles` default | `02` § 7.7 promised title capture is "opt-in, off until the user enables it"; `03` § 2.8 defaults it to `true`. | **Keep `true`, under the stated rule "permission is the gate, preference is the switch"** (§ 4.2.4). Nothing is captured until Accessibility is granted, which is a real, system-owned consent gate; the `true` default only means the feature works the moment the user grants it. The onboarding permission screen always writes the value explicitly, so first run is a deliberate choice either way. `trackBrowserDomains` defaults to **`false`**, because the Automation prompt's wording deserves an explicit yes first. |
| **C13** | Seeding `privateApplications` | `01` § 8.7 proposed seeding password managers on first run ("wrong-by-default in the safe direction"); `05` § 6.2 says both lists ship empty with a user-driven `Suggest…` action. | **`05` wins** (§ 6.7.2). Lggr ships with **no opinion** about which of the user's applications are sensitive. The `Suggest…` action proposes password managers, banking and messaging apps as **checkboxes the user must tick** — never pre-applied. Pre-applying would be a silent claim about the user's machine. |
| **C14** | Onboarding shape | `04` § 5.5: four pages, 640 × 460. `05` § 5: six screens, 560 × 460. | **`05` wins** (§ 6.5). The permission ladder needs Accessibility, Automation and Notifications to be three separate, separately-skippable asks; four pages cannot carry them without bundling two permissions into one screen. `04`'s rules are kept: one primary action per screen, a visible Skip on every permission screen, dot progress, and `Esc` ≡ Skip. |
| **C15** | Sidebar ⌘-number mapping | `01` § 6.4 referred to ⌘5 as Weekly Review and ⌘4 as Weekly Outcomes; `04` § 1.2's `SidebarSection` declaration order gives ⌘4 Weekly Review and ⌘5 Projects. | **`04` wins.** The enum's declaration order is the source of truth and is fixed for the life of the project: ⌘1 Today · ⌘2 Focus Sessions · ⌘3 Accomplishments · ⌘4 Weekly Review · ⌘5 Projects · ⌘6 Rules · ⌘7 Settings (§ 5.1.2). |
| **C16** | Settings in two places | `SPEC.md` puts Settings in the sidebar; `02` declares a `Settings` scene; `06` proposed ⌘7 opening the scene rather than an in-window pane. | **`04` wins** (§ 5.1.2). One `SettingsView`, two hosts: ⌘, opens the `Settings` scene because that is what every Mac user's hands expect; ⌘7 selects the sidebar row, which keeps the ⌘-number mapping unbroken. Zero duplicated code. |
| **C17** | `BrowserDomainReader` isolation | `02` § 6.1 makes the whole `LggrApp` target `@MainActor` and § 6.7 forbids background queues; `05` § 1.2 declares the reader an `actor`. | **`05` wins, as the single documented exception** (§ 3.8.1, § 6.1.2). `NSAppleScript` is blocking IPC that can stall for seconds behind a consent sheet; running it on the main actor would freeze the timer and the menu bar. The exception is written into the concurrency model rather than discovered later. |
| **C18** | Bundle identity and file locations | `02` § 7.4: `CFBundleIdentifier` `com.lggr.Lggr`, `CFBundleExecutable` `Lggr`, plist and entitlements under `Scripts/`. The repository ships `com.luisdoriz.lggr`, `LggrApp`, and `Resources/`. | **The repository wins** (§ 3.9.1, § 3.9.4). The bundle identifier is the TCC identity and changing it after a permission grant silently discards every grant; the executable is already built and signed, and renaming buys nothing. |
| **C19** | Un-built sidebar sections in Phase 2 | `SPEC.md` says "do not leave placeholder buttons that do nothing", but it also fixes the seven-section navigation. | **Render all seven rows, with an honest `EmptyStateView` naming the phase** each un-built section arrives in (§ 5.1.2, task P2-55). Hiding rows until their phase would renumber the ⌘-shortcuts three times over the project. The same rule applies to the two Phase-3 rows in the menu bar popover: present, disabled, with a tooltip. |
| **C20** | The `< 5 s` promise vs `GlobalShortcutService` being Phase 6 | `01` § 8.8 flagged that until ⌘⇧Space exists, the fastest path requires Lggr to be frontmost. | **State the measurement explicitly rather than pulling Carbon forward.** The Phase-2 acceptance measurement starts from **⌘N with the app frontmost**, or a click on the menu bar item (§ 2.5, task P2-64). `GlobalShortcutService` stays in Phase 6. |
| **C21** | `SessionSummaryBuilder` in Phase 2 | Listed as `[P2]`, but with no `ActivityEvent`s until Phase 3 it cannot produce `SPEC.md`'s example sentence. | **Keep it in Phase 2 with an explicitly reduced form** (task P2-17): intent, project, work type and `effectiveDuration`. The Phase-2 acceptance criteria do not ask for the application-naming sentence; `P3` grows the builder. |
| **C22** | Missing `LggrStore` methods for scoped deletion | `05` § 7.4 specifies "delete this day's activity" and "delete this session's activity, keep the session", which no protocol version carried. | **Added as `[P4]`**: `deleteActivityEvents(in: DateInterval)` and `deleteActivityEvents(sessionID: UUID)` (§ 4.4.1, task P4-08). Trivially implementable in all three backends. |
| **C23** | Missing `UserPreferences` fields | `05` § 12.6 required six new fields (`trackBrowserDomains`, `browserAutomation`, the four permission-etiquette flags, `lastPruneAt`); `03` § 2.8 did not have them, and `04` implies a `hideDockIcon` preference. | **All added before v1 ships** (§ 4.2.4), so no `decodeIfPresent` path and no `v2` key bump is required. Without persisted etiquette flags, "once, ever" degrades to "once per launch", which is nagging. |
| **C24** | Notification kinds | `SPEC.md` names four (session completed, halfway, long idle, planned session start); `UserPreferences` carries three toggles. | **Three in the MVP.** *Planned session start* requires scheduled sessions, which are not in the data model and are not in the MVP (§ 6.1.3). |

---

## Appendix B — Deliberately deferred, and one thing to verify

These are not contradictions; they are decisions that are correct today and should be revisited on a
stated trigger.

1. **`LGGR_SWIFTDATA=1 swift build` cannot be verified on this machine.** Phase 2's definition of done
   therefore accepts structural evidence — the conditional target exists and `swift build` is
   unaffected — and defers real verification to `P3-12` on a machine with Xcode. This is the one
   acceptance criterion in the document that is not directly executable here, and it is called out
   rather than quietly relaxed.
2. **The sandbox-versus-Accessibility claim has not been run on this machine.** § 6.2 states Apple's
   documented position, which matches every shipping app in this category, but this repository's
   standard is that constraints are verified by execution. Task `P3-13` is a ten-minute check whose
   result belongs in `CONSTRAINTS.md`. **If it comes back the other way, the sandbox recommendation is
   the one conclusion in this document that would change.**
3. **Retroactive per-application purge is out of scope** (§ 6.7.5). The honest alternative — a
   `deleteActivityEvents(bundleIdentifier:)` method plus a progress UI — is one more store method and
   one more sheet for a case that arises about once per install. Worth revisiting after real use; the
   confirmation copy is written so that shipping without it is not misleading.
4. **Activity events stay in the single `store.json` snapshot.** Trigger to move them to append-only
   per-month files: the measured snapshot exceeding ~10 MB, or cold start exceeding 500 ms with a year
   of fixture data (risk R10). Not before.
5. **`interruptionCount` is denormalised** and maintained by `SessionManager`. Phase 2 never writes it.
   Whoever does `P3-11` should decide whether to add a recompute-on-load reconciliation or trust the
   counter; a contract test either way would be cheap.
6. **Today's "daily intended outcomes" section is absent until Phase 5.** `SPEC.md` § 7 puts it second
   in the hierarchy, but `WeeklyOutcome` is a `[P5]` type, and an empty placeholder for four phases
   would be worse than nothing. If the intent was a lighter-weight "today's intents" list independent
   of weekly outcomes, that is a different feature and needs a data-model addition.
7. **Dynamic Type is only partially testable on macOS.** Building the ramp from text styles means Lggr
   scales wherever the system scales, and `@ScaledMetric` handles the one fixed size — but the gallery
   should grow a `.dynamicTypeSize(.accessibility3)` column so the `ViewThatFits` fallbacks in § 5.8.3
   are actually exercised rather than assumed.






