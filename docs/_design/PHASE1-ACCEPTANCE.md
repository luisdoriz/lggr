# Phase 1 — acceptance verdict

Verified 2026-07-25 against `INTELLIGENCE.md` §4, "Phase 1".

**Rule applied:** a criterion is *met* only when a test asserts it and that test was observed to run
and pass. "The code looks like it should work" is recorded as *unverified*, not as met.

Suite as run: `./Scripts/test.sh` → **314 tests in 37 suites passed** (291 before this review; 23
added here). `./Scripts/check-layering.sh` → OK. `swift build` → OK.

Tests added by this review:

- `Tests/LggrAppTests/Phase1AcceptanceTests.swift` — criteria 1, 2, 3, 4 and the redaction checks.
- `Tests/LggrKitTests/Phase1DSTAcceptanceTests.swift` — criterion 6.
- `Tests/LggrKitTests/Phase1BlastRadiusTests.swift` — corrupt-day blast radius.
- `Package.swift` gained an `LggrAppTests` target. Criteria 1–4 are properties of `ActivitySampler`
  and `ActivityLaunchRecovery`, which live in the executable target; with only `LggrKitTests` in the
  package they were **not reachable by any test at all** and could only ever have been asserted by
  reading the code.

---

## The eight criteria

| # | Criterion | Verdict | Evidence |
|---|---|---|---|
| 1 | Force-quit for 90 min → a `.appNotRunning` gap of exactly that span, not 90 min in the last app | **Met** | `Criterion1Tests` (3 tests, pass). `ActivityLaunchRecovery.plan` returns `.appNotRunning`, `start == lastHeartbeat`, `end == launch`, `duration == 5400` exactly. Fed through `EpisodeBuilder`: one gap of exactly 5400 s, a block ending at the heartbeat, total episode time 120 min not 210. Negative control: a 45 s relaunch returns `.nothingToDo`, so the mechanism can decline to fire. Also `DayFixtures.crashedAppDay`. |
| 2 | Lid closed 18:00, opened 09:00 → one sleep gap; no 15-hour block; no `.appNotRunning` mislabel | **Met** | `Criterion2Tests` (4 tests, pass). With an unresolved sleep recorded, `plan` returns a single `.systemSleep` gap of exactly 900 min and no `.appNotRunning`. Negative control: the identical launch *without* the recorded sleep returns `.appNotRunning`, so the precedence is doing work. The real nightly geometry — a heartbeat gap wrapped *around* the sleep — leaves the sleep as the long gap and the crash marker at ≤ 1 min. Also `DayFixtures.overnightSleepDay`. |
| 3 | Power cord pulled mid-session → on relaunch the open interval is closed at the last heartbeat | **Met**, with a caveat | `Criterion3Tests` (3 tests, pass). `closeOpenIntervalsAt == lastHeartbeat`, not the relaunch, and not moved forward by a flush that landed 47 s after the last beat. Through the builder, the block ends at 14:30 and the gap is exactly 100 min. **Caveat:** `Outcome.closeOpenIntervalsAt` is produced and never consumed — grep finds no reader anywhere. The outcome holds by a different route (the sampler republishes the open interval on every flush, and `EpisodeBuilder.observable(...)` clips any overlap), so the timeline is correct, but the documented mechanism is dead code and the doc comment on `ActivitySampler.launchRecovery` describes a wiring step that does not exist. |
| 4 | Fast-user-switch away for an hour → zero intervals recorded for that hour | **Met** | `Criterion4Tests` (3 tests, pass). A real `ActivitySampler` driven by real `NSWorkspace` notifications: after `sessionDidResignActive`, twelve activations and three space changes across a simulated hour produce **zero** intervals touching that span, and the only thing covering it is a `.fastUserSwitched` gap. Paired positive control on identical geometry without the switch **does** record an interval, so the test is an experiment rather than an assertion. Suite is `.serialized`: every sampler in the process shares one notification centre, and the un-serialized version of this test was observed passing for the wrong reason. |
| 5 | A real working day → ≤ 14 blocks, tester recognises ≥ 80% without explanation | **Unverified** | Needs a real working day and a human. **What would verify it:** run the built app for a full day, then have the user score each block against memory, recording block count and the fraction recognised — and, per §7, also count blocks Lggr *invented*, which must be zero at Tier 0. Nothing in this environment substitutes. **Inspection:** the fixture days assert `9 ± 2` blocks for a developer day and `≤ 8` for a manager day from 380 and 40 activations respectively, so the block-count half is plausible; the recognition half has no proxy at all. |
| 6 | A synthetic day with a DST transition and a timezone change → no negative durations, no overlapping blocks | **Met** | `Phase1DaylightSavingTests` (5 tests, pass). Spring-forward (an interval whose local end reads 03:00 after starting at 01:30), fall-back (the repeated hour), an interval whose wall clock runs backwards, and one day containing both a DST jump and a New York → Berlin flight with a sleep gap and a declared session over the top. Every episode and gap has non-negative duration, no two episodes overlap, no episode overlaps a gap, and the combined day rebuilds identically from reversed input. |
| 7 | `swift test` covers each pipeline stage against three hand-built fixture days | **Met**, exceeded | Observed run: `Test run with 314 tests in 37 suites passed`. `DayFixtures` supplies **four** hand-built days (`normalDeveloperDay`, `overnightSleepDay`, `crashedAppDay`, `fragmentedManagerDay`), each with an expected `DayTimeline` and a list of falsifiable claims. Per-stage suites exist for normalising (stage 0), evidence credit (1), absences and boundary scoring (2), segmenting/absorption (3) and naming (4), plus `EpisodeBuilderAdversarialTests`, which includes a suite asserting the fixture claims *can* fail. |
| 8 | Lggr does not appear in "Apps Using Significant Energy" over an 8-hour battery day | **Unverified** | Needs eight hours on battery and Activity Monitor. **What would verify it:** unplug, run the built `.app` for a full working day, and check Activity Monitor's Energy tab; supplement with `powermetrics --samplers tasks` for wake-ups per second. **Inspection below.** |

