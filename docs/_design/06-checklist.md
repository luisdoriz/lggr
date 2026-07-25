# Lggr — Phased Execution Checklist

> Deliverable 7 of the Phase 1 design set. Read in this order first: `CONSTRAINTS.md`,
> `SPEC.md`, `02-architecture.md`, `03-data-model.md`. This file turns SPEC's six phases into
> tasks that can be assigned, executed and *verified*. Nothing here relitigates the three-target
> split or the absence of Xcode.

---

## 0. How to read this file

**Every row has five columns.**

| Column | Meaning |
|---|---|
| **ID** | `P<phase>-<nn>`. Stable forever. Never renumbered; a dropped task becomes `~~P2-31~~ withdrawn`. |
| **Task** | One unit of work, sized so a single agent finishes it in one sitting. |
| **Files** | Repo-relative paths, taken verbatim from `02-architecture.md` § 3 unless § 2 of this file overrides them. `(new)` = create, `(edit)` = modify an existing file. |
| **Deps** | Task IDs that must be *accepted* first. `—` means it can start immediately. |
| **Acceptance** | A command whose exit status/output is checked, a named test that passes, or a numbered observable behaviour. Never "works correctly". |

**Three verification verbs are used, and they mean exactly these things:**

- **`$ <command>` → `<expected>`** — run it; stdout/exit status must match.
- **TEST `<name>` in `<file>`** — a `@Test` function that exists and passes under `./Scripts/test.sh`.
- **OBSERVE** — a numbered click/keystroke sequence against `build/Lggr.app` (or the gallery)
  with the exact expected on-screen result. Anyone can repeat it.

**The two commands you will run constantly:**

```bash
swift build          # compile check
./Scripts/test.sh    # NOT `swift test` — see § 1.2. `make test` is the same thing.
```

---

## 1. Ground truth about the repository, today

Verified by running the toolchain in this working tree, not assumed.

### 1.1 What already exists

| Path | State |
|---|---|
| `Package.swift` | Real. `swift-tools-version: 6.0`, `platforms: [.macOS(.v14)]`, `swiftLanguageMode(.v5)`, `enableUpcomingFeature("ExistentialAny")`, conditional `LggrPersistence` on `LGGR_SWIFTDATA=1`, CLT `Testing.framework` search-path workaround. |
| `Makefile` | Real. `build`, `test`, `app`, `run`, `check`, `clean`, `help`. |
| `Scripts/make-app.sh` | Real. Builds, assembles `build/Lggr.app`, `plutil -lint`, ad-hoc `codesign` with hardened runtime, `codesign --verify`. |
| `Scripts/test.sh` | Real. Wraps `swift test` and **fails if zero tests actually ran**. |
| `Scripts/make-icon.sh`, `Scripts/IconGenerator.swift` | Real. Produces `Resources/AppIcon.icns` (already generated). |
| `Resources/Info.plist`, `Resources/Lggr.entitlements`, `Resources/AppIcon.icns` | Real. |
| `Sources/LggrKit/_Scaffold.swift`, `Sources/LggrApp/_Scaffold.swift`, `Tests/LggrKitTests/_ScaffoldTests.swift` | Placeholders. Deleted by `P2-85`. |
| `.gitignore` | Real and sufficient. |
| Git | Repo initialised on `master`, **zero commits**. First commit lands with `P2-06`. |

Baseline, confirmed green before any Phase 2 work:

```
$ swift build          → Build complete!
$ ./Scripts/test.sh    → OK: Test run with 1 test in 0 suites passed
```

### 1.2 Four facts that will bite an agent who does not know them

1. **`swift test` alone silently runs nothing.** With Command Line Tools, SwiftPM cannot locate
   `Testing.framework`; it prints `Build complete!`, exits `0`, and executes zero tests. A green
   exit code with no tests is worse than a red one. **Always `./Scripts/test.sh` or `make test`.**
2. **`ExistentialAny` is on.** Every protocol existential must be spelled `any LggrStore`,
   `any DateProviding`, `[any PersistentModel.Type]`. Bare `LggrStore` is a compile error.
3. **The executable product is `LggrApp`, not `Lggr`.** The binary is
   `build/Lggr.app/Contents/MacOS/LggrApp` and `CFBundleExecutable` is `LggrApp`. This contradicts
   `02-architecture.md` § 7.1, which predates the scaffold. The scaffold wins — see `C8`.
4. **Never launch `.build/debug/LggrApp` directly.** No `Info.plist` outside the bundle means no
   activation policy, no bundle identifier, no `MenuBarExtra` identity. Always `make run`.

---

## 2. Binding-document conflict register

`02-architecture.md` and `03-data-model.md` are both binding and they disagree in twelve places.
`03-data-model.md` § 0 declares itself the source of truth for *type names, field names and
signatures*; `02-architecture.md` is the source of truth for *targets, folders, build and
concurrency*. Each conflict is resolved once, here, so no agent decides it twice.

| # | Topic | `02-architecture.md` says | `03-data-model.md` says | **Resolution** |
|---|---|---|---|---|
| C1 | `LggrStore` isolation + method names | `protocol LggrStore: Sendable`, conformers are `actor`s, `allProjects()` / `upsert(_:)` / `sessions(in:)` | `@MainActor protocol LggrStore: AnyObject`, `loadProjects()` / `saveProject(_:)` / `loadSessions(in:)` | **03 wins.** `@MainActor`, `AnyObject`, `load*/save*/delete*` naming. 02's intent (no file I/O on the main thread) is preserved by doing encode + atomic write inside a `nonisolated` helper that `JSONFileStore` `await`s — see `P2-24`. |
| C2 | Where `UserPreferences` lives | `preferences()` / `save(_:)` on `LggrStore` | `UserDefaults`, behind `PreferencesStoring`; explicitly *not* on `LggrStore` | **03 wins.** `Sources/LggrKit/Store/PreferencesStore.swift` is added to the Phase 2 file list (02 § 3 omits it). |
| C3 | Session timing API | `Domain/SessionClock.swift` + `Domain/SessionLifecycle.swift`, static funcs taking `now:` | `mutating` methods + computed props on `FocusSession`, in `Model/FocusSession+Timing.swift` | **03 wins.** `SessionClock.swift` and `SessionLifecycle.swift` are **not created**. All arithmetic is `FocusSession.elapsed(at:)`, `.pause(at:)`, `.resume(at:)`, `.finish(at:status:)`, exactly as 03 § 3.4 prints it. |
| C4 | Timing test files | `SessionClockTests.swift`, `SessionLifecycleTests.swift` | `FocusSessionTimingTests` | **03 wins.** One file: `Tests/LggrKitTests/FocusSessionTimingTests.swift`. |
| C5 | SwiftData class prefix + mapping filenames | `StoredProject.swift`, `Mapping/ProjectMapping.swift` | `SDProject`, `Mapping/SDFocusSession+Mapping.swift` | **03 wins.** `SD*` prefix, `Models/SD<Entity>.swift`, `Mapping/SD<Entity>+Mapping.swift`. |
| C6 | Enum file layout | `Model/WorkType.swift`; enums beside their struct | `Model/Enums.swift` holds all enums | **03 wins.** One `Model/Enums.swift`, appended to each phase. `Model/WorkType.swift` and `Model/ActivityCategory.swift` are not created. |
| C7 | JSON on-disk layout | one `StoreSnapshot` root → `~/Library/Application Support/Lggr/store.json`, with `schemaVersion` | "one JSON file per aggregate" (table cell) | **02 wins.** Single `store.json`, one `StoreSnapshot` root, `schemaVersion: Int`. 02 has a dedicated file and a stated version policy; 03 mentions it only in passing. |
| C8 | Executable / product name | product `Lggr`, binary `Lggr` | — | **Repo wins.** Product and binary are `LggrApp`; bundle is `build/Lggr.app`; `CFBundleExecutable = LggrApp`. Already built and signed; renaming buys nothing. |
| C9 | Bundle identifier | `com.lggr.Lggr` | — | **Repo wins.** `com.luisdoriz.lggr`. TCC keys Accessibility consent to this string; it must never change after Phase 3 ships. |
| C10 | `Info.plist` / entitlements location | `Scripts/` | — | **Repo wins.** `Resources/`. |
| C11 | `NSAccessibilityUsageDescription` | "There is no such key" — it does nothing | Key is present in `Resources/Info.plist` | **Keep it.** Harmless and self-documenting for a reader of the bundle. 02 is factually right that macOS ignores it; the real explanation lives in onboarding (`P6-01`). |
| C12 | `Scripts/run.sh` | exists, `make-app.sh && open` | — | **Both.** `make run` already works; `P2-05` adds the one-line `Scripts/run.sh` so 02's documented daily loop is literally true. |

Anything not listed above: `02-architecture.md` governs structure, `03-data-model.md` governs code.

---

## 3. Phase 1 — Product and technical design

Design only. No Swift.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P1-01 | Verify and record hard environment limits | `docs/_design/CONSTRAINTS.md` | — | **Done.** File exists and every claim in it was produced by running the compiler on this machine. |
| P1-02 | Reproduce the product specification verbatim | `docs/_design/SPEC.md` | — | **Done.** File exists. |
| P1-03 | Product definition + MVP boundary + risks | `docs/_design/01-product.md` (new) | P1-01, P1-02 | File exists; contains a one-paragraph product summary, an explicit in/out MVP table, and a risk table with at least one privacy risk and one technical risk. |
| P1-04 | Architecture and folder structure | `docs/_design/02-architecture.md` | P1-01 | **Done.** Names all three targets, the full folder tree with `[P2]`–`[P6]` markers, the service catalog, the DI mechanism and the concurrency model. |
| P1-05 | Data model | `docs/_design/03-data-model.md` | P1-04 | **Done.** Every type, field and signature declared; pause arithmetic specified with a worked table and an invariant list. |
| P1-06 | Screens and navigation | `docs/_design/04-screens.md` (new) | P1-04 | File exists; describes every Phase 2 screen and states the single primary action for each. |
| P1-07 | Permissions strategy | `docs/_design/05-permissions.md` (new) | P1-04 | File exists; covers Accessibility, Notifications and Automation: why, when asked, what happens on denial, and the "never nag" rule. |
| P1-08 | This execution checklist | `docs/_design/06-checklist.md` | P1-04, P1-05 | **Done** (this file). Every Phase 2 task has an objectively verifiable acceptance criterion. |

**Phase 1 exit:** all eight rows accepted, and § 2's conflict register is agreed by whoever owns
`02-architecture.md` and `03-data-model.md`.

---

## 4. Phase 2 — the smallest working vertical slice

> SPEC § *Implementation order*, Phase 2: create a project · start a focus session · timer in the
> main window · timer in the menu bar · pause and resume · finish the session · select the result
> status · persist the session · show the completed session in Today · add an accomplishment from
> the completed session. **"This phase must compile and work before continuing."**

86 tasks in eight stages. Stages A–D are pure `LggrKit` and can be executed by an agent with no
UI judgement; stages E–H are the app.

