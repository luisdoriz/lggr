# Lggr — Product Definition, MVP Boundary, Risks and User Flows

> Deliverable 1 of the Phase 1 design set (SPEC § *Implementation order → Phase 1*, items 1, 2, 3, 7).
> Read `CONSTRAINTS.md` first. `02-architecture.md` and `03-data-model.md` are binding; where this
> document names a type, a file or a signature it uses theirs verbatim. Divergences I found between
> those two documents are recorded in § 8, not silently resolved.

---

## 1. The product in one paragraph

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

**The distinctive idea, said plainly:** most time trackers record only reality (a wall of app usage),
and most task managers record only intent (a list of things you told yourself to do). Lggr's unit of
value is the **gap between the two, plus the evidence** — and it treats that gap as information, not
as failure. A session that ended `.blocked` is as useful a record as one that ended `.completed`, and
the app never renders either one in red.

---

## 2. Positioning

### 2.1 Who it is for

| Audience | The specific pain Lggr removes |
|---|---|
| **Engineering managers** | Most of the job leaves no artifact. Reviewing three PRs, unblocking two engineers, killing a bad plan in a 20-minute call, and absorbing an incident produces zero commits. At review time, or in a 1:1 with your own manager, you have nothing to point at and you feel like you did nothing. Lggr makes the invisible work — code review, unblocking, decisions, deprioritisation — a first-class, countable `AccomplishmentType`. |
| **Developers** | You know you had a bad week but not *why*. Was it meetings? Was it fifteen small context switches an hour? Was it that the deep work only ever happened after 4 pm? Lggr answers with your own data: context switches per day, time by category, when your longest uninterrupted stretches actually occurred. |
| **Knowledge workers generally** | You start the day with a clear intent and end it unable to account for six of the eight hours. Lggr does not ask you to remember; it asks you to state intent once, and it reconstructs the rest. |

### 2.2 The wedge

The narrowest, sharpest version: **a senior IC or first-line engineering manager who, on Friday
afternoon, has to write down what they accomplished this week and cannot.** Everything else in the
product exists to make that Friday moment take two minutes and be honest.

### 2.3 What Lggr is explicitly NOT

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

---

## 3. MVP boundary

Two framings, because they answer different questions.

