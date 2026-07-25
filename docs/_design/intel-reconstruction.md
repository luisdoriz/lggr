# Lggr — Reconstruction: the day you can't remember

> **Lens: evidence and reconstruction.** A proposal for the capture-and-reconstruct engine.
> Written against `SPEC.md` §4, §5, §6, §7, §9 and `DESIGN.md` §3.8, §4.2.5, §5.4.1, §6.1, §6.8.
> Everything here is local, deterministic-first, and additive to the Phase 2 build that runs today.

---

## 1. The core bet

Lggr today knows what you *said* you would do and what you *reported* happened. Both are
self-report, and self-report is the thing that fails at 4pm on Friday. The bet is that a
**low-frequency, low-fidelity, permission-optional event stream — frontmost app, window title,
browser host, idle, sleep — contains enough structure to reconstruct a day into eight to twelve
blocks that a human recognises as "what I was doing"**, and that the reconstruction is more accurate
than memory for anything older than about four hours. The unit of the product is not the event; it
is the **Episode** — a contiguous, named, project-attributed stretch of work like *"09:04–09:58 ·
SOR-482 Deduplicate receipts · Xcode, Terminal, github.com."* Raw events are evidence, not product.
The hard part, and the whole of the engineering risk, is the function `[ActivityEvent] → [Episode]`:
turning six hundred app activations into eight lines. If that function produces blocks the user nods
at, Lggr stops being a timer with a diary and becomes the only honest record of the week. If it
produces plausible-but-wrong blocks, it is worse than nothing, because a wrong reconstruction is
believed. Everything below is built to make the first outcome likely and the second one visible.

---

## 2. The mechanism

### 2.1 The layer stack

Five layers, each one narrower and more durable than the one below it. Only two of them are
persisted.

| Layer | Lives | Persisted? | Volume/day |
|---|---|---|---|
| **Signal** | `NSWorkspace` / `AXObserver` / HAL callbacks | never | ~600 |
| **`ActivitySample`** | tracker memory, unredacted, deliberately not `Codable` (already specified, `DESIGN.md` §4.2.5) | never | ~250 |
| **`ActivityEvent`** | redacted-at-capture interval (already specified) | **yes, 30 days** | ~150 |
| **`Episode`** | the coalesced, named, project-attributed block — **new** | **yes, forever** | ~8–14 |
| **`DayTimeline`** | ordered episodes + typed gaps for one day — **new** | derived + sealed | 1 |

Two new value types in `LggrKit`. No SwiftData macros, no UI dependency, pure and testable today.

```swift
// Sources/LggrKit/Domain/Episode.swift
public struct Episode: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var interval: DateInterval
    /// Chosen by `EpisodeNamer`. Never a raw window title.
    public var label: String
    /// Apps by descending time, capped for display by the view.
    public var applications: [AppShare]        // bundleID, displayName, seconds, glanceCount
    public var dominantCategory: ActivityCategory
    public var projectID: UUID?
    public var projectConfidence: Confidence   // .confirmed | .inferred | .none
    public var labelConfidence: Confidence
    /// Set when the episode overlaps an explicit session by ≥60% of its duration.
    public var focusSessionID: UUID?
    /// Detours: short excursions absorbed back into this episode (Slack for 90s and back).
    public var detourCount: Int
    /// Ids of the ActivityEvents this was built from — the audit trail behind the ⓘ popover.
    public var evidenceEventIDs: [UUID]
    /// True once the user renamed / re-projected / split / merged it. Never re-derived after.
    public var isUserEdited: Bool
}

// Sources/LggrKit/Domain/DayTimeline.swift
public struct DayTimeline: Codable, Sendable {
    public let day: DateInterval
    public var episodes: [Episode]
    public var gaps: [Gap]
    public var sealedAt: Date?
}

public struct Gap: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case idle, displaySleep, systemSleep, locked, fastUserSwitched
        case appNotRunning      // derived from the heartbeat — the honesty mechanism
        case trackingPaused, excludedApplication
    }
    public let interval: DateInterval
    public let kind: Kind
    /// One-click user attribution, no typing. nil until they answer, and they never have to.
    public var attribution: GapAttribution?   // .meeting | .awayFromDesk | .offlineWork | .episode(UUID)
}
```

### 2.2 Capture: what to sample, and how often

**Everything is event-driven except two polls.** The tracker is not a sampler; sampling a frontmost
app on a timer is both less accurate and more expensive than listening.

| Signal | API | Trigger | Permission |
|---|---|---|---|
| App switch | `NSWorkspace.shared.notificationCenter` → `didActivateApplicationNotification` (the `AsyncSequence` bridge already designed in `DESIGN.md` §3.8.3) | on activation | **none** |
| App launch/quit | `didLaunchApplicationNotification`, `didTerminateApplicationNotification` | on event | none |
| Window title | `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` → `kAXTitleAttribute` | on activation, **plus** `AXObserverCreate` + `AXObserverAddNotification` for `kAXFocusedWindowChangedNotification` and `kAXTitleChangedNotification` on the *frontmost app only*, torn down on switch | **Accessibility** |
| Window title (fallback) | same read, on a 20 s timer while one app stays frontmost | for apps whose AX tree refuses observer registration (common in Electron) | Accessibility |
| Browser host | `NSAppleScript` per `DESIGN.md` §6.1.2, host-only via `DomainExtractor` | on activation, on title change, max 1/15 s | **Automation**, per browser |
| Idle | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType:)` — min over `.mouseMoved`, `.keyDown`, `.scrollWheel`, `.leftMouseDown` | poll every 15 s | **none** |
| Sleep / wake / lock | `NSWorkspace` `willSleepNotification`, `didWakeNotification`, `screensDidSleepNotification`, `screensDidWakeNotification`, `screensDidLockNotification`, `screensDidUnlockNotification`, `sessionDidResignActiveNotification` | on event | none |
| Mic in use (meeting detector) | CoreAudio `AudioObjectGetPropertyData` with `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device | poll every 15 s, alongside idle | **believed none** — this reads a HAL device property, it does not open a capture session. **Spike this before relying on it**; if it turns out to prompt, drop it and detect meetings from the frontmost bundle ID alone. |
| Process liveness | `lastHeartbeatAt` written to disk every 60 s and on every event | timer | none |

Two capture rules that carry disproportionate weight:

**Idle is backdated, not stamped.** When the 15 s poll at time *T* reports `secondsSinceLastEvent =
S` and *S* ≥ threshold, the idle interval began at **T − S**, not at *T*. The open app interval is
closed at *T − S*. Getting this wrong silently attributes every idle threshold's worth of nothing to
whatever app happened to be frontmost, and at a 3-minute threshold with twenty idle transitions a
day that is an hour of fiction. Default `idleThreshold` = 180 s (the field already exists in
`UserPreferences`).

**The heartbeat is what makes the timeline honest.** If Lggr is force-quit, crashes, or the Mac
reboots at 18:40 and relaunches at 09:00, the naive reconstruction shows fourteen hours in Xcode.
That single lie destroys trust permanently. So: `lastHeartbeatAt` is persisted every 60 s; on launch,
if `now − lastHeartbeatAt > 120 s`, a `Gap(kind: .appNotRunning)` is inserted for exactly that span
before any other work happens. The app must be visibly willing to say "I don't know."

### 2.3 The grouping algorithm — this is the product

A pure function in `LggrKit`, five stages, each independently unit-testable against fixture days. No
I/O, no clock, no UI. `EpisodeBuilder.build(events:sessions:signatures:weights:) -> DayTimeline`.

#### Stage 0 — Normalise

Drop intervals shorter than 2 s (attributed to the following neighbour). Merge adjacent intervals
with identical `(bundleIdentifier, normalizedTitle)`. **Glance collapsing:** an activation shorter
than 8 s that returns to the immediately preceding app is not an interval — it increments
`glanceCount` on the interval it interrupted. This alone typically removes 40–60% of raw activations,
because a cmd-tab to check Slack and back is the single most common event in a knowledge worker's
day and it is not a context switch in any sense the user would recognise.

#### Stage 1 — Evidence extraction

Each event yields an **evidence bag**: `{bundleID} ∪ tokens(title) ∪ {host}`. Title tokenisation is
where all the leverage is, and it is app-specific. `TitleParser` is a protocol with ~15 built-in
conformances plus a generic fallback; users never see it.

| App | Title shape | Extracted |
|---|---|---|
| Xcode | `ReceiptDeduplicator.swift — Lggr` | file stem split on camelCase → `receipt`, `deduplicator`; workspace `lggr` (strong project signal) |
| Terminal / iTerm / Ghostty | `~/dev/lggr — zsh`, `user@host: ~/dev/sor` | last path component → `sor` |
| Browser + GitHub | host `github.com`, title `Fix receipt dedup by luisdoriz · Pull Request #482 · acme/sor` | repo slug `acme/sor` (regex `([\w-]+/[\w.-]+) · (Pull Request|Issue)`), PR number, subject tokens |
| Linear / Jira | `SOR-482 Deduplicate receipts` | **issue key** via `\b[A-Z]{2,6}-\d{1,6}\b` — the single strongest identifier available |
| Slack | `#sor-eng (Acme) - Slack` | channel `sor-eng` |
| Notion / Docs / Figma | document title | title tokens |
| Generic fallback | anything | strip trailing ` — App` / ` - App` / `App`, lowercase, split on non-alphanumerics, drop stopwords and tokens < 3 chars, keep top 8 |

Tokens are classified as **identifiers** (issue key, repo slug, workspace, repo directory, channel,
domain — high IDF, stable across days) or **topic tokens** (everything else). Identifiers do the
naming and the project inference; topic tokens do the segmentation.

#### Stage 2 — Boundary scoring

Walk the normalised stream. Between event *i* and *i+1*, compute a scalar. Cut when it exceeds θ.

```
boundary(i) =  w_gap      · gapScore(i)              // 0 at <60s, ramps to 1.0 at 5min, ∞ at 10min
             + w_evidence · (1 − jaccard(Bag(i−5min…i), Bag(i+1…i+5min)))
             + w_category · categoryDistance(i)      // coding→testing ≈ 0; coding→meeting = 1
             + w_session  · sessionBoundary(i)       // ∞ — an explicit session start/end always cuts
             + w_meeting  · meetingTransition(i)     // ∞ — mic-hot or meeting bundle, both edges
             − w_satellite· satelliteBonus(i)        // Xcode↔Terminal↔Simulator↔github.com are one triad
             − w_return   · returnWithin(i, 120s)    // you left and came back: a detour, not a boundary
```

All weights live in one `SegmentationWeights` struct with documented defaults. **None of them is
exposed in the UI.** There are no knobs; a user who has to tune a segmenter has been handed our
problem. They are tuned once against a fixture corpus and frozen, and changing them is a code change
with a test diff.

`sessionBoundary` being infinite is the load-bearing design decision: **an explicit focus session is
ground truth for a block**, and reconstruction fills the space between sessions rather than competing
with it. Everything the app already does keeps working and gets stronger.

#### Stage 3 — Absorption to a fixed point

Any segment shorter than `minEpisodeDuration` (default 4 min) is absorbed into whichever neighbour
shares more evidence, unless it is a meeting or is bounded on both sides by hard gaps. Re-coalesce.
Iterate to a fixed point (each pass strictly reduces the segment count, so termination is
guaranteed; cap at 10 passes anyway). **This stage is what takes 60 candidate segments to 9.**

#### Stage 4 — Naming

Strict precedence, first match wins:

1. Overlaps a focus session ≥ 60% by time → **the session's `intendedOutcome`, verbatim**. The
   user's own words are always the best label, and this is why explicit sessions remain the highest
   value thing the user can do.
2. Highest-scoring identifier present, rendered as a phrase: issue key > repo slug > git branch >
   workspace name > document title > dominant file stem. `SOR-482 · Deduplicate receipts`.
3. Dominant category: `Code review`, `Communication`, `Planning`.
4. **Zero-permission floor:** the app mix — `Xcode, Terminal, GitHub`. Which is, precisely,
   `SPEC.md` §7's own worked example.

Subtitle is always the app roster by descending time, capped at three plus "+2 more".
`labelConfidence` is `.confirmed` for tier 1, `.inferred` for 2–3, `.none` for 4.

#### Stage 5 — Project inference, learned without typing

Each project accumulates a `ProjectSignature`: observed identifier → count. It is built
**automatically from confirmed evidence** — every explicit session for project *P* donates the
identifiers seen during it, and every user confirmation of an inferred episode donates the same.
The correction loop *is* the training loop. This satisfies principle 6 completely: the user types
nothing, ever, to make project inference work.