### Stage A — build plumbing (P2-01 … P2-06)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-01 | Write the layering guard: fail if `Sources/LggrKit` imports SwiftUI/AppKit/SwiftData, or if `@Model`/`#Predicate`/`#Preview` appear anywhere under `Sources/LggrKit` or `Sources/LggrApp` except `Sources/LggrApp/_XcodeOnly/`. Print `layering OK` and exit 0 on success. | `Scripts/check-layering.sh` (new) | — | `$ ./Scripts/check-layering.sh` → `layering OK`, exit `0`. Then `$ printf 'import AppKit\n' > Sources/LggrKit/_probe.swift && ./Scripts/check-layering.sh; echo $?` → non-zero and names `_probe.swift`; delete the probe. |
| P2-02 | Call the guard from the app assembler, before `swift build`. | `Scripts/make-app.sh` (edit) | P2-01 | `$ ./Scripts/make-app.sh release` → output contains `layering OK` **before** `==> Building`, and still ends with `Built .../build/Lggr.app`. |
| P2-03 | Complete `Info.plist` per `02-architecture.md` § 7.4: add `NSPrincipalClass=NSApplication`, `NSSupportsSuddenTermination=false`, `NSSupportsAutomaticTermination=false`, `LSApplicationCategoryType=public.app-category.productivity`, `ITSAppUsesNonExemptEncryption=false`. Leave `CFBundleExecutable`, `CFBundleIdentifier` and `NSAccessibilityUsageDescription` untouched (C8, C9, C11). | `Resources/Info.plist` (edit) | — | `$ plutil -lint Resources/Info.plist` → `OK`. `$ for k in NSPrincipalClass NSSupportsSuddenTermination NSSupportsAutomaticTermination LSApplicationCategoryType ITSAppUsesNonExemptEncryption; do plutil -extract $k raw Resources/Info.plist; done` → prints 5 values, exit 0 each. |
| P2-04 | Add `exclude: ["_XcodeOnly"]` to the `LggrApp` target so the Xcode-only previews never reach this toolchain. | `Package.swift` (edit) | — | `$ mkdir -p Sources/LggrApp/_XcodeOnly && printf '#Preview { Text("x") }\n' > Sources/LggrApp/_XcodeOnly/_probe.swift && swift build` → `Build complete!`; delete the probe. |
| P2-05 | Add `Scripts/run.sh` (`make-app.sh "$@" && open build/Lggr.app`) and a `make gallery` target that runs the app with `LGGR_GALLERY=1`. | `Scripts/run.sh` (new), `Makefile` (edit) | P2-02 | `$ ./Scripts/run.sh release` → Lggr appears in the Dock. `$ make help` → lists a `gallery` target. |
| P2-06 | README: what Lggr is, the four build commands, the `swift test` trap, where data is stored, the "zero network code" claim with the `otool` check. Then make the first git commit. | `README.md` (new) | P2-01…P2-05 | `$ grep -c 'Scripts/test.sh' README.md` → ≥ 1. `$ grep -c 'Application Support/Lggr' README.md` → ≥ 1. `$ git log --oneline \| wc -l` → ≥ 1. |

### Stage B — LggrKit domain types (P2-07 … P2-18)

All files: `Sendable`, `Codable`, `Hashable`, `Identifiable`, explicit `public init`, no force
unwraps. Copy declarations verbatim from `03-data-model.md`.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-07 | The four Phase 2 enums, verbatim from `03-data-model.md` § 1: `WorkType` (8 cases, `displayName`, `symbolName`, `suggestedDuration`, `isReactiveByDefault`), `SessionResultStatus` (5 cases + `countsAsCompleted`/`countsAsInterrupted`/`needsFollowUp`), `AccomplishmentType` (11 cases + `countsAsUnblockingOthers`), `SessionState` (4 cases + `symbolName`, `isActive`). Explicit `String` raw values. | `Sources/LggrKit/Model/Enums.swift` (new) | — | `$ swift build` → `Build complete!`. TEST `workTypeSuggestedDurations` in `Tests/LggrKitTests/EnumsTests.swift`: `.deepWork.suggestedDuration == 3000`, `.communication.suggestedDuration == 1500`, and `WorkType.allCases.count == 8`, `SessionResultStatus.allCases.count == 5`, `AccomplishmentType.allCases.count == 11`. |
| P2-08 | `Project` + `defaultColorID`, `defaultIconID`, `colorIDs` (9), `iconIDs` (10). | `Sources/LggrKit/Model/Project.swift` (new) | P2-07 | TEST `projectDefaults` in `Tests/LggrKitTests/CodableRoundTripTests.swift`: `Project(name: "SOR").colorID == "blue"`, `Project.colorIDs.count == 9`, `Project.colorIDs` contains no duplicates. |
| P2-09 | `FocusSession` — all 16 stored properties including `pauseStartedAt`, with `pausedDuration` and `interruptionCount` clamped at 0 in `init`. | `Sources/LggrKit/Model/FocusSession.swift` (new) | P2-07 | TEST `negativeDurationsAreClamped` in `FocusSessionTimingTests.swift`: `FocusSession(intendedOutcome: "x", pausedDuration: -5, interruptionCount: -2)` yields `pausedDuration == 0` and `interruptionCount == 0`. |
| P2-10 | Timing extension, verbatim from `03-data-model.md` § 3.4: `state`, `isRunning`, `isPaused`, `isFinished`, `isOpenEnded`, `totalPausedDuration(at:)`, `elapsed(at:)`, `remaining(at:)`, `overrun(at:)`, `progress(at:)`, `effectiveDuration`, `wallClockInterval`, `pause(at:)`, `resume(at:)`, `finish(at:status:)`, `togglePause(at:)`. Never call `Date()` inside. | `Sources/LggrKit/Model/FocusSession+Timing.swift` (new) | P2-09 | `$ grep -c 'Date()' Sources/LggrKit/Model/FocusSession+Timing.swift` → `0`. Full behaviour is covered by `P2-26`. |
| P2-11 | `Accomplishment` + `isGeneratedFromSession`. | `Sources/LggrKit/Model/Accomplishment.swift` (new) | P2-07 | TEST `accomplishmentFromSessionIsFlagged` in `CodableRoundTripTests.swift`: `focusSessionID: nil` → `false`; a UUID → `true`. |
| P2-12 | `KeyboardShortcutSpec` (+ `.defaultStartSession` = `" "`, `(1<<20)\|(1<<17)`) and `UserPreferences` with all 15 fields, `singletonID`, `isExcluded(bundleIdentifier:)`, `isPrivate(bundleIdentifier:)`, `retentionCutoff(from:calendar:)`. | `Sources/LggrKit/Model/UserPreferences.swift` (new) | P2-07 | Covered by `P2-30`. `$ grep -c 'C0DE' Sources/LggrKit/Model/UserPreferences.swift` → ≥ 1. |
| P2-13 | `DateProviding` protocol (`var now: Date`), `SystemClock`, `FixedClock` (mutable `now`, plus `advance(by:)`). | `Sources/LggrKit/Support/DateProviding.swift` (new) | — | TEST `fixedClockAdvances` in `Tests/LggrKitTests/SupportTests.swift`: a `FixedClock` at T, `advance(by: 60)`, `now == T + 60`; two reads of `SystemClock().now` are non-decreasing. |
| P2-14 | Day and week boundary helpers: `DateInterval.day(containing:calendar:)`, `DateInterval.week(containing:calendar:)`, `Calendar.weekStart(for:)`. | `Sources/LggrKit/Support/CalendarWindows.swift` (new) | — | TEST `dayWindowCoversMidnightToMidnight` in `SupportTests.swift`: for 2026-03-08 14:30 local, `.day` interval starts at 00:00:00 and has `duration == 86_400` under a fixed-offset calendar; `weekStart` is ≤ the date and `.day` of week matches `calendar.firstWeekday`. |
| P2-15 | `[T]` lookup helpers for `Identifiable` collections: `first(id:)`, `upserted(_:)`, `removing(id:)`. | `Sources/LggrKit/Support/Identified.swift` (new) | — | TEST `upsertReplacesInPlace` in `SupportTests.swift`: upserting an edited element keeps `count` and index stable; upserting a new element appends. |
| P2-16 | Duration formatting: `DurationFormatting.clock(_:)` → `"25:00"` / `"1:23:45"`, `.compact(_:)` → `"50m"` / `"1h 12m"`, `.menuBar(_:)` → `"25:00"`, and `.overrun(_:)` → `"+2:07"`. Pure, locale-independent digits. | `Sources/LggrKit/Domain/DurationFormatting.swift` (new) | — | Covered by `P2-27`. |
| P2-17 | Deterministic Phase 2 summary generator: `SessionSummaryBuilder.suggestedSummary(for:project:) -> String`. With no activity events (all of Phase 2) it composes from intended outcome, project name, work type and `effectiveDuration` — e.g. `"Spent 45m of deep work on receipt deduplication (SOR engineering)."` No AI, no randomness. Grows in Phase 3 to name applications. | `Sources/LggrKit/Domain/SessionSummaryBuilder.swift` (new) | P2-09, P2-10, P2-16 | Covered by `P2-28`. |
| P2-18 | Fixtures: `FixtureCalendar` (a fixed `referenceDate` + `at(_ hour:_ minute:)` in a fixed-offset calendar) and `PreviewFixtures` (≥ 2 projects, 1 running session, 1 paused session, 1 finished-awaiting-review session, 3 completed sessions across today, 2 accomplishments, default preferences). Deterministic — no `Date()`, no `UUID()` at call sites that tests compare. | `Sources/LggrKit/Fixtures/FixtureCalendar.swift` (new), `Sources/LggrKit/Fixtures/PreviewFixtures.swift` (new) | P2-08…P2-12 | TEST `fixturesAreDeterministic` in `SupportTests.swift`: `PreviewFixtures.finishedSession.id == PreviewFixtures.finishedSession.id` across two accesses, and `FixtureCalendar.at(9, 0)` returns an identical `Date` on repeat calls. |