**The current build** is Phase 2 — the smallest polished vertical slice that must compile, run and
persist before anything else is written (SPEC § *Implementation order*: *"This phase must compile and
work before continuing"*). **The MVP** is Phases 2 through 6. Everything past Phase 6 is not in the
MVP at all.

### 3.1 IN — the current build (Phase 2 vertical slice)

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
6. **Finish the session** — `finish(at:)`, closing any open pause first.
7. **Choose a result status** — `SessionReviewSheet` + `ResultStatusPicker`, all five
   `SessionResultStatus` cases; required.
8. **A deterministic suggested summary, editable** — `SessionSummaryBuilder` (Phase-2 form: intent,
   project, duration, result) rendered in `SummaryEditor`. Optional `blocker` and `nextStep` behind
   a disclosure.
9. **Persist it** — `JSONFileStore` at `~/Library/Application Support/Lggr/`, atomic writes,
   crash-and-relaunch recovery of an in-flight session via `loadActiveSession()`.
   `UserPreferences` in `UserDefaults` via `UserDefaultsPreferencesStore`.
10. **See it in Today** — `TodayView` with `TodayHeader` (current or next session) and a list of
    `CompletedSessionRow`s for the day.
11. **Log an accomplishment from a finished session** — `AddAccomplishmentSheet`, all eleven
    `AccomplishmentType` cases, pre-filled from the session, linked by `focusSessionID`.
12. **The keyboard spine** — ⌘N new session, ⌘↩ start/confirm, Space pause/resume, Esc dismiss,
    ⌘1–⌘7 sidebar navigation, full tab order. Every Phase-2 flow completable without a mouse.
13. **The infrastructure that makes the above true** — `Package.swift` with the conditional
    `LggrPersistence` target, `Scripts/make-app.sh` (bundle + ad-hoc codesign),
    `Scripts/check-layering.sh`, `Scripts/run.sh`, the `LGGR_GALLERY=1` light/dark preview gallery,
    `PreviewFixtures`, and the Phase-2 test files listed in `02-architecture.md` § 3.
14. **Light and dark mode, and empty states, for every Phase-2 screen.** A screen without a designed
    empty state is not done.

### 3.2 OUT of the current build — returns inside the MVP

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
| Markdown export (daily, accomplishments), `ExportService` | **Phase 4** | |
| Weekly outcomes, `WeeklyOutcome`, planned-vs-reactive, weekly review, insights, charts, CSV export | **Phase 5** | The largest surface; needs weeks of real data to tune. |
| Onboarding, permissions flow, global shortcut (⌘⇧Space), notifications, Settings window, launch at login, accessibility polish, app icon | **Phase 6** | Polish over a working core, per SPEC principle 12. |

### 3.3 OUT of the MVP entirely

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
  verifiable product claim (§ 5.7) and we are not trading it away.
- **iOS / iPadOS / watchOS / visionOS targets** — post-MVP.
- **Localisation pipeline** — post-MVP. English strings inline; no `.xcstrings` catalogue.
- **Screenshots, keystroke logging, clipboard capture, document contents, message contents** —
  **never, in any phase.** This is a product boundary, not a scheduling one.
- **Streaks, scores, badges, gamification, shaming** — never.
- **Mac App Store distribution** — post-MVP and probably never, because it is incompatible with the
  Accessibility-based title capture that makes the product work (§ 4.2).
- **Data migration framework, encryption at rest, caching layer** — post-MVP; see `02-architecture.md`
  § 8 and risk R7 below.

---

## 4. Technical risks

Likelihood and impact are stated for the MVP as a whole. "Mitigation" means a specific, already-named
artifact — not a promise to be careful.

### R1 — No Xcode on the build machine; SwiftData macros cannot compile

**Likelihood: certain (already happened).** **Impact: high** — the spec mandates SwiftData; a naïve
implementation does not compile a single file.

**Mitigation.** The three-target split in `CONSTRAINTS.md` and `02-architecture.md`: `LggrKit` is
Foundation-only and holds ~70% of the code and 100% of the logic; `LggrPersistence` is added to
`Package.swift` only under `LGGR_SWIFTDATA=1`; `LggrApp` touches it through exactly one file,
`App/StoreBootstrap.swift`. `JSONFileStore` is the shipping backend today and is genuinely durable,
so the vertical slice is real, not a stub. `Scripts/check-layering.sh` fails the build if `@Model`,
`#Predicate` or `#Preview` appears outside `Sources/LggrPersistence/` or the excluded `_XcodeOnly/`.
`LggrStoreContractTests` runs the identical suite against `InMemoryStore`, `JSONFileStore` and — when
Xcode exists — `SwiftDataStore`, so the swap is proven rather than hoped for. `#Preview` is replaced
by the `LGGR_GALLERY=1` window, which is a real running app, not a screenshot harness.

**Residual risk:** `LggrPersistence` is written but never compiled on this machine. It will not build
first try on a machine with Xcode. That is accepted and budgeted; it is a thin mapping layer with no
logic, and the contract tests define exactly what "correct" means for it.

### R2 — App Sandbox versus Accessibility permission

**Likelihood: certain.** **Impact: high** — window titles are the difference between "you used Chrome
for 42 minutes" and "you reviewed three PRs". Without them the product is a worse Toggl.

**The conflict, precisely.** A sandboxed app *can* appear in the Accessibility list and
`AXIsProcessTrusted()` *can* return true. What fails is the thing we need it for: reading another
application's focused window title requires `AXUIElementCreateApplication(pid)` plus
`AXUIElementCopyAttributeValue(…, kAXFocusedWindowAttribute, …)`, and those calls are denied under App
Sandbox for processes outside the container. Browser domain capture is worse — Apple Events to
Safari/Chrome require per-bundle `com.apple.security.temporary-exception.apple-events` entries.

**Mitigation (decided in `02-architecture.md` § 7.7, restated here as product policy).** Ship
unsandboxed, distributed outside the Mac App Store; `Lggr.entitlements` sets
`com.apple.security.app-sandbox` to `false` explicitly and comments why. We buy back the trust a
sandbox badge would have signalled with things that are actually verifiable: zero networking
frameworks linked (checkable with `otool -L`), a documented user-readable store path, title and
domain capture that are independently switchable, and a full degradation path if Accessibility is
denied — application name and bundle ID only, app-level classification, nothing else changes, and no
repeat prompting. Hardened runtime plus Developer ID notarisation when there is a distributable build.

**The wrinkle you hit on day one of Phase 3:** TCC keys the Accessibility grant to the code
signature, and ad-hoc signing (`--sign -`) produces a new identity on every rebuild, so macOS forgets
the grant every time `make-app.sh` runs. Create a self-signed "Code Signing" certificate named
`Lggr Dev` in the login keychain and build with `LGGR_SIGN_IDENTITY="Lggr Dev"`. Ad-hoc stays the
default so a fresh clone builds with no setup.

### R3 — Timer drift and sleep/wake handling

**Likelihood: high if implemented naïvely** (an accumulating tick counter is the obvious design and it
is wrong). **Impact: high** — a wrong duration poisons every downstream number: the summary, the
daily total, the weekly allocation, planned-versus-reactive. Users forgive a missing feature; they do
not forgive a timer that lies.

**Mitigation.** The timer never accumulates. Every duration is a pure function of stored `Date`s:
`FocusSession.elapsed(at:)` = `(endedAt ?? now) − startedAt − totalPausedDuration(at: now)`, with
every subtraction clamped at zero, and `pauseStartedAt` representing the one pause that is still open
(`03-data-model.md` § 3). Consequences we therefore get for free: a dropped tick is invisible, timer
coalescing is harmless, a lid close resumes with the right number, and app relaunch mid-session
recomputes exactly via `loadActiveSession()`. `TickTimer` is a 1 Hz `Timer` with `tolerance = 0.15`
on `RunLoop.main` in **`.common`** mode (in `.default` it stops firing while the `MenuBarExtra`
popover is tracking) whose only job is to ask the UI to redraw. `SleepWakeObserver` closes the open
`ActivityEvent` at the sleep timestamp and opens a fresh one on wake; the focus session is *not*
auto-paused (the user decides), and the sleep gap surfaces as idle time on the review sheet — which
is exactly invariant 6 in `03-data-model.md` § 3.3: `elapsed` is the session clock, focused time is
aggregated from activity events, and their difference *is* the idle number. `FocusSessionTimingTests`
covers all nine edge cases in § 3.5 with an injected `FixedClock`; `SessionClock` never calls `Date()`.

### R4 — Menu bar timer battery cost

**Likelihood: medium.** **Impact: medium-high** — a menu bar app with visible energy impact gets
deleted, and no feature can win that back.

**Mitigation, as a budget rather than an intention.**

- Exactly one repeating timer exists in the whole app, at 1 Hz, `tolerance = 0.15` (which lets macOS
  coalesce our wakeup with others), and it runs **only while a session is running**. Paused, finished
  and no-session states run nothing.
- The tick is gated further: it runs only when the elapsed number is actually visible — i.e.
  `showTimerInMenuBar` is on, **or** the main window is on screen and not occluded. A paused session
  with the window closed and the menu bar time hidden schedules nothing at all.
- Idle detection polls `CGEventSource.secondsSinceLastEventType` every **15 s**, not every second.
- Application tracking is event-driven — an `AsyncSequence` over
  `NSWorkspace.didActivateApplicationNotification` — not polled.
- Store writes are coalesced: `JSONFileStore` marks the snapshot dirty and flushes 500 ms later, so a
  burst of edits is one atomic file replacement, not dozens of disk wakeups.
- No background refresh, no daemon, no XPC helper, no login-item agent process.

**Measured acceptance:** with no session running, Activity Monitor "Energy Impact" reads 0.0 and
`powermetrics --samplers tasks` attributes no idle wakeups to Lggr; with a session running, average
CPU under 0.5% over a 10-minute sample. Checked once per phase, not once ever.

### R5 — Window titles across apps that do not expose `AXTitle`

**Likelihood: high** — Electron apps, some Chromium builds, full-screen apps, apps in secure input
mode, and anything with a non-standard accessibility tree either return nothing or return something
useless. **Impact: medium** — classification quality degrades; nothing breaks.

**Mitigation.** `ActivityEvent.windowTitle` is `String?` and every consumer already handles `nil`.
Classification degrades through a defined ladder: `windowTitleContains` → `domain` → `applicationName`
→ `application` (bundle ID) → `.unknown`, and `.unknown` is a first-class displayable category, not an
error state. A missing title is never surfaced as a failure in the UI. Concretely:

- Call `AXUIElementSetMessagingTimeout` (0.25 s) on every element we create. An unresponsive target
  app must never be able to hang the main actor — this is the single most likely beachball in the
  product.
- Attempt the read **once per application switch**, not on a timer. No retry loops.
- Skip title capture entirely while `IsSecureEventInputEnabled()` is true (a password field somewhere
  has focus) — a correctness *and* privacy mitigation.
- Ship a default rule set that is useful on bundle IDs alone (Xcode → Coding, Slack →
  Communication, Terminal → Coding, Zoom/Meet → Meeting), so the app is not dependent on titles to be
  worth using.

### R6 — Browser domain extraction

**Likelihood: high fragility.** **Impact: low-medium** — it improves classification for browser time,
which is a large share of a knowledge worker's day, but nothing depends on it.

**Mitigation.** Treated as the most optional input in the system. It is opt-in, off until the user
enables it, and requires the user to approve the Automation prompt whose text is
`NSAppleEventsUsageDescription` in `Info.plist`: *"Lggr asks Safari or Chrome for the domain of the
frontmost tab so it can classify browser time. It never reads page contents."* We support Safari's
scripting dictionary and the Chrome dictionary (which Chrome, Edge, Brave and Arc share); anything
else — Firefox notably — yields `nil` and falls back to bundle-ID classification. **We extract the
host only**, immediately, and never store the path, query string or fragment: `github.com`, never
`github.com/acme/private-repo/pull/1234`. A denied or failed Apple Event is cached as "unsupported
for this bundle ID" for the session so we never prompt or retry in a loop. If the whole feature
regresses on a future macOS, the app loses one classification input and nothing else.

### R7 — SwiftData migration once real data exists

**Likelihood: medium** (certain eventually; the question is when). **Impact: high** — data loss in a
"log of what you accomplished" app is the one unrecoverable failure. The log *is* the product.

**Mitigation.** The architecture already removes most of the exposure: **the domain value types are
authoritative and SwiftData is a swappable backend**, so the canonical shape of the data is
`Codable` structs related by `UUID`, not a store schema. `StoreSnapshot` carries an explicit
`schemaVersion: Int`; the MVP refuses to load a snapshot newer than it understands and says so
clearly rather than partially decoding. There is deliberately **no migration framework** in the MVP
(`02-architecture.md` § 8) because there is no installed base to migrate. What we do build now,
cheaply, so that we can migrate later:

- `CodableRoundTripTests` asserts every value type and every enum raw value survives encode/decode
  unchanged — which is why every enum has an **explicit** string raw value, so a Swift-level rename
  can never silently invalidate persisted data.
- `LggrStoreContractTests` proves the backends are observationally identical, so JSON is a valid
  escape hatch from SwiftData and vice versa.
- Before any schema change ships: copy the store file to `store.<version>.backup.json` first, and
  ship a "Export all data" action. Recovery is re-import, not a migration plan that has to be right
  the first time.
- `UserPreferences` lives in `UserDefaults` as one JSON blob under
  `com.lggr.userPreferences.v1`, so a store failure can never cost the user their hot key or their
  privacy settings. Note the forward warning in `03-data-model.md` § 7: a field added after v1 ships
  needs an explicit `decodeIfPresent` path or a `v2` key bump.

### R8 — Clock changes and DST

**Likelihood: medium** — twice a year, plus travel across timezones, plus NTP step corrections, plus
users who set the clock manually. **Impact: medium** — a negative duration or a 25-hour Tuesday makes
the whole app look broken.

**Mitigation.** Durations use absolute time (`Date`/`TimeInterval`), which is timezone- and
DST-independent by construction, and every subtraction is clamped at zero, so a backwards clock step
can shorten a duration but can never invert one (`resume(at:)` with `date < pauseStartedAt` adds
exactly 0; `finish(at:)` with `date < startedAt` sets `endedAt = startedAt`). *Bucketing* is where
DST actually bites, so all day and week boundaries go through `Support/CalendarWindows.swift` using
`Calendar.dateInterval(of:for:)` in the user's current calendar and timezone — **never**
`date + 86_400` and never a hardcoded 7 × 24 h week. A DST day is 23 or 25 hours long and the daily
timeline must lay blocks out on the real interval length rather than assuming 1440 minutes.
`WeeklyOutcome.weekStartDate` is stored as midnight-at-week-start in the user's calendar and
recomputed, not arithmetically derived. `FixtureCalendar` includes a DST-transition date so the test
suite actually exercises this rather than assuming it.

### R9 — `MenuBarExtra(.window)` keyboard focus

**Likelihood: medium-high.** **Impact: high** — it threatens principle #1 directly. SwiftUI's
window-style menu bar popover has a history of not reliably taking first-responder focus, which would
mean the "five seconds from the keyboard" path does not exist where we planned to put it.

**Mitigation.** Spike this in the first days of Phase 2, before `StartSessionForm` is styled. The
guaranteed keyboard path is the main window's start sheet reached via ⌘N (a real menu command on a
real main menu — which is why `LSUIElement` is `false`), and the popover is the mouse path. If the
popover cannot hold focus, the global shortcut opens the window sheet instead of the popover; the
five-second budget survives either way. This is also the reason `LSUIElement = false` is not
revisited: an accessory-policy app has no main menu to hang ⌘N, ⌘⇧I, ⌘⇧A and ⌘1–⌘7 on.

