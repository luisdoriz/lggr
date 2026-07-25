# Lggr — The Evidence Engine

> **Lens: the invisible work of a manager.** A proposal for the automatic intelligence layer, written
> against `SPEC.md` §4/§5/§6/§9, `CONSTRAINTS.md`, and `DESIGN.md` §5–6. Everything here is local,
> Apple-frameworks-only, and rule-based before it is anything else.
>
> Where this proposal contradicts an existing decision in `DESIGN.md`, it says so explicitly and
> gives the cost. There is exactly one such contradiction (EventKit, §4.4).

---

## 1. The core bet

An engineering manager's week is invisible for one specific, mechanical reason: **the work that
matters never gets declared.** Nobody starts a 50-minute focus session called "unblock Priya." The
review that mattered took nine minutes between two meetings. The incident started at 20:14 on a
Tuesday because someone paged, and by the time it was over nobody had opened a timer. Lggr today
records exactly the work its user was calm and organised enough to announce in advance — which is,
almost by definition, the work that was already visible. So the bet is an inversion: **make the
continuous ambient timeline the primary record and demote focus sessions to annotations on it**, then
run a deterministic extractor over that timeline whose output is not minutes-in-a-category but
*countable objects with names attached* — this pull request, this person, this ticket, this unplanned
96-minute Tuesday night. The unit of output stops being "3h 12m — Code review," which is a number
nobody can use, and becomes "reviewed nine pull requests across three repositories; 2h 04m of that
was with Omar." That second sentence is the one that goes in a promo packet, and no commit history
contains it. The whole proposal is a bet that **window titles, plus the shape of attention over time,
plus one boolean from the audio HAL, are sufficient to reconstruct that sentence without reading a
single word anyone wrote.**

---

## 2. The mechanism

### 2.0 Architectural inversion: ambient first

Today `ActivityTrackingService` is conceptually session-scoped. It must become continuous:

```
ActivityTrackingService   — always running while the app is running and tracking is not paused
      │  emits ActivitySample (non-Codable, main-actor, never persisted raw)
      ▼
PrivacyRedactor           — DESIGN §6.7.4, unchanged, still the only door to persistence
      ▼
EvidenceExtractor         — NEW. Pure. Turns a sample into typed Evidence, then DISCARDS the title.
      ▼
EpisodeBuilder            — NEW. Pure. Coalesces samples into Episodes.
      ▼
ShapeClassifier           — NEW. Pure. Scores each Episode against the person's own baseline.
      ▼
PersonRegistry            — NEW. Pure + a small alias store. Resolves handles to people.
      ▼
SupportLedger             — NEW. Pure. Weekly aggregation by person and by artifact.
```

Every box below `PrivacyRedactor` is a pure value-type transform in `LggrKit`. All of it compiles and
is unit-testable **today**, with no Xcode, no permissions, and no running app — which matters, because
it means the risky part of this proposal can be proved against a corpus before a single view changes.

A focus session becomes a *label applied to a span of the ambient timeline*, not a container for it.
`FocusSession` gains nothing; `Episode` gains `declaredSessionID: UUID?`.

Consequence for the menu bar (`DESIGN.md` §5.6): ambient recording needs its own visible state. The
idle icon changes from a static `timer` to `timer` with a subtle filled variant while ambient capture
is live, and the popover's first row becomes **Pause tracking** rather than burying it in Settings. If
the app is always watching, the user must be able to see that at a glance and stop it in one click.
This is not negotiable and it is the price of the inversion.

### 2.1 Zero-permission capture (Tier 0)

| Signal | API | Permission |
|---|---|---|
| Frontmost app changes | `NSWorkspace.shared.notificationCenter` → `didActivateApplicationNotification`, `NSRunningApplication.bundleIdentifier / .localizedName / .processIdentifier` | none |
| Which apps are even running | `NSWorkspace.shared.runningApplications` | none |
| App launch/quit | `didLaunchApplicationNotification`, `didTerminateApplicationNotification` | none |
| Time since last human input | `CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)` — returns *how long since*, never the event | none |
| Machine slept / display slept / screen locked | `NSWorkspace.willSleepNotification`, `.didWakeNotification`, `.screensDidSleepNotification`; `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` | none |
| **Microphone is in use somewhere on the system** | CoreAudio HAL property, §2.2 | **none** |
| Launch at login | `SMAppService.mainApp.register()` | none (a Login Items row, not a TCC prompt) |

Everything in Tier 0 is notification-driven, not polled. The only poll is the idle check, and it fires
on a 15 s coalesced timer that is suspended while the screen is locked or the machine is asleep.

### 2.2 Meeting detection without reading anything private

This is the piece that makes a manager's calendar-shaped week legible, and it works with **no TCC
permission of any kind**.

macOS exposes, as a plain CoreAudio HAL property, whether the default input device is currently
running for *somebody*. Reading it does not open an audio stream, does not require
`NSMicrophoneUsageDescription`, and never touches a sample buffer:

```swift
// Sources/LggrApp/Services/AudioActivityMonitor.swift   [NEW]
import CoreAudio

private var defaultInputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope:    kAudioObjectPropertyScopeGlobal,
    mElement:  kAudioObjectPropertyElementMain)

private var runningSomewhereAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
    mScope:    kAudioObjectPropertyScopeGlobal,
    mElement:  kAudioObjectPropertyElementMain)

// AudioObjectGetPropertyData(kAudioObjectSystemObject, &defaultInputAddress, …) -> AudioDeviceID
// AudioObjectGetPropertyData(deviceID,  &runningSomewhereAddress, …)            -> UInt32 (0/1)
// AudioObjectAddPropertyListenerBlock(deviceID, &runningSomewhereAddress, queue) { … }
```

It is event-driven via `AudioObjectAddPropertyListenerBlock`, so there is no polling cost. A second
listener on `kAudioHardwarePropertyDefaultInputDevice` handles the user plugging in headphones
mid-call.

**What it is not.** It is a single boolean about one device. It does not say *which* process, and it
is true for dictation, Voice Memos, a game with voice chat, and any app that merely holds the device
open. It is therefore never used alone. `MeetingDetector` requires a **conjunction**:

```
micRunning  AND  (a known conferencing bundle is running OR a conferencing domain is frontmost)
            AND  duration >= 4 minutes
            → EpisodeKind.meeting, confidence .high
micRunning  AND  none of the above                     → confidence .low, never asserted
```

The conferencing set is *data*, not code — a shipped, user-editable list in the Rules screen:
`us.zoom.xos`, `com.microsoft.teams2`, `com.hnc.Discord`, `com.tinyspeck.slackmacgap` (huddles),
`com.apple.FaceTime`, plus domains `meet.google.com`, `teams.microsoft.com`, `zoom.us`, `whereby.com`.

**Camera is a secondary, optional signal**, via `CMIOObjectGetPropertyData` with
`kCMIODevicePropertyDeviceIsRunningSomewhere` over the CoreMediaIO device list. It also needs no
permission, but Apple has been progressively hardening the DAL/CMIO plug-in surface and I would not
build a feature on it. Implement it behind a flag, measure it on macOS 14 and 26, and drop it if it is
unreliable. The mic signal alone is sufficient.

**The bug this fixes, which is currently latent.** `CGEventSource.secondsSinceLastEventType` reports a
manager sitting in a 50-minute meeting as idle, because listening involves no keystrokes. As Lggr is
designed today, the single largest block of an EM's week would be discarded as idle time by our own
code. That is the invisible-work failure mode caused from the inside. So:

```swift
// IdleEvaluator, LggrKit — pure, unit-tested
// Idle is suppressed while a meeting is detected. "At my desk, not typing, in a meeting"
// is not the same state as "away", and only one of them should stop the clock.
if meetingDetected { return .activeListening }
if screenLocked || machineAsleep { return .away }
if secondsSinceInput > threshold { return .idle }
```

`ActivityState` gains a fourth case, `.activeListening`, which counts as tracked time, does not count
as focused time, and renders on the timeline as a distinct fill.

### 2.3 Evidence extraction: keep the PR number, not the PR

With Accessibility granted (`AXIsProcessTrusted()`), the existing `WindowTitleReader` returns the
focused window title via `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` →
`kAXTitleAttribute`, with the 0.25 s `AXUIElementSetMessagingTimeout` and the
`IsSecureEventInputEnabled()` skip already specified in `DESIGN.md` §6.1.1.

The change is what happens next. **The extractor becomes the only consumer of the raw title.**

```swift
// Sources/LggrKit/Domain/EvidenceExtractor.swift   [NEW]

public enum Evidence: Codable, Hashable, Sendable {
    case pullRequest(repo: String, number: Int, authorHandle: String?)
    case ticket(tracker: String, key: String)                    // ENG-1423, SUP-88
    case conversation(app: String, counterpart: Counterpart)     // .person("Omar Reyes") / .channel("#platform-oncall")
    case document(app: String, name: String)
    case meeting(provider: String)
    case repository(String)
}

public struct TitleGrammar: Codable, Sendable {
    public let id: String                 // "github.pull-request"
    public let bundleIdentifiers: Set<String>
    public let domains: Set<String>
    public let pattern: String            // NSRegularExpression, Foundation, no dependency
    public let captures: [String: Int]
    public let produces: EvidenceKind
    public let isEnabled: Bool
}

public enum EvidenceExtractor {
    /// The ONLY function permitted to receive a raw window title.
    /// Returns typed evidence. The title is not returned and never reaches the store.
    public static func extract(
        title: String, bundleIdentifier: String, domain: String?, grammars: [TitleGrammar]
    ) -> [Evidence]
}
```

Shipped grammars, all of them plain regexes over a string the app already had permission to read:

| Source | Title shape | Yields |
|---|---|---|
| GitHub (browser) | `Fix receipt dedup by omar-reyes · Pull Request #482 · acme/sor` | `.pullRequest(repo: "acme/sor", number: 482, authorHandle: "omar-reyes")` |
| GitLab (browser) | `Merge requests · acme/sor · !119` | `.pullRequest` |
| Slack | `Omar Reyes (DM) - Acme - Slack` / `#platform-oncall (Channel) - Acme - Slack` | `.conversation(.person)` / `.conversation(.channel)` |
| Linear | `ENG-1423 Duplicate commissions on ingest` | `.ticket(tracker: "linear", key: "ENG-1423")` |
| Jira | `[SUP-88] Customer cannot export` | `.ticket` |
| Xcode | `Lggr — EvidenceExtractor.swift` | `.repository("Lggr")` |
| Google Docs | `Ingestion architecture - Google Docs` | `.document` |
| Google Meet | `Meet - abc-defg-hij` | `.meeting(provider: "meet")` |

Six properties of this design that make it defensible rather than merely clever:

1. **The raw title is discarded by default.** `ActivitySample.rawTitle` is consumed by
   `EvidenceExtractor` inside the capture actor and is not carried into `ActivityEvent`. A new
   preference `storeRawWindowTitles` (default **off**) is the only way a title reaches disk. This is a
   *stricter* privacy posture than `DESIGN.md` §4.2.5 currently specifies. Lggr keeps the PR number,
   not the PR.
2. **Grammars are data, shipped as a versioned pack**, visible and editable in the Rules screen
   (⌘6), which already exists for `ClassificationRule`. When Slack changes its title format, this is a
   JSON edit, not a release.