**Met: 6. Unverified: 2 (criteria 5 and 8). Not met: 0.**

---

## Criterion 8 by inspection — timers, wake-ups, leeway

Ambient Lggr (tracking, no focus session running) arms exactly **two** repeating timers:

| Timer | Period | Leeway | Suspended when |
|---|---|---|---|
| `IdleMonitor` — one `DispatchSourceTimer` on `.main` | 15 s active, backing off to 60 s once idle | 3 s (20 % / 5 %) | Screen locked, system sleep, display off, fast user switch, tracking paused, not started. `reschedule()` **cancels** the source rather than calling `suspend()`, so an unbalanced resume cannot trap. |
| `ActivityHeartbeat` — one `DispatchSourceTimer` on `.main` | 60 s | 10 s (17 %) | System sleep only. |

A third timer, `TickTimer` (1 Hz, `Timer` in `.common` mode, `tolerance` 0.15 s), exists but is
installed **only while a focus session is running and unpaused** (`SessionManager` starts it on
start/resume and stops it on pause/finish). It is not part of ambient capture. No other
`Timer`, `DispatchSourceTimer`, `Timer.publish` or `TimelineView` appears in `Sources/`.

Wake-ups per hour, ambient: 240 + 60 = **300 with the user present**, 60 + 60 = **120 once idle**,
every one of them declaring leeway so the kernel can coalesce it. §4 asks for "one
`DispatchSourceTimer`, 15 s, `leeway ≥ 3 s`, backing off to 60 s once already idle, suspended on lock
and sleep. One timer, not two." That is met literally.

