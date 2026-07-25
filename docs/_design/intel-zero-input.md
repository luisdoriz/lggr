# Lggr — Zero Input

> Design proposal. Lens: **eliminate the typing.** SPEC principle 2 — *the app should require
> minimal manual data entry* — taken seriously enough to become the architecture.
>
> Status: proposal. Nothing here is built. Everything here obeys CONSTRAINTS.md (no Xcode macros in
> `LggrKit`/`LggrApp`, no third-party dependencies, `swift build` and `swift test` green at every
> step) and DESIGN.md § 6 (unsandboxed, hardened runtime, no network entitlement).

---

## 1. The core bet

Lggr already collects, or is about to collect under Phase 3, everything needed to *write the user's
own log for them* — but the current design spends that evidence only on analytics. The bet is that
the evidence stream is not a reporting substrate, it is an **input device**: the frontmost
application, its focused window title, the browser host, the git branch under the file being edited,
and the memory of what the user chose the last twenty times they were in exactly this situation are,
together, enough to propose the intended outcome before the user types a character, the project
before they pick one, the summary before the session ends, and the accomplishment before they
remember they made one. So Lggr stops asking for text and starts asking for **confirmation**: a
proposal rendered as ghost text you accept with Tab, a chip you accept with Return, a category you
change with one click. The hard half of the bet is not generating proposals — it is making a wrong
one cost *nothing*, because a wrong auto-entry is genuinely worse than no entry. That is answered
with one structural rule (**inference never becomes a record without an explicit human accept**),
one interaction rule (**propose as ghost text, never as inserted text**), and one learning rule
(**only typing and correcting change the weights; accepting barely does**), plus a correction loop
that turns each fix into a rule offer with its blast radius shown before you agree to it.

---

## 2. Mechanism

### 2.0 The two storage classes — the load-bearing idea

Everything below produces `Candidate`s, and a `Candidate` is not a record.

```swift
// Sources/LggrKit/Intel/Candidate.swift
public enum CandidateConfidence: Int, Codable, Sendable, Comparable {
    case weak = 0      // never shown; kept for the correction ledger only
    case parsed = 1    // shown as ghost text / a dismissible chip; Tab or Return accepts
    case recall = 2    // shown as ghost text, pre-selected; still requires a keystroke
}

public struct Candidate<Value: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public let id: UUID
    public let value: Value
    public let confidence: CandidateConfidence
    /// One short human sentence: "From Xcode · branch receipt-dedup". Always rendered next to
    /// the proposal so acceptance is never blind.
    public let provenance: String
    public let signature: ContextSignature
    public let createdAt: Date
    /// Unaccepted candidates are deleted after this. They never survive to a second day.
    public let expiresAt: Date
}
```

Rules that are not negotiable:

1. A `Candidate` lives in `candidates.json`, **never** in `sessions.json` or `accomplishments.json`.
2. Candidates are excluded from every export, from the Today totals, and from the weekly review.
3. Candidates expire 24 h after creation, unaccepted, and are purged on launch. An ignored
   suggestion can never become a record by neglect.
4. Accepting a candidate writes a real record carrying its origin:

```swift
public enum RecordOrigin: String, Codable, Sendable {
    case typed          // the user wrote it
    case accepted       // the user accepted a proposal unchanged
    case acceptedEdited // accepted, then edited before saving
    case corrected      // was accepted, then changed afterwards
}
```

`RecordOrigin` is what lets the weekly review say, neutrally, *"28 of 34 blocks were auto-labelled"*,
and it is what makes the whole feature auditable rather than magical.

### 2.1 Capture — what the evidence actually is

**`ActivationRecorder`** — `Sources/LggrApp/Services/ActivationRecorder.swift`, `@MainActor`.

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { note in
    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    …
}
```

Two things that bite here and must be written down: the observer goes on
`NSWorkspace.shared.notificationCenter`, **not** `NotificationCenter.default` (registering on the
default center silently receives nothing), and the notification does **not** fire for window changes
*inside* an application — switching between two Xcode workspaces is invisible to `NSWorkspace`.
Within-app window changes require `AXObserverCreate` + `kAXFocusedWindowChangedNotification`, which
is Accessibility-gated; without it, an editor switch is not a context switch, which is the honest
and defensible reading anyway.

The recorder keeps a ring buffer of the last 8 activations. **This is the whole reason it exists:**
by the time the start panel is on screen, Lggr is frontmost, so `NSWorkspace.shared
.frontmostApplication` returns Lggr. The candidate engine needs the *last non-Lggr* activation, and
only a buffer has it. Zero permissions; gives bundle identifier, localized name, pid, activation
timestamp.

**`WindowTitleReader`** (already scoped in DESIGN.md § 6.1.1) — `AXUIElementCreateApplication(pid)`
→ `kAXFocusedWindowAttribute` → `kAXTitleAttribute`. Accessibility. Per DESIGN.md R5: 0.25 s
`AXUIElementSetMessagingTimeout`, read once per activation and never on a timer, skipped entirely
while `IsSecureEventInputEnabled()` is true, and skipped for private/excluded apps **before the read
is issued**, not after.

**`DocumentPathReader`** — new, and the only genuinely new capture surface proposed here.
`kAXDocumentAttribute` on the focused window returns a file-URL string for document-based apps.
Xcode sets it to the open file. This is what unlocks the git branch:

```swift
// Sources/LggrKit/Intel/GitHeadReader.swift — pure given an injected file reader
// /Users/me/dev/lggr/Sources/…/Foo.swift
//   → walk up to the first directory containing ".git"
//   → read ".git/HEAD"  →  "ref: refs/heads/feature/receipt-dedup\n"
//   → branch "feature/receipt-dedup", repo "lggr"
```

Reading `.git/HEAD` needs **no permission at all** — it is an ordinary file read of a file the user
owns — *unless the repository lives under `~/Documents`, `~/Desktop` or `~/Downloads`, which are
TCC-protected even for unsandboxed apps* and would raise a surprise *"Lggr would like to access
files in your Documents folder"* prompt. That is exactly the kind of unexplained prompt DESIGN.md
§ 6 refuses. So: git reading is **opt-in and folder-scoped**. Settings → Privacy → *Read branch names
from* → `NSOpenPanel` → the user picks `~/dev` (or wherever), Lggr stores a security-scoped bookmark,
and reads only under that root. Repos outside the chosen roots are simply not read, silently. No
prompt Lggr did not cause, no nagging.

Whether `kAXDocumentAttribute` is populated for **Terminal.app** and iTerm2 (which would give the
shell's working directory via the window's proxy icon) is **unverified on this machine and must be
spiked before it is designed around**. If it is absent, the fallback is the folder name parsed out of
the terminal's title, at `.parsed` confidence instead of `.recall`.

**`BrowserDomainReader`** — exactly as DESIGN.md § 6.1.2 already specifies. Host only; the path is
discarded inside `DomainExtractor` and never reaches any other type. Firefox exposes no scriptable
URL and is never queried.

**Idle** — `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~UInt32(0)) ?? .null)`.
No permission. Returns *how long since* an event, never the event.

**Deliberately rejected capture surfaces.**

| Rejected | Would give | Why not |
|---|---|---|
| `SCShareableContent` (`SCWindow.title`) / `CGWindowListCopyWindowInfo` | Window titles **without** Accessibility | Both require Screen Recording, which also grants pixel access to every window. A strictly larger grant to read the same string. DESIGN.md § 6.1.6 already refuses this; nothing here changes that. |
| `CGEvent.tapCreate` | Keystroke counts → "was the user actually writing?" | Input Monitoring; SPEC § 4 forbids keystroke capture outright. This is why "document written" can only ever mean "document focused and non-idle", and the copy must say so. |
| Speech framework (`SFSpeechRecognizer`) | Dictated outcomes | Costs `NSSpeechRecognitionUsageDescription` + microphone access to replace something macOS already does for free with `fn fn`. Two new permissions to save zero typing. |
| Focus-mode observation | "Meeting starting" without EventKit | **There is no public API** to observe Do Not Disturb / Focus state on macOS. The only routes are reading `~/Library/DoNotDisturb/DB/Assertions.json` or private Control Center defaults. Both are private and brittle. Stated plainly rather than designed around. |

### 2.2 `FocusedContext` and `ContextSignature`

The readers converge on one redacted value type, produced in `LggrApp`, consumed by pure engines in
`LggrKit`:

```swift
// Sources/LggrKit/Intel/FocusedContext.swift
public struct FocusedContext: Codable, Sendable, Hashable {
    public let bundleIdentifier: String
    public let applicationName: String
    public let windowTitle: String?      // nil without Accessibility, or if private/excluded
    public let domain: String?           // nil without Automation, or for Firefox
    public let repository: String?       // nil without a chosen git root
    public let branch: String?
    public let capturedAt: Date
    public let isPrivate: Bool           // if true every other optional is already nil
}
```

The **signature** is the recall key — deliberately coarse, so it still exists at Tier 0:

```swift
public struct ContextSignature: Codable, Sendable, Hashable {
    public let bundleIdentifier: String
    /// repository ?? domain ?? nil — the "where" that survives across days
    public let locus: String?
    /// A normalized subject token from the title, or nil
    public let subject: String?