### Stage C — LggrKit persistence (P2-19 … P2-25)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-19 | `StoreError` — `notFound(UUID)`, `invalidData(String)`, `persistenceFailure(String)`; `Error, Sendable, Equatable`. | `Sources/LggrKit/Store/StoreError.swift` (new) | — | `$ swift build` → `Build complete!`. TEST `storeErrorsAreEquatable` in `Tests/LggrKitTests/LggrStoreContractTests.swift`. |
| P2-20 | `LggrStore` protocol, Phase 2 subset only, `@MainActor` + `AnyObject` (C1): `loadProjects`, `saveProject`, `deleteProject(id:)`, `loadSessions(in:)`, `loadSession(id:)`, `loadActiveSession()`, `saveSession`, `deleteSession(id:)`, `loadAccomplishments(in:)`, `saveAccomplishment`, `deleteAccomplishment(id:)`. Later-phase methods stay commented with their `[P3]`/`[P5]` markers so the growth path is visible. | `Sources/LggrKit/Store/LggrStore.swift` (new) | P2-19 | `$ grep -c '@MainActor' Sources/LggrKit/Store/LggrStore.swift` → ≥ 1. `$ grep -cE 'func (loadActivityEvents\|loadInterruptions\|loadWeeklyOutcomes)' Sources/LggrKit/Store/LggrStore.swift` → `0` (they are comments, not declarations, in Phase 2). |
| P2-21 | `StoreSnapshot`: `Codable` root holding `schemaVersion: Int` (= 1), `projects`, `sessions`, `accomplishments`. Decoding a snapshot with a *higher* `schemaVersion` throws `StoreError.invalidData` with a message naming both versions; a lower or equal version decodes. (C7) | `Sources/LggrKit/Store/StoreSnapshot.swift` (new) | P2-08…P2-11, P2-19 | TEST `futureSchemaVersionIsRefused` in `Tests/LggrKitTests/StoreSnapshotCodableTests.swift`: hand-built JSON with `"schemaVersion": 99` throws `StoreError.invalidData`; with `1` it decodes and round-trips equal. |
| P2-22 | `AtomicFileWriter.write(_ data: Data, to url: URL) throws` — create parent directory, write to a sibling temp file, `FileManager.replaceItemAt`. `nonisolated`/`Sendable`, no `try!`. | `Sources/LggrKit/Store/AtomicFileWriter.swift` (new) | P2-19 | TEST `atomicWriteLeavesNoTempFile` in `Tests/LggrKitTests/JSONFileStoreTests.swift`: after writing to a temp dir, that directory contains exactly one file and its contents equal the input bytes. |
| P2-23 | `InMemoryStore: LggrStore` — `@MainActor final class`, optional `var failureToInject: StoreError?` thrown by every method when set, `init(seed: StoreSnapshot = .empty)`. `deleteProject` **nullifies** `projectID` on referencing sessions and accomplishments rather than deleting them. | `Sources/LggrKit/Store/InMemoryStore.swift` (new) | P2-20, P2-21 | Covered by `P2-31`. |
| P2-24 | `JSONFileStore: LggrStore` — `@MainActor final class` over `~/Library/Application Support/Lggr/store.json` (directory injectable). Holds the snapshot in memory; `save*` mutates it, marks dirty and schedules a 500 ms coalesced flush; `flush()` awaits a `nonisolated` encode + `AtomicFileWriter.write` so **no JSON encoding or file I/O runs on the main actor** (this is how C1 keeps 02's intent). Missing file → empty snapshot, not an error. Corrupt file → throw `StoreError.invalidData` and leave the file untouched. | `Sources/LggrKit/Store/JSONFileStore.swift` (new) | P2-21, P2-22, P2-23 | Covered by `P2-31` and `P2-32`. Plus `$ grep -c 'nonisolated' Sources/LggrKit/Store/JSONFileStore.swift` → ≥ 1. |
| P2-25 | `PreferencesStoring` protocol + `UserDefaultsPreferencesStore` (single JSON blob under `com.lggr.userPreferences.v1`, injectable `UserDefaults`) + `InMemoryPreferencesStore` fake. (C2) | `Sources/LggrKit/Store/PreferencesStore.swift` (new) | P2-12 | TEST `preferencesSurviveAStoreRestart` in `Tests/LggrKitTests/UserPreferencesTests.swift`: against a `UserDefaults(suiteName:)` scratch domain, set `defaultSessionDuration = 1500`, construct a second store over the same suite, read `1500`. Suite is removed in the test's teardown. |

### Stage D — LggrKit tests (P2-26 … P2-32)

The spec's testable behaviours that are reachable in Phase 2. Every test injects time; none calls
`Date()`.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-26 | Timing suite. Must include, one `@Test` each: (a) elapsed with no pause; (b) the full worked table from `03-data-model.md` § 3.2 — 09:00 start → pause 09:10 → resume 09:15 → pause 09:40 → resume 09:50 → finish 10:00 gives `pausedDuration == 900` and `elapsed == 2700`; (c) elapsed is frozen while paused; (d) `pause` twice is a no-op; (e) `resume` without a pause is a no-op; (f) `finish` while paused closes the pause then ends; (g) `finish` twice never moves `endedAt`; (h) backwards clock on `resume` adds 0; (i) `finish(at:)` before `startedAt` clamps to `startedAt` and `elapsed == 0`; (j) open-ended → `remaining == nil`, `progress == nil`, `overrun == 0`; (k) `overrun` after the planned duration; (l) `effectiveDuration == 0` while running; (m) `state` returns `.running`/`.paused`/`.awaitingReview`/`.completed` in the four situations; (n) `togglePause` alternates. | `Tests/LggrKitTests/FocusSessionTimingTests.swift` (new) | P2-10, P2-18 | `$ ./Scripts/test.sh --filter FocusSessionTiming` → all pass, and the run summary reports **≥ 14 tests**. |
| P2-27 | Formatting suite: `clock(0) == "0:00"`, `clock(59) == "0:59"`, `clock(1500) == "25:00"`, `clock(3661) == "1:01:01"`, `compact(3000) == "50m"`, `compact(4320) == "1h 12m"`, `compact(0) == "0m"`, `overrun(127) == "+2:07"`, and a negative input never produces a `-` sign. | `Tests/LggrKitTests/DurationFormattingTests.swift` (new) | P2-16 | `$ ./Scripts/test.sh --filter DurationFormatting` → all pass, ≥ 8 tests. |
| P2-28 | Summary suite: same session + same project produce byte-identical strings on repeat calls; the string contains the intended outcome, the project name and a formatted duration; a session with no project omits the parenthetical and contains no `"nil"`, no `"Optional"` and no double space. | `Tests/LggrKitTests/SessionSummaryBuilderTests.swift` (new) | P2-17, P2-18 | `$ ./Scripts/test.sh --filter SessionSummaryBuilder` → all pass, ≥ 4 tests. |
| P2-29 | Codable round-trip for `Project`, `FocusSession`, `Accomplishment`, `UserPreferences`, `StoreSnapshot`, and every case of all four Phase 2 enums. Also assert the *raw strings* (`"deepWork"`, `"madeProgress"`, `"pullRequestReviewed"`, …) so a Swift-level rename cannot silently invalidate stored JSON. | `Tests/LggrKitTests/CodableRoundTripTests.swift` (new) | P2-08…P2-12, P2-21 | `$ ./Scripts/test.sh --filter CodableRoundTrip` → all pass; the enum raw-value test asserts all 28 Phase 2 raw values explicitly. |
| P2-30 | Preferences suite: `isExcluded`/`isPrivate` are case-insensitive; `retentionCutoff` returns `now − days`; `dataRetentionDays == nil` or `0` → `nil` cutoff; JSON round-trip preserves `globalShortcut`; `id` always equals `singletonID` even when the decoded JSON carries a different `id`. | `Tests/LggrKitTests/UserPreferencesTests.swift` (new) | P2-12, P2-25 | `$ ./Scripts/test.sh --filter UserPreferences` → all pass, ≥ 6 tests. |
| P2-31 | **Store contract suite**, written once and run against every conformer via a `[() -> any LggrStore]` factory list (`InMemoryStore`, `JSONFileStore` in a fresh temp dir; `SwiftDataStore` added under `LGGR_SWIFTDATA=1` in a later phase). Cases: upsert-by-id updates rather than duplicates; `loadSessions(in:)` filters on `startedAt` and returns newest first; `loadActiveSession()` returns the one with `endedAt == nil` and `nil` when there is none; `deleteProject` nullifies `projectID` on sessions and accomplishments and deletes neither; `deleteSession` removes only that session; `loadAccomplishments(in:)` filters on `timestamp`; an injected `failureToInject` surfaces as a thrown `StoreError`. | `Tests/LggrKitTests/LggrStoreContractTests.swift` (new) | P2-23, P2-24 | `$ ./Scripts/test.sh --filter LggrStoreContract` → all pass; the suite reports **2 × N** tests (each case executed against both backends). |
| P2-32 | Durability suite for `JSONFileStore` only: write → `flush()` → construct a second store over the same directory → data is there; a missing file yields an empty store and no throw; a file containing `{` throws `StoreError.invalidData` and the bad file is still on disk afterwards; the atomic-write test from `P2-22`. | `Tests/LggrKitTests/JSONFileStoreTests.swift` (new) | P2-22, P2-24 | `$ ./Scripts/test.sh --filter JSONFileStore` → all pass, ≥ 4 tests. Each test uses `FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)` and removes it afterwards. |

### Stage E — design system and components (P2-33 … P2-42)

Everything here is presentational, takes plain values, and appears in the gallery. No data access.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-33 | `Theme`: a spacing scale (4/8/12/16/24/32), corner radii, semantic surfaces built from `Material` and `Color` semantic colours only — never a hard-coded hex that ignores appearance. | `Sources/LggrApp/DesignSystem/Theme.swift` (new) | — | `$ grep -cE '(Color|NSColor)\(red:|#[0-9a-fA-F]{6}' Sources/LggrApp/DesignSystem/Theme.swift` → `0`. |
| P2-34 | `Typography`: named roles (`timer`, `screenTitle`, `sectionTitle`, `body`, `caption`) built on `Font.system(..., design:)` with `.monospacedDigit()` on `timer`. | `Sources/LggrApp/DesignSystem/Typography.swift` (new) | — | `$ grep -c 'monospacedDigit' Sources/LggrApp/DesignSystem/Typography.swift` → ≥ 1. OBSERVE in the gallery (`P2-81`): the running timer's width does not jitter as the seconds change. |
| P2-35 | `Palette`: `Color(projectColorID:)` mapping all nine `Project.colorIDs`, with a documented fallback for an unknown token. | `Sources/LggrApp/DesignSystem/Palette.swift` (new) | P2-08 | `$ grep -o '"[a-z]*"' Sources/LggrApp/DesignSystem/Palette.swift \| sort -u \| wc -l` → ≥ 9. OBSERVE: the gallery's swatch row shows nine visually distinct colours in both light and dark. |
| P2-36 | `Iconography`: every SF Symbol name used by the app, in one enum, sourced from the `symbolName` properties in `03-data-model.md`. | `Sources/LggrApp/DesignSystem/Iconography.swift` (new) | P2-07 | `$ grep -rn 'Image(systemName:' Sources/LggrApp/Views Sources/LggrApp/Components \| grep -v 'Iconography\.' \| wc -l` → `0`. |
| P2-37 | `Motion`: named animations (`.lggrStateChange`, `.lggrSheet`) that collapse to `nil`/`.none` when `accessibilityReduceMotion` is on. | `Sources/LggrApp/DesignSystem/Motion.swift` (new) | — | `$ grep -c 'accessibilityReduceMotion' Sources/LggrApp/DesignSystem/Motion.swift` → ≥ 1. OBSERVE: with System Settings → Accessibility → Display → Reduce motion **on**, pausing the session changes state with no scale or slide animation. |
| P2-38 | `Card` container — background material, radius and padding from `Theme`; used only where it improves hierarchy. | `Sources/LggrApp/Components/Card.swift` (new) | P2-33 | OBSERVE in the gallery: `Card` renders with a legible border in both light and dark. |
| P2-39 | `SectionHeader` — title, optional trailing action. | `Sources/LggrApp/Components/SectionHeader.swift` (new) | P2-33, P2-34 | OBSERVE in the gallery, both appearances. |
| P2-40 | `EmptyStateView` — symbol, title, one-line explanation, optional primary button. | `Sources/LggrApp/Components/EmptyStateView.swift` (new) | P2-33, P2-36 | OBSERVE in the gallery: renders with and without a button, both appearances. |
| P2-41 | `PrimaryButtonStyle` — the one prominent button per screen; visible focus ring; disabled state readable. | `Sources/LggrApp/Components/PrimaryButtonStyle.swift` (new) | P2-33 | OBSERVE in the gallery: enabled, disabled and keyboard-focused variants are visually distinct in both appearances. |
| P2-42 | `ProjectBadge` — colour dot + SF Symbol + name, from a `Project`. | `Sources/LggrApp/Components/ProjectBadge.swift` (new) | P2-35, P2-36 | OBSERVE in the gallery: badges for both `PreviewFixtures` projects render with the right colour and icon. |

### Stage F — app shell, DI and services (P2-43 … P2-53)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-43 | `StoreBootstrap.makeStore() -> any LggrStore` — the **only** `#if LGGR_SWIFTDATA` in the repo. Returns `JSONFileStore` rooted at `~/Library/Application Support/Lggr/`. | `Sources/LggrApp/App/StoreBootstrap.swift` (new) | P2-24 | `$ grep -rn 'LGGR_SWIFTDATA' Sources/LggrApp --include=*.swift \| wc -l` → exactly the count inside this one file (≤ 3), and no other file appears in the output. |
| P2-44 | `AppEnvironment` — `@MainActor @Observable final class` holding `store`, `preferences`, `clock`, `sessionManager`, `menuBar`. Two factories: `.live()` and `.fake(...)` with `InMemoryStore(seed: PreviewFixtures.demoDay)` + `FixedClock` defaults. Phase 3+ services are *absent*, not stubbed. | `Sources/LggrApp/App/AppEnvironment.swift` (new) | P2-43, P2-25, P2-47, P2-48 | `$ swift build` → `Build complete!`. OBSERVE: `AppEnvironment.fake()` is used by the gallery (`P2-81`) and shows fixture data; `.live()` is used by `LggrMain` and shows real data. |
| P2-45 | `EnvironmentValues+Lggr` — hand-written `EnvironmentKey`s for `clock` and `isGalleryMode`. No `@Entry` (SwiftUI macro; cannot compile here). | `Sources/LggrApp/App/EnvironmentValues+Lggr.swift` (new) | P2-13 | `$ grep -c '@Entry' Sources/LggrApp/App/EnvironmentValues+Lggr.swift` → `0`. `$ swift build` → `Build complete!`. |
| P2-46 | `TickTimer` — 1 Hz, `tolerance = 0.15`, added to `RunLoop.main` in **`.common`** mode, `MainActor.assumeIsolated` in the fire block, `stop()` invalidates. It only asks for a redraw; it accumulates nothing. | `Sources/LggrApp/Services/TickTimer.swift` (new) | — | `$ grep -c 'forMode: .common' Sources/LggrApp/Services/TickTimer.swift` → ≥ 1. OBSERVE: start a session, open the menu bar popover and **hold it open** for 10 s — the time in the popover advances every second while the popover is tracking. |
| P2-47 | `SessionManager` — `@MainActor @Observable final class`. `var active: FocusSession?`, `var awaitingReview: FocusSession?`, `var recentlyFinished: [FocusSession]`, `var tick: Date`. `start(project:outcome:workType:plannedDuration:)`, `pause()`, `resume()`, `togglePause()`, `finish()`, `applyReview(status:summary:blocker:nextStep:)`, `restoreActiveSession()`. All arithmetic delegates to `FocusSession+Timing` with `clock.now`; writes are fire-and-forget `Task { try? await store.saveSession(...) }` after the in-memory state is already updated. Starts the tick on start/resume, stops it on pause/finish. | `Sources/LggrApp/Services/SessionManager.swift` (new) | P2-10, P2-20, P2-46 | `$ grep -cE '\bDate\(\)' Sources/LggrApp/Services/SessionManager.swift` → `0` (time comes from `clock`). OBSERVE: with no session running, `sample`-ing the app for 5 s shows no repeating 1 Hz timer callback — nothing ticks when nothing runs. |
| P2-48 | `MenuBarManager` — derives `labelState` (`symbolName` from `SessionState`, plus an optional time string that is the countdown, or `+M:SS` after overrun, or the count-up when open-ended) from `SessionManager` and `preferences.showTimerInMenuBar`. | `Sources/LggrApp/Services/MenuBarManager.swift` (new) | P2-47, P2-16, P2-25 | TEST-equivalent OBSERVE: (1) no session → menu bar shows the `timer` symbol and no digits; (2) 25-min session → `24:59` within 2 s; (3) pause → symbol becomes `pause.circle` and the digits stop changing for 10 s; (4) let a 1-minute session overrun → the label switches to `+0:01`. |
| P2-49 | `SleepWakeObserver` — `for await` over `NSWorkspace.willSleepNotification` / `didWakeNotification`; in Phase 2 it only forces a redraw on wake so the timer is instantly correct. No non-`Sendable` value escapes the loop body. | `Sources/LggrApp/Services/SleepWakeObserver.swift` (new) | P2-47 | OBSERVE: start a 50-minute session, close the lid for ≥ 2 minutes, reopen — the timer shows the correct wall-clock-derived value within 1 s, with no catch-up animation. |
| P2-50 | `AppModel` — `@MainActor @Observable`: `selectedSection: SidebarSection`, `presentedSheet: AppSheet?` (`.startSession`, `.review(FocusSession)`, `.addAccomplishment(FocusSession)`, `.editProject(Project?)`). Sheet routing lives here, not in views. | `Sources/LggrApp/State/AppModel.swift` (new) | P2-54 | `$ grep -rn '@State private var.*[Ss]howing.*Sheet' Sources/LggrApp/Views \| wc -l` → `0` (no view owns sheet presentation state). |
| P2-51 | `AppDelegate` — `applicationWillTerminate` flushes the store before returning; `applicationShouldTerminateAfterLastWindowClosed` returns `false` so closing the window leaves the menu bar timer running. | `Sources/LggrApp/App/AppDelegate.swift` (new) | P2-24 | OBSERVE: start a session, close the main window (⌘W) → the app stays in the Dock and the menu bar timer keeps counting. Then quit (⌘Q) → `~/Library/Application Support/Lggr/store.json` contains the session (`$ python3 -c "import json;print(len(json.load(open('...'))['sessions']))"` → ≥ 1). |
| P2-52 | `LggrMain` — `@main App`. `MenuBarExtra { MenuBarContentView() } label: { MenuBarLabel(...) }` with `.menuBarExtraStyle(.window)`; `Window("Lggr", id: WindowID.main)` with `.defaultSize(width: 1040, height: 720)`; the `LGGR_GALLERY=1` gallery `Window`; a `Settings` scene. Injects `AppEnvironment.live()` and `AppModel` once per scene. | `Sources/LggrApp/App/LggrMain.swift` (new) | P2-44, P2-50, P2-56, P2-71 | `$ make run` → the app launches, one Dock icon, one menu bar item, one window sized ~1040×720. Two `@main` types would fail to build, so `swift build` succeeding after `P2-85` is also part of this. |
| P2-53 | `AppCommands` — `CommandGroup`s providing ⌘N (new focus session), ⌘⇧A (add accomplishment), and ⌘1–⌘7 (sidebar sections). ⌘Return (confirm) and Escape (dismiss) are provided by the sheets themselves via `.keyboardShortcut(.defaultAction)` / `.cancelAction`. ⌘⇧I is registered but **disabled with a tooltip** until Phase 3 — it is not a dead button. | `Sources/LggrApp/App/AppCommands.swift` (new) | P2-50, P2-52 | OBSERVE, with the main window frontmost: ⌘N opens the start sheet; Escape closes it; ⌘3 selects Accomplishments; ⌘5 selects Projects; ⌘⇧A opens the accomplishment sheet; the File menu shows "Capture Interruption" greyed out. |

### Stage G — views (P2-54 … P2-79)

Rule from `02-architecture.md` § 5.3: **a view never fetches its own data.** Only `TodayView`,
`ProjectsView`, `RootWindow` and the menu bar container read the environment.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-54 | `SidebarSection` — enum with all seven spec sections in fixed order (Today, Focus Sessions, Accomplishments, Weekly Review, Projects, Rules, Settings), each with `title`, `symbolName`, `shortcutNumber` 1–7 and `isAvailableInPhase2`. Numbering never changes as later phases land. | `Sources/LggrApp/Views/Root/SidebarSection.swift` (new) | P2-36 | TEST-equivalent: `$ grep -c 'case ' Sources/LggrApp/Views/Root/SidebarSection.swift` → ≥ 7. OBSERVE: ⌘1 … ⌘7 each select a different row. |
| P2-55 | `Sidebar` — native `List` with `.sidebar` style; sections not yet built render their row normally but their detail is an honest `EmptyStateView` ("Weekly review arrives in Phase 5") rather than a dead control. | `Sources/LggrApp/Views/Root/Sidebar.swift` (new) | P2-54, P2-40 | OBSERVE: selecting Weekly Review shows an empty state naming the phase; no row is a no-op. |
| P2-56 | `RootWindow` — `NavigationSplitView` with the sidebar and the selected detail; hosts the sheets routed by `AppModel`. | `Sources/LggrApp/Views/Root/RootWindow.swift` (new) | P2-55, P2-50 | OBSERVE: the window opens on Today (SPEC: "Today is selected by default"); the sidebar can be collapsed and restored. |
| P2-57 | `ProjectsModel` — `@Observable`; loads projects from the store, creates/updates/deletes, keeps `lastSelectedProjectID` in preferences fresh. | `Sources/LggrApp/State/ProjectsModel.swift` (new) | P2-20, P2-25 | Covered by `P2-59`'s OBSERVE. |
| P2-58 | `ProjectEditor` — sheet with name (required), colour picker over `Project.colorIDs`, icon picker over `Project.iconIDs`. Primary action **Save** on ⌘Return, disabled while the name is blank. | `Sources/LggrApp/Views/Projects/ProjectEditor.swift` (new) | P2-35, P2-36, P2-41 | OBSERVE: with an empty name, Save is disabled and ⌘Return does nothing; type a name → Save enables. |
| P2-59 | `ProjectsView` — list of projects with `ProjectBadge`, `EmptyStateView` when there are none, one primary action **New Project**, native context menu with Edit and Delete. | `Sources/LggrApp/Views/Projects/ProjectsView.swift` (new) | P2-57, P2-58, P2-42, P2-40 | **SPEC item 1.** OBSERVE: fresh install → Projects shows the empty state; click New Project, name it `SOR engineering`, pick purple + `hammer`, Save → the row appears with a purple `hammer` badge; quit and relaunch → it is still there. |
| P2-60 | `WorkTypePicker` — all 8 `WorkType`s; changing it updates the duration default (50 min for deep work/code review/incident/planning, 25 min for the rest) **unless the user has already edited the duration by hand**. | `Sources/LggrApp/Views/Focus/WorkTypePicker.swift` (new) | P2-07 | OBSERVE: open the start sheet → Deep work / 50 min; switch to Communication → 25 min; type a custom 35 → switch to Planning → stays 35. |
| P2-61 | `DurationPicker` — 25 / 50 / Custom / Open-ended, keyboard-selectable, custom accepts 1–480 minutes and rejects nothing silently. | `Sources/LggrApp/Views/Focus/DurationPicker.swift` (new) | — | OBSERVE: choosing Open-ended makes the active view count **up** from `0:00` and show no remaining time; choosing 25 makes it count **down** from `25:00`. |
| P2-62 | `ProjectPicker` — searchable list of active projects, preselecting `preferences.lastSelectedProjectID`, with an inline "New project…" escape hatch. | `Sources/LggrApp/Views/Focus/ProjectPicker.swift` (new) | P2-57, P2-25 | OBSERVE: start a session on `SOR engineering`, finish it, press ⌘N again → `SOR engineering` is already selected. |
| P2-63 | `OutcomeField` — required text field, autofocused on sheet appearance, offering the 5 most recent distinct intended outcomes as completions. | `Sources/LggrApp/Views/Focus/OutcomeField.swift` (new) | P2-20 | OBSERVE: press ⌘N and type immediately without clicking — the characters land in the outcome field. |
| P2-64 | `StartSessionForm` — the under-five-seconds path. Order: Outcome, Project, Duration, Work type. Primary **Start Focus** (⌘Return, disabled while the outcome is blank); secondary **Start without timer** (= open-ended). Escape cancels. | `Sources/LggrApp/Views/Focus/StartSessionForm.swift` (new) | P2-60…P2-63, P2-41, P2-47 | **SPEC item 2.** OBSERVE (timed, from a cold app with one existing project): ⌘N → type `Finish the receipt deduplication PR` → ⌘Return. Session is running in **under 5 seconds**, mouse untouched. |
| P2-65 | `TimerDisplay` — visually dominant, monospaced digits, progress ring for a planned duration and none when open-ended; after the countdown reaches zero it shows `+M:SS`. Takes `session` and `now` as plain values. | `Sources/LggrApp/Views/Focus/TimerDisplay.swift` (new) | P2-34, P2-16 | **SPEC item 3.** OBSERVE: the timer's point size is the largest on the screen; the digits do not shift horizontally as they change; a 1-minute session shows `+0:01` one second after zero. |
| P2-66 | `SessionControls` — Pause/Resume (Space when no text field has focus) and Finish. Two controls, nothing else. | `Sources/LggrApp/Views/Focus/SessionControls.swift` (new) | P2-47 | **SPEC item 5.** OBSERVE: press Space → button reads Resume, timer freezes for a 10 s count; press Space → it resumes from where it stopped, having lost exactly the paused seconds. |
| P2-67 | `ActiveSessionView` — intended outcome and timer dominant; project badge; the two controls. Deliberately **no** activity strip, switch count or timeline in Phase 2 (those are `P3-05`/`P3-06`). | `Sources/LggrApp/Views/Focus/ActiveSessionView.swift` (new) | P2-65, P2-66, P2-42 | OBSERVE: the screen contains exactly one primary action (Finish) and shows no empty "Context switches: —" placeholder. |
| P2-68 | `MenuBarLabel` — `SessionState.symbolName` + optional time string from `MenuBarManager`. Redraws on `SessionManager.tick`. | `Sources/LggrApp/Views/MenuBar/MenuBarLabel.swift` (new) | P2-48 | **SPEC item 4.** OBSERVE: with the main window closed, the menu bar shows `24:59`, `24:58`, `24:57` on successive seconds. |
| P2-69 | `MenuBarIdleView` — the six idle entries from SPEC § 1. Phase 2 wires Start Focus Session, Quick Timer (25 min, last project, outcome required inline), Add Accomplishment and Open Today. Capture Interruption and Open Weekly Review are **disabled with an explanatory tooltip** naming their phase. | `Sources/LggrApp/Views/MenuBar/MenuBarIdleView.swift` (new) | P2-47, P2-50 | OBSERVE: all six rows are present; the four live ones each perform their action; the two disabled ones show a tooltip on hover and cannot be clicked. |
| P2-70 | `MenuBarActiveView` — intended outcome, remaining/elapsed time, project, Pause, Finish, Open full app. | `Sources/LggrApp/Views/MenuBar/MenuBarActiveView.swift` (new) | P2-47, P2-48 | OBSERVE, with the main window **closed**: the popover shows the outcome and a ticking time; Pause works; Finish opens the review sheet in a window that comes to the front. |
| P2-71 | `MenuBarContentView` — switches between idle and active; the whole menu bar experience must work with the main window closed. | `Sources/LggrApp/Views/MenuBar/MenuBarContentView.swift` (new) | P2-69, P2-70 | OBSERVE: quit, relaunch, press ⌘W to close the window, then run a full start → pause → resume → finish cycle entirely from the menu bar. |
| P2-72 | `ResultStatusPicker` — the five `SessionResultStatus` options, selectable with arrow keys, each with its symbol. Neutral copy and neutral colour; nothing rendered in red. | `Sources/LggrApp/Views/Review/ResultStatusPicker.swift` (new) | P2-07 | **SPEC item 7.** OBSERVE: five options; `$ grep -cE '\.red\b' Sources/LggrApp/Views/Review/*.swift` → `0`. |
| P2-73 | `SummaryEditor` — a `TextEditor` prefilled with `SessionSummaryBuilder.suggestedSummary`, freely editable, with a "Reset to suggestion" affordance. | `Sources/LggrApp/Views/Review/SummaryEditor.swift` (new) | P2-17 | OBSERVE: the field is prefilled on open; edit it, press Reset → the generated text returns. |
| P2-74 | `SessionReviewSheet` — "What happened?", the status picker, the summary editor, and progressively disclosed Tangible result / Blocker / Next step (collapsed by default; only the status is required). Primary **Save** (⌘Return) disabled until a status is chosen. | `Sources/LggrApp/Views/Review/SessionReviewSheet.swift` (new) | P2-72, P2-73, P2-47 | **SPEC items 6+7.** OBSERVE: Finish opens the sheet; Save is disabled until a status is picked; the three optional fields are hidden behind one disclosure control; Escape leaves the session in `.awaitingReview` and the sheet reappears next time the app is opened. |
| P2-75 | `TodayModel` — `@Observable`; loads today's sessions and accomplishments via `DateInterval.day(containing: clock.now)`, exposes them newest-first, and refreshes when a session finishes. | `Sources/LggrApp/State/TodayModel.swift` (new) | P2-14, P2-20 | Covered by `P2-78`. |
| P2-76 | `CompletedSessionRow` — outcome, project badge, time range, duration, result status, and an **Add accomplishment** action. Pure `let` inputs plus one closure, per `02-architecture.md` § 5.3. | `Sources/LggrApp/Views/Today/CompletedSessionRow.swift` (new) | P2-42, P2-16 | `$ grep -c '@Environment' Sources/LggrApp/Views/Today/CompletedSessionRow.swift` → `0`. OBSERVE in the gallery: renders correctly for a session with a project and for one without. |
| P2-77 | `TodayHeader` — the current session if one is running, otherwise the single primary action **Start Focus Session**. | `Sources/LggrApp/Views/Today/TodayHeader.swift` (new) | P2-65, P2-41 | OBSERVE: with no session, the header shows exactly one prominent button; with a session running it shows the live timer instead. |
| P2-78 | `TodayView` — header, then today's completed sessions, then today's accomplishments; `EmptyStateView` for each empty region. No metric tiles or timeline in Phase 2 (those are `P4-01`/`P4-02`). | `Sources/LggrApp/Views/Today/TodayView.swift` (new) | P2-75, P2-76, P2-77, P2-40 | **SPEC item 9.** OBSERVE: finish a session → within 1 s it appears in Today with the correct duration and result status; quit and relaunch → it is still there. |
| P2-79 | `AddAccomplishmentSheet` — opened from a completed session row *and* from ⌘⇧A / the menu bar. Prefills title from the session's intended outcome, type defaults to `.featureCompleted`, project inherited from the session; `focusSessionID` set when it came from a session. Primary **Add** on ⌘Return. | `Sources/LggrApp/Views/Accomplishments/AddAccomplishmentSheet.swift` (new) | P2-11, P2-20, P2-50 | **SPEC item 10.** OBSERVE: from a completed row, click Add accomplishment → title is prefilled with the outcome → ⌘Return → it appears under Today's Accomplishments and survives relaunch. In `store.json` its `focusSessionID` equals that session's `id`. |

### Stage H — integration and closeout (P2-80 … P2-86)

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P2-80 | `GalleryEntry` — wrapper that renders one view twice side by side with `.preferredColorScheme(.light)` and `.dark`, labelled. | `Sources/LggrApp/Dev/GalleryEntry.swift` (new) | P2-33 | `$ grep -c 'preferredColorScheme' Sources/LggrApp/Dev/GalleryEntry.swift` → ≥ 2. |
| P2-81 | `PreviewGallery` — a `Window` scene present only when `LGGR_GALLERY=1`, registering every Phase 2 presentational view against `AppEnvironment.fake()`. This is the light/dark verification loop on a machine without `#Preview`. | `Sources/LggrApp/Dev/PreviewGallery.swift` (new) | P2-80, P2-38…P2-42, P2-65, P2-76 | `$ make gallery` → a second window listing ≥ 12 entries, each shown light and dark. `$ make run` (without the variable) → **no** gallery window. |
| P2-82 | `Previews.swift` — the same registrations as real `#Preview` macros, for a machine with Xcode. Excluded from the SPM target by `P2-04`. | `Sources/LggrApp/_XcodeOnly/Previews.swift` (new) | P2-04, P2-81 | `$ swift build` → `Build complete!` **and** `$ grep -c '#Preview' Sources/LggrApp/_XcodeOnly/Previews.swift` → ≥ 12. `$ ./Scripts/check-layering.sh` → `layering OK` (the guard must exempt this directory). |
| P2-83 | Relaunch recovery: on launch, `SessionManager.restoreActiveSession()` calls `loadActiveSession()`; a session with `endedAt == nil` resumes with the correct elapsed time (including a pause that was open at quit); one with `endedAt != nil` and `resultStatus == nil` reopens the review sheet. | `Sources/LggrApp/Services/SessionManager.swift` (edit), `Sources/LggrApp/App/LggrMain.swift` (edit) | P2-47, P2-52, P2-74 | OBSERVE (a): start a 50-min session, wait 30 s, ⌘Q, relaunch → the timer reads ~`49:30`, not `50:00`. OBSERVE (b): start, pause, ⌘Q, wait 60 s, relaunch → still paused, elapsed unchanged. OBSERVE (c): finish a session, dismiss the review with Escape, ⌘Q, relaunch → the review sheet is presented again. |
| P2-84 | Keyboard-only pass: every Phase 2 action reachable without a mouse; visible focus rings; Escape closes every sheet; Space pauses **only** when no text field has focus. | all Phase 2 views (edit) | P2-53…P2-79 | OBSERVE: unplug/ignore the mouse and complete the full walkthrough in § 5.3 end to end. In particular, typing a space inside the summary editor inserts a space and does **not** resume the session. |
| P2-85 | Delete the three scaffold files and the scaffold `@main`. | `Sources/LggrKit/_Scaffold.swift`, `Sources/LggrApp/_Scaffold.swift`, `Tests/LggrKitTests/_ScaffoldTests.swift` (delete) | P2-52, P2-26…P2-32 | `$ ls Sources/LggrKit/_Scaffold.swift 2>&1` → `No such file or directory`. `$ swift build && ./Scripts/test.sh` → both green, and `moduleName()` no longer appears in the test output. |
| P2-86 | Run the whole Phase 2 definition of done (§ 5) and record the result in the commit message. | — | P2-01 … P2-85 | Every command in § 5.1 produces its stated output and every step of § 5.3 behaves as written, on a machine where `~/Library/Application Support/Lggr/` was deleted first. |

---

## 5. Definition of done — Phase 2

Phase 3 does not begin until all three subsections pass **in one sitting, in this order**, starting
from a clean tree.

### 5.1 Commands

```bash
# 0. Clean slate
rm -rf .build build ~/Library/Application\ Support/Lggr
defaults delete com.luisdoriz.lggr 2>/dev/null || true
```

| # | Command | Expected result |
|---|---|---|
| 1 | `swift build` | Ends with `Build complete!`; exit `0`; **zero warnings** in the `LggrKit` and `LggrApp` compile lines. |
| 2 | `./Scripts/test.sh` | Ends with `OK: Test run with N tests in M suites passed`, **N ≥ 50**, exit `0`. (`swift test` on its own is not acceptable evidence — see § 1.2.) |
| 3 | `./Scripts/check-layering.sh` | `layering OK`, exit `0`. |
| 4 | `grep -rn '@Model\|#Predicate\|#Preview' Sources/LggrKit Sources/LggrApp --include='*.swift' \| grep -v '_XcodeOnly'` | **No output**, exit `1`. |
| 5 | `grep -rn 'DispatchQueue\|OperationQueue\|NSLock\|@unchecked Sendable\|import Combine' Sources --include='*.swift'` | **No output**, exit `1`. (`02-architecture.md` § 8.) |
| 6 | `grep -rn 'try!\|as!' Sources --include='*.swift'` | **No output**, exit `1`. |
| 7 | `grep -rn 'import SwiftUI\|import AppKit\|import SwiftData' Sources/LggrKit --include='*.swift'` | **No output**, exit `1`. |
| 8 | `make app` | Ends with `Built .../build/Lggr.app`; the run includes `layering OK` and a successful `codesign --verify`. |
| 9 | `plutil -lint build/Lggr.app/Contents/Info.plist` | `... : OK` |
| 10 | `codesign --verify --strict --verbose=2 build/Lggr.app` | `valid on disk` and `satisfies its Designated Requirement`. |
| 11 | `otool -L build/Lggr.app/Contents/MacOS/LggrApp \| grep -icE 'CFNetwork\|/Network\.framework\|libcurl'` | `0` — the "zero network code" claim in the README is mechanically true. |
| 12 | `swift package dump-package \| python3 -c "import json,sys;print(json.load(sys.stdin)['dependencies'])"` | `[]` — no third-party dependencies. |
| 13 | `LGGR_SWIFTDATA=1 swift build` | **Not run on this machine.** Recorded as *deferred, Xcode required*; the acceptance evidence is that `Package.swift` contains the conditional target and `Sources/LggrPersistence/` is absent, so `swift build` (step 1) is unaffected. Runs for real in `P3-12`'s environment or whenever an Xcode machine is available. |
| 14 | *(after § 5.3)* `python3 -c "import json;d=json.load(open('$HOME/Library/Application Support/Lggr/store.json'));print(d['schemaVersion'],len(d['projects']),len(d['sessions']),len(d['accomplishments']))"` | `1 1 1 1` — one project, one session and one accomplishment persisted at schema version 1. |

### 5.2 Test-count floor per file

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

### 5.3 The manual walkthrough — all ten SPEC Phase 2 items, keyboard only

Run against `build/Lggr.app` after the clean slate in § 5.1. Twelve steps; every one has a stated
expected result. A failure at any step means Phase 2 is not done.

| # | Action | Expected result | SPEC item |
|---|---|---|---|
| 1 | `open build/Lggr.app` | Window opens ~1040×720 on **Today**; Today shows an empty state; the menu bar shows the `timer` symbol with no digits. | — |
| 2 | ⌘5, then the New Project action; type `SOR engineering`; pick purple + `hammer`; ⌘Return | The project appears in the list with a purple `hammer` badge. | **1. Create a project** |
| 3 | ⌘N; type `Finish the receipt deduplication PR`; ⌘Return — timed from the ⌘N keypress | The session is running in **under 5 seconds**. `SOR engineering` was preselected; work type Deep work; duration 50 minutes. | **2. Start a focus session** |
| 4 | Look at the main window | The timer is the largest element on screen, reading `49:5x` and decrementing once per second; the intended outcome is directly beneath it. | **3. Timer in the main window** |
| 5 | ⌘W to close the window; look at the menu bar; open the popover and hold it open for 10 s | The menu bar shows a decrementing `49:xx`, and it keeps decrementing while the popover is open (`.common` run-loop mode). | **4. Timer in the menu bar** |
| 6 | Press Space (or Pause in the popover); wait 15 s; press Space again | The symbol becomes `pause.circle`, the digits are frozen for the full 15 s, and on resume the clock continues from exactly where it stopped — 15 s were lost, not counted. | **5. Pause and resume** |
| 7 | Finish, from the popover | The main window comes to the front with the review sheet presented, asking **What happened?** | **6. Finish the session** |
| 8 | Press Escape, then ⌘Q, then relaunch | The review sheet is presented again — an unreviewed session is never lost. | — |
| 9 | Choose **Made progress**; leave the generated summary as-is; ⌘Return | The sheet dismisses. The generated summary mentions the intended outcome, the project and the duration. | **7. Select the result status** |
| 10 | ⌘Q, relaunch, ⌘1 | Today lists the completed session with the correct time range, duration and "Made progress". | **8. Persist the session** · **9. Show it in Today** |
| 11 | Tab to the session row's **Add accomplishment** action and activate it; ⌘Return | The sheet opens with the title prefilled from the intended outcome; on save the accomplishment appears under Today's Accomplishments. | **10. Add an accomplishment from the completed session** |
| 12 | ⌘Q, relaunch; then run § 5.1 command 14 | The accomplishment is still there and its `focusSessionID` matches the session's `id`. | — |

Plus two appearance checks:

- `make gallery` — every registered view is legible and correctly contrasted in **both** columns.
- Switch System Settings → Appearance between Light and Dark **while the app is running**; every
  screen re-renders correctly with no stale colours.

---

## 6. Phase 3 — automatic application tracking

Task-level granularity. Expanded to Phase-2 detail when Phase 2 is accepted.

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P3-01 | Phase 3 model types: `ActivityEvent` (+ `redactedIfPrivate()`, `duration(at:)`), `ActivityCategory`, `ClassificationRule` (+ `matches`, `specificity`), `Interruption`, and their enums appended to `Enums.swift` | `Sources/LggrKit/Model/ActivityEvent.swift`, `ClassificationRule.swift`, `Interruption.swift`, `Enums.swift` (edit) | P2-86 | TEST `ActivityEventTests`, `ClassificationRuleTests` pass; every `redactedIfPrivate()` field assertion from `03-data-model.md` § 2.4 is covered. |
| P3-02 | Extend `LggrStore` with the `[P3]` methods in all conformers | `Sources/LggrKit/Store/*.swift` (edit) | P3-01 | `LggrStoreContractTests` grows to cover activity, interruption and rule CRUD, still 2 backends × all cases. |
| P3-03 | `ApplicationMonitoring` protocol + `WorkspaceApplicationMonitor` + `StubApplicationMonitor` | `Sources/LggrApp/Services/ApplicationMonitoringService.swift` | P2-86 | OBSERVE: switch between three apps; the live activity strip names each within 1 s. `$ grep -c 'NSRunningApplication' Sources/LggrApp/Services/ApplicationMonitoringService.swift` shows the type never escapes the `for await` body. |
| P3-04 | `IdleDetecting` protocol + `HIDIdleDetector` (CGEventSource, no Accessibility needed) + `StubIdleDetector` | `Sources/LggrApp/Services/IdleDetectionService.swift` | P2-86 | OBSERVE: with `idleThreshold` set to 60 s, do not touch the machine for 70 s — the timeline shows an idle block starting at ~60 s. |
| P3-05 | `ActivityTrackingService` — closed intervals attached to the session, batched writes, redaction at capture time | `Sources/LggrApp/Services/ActivityTrackingService.swift` | P3-02…P3-04 | TEST `PrivacyRedactorTests`; plus `$ grep -c 'redactedIfPrivate' Sources/LggrApp/Services/ActivityTrackingService.swift` → ≥ 1 on the write path. |
| P3-06 | Pure aggregation: `ActivityAggregator`, `ActivityCoalescer`, `ContextSwitchCounter`, `SessionTimelineBuilder` | `Sources/LggrKit/Domain/*.swift` | P3-01 | TEST `ActivityAggregatorTests`, `ActivityCoalescerTests`, `ContextSwitchCounterTests`, `SessionTimelineBuilderTests` all pass. |
| P3-07 | `ClassificationEngine` (pure) + `ClassificationService` (cache) + the shipped default rule set | `Sources/LggrKit/Domain/ClassificationEngine.swift`, `Sources/LggrApp/Services/ClassificationService.swift` | P3-01 | TEST `ClassificationEngineTests`: priority then specificity then id ordering; a `.manual` event is never reclassified. |
| P3-08 | `WindowTitleReader` (AX, gated on `AXIsProcessTrusted`) and `BrowserDomainReader` (Apple Events, opt-in) | `Sources/LggrApp/Services/WindowTitleReader.swift`, `BrowserDomainReader.swift` | P3-03 | OBSERVE: with Accessibility **denied**, the app still records app names and never prompts twice; with it granted, window titles appear. |
| P3-09 | `PrivacyRedactor` + privacy exclusion UI | `Sources/LggrKit/Domain/PrivacyRedactor.swift`, `Sources/LggrApp/Views/Rules/*` | P3-05, P3-07 | OBSERVE: mark an app private, use it, then inspect `store.json` — it contains `Private activity` and **no** bundle id, title or domain for that interval. |
| P3-10 | `LiveActivityStrip`, `SessionTimelineStrip`, `SessionStatsGrid` | `Sources/LggrApp/Views/Focus/*`, `Views/Review/SessionStatsGrid.swift` | P3-06 | OBSERVE: the review sheet now shows total/focused/idle time, context-switch count and time by category, matching a hand-computed fixture. |
| P3-11 | `InterruptionCaptureSheet` + ⌘⇧I enabled | `Sources/LggrApp/Views/Focus/InterruptionCaptureSheet.swift`, `App/AppCommands.swift` (edit) | P3-02 | OBSERVE: ⌘⇧I during a session saves a note to the inbox **without** ending the session and increments `interruptionCount`. |
| P3-12 | Ship the `LggrPersistence` target (`SD*` models + mappings + `SwiftDataStore`) and run the contract suite against it | `Sources/LggrPersistence/**` | P3-02 | On a machine with Xcode: `LGGR_SWIFTDATA=1 swift build` → `Build complete!`, and `LGGR_SWIFTDATA=1 ./Scripts/test.sh --filter LggrStoreContract` → the suite runs against 3 backends with identical results. |

---

## 7. Phase 4 — daily experience

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P4-01 | `DailyDigest` — the Today metric rollup (tracked/focused/reactive/meeting/communication time, session count, switches, completed outcomes, open inbox count) | `Sources/LggrKit/Domain/DailyDigest.swift` | P3-06 | TEST `DailyDigestTests` against a fixture day whose totals are computed by hand in the test. |
| P4-02 | `TodayMetricsRow`, `DailyTimelineView`, `TimelineBlockView` — grouped blocks, not one row per switch | `Sources/LggrApp/Views/Today/*` | P4-01 | OBSERVE: a day with 40 app switches across 3 sessions renders ≤ 8 timeline blocks, each labelled like SPEC § 7's `9:00–9:52 / Receipt deduplication / Xcode, Terminal, GitHub / Completed`. |
| P4-03 | `AccomplishmentLogView`, `AccomplishmentRow`, `AccomplishmentTypePicker` | `Sources/LggrApp/Views/Accomplishments/*` | P2-79 | OBSERVE: the log groups by day, filters by project and type, and all 11 accomplishment types are selectable. |
| P4-04 | `InterruptionInboxView` + inbox badge | `Sources/LggrApp/Views/Today/InterruptionInboxView.swift`, `State/InboxModel.swift` | P3-11 | OBSERVE: capture 3 interruptions; the badge reads 3; resolving one drops it to 2 and the item leaves the inbox. |
| P4-05 | `FocusSessionsView`, `FocusSessionDetailView` | `Sources/LggrApp/Views/Sessions/*` | P3-10 | OBSERVE: ⌘2 lists sessions newest-first; opening one shows its timeline and stats. |
| P4-06 | Markdown rendering: `MarkdownRendering`, `DailySummaryMarkdown`, `AccomplishmentLogMarkdown` | `Sources/LggrKit/Export/*` | P4-01 | TEST `MarkdownExportTests`: a fixture day renders to a byte-exact expected string held in the test; no `Optional(`, no `nil`, no trailing whitespace. |
| P4-07 | `ExportService` — `NSSavePanel` + write | `Sources/LggrApp/Services/ExportService.swift` | P4-06 | OBSERVE: File → Export Daily Summary writes a `.md` file whose contents equal `DailySummaryMarkdown`'s output for that day. |

---

## 8. Phase 5 — weekly review

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P5-01 | `WeeklyOutcome` + `OutcomePriority`/`OutcomeStatus`; store methods in all conformers | `Sources/LggrKit/Model/WeeklyOutcome.swift`, `Store/*` (edit) | P4-07 | `LggrStoreContractTests` covers outcome CRUD and week-range queries on every backend. |
| P5-02 | `WeeklyOutcomesView`, `WeeklyOutcomeEditor`, `WeeklyModel` | `Sources/LggrApp/Views/Weekly/*`, `State/WeeklyModel.swift` | P5-01 | OBSERVE: creating a second primary outcome shows a gentle inline hint and is **not** blocked (`maximumPerWeek` is a soft cap). |
| P5-03 | `PlannedVsReactive` | `Sources/LggrKit/Domain/PlannedVsReactive.swift` | P5-01 | TEST `PlannedVsReactiveTests`: a fixture week of 6 sessions yields the hand-computed planned/reactive split; `isReactive` overrides the `workType` default. |
| P5-04 | `WeeklyReviewBuilder` — time by project / work type / category, sessions completed vs interrupted, switches per day, main accomplishments, unblocking count, primary-outcome share | `Sources/LggrKit/Domain/WeeklyReviewBuilder.swift` | P5-03, P4-01 | TEST `WeeklyReviewBuilderTests`: every field asserted against a hand-computed fixture week; percentages sum to 100 ± 0.1. |
| P5-05 | `InsightGenerator` — neutral, evidence-based observations only | `Sources/LggrKit/Domain/InsightGenerator.swift` | P5-04 | TEST `InsightGeneratorTests`: fixtures produce the SPEC § 9 sentence shapes; and a lexicon test asserts no output contains any word from a banned judgmental list (`should`, `only`, `wasted`, `failed`, `poor`, `bad`). |
| P5-06 | `WeeklyReviewView`, `TimeAllocationChart`, `InsightList` | `Sources/LggrApp/Views/Weekly/*` | P5-04, P5-05 | OBSERVE: ⌘4 shows the review; the chart uses Swift Charts, one chart per screen, no gradients. |
| P5-07 | `WeeklyReviewMarkdown`, `SessionsCSVExporter` | `Sources/LggrKit/Export/*` | P5-04 | TEST `MarkdownExportTests` (weekly) reproduces SPEC's example structure; TEST `CSVExportTests`: header row is exact, embedded commas and quotes are escaped, and the file round-trips through `csv` parsing. |

---

## 9. Phase 6 — product polish

| ID | Task | Files | Deps | Acceptance |
|---|---|---|---|---|
| P6-01 | Onboarding + permission explainer | `Sources/LggrApp/Views/Onboarding/*` | P5-07 | OBSERVE: shown exactly once (`hasCompletedOnboarding`); explicitly lists what is never collected; relaunching does not show it again. |
| P6-02 | `PermissionsService` — request Accessibility/Notifications/Automation at most once per user action, never on launch | `Sources/LggrApp/Services/PermissionsService.swift` | P6-01 | OBSERVE: deny Accessibility, then use the app for 10 minutes across two launches — zero further prompts, and tracking degrades to app-name-only. |
| P6-03 | `GlobalShortcutService` — Carbon `RegisterEventHotKey`, default ⌘⇧Space, configurable | `Sources/LggrApp/Services/GlobalShortcutService.swift`, `Views/Settings/ShortcutsSettingsView.swift` | P6-02 | OBSERVE: with Lggr in the background and another app frontmost, ⌘⇧Space brings up the start sheet; rebinding to ⌥⇧F5 works after a rebind and after a relaunch. |
| P6-04 | `NotificationService` + the four notification kinds | `Sources/LggrApp/Services/NotificationService.swift`, `Views/Settings/NotificationsSettingsView.swift` | P6-02 | OBSERVE: a 1-minute session posts a completion notification; with the toggle off it posts none. `RecordingNotifier` asserts the same in the gallery. |
| P6-05 | Settings window — General, Tracking, Privacy, Shortcuts, Notifications | `Sources/LggrApp/Views/Settings/*` | P6-03, P6-04 | OBSERVE: ⌘, opens it; every `UserPreferences` field is reachable; "Delete activity history" empties activity and nothing else. |
| P6-06 | `LaunchAtLoginService` (`SMAppService`) | `Sources/LggrApp/Services/LaunchAtLoginService.swift` | P6-05 | OBSERVE: toggling it on registers the login item and the state survives a relaunch. |
| P6-07 | Hide-Dock-icon preference via `NSApp.setActivationPolicy(.accessory)` | `Sources/LggrApp/App/AppDelegate.swift` (edit) | P6-05 | OBSERVE: toggling it hides the Dock icon at runtime with no relaunch; the `MenuBarExtra` and the global hot key keep working. |
| P6-08 | Empty and error states everywhere; store failures surface as inline, recoverable messages | all views (edit) | P6-05 | OBSERVE: with `store.json` made read-only, saving a session shows a non-modal inline error naming the file and the session is not silently lost. |
| P6-09 | Accessibility pass — VoiceOver labels, contrast, Dynamic Type | all views (edit) | P6-08 | OBSERVE: VoiceOver reads a meaningful label for every control on Today, the start sheet and the review sheet; at the largest Dynamic Type size no text is clipped in any Phase 2 screen. |
| P6-10 | Light/dark refinement pass across the whole gallery | `Sources/LggrApp/DesignSystem/*` (edit) | P6-09 | OBSERVE: every gallery entry passes a side-by-side review; no hard-coded hex outside `Palette.swift`. |
| P6-11 | Icon + version metadata for a distributable build | `Resources/*` (edit) | P6-10 | `$ codesign --verify --strict build/Lggr.app` passes; `CFBundleShortVersionString` is bumped; `Scripts/make-icon.sh` regenerates the icon reproducibly. |

---

## 10. Unit test inventory (SPEC § *Testing requirements*)

The spec names ten behaviours. Each is listed with the **phase in which it first becomes testable**,
the file it lives in, and what "passing" means. Everything below `Rule matching` is in the spec's
own order.

| # | SPEC behaviour | First testable | File | Passing means |
|---|---|---|---|---|
| 1 | **Timer behaviour** | **P2** (`P2-26`) | `Tests/LggrKitTests/FocusSessionTimingTests.swift` | `elapsed`/`remaining`/`overrun`/`progress`/`effectiveDuration` against injected `Date`s; open-ended returns `nil` remaining; `elapsed` never exceeds the wall-clock span; a finished session returns the same `elapsed` for every `now`. |
| 2 | **Pause and resume calculations** | **P2** (`P2-26`) | same file | The exact worked table in `03-data-model.md` § 3.2 (two cycles → `pausedDuration == 900`, `elapsed == 2700`); frozen clock while paused; double-pause, orphan-resume, backwards-clock and finish-while-paused all behave as § 3.5 states. |
| 3 | **Session completion** | **P2** (`P2-26`, `P2-28`) | `FocusSessionTimingTests.swift` + `SessionSummaryBuilderTests.swift` | `finish` is idempotent and clamps `endedAt ≥ startedAt`; `state` moves `running → awaitingReview → completed` as `resultStatus` is set; the generated summary is deterministic and contains no `Optional`/`nil`. |
| 4 | **Activity aggregation** | **P3** (`P3-06`) | `Tests/LggrKitTests/ActivityAggregatorTests.swift` (+ `ActivityCoalescerTests.swift`) | Totals by application and by category over a fixture day match hand-computed values; adjacent same-app intervals coalesce; open intervals are measured against an injected `now`; idle intervals are excluded from focused time. |
| 5 | **Context-switch calculation** | **P3** (`P3-06`) | `Tests/LggrKitTests/ContextSwitchCounterTests.swift` | A → B → A counts 2; A → A counts 0; an idle interval between two A intervals does not create a switch; switches are counted per session and per day. |
| 6 | **Planned versus reactive calculation** | **P5** (`P5-03`) | `Tests/LggrKitTests/PlannedVsReactiveTests.swift` | A fixture week splits into planned/reactive seconds matching hand-computed values; an explicit `isReactive` overrides `workType.isReactiveByDefault`; the two shares sum to the total tracked time. |
| 7 | **Rule matching** | **P3** (`P3-01`, `P3-07`) | `Tests/LggrKitTests/ClassificationRuleTests.swift` (+ `ClassificationEngineTests.swift`) | All four `RuleMatchType`s; case-insensitivity; `domain` matches exactly and by suffix (`github.com` matches `gist.github.com` but not `notgithub.com`); project and work-type scoping; disabled rules never match; ordering is priority → specificity → id; a `.manual` event is never reclassified. |
| 8 | **Private application handling** | **P3** (`P3-01`, `P3-09`) | `Tests/LggrKitTests/PrivacyRedactorTests.swift` (+ `ActivityEventTests.swift`) | `redactedIfPrivate()` sets `applicationName == "Private activity"`, empties `bundleIdentifier`, and nils `windowTitle`, `domain`, category `.unknown`, source `.unclassified`; a rule never matches a private event; the redacted value is what reaches the store, asserted by writing through `InMemoryStore` and reading back. |
| 9 | **Weekly summary generation** | **P5** (`P5-04`, `P5-05`) | `Tests/LggrKitTests/WeeklyReviewBuilderTests.swift` (+ `InsightGeneratorTests.swift`) | Every weekly field matches a hand-computed fixture week; percentages sum to 100 ± 0.1; generation is deterministic; no insight string contains a word from the banned judgmental lexicon. |
| 10 | **Markdown export** | **P4** for daily + accomplishment log (`P4-06`); **P5** for the weekly review (`P5-07`) | `Tests/LggrKitTests/MarkdownExportTests.swift` | Byte-exact comparison against an expected document held in the test; heading levels and bullet order match SPEC's example; no `Optional(`, no `nil`, no trailing whitespace, and a trailing newline. |

**Supporting suites that the spec does not name but the architecture requires:**

| Suite | Phase | File | Covers |
|---|---|---|---|
| `LggrStoreContractTests` | P2 (grows every phase) | `Tests/LggrKitTests/LggrStoreContractTests.swift` | The same cases run against `InMemoryStore`, `JSONFileStore` and — under `LGGR_SWIFTDATA=1` from `P3-12` — `SwiftDataStore`. Upsert-by-id, range queries, `loadActiveSession`, project-delete nullification, session-delete cascade equivalence. This is what makes the three backends interchangeable. |
| `CodableRoundTripTests` | P2 | `Tests/LggrKitTests/CodableRoundTripTests.swift` | Every value type and every enum **raw string** survives encode/decode, so a Swift rename cannot silently invalidate stored JSON. |
| `StoreSnapshotCodableTests` | P2 | `Tests/LggrKitTests/StoreSnapshotCodableTests.swift` | `schemaVersion` policy: a newer version is refused with a clear error; an equal version round-trips. |
| `JSONFileStoreTests` | P2 | `Tests/LggrKitTests/JSONFileStoreTests.swift` | Durability across a restart, atomic writes leaving no temp file, missing file → empty store, corrupt file → `invalidData` with the bad file preserved. |
| `DurationFormattingTests` | P2 | `Tests/LggrKitTests/DurationFormattingTests.swift` | Every format the timer and menu bar render, including overrun and the zero case. |
| `UserPreferencesTests` | P2 | `Tests/LggrKitTests/UserPreferencesTests.swift` | Exclusion/private matching, `retentionCutoff`, `UserDefaults` round-trip in a scratch suite. |
| `EnumsTests`, `SupportTests` | P2 | as named | Case counts, `suggestedDuration` defaults, `FixedClock`, calendar windows, fixture determinism. |
| `SessionTimelineBuilderTests` | P3 | as named | Grouped timeline blocks: contiguous same-session intervals merge; block labels list the top 3 applications. |
| `DailyDigestTests` | P4 | as named | Today's rollup against a hand-computed fixture day. |
| `CSVExportTests` | P5 | as named | Exact header row; commas, quotes and newlines inside fields are escaped and survive a round-trip parse. |

---

## 11. What could make Phase 2 slip — risk-ordered

Ordered by *expected days lost* = likelihood × cost. Each has a tripwire (how you find out early)
and a fallback (what you do instead).

### 1. `MenuBarExtra`'s label does not redraw at 1 Hz — *high likelihood, 1–3 days*

The label of a `MenuBarExtra` is not a normal view: it is hosted by the system, it is rebuilt on its
own schedule, and it is a well-known source of "my timer freezes in the menu bar" reports. If the
label does not observe `SessionManager.tick` in a way SwiftUI honours, **SPEC Phase 2 item 4 cannot
be delivered at all**, and it is easy not to notice until the end of the phase.

- **Tripwire:** do `P2-46` + `P2-48` + `P2-68` as a throwaway spike *on day one*, before any other
  view work. The test is literally: does the menu bar count down for 60 uninterrupted seconds, and
  does it keep counting while the popover is open?
- **Fallback:** drop `MenuBarExtra` for an AppKit `NSStatusItem` owned by `AppDelegate`, whose
  `button.title` is set directly from the tick. This is a contained change (`MenuBarLabel.swift` +
  `AppDelegate.swift`) *if* nothing else has been built on top of the `MenuBarExtra` scene — which
  is exactly why the spike goes first.

### 2. A false-green test suite — *medium likelihood, unbounded cost*

`swift test` exits `0` having run **nothing** on this machine (§ 1.2). Any agent that reports
"tests pass" from a raw `swift test` has reported nothing at all, and the error compounds silently
across every subsequent task.

- **Tripwire:** `./Scripts/test.sh` already fails on a missing `Test run with N tests` line. The
  residual risk is an agent bypassing it.
- **Fallback:** none needed — enforce it. Every acceptance criterion in § 4 and § 5 names
  `./Scripts/test.sh`, never `swift test`. Add `test:` to the README's first code block so it is
  the first thing anyone copies.

### 3. Store-shape churn from the C1 conflict — *medium likelihood, 1–2 days*

`02-architecture.md` and `03-data-model.md` describe two incompatible `LggrStore`s (`actor` +
`Sendable` + `upsert`, versus `@MainActor` + `AnyObject` + `saveSession`). If two agents pick
differently, every call site in stages E–G has to be rewritten.

- **Tripwire:** it is resolved in § 2 `C1`. `P2-20` is a hard dependency of everything in stages
  C, F and G, so a wrong choice is visible on the very next task rather than at integration.
- **Fallback:** if `@MainActor` file I/O turns out to stutter the UI (it should not at these data
  volumes — hundreds of KB), the change is confined to `JSONFileStore.swift`: move more work into
  the `nonisolated` encode helper. No call site changes, because `async throws` already allows the
  hop.

### 4. Design churn from having no `#Preview` — *medium likelihood, 1–2 days*

Twenty-six view tasks with no live preview canvas means a full `make app` cycle for every visual
tweak, and light/dark problems that surface only at the end.

- **Tripwire:** build `P2-80`/`P2-81` (the gallery) **before** the view stage, not after —
  reorder them ahead of `P2-38` if there is any doubt. Register each component the moment it is
  written.
- **Fallback:** accept a slightly rougher visual pass in Phase 2 and schedule the refinement into
  `P6-10`, which exists for exactly this. Do **not** let visual polish block the ten functional
  spec items.

### 5. Sheet routing across the menu bar / main window boundary — *medium likelihood, 0.5–1 day*

Finishing a session from the popover with the main window closed must open the window, bring the
app to the front, and present the review sheet. Each of `openWindow`, `NSApp.activate` and sheet
presentation has its own timing quirk, and getting it wrong loses a completed session behind a
window nobody sees.

- **Tripwire:** step 7 of § 5.3 exercises exactly this path; run it as soon as `P2-70` and `P2-74`
  exist rather than at the end.
- **Fallback:** `P2-83`'s relaunch recovery is the safety net — an unreviewed session is re-offered
  on the next launch, so the data is never lost even if the presentation is briefly wrong.

### 6. Scope creep from Phase 3 into the review sheet and Today — *medium likelihood, 1–3 days*

SPEC § 6 and § 7 describe rich screens (focused/idle time, context switches, time by category,
timeline, metrics). **None of that is computable in Phase 2** because there are no `ActivityEvent`s.
The temptation to "just add the stats grid" pulls the whole activity tracker forward.

- **Tripwire:** `P2-67`'s and `P2-78`'s acceptance criteria explicitly assert the *absence* of
  those elements ("shows no empty `Context switches: —` placeholder").
- **Fallback:** none — this is a discipline item. The phase markers in `02-architecture.md` § 3
  are the contract: `SessionStatsGrid` is `[P3]`, `TodayMetricsRow` and `DailyTimelineView` are
  `[P4]`.

### 7. `ExistentialAny` and Swift 6 strictness churn — *medium likelihood, 0.5 day*

`enableUpcomingFeature("ExistentialAny")` makes every bare protocol type a compile error, and
language mode v5 with `@MainActor` `@Observable` classes in an executable target produces isolation
diagnostics that are easy to "fix" by scattering `@preconcurrency` or `nonisolated` in the wrong
places.

- **Tripwire:** `swift build` after **every** task, per SPEC's "run the build after meaningful
  implementation steps". The § 5.1 zero-warning requirement catches accumulated papering-over.
- **Fallback:** the isolation rules in `02-architecture.md` § 6.1 are absolute — `@MainActor` for
  the whole app target, `Sendable` structs for the domain. If a fix requires `@unchecked Sendable`
  or a `DispatchQueue`, the design is wrong; § 5.1 commands 5 and 6 fail the build rather than let
  it in.

### 8. Space-to-pause fighting text input — *low likelihood, 0.5 day*

SPEC asks for Space to pause "when appropriate". Bound naively it makes the summary editor and the
outcome field unusable.

- **Tripwire:** `P2-84`'s acceptance explicitly types a space into the summary editor.
- **Fallback:** scope the shortcut to `ActiveSessionView` only and gate it on `@FocusState`; if
  that is still ambiguous, move it to ⌘P and note the deviation from the spec in `04-screens.md`.

### 9. Ad-hoc signature identity churn — *low likelihood in Phase 2, 0 days now*

Every `make-app.sh` run produces a new code identity, so macOS forgets TCC grants. Phase 2 requests
no permissions, so this costs nothing now — but it will dominate Phase 3 debugging if not set up in
advance.

- **Tripwire:** none needed in Phase 2.
- **Fallback:** create a self-signed "Lggr Dev" code-signing certificate and export
  `LGGR_SIGN_IDENTITY` before starting `P3-08`, per `02-architecture.md` § 7.7. Add the variable to
  `make-app.sh` as part of `P2-02` so it is already plumbed.

### 10. Fixture non-determinism leaking into tests — *low likelihood, 0.5 day*

`PreviewFixtures` using `Date()` or fresh `UUID()`s produces tests that pass locally and fail an
hour later or in a different time zone.

- **Tripwire:** `P2-18`'s acceptance asserts repeat-call identity; `P2-10`'s asserts zero `Date()`
  calls in the timing file.
- **Fallback:** all fixture dates come from `FixtureCalendar` with a fixed-offset calendar, and all
  fixture UUIDs are `static let` constants.

---

## 12. Open questions

Recorded rather than silently decided. None blocks Phase 2; each has a working default in place.

1. **`LggrStore` isolation (C1) is a genuine disagreement between the two binding documents, not an
   oversight.** `02-architecture.md` § 6.1 makes "actor-isolated store, all I/O off the main thread"
   one of its three named isolation domains; `03-data-model.md` § 4 makes the protocol `@MainActor`
   because SwiftData's `ModelContext` is main-actor bound. I resolved it toward `03` (it declares
   itself the signature authority) and preserved `02`'s intent with a `nonisolated` encode/write
   helper inside `JSONFileStore`. **Someone should amend one of the two documents** so the next
   reader does not rediscover this. My recommendation: amend `02-architecture.md` § 4.2 and § 6.1 to
   match `03`, since `@ModelActor` + `@MainActor` is the shape SwiftData actually forces.

