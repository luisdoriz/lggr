# Proposal — Maximum intelligence, minimum surveillance

> Lens: how much intelligence can we get from the least invasive signal?
> Adversarial position: assume the user is unwilling to let Lggr read window titles, and treat that
> as a correct instinct rather than a limitation to be talked out of.
>
> Binding inputs: `SPEC.md` (§4, §5, §6, §9), `CONSTRAINTS.md`, `DESIGN.md` §5–6.
> Everything below is additive to the Phase 2 build that exists today.

---

## 1. The core bet

**Almost everything Lggr promises is carried by the *shape* of activity over time, not by its
content — and shape is content-free by construction.** Bundle identifier plus start and end
timestamps plus idle boundaries is not a degraded signal; it is a different and largely
non-overlapping signal, and it is the one that answers SPEC §9's questions. Dwell distributions,
excursion-and-return latency, alternation bigrams, fragmentation, warm-up time, and the hour-of-day
profile of long unbroken runs are all computable from a stream that never contains a single
character the user typed or read. The bet is that Lggr builds its intelligence engine entirely on
this stream first, treats every content-bearing signal (window title, browser URL, calendar event)
as an *optional refinement that is reduced to a bounded-cardinality label at the point of capture and
never persisted as text*, and makes that reduction **verifiable by the user with a button rather than
promised in a paragraph**. The proof that this is not a compromise is SPEC's own flagship example
summary — *"Worked primarily in Xcode and Terminal on receipt deduplication. Reviewed one GitHub pull
request and spent seven minutes in Slack."* Xcode, Terminal and the seven Slack minutes are bundle
IDs and timestamps. *"receipt deduplication"* is the intended outcome the user already typed and Lggr
already stores. *"GitHub"* is a hostname. **Zero window titles are required to produce the sentence
the spec holds up as the target.** Every competing proposal that reaches for `kAXTitleAttribute` is
paying a large, permanent, unverifiable privacy cost for the word *"GitHub"*.

---

## 2. The mechanism

### 2.1 What Tier 0 actually captures

No permission of any kind. All of this is available to an unsandboxed *and* a sandboxed build.

```swift
// Sources/LggrApp/Services/ActivitySampler.swift   [new]
let wsc = NSWorkspace.shared.notificationCenter
wsc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, ...)
// userInfo[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
//   → .bundleIdentifier, .localizedName, .processIdentifier
wsc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, ...)
wsc.addObserver(forName: NSWorkspace.willSleepNotification, ...)      // close open interval
wsc.addObserver(forName: NSWorkspace.didWakeNotification, ...)        // open a fresh one
wsc.addObserver(forName: NSWorkspace.screensDidSleepNotification, ...)
DistributedNotificationCenter.default().addObserver(
    forName: Notification.Name("com.apple.screenIsLocked"), ...)      // undocumented, stable 10.13–26
```

Idle, with no permission and no event contents:

```swift
// Sources/LggrApp/Services/IdleMonitor.swift   [new]
// kCGAnyInputEventType is ~0. CGEventType(rawValue:) is failable and force-unwrap is banned
// by CONSTRAINTS rule 4, so it is resolved once and stored.
private static let anyInput = CGEventType(rawValue: ~UInt32(0))
guard let anyInput else { return 0 }
let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
```

`secondsSinceLastEventType` returns *how long since* an event. It never returns the event, needs no
Input Monitoring grant, and cannot be used to reconstruct anything typed. Poll at 5 s; the poll is
sub-microsecond.

That is the whole capture surface of Tier 0: `(bundleIdentifier, localizedName, startedAt, endedAt,
isIdle)`. It is exactly the `ActivitySample` type DESIGN §6.7.4 already specifies, minus the two
optional fields.

### 2.2 What bundle-identifier-only tracking genuinely infers

Not "roughly which app category" — that is the boring 10%. The inventory, each item a pure function
over `[ActivityInterval]` living in `LggrKit` and unit-testable today with `swift test` on a machine
with no Xcode and no permissions granted:

| # | Derived signal | How | Why it is not obtainable from titles |
|---|---|---|---|
| 1 | **Longest unbroken run** | max contiguous dwell in one app, gaps ≤ 2 s coalesced | The unit of "focus" is duration, not content |
| 2 | **Fragmentation index** | `1 − (longest run ÷ total time in that app)` per app per session | Distinguishes 40 contiguous minutes from 4×10 interleaved — same title, same total |
| 3 | **Alternation bigrams** | count ordered pairs `(A→B)`; cluster by median excursion length | Xcode↔Terminal at a 22 s median is *one activity*. Xcode↔Slack at a 4 min median is an interruption. Same two rows in any title log |
| 4 | **Return latency** | for each excursion out of the session's dominant app, time until return | The real cost of an interruption. Nothing in a title measures it |
| 5 | **Warm-up latency** | session start → first sustained (>5 min) block in the eventually-dominant app | Answers "how long does it take me to actually start" |
| 6 | **Circadian focus profile** | histogram of long-run start hours across the week | Delivers SPEC §9's *"longest uninterrupted sessions happened before 11:00 AM"* verbatim |
| 7 | **Switch rate vs personal baseline** | switches/hour vs rolling 4-week median | Delivers *"Tuesday had twice as many context switches as your weekly average"* verbatim |
| 8 | **Interruption sources, ranked** | which bundle ID most often begins an excursion out of a deep-work session | Delivers *"Slack interrupted 42% of deep-work sessions"* verbatim |
| 9 | **Planned vs reactive** | tracked time inside a `FocusSession` vs outside it | Already fully determined by existing data |
| 10 | **App-mix project inference** | per-session vector over bundle IDs weighted by dwell; cosine nearest-neighbour against sessions where the user *declared* a project | Reduces manual entry (Principle 6) without reading anything |
| 11 | **Untracked-block reconstruction** | contiguous non-session, non-idle time ≥ 8 min, summarised by app mix | The single largest win. See §3.2 |
| 12 | **Meeting inference** | conferencing bundle ID frontmost ≥ 80% of a block, idle tolerated | `us.zoom.xos`, `com.microsoft.teams2`, Google Meet in a browser is the known miss |

Against SPEC §9's ten required weekly-review displays, **ten of ten are fully computable at Tier 0**
(context switches with a stated browser caveat, §5.1). Against SPEC §9's five example observations,
**four of five are exact and the fifth — *"5.1 hours reviewing and unblocking other engineers"* — is
reachable from authored accomplishments plus, optionally, a hostname.**

Classification (SPEC §5) at Tier 0 is a static `AppCatalog`: roughly 120 bundle-ID prefixes →
`ActivityCategory`, shipped in `LggrKit`, user-overridable, plus `RuleMatchType.application` /
`.applicationName` rules which already exist in the spec's model. `com.apple.dt.Xcode` → Coding.
`com.tinyspeck.slackmacgap` → Communication. `com.linear` → Planning. No title needed for any of the
examples SPEC §5 lists except *GitHub → Code review* and *YouTube → Distraction*, which are
hostnames, not titles.

### 2.3 The type-boundary: how "derived, not stored" is made structural

The claim "we read the title but only keep a category" is worth exactly as much as the code that
makes it impossible to do otherwise. Four mechanisms, on top of the four DESIGN §6.7.4 already
specifies.

**(a) The reader has no `String` in its signature.** This is the load-bearing one.

```swift
// Sources/LggrApp/Services/FocusedContextReader.swift   [Tier 1]
/// Bounded-cardinality output. There is no public API on this type that returns a String,
/// and check-layering.sh fails the build if one is added.
public enum TitleDerivation: Sendable, Equatable {
    case category(ActivityCategory)   // 11 cases  → ≈3.5 bits
    case none                          //           → the absence carries ≈0
}

public struct FocusedContextReader {
    /// Reads kAXTitleAttribute, matches it, releases it. The characters are never copied into
    /// Swift-managed memory: matching is done with CFStringFind against the CFStringRef the
    /// AX API hands back, and the ref is released before this function returns.
    public static func derive(pid: pid_t, rules: [CompiledRule]) -> TitleDerivation

    /// Did the focused window's title change since the previous sample for this pid?
    /// Compares two CFStringRefs and returns one bit. Neither is retained.
    public static func focusChanged(pid: pid_t) -> Bool
}
```