    /// Coarse-to-fine keys, most specific first, for graded lookup.
    public var lookupKeys: [String] { … }
}
```

At Tier 0 the signature is `(com.apple.dt.Xcode, nil, nil)` — still useful, because *"what do you
usually do in Xcode at 9 a.m."* is a real answer.

### 2.3 `TitleGrammar` — rules, as SPEC § 5 demands, before any model

A table of per-bundle parsers. Pure, table-driven, data-shaped, and unit-tested against captured
fixture strings. Not regex soup scattered through the app: one file, one test file, one fixture file.

```swift
// Sources/LggrKit/Intel/TitleGrammar.swift
public struct ParsedTitle: Sendable, Hashable {
    public var subject: String?      // "receipt deduplication", "Ingestion architecture"
    public var locus: String?        // "lggr", "acme/sor", "#eng-sor"
    public var identifier: String?   // "#412", "LGR-214"
    public var author: String?       // "luisdoriz" — from GitHub's "… by <author> ·"
    public var kind: TitleKind       // .file .pullRequest .issue .document .channel .page .unknown
}
```

The shipped grammars and what they read:

| Application / host | Title shape | Yields |
|---|---|---|
| Xcode | `Lggr — SessionSummaryBuilder.swift` | locus = workspace, subject = file stem |
| VS Code / Cursor | `SessionSummaryBuilder.swift — lggr — Visual Studio Code` | subject = file, locus = folder |
| Terminal / iTerm2 | `lggr — -zsh — 120×30` | locus = folder |
| Chrome/Safari @ `github.com` | `Fix receipt dedup by luisdoriz · Pull Request #412 · acme/sor` | subject, author, identifier `#412`, locus `acme/sor`, kind `.pullRequest` |
| Chrome/Safari @ `linear.app` | `LGR-214 Receipt dedup · Linear` | identifier, subject |
| Slack | `Slack \| #eng-sor \| Acme` | locus = channel, kind `.channel` |
| Notion / Craft / Pages | `Ingestion architecture` (+ app suffix) | subject, kind `.document` |
| *anything else* | — | whole title as `subject`, confidence dropped to `.weak` (i.e. **not shown**) |

Grammars are brittle by nature; they are therefore **data, not control flow** — a JSON table in
`Resources/`, each entry with a fixture in `Tests/LggrKitTests/Fixtures/titles.json`, so adding a
grammar is adding two lines and a test, not editing a switch statement. Because there is no network,
grammars only update when the app updates. That is a real limitation and the fallback (whole title,
suppressed) is what keeps a stale grammar from ever producing a *wrong* proposal — only a missing one.

### 2.4 `ContextMemory` — the part that works with zero permissions

```swift
// Sources/LggrKit/Intel/ContextMemory.swift
public struct MemoryEntry: Codable, Sendable, Hashable {
    public var key: String                 // a ContextSignature lookup key
    public var outcome: String
    public var projectID: UUID?
    public var workType: WorkType?
    public var weight: Double
    public var lastUsedAt: Date
}
```

Weighting is the anti-runaway rule, and it is the single most important line in this document:

| Event | Δ weight |
|---|---|
| User **typed** the outcome | **+4.0** |
| User **corrected** a proposal to something else | **+4.0** to the new value, **−3.0** to the old |
| User **accepted** a proposal unchanged | **+0.5**, capped so acceptance alone can never reach `.recall` |
| Entry unused for 14 days | ×0.9 per week (decay) |

Only typing and correcting can push an entry above the `.recall` threshold. A proposal cannot promote
itself by being accepted — which is precisely the self-reinforcement loop that would otherwise make
the system confidently wrong and impossible to steer out of.

`ContextMemory` is deleted by *Delete activity history*. If it were not, deletion would be a lie: the
raw events would be gone and the app would still know what you were doing.

### 2.5 `OutcomeCandidateEngine` — the outcome, before you type it

Pure, in `LggrKit`, deterministic, fully unit-testable:

```swift
public static func candidates(
    context: FocusedContext,
    parsed: ParsedTitle?,
    memory: ContextMemory,
    calendarEvent: CalendarSnapshot?,
    recentOutcomes: [String],
    now: Date
) -> [Candidate<String>]      // ranked, at most 4
```

Ranked sources:

1. **Recall** — the highest-weight `MemoryEntry` for the most specific matching signature key.
   *"Finish the receipt deduplication PR"*, provenance `You worked on this here on Tuesday`.
   `.recall`.
2. **Branch** — `feature/receipt-dedup` → `Receipt dedup`, provenance `Branch receipt-dedup in lggr`.
   `.parsed`.
3. **Pull request** — `#412 Fix receipt dedup`, provenance `PR #412 in acme/sor`. `.parsed`.
4. **Issue key** — `LGR-214 Receipt dedup`. `.parsed`.
5. **Calendar** — the title of an event whose interval contains `now` (§ 2.9). `.parsed`.
6. **Document / file** — `Ingestion architecture`, `SessionSummaryBuilder.swift`. `.parsed`.

Rank 1 wins whenever it exists, because a thing you actually typed here before beats anything parsed.

### 2.6 Project inference — reusing the rule engine that already exists

`ClassificationRule` already answers *"what category is this activity?"* by matching
`RuleMatchType` (`application`, `applicationName`, `windowTitleContains`, `domain`) against an
`ActivityEvent`. Project inference is the same question with a different answer type, so it gets a
sibling struct rather than a redesign — leaving the persisted shape of `ClassificationRule` alone:

```swift
// Sources/LggrKit/Model/ProjectRule.swift
public struct ProjectRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var matchType: RuleMatchType   // reused verbatim
    public var matchValue: String         // "acme/sor", "lggr", "com.apple.dt.Xcode"
    public var projectID: UUID
    public var priority: Int
    public var isEnabled: Bool
    public var isUserDefined: Bool
}
```

`ProjectInferenceEngine.project(for:rules:memory:)` scores the last 10 minutes of `FocusedContext`
samples: matched rules contribute `priority`, `ContextMemory` entries contribute `weight`, and the
argmax wins if it clears the runner-up by 1.5×. Otherwise: no proposal, the picker stays on
`lastSelectedProjectID`, and the user picks. **Ambiguity produces silence, not a guess.**

`ProjectRule`s are created the same way `ClassificationRule`s are: from a correction (§ 2.11), never
from a form the user has to fill in.

### 2.7 `SessionEvidence` and the generated summary

`SessionSummaryBuilder`'s own doc comment already promises this shape — *"Phase 3 adds application
and category evidence by appending further parameters with defaults, which leaves every existing
call site compiling unchanged."* Honour it exactly:

```swift
// Sources/LggrKit/Intel/SessionEvidence.swift
public struct SessionEvidence: Codable, Sendable, Hashable {
    public struct AppSlice: Codable, Sendable, Hashable {
        public let applicationName: String
        public let activeDuration: TimeInterval
        public let category: ActivityCategory
    }
    public let applications: [AppSlice]        // desc by duration
    public let categories: [ActivityCategory: TimeInterval]
    public let subjects: [String]              // deduped, frequency-ranked ParsedTitle.subjects
    public let domains: [String]
    public let switchCount: Int
    public let idleDuration: TimeInterval
    public let interruptionCount: Int
    /// True if any contributing app was private/excluded — the summary then says so rather than
    /// silently under-reporting.
    public let hasRedactedTime: Bool
}

// appended parameter, defaulted, existing call sites untouched
public static func summary(…, evidence: SessionEvidence? = nil) -> String
```

Deterministic output, matching SPEC § 6's exemplar:

> Deep work on SOR engineering for 52 minutes. Worked primarily in Xcode and Terminal on receipt
> deduplication, opened one GitHub pull request, and spent seven minutes in Slack.

**Then, optionally, a rewriter — never a generator.** `FoundationModels` (Apple Intelligence,
on-device, no network, no entitlement) is available **macOS 26+ only**; the deployment target is
macOS 14, so it lives behind `#if canImport(FoundationModels)` + `if #available(macOS 26, *)` and
`SystemLanguageModel.default.availability == .available` (it can be `.unavailable(.deviceNotEligible)`,
`.unavailable(.appleIntelligenceNotEnabled)`, `.unavailable(.modelNotReady)`).

Three constraints on its use, all of which follow from SPEC § 5's *rule-based before AI*:

- It is handed the **structured `SessionEvidence`**, never raw window titles, and never anything from
  a private or excluded app. Its input is already the redacted, aggregated, rule-derived facts.