3. **Fail closed to nothing.** A title that matches no grammar produces zero evidence and is dropped.
   There is no "best guess" path. A missing fact is recoverable; a wrong fact in a promo packet is not.
4. **Mail, Messages, Notes, 1Password and any app on the private/excluded lists are never passed to
   the extractor at all** — `PrivacyRedactor.mustNotInspect` already gates this *before* the AX call
   (`DESIGN.md` §6.7.4, mechanism 2). Mail and Messages are added to the shipped private-by-default
   list. Correspondence is not evidence.
5. **`kAXDocumentAttribute` is deliberately not read**, though it is available with the same
   permission and would give the file path of the focused document. A path is a directory tree of a
   person's life. The title is what SPEC §4 sanctions; we take exactly that.
6. **Deeper AX traversal is refused.** We read the focused window's title. We do not walk
   `kAXChildren`, we do not read `kAXFocusedUIElement`, we do not read text field values. That line —
   *the title of the window, and nothing inside the window* — is the whole difference between
   reconstruction and surveillance, and it is enforced by the existing `check-layering.sh` grep.

### 2.4 The people graph

```swift
// Sources/LggrKit/Model/Person.swift   [NEW]
public enum Handle: Codable, Hashable, Sendable {
    case slackDisplayName(String)     // "Omar Reyes"
    case gitForgeHandle(String)       // "omar-reyes"
    case email(String)                // from EventKit only
}

public struct Person: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var handles: Set<Handle>
    public var isConfirmedByUser: Bool
}

public struct Workstream: Identifiable, Codable, Hashable, Sendable {   // #platform-oncall
    public let id: UUID
    public var name: String
    public var handles: Set<Handle>
}
```

SPEC §9 asks for "people **or workstreams** unblocked." Both are first-class; a channel is a
workstream and is never coerced into a person.

**Resolution rules, deliberately conservative:**

- Within one handle kind, **exact case-insensitive match only**. `omar-reyes` is `omar-reyes`.
- Across handle kinds, **never automatic**. `Omar Reyes` (Slack) and `omar-reyes` (GitHub) are two
  people until the user says otherwise, or until EventKit supplies an authoritative
  name↔email binding (§4.4) and the email local-part matches — and even then it is *suggested*, with a
  one-key confirm, never applied silently.
- **No fuzzy matching, no edit distance, no nickname tables.** A wrong merge produces a false claim
  about a named colleague inside a document the user will paste into a performance review. The
  expected cost of a wrong merge is unbounded; the cost of a missed merge is one keystroke.
- The merge affordance is a single row in the weekly review: `Omar Reyes and omar-reyes — same
  person?  [ Yes ⏎ ] [ No ]`. Asked once, remembered forever, reversible in Settings.

### 2.5 Episodes: grouping attention into something a human recognises

```swift
// Sources/LggrKit/Domain/EpisodeBuilder.swift   [NEW]
public struct Episode: Identifiable, Codable, Sendable {
    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var declaredSessionID: UUID?          // nil == undeclared, the interesting case
    public var dominantEvidence: Evidence?
    public var evidence: [Evidence]
    public var applications: [String]
    public var interjections: Int                // short excursions absorbed, not breaks
    public var idleDuration: TimeInterval
    public var listeningDuration: TimeInterval
    public var kind: EpisodeKind                 // .focused .review .support .meeting .incidentCandidate .admin .unknown
    public var confidence: Confidence            // .high .medium .low
}
```

Boundary rules (pure, constant-driven, unit-tested):