### R10 — Activity event volume

**Likelihood: medium.** **Impact: medium** — `JSONFileStore` holds the entire snapshot in memory, and
a heavy year is on the order of a few thousand sessions but potentially a hundred thousand activity
events.

**Mitigation.** `ActivityCoalescer` merges adjacent same-application intervals before they are
written, which collapses alt-tab noise by an order of magnitude. `dataRetentionDays` defaults to 90
with an automatic purge (`deleteActivityEvents(startedBefore:)`). One file per aggregate, so loading
Today does not decode a year of activity. If the measured snapshot exceeds ~10 MB or cold start
exceeds 500 ms with a year of fixture data, that is the trigger to move activity events to
append-only per-month files — not before.

### R11 — Crash or force-quit mid-session

**Likelihood: medium.** **Impact: medium** — losing an in-flight session is exactly the moment a user
stops trusting the app.

**Mitigation.** The session is written to the store at `start`, not at `finish`, so it exists on disk
from second one. `loadActiveSession()` returns the most recent session with `endedAt == nil` and
`elapsed(at:)` recomputes correctly including a pause that was open at quit.
`NSSupportsSuddenTermination` and `NSSupportsAutomaticTermination` are both `false` so macOS does not
kill us mid-write, and `AppDelegate.applicationWillTerminate` flushes. Acceptance test: `kill -9`
during a session, relaunch, session restored with elapsed correct to within one second.