- Its job is one sentence of prose smoothing over facts the deterministic builder already produced.
  It may not introduce a fact, a judgement, or an adjective; a `@Generable` struct with `@Guide`
  constraints on each field enforces the shape, and a post-check rejects any output containing a
  number that is not in the evidence.
- It has a **1.5 s budget and is never on the critical path.** The review sheet opens with the
  deterministic string already in the field. If the model returns in time, the field animates to the
  polished version with a `sparkles` affordance and `Regenerate` / `Use the plain version`. If it
  throws (guardrail violation, context overflow, model unloaded) or times out, nothing happens and
  the user never learns there was a model. macOS 14/15 users, and anyone with Apple Intelligence off,
  get the deterministic string forever and lose nothing structural.

### 2.8 `AccomplishmentDetector` — the log writes itself, one Return at a time

Pure rules over the evidence stream, emitting `Candidate<Accomplishment>`:

| Rule | Evidence | Emits |
|---|---|---|
| PR worked on | `domain == github.com` && `ParsedTitle.kind == .pullRequest` && ≥ 8 min active on that `identifier` | `pullRequestOpened` **or** `pullRequestReviewed` — see below |
| PR opened (stronger) | the same PR identifier first seen within 5 min of a title matching `Comparing … · acme/sor` | `pullRequestOpened`, `.recall` confidence |
| Document written | `kind == .document`, same `subject`, ≥ 20 min active, ≤ 5 min idle | `documentWritten` |
| Issue moved | `linear.app` / `app.asana.com`, same `identifier`, ≥ 10 min | `other`, titled from the issue |
| Incident | a rule-tagged incident host (`pagerduty`, `sentry`, `datadoghq`) frontmost ≥ 15 min | `incidentResolved` |

**What is genuinely impossible, stated plainly.** Lggr cannot tell *opened* from *reviewed* from the
domain alone, because `DomainExtractor` keeps only the host — by our own design there is no path, so
`/pull/412/files` and `/pull/412` are the same evidence. The title *does* carry `by <author>`, which
would settle it, but only if Lggr knows who the user is — and asking them to type their handle is
exactly the typing this document exists to remove. So it asks once, as a tap:

```
 ⌥  Pull requests you open here say "by luisdoriz".
    Is that you?                                    [No]   [Yes]
```

Answered once, stored in `UserPreferences.identityTokens: [String]`, and never asked again. Until
it is answered, the chip offers both types as a two-segment control — one tap, still no typing.

Likewise: **"document written" can only ever mean "document focused and non-idle"**, because
detecting actual writing needs Input Monitoring, which SPEC forbids. The copy says *focused on* and
never claims *wrote*.

### 2.9 Calendar — an honest amendment, not a smuggled permission

DESIGN.md § 6.1.6 currently states Lggr *"should never appear in those panes of System Settings"*,
Calendar included. Adding EventKit contradicts that, and the contradiction should be resolved in the
open rather than by editing the sentence quietly.

**Primary mechanism needs no calendar at all.** A meeting is retroactively detectable from evidence:
`us.zoom.xos` frontmost, or `meet.google.com` / `teams.microsoft.com` as the domain, for ≥ 5
continuous minutes. The Day Reconstruction pass (§ 2.10) then proposes a `Meeting` block after the
fact. This works at Tier 2 and requires nothing new.

**EventKit is a Tier 3 opt-in that only adds a name and a prospective start.**

- API: `EKEventStore.requestFullAccessToEvents()` — macOS 14+. The pre-14 `requestAccess(to:)` is
  deprecated; macOS 14 also added a `writeOnly` tier, which is useless here.
- Info.plist: **`NSCalendarsFullAccessUsageDescription`** (macOS 14+). The legacy
  `NSCalendarsUsageDescription` is only consulted below macOS 14 and is irrelevant at our floor.
- Entitlement: **none**, because Lggr is unsandboxed. (`com.apple.security.personal-information.calendars`
  would be required only in the sandboxed configuration DESIGN.md § 6.2 keeps buildable.)
- Read surface: `EKEventStore.events(matching:)` over today only, and only `title`, `startDate`,
  `endDate`, `isAllDay`, `hasAttendees`. Never notes, never attendee names, never URLs.
- Behaviour: at `startDate`, the menu bar icon changes and the popover's first row becomes
  `Start · Weekly SOR sync` with the duration pre-set from the event. **It does not auto-start
  anything.** A session that begins without a human is a session about a meeting the user skipped.
- Without it: everything above still happens retroactively, unnamed. Blocks read `Meeting · Zoom`
  instead of `Meeting · Weekly SOR sync`.

The required doc change: § 6.1.6's Calendar row moves from *never requested* to *requested only when
the user enables Meeting names*, and the README's privacy claim is amended to match. The
*never-requested* list keeps Screen Recording, Input Monitoring, Full Disk Access, network,
Contacts, Reminders, Photos, Microphone, Camera and Location — which is still the whole point.

### 2.10 Day Reconstruction — the biggest typing win is the sessions you never started

The typing eliminated inside a session is small compared to the hours that produce **no record at
all** because nobody started a timer. Lggr is running and capturing; it can propose those hours back.

```swift
// Sources/LggrKit/Intel/DayReconstructor.swift — pure
public static func blocks(
    events: [ActivityEvent],
    contexts: [FocusedContext],
    idleThreshold: TimeInterval,
    existingSessions: [FocusSession],
    now: Date
) -> [ProposedBlock]
```

Deterministic segmentation:

1. Drop everything already covered by a real `FocusSession`.
2. Merge adjacent events sharing a dominant `(projectSignal, category)` when the gap is < 90 s.
3. Close a block on idle ≥ `idleThreshold`, or when the dominant signal over a rolling 5-minute
   window changes and *stays* changed for 5 minutes (change-point, not a jitter detector).
4. Discard blocks with < 5 min active time, or where `.unknown` holds > 70 % of the time.
5. Title each block from its top-ranked `ParsedTitle.subject`; project from `ProjectInferenceEngine`.

Each survivor is a `Candidate<FocusSession>` in the Today timeline with one button. SPEC § 7 already
asks for intelligently grouped blocks; this makes those blocks *actionable* instead of decorative.
The end state is real: **a user who never starts a session can still end Friday with an accurate log**,
having typed nothing and pressed Return a handful of times.

### 2.11 The correction loop — the half that decides whether any of this is usable

**a. Ghost text, not prefill.** The single most important interaction decision. A `.parsed` or
`.recall` outcome renders as grey placeholder text in an *empty* `OutcomeField`, accepted with
**Tab**. Typing a character makes it vanish. A wrong proposal therefore costs **zero keystrokes** —
you were going to type anyway. Inserting the text and making the user delete it costs ⌘A + type, and
worse, invites reflex-accept. `.weak` candidates render nothing at all: an empty field costs three
seconds; a plausible wrong value costs a corrupted record and a poisoned memory entry.

`⌥↓` opens the ranked alternatives; the ranked list is the second-cheapest correction after ignoring.

**b. Every inferred value is visibly inferred.** A small `sparkles` glyph (`ClassificationSource
.defaultRule` already uses it) next to any field whose value came from inference, with the
provenance string as its tooltip and its accessibility label. No hidden magic — if the user cannot
see that something was guessed, they cannot know to check it.

**c. Undo is the system Undo.** Every accept and every correction registers with the window's
`UndoManager` via `registerUndo(withTarget:handler:)`, so **⌘Z works**, and the toast says so:

```
Logged "Opened PR #412 in acme/sor".   ⌘Z to undo
```

This is the cheapest correction that exists on macOS and it costs one line per mutation.

**d. Correction applies first; the rule offer comes after, quietly.** Clicking a category on the
timeline opens a popover. The chosen category applies **immediately** and sets
`classificationSource = .manual` — which DESIGN.md:3795 already guarantees is never reclassified.
Only then does a disclosure appear:

```
┌──────────────────────────────────────────────────────────┐
│  Coding                                Set by a default rule │
│  ────────────────────────────────────────────────────────  │
│   Coding    Testing    Code review    Research ✓   …       │
│                                                            │
│   Always classify github.com as Code review?               │
│   Scope   [ Any project ▾ ]                                │
│   This would also change 23 earlier blocks — 1h 40m.       │
│   ☐ Apply to those too                                     │
│                                                            │
│                       Just this once      [ Always ]       │
└──────────────────────────────────────────────────────────┘
```

Escape means *just this once*. The correction is already saved either way.

**e. The proposed rule is derived from evidence, not from a form.**

```swift
// Sources/LggrKit/Intel/RuleSuggester.swift — pure
public static func suggest(
    correction: Correction,
    recentEvents: [ActivityEvent],
    existingRules: [ClassificationRule]
) -> RuleSuggestion?
```

It picks the **most specific field that actually discriminates**: `domain` if the event has one;
else the longest title token shared by the events the user just corrected but absent from the events
they did not (`windowTitleContains`); else `application`. If the resulting rule would be a duplicate
of, or strictly subsumed by, an existing rule, it returns `nil` — the offer never appears.