The rest of the application cannot name a window title because no function anywhere returns one. A
title is not a variable that is carefully discarded; it is a value that never enters the type system.
`check-layering.sh` — which already exists — gains two greps: `kAXTitleAttribute` outside this file,
and any `-> String` on this type.

**(b) A second, honest low-bandwidth channel.** `focusChanged` gives `distinctFocusChanges: Int` per
interval. This separates *"38 minutes in one document"* from *"38 minutes across 23 things"* — a real
and genuinely useful fragmentation signal that consumes `log₂(N)` bits about **cardinality** and
exactly **zero bits about identity**. In a browser, where NSWorkspace is blind to tab switches, this
turns an opaque 90-minute block into a measured stream of switches with no content whatsoever. It is
the single best return on the Accessibility grant and it stores nothing.

**(c) The capture ledger.** Every content-bearing read appends one row to
`~/Library/Application Support/Lggr/reads.json`:

```
{ "t": "2026-07-24T09:14:03Z", "api": "ax.title", "target": "com.apple.dt.Xcode",
  "inputBytes": 47, "output": "coding", "retained": false }
```

`inputBytes` is a length, not a string. The ledger is the *audit trail of reads*, it is displayed in
the UI (§3.3), and it converts "we don't store titles" from a claim into a counted record the user
can compare against the store file. It is pruned on the same retention schedule and is itself covered
by the canary test below.

**(d) The canary self-test, shipped in the app and runnable by the user.**
`Settings → Privacy → Run privacy self-test` builds a synthetic day in a temporary store directory
in which every window title, every URL and every calendar title is the literal string
`CANARY-EE7F11`, runs the *real* capture→redact→persist pipeline over it, then reads
`store.json`, `reads.json` and the preferences plist back **as raw bytes** and searches for the
canary. It reports:

> **Privacy self-test — passed.**
> 1,440 synthetic intervals written. The canary string appeared 0 times in store.json,
> 0 times in reads.json, 0 times in preferences.
> Ran in 0.4 s. `Show me the file` · `Run again`

The same test runs in CI as `PrivacyCanaryTests` and fails the build on a single hit. This is
verification the user *performs*, not verification the user *reads*.

### 2.4 Is derive-and-discard a real improvement, or theatre?

**It is a real and large improvement — but only when three conditions all hold, and it is theatre
the moment any one of them fails.** The test:

1. **Bounded output.** Is the derived value drawn from an enumeration fixed at build time? A category
   from 11 cases leaks ≈3.5 bits per switch. A window title is 200–600 bits. A `String` output — "the
   work item we extracted", "a short description of what you were doing" — has unbounded capacity and
   is the original title under a new name. **If the output type is `String`, it is theatre.**
2. **No intermediate persistence.** Never logged (DESIGN §6.7.4 already bans `windowTitle` as a log
   argument at every level), never in an error message, never in `CustomDebugStringConvertible`,
   never in a `Codable` type. The `CFStringFind` implementation in (a) strengthens this from
   discipline to memory layout.
3. **Verifiable.** Ledger + canary + counts over the user's own file. Absent verification, a
   privacy-conscious user is *correct* to discount the claim to zero, because they cannot tell this
   design apart from one that stores everything.

The framing that makes the answer obvious is the **threat model**. The adversary is not Lggr. The
adversary is *everyone who ends up with the file*: a Time Machine backup, another local account, an
iCloud-synced folder the user later moves it into, a support-request export, a shoulder surfer on a
train, a stolen laptop, a device handed to IT, a subpoena of the disk. Against that adversary — the
realistic one — a file containing zero customer names, zero ticket titles and zero document names is
categorically better than one containing 6,000 of them, and calling that difference "theatre" is
simply wrong.

Two residuals I will not paper over:

- **Derive-and-discard does not defend against a future malicious or compromised version of Lggr.**
  It defends against Lggr being careless and against the file being read by someone else. That is the
  honest scope.
- **A title held in a local for microseconds can in principle land in a crash report** if the user
  has diagnostics sharing on. The `CFStringFind` approach shrinks this to a CoreFoundation-owned
  buffer with a lifetime of microseconds, but it is not zero. It is also a *floor shared by every
  design that reads titles at all*, including the retain-mode ones — so it is not a reason to prefer
  storing them.

### 2.5 Where I put the line

**Storing a hostname is acceptable by default. Storing a window title is not, ever, by default.**

This is not squeamishness, it is entropy. A hostname is drawn from a small, mostly public,
mostly non-identifying set — `github.com`, `linear.app`, `youtube.com`. A window title is
unbounded free text authored by other people about other people: *"ACME Corp — overcharge dispute
#4471"*, *"Q3 layoff plan v4 — CONFIDENTIAL"*, *"Re: your performance review"*. They are not the
same kind of object and SPEC §4 treating them as one line item is the spec's weakest sentence.

Therefore this proposal **inverts SPEC §4's default**:

- `trackWindowTitles` becomes a three-state setting, defaulting to **Derived** when Accessibility is
  granted, never to **Stored**.
- **Stored** mode still exists — SPEC asks for `windowTitleContains` rules and a user may genuinely
  want a searchable log — but it is opt-in **per application**, as an allow-list, not a global
  switch. "Store titles from Xcode and Linear" is a defensible choice. "Store all titles from
  everything including 1Password's vault window and Messages" is not a choice anyone means to make.
- `RuleMatchType.windowTitleContains` remains, and its match string is stored, because **the user
  typed it themselves.** Authored text is categorically different from captured text. That
  distinction is load-bearing throughout this document.

---

## 3. What it changes for the user

### 3.1 The session review sheet gains an evidence panel

Existing sheet keeps its five result statuses and its editable summary. Below them, one new block —
neutral, counted, no colour coding, no score:

```
How it went

  49 min                    38 min                    7 switches
  session length            longest unbroken run      out of Xcode

  Xcode      31 min   ████████████████░░░░  in 4 blocks
  Terminal   12 min   ██████░░░░░░░░░░░░░░  46 alternations with Xcode, median gap 22 s
  Slack       6 min   ███░░░░░░░░░░░░░░░░░  4 visits, median 4 min before returning

  Xcode and Terminal alternated tightly enough that Lggr counts them as one activity.
  It took 6 minutes from starting the session to your first block longer than 5 minutes.
```

Generated summary, deterministic, unchanged API (`SessionSummaryBuilder` already exists):

> Worked primarily in Xcode and Terminal on receipt deduplication, with the longest unbroken
> stretch running 38 minutes. Left for Slack four times, 6 minutes in total.

No title was read. No permission was granted.

### 3.2 The end-of-day reconstruction — the largest single win

Lggr tracks all day, not only inside sessions. At the end of the day, Today shows the blocks that
were *not* inside any session, which is precisely the gap between intent and reality:

```
Not in a session today — 2 h 51 m

  10:40 – 11:25    45 min    Zoom, Calendar
                             Log as a meeting?   [ Meeting ]  [ Something else ]  [ Leave it ]

  13:10 – 13:58    48 min    Slack, Mail, Messages
                             [ Log as communication ]  [ Start a session for this ]  [ Leave it ]

  15:02 – 16:20    78 min    Xcode, Terminal, Simulator
                             This looks like Lggr — 84% match to your last 6 Lggr sessions.
                             [ Log as a Lggr session ]  [ Different project… ]  [ Leave it ]
```

One click writes a `FocusSession` with a real start, end, project and app breakdown. **This is
Principle 6 delivered — it removes typing rather than adding fields — and it is the answer to "what
did I actually do today" for the 60% of the day that was never a declared session.** All of it is
Tier 0.

### 3.3 The Record screen — "show me exactly what you have on me"

A dedicated sidebar item, not a Settings tab. Its entire job is to display the data, not to reassure.
**The words "we take your privacy seriously" are banned copy; the screen shows counts instead.**