---

## 5. Privacy risks

Lggr reads window titles. That is genuinely sensitive and it deserves to be treated as the central
design constraint of the tracking feature rather than a settings-screen afterthought.

### 5.1 What is captured

Per `ActivityEvent`: application display name, bundle identifier, window title (optional), browser
host (optional), start and end timestamps, idle flag, category, classification source, and the
session it belongs to.

### 5.2 What is never captured, in any phase

Keystrokes. Passwords. Screenshots or screen contents. Document contents. Slack, iMessage or email
message contents. Clipboard contents. URL paths, query strings and fragments — **host only**. File
contents. Anything about other people on the machine. There is no code path that could capture these,
not a preference that disables them.

### 5.3 Risk: a window title is a secret

**"Q3 Layoff Plan — Confidential.docx"**. `Acme Corp — renewal at risk`. `Re: your PIP`.
`#incident-2024-payments`. A title is often the most sensitive string on the screen.

**Mitigations.**
- **Capture requires an explicit system-level grant.** Accessibility must be granted in System
  Settings; there is no silent path. Onboarding explains what a title is used for before asking.
- **Per-app privacy list.** `UserPreferences.privateApplications` — the event is stored as
  `ActivityEvent.privatePlaceholder` ("Private activity") with an empty bundle ID, `nil` title, `nil`
  domain, `.unknown` category. The time is still counted; the identity is not recorded.
- **Redaction happens at write time, never at read time.** `redactedIfPrivate()` is called by the
  tracker *before handing the event to the store*, so a private app's title is never on disk at all —
  as opposed to being on disk and hidden in the UI, which is the version of this feature that leaks.
- **Per-app exclusion.** `excludedApplications` are not tracked at all — no event, not even a
  redacted one.
- **Global kill switch.** `trackingPaused` stops the tracker entirely; `trackWindowTitles` stops just
  titles while keeping app-level tracking.
- **Secure input awareness.** No title read while `IsSecureEventInputEnabled()` is true.
- **Proposed default private list** (see § 8, item 7): seed `privateApplications` with password
  managers on first run, so the worst case is wrong-by-default in the safe direction.

### 5.4 Risk: the app's own UI leaks titles over your shoulder or on a shared screen

You will demo this app, screen-share with it open, and sit in coffee shops with it open.

**Mitigations.** Today's timeline shows **grouped blocks by application and category** by default
(`ActivityCoalescer` + `SessionTimelineBuilder`), not a raw title feed — which is also what
SPEC § 7 asks for. Individual titles are progressive disclosure: one level down, on demand. A future
"Blur details" toggle is a natural Phase 6 addition but is not required for the MVP.

### 5.5 Risk: exports leak more than the user intended

A Markdown weekly review pasted into a shared doc must not carry `windowTitle` strings.

**Mitigation.** Exports are session-, accomplishment- and category-level by default — intent,
outcome, duration, project, category totals. Raw activity detail is included only when the user
explicitly opts in at export time, and the export sheet says what is included in plain words before
the `NSSavePanel` appears.

### 5.6 Retention and deletion

- `dataRetentionDays` defaults to **90**; anything older is purged automatically via
  `deleteActivityEvents(startedBefore:)`. `nil` means keep forever, and that is the user's choice to
  make explicitly, not the default.
- **"Delete all activity history"** — one action, `deleteAllActivityEvents()`, removes every
  `ActivityEvent` and nothing else. Sessions, accomplishments and outcomes — the parts that are
  *your writing* — survive.
- **Deleting a session deletes its captured activity.** This is the schema's only cascade
  (`SDFocusSession.activityEvents`, `deleteRule: .cascade`), and it exists precisely so that
  "I deleted that session" means the titles are gone from disk, not orphaned.
- **Deleting a project never deletes history** — every other relationship nullifies. Your record of
  what you did outlives your filing system.