**f. Blast radius before consent.** `RuleImpact.evaluate(rule:against:)` replays the candidate rule
over the retained event history and reports *"23 earlier blocks · 1h 40m"*. The
*Apply to those too* checkbox defaults to **off**, and retroactive application skips every event
whose `classificationSource == .manual`. Most rule UIs let you agree to something whose consequences
you cannot see; this is the fix, and it is what makes a button labelled *Always* honest.

**g. Never re-ask.** Declining writes `SuppressedSuggestion(signature:, category:)` and the same
offer never appears again — the same anti-nag guarantee DESIGN.md § 6.6 gives permissions. One
exception, once: if the identical correction is made **three** times without a rule, the offer
returns once with different copy — *"You've set Figma to Planning three times."* — and then never
again.

**h. Rules are reversible, with their cause attached.** Rules → *History* lists every auto-created
rule, the correction that created it, when, and how many events it has affected, with one action:
`Remove and revert`. Reverting re-runs classification over the affected window, skipping `.manual`.
A learning system you cannot un-teach is a system you stop trusting the first time it learns wrong.

**i. Correction never edits history silently.** Correcting a *record* changes `RecordOrigin` to
`.corrected` and keeps the previous value in a `Correction` row in the ledger. This is what makes the
acceptance/correction metrics in § 6 measurable at all.

---

## 3. What changes for the user

### 3.1 Starting a session — from ~45 keystrokes to 3

Today: ⌘⇧Space, pick a project, type a sentence, check the duration, Return.

```
┌────────────────────────────────────────────────────────────┐
│  What are you working on?                                  │
│                                                            │
│   Finish the receipt deduplication PR                  ⇥   │   ← grey ghost text
│   ✦ You worked on this here on Tuesday · ⌥↓ for others      │
│                                                            │
│   [ SOR engineering ▾ ]  ✦        [ Deep work ▾ ]          │
│    25m   ● 50m   Custom   Open-ended                       │
│                                                            │
│                   Start without timer      [ Start Focus ] │
└────────────────────────────────────────────────────────────┘
```

**⌘⇧Space → Tab → Return.** Three keystrokes, and the middle one is optional if you'd rather type.
At Tier 0 with no memory yet, this screen is byte-for-byte what exists today — the feature adds
nothing to look at until it has something true to say.

### 3.2 Finishing a session — from reading-and-editing to one key

```
┌──────────────────────────────────────────────────────────────┐
│  What happened?                                              │
│  [ Completed ]  Made progress   Blocked   Interrupted   …    │
│                                                              │
│  52m active · 47m focused · 5m idle · 6 switches             │
│                                                              │
│  Summary                                                ✦    │
│  Deep work on SOR engineering for 52 minutes. Worked         │
│  primarily in Xcode and Terminal on receipt deduplication,   │
│  opened one GitHub pull request, and spent seven minutes     │
│  in Slack.                                                   │
│                                     Regenerate · Written by rules │
│                                                              │
│  Also log                                                    │
│   ✦ Opened PR #412 in acme/sor              [ Log ] [ Not this ] │
│   ✦ Focused on "Ingestion architecture" 24m [ Log ] [ Not this ] │
│                                                              │
│  Add result, blocker or next step ▸                          │
│                             Not now            [ Save ]      │
└──────────────────────────────────────────────────────────────┘
```

Copy additions to DESIGN.md § 5.10:

| Key | String |
|---|---|
| Summary provenance, rules | `Written by rules` |
| Summary provenance, model | `Polished on device · Use the plain version` |
| Suggestions heading | `Also log` |
| Suggestion actions | `Log` · `Not this` |
| Suggestion decline toast | `Won't suggest that again.` |
| Redaction note | `12 minutes in private apps aren't described here.` |
| Undo toast | `Logged "Opened PR #412". ⌘Z to undo` |

### 3.3 Today — the hours nobody logged

```
Day
  9:02–9:54   Xcode · Terminal · receipt-dedup      ✦  [ Log as session ]
 10:05–10:35  Slack · Chrome · communication        ✦  [ Log as session ]
 11:00–11:28  Meeting · Zoom                        ✦  [ Log as session ]

 Nothing here is saved until you log it.
```

| Key | String |
|---|---|
| Section heading | `Not logged` |
| Footer | `Nothing here is saved until you log it.` |
| Action | `Log as session` · `Log all` |
| Empty | `Everything today is already logged.` |

### 3.4 Weekly review — one new, neutral, non-shaming line

> 28 of 34 blocks this week were labelled automatically. You corrected 4.

No score, no colour, no verdict. It is a disclosure of how much of the week is inference, which the
user needs in order to know how much to trust the rest of the page.

### 3.5 Starting without any UI

Expose `StartFocusSessionIntent` / `FinishSessionIntent` / `LogAccomplishmentIntent` as **App
Intents** (macOS 13+, `import AppIntents`, zero permissions). A session can then start from
Spotlight, from Shortcuts, or from a Shortcuts automation — with the parameters resolved by the same
`OutcomeCandidateEngine`, so the intent takes no arguments and still fills itself in.

---

## 4. Permissions and degraded modes

The ladder from DESIGN.md § 6.3 is preserved. Nothing here promotes an optional permission to a
required one.

| Tier | Grant | What this proposal adds | What is lost without it |
|---|---|---|---|
| **0 — none** | — | `ActivationRecorder`; `ContextSignature` = bundle id; `ContextMemory` recall (*"what you usually do in Xcode"*); project inference from `.application` rules; Day Reconstruction at app granularity; summaries naming applications; App Intents; the whole correction/undo/rule loop | Nothing that exists today. Proposals are coarser and rarer; the outcome ghost text appears only after a few days of memory. |
| **1 — Accessibility** | Privacy & Security → Accessibility | `WindowTitleReader` → `TitleGrammar` → subjects, PR numbers, issue keys, document names; `kAXDocumentAttribute` → git branch; within-app switch detection via `AXObserver` | Titles are `nil`. All grammar-derived proposals disappear. Recall still works on bundle id alone. |
| **2 — Automation** *(per browser)* | Automation → Lggr → *browser* | Host discrimination: `github.com` → Code review, `linear.app` → Planning, `meet.google.com` → Meeting; the PR and issue detectors | Browser time is one undifferentiated block. PR/issue detection is off entirely. Firefox is in this state permanently and by design. |
| **3 — Calendar** *(new, opt-in, off)* | Calendars, full access | Meeting names on reconstructed blocks; a *"Start · Weekly SOR sync"* row at the event's start time | Meetings are still detected retroactively from Zoom/Meet/Teams evidence; they read `Meeting · Zoom` and start nothing. |
| **F — chosen git roots** *(new, opt-in, off)* | An `NSOpenPanel` folder pick, security-scoped bookmark | Branch names → the single best outcome proposal there is | No branch proposals. Repos outside the chosen roots are never read; no prompt is ever shown. |

Two guarantees carried over verbatim: **redaction happens at capture, not at display** — a private
app's title is never read, so it can never become a candidate — and **there is no combination of
denials that produces a broken app.** With everything denied, Lggr is what it is today plus recall
and Day Reconstruction at application granularity, which is already less typing than today.

---

## 5. What could make it fail

1. **Reflex-accept corrupts the log.** The user hits Return without reading, and the week fills with
   confident nonsense. *Mitigations:* ghost text never inserts itself; `.weak` candidates are not
   shown; every proposal carries a visible provenance line; acceptance adds only +0.5 weight and can
   never promote a candidate to `.recall`; `RecordOrigin` makes the auto-labelled proportion visible
   in the weekly review. **This is the most likely way the feature fails and the mitigations are the
   reason for half the structure above.**
2. **Title grammars rot.** Xcode 27 or a GitHub redesign changes a title format and the parser
   silently produces garbage. *Mitigation:* unknown shapes degrade to `.weak` (nothing shown) rather
   than to a wrong subject; grammars are data with fixtures. *Unmitigated residue:* no network means
   no grammar updates between app releases. Accepted.
3. **The recall loop eats itself.** Memory learns from the proposals it made. *Mitigation:* the
   weighting table in § 2.4. Only typed and corrected values can cross the `.recall` threshold. If
   this rule is ever relaxed for convenience, the feature is dead within a month.
4. **Ambiguity produces confident nonsense.** Two projects, both in Xcode, both plausible.
   *Mitigation:* the 1.5× margin rule — no clear winner means no proposal, not the best guess.
5. **Correction is more work than typing.** If fixing a wrong category costs more than three seconds,
   users stop fixing and start distrusting. *Mitigation:* ⌘Z; correction-in-place with no modal;
   the rule offer strictly *after* the correction is already saved; Escape is a valid answer.