- **Break** on: gap > idle threshold with no meeting detected; the dominant evidence *entity* changes
  (PR #482 → PR #491 is a break; scrolling within #482 is not); a declared session starts or ends; the
  episode exceeds 90 minutes.
- **Absorb** an excursion shorter than 90 s back into its host episode as an `interjection`. A 40-second
  Slack glance inside 25 minutes of Xcode is a context switch to be counted, not a row to be rendered.
  This is `SPEC.md` §7's "grouped intelligently rather than one row per application switch," made
  precise.
- Episodes shorter than 90 s are merged into their neighbour, matching the existing `ActivityCoalescer`
  contract in `DESIGN.md` §5.4.1.

### 2.6 Incident response, recognised by its shape

No permission is needed for any of this. The features are all Tier 0.

```swift
// Sources/LggrKit/Domain/ShapeClassifier.swift   [NEW]
public struct EpisodeShape: Sendable {
    public let isUndeclared: Bool          // no focus session covering it
    public let displacedASession: Bool     // a running session was abandoned within 120 s of its start
    public let switchRateZ: Double         // app activations/min vs the user's own 28-day baseline
    public let outsideActiveHours: Bool    // vs the user's own learned hour-of-week histogram
    public let appSetEntropy: Double       // low entropy = a tight recurring toolset
    public let duration: TimeInterval
    public let micActiveFraction: Double
    public let evidenceKinds: Set<EvidenceKind>
}
```

**Active hours are learned, never configured.** A rolling 28-day histogram of tracked activity by
hour-of-week; "outside active hours" means below the 10th percentile *of that user's own history*.
Somebody who genuinely works evenings never gets flagged for working an evening. This satisfies
principle 6 — zero new settings fields — and principle 3, because the baseline is descriptive rather
than normative.

The classifier is a scored rule table with constants in code, not a model:

```
incidentCandidate  =  isUndeclared
                   &  duration        > 20 * 60
                   &  (displacedASession | outsideActiveHours)
                   &  switchRateZ     > 1.5
                   &  appSetEntropy   < threshold      // the same 3–4 tools, over and over

supportWork        =  evidenceKinds ⊇ {.pullRequest}  or  .conversation(.person)
                   &  the counterpart is not the user

meeting            =  §2.2
```

It emits a **candidate with a confidence, never a fact.** Above the threshold, Lggr asks exactly one
question, once, later — never during the incident. Below it, the episode stays `.unknown` and is
counted only as tracked time. Nothing is ever silently labelled "incident" in a document the user will
show to their manager.

### 2.7 Where AI is allowed, and where it is not

`SPEC.md` §5 is explicit that the deterministic engine comes first. Everything in §2.0–2.6 is
deterministic. Apple Intelligence enters at exactly one point and it is the last one.

```swift
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
enum NarrativeWriter {
    static func rewrite(_ facts: WeeklyFacts) async -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable:            // deviceNotEligible / appleIntelligenceNotEnabled / modelNotReady
            return nil
        }
        let session = LanguageModelSession(instructions: """
            Rewrite these facts as plain past-tense sentences. Add nothing. Judge nothing. \
            Do not use any name or number that is not in the input.
            """)
        let out = try? await session.respond(to: facts.serialized, generating: Narrative.self)
        return out.flatMap { NarrativeValidator.accept($0, against: facts) }   // pure, in LggrKit
    }
}
#endif
```

Four constraints that make this safe rather than decorative:

1. **The model never sees a window title, a person's name in context, or any raw capture.** Its input
   is the already-computed `WeeklyFacts` struct — counts, durations, resolved display names. A
   hallucination can garble a sentence; it cannot invent an observation.
2. **`NarrativeValidator` is a pure `LggrKit` function that rejects the output** if it contains any
   capitalised token or numeral not present in the input fact set. Deterministic, unit-tested, and it
   fails to the template writer.
3. **`SessionSummaryBuilder` remains the product.** It ships, it is tested, and it is what runs on
   macOS 14. `FoundationModels` is macOS 26+ only, requires Apple Intelligence to be enabled on an
   eligible device, and is therefore unavailable to most of the deployment target. It is polish.
4. **No network.** `FoundationModels` `SystemLanguageModel.default` is the on-device model; there is
   no entitlement and no server. The `com.apple.security.network.client` = `false` entitlement stays
   exactly as it is, and remains a reviewable property of the build.

**Explicitly refused, and why, so nobody proposes them later:**

| Considered | Refused because |
|---|---|
| **Speech framework** (`SFSpeechRecognizer`) transcribing meeting audio | Needs `NSMicrophoneUsageDescription` and captures the *contents* of what people said. `SPEC.md` §4 forbids message contents; a transcript is the most complete form of them. Not a close call. |
| **ScreenCaptureKit** / `SCShareableContent` | Requires Screen Recording, which is pixel access to every window. `SPEC.md` §4 forbids screenshots. `DESIGN.md` §6.1.6 already refused this for window titles; it is refused again here. |
| `CGWindowListCopyWindowInfo(kCGWindowName)` for titles without Accessibility | Same permission (Screen Recording) since macOS 10.15. Trading a narrow permission for a broad one to get the same string. |
| `CGEvent.tapCreate` for real typing-intensity | Input Monitoring, and it is the literal definition of a keylogger. |
| Reading `~/Library/Calendars` directly to avoid the EventKit prompt | **This is not a loophole.** That path is TCC-protected with the same calendar authorisation. Attempting it gets a permission error, or worse, looks like evasion. Do not. |

---

## 3. What changes for the user

### 3.1 Today gains one new section: the day it didn't ask you about

Below the existing timeline, above the interruption inbox:

```
  Also today                                          3 undeclared blocks
  ──────────────────────────────────────────────────────────────────────
  10:04–10:31   Review           acme/sor #482, #479 · Omar Reyes        27m
  13:20–14:10   Meeting          Zoom · mic active                       50m
  20:14–21:40   Unplanned        Terminal, Slack, grafana.acme.com    1h 26m
                ┌────────────────────────────────────────────────────┐
                │ Nothing was declared for this block. It started     │
                │ outside your usual hours and moved between three    │
                │ tools 41 times.                                     │
                │ [ Incident ⏎ ]  [ Deep work ]  [ Not work ]  [ Skip ]│
                └────────────────────────────────────────────────────┘
```

Four buttons, one keystroke, and choosing **Incident** creates an
`Accomplishment(type: .incidentResolved)` pre-filled with the time range and the evidence. That is
minimal manual entry in the strict sense of principle 6: it *replaces* the five-field manual
accomplishment form with one keypress. The block is never labelled without the answer, and **Skip**
leaves it as neutral tracked time forever.

Note the copy. "Nothing was declared for this block" — not "you forgot to track this." "It started
outside your usual hours" — not "you worked late again." Every sentence is a fact about the record,
not a judgement about the person. `SPEC.md` bans shaming; the way you actually honour that is by never
writing a sentence whose subject is the user's character.

### 3.2 The Weekly Review gains the section this whole proposal exists for

Inserted after "Planned vs reactive," before "Accomplishments":

```
│  Work that leaves no trace                             5h 12m         │
│  ─────────────────────────────────────────────────────────────────── │
│  Reviewing and unblocking, across 23 separate occasions.             │
│                                                                       │
│  Omar Reyes         2h 04m    3 reviews · 2 conversations · 1 meeting │
│  Priya Raman        1h 18m    2 reviews · 3 conversations             │
│  #platform-oncall     58m     7 occasions                             │
│  Dani Okafor          32m     1 review · 1 meeting                    │
│  4 others             20m                                             │
│                                                                       │
│  9 pull requests reviewed — acme/sor (5), acme/ingest (3), acme/web   │
│  1 unplanned block, Tuesday 20:14–21:40, outside your usual hours     │
│  4h 30m in meetings, of which 2h 10m were with one other person       │
│                                                                       │
│  Every number here links to the minutes behind it.        [ Copy ⌘C ] │
```

Three deliberate choices in that block:

- **Ordering is by the user's time spent, and the column header says so.** This ledger is a record of
  *the manager's* work. It is never framed as a record of the report's neediness. There is no
  "Omar required 6 unblocks" anywhere, ever — that would turn a self-accounting tool into a
  surveillance tool pointed at people who never installed it. This is the single most important
  guardrail in the lens and it is a copy rule, enforced in review.
- **"Every number here links to the minutes behind it."** Clicking `2h 04m` opens the Focus Sessions
  list filtered to those episodes with their timestamps. A number in a promo packet that the user
  cannot defend in the conversation that follows is worse than no number. Provenance is a feature.
- **Numbers below a confidence floor are not shown, or are shown as a floor.** "9 pull requests
  reviewed" appears only when 9 distinct `.pullRequest` evidence items resolved. Otherwise: "at least
  6 pull requests reviewed." Under-claiming is the only acceptable failure direction.

### 3.3 The export, which is the actual deliverable

`ExportService` gains one block in the weekly Markdown, and one new command:
**Copy as evidence** (⌥⌘C), and **Copy evidence for…** ▸ a person, for a 1:1.

```markdown
## Work that doesn't appear in a commit history

Week of 21 July · 5h 12m across 23 separate occasions

- Reviewed 9 pull requests: acme/sor (5), acme/ingest (3), acme/web (1).
- Omar Reyes — 2h 04m over 6 occasions: 3 reviews, 2 direct conversations, 1 meeting.
- Priya Raman — 1h 18m over 5 occasions: 2 reviews, 3 direct conversations.
- #platform-oncall — 58m over 7 occasions.
- One unplanned block, Tuesday 20:14–21:40 (1h 26m), outside usual working hours,
  resolved as: duplicate commission ingestion.
- 4h 30m in meetings; 2h 10m of that was one-to-one.
- Declined 3 meetings totalling 2h 30m.
```

That is the paragraph an EM cannot currently write on a Friday afternoon, and it is assembled entirely
from a boolean off the audio HAL, a regex over a window title, and a clock.

### 3.4 Rules (⌘6) gains a second tab

`Classification` | **`Evidence`**. The grammar pack is listed, each row showing the last title it
matched *for that user, in this session only, never persisted* — so a user can see exactly what a
grammar extracts and disable it. A grammar can be disabled per-app or globally. The Slack grammar in
particular should be trivially killable by anyone who is uncomfortable with it.

---

## 4. Permissions, and what the app is without them

### 4.1 The ladder

| Tier | Permission | Buys | What it costs |
|---|---|---|---|
| **0** | **none** | Episodes; declared vs undeclared; context-switch bursts vs personal baseline; out-of-hours detection; **meeting blocks via the mic HAL boolean**; incident *candidates*; planned/reactive/committed split; `.activeListening` so meeting time stops being deleted as idle | nothing |
| **1** | **Accessibility** — `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions` | **Names.** PR numbers, repos, author handles, ticket keys, Slack counterparts. The entire people graph and the per-person ledger. This is where the 10x lives. | System-owned prompt, once per code identity; System Settings → Privacy & Security → Accessibility; incompatible with App Sandbox (already decided, `DESIGN.md` §6.2) |
| **2** | **Automation**, per browser — `AEDeterminePermissionToAutomateTarget` | Domain only. Distinguishes `github.com` from `youtube.com`. **Worth less than Tier 1 for this lens**, because the domain does not contain the PR number and the title does. | `NSAppleEventsUsageDescription` (its absence is a *crash*, not a denial) + `com.apple.security.automation.apple-events`; one prompt per browser |
| **3** | **Calendar** — EventKit, §4.4 | Meeting ground truth, attendee identities, 1:1 detection, declines, recurring load | A new TCC pane, an amended privacy story, §4.4 |
| **4** | **Apple Intelligence** (macOS 26+, no TCC) | Prose polish on already-computed facts | Availability, not permission |

Note the inversion at Tier 2. `DESIGN.md` implicitly ranks Automation above Accessibility in
onboarding order. For a manager, it is the reverse: browser *domains* are nearly worthless and browser
*titles* are the review graph. Onboarding order should change accordingly — Accessibility is the one
permission worth explaining well, and the other three can wait until the user has seen what Tier 1
produced.

### 4.2 What Tier 0 alone actually looks like

This matters, because principle 5 says useful with zero permissions. With every permission denied, the
weekly review still says:

```
│  Work that leaves no trace                             5h 12m         │
│  Time in Slack, GitHub and Zoom outside your declared sessions,       │
│  across 23 separate occasions.                                        │
│                                                                       │
│  Slack              2h 41m    14 occasions                            │
│  Chrome             1h 30m     6 occasions                            │
│  Zoom               1h 01m     3 occasions                            │
│                                                                       │
│  1 unplanned block, Tuesday 20:14–21:40, outside your usual hours     │
│  4h 30m with the microphone active alongside a conferencing app       │
```

Real, honest, and genuinely more than the app has today — the total is right, the shape is right, the
incident is found. It is anonymous, and that is the precise thing Accessibility buys. Under it, one
unobtrusive `.caption` line, no button, in the register `DESIGN.md` §5.4.1 already established:
"Window titles are off, so this is grouped by application." Stated once, per `DESIGN.md` §6.6's
re-ask policy. Never repeated.

### 4.3 The interaction with "never nag"

The permission-shaped moment is a *consequence*, not a prompt. When a weekly review is generated in
Tier 0, the section renders with its anonymous totals and a single line at the bottom:
`Turn on window titles to see which pull requests and which people this was.` One link. It appears on
the weekly review only, at most once per week, and disappears permanently after the second dismissal.
`AXIsProcessTrustedWithOptions(prompt:)` shows its system prompt at most once per code identity
anyway, so after `didRequestAccessibilityPrompt` is set the affordance must become **Open System
Settings**, per `DESIGN.md` §6.1.1 note 2.

### 4.4 EventKit: exactly what it buys, exactly what it costs

**This contradicts `DESIGN.md` §6.1.6, which states that Lggr should never appear in the Calendar pane
of System Settings.** I am proposing to amend it. The amendment must be made deliberately, because
that sentence is part of the app's claim about itself.

**API surface, precisely:**

| | |
|---|---|
| Framework | `import EventKit`; `EKEventStore()` |
| Status (never prompts) | `EKEventStore.authorizationStatus(for: .event)` → `.notDetermined` / `.restricted` / `.denied` / `.fullAccess` / `.writeOnly` (macOS 14 renamed `.authorized` → `.fullAccess`) |
| Request | `try await store.requestFullAccessToEvents()` — macOS 14+. `requestAccess(to:)` is deprecated. `requestWriteOnlyAccessToEvents()` exists and is **useless to us**; we need to read. |
| Info.plist | **`NSCalendarsFullAccessUsageDescription`** (macOS 14+). Without it the process is **killed by TCC** on first access, exactly as with `NSAppleEventsUsageDescription`. A crash, not a denial. |
| Entitlement | **None**, because Lggr ships unsandboxed with the hardened runtime. (If it were ever sandboxed: `com.apple.security.personal-information.calendars`.) |
| Read | `store.predicateForEvents(withStart:end:calendars:)` → `store.events(matching:)` |
| Refresh | `.EKEventStoreChanged` notification |
| Grant location | System Settings → Privacy & Security → Calendars → Lggr |

**What it buys, concretely:**

1. **Certainty instead of inference for meetings** — including audio-only calls, phone calls, and
   meetings the user attended from a room where the mic boolean says nothing.
2. **Attendees, which is the highest-value people signal in the entire proposal.**
   `EKEvent.attendees: [EKParticipant]?` gives `name` and, via `EKParticipant.url` (`mailto:`), an
   email address. That is the one *authoritative* name↔identity binding available anywhere on the
   machine, and it is what makes the Slack↔GitHub handle merge suggestion in §2.4 possible.
3. **1:1 detection** — exactly two participants including the user. An EM's 1:1s are the densest form
   of invisible work and they are trivially identifiable here and nearly impossible otherwise.
4. **Declines as evidence of prioritisation.** `EKParticipant.participantStatus == .declined` for
   `isCurrentUser` turns "I said no to 2h 30m of meetings to protect the ingestion work" into a line
   in the review. That is real managerial work with literally zero other trace.
5. **Recurring load.** `hasRecurrenceRules` separates "6h 40m/week of standing meetings" from ad-hoc.
6. **A third bucket for planned/reactive: `committed`** — calendar-bound time, which is neither.

**What it costs, stated honestly:**

- **There is no per-calendar TCC granularity.** Full access is full access: every event on every
  account, including personal calendars, medical appointments, and other people's shared calendars.
  App-side filtering to a user-selected calendar set is a *promise we keep*, not a wall the OS
  enforces, and the onboarding copy must say that in those words rather than implying otherwise.
- Lggr appears in a fourth Privacy pane, and the clean claim in `DESIGN.md` §6.1.6 — "no calendar,
  no contacts, nothing" — is gone.
- `attendees` is `nil` for many events. Local calendars carry none; some CalDAV configurations
  return only the organizer. `EKParticipant.name` is frequently `nil`, leaving only an email.
- Mitigations, all of which must ship together with the permission: read-only, never write; a
  calendar picker defaulting to **nothing selected** so the user opts in per calendar; a fixed
  trailing window (the current week plus 4 weeks back, matching retention); and a stored projection
  containing **start, end, attendee identities, participant status, isRecurring, isAllDay, and
  nothing else** — never `notes`, never `location`, never `url`, because those fields routinely
  contain dial-in numbers, passcodes and agendas.

**Without it, what the app does — three things, in order:**

1. **Tier 0 meeting detection still works** (§2.2). The user gets *when* and *how long* with high
   confidence. They lose *who* and *what*.
2. **One question recovers "who", at a cost of one keystroke.** The meeting block on Today shows
   `Who was this with?` with a chip row of the people already in the local registry — learned from
   Slack and GitHub titles at Tier 1 — plus a text field. Not a form; a row of names, arrow keys, ⏎.
3. **The `.ics` escape hatch, which needs no permission at all.** Settings → *Import calendar file…*
   opens an `NSOpenPanel` (a user-selected file needs no TCC and, if we were ever sandboxed, only
   `com.apple.security.files.user-selected.read-only`). Calendar.app and Google Calendar both export
   `.ics`. ICS is line-folded `KEY;PARAM:VALUE` text; a `VEVENT`/`ATTENDEE` parser is roughly 200
   lines of `LggrKit`, no dependency, fully unit-testable today under Command Line Tools. It is
   manual and it therefore bends principle 6, so it is the fallback, never the default — but it means
   a user who will never grant Calendar access can still get attendee-level attribution.

**Recommendation:** ship EventKit, opt-in, at Tier 3, **after** the Tier 0/1 work has proven itself.
Not in the first slice, and not in onboarding. The user should be asked for their calendar only after
Lggr has already shown them something they wanted.

---

## 5. What could make this fail

**1. Window titles are an undocumented, unversioned, app-controlled contract.**
Slack could ship a version whose title is just `Slack`. GitHub could restructure its `<title>`. There
is no API guarantee anywhere. If Slack's title loses the conversation name, the largest single source
of people-evidence dies overnight. Mitigations: grammars are shipped data, hot-editable without a
release; multiple grammars per app with fallbacks; and the extractor fails to *nothing* rather than to
garbage. But there is no mitigation for the underlying fact, and the honest thing to say is that this
is the load-bearing assumption of the whole proposal. **This is what the probe in §6 exists to test
before anything is built on it.**

**2. Entity resolution is the classic hard problem and the failure is asymmetric.**
`Omar` / `Omar Reyes` / `omar-reyes` / `oreyes@acme.com` / `O. Reyes`. §2.4 refuses fuzzy matching
precisely because a wrong merge puts a false statement about a named colleague into a promotion
document. The cost of that is not a bug report, it is the user never trusting the app again. The
consequence we accept is fragmentation: the ledger will sometimes show one human as two rows until
they are merged by hand.

**3. Credibility is binary and it is spent on the first wrong number.**
"You unblocked Omar 3 times" when it was once destroys the feature permanently, because the entire
value proposition is *evidence*. Design responses: every number links to its minutes; confidence
floors suppress or bound uncertain counts; under-claiming is the only permitted error direction; and
the app never asserts an episode kind it inferred — it asks.

**4. Always-on ambient capture is a genuine change in the app's privacy posture.**
Lggr goes from "records what you started" to "records everything while it runs." Even with the raw
title discarded, that is a different promise. Responses: pause is one click from the menu bar and the
icon shows recording state; ambient evidence gets a *shorter* default retention than sessions (28
days) with raw titles off by default and pruned at 7 days if ever enabled; Mail and Messages ship on
the private list; and the onboarding screen must lead with this rather than bury it. If this cannot be
made to feel comfortable, the feature is wrong regardless of how well it works.

**5. The ledger is a document about other people who never consented to it.**
A per-person breakdown of a manager's time is one framing away from a performance-surveillance tool.
§3.2's ordering-and-labelling rule is the guardrail; it is a copy convention, which means it will be
violated by accident unless it is written into the review checklist. Second-order risk worth naming:
the ledger also makes visible *who the manager did not help*, and a screen that renders that as an
absence would be exactly the shaming `SPEC.md` forbids. The section shows presence only. No zero rows,
no "you spent no time with…", ever.

**6. Out-of-hours detection can be quietly moralising.**
Flagging evening work as anomalous is a value judgement wearing a statistic's clothes. §2.6's learned
personal baseline is the mitigation, plus copy that reports rather than concerns itself: "outside your
usual hours," never "you worked late." The signal exists to *find the incident*, not to comment on the
schedule, and it is never surfaced on its own.

**7. The mic boolean is a proxy and proxies drift.**
It is device-scoped, not process-scoped. Bluetooth handoff, a virtual audio device, or an app holding
the input open idly all corrupt it. The conjunction in §2.2 handles the common cases; it will still
call a long dictation session a meeting occasionally. Also: `kAudioDevicePropertyDeviceIsRunningSomewhere`
being permission-free is stated here from knowledge of the HAL, not from a measurement on this machine
— it belongs in the CONSTRAINTS-style "verified by running it" category and **must be empirically
confirmed on macOS 14 and macOS 26 in the first hour of work**, before anything is designed on top of it.

**8. Cost and battery.** Everything is notification- or listener-driven except a 15 s coalesced idle
check that suspends on lock and sleep. AX is read once per app activation with a 0.25 s messaging
timeout, never on a timer, never retried. The one real risk is episode/ledger aggregation over a week
of ambient data, which `DESIGN.md` §5.4.1 already flags as the one place that can exceed 250 ms; it
runs off the main actor and the weekly review already has a documented loading state.

**9. `FoundationModels` availability will be low.** macOS 26+ only, Apple Intelligence enabled, eligible
hardware, model downloaded. Against a macOS 14 minimum this is a minority of installs. Which is fine,
because §2.7 makes it strictly cosmetic — but it means nobody should plan a feature that needs it.

---

## 6. The smallest first slice

The falsifiable claim underneath this entire document is narrow and testable:

> **Window titles alone, with no AI and no calendar, contain enough structure to name the people and
> the artifacts an engineering manager worked on during a week.**

Everything else follows if that is true and collapses to a modest improvement if it is false. So the
first slice tests that claim and builds nothing.

### Slice 0 — The Title Corpus Probe *(1–2 days, then 5 working days of waiting)*

A dev-only mode, `LGGR_PROBE=1`, active only in a local build. With Accessibility granted, it appends
one line per app activation to `~/Library/Application Support/Lggr/probe.jsonl`:

```json
{"t":"2026-07-24T10:04:11Z","bundle":"com.google.Chrome","title":"Fix receipt dedup by omar-reyes · Pull Request #482 · acme/sor"}
```

Nothing else. No UI, no store changes, no `ActivityEvent`, honours the private/excluded lists, and the
file is deleted at the end of the experiment. Run it for five working days on the target user's own
machine.

Then `Scripts/probe-report.swift` (plain `swift` script, runs under Command Line Tools) reports:

- % of foreground time whose title yields ≥1 evidence entity, broken down by app
- distinct pull requests, tickets, people and channels found
- the top 20 *unparsed* title shapes, which is the backlog for the grammar pack

**Kill criteria, agreed before the data arrives:**

| Result over 5 days | Decision |
|---|---|
| ≥ 8 distinct PRs **and** ≥ 3 distinct people **and** ≥ 35% of Slack/browser foreground time yields an entity | Proceed to Slice 1. The bet is live. |
| Entities found but people are unresolvable (handles only, no names) | Proceed **without** the per-person ledger. Ship the artifact ledger — "9 PRs across 3 repos" — which is still novel. |
| Below the floor | **The people-attribution bet is dead.** Keep §2.0 (ambient inversion), §2.2 (meeting detection), §2.5 (episodes) and §2.6 (incident shape) — all of which need no titles at all and are independently valuable — and drop the evidence graph entirely. |

That third row is the point of running the probe first: the fallback is not nothing, it is a smaller
but still real feature, and we find out in a week instead of a quarter.

### Slice 1 — `EvidenceExtractor` + `PersonRegistry`, pure, no app changes *(3–4 days)*

`Sources/LggrKit/Domain/EvidenceExtractor.swift`, `TitleGrammar.swift`, `Model/Person.swift`,
`Domain/PersonRegistry.swift`. The probe corpus becomes the test fixture set. Roughly 60 new tests on
top of the existing 152, all running under `swift test` with Command Line Tools, no Xcode, no
permissions, no UI. At the end of this slice the claim is *proved in code* and still zero users have
seen anything.

### Slice 2 — Ambient inversion + episodes + the one question *(1–1.5 weeks)*

`ActivityTrackingService` goes continuous; `AudioActivityMonitor`; `.activeListening`;
`EpisodeBuilder`; `ShapeClassifier`; the "Also today" strip in §3.1 with its four-button resolver;
menu bar recording state and one-click pause. This is the slice where the user first feels it, and it
is the slice that must not feel creepy.

### Slice 3 — `SupportLedger`, the weekly section, the export *(1 week)*

§3.2 and §3.3. The Markdown block is the deliverable. **Success is a single observable event: the user
pastes it into a 1:1 document without editing it.** If they edit it before pasting, the numbers are
not yet trustworthy and slice 3 is not done.

### Only then

EventKit (§4.4), the Rules → Evidence tab, and `FoundationModels` prose — in that order, each gated on
slice 3 having landed and been used for two consecutive weeks. Nothing in this document is worth
shipping before the paragraph in §3.3 is one somebody actually wanted to paste.

---

## Adversarial review

> Written against this document, `SPEC.md`, `CONSTRAINTS.md` and `DESIGN.md` as they stand on
> 2026-07-24. Hostile by assignment. Every objection below is meant to be actionable: it names the
> call, the line, or the constant that has to change. Section numbers in **bold** are the ones I
> think are load-bearing enough to block on.

---

### 0. Two framing errors before the five fronts

**0.1 "There is exactly one such contradiction (EventKit, §4.4)" is false.** There are at least
four, and the header claim should be corrected because it is the sentence that sets the reader's
guard down.

| # | The proposal | What `DESIGN.md` actually says |
|---|---|---|
| 1 | §4.4 EventKit | §6.1.6 — "Lggr should never appear in those panes." *Acknowledged.* |
| 2 | §2.2 mic HAL boolean | §6.1.6 lists **Microphone** in the same never-requested row, with the reason "No feature needs any of them." The proposal makes microphone state the *primary* meeting signal and the headline of the Tier 0 weekly review (§4.2: "4h 30m with the microphone active"). It stays out of the TCC pane on a technicality, and the technicality is precisely that no consent is ever collected. **Unacknowledged.** |
| 3 | §4.3 weekly permission line | §6.6 fixes the re-ask surfaces at exactly three: onboarding, the Settings toggle, one dismissible banner — "Never otherwise." §4.3 adds a fourth recurring surface plus a permanent `.caption` line on every weekly review. **Unacknowledged.** |
| 4 | §2.3 property 1 (`storeRawWindowTitles` default off) | §4.2.5/§6.7.4 build the whole redaction argument around `ActivitySample.rawTitle` reaching `PrivacyRedactor`. Making the extractor the sole consumer is *stricter* and good — but it is still a change to a settled mechanism, and §6.7.4's "four independent mechanisms" argument has to be re-derived, not assumed to carry over. **Unacknowledged.** |

**0.2 The document is 756 lines proposing seven new types, an architectural inversion, a new
permission tier and a new privacy posture — and the thing it is least specific about is the one
mechanism everything else depends on: when a sample is taken.** See §1.1 below. That is not a
detail; it invalidates Slice 0.

---

### 1. Technical impossibility

#### 1.1 ⛔ BLOCKER — Activation-driven sampling cannot see nine pull requests

`DESIGN.md` §5.4.1 / line 1600: *"Application tracking is event-driven (`AsyncSequence` over
`didActivateApplicationNotification`), not polled."* §2.3 of this proposal preserves that: AX is
*"read once per app activation ... never on a timer, never retried"* (§5.8).