- **The file is yours.** `~/Library/Application Support/Lggr/` is documented in the README and
  reachable from Settings via "Reveal in Finder". The user can read it in any text editor, delete it,
  or back it up. There is no hidden database and no obfuscation.

### 5.7 Nothing leaves the machine — and it is verifiable

This is the claim the whole positioning rests on, so it is built to be *checked*, not believed:

1. **No networking framework is linked.** `otool -L build/Lggr.app/Contents/MacOS/Lggr` shows no
   `Network.framework`, no `CFNetwork` usage from our code, no URLSession call sites. The README
   states the command so a sceptical user can run it.
2. **No third-party dependencies at all** — nothing that could add a network call in a transitive
   update. Apple frameworks only.
3. **No analytics, no telemetry, no crash reporting, no update checker** — the three things that
   normally make "local-first" quietly untrue.
4. **Acceptance test:** a packet capture over a full day of real use shows zero outbound connections
   attributable to the Lggr process.

### 5.8 At rest

Not encrypted, deliberately (`02-architecture.md` § 8): FileVault is the platform's answer and
duplicating it with a homegrown scheme adds a key-management failure mode without adding real
protection. The store file is written with owner-only POSIX permissions in the user's own Application
Support directory. This is stated plainly in onboarding rather than papered over.

### 5.9 Permission etiquette

Accessibility is requested **at most twice in the app's lifetime**: once during onboarding, once if
the user turns title tracking on in Settings having previously declined. Never on launch, never on a
timer, never with a modal that reappears. If it is denied, the app works — application-level tracking
only — and says so once, calmly, in the tracking settings pane. SPEC: *"Never repeatedly nag the user
for permissions."*

---

## 6. Key user flows

Phase markers indicate when each affordance actually exists. Where a Phase 6 affordance is the ideal
entry point, the Phase 2 equivalent is given so the flow is walkable in the current build.

### 6.1 Flow A — Start a focus session in under five seconds, from the keyboard

**Budget: two keystrokes plus the time it takes to type one sentence.**

1. **⌘⇧Space** anywhere in macOS. `GlobalShortcutService` (Carbon `RegisterEventHotKey`) activates
   Lggr and presents `StartSessionForm`. **[P6]** — *in Phase 2 this is **⌘N** from the main menu
   (`AppCommands`), or clicking `MenuBarLabel` → "Start Focus Session" in `MenuBarIdleView`.*
2. The sheet appears with **`OutcomeField` already focused**. Nothing else needs touching: the
   `ProjectPicker` is pre-selected from `UserPreferences.lastSelectedProjectID`, the `WorkTypePicker`
   is on `.deepWork`, and the `DurationPicker` shows **50m** because `WorkType.deepWork
   .suggestedDuration` is 3000 s. **[P2]**
3. Type the intent — *"Finish the receipt deduplication PR"*. As you type, `OutcomeField` shows up to
   three recent outcomes from the last 30 days beneath the field; **↓** then **↩** accepts one and
   skips the typing entirely. The field is required and the primary button stays disabled until it is
   non-empty. **[P2]**
4. *(Optional, and only if you want to deviate from the defaults.)* **Tab** to `ProjectPicker` and
   type-ahead to a project; **Tab** to `WorkTypePicker` — changing it re-suggests the duration
   (`.communication` → 25m) unless you have already touched `DurationPicker` manually; **Tab** to
   `DurationPicker` where **1/2/3/4** select 25m / 50m / Custom / Open-ended. Linking to a weekly
   outcome lives behind a "Link to weekly outcome" disclosure and is skipped by default. **[P2]**,
   outcome linking **[P5]**.
5. **⌘↩** triggers the primary button **Start Focus**. (**⌥⌘↩** triggers the secondary **Start
   without timer**, which is an open-ended session — `plannedDuration = nil`.) **[P2]**
6. The sheet dismisses. `SessionManager` writes the session to the store immediately (so a crash
   cannot lose it), starts `TickTimer`, and `MenuBarLabel` switches to the `timer` symbol plus
   **49:59** counting down. If the main window is open it shows `ActiveSessionView` with
   `TimerDisplay` dominant. **[P2]**

**Steps 1, 3 and 5 are the only mandatory ones.** Everything between them is a default that is
already correct on most days — that is what buys the five seconds.

### 6.2 Flow B — Capture an interruption without ending the session

Omar pings you about a blocked PR while you are 20 minutes into deep work. The point of this flow is
that it costs you less attention than the interruption already did.

1. **⌘⇧I** from anywhere in the app, or **"Capture interruption"** in `MenuBarActiveView` (the menu
   bar popover, reachable without leaving your current app). **[P3]**
2. `InterruptionCaptureSheet` appears as a small sheet — **one text field, already focused**, and a
   compact source control. Nothing else. The session timer keeps running visibly at the top of the
   sheet so it is obvious you have not stopped anything. **[P3]**
3. Type the note — *"Review Omar's blocked PR."* **[P3]**
4. *(Optional.)* Pick an `InterruptionSource` from a segmented control — Person / Chat / Email /
   Meeting / Incident / Notification / Self / Other. It defaults to `.chat` when the previously
   frontmost application classifies as `.communication`, and `.other` otherwise, so most of the time
   you leave it alone. **[P3]**
5. **⌘↩** saves. An `Interruption` is written with `status: .inbox` and
   `focusSessionID` set to the running session; `FocusSession.interruptionCount` increments. **[P3]**
6. The sheet dismisses. **The timer was never paused, `pauseStartedAt` was never set, and
   `MenuBarLabel` did not change.** You are back where you were. **[P3]**
7. Later, the item is waiting in `InterruptionInboxView` on Today with a badge count. From there each
   item can be converted into a project (`convertedProjectID`), resolved, or dismissed — and it feeds
   "most common interruption sources" in the weekly review. **[P4]**