6. **Rule creation becomes a second job.** Offers on every correction turn into nagging.
   *Mitigation:* `SuppressedSuggestion`; the once-more-at-three-repeats escalation and then silence;
   `RuleSuggester` returns `nil` for any rule already subsumed by an existing one.
7. **`kAXDocumentAttribute` is not populated for terminals.** Then branch detection only works from
   editors. *Mitigation:* spike it before designing further; the folder-name fallback is already
   specified. Not fatal — branch is rank 2 of 6.
8. **Day Reconstruction proposes junk.** A day of scattered context switching segments into thirty
   five-minute blocks nobody wants to triage. *Mitigation:* the discard rules in § 2.10 step 4, and a
   hard cap of 8 proposed blocks per day, keeping the highest-active-time ones. A section the user
   scrolls past is a failure; a section with three good rows is the feature.
9. **`FoundationModels` is unavailable, slow, or refuses.** *Mitigation:* it is a rewriter behind a
   1.5 s budget on a field that is already populated. Everything works identically without it. It is
   the last thing built and the first thing cut.
10. **Privacy regression via inference.** A subject string derived from a title could outlive the
    event it came from and end up in an export. *Mitigation:* candidates carry `signature` and are
    purged with activity history; `ContextMemory` is deleted by *Delete activity history*; candidates
    are excluded from every export. Once a candidate is *accepted*, the string is a record the user
    approved — that is the boundary, and the privacy statement should say it in those words.
11. **The Calendar permission erodes the privacy claim.** *Mitigation:* Tier 3, off by default, and
    the amendment to § 6.1.6 made explicitly rather than by silent edit. If the claim is judged more
    valuable than meeting names, cut § 2.9 entirely — the retroactive detector survives it.

---

## 6. The smallest first slice

**Hypothesis, stated so it can be killed:** *Lggr can propose the intended outcome well enough that
the user accepts it more often than they retype it.* Everything else in this document is downstream
of that being true. If it is false, the effort belongs on the review side instead, where the evidence
is complete and the proposal is far easier.

**Ship (≈ one week, `swift build` / `swift test` green throughout):**

1. `ActivationRecorder` — `NSWorkspace` ring buffer, zero permissions. `LggrApp`.
2. `WindowTitleReader` — AX, 0.25 s timeout, secure-input skip, private-app skip. `LggrApp`.
3. `TitleGrammar` with exactly **four** grammars: Xcode, VS Code, `github.com`, Terminal. Everything
   else → `.weak` → shown as nothing. `LggrKit`, pure, fixture-tested.
4. `ContextSignature` + `ContextMemory` + the § 2.4 weighting table. A 200-entry JSON file next to
   the existing store. `LggrKit`, pure, unit-tested.
5. `OutcomeCandidateEngine` — ranks 1, 3 and 6 only. No branch, no calendar, no issue keys.
   `LggrKit`, pure, table-driven tests.
6. `OutcomeField` gains ghost text + Tab-to-accept + the provenance caption + `⌥↓` alternatives.
7. A local-only counter — `proposed`, `acceptedUnchanged`, `acceptedEdited`, `ignored`,
   `correctedLater` — written to `intel-metrics.json` and shown in the existing dev gallery. Never
   exported, never networked, deletable.

**Explicitly not in the slice:** project inference, accomplishment detection, Day Reconstruction,
`SessionEvidence`, `FoundationModels`, EventKit, git roots, rule generation. The slice **writes no
record the user did not start**, so its blast radius is one text field.

**Kill criteria, measured after 10 working days:**

| Metric | Verdict |
|---|---|
| `acceptedUnchanged + acceptedEdited` **< 40 %** of sessions where a candidate was shown | The proposal is not good enough. Kill outcome prefill; keep `ContextMemory` for the review side only. |
| `correctedLater` **> 10 %** of accepted candidates | Worse than nothing — it is producing plausible wrong records. Kill immediately; this is the failure mode in § 5.1 confirmed. |
| `acceptedUnchanged` **> 60 %** | Proceed to project inference (§ 2.6) and `SessionEvidence` (§ 2.7), in that order. |

The reason this is the right first slice: it uses the two cheapest permissions, it touches exactly
one existing view, it produces a number rather than an opinion, and if it dies it dies having cost a
week and having left `ActivationRecorder`, `WindowTitleReader` and `ContextMemory` behind — all three
of which Phase 3 needs anyway.

---

## Adversarial review

> Hostile read, written against the proposal above, `SPEC.md`, `CONSTRAINTS.md` and the current
> contents of `Sources/`. Claims marked **verified** were checked by running the compiler or reading
> the repository on this machine, not recalled.

**Conceded up front, so the rest is credible.** Four things in this document are right and are
usually got wrong: `NSWorkspace.shared.notificationCenter` really is a different centre from
`NotificationCenter.default` and registering on the wrong one really does silently receive nothing;
`kCGWindowName` really is stripped from `CGWindowListCopyWindowInfo` without Screen Recording, so
the § 2.1 rejection table is correct and the narrower permission really is the right call; there
really is no public API for Focus/Do Not Disturb state; and `EKEventStore.requestFullAccessToEvents()`
with `NSCalendarsFullAccessUsageDescription` and no entitlement really is the correct macOS 14+
shape for an unsandboxed app. Also: the `?? .null` in the idle snippet is harmless —
`CGEventType(rawValue: ~UInt32(0))` is **not** nil (verified), so the fallback never fires. The
citation to `DESIGN.md:3795` checks out verbatim.

Everything below is a defect.

---

### 1. Technical impossibility

**T1 — `@Generable` and `@Guide` do not compile on this machine. § 2.7 breaks the build.** *(verified)*

`CONSTRAINTS.md` lists exactly three macro plugins in the toolchain. The directory still contains
exactly three:

```
/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/
  libObservationMacros.dylib   libSwiftMacros.dylib   testing/libTestingMacros.dylib
```

`FoundationModels.framework` is present in the SDK, so `import FoundationModels` is fine and
`canImport` will be **true** — which is precisely the trap. Compiling the § 2.7 design:

```
error: external macro implementation type 'FoundationModelsMacros.GenerableMacro' could not be
found for macro 'Generable(description:)'; plugin for module 'FoundationModelsMacros' not found
error: external macro implementation type 'FoundationModelsMacros.GuideMacro' could not be found
for macro 'Guide(description:)'; plugin for module 'FoundationModelsMacros' not found
```

This is the same class of failure as `@Model`, and CONSTRAINTS rule 1 forbids it in `LggrKit` or
`LggrApp`. `#if canImport(FoundationModels)` does **not** save you — the macro expansion happens at
compile time on a machine where the framework imports fine. **Fix:** drop the `@Generable` struct
entirely and use the plain `respond(to:)` string API with post-validation, or move the whole rewriter
into an `LGGR_SWIFTDATA`-style Xcode-only target. As written, § 2.7 cannot be built here at all.

**T2 — App Intents (§ 3.5) will compile and then not exist.** *(verified)*

`appintentsmetadataprocessor` is not in `/Library/Developer/CommandLineTools/usr/bin`. That tool is
an Xcode build phase; it emits `Contents/Resources/Metadata.appintents`, which is the *only* thing
Spotlight and Shortcuts read. `Scripts/make-app.sh` hand-assembles the bundle and cannot generate it.
So `StartFocusSessionIntent` will build green, ship, and never appear anywhere. "Zero permissions" is
true and irrelevant. **Fix:** cut § 3.5, or mark it explicitly Xcode-only alongside `LggrPersistence`.

**T3 — `.combinedSessionState` is the wrong event source, and idle detection is load-bearing.**

`CGEventSourceStateID.combinedSessionState` includes **synthetic events posted by other processes**.
Zoom's presence keeper, Amphetamine, Karabiner-Elements, Logi Options+, mouse jigglers and half the
utility belt of the target persona post CGEvents. Under any of them
`secondsSinceLastEventType` never grows, so § 2.10 step 3 ("close a block on idle ≥ threshold") never
fires and § 2.8's "≤ 5 min idle" precondition is always satisfied. Day Reconstruction then emits one
gigantic block per app and `documentWritten` fires on a document you left open. `.hidSystemState` is
hardware-only and correct for this, but it is *system-wide* and therefore counts the other user's
typing under fast user switching. Neither is right alone. **Fix:** `.hidSystemState`, **plus** a hard
capture stop between `NSWorkspace.sessionDidResignActiveNotification` and
`sessionDidBecomeActiveNotification`, **plus** `com.apple.screenIsLocked` / `screenIsUnlocked` from
`DistributedNotificationCenter`. None of the three appear in the proposal.

**T4 — The dwell thresholds in § 2.8 are unmeasurable under the capture model in § 2.1.**