```
Record

Lggr has 6,412 activity intervals, 41 focus sessions, 88 accomplishments and 12 projects,
from 12 March to today. Everything is in one file on this Mac.
                                                            [ Reveal in Finder ]  [ Export… ]


Every field Lggr can store                          Stored for you       Example from your data
────────────────────────────────────────────────────────────────────────────────────────────
Application name                                    6,412 of 6,412       "Xcode"
Bundle identifier                                   6,412 of 6,412       "com.apple.dt.Xcode"
Start and end time                                  6,412 of 6,412       09:14:02 – 09:52:41
Idle flag                                           6,412 of 6,412       false
Category                                            6,201 of 6,412       Coding
Focus changes within the interval (a count)           412 of 6,412       23
Window title                                            0 of 6,412       — never stored —
Browser host                                           96 of 6,412       "github.com"
Full URL, path or query                                 0 of 6,412       — never stored —
Calendar event title                                    0 of 6,412       — never read —
Keystrokes, screenshots, clipboard, documents           0                — no API is called —


What Lggr read today                                                    [ Last 7 days ▾ ]
────────────────────────────────────────────────────────────────────────────────────────────
Window titles read                412     Retained as text        0     Turned into a category  412
Browser addresses read             96     Full URLs retained      0     Hosts retained         96
Calendar events read                0     Titles retained         0
                                                                        [ Show the read log ]

Verify this yourself                                        [ Run privacy self-test ]
Writes a synthetic day where every title is CANARY-EE7F11, then searches the actual files
for it byte by byte. Last run: today 09:02 — passed, 0 hits.


What Lggr cannot do                                              read from this copy of the app
────────────────────────────────────────────────────────────────────────────────────────────
Network                No networking framework is linked. com.apple.security.network.client: false
Screen Recording       Not requested. Lggr does not appear in that pane of System Settings.
Input Monitoring       Not requested. Idle time is measured as "seconds since last input".
Full Disk Access       Not requested.
Currently granted      Accessibility · Automation (Safari) · Notifications


Apps Lggr knows about                                                        88 apps, sorted
────────────────────────────────────────────────────────────────────────────────────────────
Xcode              41 h 12 m    Coding            [ Private ] [ Exclude ] [ Forget all records ]
Slack               8 h 04 m    Communication     [ Private ] [ Exclude ] [ Forget all records ]
1Password              —        excluded          [ Restore ]
…

Delete                    [ Today ]  [ Last 7 days ]  [ Date range… ]  [ All activity history ]
Sessions, accomplishments and notes are never deleted automatically, at any retention setting.
```

Three properties make this screen do real work rather than perform: the counts are computed over the
user's own file at render time (not hardcoded), the "What Lggr cannot do" block is read out of the
running bundle's entitlements and `otool`-visible load commands rather than typed into a string, and
the self-test button lets the user falsify the claim above it in 400 ms.

### 3.4 Weekly review observations, all Tier 0

Neutral, evidence-first, no comparison to anyone, no score, no streak:

> - Your longest unbroken stretches started between 9:00 and 11:00 on four of five days.
> - Slack began an excursion out of 11 of your 26 deep-work sessions (42%). Median time before
>   returning: 4 minutes 10 seconds.
> - Tuesday's switch rate was 2.1× your four-week median.
> - The primary outcome, *Improve receipt ingestion reliability*, received 18% of tracked time
>   across 7 sessions.
> - 2 h 51 m of Wednesday was tracked but not inside any session. Most of it was Zoom and Slack.
> - 38% of tracked time was inside a browser. Lggr sees a browser as one application, so switch
>   counts on this page do not include anything that happened between tabs.

That last line is not a footnote, it is a design commitment: **Lggr states its own blind spots on the
screen where the number appears**, because a flatteringly low context-switch count that the user
cannot interpret is worse than no count.

---

## 4. Permissions, and the ladder as an informed trade

Every rung is independently deniable and denying one never disables one above it. The existing
DESIGN §6.3 ladder is preserved and refined; what is new is that each rung states **what intelligence
it buys and what it costs in stored bytes**, so the user trades rather than capitulates.

| Rung | Grant | Buys | Costs, on disk | Without it |
|---|---|---|---|---|
| **0** | none | Items 1–12 of §2.2. Session evidence panel, end-of-day reconstruction, project inference, all ten SPEC §9 displays, four of five SPEC §9 example observations | bundle ID + two timestamps + idle bit per interval | — this *is* the product |
| **1-D** — Accessibility, **Derived** *(default when granted)* | Accessibility | Category refinement inside generic apps (Terminal → Testing vs Coding). **Tab-level switch counting inside browsers.** Per-interval focus-change count | one enum case + one integer. **No text.** | Terminal stays "Coding". Browsers stay one opaque block |
| **1-S** — Accessibility, **Stored** *(opt-in, per app, allow-list)* | Accessibility | Searchable titles, `windowTitleContains` rules, summaries that name the document | **free text authored by other people, permanently** | Rules by app and host still work; the user's own intended outcome still names the work |
| **2** — Automation, per browser | Automation for that browser | `github.com → Code review`, `youtube.com → Distraction`; browser time splits by site | **hostname only**, low entropy, never path or query | All browser time is one block |
| **3** — Calendar, **time skeleton only** | Calendar full access | Meeting load, calendar fragmentation, "this untracked block sits inside a 3-person event" | start, end, all-day flag, attendee **count**, status. **Never title, notes, location or attendee identity** | Meetings inferred from Zoom/Teams frontmost only; Meet-in-a-browser is missed |
| **N / L** | Notifications, `SMAppService` | Alerts; app running at login | nothing | Menu bar still changes state; user launches Lggr themselves |

**Three honest statements this ladder owes the user, stated on the permission screens themselves:**

1. **macOS has no narrow Accessibility grant.** `AXIsProcessTrusted()` is a single bit that authorises
   reading and controlling *every* application. Lggr needs a thousandth of what that grant confers.
   There is no API to ask for less. Lggr says so on the screen where it asks, offers Derived mode as
   the default, and offers the ledger and the self-test as the only available compensation. Designing
   around this is not possible; pretending otherwise would be the fantasy the brief warns against.
2. **EventKit has no times-only scope.** On macOS 14+ the choices are
   `requestWriteOnlyAccessToEvents()` (useless here) and `requestFullAccessToEvents()` (everything).
   Lggr requests full access and reads five non-text properties. That gap between what is granted and
   what is used is exactly the gap the type boundary, the ledger and the canary exist to make
   checkable — the `CalendarReader` returns `[CalendarBlock]`, a struct with no `String` field.
3. **Automation cannot detect Safari or Firefox private windows.** Chromium's
   `mode of front window` is checked and skipped; Safari and Firefox expose no equivalent. DESIGN
   §6.1.2 already states this; the Record screen should state it too, next to the browser host count.

**Degraded mode is not a fallback, it is the shipping default.** With every permission denied, Lggr
delivers §3.1, §3.2, §3.3 and §3.4 in full. Nothing in this proposal's user-facing value depends on a
grant. The app must therefore never show a permission banner more than once, never colour it, and
never show it during a running session (DESIGN §6.6 already commits to this).

### 4.1 FoundationModels — does on-device inference change the calculus?

**On captured content: no, and I would refuse to use it there.** Three reasons.

1. **The privacy question here was never the network; it was channel capacity.** An LLM is by
   construction a high-capacity, general-purpose interpreter of text. Routing a window title into an
   11-case rule table leaks ≈3.5 bits. Routing it into `LanguageModelSession.respond(to:)` invites a
   `String` output, and every product pressure to make that output "useful" is pressure to raise its
   capacity until it is the title, paraphrased, on disk. On-device inference does not make a stored
   paraphrase of a confidential document title acceptable.
2. **It cannot be the primary path.** `FoundationModels` is macOS 26+, and further requires Apple
   Intelligence to be enabled and the device to be eligible — `SystemLanguageModel.default.availability`
   returns `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)`. Lggr's
   floor is macOS 14. So any feature built on it needs a rule-based fallback producing the same output
   shape. If that fallback is adequate the model was unnecessary; if it is not, the app is broken for
   most users. SPEC §5's *"rule-based classification engine before any AI"* is not a sequencing
   preference, it is the correct architecture.
   *Build note:* `@Generable` and `@Guide` are macros. Per `CONSTRAINTS.md`, macro plugin dylibs ship
   with Xcode, not Command Line Tools — expect the same hard failure as `@Model`. Verify before
   relying on it; either way it belongs behind the existing `LGGR_SWIFTDATA`-style conditional-target
   pattern, never in `LggrKit` or `LggrApp`.
3. **It is not correctable.** SPEC §5 requires that a user can fix a classification and get a reusable
   rule. "Enable a rule that says Terminal in the Lggr project is Testing" is correctable. "The model
   decided" is not.