`NSWorkspace.didActivateApplicationNotification` fires when the **frontmost application** changes.
It does not fire when:

- the user switches Chrome tabs (PR #482 → PR #491 → the Linear ticket → back);
- the user switches between two windows of the same app (`⌘\``);
- an SPA mutates `document.title` in place — which is exactly what GitHub, Linear and Slack all do,
  because they are single-page applications and *never navigate*;
- Slack switches channel or DM, which is the entire Slack grammar.

So the concrete failure is: a manager spends 40 minutes in Chrome reading nine pull requests and
Lggr captures **one** title — whichever PR happened to be focused at the moment Chrome came
forward. §2.5's boundary rule *"the dominant evidence entity changes (PR #482 → PR #491 is a
break)"* is unimplementable against a signal that never reports #491. §3.2's headline
"9 pull requests reviewed" and §3.3's "Reviewed 9 pull requests: acme/sor (5), acme/ingest (3)"
are arithmetic over samples that do not exist.

There are only three ways out and the proposal picks none of them:

1. **`AXObserver`** — `AXObserverCreate` + `AXObserverAddNotification` for
   `kAXFocusedWindowChangedNotification` and `kAXTitleChangedNotification`, one observer per
   observed process, added to the run loop. This is the correct API and it is *not mentioned once in
   756 lines*. It also has real costs: an observer per app, teardown on `didTerminateApplication`,
   and `kAXErrorCannotComplete` from apps that are busy. Budget it.