This is the sharpest internal contradiction in the document. § 2.1 mandates the title is read *"once
per activation and never on a timer."* § 2.8 then requires "≥ 8 min active on that `identifier`",
"same `subject`, ≥ 20 min active", "same `identifier`, ≥ 10 min", "frontmost ≥ 15 min". A Chrome tab
switch produces **no** `NSWorkspace` activation and **no** `kAXFocusedWindowChangedNotification` —
the focused window is unchanged. Sit in Chrome for forty minutes across three pull requests and Lggr
observes exactly one title, sampled at t=0, and will attribute all forty minutes to whichever PR
happened to be open when you switched in. That is not a missing feature; it is a *fabricated*
accomplishment about a PR you glanced at. **Fix:** either subscribe to `kAXTitleChangedNotification`
on the focused window element (AX, no new permission — this is the notification that actually fires
on tab change) and accept one Apple Event per tab switch with the battery cost that implies, or
delete every dwell threshold in § 2.8 and detect nothing from duration.

**T5 — "frontmost" is a single global, and the meeting detector is the casualty.**

§ 2.9's primary, permission-free mechanism is "`us.zoom.xos` frontmost … for ≥ 5 continuous minutes."
The persona is a two-monitor engineering manager. The overwhelmingly common meeting is Zoom visible
on display 2 while Xcode is focused on display 1 — Zoom is never frontmost, the detector never fires,
and the hour is logged as coding. The same defect makes `BrowserDomainReader` ambiguous: the Apple
Event resolves the browser's *own* front window, which with two Chrome windows across two Spaces need
not be the one the user is looking at. This is not fixable without window enumeration, which needs
Screen Recording, which the document correctly refuses. **Fix:** state it in § 5 as unmitigated
residue, and stop claiming EventKit "only adds a name and a prospective start" — without it, meeting
detection misses the majority case, which makes § 2.9 a much bigger concession than it admits.

**T6 — `kAXDocumentAttribute` is assumed for Xcode and VS Code, and is only flagged for terminals.**

`AXDocument` is published by AppKit from `NSWindow.representedURL`. Nothing else sets it.
- **VS Code / Cursor** are Electron and call `setRepresentedFilename` only when a *single file* is
  opened — the ordinary "open a folder / workspace" case gives `nil`. This is the common developer
  case and the document assumes it works.
- **Terminal.app** publishes the cwd only because `/etc/zshrc`'s `update_terminal_cwd` emits OSC 7.
  `bash`, `fish`, `nushell`, a custom `ZDOTDIR`, or an active `ssh` / `tmux` / `docker exec` session
  give `nil` or a *remote host's* path presented as a local one. iTerm2 needs shell integration
  installed.
- **Xcode** with a workspace open but no editor focused gives `nil`.

The proposal flags only terminals as unverified. **Fix:** spike all four, and put the `nil` case in
`Tests/LggrKitTests/Fixtures/` as a first-class fixture, not an afterthought.

**T7 — Security-scoped bookmarks are a sandbox mechanism; § 2.1's guarantee is built on one.**

`URL.bookmarkData(options: .withSecurityScope)` and `startAccessingSecurityScopedResource()` are
defined by the App Sandbox. In the shipped **unsandboxed, hardened-runtime** configuration
`startAccessing…` returns `false`, which a careless implementation reads as "denied". More
importantly, the premise is wrong: a bookmark does not carry a TCC grant. The prompt for
`~/Documents` is driven by the first `open(2)` on a protected path by a process with no matching TCC
record. Picking a folder in `NSOpenPanel` does not durably create that record for a non-sandboxed
app. So "no prompt Lggr did not cause" is not achievable by the stated mechanism. **Fix:** use a
plain bookmark, and make the actual rule the guarantee — Lggr reads only under user-chosen roots and
**refuses outright** to read under `~/Documents`, `~/Desktop`, `~/Downloads` and
`~/Library/Mobile Documents`, prompt or no prompt.

**T8 — `GitHeadReader` will produce a hash as an intended outcome.**

The walk-up looks for "the first directory containing `.git`". In every **worktree** and every
**submodule**, `.git` is a *file* containing `gitdir: /elsewhere` — the directory test fails
silently. In detached HEAD (bisect, rebase, `git checkout <sha>`, any CI-style checkout) `.git/HEAD`
is a bare 40-hex SHA, not `ref: refs/heads/…`, and the § 2.5 rank-2 source will offer
*"Work on a1b2c3d4e5…"* as the user's intended outcome, at `.parsed` confidence, i.e. **shown**.
`GIT_DIR` and `--separate-git-dir` are further cases. **Fix:** follow `gitdir:` indirection; treat
anything not matching `^ref: refs/heads/` as *no branch*; fixtures for detached, worktree, submodule.

**T9 — Ad-hoc code signing versus TCC. This is what the week will actually be spent on.**

`CONSTRAINTS.md` ships via `codesign --sign -`. TCC keys Accessibility, Automation and Calendar
grants to the code-signing identity — for an ad-hoc signature, the `cdhash`. Every rebuild changes
the cdhash, so the grant goes stale: **Lggr stays checked in System Settings → Accessibility while
`AXIsProcessTrusted()` returns `false`**, with no user-visible explanation. Since Tiers 1–3 gate
essentially all of this proposal's value, the author will hit this on day one and may misdiagnose it
as an AX bug. **Fix:** § 4 must document it, and Settings needs a diagnostic that detects
"listed but not trusted" and surfaces `tccutil reset Accessibility com.luisdoriz.lggr`.

**T10 — AX reads on `@MainActor` will hang the UI.**

`AXUIElementCopyAttributeValue` is synchronous IPC into the target application's run loop.
`ActivationRecorder` is declared `@MainActor` and `WindowTitleReader` is invoked from it with a
0.25 s messaging timeout. A launching, beachballing or swapping app therefore blocks Lggr's main
thread for 250 ms per activation — and activations arrive in bursts. **Fix:** the AX read runs on a
dedicated serial background queue and hops back to the main actor. Note also that
`AXUIElementSetMessagingTimeout` is **per element** — it must be set on each per-application element
*and* on `AXUIElementCreateSystemWide()`, not once globally.

**T11 — `IsSecureEventInputEnabled()` is global and sticky.**