**The cost that is not a timer, and the one risk worth stating.** Every heartbeat triggers
`ActivitySampler.flush(reason: .heartbeat)`, which republishes the still-open interval with its end
moved forward. That always marks the day dirty, so `FileActivityLog.flush()` re-encodes and
atomically rewrites **the whole day file, once a minute, all day**, each write ending in
`F_FULLFSYNC`. Measured: an encoded `ActivityDayRecord` costs 241 bytes per interval, so a
600-interval day file is ~145 KB by evening; averaged over 1,440 writes that is on the order of
100 MB written and 1,440 full syncs per day. Small in absolute terms, and almost certainly well under
the sustained-CPU bar Activity Monitor uses — but it is the largest ambient cost in Phase 1 and it is
the thing to look at first if criterion 8 fails.

Second, smaller risk: the heartbeat is suspended **only** on `.systemSleep`. A machine sitting locked
or with the display off (but awake) keeps beating and keeps rewriting the day file once a minute.

Verdict on 8 by inspection: **plausibly met, unproven.** The design does what §4 asked for. Nobody
has run it for eight hours on battery.

---

## The five specific checks

### Does any code path record or persist a window title?

**No.** Grepped `Sources/` and `Tests/` for `windowTitle`, `kAXTitle`, `AXUIElement`,
`CGWindowListCopyWindowInfo`, `kCGWindowName`. The only hits are prose and one dead preference (see
below). `ActivityInterval` has no title field, and `Phase1QuietFailureTests` asserts this over the
*encoded* form — the JSON keys are exactly `id, bundleIdentifier, displayName, start, end,
monotonicDuration, isIdle, idleConfidence, tzOffsetMinutes` — so adding one fails a test rather than
relying on review.

One loose end: `UserPreferences.trackWindowTitles: Bool = true` exists, is `Codable`, is persisted,
and is **read by nothing**. It records no title, so the promise holds; but a stored preference
defaulting to `true` and named for the one capability §3.3 kills is a trap for the next reader.
Recommend deleting it or defaulting it to `false` with a comment.

### Does the app request any permission in Phase 1?

**No permission is requested at runtime.** No `AXIsProcessTrusted`, no `requestAccess`, no
`EKEventStore`, no `AVCaptureDevice`, no `SCShareableContent`, no `CGRequestListenEventAccess`, no
`CNContactStore`, no `UNUserNotificationCenter`, no `NSAppleScript`/`NSAppleEventDescriptor`
anywhere in `Sources/`. Every signal comes from `NSWorkspace`, `DistributedNotificationCenter`,
`CGSessionCopyCurrentDictionary`, `CGDisplayIsAsleep` and `CGEventSource`, none of which prompt.

**But the shipped bundle still advertises two it does not use**, and this contradicts §3.5's claim
that "the reviewable emptiness of Lggr's TCC footprint is a product claim":

- `Resources/Info.plist` ships `NSAccessibilityUsageDescription` — *"Lggr reads the title of the
  window you are currently working in"* — which is the Phase 4 capability §3.3 forbids, written in
  the present tense.
- `Resources/Info.plist` ships `NSAppleEventsUsageDescription` for a browser-domain feature that does
  not exist.
- `Resources/Lggr.entitlements` sets `com.apple.security.automation.apple-events` to `true`, and its
  comment block describes reading window titles via `AXUIElement` as "the core automatic-tracking
  feature".

None of these triggers a prompt on its own, so criterion-wise Phase 1 requests nothing. They are
nonetheless a shipped, user-visible claim to capabilities the phase has deliberately not built, and
the entitlements comment directly contradicts the design. Recommend removing all three until Phase 4.

### Is redaction for private applications applied at capture, or only at display?

