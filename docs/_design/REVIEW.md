# Adversarial review of `docs/DESIGN.md`

Reviewed against `docs/_design/SPEC.md` (the contract) and `docs/_design/CONSTRAINTS.md` (the verified
environment). Findings are ordered blocker → major → minor. Compile claims marked **[verified]** were
reproduced by running `swiftc` / `swift package` on this machine.

---

## Blockers

### 1. The `LGGR_GALLERY=1` gallery `Window` cannot be declared conditionally — `SceneBuilder` has no `buildEither`/`buildOptional` **[verified]**

**Location:** § 3.7.4, § 5.1.1 ("`Window ─ PreviewGallery ─ only when LGGR_GALLERY=1`"), task **P2-52**
("the `LGGR_GALLERY=1` gallery `Window`"), task **P2-81** ("a `Window` scene present only when
`LGGR_GALLERY=1`").

**What is wrong:** `@SceneBuilder` supports only `buildBlock` overloads and `buildLimitedAvailability`.
An `if` inside `var body: some Scene` is a hard compile error. Reproduced:

```
scene.swift:5:26: error: failed to produce diagnostic for expression; please submit a bug report
 5 |     var body: some Scene {
 6 |         WindowGroup { Text("a") }
 7 |         if ProcessInfo.processInfo.environment["X"] == "1" {
```

This is not cosmetic: the gallery is the **only** light/dark verification loop on a machine without
`#Preview` (§ 3.7.4, § 5.2.9, § 2.5 "Craft"), and P2-81 is a hard dependency of the Phase-2
definition of done.

**Corrected version:** declare the scene unconditionally and gate its *content*:

```swift
// App/LggrMain.swift
Window("Lggr Gallery", id: WindowID.gallery) {
    if AppFlags.galleryEnabled {          // ProcessInfo read once, static let
        PreviewGallery().environment(AppEnvironment.fake())
    } else {
        EmptyView()
    }
}
.defaultLaunchBehavior(AppFlags.galleryEnabled ? .presented : .suppressed)  // macOS 15+
```

On macOS 14 there is no `defaultLaunchBehavior`; use `.commandsRemoved()` plus an explicit
`openWindow(id: WindowID.gallery)` fired from `AppDelegate.applicationDidFinishLaunching` when the
variable is set. Either way, **the `Window` itself is always in the scene graph.** Amend P2-52 and
P2-81 accordingly, and add an acceptance step `$ make run` → exactly one visible window.

---

### 2. `NavigationSplitView(columnVisibility: $app.columnVisibility)` does not compile — `@Environment` gives no projected value **[verified]**

**Location:** § 5.1.1 `Views/Root/RootWindow.swift` code block (`$app.columnVisibility`,
`$app.section`, `$app.detailPath`), consumed together with § 3.7.1's stated consumption pattern
`@Environment(AppEnvironment.self) private var env`.

**What is wrong:** `@Environment(AppModel.self) private var app` exposes no `$app`. Reproduced:

```
env.swift:13:47: error: cannot find '$app' in scope
env.swift:16:35: error: cannot find '$app' in scope
```

`RootWindow` is task **P2-56**, a dependency of `LggrMain` (P2-52), so Phase 2 does not build.
The same defect will recur in every view that binds to `AppModel` sheet routing (P2-50 mandates that
*all* sheet state lives on `AppModel`, so this pattern is repo-wide).

**Corrected version:**

```swift
struct RootWindow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var app = appModel          // required for $ projection on @Observable
        NavigationSplitView(columnVisibility: $app.columnVisibility) {
            Sidebar(selection: $app.section)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        } detail: {
            NavigationStack(path: $app.detailPath) { DetailContent(section: app.section) }
                .frame(minWidth: 640)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
```

Add a sentence to § 3.7.1: *"Any view that needs a `Binding` into an `@Observable` environment object
must open its body with `@Bindable var x = environmentObject`."*

---

### 3. `LggrMain` (Phase 2) references `SettingsView`, which the design marks Phase 6

**Location:** § 3.7.1 `LggrMain.swift` code block (`Settings { SettingsView().environment(env) }`);
task **P2-52** ("…and a `Settings` scene"); § 3.5 folder tree marks
`Views/Settings/SettingsView.swift` **`[P6]`**; § 5.4.7 is headed *"Settings ⌘7 (and ⌘,) (Phase 6)"*;
task **P6-05** creates it.

**What is wrong:** the Phase-2 `@main` file references a type created four phases later. `swift build`
fails at P2-52, and the Phase-2 definition of done (§ 7.4.1 command 1) cannot pass.

The same contradiction appears a second time: § 5.1.2's `SidebarSection.isAvailableInPhase2` returns
`true` for `.settings`, asserting Settings has real Phase-2 content, while § 3.5 and § 5.4.7 say it
does not.

**Corrected version:** in Phase 2 ship a two-line placeholder and grow it in P6-05:

```swift
// Views/Settings/SettingsView.swift   [P2, grows in P6-05]
struct SettingsView: View {
    var body: some View {
        EmptyStateView(symbol: Icon.privacy,
                       title: "Settings arrive in Phase 6.",
                       message: "Preferences already persist; the panes land with onboarding.")
            .frame(width: 480, height: 320)
    }
}
```

and change `isAvailableInPhase2` to `self == .today || self == .projects` (Settings is not available),
or rename it `hasPhase2Content` and keep `.settings` out of it. Add the file to § 3.5 as `[P2]`.

---

### 4. `AppEnvironment` as printed cannot compile in Phase 2 — its `init` and `.fake()` reference six types that do not exist until P3/P6

**Location:** § 3.7.1 code block; the note immediately below it ("Phase 2 constructs only `store`,
`preferences`, `clock`, `sessionManager` and `menuBar`. Phase 3+ services are **absent from the
Phase-2 type**"); task **P2-44** (Deps: P2-43, P2-25, P2-47, P2-48 — no permission/monitor task).

**What is wrong:** the printed `init` requires `any ApplicationMonitoring`, `any IdleDetecting`,
`any Notifying`, `any PermissionsProviding`, and `.fake()` defaults to `StubApplicationMonitor`,
`StubIdleDetector`, `RecordingNotifier`, `StubPermissionsService`. Every one of those is `[P3]` or
`[P6]` in § 3.5 / § 3.6. § 4 declares itself "the single source of truth… later agents copy these
declarations verbatim" — an agent that does so does not compile. Two undefined fixtures compound it:
`PreviewFixtures.demoDay` and `PreviewFixtures.appSwitches` are used here but are not in P2-18's
fixture list, and `PreviewFixtures.referenceDate` (§ 3.7.1) contradicts `FixtureCalendar.referenceDate`
(§ 3.7.5, P2-18).

**Corrected version:** print the *Phase-2* type in § 3.7.1 and move the full version to a clearly
labelled "grows to" block:

```swift
// App/AppEnvironment.swift   [P2]
@MainActor @Observable
public final class AppEnvironment {
    public let store: any LggrStore
    public let preferences: any PreferencesStoring
    public let clock: any DateProviding
    public let sessionManager: SessionManager
    public let menuBar: MenuBarManager

    public init(store: any LggrStore, preferences: any PreferencesStoring, clock: any DateProviding) {
        self.store = store
        self.preferences = preferences
        self.clock = clock
        self.sessionManager = SessionManager(store: store, clock: clock)
        self.menuBar = MenuBarManager(sessions: sessionManager, preferences: preferences)
    }

    static func live() -> AppEnvironment {
        AppEnvironment(store: StoreBootstrap.makeStore(),
                       preferences: UserDefaultsPreferencesStore(),
                       clock: SystemClock())
    }

    static func fake(store: any LggrStore = InMemoryStore(seed: PreviewFixtures.demoDay),
                     preferences: any PreferencesStoring = InMemoryPreferencesStore(),
                     clock: any DateProviding = FixedClock(FixtureCalendar.referenceDate)) -> AppEnvironment {
        AppEnvironment(store: store, preferences: preferences, clock: clock)
    }
}
```

Add to P2-18: `PreviewFixtures.demoDay: StoreSnapshot` (explicitly typed), and delete
`PreviewFixtures.referenceDate` / `PreviewFixtures.appSwitches` — `referenceDate` lives on
`FixtureCalendar` only, and `appSwitches` belongs in P3-03's fixture work.

---

### 5. The review sheet has a **Tangible result** field with nowhere to store it

**Location:** SPEC § 6 — *"Additional fields: Tangible result, Blocker, Next step."*
§ 5.5.3 wireframe and § 5.10 copy table (`Field labels | Tangible result · Blocker · Next step`,
placeholder *"What exists now that didn't before?"*), task **P2-74**.
Against § 4.2.2 `FocusSession`, whose only text fields are `resultSummary`, `blocker`, `nextStep`.

**What is wrong:** a required-by-spec, designed, copy-written, task-scheduled input field has no
persisted property. `resultSummary` cannot double for it — the same sheet shows `resultSummary` in a
separate editable `TextEditor` directly above the disclosure. Whoever implements P2-74 will either
silently drop the field (SPEC violation) or invent a property, breaking § 4's "single source of truth"
guarantee and `CodableRoundTripTests`.

**Corrected version:** add the field to § 4.2.2, before v1 ships (same argument as C23):

```swift
    /// SPEC § 6 "Tangible result". What exists now that did not before. Optional.
    public var tangibleResult: String?
```

with `tangibleResult: String? = nil` in the memberwise `init` (placed between `resultSummary` and
`blocker`), the matching `public var tangibleResult: String?` on `SDFocusSession`, one line in
`SDFocusSession+Mapping` (`toDomain` and `apply`), and the field added to P2-29's round-trip suite.

---

### 6. `loadActiveSession()` cannot find an `.awaitingReview` session, so P2-83(c) is unachievable

**Location:** § 4.4.1 — *"`loadActiveSession()` — The most recent session with `endedAt == nil`. Used
for crash / relaunch recovery."* Against task **P2-83** acceptance (c): *"finish a session, dismiss the
review with Escape, ⌘Q, relaunch → the review sheet is presented again"*, § 5.5.3 (*"A finished session
is never lost because a sheet was dismissed"*), § 5.1.3, and § 7.4.3 step 8, which is a
definition-of-done step.

**What is wrong:** an `.awaitingReview` session has `endedAt != nil` and `resultStatus == nil`, so
`loadActiveSession()` returns `nil` for it by definition. `loadSessions(in:)` is the only alternative
and is day-scoped — quit on Thursday evening and relaunch Friday and the unreviewed session is
unreachable, exactly the data-loss case R11 and § 5.5.3 promise to prevent. There is no store method
that can find it.

**Corrected version:** add a sibling method to the Phase-2 subset of `LggrStore` (§ 4.4.1) and to
P2-20's method list:

```swift
    /// The most recent session with `endedAt != nil` and `resultStatus == nil`, regardless of day.
    /// Drives the "review the session you never answered" recovery path (§ 5.5.3, P2-83c).
    func loadUnreviewedSession() async throws -> FocusSession?
```

Implement in `InMemoryStore` and `JSONFileStore` (P2-23, P2-24), add a case to P2-31's contract suite
("an unreviewed session from a previous day is returned; a reviewed one is not"), and have
`SessionManager.restoreActiveSession()` (P2-83) call both `loadActiveSession()` and
`loadUnreviewedSession()`.

---

## Major

### 7. `UserPreferences.defaultSessionDuration` — a SPEC-mandated field — is never read by anything

**Location:** SPEC § Data model lists it first in `UserPreferences`. § 4.2.2/§ 4.2.4 declare it
(default `50 * 60`). § 5.4.7 Settings → General exposes a control for it
(`Default duration ( 25m ) (•50m) ( Custom 50 ▲▼ )`).
Against § 5.5.2's defaults table and § 2.2 item 2 and task **P2-60**, which all say the duration
default is `workType.suggestedDuration`.

**What is wrong:** the preference is written but never consulted. A user who sets "Default duration:
25m" in Settings gets 50m on the next deep-work session, with no explanation. This is a dead
spec field plus a visible lie in the UI.

**Corrected version:** define the precedence explicitly in § 5.5.2's defaults table and in P2-60:

> **Duration** — on the *first* session after launch, `preferences.defaultSessionDuration`. Thereafter,
> `workType.suggestedDuration` whenever the work type changes and `durationWasEdited == false`. Setting
> a custom duration writes it back to `defaultSessionDuration` only from Settings, never from the start
> panel.

Or, if `suggestedDuration` is genuinely meant to win always, delete `defaultSessionDuration` from
§ 4.2.4 and from the Settings pane and record the SPEC deviation in Appendix A.

---

### 8. Two incompatible definitions of "reactive time" that will print different numbers for the same day

**Location:** § 4.1 `ActivityCategory.countsAsReactiveTime` (*"Contributes to 'Reactive time' on Today.
SPEC § 7"*) — true for `.communication`, `.meeting`, `.administrative`.
§ 4.2.2 `FocusSession.isReactive` + § 4.1 `WorkType.isReactiveByDefault` — true for `.incident`,
`.communication`, `.meeting`, `.administrative`. § 5.4.1 renders "reactive" from the first;
§ 5.4.4 and task **P5-03** `PlannedVsReactive` render it from the second.

**What is wrong:** Today says "1h 05m reactive" derived from *activity categories*; Weekly Review says
"38% reactive" derived from *session flags*. Nothing reconciles them, `.incident` is reactive in one
and has no category counterpart in the other, and a user comparing Monday's Today with the week's
review will see contradictory numbers. SPEC § 9 asks *"How much work was planned versus reactive?"* —
one answer, not two.

**Corrected version:** make session intent authoritative and derive both surfaces from it. In § 4.1,
delete `ActivityCategory.countsAsReactiveTime` entirely and add to § 4.7:

> **Reactive time is a property of the session, never of the activity category.** Today's "reactive"
> tile and the weekly planned-vs-reactive split both sum `effectiveDuration` over sessions where
> `isReactive == true`. Activity outside any session is `Untracked` and counts as neither. Category
> totals answer *what kind of work*, not *planned vs reactive*.

Add a `DailyDigestTests` case asserting `digest.reactive == weeklyBuilder.reactive(forDay:)` for the
same fixture day.

---

### 9. The R4 tick gate silently freezes the popover timer and contradicts P2-46's own acceptance test

**Location:** § 3.11 R4 — *"The tick is gated further: it runs only when the elapsed number is actually
visible — i.e. `showTimerInMenuBar` is on, **or** the main window is on screen and not occluded."*
Against § 5.5.1 `MenuBarActiveView` (a live `32:41 / remaining` inside the popover), § 5.6.2
(`showTimerInMenuBar == false` → *no text in any state*), and task **P2-46** acceptance: *"open the
menu bar popover and hold it open for 10 s — the time in the popover advances every second."*

**What is wrong:** with `showTimerInMenuBar = false` and the main window closed, the gate stops the
tick — but the popover still renders a timer that is supposed to be live. P2-46's acceptance test
fails under a supported preference combination. Separately, **no Phase-2 task implements the gate at
all** (P2-46/47/48 do not mention window occlusion), so R4's "measured acceptance" (0.0 energy impact)
has no artifact behind it, in violation of § 3.11's own rule that *"'Mitigation' means a specific,
already-named artifact — not a promise to be careful."*

**Corrected version:** replace the R4 bullet with a gate that is actually implementable and does not
break a visible surface:

> - The tick runs while a session is **running** (not paused, not finished) **and** at least one live
>   consumer is registered. `MenuBarManager` registers when `showTimerInMenuBar` is true **or** the
>   popover is open (`MenuBarExtra` `isPresented` binding); `ActiveSessionView` and `TodayHeader`
>   register in `.onAppear` and deregister in `.onDisappear`. `TickTimer.start`/`stop` is driven by
>   the registration count crossing zero. No window-occlusion detection — `NSWindow.occlusionState`
>   is not reliable enough to gate a clock on.

Add the consumer-registration API to task P2-46 and an acceptance line: *"with
`showTimerInMenuBar = false` and the window closed, opening the popover restarts the tick within 1 s;
closing it stops the tick."*

---

### 10. Session saves are `try?` fire-and-forget, so the save-failure alert § 5.5.3 promises can never fire

**Location:** § 3.8.6 —
`Task { try? await store.saveSession(session) }   // hops off, never blocks the frame`.
Against § 5.5.3 — *"a failed save is the one case in the app that gets an `Alert`, because the user's
typed summary is at risk… `[ Copy summary ]` `[ Try again ]`. The sheet stays open"*, § 5.3.3
(*"`StoreError.persistenceFailure` while saving is the only case that gets an `Alert`"*), and task
**P6-08** (*"with `store.json` made read-only, saving a session shows the § 5.5.3 alert… and the
session is not silently lost"*).

**What is wrong:** `try?` discards the error into a detached `Task` with no continuation back to the
sheet. The alert is unreachable, and the user's typed summary is lost silently — the exact failure the
design calls out as indefensible. It also violates CONSTRAINTS rule 4 ("Handle errors explicitly").

**Corrected version:** split the two paths in § 3.8.6 and state the rule:

```swift
/// Fire-and-forget is allowed ONLY for writes the user did not author in this interaction
/// (tick-driven updates, denormalised counters). Anything carrying user-typed text awaits.
@MainActor
func applyReview(status: SessionResultStatus, summary: String,
                 tangibleResult: String?, blocker: String?, nextStep: String?) async throws {
    guard var session = awaitingReview else { return }
    session.resultStatus = status
    session.resultSummary = summary
    session.tangibleResult = tangibleResult
    session.blocker = blocker
    session.nextStep = nextStep
    try await store.saveSession(session)     // throws → SessionReviewSheet presents the Alert
    try await store.flush()                  // the user pressed Save; do not wait 500 ms
    awaitingReview = nil
    recentlyFinished.insert(session, at: 0)
}
```

`SessionReviewSheet` calls it from a `Task` and maps a thrown `StoreError` onto the alert; the sheet
stays open and the text is preserved.

---

### 11. `Type.timerHero` uses `@ScaledMetric` as a static in an enum — it compiles but never scales **[verified]**

**Location:** § 5.2.1 — *"`Type.timerHero` | `.system(size: timerSize, weight: .medium, design:
.rounded).monospacedDigit()` | 72, `@ScaledMetric(relativeTo: .largeTitle)`"*, with
`DesignSystem/Typography.swift` holding the named roles (task **P2-34**). § 5.8.3 repeats it: *"the
hero timer — uses `@ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 72"*.

**What is wrong:** `@ScaledMetric` is a `DynamicProperty`; SwiftUI only updates it inside a `View`'s
storage. A `static` in an enum type-checks (confirmed) but is initialised once with the launch-time
trait environment and never re-evaluated. The result is silent: the app "supports Dynamic Type" in the
document and does not in the binary, and § 5.8.3's own caveat about macOS testability makes it very
unlikely anyone catches it.

**Corrected version:** `timerHero` cannot be a static token. Declare it as a view instead, and say so
in § 5.2.1:

```swift
// DesignSystem/Typography.swift
struct TimerHeroText: View {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 72
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .medium, design: .rounded).monospacedDigit())
    }
}
```

`TimerDisplay` (P2-65) uses `TimerHeroText`, and § 5.2.1's row reads *"the only role that is a view,
not a font token — see `TimerHeroText`."* Add to P2-34's acceptance:
`$ grep -c '@ScaledMetric' Sources/LggrApp/DesignSystem/Typography.swift` → `1`, inside a `View`.

---

### 12. SPEC § 3's "Time spent in potentially distracting applications" is never surfaced anywhere

**Location:** SPEC § 3 *Active focus session* — *"Show: … Current active application, Number of context
switches, **Time spent in potentially distracting applications**, Session timeline…"*.
Against § 5.4.1's live card (`Xcode · 4 switches · 1 interruption`), § 5.10's copy
(`Live activity line | Xcode · 4 switches · 1 interruption`), § 3.5's `LiveActivityStrip` [P3]
(*"current app + switch count"*), and § 5.5.3's stats line
(`52m active · 47m focused · 5m idle · 6 switches · 1 interruption`).

**What is wrong:** `ActivityCategory.distraction` and `isDistraction` exist in the model, but no
screen, no copy string and no task ever renders distraction time. A named SPEC display requirement was
dropped without being recorded in Appendix A or Appendix B.

**Corrected version:** extend the live activity line and P3-10's acceptance. § 5.10:

| Live activity line | `Xcode · 4 switches · 1 interruption` |
| Live activity line, with distraction time | `Xcode · 4 switches · 1 interruption · 6m off-task` |

using the word **off-task**, not "distracted" (§ 5.9's banned lexicon). Rendered only when
`distractionTime >= 60` seconds, in `.secondary`, never in `Palette.attention`. Add to P3-10:
*"OBSERVE: spend 3 minutes in an app classified `.distraction` during a session — the live strip shows
`3m off-task` and the review sheet's stats line includes the same figure."*

---

### 13. SPEC § 9's "Most common interruption sources" is never computed or displayed

**Location:** SPEC § 9 — *"Display: … Most common interruption sources."*
§ 4.1 `InterruptionSource` claims *"Powers 'most common interruption sources'. SPEC § 9."*
§ 5.11 Flow B claims *"it feeds 'most common interruption sources' in the weekly review."*
Against § 5.4.4's Weekly Review wireframe (no such section) and task **P5-04**, whose
`WeeklyReviewBuilder` field list is *"time by project / work type / category, sessions completed vs
interrupted, switches per day, main accomplishments, unblocking count, primary-outcome share"* — the
list does not include it, and `WeeklyReviewBuilderTests` asserts "every field".

**What is wrong:** two places in the document assert the feature exists; the builder that would compute
it and the screen that would render it both omit it. It will not be built.

**Corrected version:** add to § 5.4.4's wireframe, between *Focus* and *Accomplishments*:

```
│  Interruptions · 14                                             │
│  Chat 6 · Person 4 · Incident 2 · Meeting 1 · Other 1           │
```

add the field to P5-04's `WeeklyReviewBuilder`
(`interruptionsBySource: [InterruptionSource: Int]`, sorted descending, ties by
`InterruptionSource.allCases` order for determinism), and add a `WeeklyReviewBuilderTests` case
asserting the counts and the tie-break against a hand-computed fixture week. It must also appear in
`WeeklyReviewMarkdown` (P5-07).

---

### 14. Three SPEC § 7 Today figures are computed and then thrown away

**Location:** SPEC § 7 — *"Show: Total tracked time, Focused time, Reactive time, **Meeting time**,
**Communication time**, Number of focus sessions, Context switches, **Completed outcomes**, Current
interruption inbox."*
Against § 5.4.1's five tiles (`tracked · focused · reactive · sessions · switches`), § 5.10's metric
labels (the same five), and § 5.9's *"Hard budget: at most 5 metrics on Today"*.
Task **P4-01** computes all of them: *"tracked/focused/reactive/**meeting/communication** time, session
count, switches, **completed outcomes**, open inbox count."*

**What is wrong:** `DailyDigest` computes meeting time, communication time and completed outcomes, and
nothing renders them. The design's self-imposed 5-metric budget silently overrides three explicit SPEC
display requirements, and Appendix A/B never record the deviation.

**Corrected version:** either raise the budget or state the substitution. The cheaper fix, which keeps
the calm-layout argument intact, is to say so explicitly in § 5.4.1 under *Time allocation*:

> **Meeting time and Communication time are not tiles.** They are read off the stacked category bar
> directly beneath the tiles, which is labelled inline (`▐coding 31%▐review 22%▐comms 19%▐mtg 14%▐`)
> and shows the absolute duration in its `.help()` tooltip and in its
> `.accessibilityRepresentation`. **Completed outcomes** appears as the trailing count on the
> *Working toward* section header (`Working toward · 1 of 3 done`), [P5].

and add to § 5.9's budget row: *"5 tiles, plus the category bar and two section-header counts, which
are not tiles."* Add a `DailyDigestTests` assertion that `meeting + communication` equals the sum of
their bar segments so the numbers cannot drift.

---

### 15. `SessionManager.finish(result:summary:)` in § 3.8.6 contradicts P2-47 and destroys the `.awaitingReview` state the recovery path depends on

**Location:** § 3.8.6 code block —
`func finish(result: SessionResultStatus, summary: String)` calling
`session.finish(at: clock.now, status: result)` and `active = nil`.
Against task **P2-47**, which specifies `finish()` and a *separate*
`applyReview(status:summary:blocker:nextStep:)`; § 4.3.4 `state` (`endedAt != nil && resultStatus == nil
→ .awaitingReview`); § 5.5.3 (*"`Esc` and `Not now` do not discard the session. They leave it
`.awaitingReview`"*); § 5.6.1 (menu bar `questionmark.circle`); P2-83(c); § 7.4.3 step 8.

**What is wrong:** the printed method sets the status at finish time, so a session can never be
`.awaitingReview`, and `SessionState.awaitingReview`, the `questionmark.circle` menu bar state, the
`[ Review ]` buttons and step 8 of the definition-of-done walkthrough all become unreachable. It also
never populates `awaitingReview`, which P2-47 declares as a stored property.

**Corrected version:** replace the § 3.8.6 block with the two-step form:

```swift
@MainActor
func finish() {
    guard var session = active else { return }
    session.finish(at: clock.now)          // no status — enters .awaitingReview
    active = nil
    awaitingReview = session
    tickTimer.stop()
    Task { try? await store.saveSession(session) }   // no user text at risk yet
}
```

and keep the corrected `applyReview` from finding 10 as the only place `resultStatus` is written. Note
in § 3.8.6 that this is the *one* fire-and-forget write in the finish path, and why.

---

### 16. `UserPreferences.id` emits a compiler warning, and § 7.4.1 requires zero warnings **[verified]**

**Location:** § 4.2.4 — `public let id: UUID = UserPreferences.singletonID`, with the note *"`id` is
declared `public let id: UUID = ...` with an initial value, so it is not part of the memberwise init
and `Codable` will ignore any decoded value for it. That is intended."*
Against § 7.4.1 command 1: *"Ends with `Build complete!`; exit `0`; **zero warnings** in the `LggrKit`
and `LggrApp` compile lines."*

**What is wrong:** reproduced verbatim on this toolchain:

```
prefs.swift:3:16: warning: immutable property will not be decoded because it is declared with an
initial value which cannot be overwritten
```

The behaviour is intended, but the design's own definition-of-done gate fails on its own declaration.
An agent will "fix" the warning by making `id` a `var`, which breaks P2-30's assertion that `id`
always equals `singletonID`.

**Corrected version:** silence it the way the compiler's own note suggests, and say so in § 4.2.4:

```swift
public struct UserPreferences: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID = UserPreferences.singletonID
    public static let singletonID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")
        ?? UUID()

    /// `id` is deliberately omitted: preferences are a singleton, so the identifier is a constant
    /// and any decoded value for it must be ignored. Asserted by `UserPreferencesTests`.
    private enum CodingKeys: String, CodingKey {
        case defaultSessionDuration, globalShortcut, trackWindowTitles, trackBrowserDomains,
             browserAutomation, idleThreshold, excludedApplications, privateApplications,
             dataRetentionDays, trackingPaused, lastPruneAt, launchAtLogin, showTimerInMenuBar,
             hideDockIcon, notifyOnSessionCompleted, notifyAtHalfway, notifyOnLongIdle,
             didRequestAccessibilityPrompt, didRequestNotificationAuthorization,
             didDismissAccessibilityBanner, didDismissAutomationBanner,
             lastSelectedProjectID, hasCompletedOnboarding
    }
}
```

Note that this **re-introduces the migration hazard C23 claimed to avoid**: with an explicit
`CodingKeys`, adding a field after v1 needs `decodeIfPresent` or a `v2` key bump. Add that sentence to
§ 4.4.2's forward warning.

---

### 17. Contextual ⌘N (New Project on the Projects screen) contradicts SPEC's flat keyboard map

**Location:** SPEC § Keyboard experience — *"Command + N: New focus session"*, stated without
qualification.
Against § 5.7.1 (*"⌘N | File → New Focus Session | … **In Projects, ⌘N is New Project.**"*),
§ 5.4.5 (*"Primary action: New Project ⌘N (when Projects is the selected section); ⌘⇧N anywhere"*),
§ 5.10's Projects empty state (`[ New Project ⌘N ]`), and task **P2-53**, which registers ⌘N as
*New Focus Session* and ⌘⇧N as *New Project* with **no** context switching.

**What is wrong:** three-way disagreement — SPEC says ⌘N is always New Focus Session, § 5.4.5/§ 5.7.1
say it retargets on one screen, and P2-53 (the thing that gets built) says it never retargets. A
retargeting ⌘N also breaks § 5.11 Flow A, whose five-second budget assumes ⌘N always starts a session,
and § 7.4.3 step 3 runs ⌘N *immediately after* ⌘5 selects Projects — which under § 5.4.5's rule would
open the project editor, not the start panel.

**Corrected version:** follow SPEC. In § 5.7.1 delete the sentence "In Projects, ⌘N is New Project." In
§ 5.4.5 change the primary action to *"**New Project** ⌘⇧N"* and § 5.10's Projects empty state button
to `[ New Project  ⌘⇧N ]`. Record it in Appendix A as a new row:

> **C25** — ⌘N retargeting. `04` retargeted ⌘N on the Projects screen; `SPEC.md` § Keyboard experience
> states ⌘N unconditionally. **SPEC wins.** ⌘N is always New Focus Session; New Project is ⌘⇧N
> everywhere. § 7.4.3 step 3's timing measurement depends on this.

Also fix § 7.4.3 step 2 to name ⌘⇧N explicitly instead of "the New Project action".

---

### 18. The DST test cannot detect a DST bug — the fixture calendar is fixed-offset

**Location:** Task **P2-14** acceptance — *"for 2026-03-08 14:30 local, `.day` starts at 00:00:00 and
has `duration == 86_400` **under a fixed-offset calendar**"*.
Against § 3.11 R8 — *"A DST day is 23 or 25 hours long and the daily timeline must lay blocks out on
the real interval length. … `FixtureCalendar` includes a DST-transition date **so the suite actually
exercises this**"*, and task **P2-18** (*"a fixed-offset calendar, **including a DST-transition
date**"*).

**What is wrong:** 2026-03-08 is the US spring-forward date, but a fixed-offset calendar has no DST, so
the day is 86,400 s and the assertion passes for both a correct `Calendar.dateInterval(of:for:)`
implementation and a naïve `date + 86_400`. The test is a tautology. R8's mitigation has no artifact
behind it, and the daily timeline's block layout — the thing that actually breaks — is untested.

**Corrected version:** use a real DST zone for the boundary tests. Amend P2-14:

> TEST `dstSpringForwardDayIs23Hours` in `SupportTests.swift`: with
> `Calendar(identifier: .gregorian)` whose `timeZone == TimeZone(identifier: "America/Los_Angeles")`,
> `DateInterval.day(containing: 2026-03-08 14:30 PDT).duration == 82_800`; and
> `dstFallBackDayIs25Hours`: 2026-11-01 → `90_000`.
> TEST `dayWindowCoversMidnightToMidnight` keeps the fixed-offset calendar and asserts `86_400` — the
> two tests together are what make the helper trustworthy.

`FixtureCalendar` needs two calendars: `fixed` (deterministic, default) and `dstZone` (for these two
tests only). Note it in P2-18.

---

### 19. `Increase contrast` cannot be implemented with the single colour helper the design mandates

**Location:** § 5.2.7 — *"Under **Increase contrast** … `Stroke.card` opacity goes 0.07 → 0.22 (light)
and 0.10 → 0.28 (dark); `Surface.hover` goes 0.06 → 0.12; the timeline's idle blocks go from 40% to 65%
opacity."*
Against § 5.2.0/§ 5.2.4, where `Stroke.card` and `Surface.hover` are `static let` constants and the
only adaptive mechanism is
`NSColor.lggrDynamic(light:dark:)` = `NSColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }`.
Task **P6-10** and § 2.5 ("Craft") both assert the pass happens.

**What is wrong:** `bestMatch(from: [.aqua, .darkAqua])` deliberately collapses
`accessibilityHighContrastAqua` / `accessibilityHighContrastDarkAqua` down to `.aqua`/`.darkAqua`,
discarding exactly the signal the step-ups need. A `static let Color` also cannot observe
`@Environment(\.colorSchemeContrast)`. As written the increase-contrast behaviour is unimplementable.

**Corrected version:** widen the helper to four appearances and keep the call sites unchanged:

```swift
extension NSColor {
    static func lggrDynamic(light: NSColor, dark: NSColor,
                            lightHC: NSColor? = nil, darkHC: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua,
                                               .accessibilityHighContrastAqua,
                                               .accessibilityHighContrastDarkAqua]) {
            case .some(.accessibilityHighContrastAqua):     return lightHC ?? light
            case .some(.accessibilityHighContrastDarkAqua): return darkHC ?? dark
            case .some(.darkAqua):                          return dark
            default:                                        return light
            }
        }
    }
}

public enum Stroke {
    public static let card = Color(nsColor: .lggrDynamic(
        light:   NSColor(white: 0.0, alpha: 0.07),
        dark:    NSColor(white: 1.0, alpha: 0.10),
        lightHC: NSColor(white: 0.0, alpha: 0.22),
        darkHC:  NSColor(white: 1.0, alpha: 0.28)))
}
```

`Surface.hover` follows the same shape. The timeline's idle-block opacity is a *view* concern — read
`@Environment(\.colorSchemeContrast)` in `TimelineBlockView` (P4-02), not in `Palette`. Correct § 5.2.7
to say so, and correct § 5.2.9's claim that there are "only two hand-made colours, deliberately" — they
now carry four values each.

---

### 20. Phase 2 carries at least seven work items that SPEC's ten Phase-2 items do not ask for

**Location:** § 2.2 (14 numbered "IN" items), § 7.3 (86 tasks), against SPEC § Implementation order
Phase 2: *create a project · start a focus session · timer in the main window · timer in the menu bar ·
pause and resume · finish the session · select the result status · save the session using SwiftData ·
show the completed session in Today · add an accomplishment from the completed session.*

**What is wrong:** each of the following is scheduled into the phase SPEC says *"must compile and work
before continuing"*, and none is required by the ten items:

| Crept-in item | Where | SPEC's actual home |
|---|---|---|
| **`SessionSummaryBuilder` + `SummaryEditor` + ⌘R regenerate** (§ 2.2 item 8, P2-17, P2-28, P2-73) | Phase 2 | SPEC § 6, no phase; C21 keeps it in P2 without arguing against the ten items |
| **Tangible result / Blocker / Next step disclosure** (P2-74) | Phase 2 | SPEC § 6 |
| **The keyboard spine** ⌘1–⌘7, full tab order, mouse-free walkthrough (§ 2.2 item 12, P2-53, P2-84) | Phase 2 | SPEC Phase **6** item 9 ("Keyboard navigation") |
| **Light and dark mode + designed empty states for every screen** (§ 2.2 item 14, P2-40, P2-80/81, § 7.4.3's two appearance checks) | Phase 2 | SPEC Phase **6** items 6 and 10 |
| **Project edit / deactivate / delete + delete-confirmation copy** (§ 2.2 item 1, P2-59) | Phase 2 | SPEC item 1 is "Create a project" |
| **Six-row menu bar idle popover incl. Quick Timer and Open Today** (P2-69) | Phase 2 | SPEC § 1; Phase 2 item 4 is only "Display the timer in the menu bar" |
| **`_XcodeOnly/Previews.swift` with ≥ 12 `#Preview` macros** (P2-82) | Phase 2 | CONSTRAINTS asks for *"a documented Xcode-only file"*, singular; 12+ macros that **cannot be compiled, run or verified on this machine** are unverifiable dead weight in the phase that must compile and work |

**Corrected version:** § 2.2 should distinguish *"required by SPEC's ten items"* from *"carried into
Phase 2 deliberately, with a reason"*. Concretely:

- Keep in Phase 2, with the reason stated inline: `SessionSummaryBuilder` (the review sheet needs
  *something* in the editor; C21 already argues the reduced form), project delete (needed to test
  `.nullify` equivalence in `LggrStoreContractTests`), the gallery (it is the only light/dark loop
  CONSTRAINTS leaves us).
- **Move to Phase 6:** the full keyboard pass P2-84 and the "every screen has a designed empty state"
  bar in § 2.2 item 14 — Phase 2 needs ⌘N, ⌘⏎, Esc and Space (the flows in the ten items) and one
  empty state per Phase-2 screen, not a mouse-free audit of all twelve flows.
- **Cut P2-82 to a single `#Preview`** over `CompletedSessionRow`, as a documented smoke test of the
  `exclude:` mechanism, and move the remaining registrations to P6-10 where a machine with Xcode can
  actually run them. Change P2-82's acceptance from `grep -c '#Preview' … → ≥ 12` to `== 1`.
- Add a line to § 2.2: *"Anything in this list not traceable to one of SPEC's ten Phase-2 items is
  named here with its justification; nothing else may be added to the phase."*

---

## Minor

### 21. Six referenced types have no declaration and no file

**Location:** `WindowID` (§ 3.7.1, § 5.1.1, § 5.1.3 ×2, P2-52), `MenuBarLabelState` (§ 5.6 code block,
P2-48), `AppSheet` (P2-50), `DetailContent` (§ 5.1.1), `PermissionBanner.swift` (P6-02's Files column),
`ModelLookup` (§ 4.6, used by all seven mapping files).

**What is wrong:** § 4 claims to be *"the single source of truth for every type name, field name and
signature"*, and § 3.5 claims to be the *"complete folder structure"*. None of these six appears in
either. `MenuBarLabelState` in particular is the interface between P2-48 and P2-68 and its shape is
only implied (`symbolName`, `timeText`, `isPaused`, `spokenValue`).

**Corrected version:** add to § 3.5 —
`App/WindowID.swift [P2]`, `State/AppSheet.swift [P2]`, `Views/Root/DetailContent.swift [P2]`,
`Services/MenuBarLabelState.swift [P2]`, `Components/PermissionBanner.swift [P6]`,
`LggrPersistence/Mapping/ModelLookup.swift` — and declare the two load-bearing ones in § 4:

```swift
public enum WindowID {
    public static let main = "lggr.main"
    public static let gallery = "lggr.gallery"
}

public struct MenuBarLabelState: Equatable, Sendable {
    public let symbolName: String        // SessionState.symbolName
    public let timeText: String?         // nil when showTimerInMenuBar == false or idle
    public let isPaused: Bool
    public let isOvertime: Bool          // drives Palette.attention on the digits
    public let spokenValue: String       // § 5.6.4
}

enum AppSheet: Identifiable, Hashable {
    case startSession, review(FocusSession), addAccomplishment(FocusSession?), editProject(Project?)
    var id: String { … }                 // Identifiable is required by .sheet(item:)
}
```

---

### 22. `SidebarSection` is persisted to `UserDefaults` with implicit raw values, violating § 4.1's own rule

**Location:** § 5.1.2 — `public enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
case today, sessions, accomplishments, weeklyReview, projects, rules, settings }`, persisted per
§ 5.1.1 (*"Sidebar selection persists in `UserDefaults` under `com.lggr.sidebar.section`"*).
Against § 4.1: *"All enums are `String`-backed with **explicit** raw values so that a Swift-level rename
can never silently invalidate persisted JSON."*

**Corrected version:**

```swift
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case today = "today"
    case sessions = "sessions"
    case accomplishments = "accomplishments"
    case weeklyReview = "weeklyReview"
    case projects = "projects"
    case rules = "rules"
    case settings = "settings"
```

and add `SidebarSection` to P2-29's raw-value assertions (raising the count from 28 to 35).

---

### 23. Today's accomplishment ordering is specified twice, oppositely

**Location:** § 5.4.1 — *"**Accomplishments** — today's rows, **newest last** so the day reads top to
bottom."* Against task **P2-75** — *"`TodayModel` … exposes them **newest-first**."*

**Corrected version:** § 5.4.1's argument is the better one (the day reads chronologically, and the
wireframe shows `11:04` above `14:20`). Change P2-75 to *"exposes today's sessions newest-first and
today's accomplishments **oldest-first**, so the day reads top to bottom"* and add the ordering to
P2-78's acceptance.

---

### 24. A running session contributes `0` to every Today total, and nothing says so

**Location:** § 4.3.4 — *"`effectiveDuration` — Active duration of a **finished** session. Returns 0
while the session is still running"*; § 4.7 — *"Never call `elapsed(at: Date())` inside an aggregate —
use `effectiveDuration`"*. Against § 5.4.1's `5h 12m tracked` tile and § 5.10's popover footer
`Today · 3h 40m focused · 2 sessions`.

**What is wrong:** while a 50-minute session runs, Today's "tracked" and the popover's footer exclude
it entirely, then jump by 50 minutes the instant Finish is pressed. That is defensible (aggregates stay
deterministic) but it is surprising, it is never stated, and P4-01's `DailyDigestTests` will be written
against whichever behaviour the author assumed.

**Corrected version:** add to § 4.3.4's doc comment and to § 5.4.1:

> **Daily and weekly totals count finished sessions only.** A session in flight is represented by the
> live card at the top of Today, not by the tiles beneath it; the tiles' caption reads
> *"so far today"* and the in-flight session joins them when it is finished. This keeps every aggregate
> a pure function of stored `Date`s with no dependence on `now`.

Add a `DailyDigestTests` case: *"a running session contributes zero to `tracked`."*

---

### 25. `BrowserDomainReader` is an `actor` with per-browser cached state but is called statically

**Location:** § 6.7.4 capture pipeline step 5 —
`sample.domain = await BrowserDomainReader.host(for: bundleID)`.
Against § 3.8.1 / § 6.1.2, which declare it `public actor BrowserDomainReader` that *"owns one cached
compiled `NSAppleScript` per browser, serialises calls"* — i.e. instance state.

**Corrected version:** the pipeline must hold the instance. In § 6.7.4 step 5:

```
→ if trackBrowserDomains && isBrowser && automation(for: bundleID) == .granted
      sample.domain = await browserReader.host(for: bundleID)   // instance owned by
                                                                // ActivityTrackingService
```

and add `browserReader: BrowserDomainReader` to `ActivityTrackingService`'s stored properties in
§ 3.6 / P3-05.

---

### 26. The review sheet drops SPEC § 6's "Time by category"

**Location:** SPEC § 6 — *"Display: Total duration, Focused time, Idle time, Number of context
switches, Main applications used, **Time by category**, Interruption count."*
§ 3.5 lists `SessionStatsGrid.swift [P3]` as *"focused/idle/switches/categories"*, but § 5.5.3's
wireframe shows only two lines (stats, then applications) and § 5.10's copy table has no category row.

**Corrected version:** add a third line to § 5.5.3's wireframe and to § 5.10:

```
│  52m active · 47m focused · 5m idle · 6 switches · 1 int.  │
│  Xcode 31m · Terminal 9m · Slack 7m · GitHub 5m            │
│  Coding 40m · Code review 5m · Communication 7m            │
```

| Category line | `Coding 40m · Code review 5m · Communication 7m` |
| Category line, no data | *(row absent)* |

and name it in P3-10's acceptance.

---

### 27. Onboarding auto-creates a "General" project, contradicting "projects are optional"

**Location:** § 6.5 Screen 6 — *"**Secondary:** `Skip` — creates a project named **General**, so the
user is never dropped into an app with an empty required picker."*
Against § 5.5.2 (*"Starting with no project is fully supported and is not flagged"*), § 5.10's Projects
empty state (*"Projects are optional — you can start a session without one"*), and § 4.2.2 where
`projectID` is `UUID?`.

**Corrected version:** `Skip` should skip. Change Screen 6's secondary action to:

> **Secondary:** `Skip` — advances without creating anything. The start panel's project menu reads
> *No project* and offers *New Project…*; `FocusSession.projectID` stays `nil`. Creating a project the
> user declined to name is a silent claim about their work.

---

### 28. Overengineering: four abstractions the spec did not ask for and that earn nothing

**Location and correction:**

a. **Runtime Dock-icon hiding** — § 3.9.6, § 5.1.3, `UserPreferences.hideDockIcon`, task **P6-07**
(`NSApp.setActivationPolicy(.accessory)` at runtime, with the popover *growing* `Preferences…` and
`Quit Lggr` rows and *"the keyboard map degrades to popover-scoped shortcuts"*). SPEC asks for "menu
bar support", not two activation policies. This buys one preference at the cost of a second, degraded
keyboard map that must be designed, built and tested. **Cut P6-07 and `hideDockIcon`;** record in
Appendix B as a post-MVP item with the trigger *"a user asks for it."*

b. **The 250 ms redacted-placeholder loading policy** — § 5.3.2 steps 2–3, mandated for *every*
section of *every* screen, over a local JSON file the same section calls *"measured in milliseconds"*.
Building fixture-shaped placeholder content for each section, plus a 250 ms timer, plus a third
`ProgressView` state, is three states where one suffices. **Replace § 5.3.2 with:** *"Chrome renders
immediately. Sections render their empty state until data lands. There is no spinner, no skeleton and
no placeholder anywhere in Lggr; if a read ever exceeds 250 ms that is a bug in the store, not a case
for a loading state."* Keep the `ProgressView` exception for Weekly Review aggregation only (§ 5.4.4
already argues it).

c. **`UserPreferences.browserAutomation: [String: Bool]`** — § 4.2.4. `PermissionsProviding`
(§ 6.4) already exposes `automation(forBundleIdentifier:) -> PermissionStatus` non-prompting, and TCC
is the authority. A shadow copy in `UserDefaults` can only go stale (the user revokes in System
Settings; the dictionary still says `true`). **Cut the field.** The one thing it uniquely carries —
"the user said no, never re-ask" — is already covered by `didDismissAutomationBanner` plus § 6.6 rule 3
("Automation is once **per browser**"), which needs a `Set<String>` of *asked* bundle IDs, not a
`Bool` of *granted*. Replace with `public var didRequestAutomationFor: [String]`.

d. **`MenuBarManager` as a separate `@Observable` service** — § 3.6, P2-48. Its entire job is to turn
`SessionManager` state plus one preference into a `MenuBarLabelState`. That is a pure function.
§ 3.10 already forbids "a static-function façade over methods that already exist on a value type";
this is the same shape with a class around it. **Make it a `Sendable` struct in `LggrKit`** —
`MenuBarLabelState.make(session:preferences:now:)` — which also makes § 5.6.2's format table
unit-testable (it currently has no test in § 7.9) and removes a stored property from `AppEnvironment`.
Add `MenuBarLabelStateTests` to P2-48 covering all six rows of § 5.6.1.

---

### 29. `JSONFileStore` re-encodes the entire snapshot every 500 ms during tracking

**Location:** § 4.4.1 (*"every `save…` mutates it, marks it dirty and schedules a coalesced flush 500 ms
later"*), § 3.10 (*"`JSONFileStore` holds the whole snapshot in memory"*), § 3.11 R10 (*"potentially a
hundred thousand activity events"* in one file, trigger to change at ~10 MB).
Against § 2.5's cost target *"Active CPU | 10-minute average with a session running and tracking on |
**< 0.5%**"*.

**What is wrong:** during Phase-3 tracking, `saveActivityEvents` fires on every application switch, so
a 10 MB `JSONEncoder` pass plus a 10 MB atomic write happens at up to 2 Hz. At the stated volume that
alone will exceed the CPU budget, and R10's trigger (10 MB *file size*) does not fire on it — the
problem is write *frequency* against a whole-file encoder, not size.

**Corrected version:** add to § 4.4.1's `JSONFileStore` row and to R10's mitigation:

> The flush debounce is **500 ms for user-authored writes** (project, session, accomplishment,
> interruption) and **30 s, or 200 buffered events, whichever comes first, for `saveActivityEvents`**,
> plus an unconditional flush on `applicationWillTerminate`, on `willSleepNotification`, and on session
> finish. Activity is buffered in memory and is recoverable from the open `ActivitySample` on relaunch;
> user-authored records are never delayed more than 500 ms.

Add to R10's trigger list: *"or the measured encode time for one flush exceeds 50 ms."*

---

### 30. SPEC Phase-2 item 8 ("Save the session using **SwiftData**") is silently reworded

**Location:** § 7.4.3 step 10 maps the walkthrough to *"**8. Persist the session**"*; § 2.2 item 9 is
*"**Persist it** — `JSONFileStore`…"*. SPEC's text is *"Save the session using SwiftData."*

**What is wrong:** CONSTRAINTS.md makes this unavoidable and the substitution is the right call — but
it is the one SPEC requirement the design *cannot* meet, and it is the only one paraphrased away rather
than recorded. Appendix A has 24 rows and none of them is this; Appendix B item 1 covers the *build
verification* gap, not the requirement gap.

**Corrected version:** add an Appendix A row:

> **C25** — SPEC Phase 2 item 8 says "Save the session using SwiftData". `CONSTRAINTS.md` proves
> `@Model` cannot compile on this machine. **CONSTRAINTS wins.** Phase 2 satisfies "persist the
> session" with `JSONFileStore`, which is genuinely durable; `SwiftDataStore` lands in `P3-12` behind
> `LGGR_SWIFTDATA=1` and is proven equivalent by `LggrStoreContractTests`. The deviation is from the
> *mechanism*, not the requirement.

and change § 7.4.3 step 10's SPEC-item column to read *"8. Persist the session (SwiftData deferred —
Appendix A C25)"* so the substitution is visible at the point of acceptance.

---

### 31. A `kill -9` within 500 ms of session start loses the session, contradicting R11

**Location:** § 3.11 R11 — *"The session is written to the store at `start`, not at `finish`, **so it
exists on disk from second one**"*; § 2.5 — *"Crash durability | `kill -9` mid-session, relaunch |
**Session restored**"*.
Against § 4.4.1 / § 3.8.6, where every `save…` only marks the snapshot dirty and schedules a flush
500 ms later.

**Corrected version:** make session *start* the one write that does not wait. In P2-47:

> `start(…)` writes the session and then **awaits `store.flush()`** before returning, off the main
> actor via the `nonisolated` encode helper. This is the only `save…` call site that forces an
> immediate flush; it costs one small write on a path the user has just committed to, and it is what
> makes R11's "on disk from second one" literally true.

Add to P2-32's durability suite: *"`saveSession` followed by an immediate second `JSONFileStore` over
the same directory, with no `flush()` call in between, finds the session"* — with `start`'s forced
flush this passes; without it, it does not.

---

### 32. The weekly "Time allocation" list mixes projects and work types with no stated rule

**Location:** § 5.4.4's *Where the time went* (`SOR engineering 31% · Code review 22% · Comms 19% ·
Incidents 14% · Planning 9% · Other 5%`), reproducing SPEC § Export's example verbatim. Against
task **P5-04**, whose `WeeklyReviewBuilder` computes *"time by project / work type / category"* as
three separate dimensions, and **P5-07**, which must render *"`SPEC.md`'s example structure"*.

**What is wrong:** "SOR engineering" and "Incidents" are projects; "Code review", "Communication" and
"Planning" are work types (or categories). Whoever writes `WeeklyReviewMarkdown` has to pick, and the
byte-exact test in P5-07 will lock in whatever they pick.

**Corrected version:** state the rule in § 5.4.4 and § 5.11 Flow D:

> **"Where the time went" is time by project**, largest first, with sessions that have no project
> collected into `No project`. SPEC's example reads as a mix because the author's projects happened to
> be named after work types; it is not a mixed dimension. Time by work type and time by category are
> separate, collapsed sections below it, each with the same bar-plus-legend treatment.

and split P5-07's expected document into three headed lists so the byte-exact assertion is
unambiguous.

---

### 33. `check-layering.sh` is asked to detect something grep cannot see

**Location:** § 3.4 — *"**[P6]** a system permission prompt is fired outside the three sanctioned call
sites (§ 6.6)"*; § 6.6 rule 2 — *"Exactly three call sites exist in the app, and
`Scripts/check-layering.sh` **greps for them**"*; task **P6-02** acceptance — *"`check-layering.sh`
finds no prompt call outside the three sites."*

**What is wrong:** a shell grep cannot tell a *call site* from a *definition* or a *comment*, and it
cannot see through `permissions.requestAccessibility()` being invoked from a closure stored elsewhere.
As specified the check is either trivially bypassed or noisy, and P6-02's acceptance depends on it.

**Corrected version:** make it a lexical check on a marker that is cheap to enforce and cheap to grep:

> Every sanctioned prompt call site is preceded by the exact comment line
> `// SANCTIONED-PROMPT: <onboarding|settings|banner>`. `check-layering.sh` fails if
> `requestAccessibility(|requestNotifications(|requestAutomation(` appears in `Sources/LggrApp`
> **without** that marker on the preceding line, or if the marker appears more than three times in
> total, or outside `Views/Onboarding/`, `Views/Settings/` and `Components/PermissionBanner.swift`.

That is greppable, self-documenting at the call site, and fails closed.