It is on whenever *any* process focuses a secure field, and terminals with `SecureKeyboardEntry`
enabled, plus a long tail of buggy apps, leave it on for hours. Title capture then silently produces
nothing and the app looks broken. Worth noting: secure input has no bearing on AX title reads — this
is self-imposed conservatism. **Fix:** keep it, but surface a calm state ("Window titles paused while
a password field is active") and a diagnostic row, or the support burden lands on a feature nobody
asked for.

**T12 — "Already exists" is doing unearned work.** *(verified)*

`DESIGN.md:3795` checks out. The code does not. `Sources/LggrKit` is 17 files and contains **no**
`ClassificationRule`, no `RuleMatchType`, no `ActivityEvent`, no `DomainExtractor`, no
`ClassificationSource`. Those symbols exist only in `Sources/LggrPersistence/Models/SDModels.swift`,
which `Package.swift` builds **only** under `LGGR_SWIFTDATA=1` and therefore never on this machine.
So § 2.6's *"reusing the rule engine that already exists"* is false as code, and § 2.8, § 2.10 and
§ 2.11 d–h are all Phase 3+ work described in the present tense. § 6 is honest about this for items
1–7; the body of the document is not. **Fix:** every "already" becomes "designed in DESIGN.md, not
implemented", and Phase 3 goes explicitly upstream of § 2.6 onward.

---

### 2. Creepiness

**C1 — `.weak` is a retention policy wearing a suppression policy's clothes. This is the worst thing
in the document.**

§ 2.0 defines `.weak` as *"never shown; kept for the correction ledger only."* § 2.3's fallback row
sends **every unrecognised window title, whole**, to `.weak`. Composed, those two sentences mean:
*Lggr writes the complete, unparsed title of every window in every app it has no grammar for into
`candidates.json`.* Concretely, that file will contain:

- `Re: Q3 comp adjustments — 47 messages` (Mail)
- `Omar Reyes` (Messages)
- `Termination letter - Alvarez.pdf` (Preview)
- the subject line of whatever is open in `mail.google.com` (Safari)

SPEC § 4 forbids storing **email contents** and **Slack message contents**. A subject line *is*
email content. A DM window title *is* the identity of the person you are messaging. The § 5.10
mitigation only covers *accepted* candidates and does not touch this. Would a reasonable engineer be
comfortable if a colleague saw `candidates.json` on their screen? No — and it is on disk in
`~/Library/Application Support/Lggr/`, unencrypted, for 24 hours, plus however long until a
never-relaunched menu-bar app performs its "purge on launch" (see B2). **Fix:** `.weak` must mean
**discarded**, not stored. Keep a count of unrecognised titles, never a string. If the correction
ledger genuinely needs the case, store `SHA-256(title)` plus the bundle id.

**C2 — `ParsedTitle.author` harvests people who never installed this app.**

Reviewing a colleague's PR writes *their* GitHub handle into `ParsedTitle.author`, thence into
`ContextMemory.key` / `outcome`, thence into any accomplishment titled from that PR, thence into an
exported Markdown. § 2.8's *"Pull requests you open here say 'by luisdoriz'. Is that you?"* makes it
concrete: the app displays a harvested identifier back to the user, and on the first run that
identifier will frequently be a *colleague's*, because the first PR you open is usually someone
else's. SPEC principle 3 draws the line at "reconstruct work, not surveil the user"; this surveils a
**non-user**. **Fix:** `author` is compared once against `identityTokens` and immediately discarded —
never persisted, never in a provenance string, never rendered. Ask the identity question in Settings
against a handle the user types.

**C3 — A window title containing a customer name is a customer record, and it ends up in an export.**

Linear, Jira, Zendesk, Salesforce and PagerDuty titles routinely carry the customer: *"ACME Corp —
duplicate commission ingestion"*. § 2.3 extracts that as `ParsedTitle.subject`; § 2.8 turns it into
an `Accomplishment.title`; SPEC's Export turns that into a Markdown file the user hands to their
manager. SPEC § 4 is satisfied literally ("full document contents" were not captured) and violated in
effect. **Fix:** a host deny-list for *subject* extraction — CRM, support, HR and ATS hosts yield
`locus` and `kind` only, never `subject` — plus a one-line disclosure at export time: *"Summaries may
include text taken from window titles."*

**C4 — Day Reconstruction (§ 3.3) is the screen that turns this into a monitoring product.**

Every other surface here describes work the user chose to record. § 3.3 renders an unrequested
timeline of the hours they *did not* choose to record. That will contain `14:20–14:50 Safari ·
<bank>`, `12:10–12:40 Chrome · <health portal>`, `16:05–16:20 Messages`. `05-permissions.md:1150`
already concedes Safari and Firefox private windows are undetectable, so private browsing lands here
too. This is the one screen in Lggr that looks exactly like the enterprise surveillance software
SPEC principle 4 exists to avoid, and it is proposed as on-by-default. **Fix:** reconstruction
proposes a labelled block **only** when the dominant category is a work category *and* the locus
matches an existing rule or a previously-logged locus. Everything else collapses into a single
`Other · 1h 10m` row with no detail and no expand affordance. Off by default.

**C5 — `intel-metrics.json` is telemetry about the human.**

`proposed / acceptedUnchanged / acceptedEdited / ignored / correctedLater` is a record of the user's
compliance with the machine's suggestions. Local, deletable and dev-gallery-only, it is a legitimate
10-day instrument. Shipped, it is the seed of a nagging system, and `ignored` is a field that exists
to be acted on later. **Fix:** compile it out of release builds, delete it when the experiment ends,
and write down that `ignored` may never become an input to ranking or to any UI.

**C6 — Five new stores sit outside every privacy control SPEC § 4 requires.**

SPEC § 4 requires "Delete activity history" and "Define retention duration". `candidates.json`
self-expires (good). But `ContextMemory` only *decays* — `×0.9` per week asymptotes and an entry
never leaves the file. And `intel-metrics.json`, `SuppressedSuggestion`, `identityTokens`, the
auto-created rule **History** (§ 2.11h) and the `Correction` ledger (§ 2.11i) are covered by
`dataRetentionDays` not at all. The ledger is the worst: it exists specifically to preserve the
*original wrong value* indefinitely. **Fix:** enumerate every new store in Settings → Privacy with
its own retention; `dataRetentionDays` prunes all of them; `ContextMemory` entries below a floor
weight are deleted, not decayed forever.

---

### 3. Battery, CPU and correctness

**B1 — Activation storms.** `didActivateApplicationNotification` fires for Spotlight, Notification
Centre, Dock previews and helper processes, not just real switches. Holding ⌘-Tab through eight apps
produces eight AX round-trips, up to eight Apple Events, eight memory lookups and — if written
naively — eight full atomic rewrites of a JSON file. **Fix:** no capture until an app has been
frontmost ≥ 1.5 s continuously; coalesce `ContextMemory` writes behind a ≥ 30 s flush; never touch
disk on the activation path.

**B2 — "Purged on launch" is false for the only users who matter.** § 2.0 rule 3 guarantees
candidates never survive to a second day, enforced by a purge on launch. A menu-bar app with
`launchAtLogin` is relaunched approximately never. Given C1, this means unparsed window titles
persist for weeks. **Fix:** purge on `NSCalendar.dayChangedNotification`, on
`NSWorkspace.didWakeNotification`, and on a coarse timer — not on launch.

**B3 — Nothing observes sleep, wake or lock.** No `willSleepNotification`, `didWakeNotification`,
`screensDidSleepNotification` or `com.apple.screenIsLocked` appears anywhere. A lid closed at 17:00
with Xcode frontmost and reopened at 09:00 produces one interval that Day Reconstruction will happily
propose as a sixteen-hour block — the idle rule does not save you, because a suspended app samples
nothing. The § 2.1 ring buffer's "last non-Lggr activation" also survives the night and will feed
stale context to the first session of the morning. **Fix:** on wake, invalidate the ring buffer,
close any open block at the *sleep* timestamp, and never merge across a sleep gap regardless of the
90 s rule.

**B4 — The time dimension is promised and absent.** § 2.2 sells the Tier-0 case as *"what do you
usually do in Xcode at 9 a.m."* — but `ContextSignature` is `(bundleIdentifier, locus, subject)`.
There is no time field. Either the pitch is wrong or the type is. If a bucket is added: local-hour
buckets are wrong across DST (one hour occurs twice, another never) and wrong for a week of travel,
and `lastUsedAt` decay measured in local days breaks on the same transitions. **Fix:** drop the
time-of-day claim, or key on a UTC-anchored bucket with an explicit timezone and re-bucket on
`NSSystemTimeZoneDidChangeNotification`.

**B5 — Fast user switching manufactures activity.** In a background login session, `NSWorkspace`
still reports that session's frontmost app and still delivers activation notifications. Combined with
T3, Lggr will keep generating context samples — and possibly non-idle ones — for a user who walked
away three hours ago, then propose those hours back as reconstructed blocks. **Fix:** as T3.

**B6 — Multiple displays and Spaces.** As T5: only one app is frontmost system-wide, so every
category total in the weekly review inherits a systematic error for multi-monitor users, who are the
target persona. Unfixable within the permission budget. **Fix:** say so in § 5 and cap the confidence
of any duration-derived inference accordingly.

**B7 — A 1.5 s budget versus a cold model load.** The first `SystemLanguageModel` use in a process
loads a multi-gigabyte model; cold, that is seconds. The rewriter will therefore time out on
essentially every *first* session of the day — the moment the user forms their impression of it — and
work only afterwards, which reads as flakiness rather than as graceful degradation. Sustained ANE/GPU
inference is also a real battery cost for one sentence of prose. Combined with T1, § 2.7 is the
strongest deletion candidate in the document, and § 5.9 already concedes it is first to be cut.

---

### 4. Being wrong

**W1 — The document's own mockups violate its own load-bearing rule.** § 2.11a — *propose as ghost
text, never as inserted text* — is what makes "a wrong proposal costs zero keystrokes" true. But
§ 3.1 shows the project picker reading `[ SOR engineering ▾ ] ✦`: a **set** value, not ghost text.
And § 3.2 shows the generated summary **already in the field**. Pressing Start, or Save, commits both
without the "explicit human accept" § 2.0 promised. So the zero-cost argument holds for exactly the
one field the § 6 slice touches, and collapses for the two fields with the largest blast radius: a
wrong project corrupts *every* aggregate in the weekly review, and the summary is the text the user
shows other people. **Fix:** either the picker renders the inferred project ghosted and unselected,
requiring a keystroke, or § 2.0's structural rule is honestly narrowed to *"the outcome field only"* —
and if it is narrowed, most of § 1's argument goes with it.

**W2 — Wrong accomplishments are categorically worse than wrong summaries, and § 2.8 generates the
worst kind.** `incidentResolved` fires because a Datadog dashboard was frontmost for fifteen minutes
— reading a dashboard is not resolving an incident. `pullRequestOpened` is emitted from a heuristic
the document itself admits cannot distinguish *opened* from *reviewed*. These become rows in the
Friday "evidence of what you delivered" list, then rows in an exported Markdown that a manager reads.
A wrong *claim about your output* is a professional liability, not a UI annoyance — and unlike the
outcome field, there is no prior intent to compare it against, so nothing feels wrong when reading
it. **Fix:** the two highest-stakes types are never proposed from dwell time. Propose neutral `other`
with the observed title and let the user pick the type. Dwell proves attention; it never proves
completion. The copy rule from § 2.8 ("focused on", never "wrote") must apply here too and does not.

**W3 — Undo does not undo the learning.** § 2.11c registers accepts and corrections with
`UndoManager`. § 2.4 mutates weights; § 2.11i appends a `Correction`. Nothing says ⌘Z reverts either.
An undo that leaves a `+4.0` behind teaches the system from an action the user explicitly retracted —
the exact self-reinforcement § 2.4 exists to prevent, arriving through the back door. **Fix:** the
undo closure is the inverse of the whole transaction — record, weight, ledger row, any
`SuppressedSuggestion` — expressed as one function with one test.

**W4 — `Log all` is an unbounded accept that corrupts the app's central analysis.** One button
creates up to eight `FocusSession`s with machine-written outcomes, with no per-block review
requirement and an undo that must revert eight records atomically. Worse: reconstructed blocks are by
construction **not planned**, yet they are stored as `FocusSession`s. SPEC § 9 asks *"how much work
was planned versus reactive"* and SPEC § 3's model has `isReactive`. Saving reconstructions as
ordinary sessions silently inflates planned time and "focus sessions completed", corrupting the one
analysis the product exists to produce. **Fix:** reconstructed blocks set `isReactive = true`, are
excluded from the sessions-completed count, and carry `RecordOrigin.accepted` into the weekly review
as a separate line. Remove `Log all` until per-block precision has been measured.

**W5 — The kill criteria cannot detect the failure they are aimed at.** `correctedLater > 10 %` is
the guard against plausible-but-wrong records — but it is measured *by the user noticing*, and
plausible-wrong records are precisely the ones nobody notices. The metric is anti-correlated with the
risk it monitors. The population is n = 1 for 10 days, and the subject is the author, who knows what
every proposal *should* say and will therefore accept at a rate no other user can reproduce.
**Fix:** on 2 of the 10 days the user keeps an independent manual log and diffs it against what Lggr
proposed — that yields precision, not acceptance. Add a fourth criterion: if the median time from
proposal-shown to accept is under ~400 ms, the user is reflex-accepting and the acceptance rate means
nothing. That criterion is the only direct instrument for § 5.1, which the document calls its most
likely failure mode and then does not measure.

**W6 — `.recall` is defined twice, incompatibly.** § 2.0: *"shown as ghost text, **pre-selected**;
still requires a keystroke."* § 2.11a: ghost text lives in an **empty** field. Pre-selected text in a
non-empty field is exactly the prefill § 2.11a bans, and it makes the next character the user types a
destructive replace. **Fix:** collapse `.recall` and `.parsed` into one presentation — ghost text,
empty field — and let confidence affect only ranking and the provenance sentence.

---

### 5. Product principle violations

**P1 — Net manual entry plausibly goes up.** The ledger: −45 keystrokes at session start; **+** a
daily triage queue of up to eight blocks (§ 3.3), **+** a rule-offer popover with a scope dropdown, a
blast-radius checkbox and two buttons on every correction (§ 2.11d), **+** an identity question
(§ 2.8), **+** a folder picker (§ 2.1), **+** a Calendar permission (§ 2.9), **+** a two-segment PR
type control. For the disciplined user who already starts sessions, this is strictly more decisions
per day than today. SPEC principle 2 is about *data entry*, and a decision queue is data entry with
the typing removed. **Fix:** state the ledger in § 3 and default every net-adding surface to off.

**P2 — It optimises for the user who is not using the product.** § 2.10's own framing — *"the biggest
typing win is the sessions you never started"* — concedes that the headline value accrues to someone
outside the core loop. SPEC's product is *intentional* time tracking; a reliable reconstruction
engine makes not starting a session the cheaper path and quietly removes the reason the session
exists. **Fix:** decide which product this is. If reconstruction wins, say so and demote sessions
deliberately. Shipping both as equals means neither is the primary action, which breaks SPEC
principle 6.

**P3 — Every grammar describes one kind of user.** Xcode, VS Code, `github.com`, Linear, Slack,
Terminal: this is a software engineer at a GitHub-and-Linear company. SPEC's audience is *"engineering
managers, developers, and knowledge workers"*. A designer in Figma, a PM in Google Docs, or a manager
living in Mail and Calendar gets rank 6 at best and `.weak` — i.e. nothing, forever — at worst,
because § 5.2 concedes grammars only update when the app updates. **Fix:** ship at least one
non-engineering grammar in the first slice, and make the *fallback* useful to everyone: propose the
last thing the user typed in **this app**, which requires no grammar at all, works at Tier 0, and is
the single highest-value proposal in the document for the users the grammars exclude.

**P4 — Permission nagging by accretion, and a modal on the busiest path.** DESIGN § 6.6's re-ask
policy is per-permission; this proposal adds Calendar, a folder picker and an identity question on
top of Accessibility and per-browser Automation. Each is individually opt-in and individually
non-nagging; the aggregate is an app that keeps asking. Worse, the § 2.8 identity question fires at
**session finish**, which SPEC § 6 wants to be a compact review sheet and which the design direction
explicitly protects from "modal dialogs for common actions". **Fix:** all consent lives in onboarding
and Settings → Privacy. Nothing asks the user for anything on the finish path, ever.

**P5 — AI where a rule would do, and a guardrail that does not guard.** § 2.7's rewriter is an
on-device LLM whose entire remit is *"one sentence of prose smoothing over facts the deterministic
builder already produced"* and which *"may not introduce a fact, a judgement, or an adjective."* A
component forbidden from adding information has no output worth the surface area. And the stated
post-check — *"rejects any output containing a number that is not in the evidence"* — does not bound
the failure that matters: the model can invert a relation, *"spent most of the session in Slack"* when
Slack was seven minutes, using no numbers at all. SPEC § 5 says rules before AI. **Fix:** cut it. T1
says it does not compile here anyway.

**P6 — "You corrected 4."** § 3.4's line attributes errors to the user's activity rather than to the
system's, and any per-week accuracy figure invites the user to optimise it — which is the mechanism
behind the "productivity scores that shame the user" SPEC bans. **Fix:** *"4 labels were corrected."*
Passive, about the labels, not the person. No trend line, ever. (The § 3.2 copy `Won't suggest that
again.` is exactly right and should be the model for the rest.)

**P7 — Two rule systems.** § 2.6 adds `ProjectRule` as a sibling of `ClassificationRule`: two types,
two matchers, two histories, two suppression stores, two Settings screens, two revert flows. SPEC
principle 11 forbids unnecessary abstraction; CONSTRAINTS asks for small focused files, not doubled
ones. **Fix:** one `Rule` with an enum outcome — `.category(ActivityCategory)` / `.project(UUID)` —
one matcher, one history, one revert. This is cheaper *now*, before either exists (T12).

---

### Verdict

**KEEP WITH CHANGES** — the core bet survives, because *propose-never-insert* plus *only typing and
correcting change the weights* is the right reading of SPEC principle 2 and is the rare
auto-suggestion design whose failure mode is silence rather than fabrication; but it does not survive
as written, because § 2.7 does not compile under CONSTRAINTS (T1), § 3.5 cannot register without
Xcode (T2), `.weak` persistence stores email subject lines and colleagues' names in violation of
SPEC § 4 (C1), the dwell thresholds in § 2.8 are unmeasurable under § 2.1's own capture rule (T4),
and the ghost-text guarantee must cover the project picker and the summary field before this writes
a single record (W1).

**Required before any of this is built, in order:**

1. Delete § 2.7's `FoundationModels` rewriter and § 3.5's App Intents. (T1, T2, B7, P5)
2. Redefine `.weak` as *discarded*, not *stored*. Never persist an unparsed title. (C1)
3. Extend ghost-text semantics to the project picker and the summary field, or narrow § 2.0's rule
   in writing to the outcome field alone. (W1, W6)
4. Resolve T4: adopt `kAXTitleChangedNotification` and price the Apple Events, or delete every
   dwell threshold in § 2.8. Never propose `incidentResolved` or `pullRequestOpened` from dwell. (W2)
5. Switch idle to `.hidSystemState` and add session-active, sleep/wake and lock observers. (T3, B3, B5)
6. Make undo transactional over record + weight + ledger. (W3)
7. Discard `ParsedTitle.author` after one comparison; move the identity question to Settings. (C2, P4)
8. Day Reconstruction off by default, work-category-only, `isReactive = true`, no `Log all`. (C4, W4)
9. Replace security-scoped bookmarks with a plain bookmark plus a hard refusal to read TCC-protected
   roots; fix `GitHeadReader` for worktrees, submodules and detached HEAD. (T7, T8)
10. Move the AX read off `@MainActor`; debounce activations at 1.5 s; purge candidates on day-change
    and wake, not on launch. (T10, B1, B2)
11. Bring `ContextMemory`, `intel-metrics.json`, the correction ledger, rule history and
    `identityTokens` under `dataRetentionDays` and *Delete activity history*. (C6)
12. Rewrite § 6's kill criteria around a two-day ground-truth diff and a median-time-to-accept floor,
    and rewrite every "already exists" claim to name Phase 3 as a prerequisite. (W5, T12)