**Escape hatch:** **Esc** dismisses without saving, and the same sheet is available with no session
running (`focusSessionID` is `nil`) from `MenuBarIdleView` → "Capture Interruption".

### 6.3 Flow C — Finish a session and review it

1. The countdown reaches zero. `NotificationService` posts "Session complete — *Finish the receipt
   deduplication PR*" **[P6]**, and `MenuBarLabel` switches to a `+M:SS` overrun reading driven by
   `FocusSession.overrun(at:)`. Nothing auto-stops; running past the timer is normal and is not
   treated as an error. **[P2]**
2. **Finish** — the primary button in `SessionControls`, or "Finish" in `MenuBarActiveView`, or the
   notification's action. `finish(at:)` closes any open pause first, sets `endedAt`, and the session
   enters `SessionState.awaitingReview` (menu bar symbol `questionmark.circle`). **[P2]**
3. `SessionReviewSheet` appears. It leads with the question — **"What happened?"** — and
   `ResultStatusPicker` shows all five options with their SF Symbols; **1–5** select them from the
   keyboard. This is the only required field. **[P2]**
4. Beneath it, `SessionStatsGrid` presents the evidence without commentary: total duration, focused
   time, idle time, context switches, main applications used, time by category, interruption count.
   **[P3]** — *in Phase 2 this is duration and interruption count only.*
5. `SummaryEditor` is pre-filled by `SessionSummaryBuilder` with deterministic text —
   *"Worked primarily in Xcode and Terminal on receipt deduplication. Reviewed one GitHub pull request
   and spent seven minutes in Slack."* It is a normal editable text view; you accept it, tweak a
   word, or rewrite it. **[P2]** for the intent/duration form, **[P3]** for the activity-derived form.
6. *(Optional.)* A **"Add details"** disclosure reveals `Tangible result`, `Blocker` and `Next step`.
   Collapsed by default — progressive disclosure, and only `resultStatus` is required. When the
   status is `.blocked` the `Blocker` field is expanded automatically, because that is the one case
   where you will want it. **[P2]**
7. **⌘↩** saves. The session persists with its `resultStatus` and `resultSummary`, and `SessionState`
   becomes `.completed`. **[P2]**
8. The sheet dismisses to `TodayView`, where the session is now a `CompletedSessionRow` in the day's
   list, and — from Phase 4 — a block on `DailyTimelineView` reading *"9:00–9:52 / Receipt
   deduplication / Xcode, Terminal, GitHub / Completed"*. **[P2] / [P4]**
9. The row carries a single inline action, **"Log accomplishment"**, which opens
   `AddAccomplishmentSheet` pre-filled: title from the session summary, `projectID` and
   `focusSessionID` linked, `AccomplishmentType` defaulted by result status (`.completed` →
   `.featureCompleted`). **⌘↩** saves it to the Done log. **[P2]**

### 6.4 Flow D — Friday morning weekly review

The Friday moment is the reason the product exists; this flow should take two minutes and require no
recall.

1. Open Lggr — Dock icon, or `MenuBarIdleView` → **"Open Weekly Review"**, which opens the main
   window directly on the review. **[P2]** for the menu item, **[P5]** for the destination.
2. **⌘5** selects **Weekly Review** in the sidebar (`SidebarSection`). It opens on the *current*
   week, with a week stepper for looking back. **[P5]**
3. Read top to bottom. The order is the answer to "what did I do", before "where did the time go":
   1. **Primary outcome** — title, `OutcomeStatus`, progress bar, and the share of tracked time it
      actually received.
   2. **Accomplishments** — the week's `Accomplishment` list grouped by type. This is the section you
      copy into a status update.
   3. **Time allocation** — `TimeAllocationChart` (Swift Charts, restrained): by project, by
      `WorkType`, by `ActivityCategory`.
   4. **Planned versus reactive** — a single proportion from `PlannedVsReactive`, computed from
      `FocusSession.isReactive` and category.
   5. **Rhythm** — focus sessions completed, sessions interrupted, context switches per day.
   6. **`InsightList`** — neutral observations from `InsightGenerator`: *"Your longest uninterrupted
      sessions happened before 11:00 AM." "Slack interrupted 42% of deep-work sessions." "You spent
      5.1 hours reviewing and unblocking other engineers."* Evidence-based, never judgmental, and
      each one traceable to the number it came from.
   7. **Most common interruption sources**, from the inbox. **[P5]**
4. The screen has **one primary action: "Export Markdown"**. It opens `NSSavePanel` via
   `ExportService` and writes the document shaped exactly like the example in SPEC § *Export*. **[P5]**
5. *(The second half of Friday morning.)* **⌘4** → `WeeklyOutcomesView` for next week: set one
   primary outcome, up to two secondary, plus operational responsibilities. Anything not achieved can
   be marked `.carriedOver` rather than silently rewritten, so next week starts honest. **[P5]**

### 6.5 Flow E — Reclassify an activity and create a rule from it

The app got something wrong. Correcting it must take one interaction and must make the app
permanently smarter — this is the loop that replaces AI in the MVP.

1. On `DailyTimelineView` (Today) or `SessionTimelineStrip` (inside a session), a block reads
   **"Chrome · 18m · Distraction"**. It was actually GitHub code review. **[P3]/[P4]**
2. **Right-click the block** → native context menu → **"Reclassify…"**. (Keyboard: focus the block
   and press **⌘R**.) **[P3]**
3. `ReclassifySheet` opens. The top half is the correction: the eleven `ActivityCategory` options,
   with the current one selected. Pick **Code review**. **[P3]**
4. The bottom half is the *learning*, and it shows the exact evidence available to match on, so the
   rule you create is never a guess:
   - Application bundle ID — `com.google.Chrome`
   - Application name — `Chrome`
   - Window title contains — `Pull request`
   - Browser domain — `github.com`
   Lggr pre-selects the **most specific field that is present** (here, `domain` → `github.com`), with
   a one-line preview: *"Browser domain `github.com` → Code review."* **[P3]**