**At capture.** `ActivitySampler.refreshFromSystem` substitutes
`ActivitySampler.privateBundleIdentifier` / `privateDisplayName` *before* the `OpenInterval` is
constructed, so the real identity never enters the sampler's buffer, never reaches the flush handler,
and never reaches the day file. Asserted, not assumed: `Phase1QuietFailureTests` marks the test
host's own frontmost application private, runs a real sampler, and checks every flushed interval —
none carries the real bundle identifier, all carry the sentinel, and the time is still recorded so
the day still adds up. A companion test shows an *excluded* application becomes a typed
`.excludedApplication` gap rather than a silent hole.

The pseudonym is a single shared constant rather than per-app, which is the right call: a stable
per-app pseudonym would still be a join key.

### Can a single corrupt day file cost the user more than that day?

**No.** `Phase1BlastRadiusTests` (2 tests, pass), alongside the pre-existing
`ActivityLogTests.oneBadDayCostsOneDay`. With four day files and one destroyed on disk: listing the
directory still works before and after, the damaged day quarantines to `YYYY-MM-DD-corrupt-*.json`
and returns an empty record rather than throwing, the other three load byte-identical, the
quarantined file is not mistaken for a day by `availableDays()`, **the damaged day can be appended to
and flushed again** — so today does not stop recording because this morning's file was destroyed —
and the original bytes are preserved rather than deleted. Reading the newest day first, which is what
the launch path does, does not block older days.

Scope note: this covers `activity/YYYY-MM-DD.json`. A corrupt `store.json` still costs every session
and accomplishment, but that is the Phase 2 store and outside this criterion.

### Does the sampler write to `store.json` on every activation?

**No — it never writes to `store.json` at all.** `ActivitySampler` holds no reference to `LggrStore`;
its only sink is the injected `ActivityFlushHandler`, and `ActivityCapture` wires that handler
exclusively to `ActivityLog`. `SessionManager` is the only object in the app that talks to
`LggrStore`.

Nor does it write per activation. An activation only mutates the in-memory buffer and schedules a
burst flush that waits `burstQuietPeriod` (2 s) of quiet, cancelling any earlier one; writes
otherwise ride the 60 s heartbeat plus transitions (sleep, lock, pause, timezone change, terminate).
The heartbeat is its own 40-byte file, not a field in `store.json`, as §4 requires.

---

## Also worth recording

Two things outside the numbered criteria, both from §4's "What ships" list and §2's
"price of the inversion, paid up front".

**The menu bar does not show tracking state, and Pause tracking is a Settings toggle.** §2 calls this
non-negotiable: *"the menu bar icon must visibly distinguish tracking / paused / not tracking, and
**Pause tracking** is the popover's first row, not a Settings toggle."* `TrackingStateGlyph` and
`TrackingPauseRow` are both written, documented and tested-adjacent — and `TrackingPauseRow` is
**referenced nowhere**. `MenuBarLabel` and `MenuBarContentView` contain no tracking state and no
pause row; the only rendering of `TrackingStateGlyph` in the app is inside
`PrivacySettingsView.trackingSection`, which is exactly the Settings toggle §2 rules out. The
component exists; the wiring does not. This is a one-line-per-site fix, and until it lands the app is
always watching with no glance-level indication and no one-click stop.

**`Scripts/test.sh`'s silent-skip guard does not catch a zero-test run.** The guard greps for
`Test run with [0-9]+ test`, which matches `Test run with 0 tests in 0 suites passed`. Observed
during this review: `./Scripts/test.sh --filter "Phase 1 acceptance"` matched nothing, ran zero
tests, and the script printed `OK`. Given that this project has already been bitten once by a
`swift test` that ran nothing, the guard should require `[1-9][0-9]*`, or assert a floor on the test
count.

**Storage layout differs from the plan.** §5 specifies `Activity/YYYY-MM.json` loaded a month at a
time; what shipped is `activity/YYYY-MM-DD.json`, one file per day. The per-day split is arguably the
better choice — it makes retention pruning and "delete all activity" file deletions, and it is why
the blast radius above is one day — but the design document should be amended to say so rather than
leaving the two out of step.