2. **Poll the focused title** on a timer while a title-bearing app is frontmost. Cheapest to build,
   directly contradicts §5.8's "never on a timer" battery claim, and re-opens the cost analysis.
3. **Accept that evidence is sampled, not enumerated** — and then delete every count from §3.2/§3.3
   and replace it with "at least N", permanently, not just below a confidence floor.

**And this invalidates Slice 0.** The probe (§6) appends *"one line per app activation."* It will
therefore under-count distinct PRs by roughly the ratio of in-app navigations to app switches —
plausibly 5–10× for a browser-heavy reviewer. The kill criterion is "≥ 8 distinct PRs over 5 days."
A probe built on activation sampling can fail that floor on a week in which the user genuinely
reviewed forty PRs, and §6's third row would then kill the correct hypothesis on bad instrumentation.
**Fix the probe's sampling before running it, or the pre-agreed kill criteria are worse than
useless — they are a decision procedure with a systematic bias in the fatal direction.**

#### 1.2 ⛔ BLOCKER — `IdleEvaluator` returns `.activeListening` for a sleeping machine

§2.2, verbatim:

```swift
if meetingDetected { return .activeListening }
if screenLocked || machineAsleep { return .away }
if secondsSinceInput > threshold { return .idle }
```

The meeting test precedes the lock/sleep test. `meetingDetected` is
`micRunning AND (a known conferencing bundle is running OR …)`. Both conjuncts survive a locked
screen and a closed lid:

- `kAudioDevicePropertyDeviceIsRunningSomewhere` is pinned `1` for as long as *any* process holds the
  input device open. Krisp, Loopback, BlackHole, Rogue Amoeba's ACE, Descript, SoundSource, and Zoom
  with "keep microphone active" all do this indefinitely, by design, with no call in progress.
- `NSWorkspace.shared.runningApplications` contains `us.zoom.xos` / `com.microsoft.teams2` /
  `com.tinyspeck.slackmacgap` from login to logout for essentially every engineering manager alive.

Therefore: user closes the lid on Friday at 18:00 with Krisp installed and Slack running; Lggr
records **62 continuous hours of `.activeListening`**, which §2.2 says "counts as tracked time," and
Monday's Today view shows a weekend. Reorder to `away → listening → idle` and gate `.activeListening`
on both a mic transition *edge* and a hard ceiling (no `.activeListening` run may exceed, say, 4h
without a HID event or an app activation). Note this is not a corner case: it is the default outcome
for anyone with a noise-suppression tool, which is most people who take calls.

#### 1.3 The §2.2 conjunction is `micRunning AND true`

Related to 1.2 but independent, and it is a plain logic error rather than an ordering one.
"a known conferencing bundle **is running**" is satisfied permanently. The conjunction as written
reduces to `micRunning AND duration ≥ 4min → EpisodeKind.meeting, confidence .high`. So:

- dictating a text message for five minutes → `.meeting`, high confidence;
- a personal FaceTime call at lunch → `.meeting`;
- a voice note in Voice Memos → `.meeting`;
- a game with voice chat → `.meeting`;
- Photo Booth, Audio Hijack, a mic test → `.meeting`.

§2.2 explicitly lists these as the false positives the conjunction exists to exclude, then writes a
conjunction that excludes none of them. The predicate has to be **frontmost or foreground-active**
conferencing app, not *running* — and even that mislabels a personal Zoom. Rewrite the rule and
re-derive the confidence label; `.high` is not defensible for any mic-derived inference.

#### 1.4 `kAudioDevicePropertyDeviceIsRunningSomewhere` on the **default input device** is the wrong device

Even granting that the property is permission-free (which §5.7 correctly flags as unverified — do
verify it, on macOS 14 *and* 26, before anything else), the proposal reads it on
`kAudioHardwarePropertyDefaultInputDevice`. Conferencing apps routinely do not use the default input:

- Zoom, Teams and Meet each have their own input-device picker, and users pin them to a headset;
- Zoom creates its own aggregate/virtual device (`ZoomAudioDevice`) in some configurations;
- Krisp/Loopback insert a *virtual* device that the app selects while the physical device stays default;
- a Bluetooth headset connecting mid-call changes the device out from under you — §2.2 handles the
  *default* changing, but not the case where the app's chosen device was never the default.

Net effect: **false negatives on the exact users who take the most calls** (headset users) and false
positives everywhere else. If this signal is kept at all it must enumerate
`kAudioHardwarePropertyDevices` and OR the property across all input-capable devices, which changes
the cost story (N listeners, re-established on `kAudioHardwarePropertyDevices` changes) and makes the
"one boolean from the audio HAL" framing in §1 inaccurate.

#### 1.5 `§2.7` does not compile on this machine, contrary to the doc's central architectural claim

`CONSTRAINTS.md` is explicit: the CLT plugin directory ships only `libObservationMacros.dylib`,
`libSwiftMacros.dylib` and `testing/libTestingMacros.dylib`. Any external macro plugin is a hard
compile error.

`session.respond(to:generating: Narrative.self)` requires `Narrative: Generable`. In practice
`Generable` conformance comes from the **`@Generable` macro** (and `@Guide`), which lives in
`FoundationModelsMacros`. That produces exactly the error CONSTRAINTS already documents for
`@Model`:

```
error: external macro implementation type 'FoundationModelsMacros.GenerableMacro' could not be
found for macro 'Generable()'; plugin for module 'FoundationModelsMacros' not found
```

`#if canImport(FoundationModels)` will not save you: `canImport` is evaluated against the **SDK**
(26.1 here), so it is `true`, and the file will be compiled. The correct guard is the
`LGGR_SWIFTDATA=1`-style conditional target pattern CONSTRAINTS already established, or hand-rolled
`Generable` conformance. Two smaller API errors in the same snippet:

- `respond(to:generating:)` returns `Response<Content>`, not `Content`. `out.flatMap { Narrative… }`
  is passing a `Response<Narrative>` where `NarrativeValidator.accept` expects a `Narrative`.
- `SystemLanguageModel.default.availability`'s `.unavailable` case carries an associated reason;
  `case .unavailable:` without binding is fine but the comment implies you are inspecting it.

#### 1.6 `CGEventType(rawValue: ~0)!` violates CONSTRAINTS rule 4, and changes a verified constant

Two things in one table cell (§2.1):

- **Force unwrap.** `CONSTRAINTS.md` rule 4: *"Avoid force unwraps (`!`) and `try!`."* Use
  `CGEventType(rawValue: ~0) ?? .null` with an explicit failure path, or the documented
  `kCGAnyInputEventType` value.
- **`.hidSystemState` vs `.combinedSessionState`.** `DESIGN.md` line 1218 specifies
  `HIDIdleDetector` polls `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`. The
  proposal silently substitutes `.hidSystemState`. These differ: `hidSystemState` counts only
  hardware HID events; `combinedSessionState` also counts synthesised events (Karabiner, Hammerspoon,
  Alfred, remote-control software, `cliclick`). Changing it changes idle behaviour for every user
  with a keyboard remapper. If the change is intentional, argue for it; if not, it is an unreviewed
  regression introduced by a design doc.

#### 1.7 Screen lock is conflated with display sleep, and fast user switching is absent

§2.1 offers `NSWorkspace.screensDidSleepNotification` and
`CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` for "screen locked."

- `screensDidSleepNotification` is **display sleep**, which is neither necessary nor sufficient for a
  lock. A user who locks with `⌃⌘Q` and keeps the display awake generates no such notification.
  The event-driven lock signal is `DistributedNotificationCenter` `com.apple.screenIsLocked` /
  `com.apple.screenIsUnlocked` — undocumented, but it is what every app in this category uses. Say so
  and take the risk explicitly rather than by omission.
- `CGSessionCopyCurrentDictionary()` returns `NULL` when the calling process is not attached to a GUI
  session, and its keys are `kCGSSessionScreenIsLockedKey` / `kCGSessionOnConsoleKey`. Under **fast
  user switching**, a Lggr instance running in a background session sees `onConsole == false` and
  will keep sampling `NSWorkspace` for a session that is not on screen. The proposal has zero words
  on fast user switching. The right notifications are
  `NSWorkspace.sessionDidResignActiveNotification` / `sessionDidBecomeActiveNotification`, and
  ambient capture must suspend on the former. Without this, two people sharing a Mac each get the
  other's meeting time.

#### 1.8 `SMAppService.mainApp.register()` is listed as Tier 0 "none," and is not verified on this build

`CONSTRAINTS.md` says the app is assembled by hand and **ad-hoc signed** (`codesign --sign -`).
`SMAppService.register()` for an ad-hoc-signed, non-notarised bundle outside `/Applications` commonly
throws `SMAppServiceErrorDomain` Code 1 ("Operation not permitted"), and the bundle is subject to
path randomisation/translocation. This may already be known-good in the existing app; if so, cite
where. If not, it does not belong in a table of things that cost "none."

#### 1.9 Things that silently return nothing, which the proposal treats as always working