5. *(Optional scope.)* Two toggles narrow the rule into `ClassificationRule.projectID` and
   `.workType`: **"Only in project: SOR engineering"**, **"Only for work type: Code review"**. This is
   what makes SPEC § 5's *"Claude → Research or Coding, depending on the active project"* expressible
   as two scoped rules; scoped rules beat unscoped ones at equal priority via
   `ClassificationRule.specificity`. **[P3]**
6. A checkbox — **"Create a rule from this"** — is on by default. Unchecking it makes the change a
   one-off correction. **[P3]**
7. **⌘↩** confirms. Two things happen: the event's `category` is set with
   `classificationSource = .manual` (and per `03-data-model.md` § 8, re-running the classifier may
   never overwrite it), and a `ClassificationRule` is saved with `isUserDefined = true`. **[P3]**
8. A brief inline confirmation appears where the block was: **"Applied to 6 other blocks today.
   Undo."** Retroactive application covers events whose `classificationSource` is not `.manual`.
   **[P3]**
9. The rule is now visible and editable in **`RulesView` (⌘6)**, showing whether it is yours or a
   default, its scope, and how many events it matched this week — with **"Reset to defaults"**
   available for the shipped rule set. **[P3]**

---

## 7. Success criteria

Observable, measurable, and checkable by one person on one machine. Grouped by what they protect.

### 7.1 Speed — the five-second promise

| Criterion | Measurement | Target |
|---|---|---|
| Time to start a session | Stopwatch, 10 consecutive cold starts, from keystroke to timer visible | **Median < 5 s, p95 < 8 s** |
| Interaction cost | Count of keystrokes beyond typing the outcome, with a remembered project | **≤ 2** |
| Time to capture an interruption | Stopwatch, keystroke to sheet dismissed | **< 4 s**, session never paused |
| Cold launch to interactive Today | `mach_absolute_time` at `applicationDidFinishLaunching` → first frame, with a year of fixture data | **< 500 ms** |
| Mouse-free operation | Every Phase-2 flow attempted with the trackpad physically unavailable | **12 / 12 completable** |

### 7.2 Correctness — the numbers must be trustworthy

| Criterion | Measurement | Target |
|---|---|---|
| Test suite | `swift build && swift test` | **Green at every commit**, no skipped tests |
| Timing edge cases | `FocusSessionTimingTests` against `03-data-model.md` § 3.5 | **All 9 cases covered and passing** |
| Backend equivalence | `LggrStoreContractTests` on `InMemoryStore` and `JSONFileStore` | **Identical observable behaviour** |
| Timer accuracy under stress | 50-min session with 2 pause cycles and a 10-min machine sleep | **`elapsed` within 1 s of hand-computed truth** |
| Crash durability | `kill -9` mid-session, relaunch | **Session restored, elapsed correct within 1 s** |
| Persistence durability | 100 launch/quit cycles with writes | **Zero lost records, zero corrupt files** |
| Layering | `Scripts/check-layering.sh` | **Passes; no `@Model`/`#Predicate`/`#Preview` outside `LggrPersistence` and `_XcodeOnly`** |

### 7.3 Cost — it has to be invisible when idle

| Criterion | Measurement | Target |
|---|---|---|
| Idle energy | Activity Monitor Energy Impact, no session running | **0.0**, no attributable idle wakeups in `powermetrics --samplers tasks` |
| Active CPU | 10-minute average with a session running and tracking on | **< 0.5%** |
| Memory | RSS with a year of fixture data loaded | **< 150 MB** |
| Main-thread responsiveness | No hitch when switching applications rapidly for 60 s | **No beachball; AX reads bounded by a 0.25 s messaging timeout** |

### 7.4 Privacy — the claims must be verifiable, not asserted

| Criterion | Measurement | Target |
|---|---|---|
| No network | `otool -L` on the built binary; full-day packet capture | **No networking framework linked; zero outbound connections** |
| Private-app redaction | Mark an app private, use it, inspect `store.json` by hand | **No title, no bundle ID, no domain on disk — only "Private activity"** |
| Excluded apps | Same, for an excluded app | **No event at all** |
| Deletion is real | Delete a session, inspect the file | **Its `ActivityEvent`s are gone from disk** |
| Retention purge | Set `dataRetentionDays = 7`, seed 30 days of fixtures, relaunch | **Only the last 7 days remain** |
| Permission etiquette | Deny Accessibility, then use the app for a full day | **Prompted at most twice ever; every screen renders; no error state** |
| Degraded tracking still useful | With Accessibility denied for a week | **Session, app-level activity, category totals and weekly review all still produce output** |

### 7.5 Product — does it actually reconstruct the week?

These are the criteria that decide whether the MVP is *good*, as opposed to merely working. Measured
by one week of real, unprompted use by the author.

| Criterion | Measurement | Target |
|---|---|---|
| The Friday test | Answer SPEC § 9's seven questions using only the app — no Git log, no Slack, no calendar | **7 / 7 answerable** |
| Summary usefulness | Fraction of finished sessions whose generated summary was accepted or lightly edited rather than replaced or emptied | **≥ 80%** |
| Evidence density | Accomplishments logged per working week | **≥ 5**, at least 2 of them of an "invisible work" type (`personUnblocked`, `pullRequestReviewed`, `decisionMade`, `workDeprioritized`) |
| Classification coverage | Share of tracked time not in `.unknown`, after the default rule set | **≥ 70% in week 1, ≥ 90% after one week of corrections** |
| Correction burden | Manual reclassifications per tracked hour, after week 2 | **< 1** |
| Capture rate | Focus sessions started per working day during the trial | **≥ 3**, without a reminder to do so |
| Honest retention | Consecutive working days of unprompted use, no spreadsheet fallback | **≥ 10** |

### 7.6 Craft — the calm bar