2. **`SessionClock`/`SessionLifecycle` versus `FocusSession+Timing` (C3).** I dropped the two
   `Domain/` files. Two static-function façades over methods that already exist on the value type
   would be exactly the "abstraction without two implementations" that `02-architecture.md` § 8
   forbids. If a reviewer prefers the namespaced API, the change is additive and cheap — one file
   of `static func` forwarders — but it should be a deliberate decision, not drift.

3. **`Settings` as the seventh sidebar row.** SPEC § *Navigation* lists Settings in the sidebar and
   also asks for ⌘1–⌘7; `02-architecture.md` puts settings in a `Settings` scene (⌘,). I kept all
   seven rows so the ⌘-number mapping never shifts as later phases land, with ⌘7 opening the
   Settings scene rather than an in-window pane. Worth a second opinion from whoever writes
   `04-screens.md`.

4. **Un-built sidebar sections in Phase 2.** SPEC says "do not leave placeholder buttons that do
   nothing", but it also fixes the seven-section navigation. I render the four not-yet-built
   sections as honest `EmptyStateView`s naming the phase they arrive in (`P2-55`). The alternative —
   hiding rows until their phase — renumbers the ⌘-shortcuts three times over the project. I chose
   stability; the opposite choice is defensible.

5. **Test-count floor of 50 (§ 5.1 step 2).** That number is derived from the per-file minimums in
   § 5.2, which are in turn derived from the enumerated cases in `P2-26`…`P2-32`. It is a floor to
   stop a suite silently shrinking, not a target to pad toward.

6. **`LGGR_SWIFTDATA=1 swift build` cannot be verified on this machine** (§ 5.1 step 13). Phase 2's
   definition of done therefore accepts structural evidence — the conditional target exists and
   `swift build` is unaffected — and defers real verification to `P3-12` on a machine with Xcode.
   This is the one acceptance criterion in the document that is not directly executable here, and
   it is called out rather than quietly relaxed.

7. **`interruptionCount` maintenance.** `03-data-model.md` documents it as denormalised and
   maintained by `SessionManager`, recomputable from the interruption store. Phase 2 never writes
   it (interruptions are `P3-11`). Whoever does `P3-11` should decide whether to add a
   recompute-on-load reconciliation or trust the counter; a contract test either way would be
   cheap.