**On text the user authored: yes, and it is the one place it earns its keep.** The intended outcome,
the tangible result, the blocker, the next step and interruption notes are already on disk, already
the user's own words, and were never captured from anyone. Turning a week of them into a draft
narrative paragraph — presented editable, never auto-saved — adds **zero new capture surface** and
directly serves the Friday-afternoon problem. Gate on macOS 26 + availability, fall back to the
deterministic `SessionSummaryBuilder` that already exists and is already tested.

Two other frameworks named in the brief, ruled out plainly: **ScreenCaptureKit** would give titles via
`SCWindow.title` and is the *easiest* route — and it requires Screen Recording, which grants pixel
access to every window on the display. That is disproportionate for reading a string, and DESIGN
§6.1.6 already refuses the equivalent `CGWindowListCopyWindowInfo` route for the same reason;
`SCShareableContent` gets the same refusal. **Speech** requires the microphone, and meeting audio is
categorically out of scope.

### 4.2 What I would refuse to build, even if asked

- Any use of Screen Recording, including `SCWindow.title` as a title source.
- OCR of window contents (`VNRecognizeTextRequest`), under any framing.
- Any `CGEvent.tapCreate` event tap. Including keystroke *counts* — it needs Input Monitoring, it is a
  shaming metric, and words-per-minute is a lie about knowledge work.
- Salted, truncated hashes of window titles presented to the user as anonymous. The candidate space of
  plausible titles is small and the salt lives on the same disk as the hash. That is pseudonymisation,
  and shipping it under the word "anonymous" would be the exact theatre §2.4 warns about.
- Storing full URLs, paths or query strings; reading `~/Library/Safari/History.db` (Full Disk Access).
- Any LLM call whose input is captured content rather than authored content.
- A single number that summarises a person. No focus score, no productivity score, no streak, no
  weekly grade, no red. SPEC bans it and it is also just wrong.
- Silent tracking. The menu bar icon must always distinguish tracking / paused / not tracking.
- Retroactive backfill of titles onto history when Accessibility is later granted.

---

## 5. What could make it fail

**1. The biggest risk: timing insight may be true but not *evidential*.** "Your Xcode↔Slack return
latency is 4 m 10 s" is a fact. "You finished the receipt deduplication PR" is evidence. The Friday
problem — SPEC §10's *"open the app on Friday and immediately see evidence of what they delivered"* —
wants nouns, and Tier 0 produces adverbs. Mitigation: the nouns come from the intended outcome and the
tangible result, which the user already types and Lggr already stores; every generated observation
must pair a timing fact with authored text. But if the pairing feels thin, the honest conclusion is
that content capture is necessary and this proposal loses. §6 makes that falsifiable rather than
arguable.

**2. Browsers are a structural blind spot at Tier 0, and it is worse than it looks.** Chrome tab
switches produce no `NSWorkspace` notification, so context switches are *systematically undercounted*
for browser-centric workers — which is a flattering error, the worst kind. If the user's browser share
is high, Tier 0's headline metric is quietly wrong. Partial mitigations: state the browser share next
to every switch count (§3.4); at Tier 1-D, `AXObserverCreate` + `kAXTitleChangedNotification` /
`kAXFocusedWindowChangedNotification` on the frontmost browser yields a switch *count* with no
content. This makes browser share a go/no-go measurement, not a footnote — see §6.

**3. Idle detection lies in exactly the situations that matter.**
`secondsSinceLastEventType` does not count video playback, an active call, or reading. A 45-minute
Zoom where the user listened attentively reads as 45 minutes idle. Mitigation: never mark idle while
an app in the Meeting category is frontmost, and never while `IsSecureEventInputEnabled()` is true.
Residual: reading a long document in Preview still reads as idle, and there is no permission-free fix.

**4. App-mix project inference degrades to noise** for anyone whose every project uses the same three
apps. Needs a confidence floor (suggest only above ~70% cosine similarity with ≥4 prior labelled
sessions), must always be a suggestion with a visible percentage, and must never auto-assign.

**5. Catalog rot and genuine ambiguity.** Terminal is coding, testing, ops and ssh. Electron apps
proliferate. A static 120-entry catalog needs to fail gracefully to `.unknown` rather than guess, and
`.unknown` must be visible on screen rather than silently folded into a bucket.

**6. AX observers are a hang risk.** `AXObserver` on an unresponsive app can block. Mandatory:
`AXUIElementSetMessagingTimeout(element, 0.25)` on every element, one observer for the frontmost app
only, torn down on every switch, and never a retry loop. DESIGN R5 already requires this; the
tab-counting feature makes it load-bearing.

**7. The ledger is itself new data.** It records metadata about reads. It must contain lengths and
enum cases only, must be pruned on the same retention schedule, and must be covered by the canary
test — otherwise the privacy feature becomes a privacy liability.

**8. Interval hygiene.** Sleep, wake, screen lock, fast user switching, display sleep and app crashes
must all close the open interval, or a laptop closed at 18:00 and opened at 09:00 records a
fifteen-hour Xcode session. Every notification in §2.1 exists for this reason and each needs a test.

---

## 6. The smallest first slice that proves or kills it

The claim under test is **not** "can we capture bundle IDs" — that is a morning's work and never in
doubt. It is: **do timing-only signals produce observations the user judges both true and worth
knowing?** So the slice must ship observations, not infrastructure.

**Build — about a week, all of it compiling and testing on this machine today (no Xcode, no
permissions, no `@Model`, no `#Preview`):**

1. `LggrApp/Services/ActivitySampler.swift` — the `NSWorkspace` + sleep/wake/lock observers of §2.1,
   emitting `ActivitySample`. `@MainActor`. ~150 lines.
2. `LggrApp/Services/IdleMonitor.swift` — `CGEventSource`, 5 s poll, threshold from `UserPreferences`.
   ~40 lines.
3. `LggrKit/Domain/ActivityCoalescer.swift` — merge only when `next.startedAt − prev.endedAt ≤ 2 s`,
   preserving DESIGN §6.7.3's exclusion-gap rule. Pure. Tested.
4. `LggrKit/Domain/AppCatalog.swift` — ~120 bundle-ID prefixes → `ActivityCategory`. Pure. Tested.
5. `LggrKit/Domain/ShapeOfWork.swift` — **the actual bet.** Longest run, fragmentation index,
   alternation bigrams with median gap, excursion/return pairs, warm-up latency, switch rate,
   circadian profile. All pure functions over `[ActivityInterval]`, all unit-tested with
   `swift test`. This is where the intelligence lives and it needs no permission to write, run or
   verify.
6. `LggrKit/Domain/ObservationBuilder.swift` — deterministic sentences from §3.4, with the browser
   caveat line.
7. The §3.1 evidence panel on the existing review sheet, the §3.2 untracked-block reconstruction on
   Today, and a minimal §3.3 Record screen: counts, the field table, delete.

**Deliberately not in the slice:** window titles, Accessibility, Apple Events, calendar,
FoundationModels, the ledger, the canary test. Those are Tier 1+ and are pointless to build before
Tier 0 has earned or lost the argument. (The type boundary in §2.3(a) is designed in from day one so
that Tier 1 can only ever be added the right way.)

**Run it for five working days on the author's own machine. Then two measurements.**

**Kill test A — the value test.** Present the ten strongest generated observations, one at a time, in
a local rating sheet the app already knows how to draw. Two questions each: *Is this true?* /
*Is this worth knowing?*

> **If fewer than 6 of 10 are both true and worth knowing, the bet is dead.** Timing-only intelligence
> is then insufficient, content capture is mandatory rather than optional, and this proposal should be
> abandoned in favour of one that reaches for titles — with the type boundary and the Record screen
> salvaged from it, because those are correct regardless of who wins.

**Kill test B — the blind-spot test.** Measure browser share of tracked time.

> **If it exceeds 35%, Tier 0 is structurally blind on a third of the day** and the correct next
> investment is Tier 1-D's content-free tab-switch counting, not more timing mathematics computed over
> a hole.

Both tests are cheap, both are falsifiable, both produce a decision rather than a discussion, and
neither requires a single permission to run.

---

## Adversarial review