```swift
score(P, episode) = Σ_{t ∈ identifiers(episode)} log(1 + count_P(t)) · idf(t)
```

Assign only if `top ≥ minScore && top ≥ 1.5 × runnerUp`. Otherwise `projectID = nil`, rendered as
*Unassigned*. **Refusing to guess is a feature.** Inferred assignments render with a dotted
underline and a one-click confirm; confirming writes back into the signature.

Naive Bayes over a token bag, in pure Swift, ~80 lines, no ML framework, fully deterministic and
snapshot-testable. This is exactly what `SPEC.md` §5's "rule-based classification engine before any
AI" means in practice.

### 2.4 Live, not just nightly

The open episode is recomputed on every event over a trailing 30-minute window — microseconds of
work — so the menu bar can say *"Untracked · SOR-482 · 41m"* right now. That is what makes the 9:02am
standup case work, not only the Friday case.

Days seal at **04:00 local**. After sealing, a day's episodes are immutable except for explicit user
edits; re-segmentation only happens if the user asks for *Rebuild this day*. **A timeline that
silently rewrites its own past is not evidence.**

### 2.5 Storage: the actual numbers, and the one change required

Per persisted `ActivityEvent`, minified JSON: uuid 38 + bundleID ~27 + appName ~12 + title ~62 +
two ISO dates ~54 + category/flags/source ~55 + key names ~120 ≈ **~300 bytes**. At 150 events/day ×
250 working days = **37,500 events ≈ 11 MB/year**. That is already past the 10 MB trigger
`DESIGN.md` R10 sets for `JSONFileStore`, which holds the whole snapshot in memory. So:

**Split the store when this ships, not later.** Activity events move out of `snapshot.json` into
`Activity/YYYY-MM.json` month files, loaded lazily one month at a time. Sessions, accomplishments,
projects and outcomes stay in the single snapshot — they are tiny (~1,500 sessions/year × 400 B ≈
600 KB) and they are the authored record. `LggrStore` gains three methods:
`loadActivityEvents(in:)`, `appendActivityEvents(_:)`, `loadTimeline(day:)` / `saveTimeline(_:)`.
Existing `snapshot.json` files are untouched, so there is **no migration for current data**.

**Two-tier retention, which is strictly better than one number:**