- `AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, …)` returns `kAXErrorNoValue` for
  apps with no focused window (very common for menu-bar apps and for an app activated by `⌘Tab`
  before its window materialises) and `kAXErrorCannotComplete` for a busy/hung target. The proposal
  never says what an episode does with a run of empty titles; §2.3 property 3 ("fail closed to
  nothing") covers *unmatched* titles but not *absent* ones. They are different: absent titles should
  probably suppress the sample entirely rather than create an `.unknown` evidence-free segment that
  later gets counted as an "occasion."
- **Chromium and Electron.** Chrome's and Slack's full accessibility tree is built lazily and only
  when an AX client asks for it; some clients force it with the private `AXManualAccessibility` /
  `AXEnhancedUserInterface` attribute. Window *title* usually resolves without that, but you must
  verify per app, on the current versions, because the failure is silent — you get `nil` and log
  nothing. If it turns out titles need `AXEnhancedUserInterface`, note that setting it forces Chrome
  into full accessibility mode, a well-documented, large, *persistent* CPU and memory regression in a
  process Lggr does not own. That would be an unacceptable cost and needs to be checked before
  Slice 1, not discovered in Slice 2.
- `kAXTitleAttribute` on a Chrome window returns the **tab title with " - Google Chrome" appended**
  in some versions, the profile name appended in others, and is localised. Every grammar in the §2.3
  table is written against `en-US` and against one app version. `·` in GitHub's title is localised
  and reordered in RTL locales. The grammar pack needs a locale dimension or an explicit
  "English-only, by design" statement in the §5 risk list.

#### 1.10 CoreMediaIO camera signal — the proposal's own hedge is right, go further

`CMIOObjectGetPropertyData(kCMIODevicePropertyDeviceIsRunningSomewhere)` requires enumerating
`kCMIOHardwarePropertyDevices`, which historically loads DAL plug-ins into your process. The DAL
plug-in architecture is deprecated in favour of Core Media I/O extensions, and Apple has moved this
surface repeatedly. §2.2 already says "would not build a feature on it." Then don't build it behind a
flag either — a flag is a promise to maintain two code paths for a signal you have already decided is
untrustworthy. **Cut it from the proposal entirely** and reclaim the review budget.

#### 1.11 Actor story is contradictory

§2.0 says `ActivitySample` is *"non-Codable, main-actor."* §2.3 says the raw title is
*"consumed by `EvidenceExtractor` inside the capture actor."* Those are two different isolation
domains. Meanwhile `AudioObjectAddPropertyListenerBlock` delivers on a dispatch queue you supply, and
its handler needs `NSWorkspace.shared.runningApplications` (main-thread-affine in practice). Pick one
isolation domain, state it, and note that AX calls must **not** run on the main actor: a 0.25 s
`AXUIElementSetMessagingTimeout` against a beachballed target is a 250 ms main-thread stall *per app
activation*, and `⌘Tab`-heavy users activate apps hundreds of times an hour.

#### 1.12 What the proposal gets right, technically

Credit where due, so this section is not read as uniformly negative: the refusals table in §2.7 is
correct on every row. `CGWindowListCopyWindowInfo(kCGWindowName)` really does require Screen
Recording since 10.15; `SFSpeechRecognizer` really does need `NSMicrophoneUsageDescription`;
`~/Library/Calendars` really is TCC-protected and attempting it really does look like evasion. The
EventKit API surface in §4.4 is accurate — `requestFullAccessToEvents()`, the macOS 14
`.authorized` → `.fullAccess` rename, `NSCalendarsFullAccessUsageDescription` being a *crash* rather
than a denial, and no entitlement while unsandboxed. That table is the strongest technical writing in
the document.

---

### 2. Creepiness

#### 2.1 ⛔ The mic signal was chosen *because* it has no consent gate. That is the problem, not the feature.

§2.2's selling point, stated three times, is "**no TCC permission of any kind**." Read that back as a
user would: *Lggr knows, and records to disk, every minute your microphone was live — and it was
designed that way specifically so macOS would never ask you.*

The orange indicator dot exists because Apple decided mic activity is information the *user* is owed.
The proposal harvests the same fact for a third party, persists it (`Episode.micActiveFraction`,
`listeningDuration`), aggregates it into a weekly document, and renders it verbatim in §4.2:
"4h 30m with the microphone active alongside a conferencing app." That log includes the personal
call, the doctor's appointment taken from the home office, the therapy session, the recruiter call,
the argument with a landlord, the dictated resignation letter. Nothing in the proposal excludes any
of them, because the signal carries no process identity and the "conferencing bundle is running"
conjunct is permanently true (§1.3).

Would a reasonable engineer be uncomfortable if a colleague saw this on their screen? A row reading
`13:20–14:10 Meeting · mic active 50m` on a Tuesday when they took a personal call — yes, obviously,
and worse, they cannot explain it away because the app asserts it as a meeting.

**Minimum acceptable changes if this is kept:** (a) it must be surfaced in onboarding in the same
register as a permission, with a real off switch, even though macOS does not require one; (b)
`micActiveFraction` must not be persisted, only the derived boolean at episode granularity; (c) the
words "microphone" and "mic active" must never appear in a rendered summary or an export — §4.2 and
§3.1 both currently print them; (d) it must be defeasible after the fact from the Today strip.

My actual recommendation is stronger: **drop the mic signal and get meeting ground truth from
EventKit**, which is the permission the user can see, reason about, and revoke. §4.4 already argues
EventKit gives strictly better meeting data (audio-only calls, room-joined meetings, attendees, 1:1s,
declines). The proposal's ordering — build the consent-free proxy first, ask for the honest
permission at Tier 3 — is exactly backwards from a privacy standpoint. It optimises for shipping
speed at the cost of the one thing the product is selling.

#### 2.2 ⛔ `probe.jsonl` is the most invasive artifact in the entire plan and it is defended by one sentence

§6, Slice 0: five working days of **every window title of an engineering manager**, in plaintext
JSONL, in `~/Library/Application Support/Lggr/`. That single file contains, in practice: customer
names, candidate names in ATS tabs, `[SUP-88] Acme Corp cannot export`, salary-band spreadsheet
titles, `Termination memo — J. Smith - Google Docs`, `PIP draft — <report> - Google Docs`,
`Offer — <candidate> - Docs`, private Slack DM counterparties, the URL-derived titles of anything the
user looked at between tasks, and every personal browser tab title they opened during the working
day. It is not covered by the `storeRawWindowTitles` default-off protection, because the probe *is*
the exception.

Defences offered: "honours the private/excluded lists" and "the file is deleted at the end of the
experiment." Neither is sufficient.

- The private/excluded lists are **app-granular**. Mail and Messages get excluded. Chrome cannot be,
  because Chrome is the entire experiment. Every sensitive thing above arrives through Chrome.
- "Deleted" is `unlink`, not erasure, and in the interim the file is: backed up by Time Machine,
  synced if `~/Library/Application Support` is in a managed sync scope, indexed by Spotlight,
  readable by every process running as that user, and — on a corp-managed Mac, which is where
  engineering managers work — potentially collected by an EDR agent that ships file contents.
- No mention of file mode. `DESIGN.md` §6.8 goes to the trouble of setting explicit permissions on
  the store because the app is unsandboxed; the probe inherits nothing from that.

**Concrete fixes, all cheap:** write the file `0600` into a directory created `0700`; exclude it from
Time Machine via `NSURLIsExcludedFromBackupKey`; **hash or bucket by default** and record raw titles
only for bundle IDs the operator explicitly allowlists; make it self-expiring (refuse to append past
day 5 and delete on next launch, so a forgotten probe cannot run for a month); and overwrite before
unlink. Better still: run the probe against titles *already reduced by a candidate grammar*, logging
the extraction result plus a **redacted shape** of the unmatched title (`"Aa · Pull Request #NNN ·
aa/aa"`), which is all §6's "top 20 unparsed title shapes" analysis actually needs.

#### 2.3 `.document(app:name:)` and `.conversation(.channel(_))` are raw titles wearing a type

§2.3 property 1 asserts "Lggr keeps the PR number, not the PR." True of `.pullRequest` and `.ticket`,
which discard the free-text summary. Not true of two of the six `Evidence` cases:

| Case | Field | What it actually contains |
|---|---|---|
| `.document(app:name:)` | `name` | the whole document title, unbounded free text: `Acme Corp — MSA redlines`, `Q3 layoff planning`, `PIP — Dani Okafor`, `Series B model v7` |
| `.conversation(.channel(_))` | channel name | `#acme-corp-escalation`, `#incident-2026-07-payments-outage`, `#hiring-staff-eng`, `#legal-nda-review` |
| `.repository(_)` | name | usually fine; occasionally a client's name |

The prompt's own test applies: *a window title that contains a customer name is a customer record.*
`.document` and `.channel` will contain customer names, candidate names, and report names routinely,
and they are **persisted, aggregated, and exported to Markdown** (`#platform-oncall — 58m over 7
occasions` in §3.3 becomes `#acme-corp-escalation — 58m` in real life). This is a direct SPEC §4
problem arriving indirectly, which is precisely the failure mode the review was asked to look for.

**Fix:** `.document` must not ship in v1, or must store a stable hash plus the app, with the display
name held only in memory for the current session. `.channel` should be opt-in per channel, or
allowlist-only, exactly as §3.4 makes the Slack grammar killable — but killable-after-the-fact is
the wrong default when the thing already reached disk.

#### 2.4 "Copy evidence for… ▸ a person" is the surveillance affordance, and §5.5 already knows it

§5.5 correctly names the risk: *"The ledger is a document about other people who never consented to
it."* Then §3.3 ships a menu command whose entire purpose is to generate that document, per named
individual, on demand, formatted for pasting into a 1:1.

Everything else in the ledger is defensible as self-accounting — "here is where *my* time went, and
some of it went to Omar." `Copy evidence for Omar Reyes` is not that. It is a per-report dossier with
timestamps, and the only thing standing between it and a performance-management artifact is a **copy
convention enforced in code review** (§3.2, §5.5). Copy conventions do not survive contact with a
feature request from a user who wants "just a bit more detail for the review cycle."

**Cut the per-person export command.** Keep the per-person *rows* in the weekly review (they are the
manager's own time, ordered by the manager's own time, per §3.2's rule) and keep the drill-through to
minutes. If a manager wants to prepare for a 1:1, they can read the row. The moment it becomes a
one-keystroke shareable file about a named subordinate, Lggr has shipped the thing SPEC principle 3
forbids — and it did it in a menu item, not in the capture layer where everyone was looking.

Related, and specific: §3.3's export currently contains **another person's name and a time budget for
them** in a document the user is explicitly encouraged to paste into shared docs. `Omar Reyes — 2h 04m
over 6 occasions: 3 reviews, 2 direct conversations` in a promo packet reads to a skip-level as
"Omar needed 2 hours of my time," no matter how §3.2 orders the column. The guardrail in §3.2 governs
Lggr's UI; it does not govern the reader of the Markdown, and the Markdown is the product (§3.3).
Consider anonymising the export by default (`Engineer A — 2h 04m`) with a per-person reveal, or
exporting aggregate-only (`5h 12m supporting 4 engineers`) with names visible in-app only.

#### 2.5 The always-on inversion needs an affirmative moment, not a menu-bar icon variant

§2.0 changes the app from "records what you started" to "records everything while it runs," and
offers as compensation a *"subtle filled variant"* of the `timer` SF Symbol. §5.4 acknowledges this
is a genuine posture change and says onboarding "must lead with this."

A subtle fill variant is not perceptible. `DESIGN.md` §5.6 already defines the menu bar icon state
vocabulary; adding a fourth state that differs by fill weight will be indistinguishable at 16pt in a
crowded menu bar, in both light and dark mode, and is exactly the kind of thing that reads in a
retrospective as "we technically disclosed it." If ambient capture is on, the honest signal is a
**visibly different glyph** (or a tinted one), plus a first-run modal that the user has to
affirmatively accept, plus — the thing that actually builds trust — a "what Lggr recorded in the last
hour" inspector the user can open at any moment and see the literal rows. §3.4's Rules → Evidence tab
is a sketch of this; promote it to a first-class, always-available "show me what you have on me"
view, and make it the *first* thing onboarding demonstrates.

#### 2.6 §3.4's "last title it matched" renders a raw title on screen

Minor but real, and it contradicts §2.3's framing. If a user is screen-sharing (which managers do
constantly) and opens Rules → Evidence, the last matched title — potentially
`[SUP-88] Acme Corp cannot export` — is rendered to the whole call. Show the *extraction result* and
a redacted shape by default, with a hold-to-reveal for the raw string.

---

### 3. Battery, CPU and correctness

#### 3.1 The cost claim in §5.8 is asserted, not derived, and it is wrong in three places

§5.8: *"Everything is notification- or listener-driven except a 15 s coalesced idle check."*

1. **`NSWorkspace.shared.runningApplications` is not free.** §2.2's conjunction consults it. Building
   that array instantiates an `NSRunningApplication` per process and crosses to the WindowServer;
   with 300+ processes it is measured in single-digit milliseconds, which is fine once and terrible
   if evaluated on every mic property change and every activation. The proposal already subscribes to
   `didLaunchApplicationNotification` / `didTerminateApplicationNotification`; say explicitly that
   the conferencing-app set is a **cached `Set<String>` maintained by those notifications**, and that
   `runningApplications` is read exactly once at startup.
2. **AX is not free and, per §1.1, the current sampling rate is too low to work.** Any fix (AXObserver
   per app, or title polling) changes the cost model. The proposal cannot both claim §1.1's evidence
   density and §5.8's cost profile; one of them has to give, and the doc should say which.
3. **The 15 s idle timer.** Fine in isolation, but state the tolerance (`Timer.tolerance` /
   `DispatchSourceTimer` leeway) so the kernel can coalesce it, and confirm it is invalidated — not
   merely "suspended" — across `willSleepNotification`, and re-created on `didWakeNotification`. A
   suspended `DispatchSourceTimer` that is resumed after a 62-hour sleep will fire immediately with a
   nonsense delta.

#### 3.2 Wall-clock time is used everywhere and there is not one word about the clock changing

Every duration in the proposal (`Episode.startedAt/endedAt`, `listeningDuration`, the 90-minute
break, the 90-second absorb window, `idleDuration`) is implicitly `Date()` arithmetic. Concrete
failures:

- **Sleep/wake.** An `Episode` open at `willSleepNotification` and still open at `didWakeNotification`
  spans the sleep. §2.5's break rule ("gap > idle threshold with **no meeting detected**") does not
  fire when §1.2's bug pins `meetingDetected` true. Even with §1.2 fixed, the episode must be closed
  *at* `willSleepNotification`, not inferred afterwards — and the proposal never says so. Use
  `mach_continuous_time` / `ContinuousClock` for durations and `Date` only for display, then a sleep
  cannot silently inflate a duration.
- **DST.** Two transitions a year produce a 23-hour and a 25-hour day. `ShapeClassifier`'s
  `outsideActiveHours` histogram is keyed on hour-of-week; on the spring transition, one hour-of-week
  bucket has no samples ever, and on the autumn one, a bucket has double. Minor, but it will produce
  exactly one spurious `incidentCandidate` per year and someone will file it.
- **NTP correction / manual clock change.** A backwards step yields negative durations. Every
  `TimeInterval` in `Episode` needs a `max(0, …)` floor at construction and a unit test.
- **⛔ Timezone travel is the serious one.** §2.6: *"Active hours are learned, never configured. A
  rolling 28-day histogram ... 'outside active hours' means below the 10th percentile of that user's
  own history."* Fly from Mexico City to Berlin. The histogram is in local wall-clock hours. Every
  working hour of the next week lands in a bucket that historically held nothing — 09:00 Berlin is
  01:00 CDMX. `outsideActiveHours` is `true` for **every single episode**, all week. Combined with
  jet-lagged erratic app switching (`switchRateZ > 1.5`) and a week of undeclared catch-up work, the
  incident classifier fires on essentially every block, and Today shows a permanent stack of
  "Nothing was declared for this block. It started outside your usual hours." The user's first
  business trip turns the feature into noise. **Fix:** store the histogram in UTC *and* in
  device-local, detect `NSSystemTimeZoneDidChangeNotification`, and suppress `outsideActiveHours`
  entirely for N days after a timezone change. Say this in the doc; it is the difference between a
  clever statistic and a shipped one.

#### 3.3 Cold start: the classifier has no baseline for its first 28 days

`switchRateZ` is "vs the user's own 28-day baseline." `outsideActiveHours` is "below the 10th
percentile of that user's own history." On day 1 there is no history; on day 3 the 10th percentile of
three days of data is meaningless and the z-score's denominator is near zero, so `switchRateZ`
explodes and `incidentCandidate` fires on everything. Day 1–28 is *precisely* the window in which the
product must earn trust, and it is the window the design does not cover.

**Fix, and state it in §2.6:** hard-suppress every baseline-derived signal until N ≥ some minimum
(e.g. 10 days with ≥ 2h tracked each); until then, `ShapeClassifier` emits `.unknown` and the "Also
today" strip shows nothing. A feature that is silent for two weeks and then correct is far better
than one that is loud and wrong on day two. Also add a variance floor so `switchRateZ` cannot divide
by a near-zero σ.

#### 3.4 Multiple displays and Spaces

Not addressed at all, and it interacts with §1.1. `kAXFocusedWindowAttribute` on the frontmost
application returns *that application's* focused window, which may be on another Space or another
display than the one the user is looking at. On a two-display setup where Slack is permanently
frontmost-eligible on display 2 while the user works in Xcode on display 1, `didActivateApplication`
fires on every incidental click into the second display — generating a burst of activations that
`switchRateZ` reads as a context-switch storm and `ShapeClassifier` reads as an incident. The 90 s
"absorb" rule in §2.5 helps, but `interjections` still increments, and `interjections` feeds
"moved between three tools 41 times" in §3.1's copy. **A dual-monitor user will see a materially
higher context-switch count than a laptop user doing identical work**, and the weekly review presents
that number as a fact about their attention. At minimum, dedupe activations shorter than the absorb
window out of the switch count, and validate the switch-rate metric against a two-display session
before shipping it.

#### 3.5 The "occasions" number is an artifact of constants, presented as an observation

§2.5 breaks an episode at 90 minutes, absorbs excursions under 90 s, and merges episodes under 90 s.
"23 separate occasions" (§3.2, §3.3) and "6 occasions" per person are therefore direct functions of
three tuning constants. Change the 90-minute cap to 120 and the headline number drops. The export
presents it as a count of real-world events. Either (a) define "occasion" in user-visible copy and in
the export, or (b) stop counting occasions and report only durations and distinct-entity counts,
which are constant-independent.

#### 3.6 Retention interacts badly with the 28-day baseline

§5.4 proposes 28-day retention for ambient evidence. §2.6 needs a rolling 28-day baseline. At steady
state the baseline is computed over data that is being deleted out from under it, and on the day the
retention prune runs, the histogram loses its oldest day. That is survivable, but the baseline must
be maintained as a **separate, aggregate-only, non-prunable histogram** (counts per hour-of-week —
no titles, no evidence, nothing identifying), not recomputed from retained events. Otherwise
shortening retention to 7 days in Settings silently destroys the incident detector, with no
explanation to the user.

---

### 4. Being wrong

#### 4.1 ⛔ "Reviewed 9 pull requests" will include the user's own pull requests

This is the flagship sentence of the entire document (§1, §3.2, §3.3) and the inference under it does
not hold.

- Having a PR page frontmost is not reviewing. Opening your own PR to check CI, re-reading a diff you
  wrote, being linked into a PR from Slack and bouncing straight out — all produce identical evidence.
- §2.6's guard is `supportWork = evidenceKinds ⊇ {.pullRequest} & the counterpart is not the user`.
  **Lggr has no idea who the user is.** There is no account, no sign-in (SPEC principle 10), and the
  proposal never specifies how the user's own `gitForgeHandle` is learned. Tier 1 gives window titles;
  a window title does not say "you are omar-reyes." Reading `~/.gitconfig` is not proposed (and would
  give an email, not a forge handle). So `counterpart is not the user` evaluates against an empty set,
  and **every PR the user authored is counted as support work for someone else.**
- For an EM who still writes code, that is a large fraction. The single most quotable output of the
  product — "you spent 5.1 hours reviewing and unblocking other engineers," which is SPEC §9's own
  example observation — is systematically inflated by the user's own work.

**Fix:** ask once, in the weekly review, "Which of these is you?" with the handles already extracted
(`omar-reyes`, `Omar Reyes`) — one keystroke, the same affordance §2.4 already designed for merges.
Until answered, do not emit the per-person ledger at all. And change the verb: "9 pull requests
**opened in the browser**" is defensible; "reviewed" is a claim about an action never observed.
SPEC §10's accomplishment type is literally "Pull request reviewed," so the word matters — it will
become an `Accomplishment`.

#### 4.2 "Under-claiming is the only acceptable failure direction" is violated by the design itself

§3.2 states the principle. Four mechanisms in the same document over-claim:

| Mechanism | Direction | Magnitude |
|---|---|---|
| §1.2 `.activeListening` before the sleep check | over | up to days |
| §1.3 mic conjunction always true | over | every dictation and personal call becomes meeting minutes in "4h 30m in meetings" |
| §4.1 user's own PRs counted as support | over | potentially half the headline |
| Frontmost-window-as-attention | over | Slack idle on a DM over lunch → "2h 04m with Omar." `.activeListening` specifically defeats the idle suppression that would otherwise catch this |

The principle is right. Add a test: for every number that reaches §3.3's Markdown, write down the
adversarial input that inflates it, and require a suppression rule. If you cannot write the
suppression rule, the number does not ship.

#### 4.3 What undoing actually costs, which the proposal never computes

§3.1: pressing **Incident** creates an `Accomplishment(type: .incidentResolved)`. Suppose the block
was actually the user rebuilding their dev environment at 20:14 after a bad merge — a genuinely
plausible shape match (undeclared, out of hours, high switch rate, tight toolset: Terminal, Slack,
a dashboard). To undo:

1. Notice it. The prompt appears "later," possibly days later, and the block is one of three that day.
2. Navigate to Accomplishments (⌘3), find the row, delete it.
3. Find the `Episode`, change its kind — **is that even possible?** The proposal specifies the
   four-button resolver as a one-time question ("Asked once, remembered forever"). There is no
   re-answer affordance described anywhere. §3.1 says **Skip** "leaves it as neutral tracked time
   forever" — *forever* is doing a lot of work. Undo has to be a first-class, always-available
   action on the episode row, and it is not in the document.
4. If the weekly review has already been exported and pasted, it is out in the world.

Compare with the blank case: a manager who sees nothing writes the incident down themselves in ten
seconds, from memory, correctly. **A wrong auto-fill is worse than a blank one here**, because the
wrong version is *plausible* — it has a timestamp and a duration and three app names, so it reads as
evidence, and evidence does not get re-derived from memory. §5.3 says exactly this ("credibility is
binary") and then §3.1 ships a button that creates a durable record from an inference. The mitigation
is not "ask instead of assert" — it already asks. It is: **make the created record visibly
provisional** (a distinct state in the Accomplishment log, "from a suggestion, unconfirmed"), and
make the resolver re-openable forever from the timeline row.

#### 4.4 The per-person ledger is asserted, not asked — the opposite of the doc's own rule

§2.6 is careful: the classifier *"emits a candidate with a confidence, never a fact,"* and Lggr
*"never asserts an episode kind it inferred — it asks."* But §3.2's ledger —
`Omar Reyes 2h 04m 3 reviews · 2 conversations · 1 meeting` — is rendered with **no confirmation
step at all**, and it is the higher-stakes claim: it names a real colleague and it is the thing
destined for a promo packet. The "ask, don't assert" discipline is applied to the low-stakes label
(episode kind) and skipped for the high-stakes one (a claim about a named person). Invert it, or at
least apply the same confidence floors and the same one-keystroke correction to each person row.

#### 4.5 Fragmentation is presented as the safe failure. It is not free.

§5.2 accepts that "the ledger will sometimes show one human as two rows until they are merged by
hand." Consider the actual user experience at Tier 1 with Slack + GitHub, which is the target
configuration: **every colleague appears twice**, once as `Omar Reyes` and once as `omar-reyes`, and
each row has half the true time. So the first weekly review a user ever sees shows eight rows for
four people, all with wrong numbers, plus a stack of merge prompts. That is not a graceful
degradation; that is a broken first impression, and it lands in Slice 3, the slice whose success
criterion is "the user pastes it without editing."

The conservative merge policy is correct — do not weaken it. But the *presentation* needs to handle
it: hold the per-person ledger back until the merge queue is empty, or group unmerged handle-pairs
visually and show a combined total with an explicit "unconfirmed — same person?" affordance inline,
rather than shipping a document with double-counted rows. And note that §4.4's EventKit-based merge
suggestion — the one thing that would fix this — is deliberately sequenced *after* Slice 3.

#### 4.6 Confidence floors are specified but never defined

§3.2: *"Numbers below a confidence floor are not shown, or are shown as a floor."* No floor is
given, no rule for computing it, and no definition of what makes a `.pullRequest` evidence item
confident. `Confidence` is an enum with three cases and no documented derivation anywhere in the
document. This is the mechanism the entire credibility argument rests on (§5.3), and it is a
placeholder. Define it in Slice 1, against the probe corpus, or the argument in §5.3 is unfalsifiable.

---

### 5. Product principle violations

#### 5.1 SPEC principle 2 ("minimal manual data entry") — the proposal adds a daily inbox

Count what §3.1 adds to a normal day: **"3 undeclared blocks"** with a four-button resolver each.
Plus §4.4's "Who was this with?" chip row per meeting when EventKit is off. Plus §2.4's merge
confirmations. Plus §4.1's "Which of these is you?" (my addition, but required). Plus §3.4's grammar
management. Plus the `.ics` import fallback, which §4.4 concedes "bends principle 6."

The defence offered — "it *replaces* the five-field manual accomplishment form with one keypress" —
does not hold, because **the five-field form was optional and this is not.** Nobody was required to
log an accomplishment. Now there is a daily queue with a count on it. That is a new obligation
introduced by the feature, and it recurs every day, forever, whether or not the user wants anything
from it.

Worse, SPEC's design direction bans *"gamification, streaks, productivity scores that shame the
user."* A badge reading **"3 undeclared blocks"** is functionally a streak counter run in reverse: a
number, visible on the default screen (Today, ⌘1), that goes **up** when the user fails to comply
with the app's model of good behaviour, and down when they perform triage. It does not matter that
the copy is neutral (and the copy in §3.1 genuinely is — "Nothing was declared for this block" is
well written). The *number* is the judgement. Ship the section without the count, cap it at one
prompt per day, and let unresolved blocks age out silently into neutral tracked time.

#### 5.2 SPEC "Do not use judgmental language" — §3.3 exports out-of-hours to the manager

§5.6 promises the out-of-hours signal *"is never surfaced on its own."* Then:

- §3.2, on its own line: `1 unplanned block, Tuesday 20:14–21:40, outside your usual hours`
- §3.3, in the Markdown the user pastes into a shared doc: `One unplanned block, Tuesday 20:14–21:40
  (1h 26m), outside usual working hours`
- §3.1, in the resolver copy: `It started outside your usual hours`

That is three surfacings, one of which leaves the user's machine. The in-app copy is genuinely
non-judgemental. **The exported copy is not the user's to control.** Once "outside usual working
hours" is in a document a manager reads, it is either a boast or a red flag depending entirely on
that reader, and the user has lost the framing. Some readers will see dedication; some will see a
burnout risk to be managed; some will see poor planning. Remove the out-of-hours phrase from the
export entirely — the timestamp is already there and speaks for itself — and keep the signal
internal, as §5.6 promised.

#### 5.3 SPEC "Never repeatedly nag" — §4.3 adds a weekly permission surface

`DESIGN.md` §6.6 fixes the surfaces at three and says "Never otherwise." §4.3 adds: a line on every
weekly review (up to twice), plus a permanent `.caption` line that appears **every single week,
forever** ("Window titles are off, so this is grouped by application"). A permanent line about a
permission you declined, on the screen you visit to do your weekly reflection, is a nag with a
different tone of voice. §4.3 even says "Stated once, per §6.6's re-ask policy" while describing a
recurring element — the doc contradicts itself in the same paragraph. Show it once, ever, then never
again; the Settings → Privacy toggle already exists for people who change their mind.

#### 5.4 "AI where a rule would do" — inverted, but present

§2.7 is the strongest section in the document. `FoundationModels` is correctly confined to prose
rewriting over already-computed facts, with a deterministic validator and a fallback. No objection.

The violation is elsewhere and it is statistics rather than AI: `switchRateZ`, `appSetEntropy`, a
10th-percentile hour-of-week histogram, and a five-term scored conjunction with an unnamed
`threshold`. This is a model. It has hyperparameters, a cold-start problem (§3.3), a timezone
failure (§3.2), and no way for a user to understand why it fired. SPEC §5 asks for a "rule-based
classification engine" and asks the user to be able to *correct a classification* and have the app
*offer to create a reusable rule*. `appSetEntropy < threshold` cannot be corrected and cannot become
a rule.

**Try the boring version first:** an undeclared block is worth asking about if it is longer than
20 minutes and is not covered by a session. That is one rule, it is explainable in one sentence, it
works on day one with no baseline, it never fires on a flight, and it is right most of the time. Ship
that in Slice 2, measure how often the user picks "Incident," and only then decide whether z-scores
buy anything. Right now the entropy term is doing unmeasured work in a document that (correctly)
demands measurement before belief everywhere else.

#### 5.5 "A feature that only works for one kind of user"

The document is titled "the invisible work of a manager" and it delivers on that. But SPEC's audience
is *"engineering managers, developers, and knowledge workers,"* and the value here is unevenly
distributed:

- **An IC developer** gets almost nothing from the people ledger — their week is Xcode, and the
  `.repository("Lggr")` grammar yields one entity all week. The ambient inversion and episodes help
  them; §3.2 and §3.3, the "section this whole proposal exists for," do not.
- **The grammar pack covers eight tools**, all of them the modern-startup default stack. A user on
  JetBrains, VS Code, Notion, Obsidian, Figma, Jupyter, Confluence, Azure DevOps, Bitbucket, Gerrit,
  Phabricator, iTerm, or any internal tool gets zero evidence and a weekly review that says nothing.
  §3.4 lets them "edit grammars" — writing `NSRegularExpression` patterns against window titles is
  not a user-facing feature, it is a support burden.
- **Non-English users get nothing.** Every pattern in the §2.3 table is `en-US`. GitHub localises its
  `<title>` separator and word order. Slack localises `(DM)` and `(Channel)`. Jira and Linear localise
  their UI chrome. Nothing in the document acknowledges a locale exists.
- **Anyone in a regulated or client-confidential environment** (agency, consultancy, healthcare,
  legal-adjacent) cannot run the Slice 0 probe at all, and arguably cannot run `.document` evidence
  at all — see §2.3 above.

None of this kills the proposal, but the doc should say plainly: *this is an EM feature, English
first, for teams on GitHub/Slack/Linear*, and it should say what an IC sees. Right now §4.2's "what
Tier 0 alone looks like" is the closest thing to that answer, and it is about permissions rather than
about who the user is.

#### 5.6 Scope, against SPEC principle 12

SPEC principle 11: *"Avoid unnecessary abstractions and overengineering."* Principle 12: *"Build the
smallest polished vertical slice before adding advanced functionality."* This proposal introduces
seven new domain types, a new persisted graph (`Person`, `Workstream`, alias store), an
architectural inversion of the core service, a new `ActivityState` case, a fourth privacy pane, a
second Rules tab, two new export commands, a new menu-bar state, and a new daily UI surface —
against a codebase whose weekly review (`DESIGN.md` §5.4.4) is still marked *Phase 5*.

The slicing in §6 is genuinely good and I want to say so: the probe-first structure, the pre-agreed
kill criteria, and the "Slice 1 changes no UI and proves the claim in `swift test`" discipline are
better than most engineering plans get. **The correct response to this review is not to shrink the
ambition; it is to shrink the first three slices further** and let §3.2/§3.3 wait until the numbers
in them have survived a month of the author's own use.

---

### 6. What I would change, in priority order

Blocking, must be resolved before Slice 0 runs:

1. **Fix the probe's sampling** (§1.1). Add `AXObserver` on `kAXFocusedWindowChangedNotification` /
   `kAXTitleChangedNotification`, or a bounded title poll. Without this the kill criteria are biased
   toward killing a live hypothesis.
2. **Harden `probe.jsonl`** (§2.2): `0600`, backup-excluded, redacted-shape by default, allowlisted
   raw capture, self-expiring, overwrite-before-unlink.
3. **Verify `kAudioDevicePropertyDeviceIsRunningSomewhere` is permission-free** on macOS 14 and 26,
   as §5.7 already demands — and verify it against a headset, since §1.4 suggests the default-input
   scoping is wrong regardless.

Blocking before Slice 2 ships to a human:

4. **Reorder `IdleEvaluator`** (§1.2) and cap `.activeListening` runs.
5. **Rewrite the meeting conjunction** to require a *frontmost/foreground* conferencing app (§1.3),
   and downgrade its confidence from `.high`.
6. **Suppress all baseline-derived signals for the first N days** and after a timezone change
   (§3.2, §3.3). Store the hour-of-week histogram separately from prunable events (§3.6).
7. **Use a monotonic clock for durations** and floor every interval at zero (§3.2).
8. **Handle fast user switching** via `sessionDidResignActiveNotification` (§1.7).
9. **Make the resolver re-openable forever** and mark auto-created accomplishments provisional (§4.3).
10. **Drop the "3 undeclared blocks" count** (§5.1).

Blocking before Slice 3 ships:

11. **Learn who the user is** before emitting any per-person number (§4.1), and change "reviewed" to
    a verb the app can observe.
12. **Cut `Copy evidence for… ▸ person`** (§2.4).
13. **Cut or hash `.document(name:)`, gate `.conversation(.channel)`** (§2.3).
14. **Remove "outside usual working hours" from the export** (§5.2).
15. **Define the confidence floor numerically** (§4.6).
16. **Hold the per-person ledger until the merge queue is empty** (§4.5).

Cut outright:

17. **The CoreMediaIO camera signal** (§1.10) — already distrusted, so do not carry the code.
18. **The §4.3 recurring weekly permission line** (§5.3) — one surfacing, ever.

Fix before anyone quotes the doc:

19. **§2.7 will not compile under Command Line Tools** (`@Generable`, §1.5). Either conditional-target
    it like `LggrPersistence` or hand-roll the conformance, and correct the `Response<Content>` unwrap.
20. **Correct the header claim** to name all four contradictions with `DESIGN.md` (§0.1), and the
    `.hidSystemState` / `.combinedSessionState` substitution (§1.6), and the force unwrap.

---

### 7. Verdict

**KEEP WITH CHANGES** — the core bet (ambient-first capture plus a deterministic, discard-the-title
evidence extractor, proved by a corpus probe before anything is built) is right and is the most
credible plan in this folder; but two of its three named legs are broken as specified — the mic HAL
boolean is a consent-free surveillance proxy whose conjunction is always true and whose idle
interaction fabricates days of "listening," and activation-only sampling cannot observe the nine pull
requests the whole document is written to count — so ship it only after the probe's sampling is
fixed, the mic signal is either replaced by EventKit or made visible and defeasible, and the
per-person export is cut.