| Criterion | Measurement | Target |
|---|---|---|
| Light and dark | Every Phase-2 screen in the `LGGR_GALLERY=1` gallery, side by side | **No unreadable contrast, no missing separator, no hardcoded colour** |
| Empty states | Every list and dashboard with an empty store | **Every one has designed copy and a clear primary action — zero blank panes** |
| One primary action per screen | Design walkthrough of every screen | **Exactly one visually dominant action each** |
| No dead affordances | Click every control | **Zero placeholder buttons that do nothing** (SPEC § *Coding expectations*) |
| Tone | Grep the UI strings | **No "score", no "streak", no "wasted", no "you failed"; no red used for a normal outcome** |
| Accessibility | Full keyboard traversal; VoiceOver pass over Today and the active session | **Every control reachable and labelled** |

---

## 8. Open questions

Places where `02-architecture.md` and `03-data-model.md` disagree with each other, or where this
document would have made a different call. Recorded rather than silently resolved. Since
`03-data-model.md` declares itself *"the single source of truth for every type name, field name, and
signature"*, my recommendation is that it wins on every naming conflict below and that
`02-architecture.md` is amended to match.

1. **`LggrStore` has two incompatible definitions.** `02-architecture.md` § 4.2 declares
   `public protocol LggrStore: Sendable` with `actor` conformers and methods
   `allProjects()` / `upsert(_:)` / `sessions(in:)` / `preferences()` / `flush()`.
   `03-data-model.md` § 4 declares `@MainActor public protocol LggrStore: AnyObject` with
   `loadProjects()` / `saveProject(_:)` / `loadSessions(in:)`, no preferences methods, and no
   `flush()`. These cannot both be implemented. **Recommendation: adopt `03`'s signatures verbatim**
   (they are the keystone, and `@MainActor` is forced by SwiftData's `ModelContext`), and amend
   `02` § 4.2, § 5.1 and § 6.6.
2. **`flush()` has nowhere to live under `03`'s protocol,** but `02` § 6.6 depends on it for the
   500 ms write coalescing and `02` § 5.5 / § 6.5 call it from `applicationWillTerminate`.
   **Recommendation:** add `func flush() async throws` to `03`'s `LggrStore` — it is a lifecycle
   method, not a query, and `SwiftDataStore` can implement it as `try context.save()`.
3. **Off-main-thread I/O versus a `@MainActor` store.** `02` § 6.1 justifies the store being an
   `actor` so that "all file and database I/O happens off the main thread automatically"; `03`'s
   `@MainActor` protocol makes that impossible as written. **Recommendation:** keep the `@MainActor`
   protocol and give `JSONFileStore` a private nested `actor` that owns encoding and the atomic
   write, so both intentions survive. This needs to be decided before `JSONFileStore` is written.
4. **`@Model` class prefix: `Stored*` versus `SD*`.** `02` § 2.1 and the folder tree in § 3 use
   `StoredProject`, `StoredFocusSession`, …, and mapping files `ProjectMapping.swift`. `03` § 5 uses
   `SDProject`, `SDFocusSession`, …, and `SDFocusSession+Mapping.swift`. **Recommendation: `SD*`,
   per `03`**; update `02`'s folder tree.
5. **`AppEnvironment` has no preferences store.** `03` § 7 moves `UserPreferences` out of `LggrStore`
   into `UserDefaultsPreferencesStore: PreferencesStoring`, but `02` § 5.1's `AppEnvironment` never
   constructs or holds one — yet `StartSessionForm` needs `lastSelectedProjectID` and
   `MenuBarManager` needs `showTimerInMenuBar` on the first frame. **Recommendation:** add
   `public let preferences: any PreferencesStoring` to `AppEnvironment` and to both factories.
6. **`PrivacyRedactor.swift` versus `ActivityEvent.redactedIfPrivate()`.** `02`'s tree lists
   `Domain/PrivacyRedactor.swift` [P3]; `03` § 2.4 puts redaction on the value type.
   **Recommendation:** keep redaction on the value type and either delete the file from the tree, or
   redefine `PrivacyRedactor` as the *policy* layer that reads `UserPreferences` to decide
   `isExcluded` / `isPrivate` and then calls `redactedIfPrivate()`. The second is genuinely useful and
   testable; it should just not duplicate the erasure logic.
7. **`trackWindowTitles` defaults to `true`, but `02` § 7.7 promises title capture is "opt-in, off
   until the user enables it in onboarding".** These are reconcilable only because capture is
   impossible without the Accessibility grant, which is a real consent gate — but a privacy document
   should not have to lean on that. **Recommendation:** keep the declared default (it is binding) and
   make the onboarding permission screen *always* write the value explicitly, so first run is a
   deliberate choice either way. If we want strict opt-in semantics, flip the default to `false`.
   Also proposed: seed `privateApplications` with password-manager bundle IDs on first run rather
   than the declared empty array — wrong-by-default in the safe direction. Both need a decision
   before Phase 3.
8. **The `<5 s` promise is a Phase-2 principle but `GlobalShortcutService` is Phase 6.** Until then
   the fastest path requires Lggr to already be frontmost (⌘N) or a menu bar click.
   **Recommendation:** either pull `GlobalShortcutService` forward into Phase 2 (it is one Carbon
   file and one preference we already model), or state explicitly that the Phase-2 acceptance
   measurement starts from ⌘N with the app frontmost. Related: R9's `MenuBarExtra(.window)` keyboard
   focus spike should happen in the same week, because if the popover cannot hold focus, the global
   shortcut must open the window sheet instead.
9. **`SessionSummaryBuilder` is listed as [P2]** in `02`'s tree, but with no `ActivityEvent`s until
   Phase 3 it can only assemble intent, project, duration and result. That is fine and worth having —
   it just means the spec's example sentence ("Worked primarily in Xcode and Terminal…") is not
   achievable until Phase 3, and the Phase-2 acceptance criteria should not ask for it.