> Hostile read against `SPEC.md` (§4, §5, §9, §10, product principles, design direction),
> `CONSTRAINTS.md`, `DESIGN.md` §3.11, §4.2.5, §6, and the actual repository state
> (`Resources/Lggr.entitlements`, `Scripts/check-layering.sh`, `.build/…/LggrApp`).
>
> Claims marked **[verified]** were compiled and run on this machine, or read out of the repo.
> Where the proposal is right, it is credited — a review that cannot concede is not a review.

### 0. What survives scrutiny

Three things hold up and should not be re-litigated by the next reviewer:

- **The `CGEventType(rawValue: ~UInt32(0))` snippet works.** **[verified]** I expected it to return
  `nil` and kill idle detection at birth. It does not: `0xFFFFFFFF` collides with
  `kCGEventTapDisabledByUserInput`, so the initialiser succeeds and
  `secondsSinceLastEventType` returns a real value (measured 8.86 s, then 25.56 s). The only defect is
  cosmetic — `private static let anyInput = …` followed by `guard let anyInput else { return 0 }` at
  *type* scope does not compile; the `guard` has to be inside the accessor.
- **The §2.3(a) type-boundary is the right idea**, and `check-layering.sh` really is the right place
  to enforce it. See §1.7 for why the stated implementation cannot be written as described.
- **The citation trail is honest.** I checked `DESIGN.md` §6.1.2, §6.1.6, §6.3, §6.6, §6.7.3, §6.7.4
  and R5 individually. All exist and all say what the proposal claims they say.

Everything below is what is wrong.

---

### 1. Technical impossibility — the named APIs, one at a time

#### 1.1 `com.apple.security.network.client: false` is inert, and the Record screen ships it as proof **[verified]**

This is the most serious technical finding in the document, and it is fatal to §3.3 as written.

`Resources/Lggr.entitlements` in this repo sets:

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
```

Sandbox entitlements constrain **only a sandboxed process**. In an unsandboxed build,
`com.apple.security.network.client: false` restricts precisely nothing — the app has unrestricted
outbound network access and always has had.

The second clause fails too. §3.3 renders:

> `Network — No networking framework is linked. com.apple.security.network.client: false`

`otool -L .build/arm64-apple-macosx/debug/LggrApp` **[verified]** shows `Foundation` linked, and
`URLSession` lives *inside* Foundation on Darwin. I compiled a binary importing nothing but
Foundation and instantiated `URLSession.shared` successfully **[verified]** — it resolved to
`__NSURLSessionLocal`. No separate network framework ever appears in a load command. So "no
networking framework is linked" is trivially true and carries **zero information**: the app can make
an HTTP request today, from any file, with no new link edge and no entitlement change, and
`otool -L` would look byte-identical.

§3.3 makes this worse rather than better by insisting the block is *"read out of the running
bundle's entitlements and `otool`-visible load commands rather than typed into a string."*
Computing a false guarantee at runtime does not make it true; it makes the app an automated
generator of a false guarantee, on the one screen whose entire purpose is to be non-theatrical.
This is the exact failure §2.4 condemns, committed by §3.3.

**Actionable, pick one:**
- Ship a genuinely sandboxed build and the entitlement becomes real — but then see §1.4.
- Or delete the "Network" row and replace it with something checkable: a `LggrKit`-level rule that
  no target may `import Network`/`CFNetwork`, enforced in `check-layering.sh` alongside the existing
  rules, plus a plain sentence *"Lggr makes no network requests"* with no fake mechanism attached.
- The "Full Disk Access — not requested" row has the same defect: FDA is never "requested" by an
  app, it is granted by the user dragging any binary into a list. And "Screen Recording — Lggr does
  not appear in that pane" is true only because the API was never called; it reads as an
  OS-enforced guarantee and is not one.

#### 1.2 Idle is forgeable by any process on the machine, with no permission **[verified]**

`secondsSinceLastEventType` is not a measurement of the human. It is a measurement of the event
stream, and **any** process can write to that stream. I posted a single synthetic `mouseMoved`
event and measured, before and after:

```
before            combined= 24.601   hid= 24.601
after synthetic   combined=  0.294   hid=  0.305
```

Both `.combinedSessionState` **and** `.hidSystemState` were zeroed, whether the event was posted to
`.cghidEventTap` or `.cgSessionEventTap`. Choosing a different `CGEventSourceStateID` does not help.

Real software that does this routinely: Screen Sharing / ARD (a remote session posts events, so an
unattended machine being administered reads as a human at the keyboard), mouse jigglers, Karabiner
and other remappers, BetterTouchTool, Logitech Options, Zoom's remote-control feature, and any
accessibility tool that synthesises input.

Now combine with the proposal's own §5.3 admission that idle **over**-reports for video, reading and
calls. The idle bit is therefore wrong in **both directions**, and §2.1 lists it as one of only five
fields in the entire Tier 0 capture surface. It is not a peripheral signal: idle is the boundary
condition that defines *longest unbroken run*, *fragmentation index* and *warm-up latency* — every
headline number in §3.1 and items 1, 2 and 5 of §2.2.

**Actionable:** stop letting idle define "unbroken." Define an unbroken run as *frontmost-app
continuity* (a signal Lggr actually observes reliably) and demote idle to a display-only annotation.
If idle must stay load-bearing, cross-check it against `CGDisplayIsAsleep(CGMainDisplayID())` and
`CGSessionCopyCurrentDictionary()`'s `kCGSSessionOnConsoleKey`, and persist an
`idleConfidence: .high/.low` per interval so the analytics can exclude low-confidence boundaries.

#### 1.3 There is no content-free tab-switch signal in the Accessibility API

§2.3(b) calls browser tab counting *"the single best return on the Accessibility grant,"* §5.2 makes
it the mitigation for the browser blind spot, and §6's Kill test B names it as the correct next
investment. The named APIs do not do this.

- **`kAXTitleChangedNotification` is not a tab counter.** It fires on every mutation of the window
  title, which in a browser is `document.title`. Gmail, Slack-in-a-browser, Linear and GitHub rewrite
  the title on every unread-count change; a page with a clock or a live counter in the title fires it
  at ~1 Hz indefinitely. `distinctFocusChanges` in a browser therefore measures **notification
  volume**, not switching — and it is an unbounded wake-up source (see §3.3).
- **`kAXFocusedWindowChangedNotification` does not fire on a tab switch.** A tab is not an
  `AXWindow`. Switching tabs changes the focused *element* inside one window.
- The attribute that actually distinguishes one tab from another is the web area's `AXURL` (or its
  title). Reading `AXURL` is reading a **full URL**, which §4.2 forbids outright.

So the one signal that would rescue browser-centric users does not exist at the stated permission
level. This is not a detail: it means Kill test B has no remedy branch, and the proposal's answer to
its own largest structural risk is a capability it cannot build.

**Actionable:** either accept the browser blind spot permanently and say so on every affected number
(the proposal already does this well in §3.4), or move browser splitting to the Automation rung
(§4 rung 2), which the proposal already accepts and which returns a *host*, not a URL. Delete the
tab-counting claim from §2.3(b), §5.2 and §6.

#### 1.4 "Available to a sandboxed build" is true for Tier 0 and self-defeating

§2.1 asserts the Tier 0 surface works sandboxed. Mostly right — `NSWorkspace` activation
notifications, `CGEventSource` idle and container file I/O are all sandbox-safe. Two problems:

- `DistributedNotificationCenter` observation of `com.apple.screenIsLocked` is **undocumented**, and
  the parenthetical *"stable 10.13–26"* is asserted with no evidence in a document that elsewhere
  insists on verification over assertion. It is also not posted for display-sleep-without-lock or for
  fast user switching. Supported alternative: `CGSessionCopyCurrentDictionary()` →
  `CGSSessionScreenIsLocked` / `kCGSSessionOnConsoleKey`, paired with
  `NSWorkspace.sessionDidResignActiveNotification`.
- If you *do* sandbox in order to make §1.1's entitlement claim real, the store moves from
  `~/Library/Application Support/Lggr/store.json` (DESIGN §6.8.1) into
  `~/Library/Containers/…/Data/…`. That breaks §3.3's *"Everything is in one file on this Mac"* and
  its `Reveal in Finder` affordance, which is a load-bearing part of the trust argument. The proposal
  never notices that its privacy claim and its transparency claim are in tension.

#### 1.5 Fast user switching has no observer, and the failure mode is other people's data

§5.8 lists fast user switching as mandatory interval hygiene. §2.1 — the complete stated capture
surface — contains **no notification for it**. The correct ones,
`NSWorkspace.shared.notificationCenter`'s `sessionDidResignActiveNotification` /
`sessionDidBecomeActiveNotification`, are absent.

Without them: user A's interval stays open when user B switches in, and because
`secondsSinceLastEventType(.combinedSessionState, …)` keeps getting reset by **user B's** typing
**[verified: any posted event zeroes it]**, user A is never marked idle. Lggr records user B's work
as user A's unbroken focus run. On a shared family Mac that is a two-hour phantom session; under the
proposal's own threat model (§2.4 — "another local account") it is Lggr silently observing a
different human.

#### 1.6 `AXUIElementSetMessagingTimeout(0.25)` and `@MainActor` are in direct conflict

§6 build item 1 specifies `@MainActor`. §5.6 mandates a 0.25 s messaging timeout.
`AXUIElementCopyAttributeValue` is a **synchronous mach IPC round-trip to the target process**; an
unresponsive app burns the full timeout. DESIGN R5 already names this *"the single most likely
beachball in the product."* A user alt-tabbing through five apps stalls the main actor for up to
1.25 s while the menu-bar timer is ticking on it.

The proposal never states which thread AX runs on. It cannot be the main actor, but `AXObserver`
requires a `CFRunLoop`, so this needs a dedicated thread with its own run loop, and
`FocusedContextReader.derive` must be non-isolated. That is a real architectural requirement that
DESIGN §3.8 (three isolation domains, "no custom global actors, no DispatchQueue") currently forbids.
Resolve it explicitly or the feature is unimplementable inside the stated concurrency model.

#### 1.7 §2.3(a)'s `CFStringFind` mechanism cannot be written as described, and does not mean what it claims

Two independent problems with the load-bearing privacy mechanism.

**It trips this repo's own lint.** `AXUIElementCopyAttributeValue` hands back `CFTypeRef?`. Getting a
`CFString` out of it in Swift requires `as!` or `unsafeBitCast`. `Scripts/check-layering.sh`
**Rule 4** fails the build on `as!`, and CONSTRAINTS rule 4 bans force unwraps. **[verified — read
the script.]** Write it as `CFGetTypeID(v) == CFStringGetTypeID()` followed by a conditional
`as? CFString`, and say so, because the naive implementation does not build here.

**The security claim is substantively false.** *"The characters are never copied into Swift-managed
memory"* is true and irrelevant. The AX call **deserialises the string into Lggr's address space** —
that is what a copy-out IPC does. "CoreFoundation-owned" versus "Swift-managed" is not a security
boundary: same process, same heap, same core dump, same `vmmap`, same crash report. §2.4's second
residual half-concedes this, then §2.3(a) spends it as though it were a guarantee. Downgrade the
claim to what it actually buys — a shorter lifetime — and stop calling it a memory-layout property.

#### 1.8 Smaller API defects

- **`NSWorkspace.didActivateApplicationNotification` never fires for the app that is already
  frontmost at launch.** Every launch loses its first interval unless seeded from
  `NSWorkspace.shared.frontmostApplication`. Not mentioned.
- **It does not fire on a Space switch between two windows of the same app.** Xcode on Space 1 and
  Xcode on Space 2 are one continuous run. `NSWorkspace.activeSpaceDidChangeNotification` exists and
  is unused. See §3.7.
- **`screensDidSleepNotification` fires only when *all* displays sleep.** On a laptop with an
  external display awake, it never arrives — and the multi-display case is the common one for the
  target user.
- **`FoundationModels`**: the macro analysis is right and consistent with CONSTRAINTS. But
  `SystemLanguageModel.default.availability` is itself macOS 26+ API against a macOS 14 deployment
  target, so even the *availability check* needs `#available` and weak linking. CONSTRAINTS records a
  default target of `arm64-apple-macosx26.0` against a stated deployment floor of macOS 14; §4.1
  should say which one it is compiling against.