| Tier | Contents | Default retention | Size |
|---|---|---|---|
| Evidence | `ActivityEvent` **with window titles** | **30 days** | ~0.9 MB resident |
| Reconstruction | `Episode` / `DayTimeline` (~250 B × 12/day) | **kept** (or the user's setting) | **~0.8 MB/year** |

This inverts the usual tradeoff on purpose: **the evidence expires, the reconstruction persists.**
You can keep a decade of "what I actually did" for less than a photo. It is also the
privacy-correct default — window titles, the most sensitive thing captured, have the shortest life —
and the existing `RetentionPruner` (`DESIGN.md` §6.8.3) needs only a second cutoff. Settings copy:

> **Detailed activity** 30 days — window titles and app intervals.
> **Your day timeline** Kept — the blocks built from them. Sessions and accomplishments are always kept.

Weekly review then reads ~60 episodes, not 40,000 events. Yearly review reads ~3,000.

---

## 3. What it changes for the user

### 3.1 Recap — ⌘R, and the reason the feature exists

One new surface, not a dashboard. Prose, scannable, copyable.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Yesterday                                              Wed 23 July  ⌄   │
│  ──────────────────────────────────────────────────────────────────────  │
│  09:04–09:58   SOR-482 Deduplicate receipts                       54m  ⓘ │
│                Xcode, Terminal, github.com          ● SOR engineering    │
│                ↳ "Finish the receipt dedup PR" — Made progress           │
│                                                                          │
│  09:58–10:12   Communication                                      14m  ⓘ │
│                Slack · #sor-eng, #incidents            ○ Unassigned      │
│                                                                          │
│  10:12–10:40   Away · display asleep                              28m    │
│                [ Meeting ]  [ Away from desk ]  [ Offline work ]  [ ✕ ]  │
│                                                                          │
│  10:40–12:05   Reviewing acme/sor #479 and #481                1h 25m  ⓘ │
│                github.com, Xcode                    ● SOR engineering    │
│                                                                          │
│  13:10–13:52   Platform sync                                      42m  ⓘ │
│                Google Meet, Notion                  ⋯ Team leadership    │
│  ──────────────────────────────────────────────────────────────────────  │
│  6h 12m tracked · 9 blocks · 3 gaps · longest unbroken stretch 1h 25m    │
│  [ Copy as Markdown ]   [ Copy standup note ]   [ Log an accomplishment ]│
└──────────────────────────────────────────────────────────────────────────┘
```

Three details carry the whole thing:

- **ⓘ is the credibility mechanism.** It opens the evidence: the intervals the block was built from,
  the identifiers extracted, and why this project was chosen. Raw window titles appear *only* here,
  behind an explicit **Show titles** reveal, never in the timeline itself. A block a user can audit
  is a block a user believes; a block they cannot audit is a claim.
- **Dotted underline = inferred.** `● SOR engineering` is confirmed, `⋯ Team leadership` is inferred,
  `○ Unassigned` is an honest shrug. One click confirms and teaches the signature.
- **Gaps ask once, with buttons, never a text field.** Zero typing, and `[ ✕ ]` dismisses forever.

**Copy standup note** produces deterministic prose from the episodes:

> Yesterday: receipt dedup (SOR-482) for just under an hour, then reviewing acme/sor #479 and #481
> for 1h 25m. Platform sync at 13:10. 28 minutes away mid-morning. Nothing recorded as blocked.

### 3.2 Today gains a timeline that is populated whether or not you started a session

`DESIGN.md` §5.4.1 already reserves the strip and the two lines beneath it. It now has real data all
day, including the hours you forgot to track. The 4pm realisation *"I never started a session this
morning"* stops costing you the morning.

### 3.3 The menu bar converts reconstruction into intent

With no session running, the popover header reads:

> **Untracked · SOR-482 · 41m**   `[ Start a session on this  ⌘⏎ ]`

One keystroke turns an inferred block into an explicit session with project and outcome pre-filled.
This is the highest-leverage moment in the whole app: the user is already doing the work, and we are
asking for one key rather than a form. Principle 6, and the five-second rule, both honoured.

### 3.4 The session review sheet stops being a blank page

`SessionSummaryBuilder` already generates the summary line. It now has evidence to build it from —
`SPEC.md` §6's worked sentence becomes literally derivable — plus the detour count as
"interruptions", and a suggested tangible result when the evidence contains a PR number that appeared
for the first time during the session.

### 3.5 Weekly review observations become evidence-backed

Every `SPEC.md` §9 observation is now computable and neutral: *"Your longest unbroken blocks started
before 11:00 on four of five days." "Blocks containing Slack averaged 11 minutes; blocks without it
averaged 34." "5.1 hours went to reviewing other people's pull requests."* Statements of measurement.
No score, no streak, no red. `SPEC.md`'s ban on shaming is preserved by construction: the engine
emits durations and counts, and the copy layer is forbidden the words *only*, *just*, *wasted*,
*distracted* and *should*.

---

## 4. Permissions and the degraded modes

| Tier | Grant | What reconstruction becomes | Rough value |
|---|---|---|---|
| **0** | **Nothing** | Real blocks, honest gaps, correct idle and sleep handling, context-switch counts, per-app time. Labels are app mixes: *"09:00–09:52 · Xcode, Terminal, GitHub."* Project inference works only via explicit-session overlap. | ~55% |
| **1** | **+ Accessibility** (`AXIsProcessTrusted()` to check, never caches; `AXIsProcessTrustedWithOptions` to ask, at most once ever) | Titles → identifiers → real names and learned project inference. *"SOR-482 Deduplicate receipts."* **This is the jump.** | ~85% |
| **2** | **+ Automation**, per browser | Browser time stops being one blob: github.com ≠ youtube.com. Domain rules from `SPEC.md` §5 become possible. Firefox never participates — it exposes no scriptable URL, full stop. | ~95% |

Nothing degrades to broken. Every tier produces a complete Recap; higher tiers produce a
better-labelled one. The ladder in `DESIGN.md` §6.3 is unchanged, and the ask happens exactly once,
in onboarding, per `DESIGN.md` §6.6.

**What is genuinely impossible on macOS, stated plainly rather than designed around:**

- **Browser URL without Apple Events.** There is no public API. Window titles do not contain URLs in
  any major browser.
- **Window titles without Accessibility or Screen Recording.** `CGWindowListCopyWindowInfo` has
  returned `nil` for `kCGWindowName` on other processes' windows since macOS 10.15 unless the caller
  holds Screen Recording.
- **Which file/document is open**, beyond whatever the title says.
- **"Thinking" versus "left the room."** `secondsSinceLastEventType` measures input silence. Nothing
  more is knowable without a camera, which we will never ask for.

**Deliberately rejected, named here so nobody proposes them in six months:**

- **ScreenCaptureKit / OCR of the screen.** Technically the highest-fidelity signal available and an
  outright violation of `SPEC.md` §4's screenshot ban. Also requires Screen Recording, which grants
  pixel access to every window. Rejected permanently, not deferred.
- **EventKit calendar read.** Would resolve most large gaps into meetings for near-zero effort. But
  `DESIGN.md` §6.1.6 makes a hard commitment that Lggr never appears in the Calendar pane of System
  Settings, and it is a good commitment: the reviewable emptiness of Lggr's TCC footprint is a
  product claim. Meetings are instead detected from the frontmost bundle plus the mic-hot HAL
  property, which costs no permission and covers the meetings that actually happened rather than the
  ones that were scheduled. If this is ever revisited, it must be a separate, off-by-default,
  clearly-labelled opt-in and `NSCalendarsFullAccessUsageDescription` (macOS 14+) must be added.
- **Speech framework.** There is nothing to transcribe without recording audio.
- **Input Monitoring / `CGEvent.tapCreate`.** Forbidden by `SPEC.md` §4 and unnecessary.

**FoundationModels (Apple Intelligence, on-device, macOS 26+):** permitted under principle 1 — it is
genuinely local, no network entitlement, and `CONSTRAINTS.md`'s machine runs macOS 26. But it is
gated by OS version *and* hardware *and* the user enabling Apple Intelligence, so it can never be
load-bearing. Its **only** sanctioned role is naming of last resort: when Stage 4 falls through to
tier 4 ("Xcode, Terminal"), pass the evidence bag — not the raw titles, not private-app data — to a
`LanguageModelSession` with a `@Generable` five-word-label struct, guarded by
`SystemLanguageModel.default.availability`. Fallback on macOS 14–25, on unsupported hardware, or when
disabled: the rule-based name, which is the shipped behaviour. **Segmentation and classification stay
deterministic forever**, because they must be reproducible, testable and auditable, and because
`SPEC.md` §5 says so. Off by default, one Settings toggle, described honestly.

---

## 5. What could make this fail

1. **Confidently wrong blocks.** The killer failure is not messy output, it is a plausible block that
   did not happen. Users forgive *"I don't know"*; they never forgive *"you did X"* when they did Y —
   one such block and the timeline is never trusted again. *Mitigations:* visible confidence tiers,
   the ⓘ audit trail, refusing to assign a project below the margin, never auto-creating an
   accomplishment, and hard gaps rendered as gaps rather than smeared into neighbours.

2. **Window titles are worse than assumed. This is the biggest risk.** Slack sometimes reports just
   `Slack`. Electron apps expose flaky AX trees and may refuse `AXObserver` registration. Some apps
   report the document but not the project. If title quality is poor, tier 1 never delivers its jump
   and the whole system is tier 0 forever — still useful, but not 10x. It is also *measurable in a
   week*, which is why §6's first slice exists solely to measure it.

3. **Titles leak more than users expect.** *"Q3 Layoff Plan.docx — Pages"* is not document contents,
   but it is content-adjacent. *Mitigations:* the 30-day evidence tier; the existing private/excluded
   app lists with capture-time redaction; a user-editable `titleDenyPattern` list; skipping capture
   entirely while `IsSecureEventInputEnabled()`; and the structural one — **titles are never rendered
   in the timeline**, only derived labels, with raw titles behind an explicit reveal.

4. **It reads as an accusation.** A neutral engine plus careless copy produces shaming. *Mitigation:*
   the banned-word list above, enforced by a test over the copy catalogue, and no aggregate score of
   any kind, ever.

5. **AX calls hang.** `AXUIElementCopyAttributeValue` against a wedged app blocks the caller.
   *Mitigation:* `AXUIElementSetMessagingTimeout(element, 0.25)` on every element (already `DESIGN.md`
   R5), reads only on switch or observer callback, never in a retry loop, and off the main actor.

6. **Trust collapse from one bad day** — the fourteen-hour-Xcode failure. *Mitigation:* the heartbeat
   and `Gap(.appNotRunning)`. Non-negotiable, ships in slice 1.

7. **Nobody looks.** A reconstruction with no destination is a log that rots. *Mitigation:* the Recap
   sheet and the standup-copy button must ship **in the same slice** as the timeline. Capture without
   a retrieval moment is not a feature.

8. **Store growth** — addressed by §2.5, and the month-file split must land with the feature rather
   than after the first 10 MB snapshot makes cold start visible.

---

## 6. The smallest first slice

The dominant risk is #2, and it is a *measurement* question, not a design question. So the first
slice measures rather than builds.

### Slice 0 — the title probe (2–3 days)

A dev-only menu item runs the capture loop for one real working week and appends to a local
`probe.jsonl`, one line per activation: bundle ID, title **length**, which `TitleParser` matched,
which identifier tokens were extracted, and a SHA-256 of the title — **never the title**. Plus a
one-screen report:

> 1,240 activations across 22 applications. 71% of active minutes carried at least one identifier
> token. Top unmatched applications: Slack (title `Slack`, 14% of time), Preview, Messages.

**Kill criterion, decided in advance: if fewer than 50% of active-time minutes carry an identifier
token, the ambitious version of this is dead** and Lggr ships tier-0 app-mix blocks only, which is a
smaller and perfectly honest product. Cheap, fast, and it uses the actual user's actual work rather
than a fixture.

### Slice 1 — one day, one screen, zero permissions (1 week)

- Capture at **tier 0 only**: `NSWorkspace` activations, backdated idle, sleep/lock, heartbeat.
- The **full five-stage pipeline** in `LggrKit`, with the evidence bag reduced to `{bundleID}` and
  satellite groups. Every stage unit-tested against three hand-built fixture days.
- Exactly **one** new UI surface: the Recap sheet for *today*, on ⌘R.
- No settings, no rules UI, no store changes — one day of events fits in memory.

**The proof test, run for five days:** each morning, before opening Lggr, write down from memory what
you did yesterday, in blocks. Then open Recap and score three things: **(a)** blocks the app found
that you had forgotten; **(b)** blocks it invented that did not happen; **(c)** would you have sent
the standup note unedited?

**Proceed only if (a) ≥ 1 per day and (b) ≈ 0.** If (a) is zero, memory is sufficient and this feature
is solving a problem the user does not have. If (b) is non-zero, the segmenter is confabulating and
must be fixed before a single window title is ever read — because at tier 0 there is nothing to blame
but the algorithm, and that is exactly the diagnostic you want.

Only then: Accessibility, `TitleParser`, project signatures, the month-file store split, and the
two-tier retention.

---

## Adversarial review

> Hostile pass. Every objection below is meant to be actionable: it names the call, the line, or the
> number that is wrong. Verified against the macOS 26.1 SDK headers on this machine where the claim
> was checkable.

### 1. Technical impossibility — the named APIs

**1.1 `NSWorkspace.screensDidLockNotification` and `screensDidUnlockNotification` do not exist.**
§2.2's sleep/lock row lists six `NSWorkspace` notifications; two of them are invented. Verified in
`MacOSX26.1.sdk/.../AppKit.framework/Headers/NSWorkspace.h`: the complete power/session set is
`WillPowerOff`, `WillSleep`, `DidWake`, `ScreensDidSleep`, `ScreensDidWake`,
`SessionDidBecomeActive`, `SessionDidResignActive`, `ActiveSpaceDidChange`. There is no lock
notification in AppKit at any version. Screen lock is only observable via
`DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"))`
— an undocumented, unentitled, historically-stable-but-unsupported string. `Gap.Kind.locked` is
therefore built on an SPI. Either adopt the distributed notification and say so in the doc with the
risk stated, or delete `.locked` and fold it into `.displaySleep`.

**1.2 `AXObserver` cannot be registered "off the main actor" as written.** §5's mitigation says AX
reads happen "off the main actor," and §2.2 registers `AXObserverCreate` +
`AXObserverAddNotification`. The SDK's own example (`AXUIElement.h:654`) is
`CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), kCFRunLoopDefaultMode)`.
Swift concurrency's cooperative thread pool has **no CFRunLoop**, and any run loop you do get is
never run. Registering an observer from inside an actor's `Task` compiles, returns
`kAXErrorSuccess`, and then silently never fires — the worst failure mode available. This needs
either a dedicated `Thread` running `CFRunLoopRun()` for the lifetime of the process, or observers
on the main run loop with the callback hopping off immediately. Pick one and write it down; the
current text describes a thing that does not work.

**1.3 The `AXObserver` is registered on the wrong element.** `kAXTitleChangedNotification` fired on
the *application* element does not deliver window title changes in most apps; the notification is
posted by the window element. Since the focused window changes constantly, the design is actually
"observe app for `kAXFocusedWindowChanged`, then tear down and re-register a second observer on the
new window element for `kAXTitleChanged`" — two observers, a re-registration on every window switch,
and a leak if teardown is missed. §2.2 describes it as one registration.

**1.4 Querying Chrome/Electron AX trees is not free and is not reversible.** Chromium and Electron
build their accessibility tree lazily and enable "accessibility mode" process-wide the first time an
assistive client touches the tree — and they do not turn it off. The §2.2 fallback ("a 20 s timer
while one app stays frontmost, common in Electron") means Lggr permanently puts Chrome, Slack, VS
Code, Notion and Figma into accessibility mode for the whole session. The cost lands in *their*
renderer processes, not ours, so it will not show up in Lggr's Energy Impact and will show up as
"Chrome got slower after I installed this." This must be measured in Slice 0, not assumed.

**1.5 Ad-hoc code signing invalidates every TCC grant on every build.** `CONSTRAINTS.md` ships via
`codesign --sign -`; `05-permissions.md` signs with `--options runtime`. TCC keys grants for
ad-hoc/unsigned binaries on the cdhash. Every rebuild is a new app to TCC: Accessibility drops,
every per-browser Automation grant drops, and the user re-approves. §4's claim that "the ask happens
exactly once, in onboarding" is false for the only build configuration this project can produce
today. This also silently breaks the Slice-0 probe and any multi-day dogfood. Fix: get a Developer
ID, or state plainly that permissions reset per build and design the probe around it.

**1.6 `kAudioDevicePropertyDeviceIsRunningSomewhere` does not mean "mic hot."** The property is
queried at `kAudioObjectPropertyScopeGlobal` on a *device*, not on the input scope. For any duplex
device — AirPods, most USB interfaces, Bluetooth headsets — playing music sets it. Meanwhile a
meeting on a non-default input (external mic while Built-in is default) is missed entirely. The
proposal makes `meetingTransition` an **∞-weight boundary**, so a single false positive from Spotify
through AirPods hard-splits an episode. Also: virtual audio devices (Krisp, Loopback, BlackHole) run
continuously and will report `true` all day. And `w_meeting = ∞` means one bad signal cannot be
outvoted by anything. Downgrade it from ∞ to a finite weight at minimum. See also §2.3 below for why
this signal should be deleted outright.

**1.7 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)` is the wrong state for a
multi-user Mac.** `CGEventSource.h` documents `kCGEventSourceStateCombinedSessionState` as the
combined table across login sessions. When another user is switched in and typing, Lggr's idle timer
never trips — so `.fastUserSwitched` and idle detection contradict each other, and Lggr records the
other user's activity as your continued presence in whatever app was frontmost. Gate idle evaluation
on `sessionDidResignActive`/`DidBecomeActive` explicitly, and say which state ID wins.

**1.8 Taking `min` over four event types under-detects input.** `.mouseMoved`, `.keyDown`,
`.scrollWheel`, `.leftMouseDown` misses modifier-only keys, right/other mouse buttons, tablet
proximity, gestures, and — importantly — `.keyUp`. `CGEventTypes.h` defines a constant for *any*
input event; use it. Four hand-picked types is a bug generator with no upside.

**1.9 The sandbox question is decided by this proposal and never stated.** The Accessibility read is
not available to a sandboxed process and Apple grants no entitlement for it to a non-MAS app —
`Resources/Lggr.entitlements` already disables the sandbox and says so. Fine, but this proposal is
the thing that makes that permanent, and it means Lggr can never ship on the Mac App Store and its
data directory has no container protection. `SPEC.md`'s "sandboxed where practical" is being answered
"never" by a document that does not mention the sandbox once. Say it out loud in §4.

**1.10 FoundationModels is real but wrong here.** The framework exists in this SDK
(`FoundationModels.framework`, macOS 26). The objection is not availability, it is that a
`LanguageModelSession` is **non-deterministic**, and §2.4 promises "a timeline that silently rewrites
its own past is not evidence" plus sealed, immutable days. An LLM-generated label cannot be
reproduced by a snapshot test, cannot be re-derived after a rebuild, and will differ between two runs
over identical evidence. It also only exists for users on macOS 26 + Apple Silicon + Apple
Intelligence enabled + a supported region — while the project's deployment target is macOS 14. That
is a feature for exactly one kind of user, which §5 of this review flags separately.

**Correct in the proposal, for the record:** `CGWindowListCopyWindowInfo`/`kCGWindowName` requiring
Screen Recording, no public browser-URL API, `AXUIElementSetMessagingTimeout` (confirmed at
`AXUIElement.h:402`), `kAXTitleChangedNotification` / `kAXFocusedWindowChangedNotification` as
constants, and the `AXIsProcessTrusted` vs `AXIsProcessTrustedWithOptions` split.

---

### 2. Creepiness

**2.1 This builds a better browsing history than the browser, and stores it in plaintext.** §2.2
captures browser *window titles* — required, because §2.3's GitHub parser reads
`Fix receipt dedup by luisdoriz · Pull Request #482 · acme/sor` out of the title. A window title in
a browser is the page `<title>`. So Lggr persists, for 30 days, the title of every page that held
focus: `Salesforce: Acme Corp — Opportunity #4412`, `Kaiser Permanente — Your test results`,
`Divorce lawyer San Jose — Google Search`, `Greenhouse — Interview: Senior Engineer`. The prompt's
own rule applies exactly: a window title containing a customer name **is a customer record**, and
`SPEC.md` §4's ban on document contents and email contents is defeated by subject lines. Mail's
window title is the message subject. Messages' window title is the person. Zoom's is the meeting
topic plus, often, the other party. This is not an edge case; it is the median title.

And it lands in `~/Library/Application Support/Lggr/Activity/YYYY-MM.json` — unsandboxed (1.9),
unencrypted, no container, readable by every process the user runs and every script they `curl |
bash`. Safari's history is behind Full Disk Access. Chrome's is a locked SQLite file. Lggr's copy is
`cat`-able. That is a net *reduction* in the user's privacy posture, delivered by a privacy-first
app.

*Actionable:* ship a **default deny list** (Mail, Messages, Notes, 1Password, Keychain Access,
Preview, Photos, Calendar, Contacts, FaceTime, Books, Health-adjacent apps) with titles never read,
not merely user-configurable exclusions. Make browser title capture separately opt-in from
Accessibility. Consider storing the evidence tier encrypted at rest, or storing only extracted
identifier tokens and never the title string.

**2.2 The retention model is inverted from what §2.5 claims.** "The evidence expires, the
reconstruction persists" sounds privacy-correct and is the opposite. The `Episode.label` is the most
human-legible, most quotable string in the system — Stage 4 tier 2 explicitly names episodes from
**document titles** and Slack channels. So `Q3 Layoff Plan` and `#incident-payroll-breach` become
permanent Episode labels, kept forever, while the auditable evidence that would let anyone contest
them is deleted at 30 days. The sensitive string survives; the context dies. *Actionable:* labels
derived below `.confirmed` confidence must expire with their evidence and degrade to the tier-4
app-mix name, or the user must be able to see and bulk-scrub labels.

**2.3 Mic-hot detection is the line.** A permanent, per-minute record of when this person was on a
call — every day, forever, in a file a colleague could read over their shoulder — is not
reconstruction. It captures the 1:1 where they were told they were being managed out, the therapy
appointment, the recruiter call, the call to a parent's hospital. A reasonable engineer seeing
`13:10–13:52 · mic active` on a colleague's screen would be uncomfortable, and would be right. It
also buys very little: §4 already concedes meetings can be detected from the frontmost bundle ID.
*Actionable:* delete the CoreAudio signal. It is the single creepiest thing in the document and it is
the most easily removed.

**2.4 `evidenceEventIDs` after pruning.** Episodes keep `[UUID]` forever; `ActivityEvent`s are pruned
at 30 days. §3.1 stakes the entire credibility argument on ⓘ — "a block a user can audit is a block
a user believes; a block they cannot audit is a claim." That mechanism has a 30-day fuse, after which
every historical episode is, by the document's own definition, a claim. Nothing in §2.5 or §3.1
addresses what ⓘ shows on day 31.

**2.5 `Copy standup note` makes Lggr coercible.** The moment a machine-generated prose account of
someone's day exists as one button, a manager can ask for it, and "I don't use that feature" stops
being available. `SPEC.md` principle 3 protects the user from the app; nothing here protects the user
from their org. This is not a reason to kill the feature — it is a reason not to make the output look
like a report, and to keep the copy first-person and editable rather than authoritative.

**2.6 Gap buttons are a bathroom-break log.** `10:12–10:40 Away · display asleep` with three
attribution buttons is, in aggregate over a year, a record of when this person was not at their desk.
Rendering it as an unanswered prompt, every day, invites them to justify it.

---

### 3. Battery, CPU, correctness

**3.1 The 60-second heartbeat is a disk write loop.** `JSONFileStore` writes the whole snapshot
atomically. If `lastHeartbeatAt` lives in it, that is 1,440 full-snapshot serialise + write + rename
cycles per day, growing with the file. `REVIEW.md` already flagged snapshot encode cost against R10.
*Actionable:* heartbeat goes to its own 40-byte file, or to `UserDefaults`, never to the snapshot.

**3.2 Two 15-second repeating timers defeat timer coalescing.** Idle poll and mic poll on 15 s with
no `tolerance` wake the CPU 5,760 times a day between them and prevent deep idle residency. Set
`tolerance` to at least 20% and merge the two polls into one timer. Deleting the mic poll (2.3)
removes half the problem for free.

**3.3 Sleep/wake breaks backdated idle.** On wake, `secondsSinceLastEventType` returns a value that
*includes the sleep duration*. `T − S` then lands before `willSleepNotification` fired, producing an
idle interval that overlaps or precedes the `.systemSleep` gap — negative-length intervals, or two
gaps claiming the same minutes. §2.2 specifies backdating and specifies sleep gaps and never
reconciles them. *Actionable:* clamp `T − S` to `max(T − S, lastWakeAt)` and state the precedence.

**3.4 `.systemSleep` and `.appNotRunning` collide every single night.** The heartbeat stops during
sleep, so on every morning launch `now − lastHeartbeatAt > 120 s` is true and §2.2 inserts
`Gap(.appNotRunning)` for the whole night — including for a machine that merely slept with Lggr
running fine. The "honesty mechanism" mislabels the most common event in the corpus. Precedence rules
between the two kinds are undefined. This is a slice-1 bug, and slice 1 is where the heartbeat is
declared non-negotiable.

**3.5 Spaces and multiple displays produce no events.** `NSWorkspaceActiveSpaceDidChangeNotification`
exists and is not used. Moving from a coding Space to a Slack Space *without* changing frontmost app
(possible with per-display Spaces) yields no boundary at all. With two displays, "frontmost app" is a
single value while the user watches a build log on the second screen; §2.3's glance collapsing then
deletes the switches that would have revealed it.

**3.6 Timezone / DST versus sealed days.** `01-product.md` already routes day boundaries through
`Calendar.dateInterval(of:for:)`, good. But a `DayTimeline` sealed at 04:00 in Berlin and then read
in San Francisco covers a different set of wall-clock hours than the recomputed day window, so
episodes fall outside their own sealed `day` interval, and adjacent sealed days overlap or gap.
Nothing in §2.4 says whether the seal is authoritative or the calendar is. Pick one and add a
travel-day fixture.

**3.7 "Microseconds of work" is wrong.** §2.4 recomputes the open episode on every event over a
trailing 30-minute window. That window holds ~50–100 normalised intervals; Stage 1 tokenises titles,
Stage 2 computes Jaccard over 5-minute evidence bags at every adjacency, Stage 3 iterates to a fixed
point. That is milliseconds, allocating, on every one of ~600 daily activations, and it feeds a menu
bar label — i.e. it will be on or adjacent to the main actor. Cache the tokenisation per event, debounce
the recompute to ~2 s, and measure it.

**3.8 The volume estimate is 3–10× low, and the Episode size estimate omits its largest field.** §2.5
assumes 150 `ActivityEvent`/day. But §2.2 emits an event on every **title change** — an Xcode user
switching files, a browser user switching tabs, and a 20-second polling fallback for every Electron
app. Realistic is 500–1,500/day, i.e. 35–110 MB/year, not 11 MB. Separately, "Episode ≈ 250 B" ignores
`evidenceEventIDs: [UUID]`: at 150 events/day across 12 episodes that is ~5 KB/day, ~1.3 MB/year — and
at the realistic event rate, ~10 MB/year. The "less than a photo" claim does not survive its own
capture design. *Actionable:* store an evidence *interval range* plus a count, not a UUID list.

**3.9 Glance collapsing silently changes an already-shipped metric.** `SPEC.md` §3 and §9 require
context-switch counts. After Stage 0, a `<8 s` return-visit is no longer a switch. Today's tile and
Recap will now report different switch counts for the same day, and §3.5's proposed observation
*"blocks containing Slack averaged 11 minutes"* is computed over data from which short Slack visits
were deliberately removed. Define one canonical context-switch definition and apply it in both
places.

---

### 4. Being wrong

**4.1 Cold start guarantees over-assignment.** Stage 5 assigns when `top ≥ minScore && top ≥ 1.5 ×
runnerUp`. A new user has one project. `runnerUp = 0`, so the margin test passes trivially and
*everything* with any matching token gets assigned to the only project that exists. `minScore` is
never given a value. The "refusing to guess is a feature" property is exactly backwards during the
first two weeks, which is when trust is decided. *Actionable:* require `runnerUp` to exist, or use an
absolute margin, and specify `minScore`.

**4.2 The correction loop trains on its own output.** §3.3 pre-fills a new session's project **and
intended outcome** from the inferred episode, one keystroke, no typing. §2.5 then treats "every
explicit session for project P" as *confirmed evidence* that donates identifiers to P's signature.
So the inference generates a suggestion, the user accepts it with ⌘⏎ without reading, and the system
records that acceptance as ground truth and increases its own confidence. This is not a training
loop, it is a feedback loop, and it will lock in early mistakes precisely because the interaction is
designed to be frictionless. *Actionable:* only sessions where the user *changed* the pre-filled
project, or created the session cold, may donate to the signature. Accepting a suggestion must be
worth strictly less than authoring one.

**4.3 A wrong auto-summary is much worse than a blank one, and this pipeline aims it at the
accomplishment log.** §3.4 feeds evidence into `SessionSummaryBuilder`, and `SPEC.md` §10 says
accomplishments can be generated from completed sessions and exported to Markdown for Friday. The
failure chain is: mis-segmented episode → wrong PR number → "Opened the receipt deduplication PR" →
accepted without reading → exported to a manager. A blank summary costs 20 seconds of typing. A
fabricated accomplishment in a performance-review artifact costs credibility that cannot be
recovered, and the user will not know it happened. *Actionable:* summaries may state **durations and
app names** (facts Lggr observed) but must never assert an **outcome** ("opened", "reviewed",
"resolved") from inference. Tangible result stays human-authored, always.

**4.4 Undo cost is not designed.** Renaming, re-projecting, splitting or merging an episode is
described but never costed. `isUserEdited` says "never re-derived after," and §2.4 offers *Rebuild
this day* — the interaction between them is undefined. Does Rebuild destroy edits? If yes, a user who
fixed 8 of 12 blocks loses that work; if no, a rebuild produces a chimera of new and stale blocks.
Also: fixing a mis-trained signature requires correcting N episodes across M days with no bulk
operation and no "forget what you learned from this."

**4.5 The kill criteria are not measurable at the sample size proposed.** Slice 1's gate is "(b) ≈ 0"
— invented blocks — over five days, one user, ~50 blocks. A 4% confabulation rate (two bad blocks a
month, easily enough to destroy trust per §5.1) is indistinguishable from zero at n=50. The gate as
written will pass a system that fails in the field. *Actionable:* score every block, report the count
and the denominator, and set the bar as "zero invented blocks in ≥150 scored blocks" — which means
running the probe for three weeks, not five days.

**4.6 Idle threshold false positives are the largest source of fiction, not the smallest.** 180 s of
input silence is: reading a design doc, reading a long PR, watching a build, thinking, or being on a
call with the laptop untouched. Backdating (correctly) then *retroactively deletes* those three
minutes from the app the user was genuinely reading in. §2.2 sells backdating as the fix for
over-attribution; it is simultaneously a new source of under-attribution during exactly the deep-work
the product exists to make visible. At minimum, suppress idle while a video-conference or
document-reader bundle is frontmost, and surface idle-derived gaps as `.idle` rather than deleting
time.

---

### 5. Product principle violations

**5.1 "Longest unbroken stretch 1h 25m" is a personal record.** `SPEC.md`'s design direction bans
gamification, streaks and productivity scores. A daily maximum, displayed in the footer of the daily
recap, is a high score. It goes down on bad days. The banned-word test in §3.5 protects the prose and
does nothing about the number. Same for `6h 12m tracked` as a headline figure — it invites comparison
against yesterday, which is what a score is. *Actionable:* drop "longest unbroken stretch" from the
footer entirely; if it must exist, put it in Weekly Review as a distribution, not a maximum.

**5.2 Gap attribution is added manual entry.** Three buttons × ~3 gaps × every day. §2.1's comment
says "they never have to," but the UI presents unanswered gaps daily until dismissed, which is the
definition of a nag. `SPEC.md` principle 2 is "minimal manual data entry." *Actionable:* attribute
gaps automatically where possible (display asleep + >20 min ⇒ away; no buttons), and ask at most once
per day, in Recap only, for the single largest gap.

**5.3 FoundationModels is AI where a rule would do, for a user base of one.** Its only job is naming
a block that already has a perfectly good rule-based name ("Xcode, Terminal") — which §4 concedes is
`SPEC.md` §7's own worked example, i.e. the shipped, spec-endorsed answer. In exchange it costs:
non-determinism (1.10), a settings toggle, a code path that cannot be tested on CI, and availability
gated on macOS 26 + Apple Silicon + Apple Intelligence enabled + supported region, against a macOS 14
deployment target. *Actionable:* cut it from this proposal entirely. It can be a separate document
later if tier-4 names prove to be a real complaint, which nobody has evidence for yet.

**5.4 The whole title-parsing thesis is tuned for one persona, and it is not the persona `SPEC.md`
names first.** The `TitleParser` table is Xcode, Terminal, GitHub, Linear/Jira, Slack, Notion/Figma —
an IC engineer at a company that uses Linear. `SPEC.md`'s stated audience is "engineering managers,
developers, and knowledge workers." An engineering manager's day is Gmail, Google Docs, Calendar,
Zoom and Slack; of those, only Slack has a parser, and §5.2 already admits Slack's titles are the
worst in the corpus. So tier 1's "~85%" is the author's own workflow, and the manager — the person
who most needs "where did my week go" — stays at tier 0 forever. *Actionable:* Slice 0's report must
break down identifier coverage **by persona**, and the kill criterion must be evaluated on a
non-engineer's week too, or the doc must narrow its claimed audience to ICs and say so.

**5.5 The percentages in §4 are fabricated.** "~55%", "~85%", "~95%" are presented as engineering
facts in a table, in a document whose own §6 exists because nobody knows the title coverage rate yet.
Delete them or mark them explicitly as hypotheses to be replaced by Slice 0's measurement.

**5.6 Permission nagging is structurally guaranteed by 1.5.** "At most once ever" cannot hold when
every rebuild is a new app to TCC. `SPEC.md`'s "never repeatedly nag" will be violated in practice
for the entire dogfood period, and for real users on any update that changes the signature.

---

### Verdict

**KEEP WITH CHANGES** — the core bet (`[ActivityEvent] → [Episode]`, a tier-0 floor that works with
zero permissions, the heartbeat honesty gap, refusing to assign below a margin, and a Slice 0 that
measures before it builds) is sound and is the right shape for this product; but it does not survive
as written without: deleting the mic-hot signal and the FoundationModels naming path, shipping a
default-deny list so Mail/Messages/browser titles are never captured rather than merely excludable,
making Episode labels expire with the evidence that justifies them, breaking the
suggestion→acceptance→training feedback loop in Stage 5, and fixing the four concrete API errors
(no `screensDidLock` notification, `AXObserver` with no run loop, observer on the wrong element,
`combinedSessionState` under fast user switching) plus the nightly `.systemSleep` / `.appNotRunning`
collision.