- **EventKit**: the all-or-nothing analysis is correct. But an `EKEvent` returned by
  `events(matching:)` has already materialised `title` in-process, so `CalendarReader`'s "struct with
  no `String` field" has exactly the in-memory property §2.3(a) grades harshly. Be consistent, or the
  standard is applied unevenly.

---

### 2. Creepiness — where this becomes surveillance

#### 2.1 The category channel is a covert content channel, and it violates SPEC §4 indirectly

§2.5 keeps `RuleMatchType.windowTitleContains` and stores the match string, defended as *"the user
typed it themselves."* That defence protects the **rule**. It does not protect the **derived
timeline**, and the proposal never separates the two.

A user writes one rule: `windowTitleContains: "ACME"` → Coding. `store.json` now contains a
second-resolution record of exactly when a document containing the string "ACME" was frontmost.
Join it against the rules table — which lives in the same file — and you have reconstructed a
customer-activity log. Under the document's own threat model (§2.4: Time Machine, a stolen laptop, a
device handed to IT, a subpoena of the disk), a join across two tables in one file is not a
meaningful obstacle.

The brief's test — *"a window title that contains a customer name is a customer record"* — is met
here. Three bits per switch is a per-sample figure; the proposal never multiplies it by 412 reads a
day, and never accounts for the rule table as the decoding key sitting next to the ciphertext.

**Actionable:** never persist rule provenance per interval. Store the resulting `ActivityCategory`
with `classificationSource: .titleRule` and no rule identifier, so the timeline cannot be joined back
to the authored string. Warn on rule creation when a match string is high-entropy or looks like a
proper noun.

#### 2.2 `reads.json` is finer-grained than the store it audits, and `inputBytes` is not content-free

§5.7 correctly flags the ledger as new data, then under-scopes the fix to "lengths and enum cases
only," as though a length were inert. It is not:

- **Granularity.** The ledger is **per read** (412 rows/day by §3.3's own numbers) where `store.json`
  is per *coalesced interval*. The audit artefact therefore reconstructs the day at higher resolution
  than the thing it exists to audit — including inside apps the user marked **private**.
- **`inputBytes` is a title-length time series, per app, per second.** Length changes segment the day
  into distinct-document runs. In Messages it tracks contact-name length. It buys nothing: the audit
  claim is `"retained": false`, and a length does not corroborate that.

**Actionable:** drop `inputBytes` entirely. Aggregate the ledger to hourly counts per
`(api, target, output)` rather than per-read rows. And extend DESIGN §6.7.2's excluded/private field
table to cover both **new** fields — the ledger row *and* `distinctFocusChanges` — because right now
§3.3 lists "Focus changes within the interval (a count) — 412 of 6,412" with no private-app carve-out
at all. "23 focus changes in 1Password at 02:14" is a count of vault items viewed, and a private app
is supposed to be exempt from exactly that.

#### 2.3 The transparency screens are the most screen-shared surfaces in the app

Would a reasonable engineer be uncomfortable if a colleague saw this? Yes, at four specific places,
and all four are creations of *this* proposal rather than of SPEC:

- **§3.3's "Example from your data" column** renders the user's real browser host next to real app
  timings, on the screen a privacy-curious user is most likely to show someone else.
- **§3.2's Today panel** renders `13:10 – 13:58 · 48 min · Slack, Mail, Messages` in the primary
  dashboard. A colleague glancing at your screen learns you spent 48 minutes in Messages.
- **§3.4's weekly line** *"2 h 51 m of Wednesday was tracked but not inside any session. Most of it
  was Zoom and Slack."* SPEC's Export section is **in scope** and produces Markdown. This sentence is
  a diligence report about a named human, and it leaves the machine by design.
- **§3.1's warm-up line** *"It took 6 minutes from starting the session to your first block longer
  than 5 minutes."*

**Actionable:** put the example column behind a click-to-reveal; collapse §3.2 by default; and
exclude untracked-time totals and warm-up latency from every export.

#### 2.4 Attendee count plus exact times is a quasi-identifier

Rung 3 stores start, end, all-day flag, **attendee count** and status, and calls this "never
identifying" because it contains no text. Against a shared team calendar — which everyone at the
company has — a 3-person event from 14:00 to 14:30 on Wednesday resolves to exactly one meeting.
§3.4's *"this untracked block sits inside a 3-person event"* is, in an exported weekly review, a
statement about a specific identifiable meeting with specific identifiable people.

**Actionable:** bucket the count (`oneToOne` / `small` / `large`), round times to 15 minutes in
anything exported, and drop `status` — it adds nothing and leaks whether you declined.

---

### 3. Battery, CPU and correctness

#### 3.1 Two always-on timers, and "sub-microsecond" measures the wrong thing

§2.1 defends the 5 s idle poll as *"sub-microsecond."* That is the cost of the **call**, not the cost
of the **wake-up**. A 5 s repeating main-run-loop `Timer` is 17,280 wake-ups a day, defeats timer
coalescing, and keeps the process out of App Nap — on top of the menu-bar tick that DESIGN R4 already
flags as a battery risk. Two always-on timers in a lightweight tracker is one too many.

**Actionable:** `DispatchSourceTimer` with `leeway` ≥ 2 s; back off to 60 s once idle already exceeds
the threshold (the only transition that matters then is *return*, and that is what the next
`didActivateApplication` tells you); suspend entirely on `screensDidSleep`, screen lock and
`sessionDidResignActive`.

#### 3.2 AX cost per app switch is unbounded and lands on the main actor

Covered in §1.6. Additionally: §5.6 mandates creating and tearing down an `AXObserver` **on every
switch**. `AXObserverCreate` + `CFRunLoopAddSource` + teardown per switch is expensive during
alt-tab bursts and is racy against target-app termination — the callback context can outlive the
observed process. Prefer one long-lived observer retargeted on switch, and hold a weak association
keyed by pid that is invalidated from `didTerminateApplicationNotification`.

#### 3.3 The browser title observer is a permanent wake-up source

From §1.3: `kAXTitleChangedNotification` on a page with a live `document.title` fires at ~1 Hz
forever. Each firing runs a callback and, per §2.3(b), a title read — an IPC round-trip. This is a
continuous background load caused by an arbitrary web page, on a feature sold as low-cost.

#### 3.4 Sleep and wake: one missing signal manufactures activity, one manufactures a 15-hour session

- **Power Nap / Dark Wake** delivers `didWakeNotification` with the lid shut and nobody present.
  §2.1 says *"open a fresh one."* Lggr will manufacture activity at 03:00. Gate interval reopening on
  `CGDisplayIsActive(CGMainDisplayID())` or on screen *unlock*, never on `didWake` alone.
- **`willSleepNotification` is not delivered** on power loss, kernel panic or forced shutdown, so the
  open interval survives to the next launch — the exact fifteen-hour-Xcode-session bug §5.8 says it
  is preventing. The notification set cannot fix this on its own. **Actionable:** persist an
  `openInterval` marker with a heartbeat (say every 60 s); on launch, if a marker exists, close the
  interval at *last heartbeat*, not at launch time or at `willSleep`.

#### 3.5 Timezones and DST are unhandled, and they corrupt the headline metrics

`ActivitySample` (DESIGN §4.2.5) has no timezone field, yet §2.2 item 6 is a **circadian** profile and
SPEC §9 demands *"before 11:00 AM."*

- A week with travel silently smears the hour-of-day histogram across two zones. The observation
  *"your longest stretches started between 9:00 and 11:00 on four of five days"* is then simply false
  and unfalsifiable by the user.
- Durations derived from `Date` deltas are wall-clock. A DST transition, an NTP step or a manual
  clock change yields negative or multi-hour "unbroken runs" — and *longest unbroken run* is the
  single number §3.1 puts in 24pt type. DESIGN R8 covers clock changes for the session timer; nothing
  covers it for `ShapeOfWork`.

**Actionable:** persist `tzOffsetMinutes` per interval and bucket by the local hour *in effect at
capture*; compute durations from a monotonic source (`ContinuousClock` / `mach_absolute_time`) and
carry both, so a wall-clock/monotonic disagreement can be detected and the interval dropped.

#### 3.6 Multiple displays and Spaces

`didActivateApplicationNotification` does not fire when the user switches Spaces between two windows
of the same app, so a "38-minute unbroken Xcode run" may be two unrelated pieces of work.
`activeSpaceDidChangeNotification` exists and is unused. `screensDidSleepNotification` requires *all*
displays to sleep. Both matter most for the multi-monitor desk setup that the target user has.

#### 3.7 One algorithmic note

§2.2 item 3 (alternation bigrams with median excursion length) recomputed on every session end, over
a day of intervals, is easy to write as O(n²) with a per-pair median scan. Specify it as a single
pass accumulating per-ordered-pair reservoirs, or it becomes a visible stall on the review sheet —
the one sheet SPEC requires to feel instant.

---

### 4. Being wrong

#### 4.1 §3.2 writes real sessions at 84% confidence, with no provenance and no undo

One click on *"Log as a Lggr session"* writes a `FocusSession` with a project. Get the project wrong
and you have silently corrupted the exact number SPEC §9 requires: *"the primary weekly outcome
received only 18% of your tracked time."* §5.4 specifies a 70% confidence floor. It specifies no
provenance field, no visual distinction, no exclusion from aggregates, and **no undo**.

The realistic failure is not a bad classifier, it is a tired human at 18:00 clicking through a
triage queue and accepting three suggestions to make the panel go away. Ten days later the weekly
review is confidently wrong and there is no way to tell which sessions were declared and which were
guessed.

**Actionable:** add `FocusSession.provenance: .declared | .reconstructed`; render reconstructed
sessions distinctly **forever**, not just on the day; state the reconstructed share next to every
weekly percentage; ship a single "undo today's reconstruction" action.

#### 4.2 Is a wrong auto-filled summary worse than a blank one? Here, yes

§3.1's generated sentence — *"Left for Slack four times, 6 minutes in total"* — lands in the
accomplishment log that SPEC §10 says the user opens on Friday to *"see evidence of what they
delivered."* If the Slack count is wrong because idle was forged (§1.2), a Space switch was missed
(§3.6), or an interval was mis-closed (§3.4), the user's own record of their week is wrong in a way
they cannot detect, and it is phrased with the confidence of a measurement.

A blank summary costs thirty seconds of typing. A wrong one gets confirmed, propagates into the
weekly review and the Markdown export, and is never caught.

**Actionable:** the prose summary is editable — good. The **derived numbers in the evidence panel are
not**, and they should be: let the user delete or split an interval, and let a session be marked
"the timing data for this is wrong" so it is excluded from `ShapeOfWork` aggregates.

#### 4.3 §5.3's own mitigation ships the flattering error the proposal condemns

§5.2 correctly identifies undercounting as *"a flattering error, the worst kind."* Then §5.3
mitigates false-idle-during-meetings with *"never mark idle while an app in the Meeting category is
frontmost."*

Leave Zoom open over lunch and that rule produces sixty minutes of attentive meeting time. It
converts a false negative into a false positive in the flattering direction — the failure mode the
document names as the worst kind, two pages earlier.

**Actionable:** cap meeting-idle tolerance at a duration (e.g. mark idle after 10 minutes of no input
even in a meeting app), or require corroboration — microphone-in-use is out of scope, but
`IOPMAssertion` "prevent display sleep" held by the conferencing app is observable and is the signal
that actually distinguishes an active call from an abandoned window.

#### 4.4 Derived statistics are uncorrectable, which SPEC §5 does not allow for classification and should not allow here

SPEC §5 requires that a user can fix a classification and get a reusable rule. §4.1's third argument
against on-device models is precisely *"it is not correctable."* That standard is not applied to the
proposal's own output. *"Xcode and Terminal alternated tightly enough that Lggr counts them as one
activity"* is a claim the user may know to be false — and there is no gesture that says so. The 2 s
coalescing threshold, the bigram clustering, the 5-minute "sustained block" and the 8-minute
untracked-block floor are all global constants with no override anywhere.

If "the model decided" is disqualifying, "the constant decided" needs at least a visible value and a
per-session override.

#### 4.5 Kill test A is structurally incapable of killing

N = 1. Unblinded. Self-rated. By the author of the bet. Over five days. On ten observations that the
author's own `ObservationBuilder` pre-selected as *"the ten strongest."* Every bias in the design
points the same way, and the 6/10 threshold has no derivation.

**Actionable — make it able to fail:** pre-register the ten observation *types* before looking at any
data; generate **twenty** observations of which ten are decoys (same sentence templates over shuffled
days, permuted app labels, inverted comparisons); rate blind and in random order; and require the
true observations to beat the decoys by a stated margin. If a person cannot distinguish a real
finding about their week from a shuffled one, the signal is not there — and that is the question this
test is supposed to answer.

#### 4.6 Kill test B is guaranteed to pass, on the wrong machine

Browser share is measured on the author's Mac. The author is a Swift developer building a native
macOS app in Xcode — the single least browser-centric user in SPEC's stated audience of *"engineering
managers, developers, and knowledge workers."* The engineering manager this product is aimed at lives
in Chrome all day. The 35% threshold has no stated derivation either.

The test will return something like 15%, the team will conclude the blind spot is tolerable, and the
conclusion will be an artefact of who ran it.

**Actionable:** run it on at least one EM and one non-developer knowledge worker before the number
means anything; and measure the browser share of **switches**, not of time, since switches are the
metric the blind spot corrupts.

#### 4.7 Project inference has a degeneracy problem that a confidence floor does not fix

§2.2 item 10 is cosine similarity over bundle-ID dwell vectors. For a developer whose every project
is Xcode + Terminal + Chrome, *all* project vectors are near-identical — so the top match and the
runner-up are separated by noise. §5.4's fix is an absolute floor (~70%), which addresses low scores
but not **indistinguishable** ones: two projects at 0.88 and 0.87 both clear the floor and the
choice between them is a coin flip presented as "88% match."

**Actionable:** gate on the *margin* between first and second match, not on the absolute score, and
suppress the suggestion entirely when the top two are within a few points.

---

### 5. Product principle violations

#### 5.1 "Not in a session today — 2 h 51 m" is a shaming metric

SPEC's design direction bans *"productivity scores that shame the user."* §4.2 of this proposal bans
*"a single number that summarises a person."*

Untracked time is, by construction, the number that grows when you fail to comply with the app.
Presenting it as a headline total on Today — the calm dashboard SPEC principle 5 wants readable at a
glance — is enterprise timesheet UX, which SPEC principle 4 explicitly guards against.

**Actionable:** title the block *"Also tracked"*, list the blocks, and never render the total, never
compare it to the length of the day.

#### 5.2 §4.2 bans scores, then §2.2 ships three

- **Fragmentation index** (item 2) is a literal 0–1 score, per app, per session.
- **Switch rate vs personal baseline** (item 7) is a ratio rendered as *"2.1× your four-week median."*
- **Warm-up latency** (item 5) is *"it took you six minutes to start,"* which is the most judgmental
  sentence in the document.

Self-relative scores are still scores; "compared to your own median" is the standard framing of
every gamified tracker on the market. Either drop the §4.2 prohibition as unmet, or drop these three
from the surfaced set and keep them internal.

#### 5.3 §3.2 adds manual entry while claiming to remove it, and cites the wrong principle

*"This is Principle 6 delivered — it removes typing rather than adding fields."* Two errors:

- **SPEC principle 6 is "Every screen should have a clear primary action."** Minimal manual data
  entry is principle **2**. The document cites principle 6 for this twice (§2.2 item 10 and §3.2), in
  a section headed "binding inputs."
- **It does not remove typing; it adds a daily chore.** N blocks × 3 buttons, every evening, forever
  — and *"Different project…"* opens a picker, which is manual entry. Today a user who does not
  declare a session simply has no session. After this, they have a queue.

This is Toggl's timeline-confirmation flow, and Toggl is the product SPEC principle 4 is defining
Lggr against. **Actionable:** show at most the single largest untracked block, only when it exceeds
some real threshold, with one button and a dismiss — not a queue.

#### 5.4 A whole sidebar item for privacy accounting breaks SPEC's navigation contract

SPEC's navigation is a fixed seven — Today, Focus Sessions, Accomplishments, Weekly Review, Projects,
Rules, Settings — with ⌘1 through ⌘7 specified as a keyboard contract. §3.3 demands an **eighth**
top-level item ("a dedicated sidebar item, not a Settings tab"), which breaks that mapping and spends
the app's scarcest surface on a screen the user visits perhaps twice. It also violates principle 7
(progressive disclosure) at the top level of the app.

DESIGN §6 already specifies a Settings → Privacy screen. **Actionable:** build the Record screen
there, and deep-link to it from onboarding and from every permission prompt. The content is good; the
placement is not.

#### 5.5 The shipped self-test is theatre by the proposal's own §2.4 criterion

§2.4 sets the standard: verification the user can *perform*, over their own data. The self-test does
not meet it. It builds a **synthetic** day, in a **temporary** store directory, with configuration
**the test controls**, and then reports on that.

The decisive case: a user who has enabled §2.5's per-app **Stored** mode for Xcode and Linear will
see *"passed, 0 hits"* while their real `store.json` contains thousands of real window titles —
because the canary run does not use their allow-list. The reassurance screen ships a false
reassurance, precisely inverting its own purpose.

**Actionable:** keep the canary in CI as `PrivacyCanaryTests` where it belongs. The *shipped* button
should scan the **real** store and report real counts against the user's **actual** configuration:
"your store contains 4,113 window titles from 2 applications you allow-listed; 0 from any other app."
That is a number the user can act on. The canary is a developer test wearing a user-facing coat.

#### 5.6 A feature that only works for one kind of user — and the document knows it

All twelve Tier 0 signals presuppose a day composed of several distinguishable native apps with
short, meaningful alternations between them. That describes a developer working in Xcode and
Terminal. It does not describe the engineering manager in SPEC's target list, whose day is Chrome,
Slack and Zoom.

For that user, Tier 0 produces one opaque browser block, one Slack block and one Zoom block. Every
signal degrades **simultaneously and to nothing**: fragmentation is undefined inside one app,
alternation bigrams have two rows, warm-up latency is meaningless, interruption-source ranking has
one candidate, and project inference has identical vectors for every project. And per §1.3, the
remedy the proposal reserves for this case does not exist at the stated permission level.

Rung 0's claim — *"this **is** the product"* — is true for native-app developers and false for the
rest of the stated audience. Say so explicitly, choose the wedge deliberately (SPEC principle 12
favours the smallest polished slice, and "for developers first" is a legitimate choice), but do not
present a developer-only capability as universal.

#### 5.7 Nagging: credit, with one caveat

§4's commitment — never more than one banner, never coloured, never during a session — is correct and
better than SPEC requires. But §4 then requires three dense "honest statements" about
`AXIsProcessTrusted()`, EventKit scopes and private-window detection to appear **on the permission
screens themselves**, at the exact moment of highest friction, against SPEC's instruction that
user-facing copy be *"concise and natural."* One sentence each, with the rest behind a disclosure
triangle.

#### 5.8 AI where a rule would do — mostly avoided, but §4.1's carve-out should be cut

§4.1's refusal to route captured content through a language model is the strongest argument in the
document and should be preserved verbatim. The carve-out for authored text is defensible in
principle, but it is gated on macOS 26 **plus** Apple Intelligence eligibility against a macOS 14
floor, and the proposal itself supplies the argument that kills it: *"if that fallback is adequate
the model was unnecessary."* `SessionSummaryBuilder` already exists and is already tested.

**Actionable:** cut it from scope entirely rather than deferring it. It is a feature for a minority of
machines, duplicating a component that already ships.

---

### 6. Verdict

**KEEP WITH CHANGES** — the core bet is right and unusually cheap to test: the shape of activity over
time genuinely does carry most of SPEC §9, `ShapeOfWork` is pure, testable today with no permissions
and no Xcode, and inverting SPEC §4's window-title default from Stored to Derived is a better default
than SPEC's own. But three things must change before a line is written: **the Record screen's network
guarantee is false** (§1.1 — the entitlement is inert in an unsandboxed build and `URLSession` ships
inside Foundation, both verified), **the browser tab-count remedy does not exist in the Accessibility
API** (§1.3), which leaves Kill test B with no remedy branch, and **idle is forgeable by any process**
(§1.2, verified), so it must stop defining "longest unbroken run." Then de-shame §3.2 and §3.4, add
provenance and undo to reconstruction, move the Record screen into Settings, delete `inputBytes`, and
re-design both kill tests so they are capable of returning "kill."
