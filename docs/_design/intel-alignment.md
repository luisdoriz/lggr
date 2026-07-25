# Intent vs. reality — the alignment layer

**Lens:** the gap between what you meant to do and what you did.
**Status:** proposal. Depends on Phase 3 capture landing; specifies what Phase 3's data is *for*.
**New permissions required: none. New entitlements: none. New Info.plist keys: none.**

---

## 1. The core bet

The bet is that **the gap between intent and reality is not a quantity, it is a small number of
nameable moments**, and that an app which names two or three of them honestly is worth more than an
app which scores all of them confidently. Lggr already knows what you declared: an intended outcome
in your own words, a project, a work type. Phase 3 will know what was frontmost, for how long, and
under what title. The alignment layer is the pure function between them — and its most important
property is that it is **asymmetric about evidence**. It will claim you were on your intent only when
something positively says so, it will claim you were elsewhere only when something positively says
so, and in every other case — which at zero permissions is most cases — it says nothing at all and
counts the time as *consistent with* your intent. Out of that three-valued judgment fall exactly two
primitives: **stretches** (unbroken runs of time nothing contradicted) and **departures** (runs of
time something did). One number is published from them — *the longest unbroken stretch, in minutes* —
and it is a duration, not a ratio, because a ratio needs a denominator the app cannot honestly supply.
The app never sends you a message about drift. It answers when asked, in the popover you opened
yourself and in the review sheet you were already going to fill in. And when it does detect real
drift, its response is never to tell you that you failed — it is to **offer to correct the log**:
*"Most window titles named Platform migration. Move this session?"* Drift stops being a verdict and
becomes a saved keystroke.

---

## 2. Why not a score

The obvious feature is "Alignment: 68%". It is wrong in four independent ways, and each one alone
would be disqualifying.

**It is false precision.** The app sees `Xcode`, and with Accessibility it sees
`ReceiptDeduplicator.swift — Lggr`. It cannot see the branch, the diff, or whether that file was the
right file. Forty minutes in Xcode against "Finish the receipt deduplication PR" might be 100% aligned
or 0% aligned and the evidence available to a userland macOS process is identical in both cases. Any
denominator is manufactured.

**It is the banned object.** `SPEC.md` § Design direction: *no gamification, no streaks, no
productivity scores that shame the user*. A percentage with an implied ceiling of 100 is a score with
a target. There is no neutral phrasing of "you were 68% aligned."

**It is not actionable.** The lever on a percentage is "try harder." Nobody has ever changed their
week because a number moved from 68 to 71.

**It collapses two opposite problems into one value.** Eleven two-minute Slack checks and one
twenty-two-minute detour produce the same 68%. They require opposite remedies — one is an
interruption-environment problem, the other is a decision you made once. A single scalar destroys
exactly the distinction the user needs.

### What replaces it

**One number: `Longest unbroken stretch — 23m`.**

- **It is measured, not inferred.** To have had a 23-minute stretch you must actually have had one.
  There is no ratio, no assumed total, no implied maximum.
- **It degrades honestly.** Its *value* comes from timing, which is reliable at zero permissions. Only
  its *boundaries* sharpen as permissions are granted. A percentage would silently change meaning
  between permission tiers; a duration does not.
- **Its lever is environmental, not moral.** You lengthen a stretch by quitting Slack before you
  start, by booking the calendar, by picking a different hour — decisions made *before* the session.
  That is a real lever. "Focus more" is not.
- **It refuses to be a target.** It is shown in exactly three places (§ 5). There is no personal best,
  no chart with a goal line, no comparison to yesterday in the moment, no notification, no badge, no
  colour. See § 7.4 for why this is not a streak by another name.

Alongside it, **departures** — a count and a list, never a percentage. Two to four per session, each
one a line of text you can read and correct.

Rejected alternatives, for the record: *time-to-first-departure* (too sensitive to a single early
Slack glance), *number of context switches* (SPEC asks for it and Today will keep showing it, but it
counts `Xcode → Terminal → Xcode` as two failures when it is one thought), *recovery time* (needs the
departure boundaries to be exactly right, which they are not).

---

## 3. The mechanism

### 3.0 Where it lives

Everything computational is a pure function over value types in `LggrKit`, unit-testable today with
`swift test` on Command Line Tools. No SwiftData, no `#Preview`, no AppKit.

```
Sources/LggrKit/Domain/
  IntentSignature.swift          [P3+]   what you declared, tokenised
  Relatedness.swift              [P3+]   the three-valued judgment + its evidence
  RelatednessResolver.swift      [P3+]   ActivityEvent → Relatedness, deterministic ladder
  SessionShape.swift             [P3+]   Stretch, Departure, SessionShape
  SessionShapeBuilder.swift      [P3+]   [ActivityEvent] → SessionShape
  SessionSummaryBuilder.swift    (exists) extended with shape-aware sentences
Sources/LggrApp/Views/Review/
  SessionShapeBar.swift          [P3+]   the striped session bar
  DepartureRow.swift             [P3+]   one departure + its correction affordance
```

### 3.1 Capture — nothing new is asked for

The alignment layer consumes Phase 3's existing signals and adds no capture of its own.

| Signal | API | Permission | Gate |
|---|---|---|---|
| Frontmost app, bundle id | `NSWorkspace.shared.notificationCenter` → `NSWorkspace.didActivateApplicationNotification`; `NSWorkspace.shared.frontmostApplication` | none | macOS 10.6+ |
| Idle | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)` (any event) | none | macOS 10.4+ |
| Window title | `AXUIElementCreateApplication(pid)` → `kAXFocusedWindowAttribute` → `kAXTitleAttribute` | **Accessibility** | macOS 10.2+ |
| Browser host | `NSAppleScript` per DESIGN § 6.1.2, host extracted by `DomainExtractor` | **Automation**, per browser | — |

Two capture facts that shape the whole design and must be stated rather than designed around:

1. **`secondsSinceLastEventType` measures input, not attention.** A 45-minute YouTube video with no
   keypresses reads as *idle*, not as a departure. This is a genuine hole. It fails in the safe
   direction — passive consumption is under-accused, never over-accused — and closing it would
   require Screen Recording, which § 6.1.6 forbids. It is documented in the app's own privacy text,
   not papered over.
2. **There is no supported way to know which git branch, file, or document another app has open.**
   `kAXDocumentAttribute` returns a `file://` URL for many document-based apps, which is more than the
   title and more sensitive than the title; it is **named here and deliberately not used**, because
   the title already carries the filename in Xcode, VS Code and Sublime, and a path is a step toward
   the thing SPEC § 4 forbids. If someone proposes `ScreenCaptureKit` for titles —
   `SCShareableContent.current` does expose `SCWindow.title` and does require Screen Recording, which
   grants pixel access to every window on the display. Rejected, permanently, for the reason in
   § 6.1.6: we take the narrower permission even though it is harder to explain.

### 3.2 `IntentSignature` — built from what you already typed

**Zero new fields.** This is the whole of principle 6. The signature is derived at session start from
the intended outcome, the project, and the work type — all of which the user typed anyway.

```swift
public struct IntentSignature: Sendable, Hashable {
    public let terms: Set<String>                       // folded, stemmed, ≥4 chars
    public let expectedCategories: Set<ActivityCategory>
    public let projectID: UUID?
    public let otherProjectTerms: [UUID: Set<String>]   // for cross-project evidence
}
```

**Tokenisation is deterministic and offline.** `NLTokenizer(unit: .word)` from the NaturalLanguage
framework (macOS 10.14+, on-device, no permission, no network, no downloadable assets) splits the
outcome; a fixed stopword list drops articles, prepositions and intent verbs (*finish, ship, fix,
review, write, the, a, on, for*); camelCase and snake_case are folded at both ends so
`receipt deduplication` matches `ReceiptDeduplicator.swift`; terms shorter than four characters are
dropped, except acronyms in the project's learned set.

> `NLTagger` with `.lemma` would give better stemming but pulls language assets for non-English text,
> which is a network operation in disguise. **It is not used.** A prefix match on ≥4 characters is
> good enough and provably offline.

`"Finish the receipt deduplication PR"` → `{receipt, dedup, deduplication}` (`PR` is 2 chars, dropped
as a term but present in `expectedCategories` via work type).

**Work type → expected categories** (a fixed table, not a guess):

| WorkType | expectedCategories |
|---|---|
| `.deepWork` | coding, testing, research, documentation |
| `.codeReview` | codeReview, coding |
| `.management` | communication, planning, meeting |
| `.communication` | communication |
| `.planning` | planning, documentation, research |
| `.incident` | **all except distraction** — see § 7.5 |
| `.meeting` | meeting, communication, documentation |
| `.administrative` | administrative, communication |

**`otherProjectTerms`** is the signature of every *other* active project, computed the same way from
its name. This is what makes the strongest honest drift signal possible: you said Project A and the
window titles say Project B.

### 3.3 `Relatedness` — three values, and why the third one is the ethics

```swift
public enum Relatedness: String, Codable, Sendable {
    case onIntent     // positive evidence tying this interval to the declared outcome
    case consistent   // no evidence either way — the default, and the majority
    case elsewhere    // positive evidence of different work
}

public enum RelatednessEvidence: String, Codable, Sendable {
    case none, distractionRule, titleTerm, domainTerm,
         otherProjectTitle, expectedCategory, unexpectedCategory, privateApp, idle
}
```

Two-valued classification (`aligned` / `not aligned`) forces the app to guess in the absence of
evidence, and a guess about whether you were working is an accusation. The third case makes
"I don't know" a first-class, countable outcome. **At zero permissions almost everything is
`.consistent`, and that is correct behaviour, not degraded behaviour.**

### 3.4 The resolver ladder

`RelatednessResolver.resolve(_ event: ActivityEvent, against: IntentSignature, preferences:)` →
`(Relatedness, RelatednessEvidence)`. Deterministic, first match wins, every result carries the rule
that produced it so the UI can always answer *why*.

| # | Condition | Result | Evidence | Needs |
|---|---|---|---|---|
| 1 | `event.isPrivate` | `.consistent` | `.privateApp` | — |
| 2 | `event.isIdle` | `.consistent` | `.idle` | — |
| 3 | title or domain contains an intent term | **`.onIntent`** | `.titleTerm` / `.domainTerm` | AX / AE |
| 4 | title or domain contains another project's terms | **`.elsewhere`** | `.otherProjectTitle` | AX / AE |
| 5 | `category == .distraction` (from a user rule) and `duration ≥ 60s` | **`.elsewhere`** | `.distractionRule` | — |
| 6 | `category ∈ expectedCategories` | `.consistent` | `.expectedCategory` | — |
| 7 | `category ∉ expectedCategories` **and** `classificationSource != .unclassified` | **`.elsewhere`** | `.unexpectedCategory` | — |
| 8 | otherwise | `.consistent` | `.none` | — |

Four properties of this ladder are load-bearing:

- **Rule 1 is absolute and first.** Marking an app private makes it permanently invisible to judgment.
  The app has no opinion about what it agreed not to look at. Private time extends a stretch and can
  never create a departure. This is a feature, not a loophole — it is the only way "mark as private"
  means anything.
- **Term matching can only ever produce `.onIntent`, never `.elsewhere`** (rule 3 vs. rule 4, which
  needs a *different* positive match). A missed term match costs you a nicer sentence. It never
  accuses you.
- **Rule 7 requires `classificationSource != .unclassified`.** The app calls Slack a departure from
  deep work only because a *rule the user can see and edit* says Slack is communication. `.unknown`
  never becomes `.elsewhere`. The app never accuses on the strength of its own ignorance.
- **Rule 3 outranks rule 7.** Slack with "receipt deduplication" in the title is on-intent. Arguing
  about the PR in Slack *is* the work.

### 3.5 The two primitives

```swift
public struct Stretch: Sendable, Hashable { public let start: Date, end: Date }
public struct Departure: Sendable, Identifiable {
    public let id: UUID
    public let start: Date, duration: TimeInterval
    public let dominantApplication: String   // already redacted
    public let evidence: RelatednessEvidence
    public let eventIDs: [UUID]              // so a correction can rewrite them
}
public struct SessionShape: Sendable {
    public let stretches: [Stretch]
    public let departures: [Departure]
    public let longestStretch: Stretch?
    public let idleTotal: TimeInterval
    public let hadTitleEvidence: Bool        // drives the honesty caption
}
```

**A stretch** is a maximal run of session time containing no `.elsewhere` interval longer than
`graceSeconds` (**90s**) and no idle run longer than `preferences.idleThreshold`.

The 90-second grace is the single most important constant in the design. Glancing at Slack for forty
seconds does not end your focus, and every tool that says it does produces numbers users know to be
false — which is precisely how a tool loses the right to make claims. Ninety seconds is long enough
to read a message and short enough that replying to one breaks the run.

**A departure** is a maximal run of `.elsewhere` time ≥ `departureFloor` (**120s**), attributed to
whichever app held the most of it. Sub-two-minute excursions are aggregated into the session totals
and are *never listed*. A session typically yields zero to four. Each one is a sentence.

Both are pure functions of `[ActivityEvent]` sorted by `startedAt`. Cost is O(n) after an O(n·|terms|)
resolve pass, with n ≈ 200 and |terms| ≈ 6. It runs in well under a millisecond; the review sheet does
not wait on it (DESIGN § 5.5.3 already specifies that the sheet is answerable before statistics land).

### 3.6 Where AI is allowed, and where it is not

`SPEC.md` § 5 is explicit: deterministic engine first. The ladder above **is** the engine, and it is
the only thing that ever assigns a `Relatedness`.

**FoundationModels** (`import FoundationModels`, macOS 26+, on-device, no network, Apple silicon,
Apple Intelligence enabled) is used for exactly one optional job: turning an already-decided
`SessionShape` into a better sentence than the template produces.

```swift
if #available(macOS 26, *), SystemLanguageModel.default.availability == .available { … }
```

Three constraints, all hard:

1. **It never changes a classification.** It receives a struct that is already final and returns
   prose. If it returned something unparseable, the template output ships instead.
2. **It never receives a window title.** `FoundationModels` executes in a separate system process, so
   passing titles moves them out of Lggr's address space. The prompt carries app names, durations,
   departure count and the intent string the user typed — nothing that was captured under
   Accessibility. This is stricter than "local only" requires, and it is the right line.
3. **The fallback is not degraded, it is just flatter.** macOS 14 and 15 have no
   `FoundationModels`; the framework is weak-linked and `SessionSummaryBuilder`'s deterministic
   templates (§ 4.2) carry every sentence the feature needs. **Nothing in this proposal requires
   macOS 26.**

---

## 4. What it changes for the user

### 4.1 During the session — the app answers, it never speaks first

**Take a side on the fork: the app never initiates. It is also never hiding.**

Rejected — *intervene*: a notification saying "you've been in Slack for 11 minutes" is an
interruption sent to tell you that you were interrupted. It is self-defeating on its face, it is
shaming by construction (an unbidden message about your behaviour is a judgment, whatever its
wording), and the app is wrong often enough — you were reading a spec on a domain it does not know —
that one false positive costs more trust than ten true positives earn. It would also train users to
close the app, which is the only outcome that makes the product worthless.

Rejected — *report only at review*: safe, but it throws away the one moment where the information
could still change something.

**Chosen — the live number is always there, and only where you already look.** The running popover
(DESIGN § 5.5.1) gains **one line**, at `Type.caption`, `.secondary`, no colour, no symbol change, no
animation:

```
┌────────────────────────────────────────┐
│  ● SOR engineering · Deep work         │
│  Finish the receipt deduplication PR   │
│                                        │
│             32:41                      │
│             remaining                  │
│  ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░▌        │
│  18m in this stretch                   │  ← new
│                                        │
│  [   Pause   ]      [   Finish   ⌘⏎ ]  │
└────────────────────────────────────────┘
```

During a departure the line becomes `4m elsewhere · 18m before that`. Never red. Never bold. The menu
bar symbol does **not** change — DESIGN § 5.6's icon states stay exactly as specified.

The argument for the live number is that it is the only element in this design capable of changing
behaviour in the moment, and it does so by being *a thing you would rather not reset* instead of *a
thing that scolds you*. Those are different psychological objects. It also recomputes only on
app-switch and idle-edge events, never on the one-second tick, so the popover keeps DESIGN § 5.1.2's
promise that nothing reprints itself every second.

**No notification about drift, ever.** The three notification kinds in DESIGN § 6.1.3 are unchanged
and this feature adds none. The long-idle notification stays — that one is about the *timer* being
wrong, not the user.

### 4.2 The review sheet

Replacing the statistics block of DESIGN § 5.5.3. The `6 switches` figure is retired from this sheet
(Today keeps it) because nobody can act on it.

```
┌────────────────────────────────────────────────────────────┐
│  What happened?                                            │
│  Finish the receipt deduplication PR                       │
│  ● SOR engineering · Deep work · 9:00–9:52                 │
│                                                            │
│  ( ✓ Completed ) ( ↷ Made progress ) ( ✋ Blocked )         │
│  ( ⌁ Interrupted ) ( ⑂ Reprioritized )                     │
│                                                            │
│  Longest unbroken stretch    23m           9:04–9:27       │
│  ▐▓▓▓▓▓▓▓▓▓░░░░░░░▓▓▓▓▓▓▓░░░░▓▓▓▓▓▓▓▓░░▌   52m             │
│                                                            │
│  Two departures                                            │
│   9:27  11m  Slack        ⓘ    [ part of this work ]       │
│   9:41   6m  YouTube      ⓘ    [ part of this work ]       │
│                                                            │
│  Xcode 24m · Terminal 9m · Slack 11m · YouTube 6m · 2m idle│
│                                                            │
│  Summary                                    ⟳ Regenerate ⌘R│
│  ┌──────────────────────────────────────────────────────┐  │
│  │ 52 minutes logged against the receipt deduplication  │  │
│  │ PR. The longest unbroken stretch was 23 minutes,     │  │
│  │ from 9:04 to 9:27. Two departures followed: 11       │  │
│  │ minutes in Slack and 6 minutes in YouTube.           │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ▸ Add result, blocker or next step                        │
│                                                            │
│  Not now            [ Log accomplishment ]   [ Save  ⌘⏎ ]  │
└────────────────────────────────────────────────────────────┘
```

**The bar is the session drawn as time.** Solid = on-intent or consistent, hollow = departure,
hairline = idle. One glance gives the shape, which is the thing a percentage destroys. It uses the
project colour and its own `.secondary` — no new semantic colour, per DESIGN § 5.0 rule 2.

**Departures carry the same typographic weight as everything else.** Not smaller, not red, not in a
box, no warning glyph. A departure is a fact about a Tuesday.

**`ⓘ` is the honesty affordance.** Hover or focus reveals *what Lggr saw*: `Slack · communication ·
rule "Slack → Communication" · not expected for Deep work`. The app can always be asked to justify
itself, in one hover, in plain words.

**`[ part of this work ]` is the retention mechanism, not polish.** One click rewrites those events to
`.onIntent`, recomputes the stretch live in front of the user, and offers *Always treat Slack as part
of SOR engineering?* → a real `ClassificationRule`. This is exactly the loop SPEC § 5 already demands.
**The app earns the right to make claims by being one click from being told it was wrong, and by
remembering.**

### 4.3 The copy rules

Non-negotiable, enforced in `SessionSummaryBuilder` and reviewed as strings:

1. Name the observation, never the person. *"11 minutes in Slack"*, never *"you got distracted."*
2. Verbs of occurrence — *happened, followed, ran, went*. Banned: *lost, wasted, failed, slipped*.
3. **No contrastive conjunction that implies a shortfall.** Banned tokens: *but, however, only, just,
   despite*. "You planned 50 minutes but managed 23" is forbidden; the same facts are stated as two
   sentences, in order.
4. No percentage of intent, anywhere, in any string.
5. No praise either. Zero departures reads **"No departures recorded."** — never *"Perfect focus!"*.
   Praise and shame are the same mechanism.
6. The summary asserts relatedness only where evidence exists, and states its own limits otherwise.

Four generated summaries, all deterministic, all shippable on macOS 14:

> **Clean.** "52 minutes on the receipt deduplication PR. Xcode and Terminal throughout, with one
> 5-minute GitHub review. Longest unbroken stretch: 47 minutes."

> **Drifted.** "52 minutes logged against the receipt deduplication PR. The longest unbroken stretch
> was 23 minutes, from 9:04 to 9:27. Two departures followed: 11 minutes in Slack and 6 minutes in
> YouTube."

> **Different work entirely.** "52 minutes logged against the receipt deduplication PR. Most window
> titles named Platform migration. The longest stretch on receipt deduplication was 6 minutes."
> — followed by an inline button: **`[ Move this session to Platform migration ]`**

> **No evidence** (Accessibility off). "52 minutes logged against the receipt deduplication PR.
> Xcode, Terminal and Slack. Lggr couldn't tell which of these were part of it."

That third case is the design in one line. **The app's response to detected drift is to offer to
correct the record, never to correct the user.** It reads as helpfulness because it *is* helpfulness:
you did real work on the wrong ticket and the app just filed it correctly for you. Drift becomes a
saved keystroke.

### 4.4 The weekly review

The same primitive aggregates into SPEC § 9's observation list, which becomes computable rather than
aspirational:

- "Your longest stretches happened before 11:00." *(SPEC's own example, now measurable.)*
- "Median longest stretch this week: 19 minutes. On Tuesday it was 6."
- "Slack accounted for 14 of your 31 departures."
- "Nine of your 22 sessions had no departure Lggr could see."
- **"You reclassified 7 departures as part of the work."** — the app publishing how often it was
  wrong. Nothing else in the product buys as much trust for as little code.

Weekly number = **median longest stretch**. Same primitive, one level up. Median, not mean, so one
four-hour Saturday does not rewrite the week.

---

## 5. Permissions, and the degraded mode

The one-line version: **this feature requests nothing.** It re-reads signals the permission ladder
already accounts for, and it appears in exactly three places — the running popover, the review sheet,
the weekly review.

| Tier | What the alignment layer gains | What the number means |
|---|---|---|
| **0 — nothing granted** *(the default)* | Rules 1, 2, 5, 6, 7, 8 fire. Departures exist only where a user rule already labels an app `.distraction`, or where the app's category contradicts the work type. Stretches are fully computed — they break on those departures and on idle. | "Longest run with no known distraction app and no long idle." Honest, useful, and the label does not change. |
| **1 — Accessibility** | Rules 3 and 4. `.onIntent` becomes possible; cross-project drift becomes possible; browser *page titles* become readable, which recovers much of Tier 2 for free (a GitHub PR's title usually contains the work item). | "Longest run where nothing said you were somewhere else." This is the tier where the feature is fully itself. |
| **2 — Automation, per browser** | `.domain` populated → `github.com` and `youtube.com` separate inside one Safari. | Sharpens browser departures only. |
| **Notifications** | **Unused by this feature.** | — |

**Degraded mode is a designed state, not an accident.** At Tier 0 the review sheet shows the bar, the
stretch, the idle hairlines and the app totals; the departures block is absent, and one
`Type.caption` `.secondary` line replaces it:

> "Window titles are off, so Lggr can only see which apps you used."

**No `Enable` button sits there.** DESIGN § 6.3 permits the Accessibility ask in exactly three places
and this is not one of them. It is a statement of the app's limits, offered once per sheet, never
escalating. Principle 5 says *never nag*, and a permission button that appears after every session is
a nag with a nice font.

Testable end to end without touching TCC, using the existing harness: `LGGR_PERMISSIONS=none|ax|ax+ae
./Scripts/run.sh`.

**Not used, on purpose:** EventKit (a scheduled meeting is intent-adjacent, but § 6.1.6 promises Lggr
never appears in the Calendar pane of System Settings, and that promise is worth more than the
feature); Screen Recording / ScreenCaptureKit (§ 3.1); Input Monitoring (SPEC § 4); the Speech
framework (needs a microphone, and there is nothing here to transcribe).

---

## 6. What could make it fail

**1. The feature is inert at Tier 0 — the most likely failure.** Most users never grant Accessibility.
If departures require titles, the panel is blank for most people and the whole thing reads as an
advertisement for a permission. *Mitigation:* build Tier 0 **first** and ship nothing until the review
sheet is visibly better than today's on stretches and idle alone. If it is not, the feature is
mis-scoped. See the kill criterion in § 8.

**2. Term matching is brittle.** "Finish the receipt dedup PR" against `ReceiptDeduplicator.swift`
needs camelCase folding and prefix matching, and it will still miss. *Mitigation:* the miss is
harmless by construction — rule 3 only produces `.onIntent`, so a missed match costs a nicer sentence
and never an accusation. Asymmetric failure is the design, not a patch on it.

**3. The false departure.** You read an RFC on a domain the app has never seen. *Mitigation:*
`.elsewhere` requires positive evidence (§ 3.4); the 120-second floor hides short excursions; and one
click corrects it and creates a rule. Note the structural advantage of the duration over the
percentage here — a wrong departure shortens one stretch and is visibly wrong in one place. A wrong
departure in a percentage silently poisons a headline number the user cannot audit.

**4. The stretch becomes a target.** If people start optimising it, it is the score I argued against.
*Mitigation, enforced as product law:* no personal best, no chart with a goal line, no in-session
comparison to yesterday, no notification, no badge, no colour, no appearance in the menu bar. It
resets constantly, keeps no record, and is never celebrated. A streak is a cross-day count with a
record you are afraid to lose and an alert when it is at risk; this has none of those four properties.
That distinction has to be defended in review every time someone proposes a "best stretch" badge.

**5. Meetings and incidents break the model.** In a meeting you also take notes and look things up; in
an incident you are legitimately in eight apps. *Mitigation:* `expectedCategories` is wide for both,
and **`.incident` sessions compute no departures at all** — an incident is definitionally everywhere,
and the app says so rather than pretending.

**6. The passive-consumption hole.** § 3.1, note 1: a long video reads as idle. Unfixable without
Screen Recording. Stated in the privacy text; failing safe.

**7. The user resents being right.** If the app calls two things departures, the user knows both were
work, and the correction does not stick, they turn tracking off within a week. The rule-creation loop
in § 4.2 is not a nice-to-have; it is the entire retention story.

---

## 7. The smallest first slice

**Tier 0 only. No new permissions. No AI. One screen.**

**`LggrKit`** — pure, tested today with `swift test` on Command Line Tools:

- `Relatedness`, `RelatednessEvidence`, `IntentSignature`, `RelatednessResolver`, `Stretch`,
  `Departure`, `SessionShape`, `SessionShapeBuilder`.
- Only ladder rules 1, 2, 5, 6, 7, 8 — **rules 3 and 4 are deliberately not written yet.**
- Tests, each one a design claim made falsifiable: a 60-second Slack visit does not break a stretch
  and a 100-second one does; idle below `idleThreshold` does not break a stretch; a 90-second
  distraction never becomes a listed departure; a private event never produces `.elsewhere` and always
  extends the stretch; an `.incident` session yields zero departures; a session with no activity
  events yields `longestStretch == active duration` and zero departures; `.unclassified` never becomes
  `.elsewhere`.

**`LggrApp`** — two components:

- `SessionShapeBar` + the departures list, inserted into `SessionReviewSheet` between the status
  picker and the summary.
- The `18m in this stretch` line in `MenuBarActiveView`.

**Explicitly not in the slice:** title matching, domain matching, cross-project detection,
`FoundationModels`, weekly aggregation, rule creation from a departure, the *Move this session to…*
action.

### The kill criteria, written down before the code

1. **After ten real sessions, if the "longest unbroken stretch" is a number the user cannot recognise
   as true, the model is wrong** — and no additional permission fixes a wrong model. Tune
   `graceSeconds` once; if it is still unrecognisable, kill it.
2. **If the departures list is empty in more than 8 of 10 Tier-0 sessions**, the feature has no content
   without Accessibility. That is not fatal, but it means this must be re-scoped and shipped honestly
   as a Tier-1 feature rather than as a mostly-blank panel that exists to sell a permission.

Both are answerable in a week of ordinary use, by the person who asked for it, on the machine that
already runs the app.

---

## Adversarial review

> Hostile read of §§1–7 against `SPEC.md`, `CONSTRAINTS.md`, `02-architecture.md`, `03-data-model.md`,
> `04-screens.md` and `05-permissions.md`. Claims below marked *(verified)* were checked by running
> `swiftc` against the CLT SDK on this machine, per this repo's culture of not asserting from memory.

### A. Technical impossibility — the named calls

**A.1 Every cross-reference in this proposal points at a file that does not exist.** There is no
`DESIGN.md` in `docs/_design/`. The design is `01-product.md` … `06-checklist.md`, and the cited
numbers do not map onto them:

| Cited as | Actually |
|---|---|
| DESIGN § 5.5.1 "the running popover" | `04-screens.md` § 5.1 — *The menu bar popover* |
| DESIGN § 5.5.3 "the review sheet" | `04-screens.md` § 5.3 (§ 5.5 is *Onboarding*) |
| DESIGN § 5.6 "icon states" | `04-screens.md` § 6.1 |
| DESIGN § 5.0 rule 2 "no new semantic colour" | `04-screens.md` § 2.4 |
| DESIGN § 5.1.2 "nothing reprints every second" | `04-screens.md` § 5.1 (no § 5.1.2 exists) |
| DESIGN § 6.1.2 / § 6.1.3 / § 6.1.6 | `05-permissions.md` § 1.2 / § 1.3 / § 1.6 |
| DESIGN § 6.3 "permits the Accessibility ask in three places" | `05-permissions.md` § 5.1 (`04-screens.md` § 6.3 is *How the menu bar icon stays subtle*) |

The central claim of this document is that it consumes only what is already specified and adds
nothing. That claim is currently unauditable. **Action: re-cite every reference against the real
filenames and section numbers before any other change is made to this file.**

**A.2 The idle row contradicts a locked architecture decision and force-unwraps.** § 3.1 specifies
`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .init(rawValue: ~0)!)`.
*(verified)* `CGEventType(rawValue: ~0)` is non-`nil` — `0xFFFFFFFF` is a declared case — so this
does not trap; but it is a force unwrap in a repo whose `CONSTRAINTS.md` rule 4 bans `!`, and it
survives only by accident of the enum's raw values. More importantly `02-architecture.md` § 6.4
already specifies idle detection differently: the *minimum* of `.mouseMoved`, key and scroll event
types, polled from a 15-second `@MainActor` timer. Two idle detectors is one too many.
**Action: delete the row and cite § 6.4.**

**A.3 The AX title read must not run on the main actor.** `AXUIElementCopyAttributeValue` is
synchronous cross-process IPC. Against an app that is hung, showing a modal, or swapping in, it
blocks the caller until the messaging timeout. `02-architecture.md` § 6.1 makes the entire `LggrApp`
target `@MainActor` with exactly one documented exception (`BrowserDomainReader`, an `actor`,
precisely because Apple Events can block). Nothing in this proposal or in Phase 3 grants the title
reader the same exception — so every app switch puts a blocking IPC call on the thread that draws the
popover. **Action: `actor AXTitleReader`, `AXUIElementSetMessagingTimeout(appElement, 0.25)` on the
application element at creation, and a second named exception in § 6.1.**

**A.4 The escape hatch in rule 3 will almost never fire, and rule 7 will fire in its place.** § 3.4
argues *"Slack with 'receipt deduplication' in the title is on-intent. Arguing about the PR in Slack
**is** the work."* Slack's `kAXTitleAttribute` is the workspace name, not the channel and never the
message. Linear, Notion, Figma and Teams are the same: the window title names the app or the
workspace, not the work item. So rule 3 misses, rule 7 catches, and the app calls a real working
conversation a departure. The doc treats term-match misses as harmless ("costs a nicer sentence")
— they are not harmless when a *lower* rule produces `.elsewhere` on the same event.
**Action: state which apps actually carry a work-item-bearing title (Xcode, VS Code, Sublime,
browsers) and confine rule 7 to apps outside that set, or accept A.7's fix.**

Related and worth forbidding in writing: the "fix" for Electron apps is to write
`AXManualAccessibility` / `AXEnhancedUserInterface` into the target process to force a fuller
accessibility tree. Lggr must never write an AX attribute into another application.

**A.5 The one place a title is genuinely rich is the browser — and § 5 celebrates it.** Tier 1 claims
browser page titles "recover much of Tier 2 for free". A host is `github.com`; a page title is
`Fix SSO bypass for Acme Corp · Pull Request #482`. That string is the most sensitive thing Lggr can
hold, and this proposal is the first feature to pattern-match it against *every project name in the
database*. It is a cost, not a bonus. See B.4.

**A.6 `NLTokenizer` earns nothing.** § 3.2 already hand-writes camelCase/snake_case folding,
stopwords, a ≥4-character filter and prefix matching. What is left for `NLTokenizer` is splitting on
whitespace and punctuation. Importing NaturalLanguage — with its version story, its asset caveat and
its per-language segmentation behaviour — to do that violates `CONSTRAINTS.md`'s "avoid unnecessary
abstractions" and adds a framework to a pure `LggrKit` type. **Action: split on
`CharacterSet.alphanumerics`; delete the framework and the paragraph defending it.**

**A.7 The header is not true.** *"New permissions required: none."* is true of Tier 0 only, and § 5
concedes Tier 1 is "the tier where the feature is fully itself". No *new grant* is requested, but the
*purpose* of an existing grant changes materially. `05-permissions.md` § 5 (onboarding Screen 3)
tells the user titles are read so the timeline can say "Xcode — ReceiptDeduplication.swift" and so
title rules can match. It does not tell them titles will be used to adjudicate whether they were
on-task, or to detect that they were secretly working on a different project. That is new consent
copy. **Action: rewrite onboarding Screen 3 and the privacy statement in the same change that ships
rules 3 and 4, and remove the "none / none / none" header, which currently reads as an argument
against review.**

### B. Creepiness — where reconstruction becomes surveillance

**B.1 Title-derived judgments outlive the titles they came from.** `05-permissions.md` § 7.2 is
explicit: retention prunes `ActivityEvent` **and nothing else**; sessions, summaries and
accomplishments are never auto-deleted, at any setting, ever. § 4.3's "Different work entirely"
summary — *"Most window titles named Platform migration"* — lands in `FocusSession.resultSummary`,
is kept forever, and is exported to Markdown. A user who set 30-day retention specifically to stop
keeping a window-title trace now has a permanent sentence that says the words *window titles*.
`Departure.evidence == .otherProjectTitle` has the same defect. **Action: title-derived facts are
recomputed at read time from live events and never persisted; and no generated string may contain
the phrase "window titles".**

**B.2 The `ⓘ` affordance cannot justify the two rules that matter without showing a title.** The
worked example (`Slack · communication · rule "Slack → Communication" · not expected for Deep work`)
is a rule-7 case. For `.titleTerm` and `.otherProjectTitle` the honest justification *is* the title.
Either `ⓘ` shows it — a surveillance-grade string on screen, screenshot-able, in a sheet that opens
automatically — or "the app can always be asked to justify itself" is false exactly where the app is
making its strongest claims. **Action: write the rule down — `ⓘ` shows only the **matched term**,
never the surrounding string; and the matched term is always something the user typed themselves
(their own outcome text, or their own project name). That resolves the fork without losing the
property. Add a test asserting no `String` sourced from a title reaches `Departure` or
`SessionShape`.**

**B.3 The departures list is a shoulder-surfing hazard.** `9:41 6m YouTube`, in a sheet that appears
at the end of every session, on a laptop that is frequently screen-shared. The doc's defence is
typographic — not red, not bold, not boxed. Legibility is not weight-dependent. Yes, a reasonable
engineer would mind a colleague reading it. **Action: departures collapsed behind a disclosure by
default; excluded from Markdown and CSV export unless explicitly opted in; and honour a single
"hide activity detail" switch that also blanks the popover line.**

**B.4 `otherProjectTerms` is a cross-referencing engine, and it is the one thing here that is
genuinely surveillance rather than reconstruction.** Every project name in the store is matched
against every window title — including personal projects, and including titles from apps the user
never thought to mark private. The output is a durable, exportable claim of the form *"you said A and
you were doing B"*, with a button. Reconstruction describes; this adjudicates. It also breaks the
document's own asymmetry: rule 4 is the only rule that converts a *title* directly into an
accusation, and it is the only accusation the user cannot correct with a rule — *(verified)*
`03-data-model.md` § `RuleMatchType` has four cases (`application`, `applicationName`,
`windowTitleContains`, `domain`) and no negation, so there is no "this title is not that project"
rule to create. **Action: cross-project evidence is computed at review time, never persisted, never
exported, and never produces a `Departure` — only the offer to re-file.**

**B.5 A customer name in a window title.** `Acme Corp — refund dispute — Zendesk` matches no intent
term and no other project, so it falls to rule 7: Zendesk is `.administrative` under a shipped rule,
the work type is Deep work, and a `Departure` is persisted. No customer name is stored — but the
string was read into the process, and the distance between "read into the process" and the SPEC § 4
prohibition on customer records is one careless `print`, one crash log, one `ⓘ` that shows too much,
and one summary template that quotes its evidence. **Action: state as an invariant that no code path
may log, persist, export or display a raw title; enforce it with the test in B.2.**

### C. Battery, CPU and correctness

**C.1 The live counter cannot be both correct and non-ticking.** § 4.1 promises `18m in this stretch`
"recomputes only on app-switch and idle-edge events, never on the one-second tick". A duration that
only recomputes on switch is *frozen*: forty minutes in Xcode and the popover still reads `18m`. The
number the doc calls "the only element capable of changing behaviour in the moment" is wrong for
most of the moment. **Action: publish `stretchStartedAt: Date` on switch and idle edges only, and
render `now − stretchStartedAt` through the timer text that already ticks. The *computation* is
event-driven; the *display* is per-second; § 5.1's promise is about layout, not about text.**

**C.2 Idle boundaries carry up to 15 seconds of one-directional error.** `02-architecture.md` § 6.4
polls every 15 seconds and closes the interval when the threshold is *detected*, not when input
actually stopped. Active time is therefore systematically over-counted, and the headline number is a
sum of intervals delimited by those edges — a stretch with four idle edges can be a minute wrong, in
the flattering direction. That is precisely "a number the user cannot recognise as true", kill
criterion 1, arriving from the instrument rather than the model. **Action: backdate the idle start —
`secondsSinceLastEventType` returns seconds since last input, so the true edge is computable at
detection time. Unit-test it.**

**C.3 Sleep and wake are not mentioned once in this document.** `SessionShapeBuilder` breaks a
stretch only on `.elsewhere > 90s` or idle > `idleThreshold`. Close the lid at 17:00 on an
open-ended session, reopen at 09:00, and if the sleep gap does not produce an idle event the flagship
number is `16h 04m`. Worse, `02-architecture.md` § 6.5 — the section that would prevent this —
observes `NSWorkspace.screensDidLockNotification`, which *(verified)* **does not exist**:
`error: type 'NSWorkspace' has no member 'screensDidLockNotification'`. The real signals are
`NSWorkspace.willSleepNotification` / `didWakeNotification` *(verified present)* plus
`com.apple.screenIsLocked` on `DistributedNotificationCenter`. **Action: state in § 3.5 that a sleep
gap, a screen lock and a fast-user-switch each unconditionally terminate a stretch regardless of
`idleThreshold`; unit-test the overnight case; and fix § 6.5's symbol.**

**C.4 Fast user switching is unhandled.** *(verified)* `NSWorkspace.sessionDidResignActiveNotification`
and `sessionDidBecomeActiveNotification` exist and are observed nowhere in the design. While another
user is switched in, Lggr keeps running, `frontmostApplication` still names your last app, and an
open session keeps accruing. **Action: observe both; close the interval on resign; treat the gap
exactly like sleep.**

**C.5 No timezone anywhere in the data model.** *(verified)* `03-data-model.md` contains no
`TimeZone` field on `FocusSession` or `ActivityEvent`. `Stretch` is two `Date`s and the sheet renders
`9:04–9:27`. Fly to Berlin and § 4.4's *"Your longest stretches happened before 11:00"* buckets by
the zone you are in now, not the zone you worked in. Cross a DST boundary inside a session and a
23-minute stretch renders `1:52–1:15`. **Action: add `timeZoneIdentifier` to `FocusSession`; bucket
hours with a `Calendar` in that zone; compute every duration as a `Date` delta and never from
wall-clock components.**

**C.6 One display, one app, one Space.** `frontmostApplication` is a single global. A video on the
second monitor, a build on the third, a dashboard on another Space — none of it exists to Lggr, and
`kAXFocusedWindowAttribute` can return the title of a window on a Space you are not looking at.
§ 3.1's honesty note covers passive video only. The true statement is broader and should be in the
privacy text verbatim: **Lggr sees one application at a time and cannot see a second display at
all.**

**C.7 The cost analysis prices the wrong thing.** § 3.5 costs the pure function — correct, and
negligible. It never costs capture. The real per-switch cost is a synchronous AX round trip (A.3)
plus, for browsers, an Apple Event once per activation and every 15 seconds while frontmost
(`05-permissions.md` § 1.2). This proposal materially increases the incentive to grant Automation,
which is the expensive permission. **Action: adopt a measured acceptance criterion — Lggr must not
appear in Activity Monitor's "Apps Using Significant Energy" across an 8-hour battery day — and make
it a Phase 3 gate, not a Phase 6 nicety.**

### D. Being wrong

**D.1 The asymmetry claim is false at the default tier, and this is the most serious objection in
this review.** § 1 and § 3.3 rest on *"it will claim you were elsewhere only when something
positively says so"*. Rule 7 fires on `category ∉ expectedCategories` **and**
`classificationSource != .unclassified`. § 3.4 defends the guard as meaning "a *rule the user can see
and edit*". It does not. *(verified)* `03-data-model.md`: `ClassificationSource` has
`.defaultRule`, `.userRule`, `.manual`, `.unclassified`, and
`ClassificationRule.source == isUserDefined ? .userRule : .defaultRule`. Lggr ships default rules —
SPEC § 5 names them (`Slack → Communication`, `YouTube → Distraction`). So `.defaultRule` satisfies
the guard, and at **Tier 0 — the default, the majority of users, and the only tier the first slice
ships** — every departure the user sees is manufactured by a table Lggr shipped, about an app the
user never labelled, with no positive evidence of anything. The document's proudest property is
violated by its most common code path.

**Action: rule 7 requires `classificationSource == .userRule || classificationSource == .manual`.**
Then face the consequence rather than patching it: a Tier-0 user with no rules gets zero departures,
which trips kill criterion 2, which means this is honestly a Tier-1 feature that degrades to a
stretch-and-idle bar. That is a defensible product. "Accurate at Tier 0" is not.

**D.2 Corrections are one-directional, so the feature erodes itself to nothing.** `[part of this
work]` exists; `[not part of this work]` does not. Every correction pushes events toward `.onIntent`
and offers a permanent `ClassificationRule`. No path ever *adds* a departure. Over weeks the rule set
converges on "nothing is ever a departure", the panel empties, and § 4.4's trust-buying line — *"You
reclassified 7 departures as part of the work"* — reads `0` for the flattering reason. **Action: make
the correction symmetric, and default the offered rule to project scope (`ClassificationRule.projectID`
already exists) rather than global. "Slack is part of SOR engineering" is almost never true of every
project.**

**D.3 A correction destroys the evidence and makes the headline number editable.** § 4.2: one click
"rewrites those events to `.onIntent`". `Relatedness` is a *derived* value; writing it back into
`ActivityEvent` makes the correction irreversible, makes the shape unrecomputable, and means the
"longest unbroken stretch" can be raised by clicking. "Measured, not inferred" does not survive a UI
where the measurement is an editable field. **Action: store corrections as a separate
`[UUID: Relatedness]` override map on the session; `SessionShape` remains a pure function of
`events + overrides`; undo is removing a map entry.**

**D.4 Granting Accessibility retroactively shortens your history.** Rules 3 and 4 only *add*
verdicts. If `SessionShape` is computed on read, Monday's 23-minute stretch becomes 11 minutes on
Thursday because a permission changed on Wednesday. If it is stored, it is stale and the weekly
median silently mixes tiers. § 2 claims the opposite — *"a percentage would silently change meaning
between permission tiers; a duration does not"*. It changes just as silently, and this is the one
place the duration has no advantage over the ratio. **Action: seal `SessionShape` at session end,
persist the tier that produced it, and either exclude tier-mixed weeks from the median or label them
on screen.**

**D.5 "Move this session to Platform migration" is not one click to undo.** Moving a session rewrites
project time allocation, the weekly-outcome link, and the provenance of any `Accomplishment` already
generated from it — `Accomplishment` carries both `project` and `focusSession`. The doc calls it "a
saved keystroke"; reversing it is several, across three screens. **Action: one reversible
transaction with an explicit Undo, never touch `Accomplishment.project`, and a confirmation that
names exactly what will move.**

**D.6 The cost of being wrong is paid every session, forever.** § 6.3's mitigation is "one click
corrects it". At 2–4 departures per session that is 2–4 decisions per session, for the life of the
product, spent defending the app's opinions — against SPEC principle 2 (*minimal manual data entry*)
and against § 5.3's promise that the sheet is answerable in seconds. **A wrong auto-filled summary is
worse than a blank one here** for a specific reason the doc does not state: the summary is written
into the permanent record (B.1) and exported to Markdown, so an uncorrected wrong sentence becomes
the user's own account of their week. **Action: the generated summary must remain a *suggestion* the
user confirms, per SPEC § core workflow steps 9–10 — never pre-committed on save-without-edit.**

**D.7 `.incident` poisons the weekly number.** § 6.5 gives incident sessions zero departures, so an
incident's longest stretch is the entire session — necessarily every user's best. § 4.4's weekly
median is then dragged up by exactly the sessions in which focus was least real. **Action: exclude
`.incident` from the weekly median, and say so in the caption.**

### E. Product principle violations

**E.1 The live stretch counter is the banned object, by this document's own argument.** § 4.1
justifies it as *"a thing you would rather not reset"*. A visible, live, monotonically increasing
number that resets on the behaviour you are trying to avoid is a score with a loss condition; the
named mechanism is loss aversion. § 7.4 defines a streak by four properties and then observes the
feature has none of them — but the definition was written after the feature, to exclude it. SPEC's
Design direction bans *gamification, streaks, productivity scores that shame the user*, and the
operative word is the mechanism, not the noun. **Action: either show the stretch only after the
session ends — where it informs and cannot pressure — or ship it default-off behind a Settings
toggle. And delete the loss-aversion paragraph: a feature that needs that argument is the feature
SPEC banned.**

**E.2 The Tier-0 caption is a per-session permission nag.** *"Window titles are off, so Lggr can only
see which apps you used"* appears in the review sheet after **every** session. `05-permissions.md`
§ 5.1 sets the re-ask policy at one dismissible banner, ever. § 5 congratulates itself on having no
`Enable` button while shipping a recurring, non-dismissible reminder of a withheld permission — "a
nag with a nice font", the doc's own phrase, applied to itself. **Action: once, dismissible forever,
or fold it into Settings › Privacy.**

**E.3 It is a feature for one persona, and SPEC lists that persona second.** The whole term-matching
mechanism assumes your window titles contain the words you typed — true for a developer whose ticket
name resembles a filename. SPEC's mandate names **engineering managers first**. For `.management`,
`.meeting` and `.communication`, `expectedCategories` is wide so rule 7 rarely fires, rule 3 never
fires because no title says *"1:1 with Omar"*, and the manager gets one solid bar, no `.onIntent`, no
departures and a caption explaining that Lggr could not tell. **Action: state the target persona
honestly in § 1, and add one manager-legible signal that works at Tier 0 — declared meeting duration
versus time in meeting-category apps is a rule, not AI, and needs no permission — or narrow the
claim.**

**E.4 `FoundationModels` is AI where a rule already does the job.** § 4.3 ships four deterministic
templates that this document presents as good copy, then adds an on-device LLM to make them "better".
It is macOS 26 only, Apple-silicon only, Apple-Intelligence-enabled only, region- and language-gated,
and *unbuildable and untestable on the machine `CONSTRAINTS.md` describes* (macOS 14 target, no
Xcode). Its output must then be validated against the same § 4.3 copy rules that the templates
satisfy by construction. **Action: delete § 3.6 outright rather than deferring it. A documented but
unshipped LLM path is an invitation, and SPEC's closing line forbids AI summaries until the core
tracking workflow is functional, polished, persistent and tested — which Phase 3 is not.**

**E.5 It silently retires a SPEC requirement.** § 4.2: *"The `6 switches` figure is retired from this
sheet ... because nobody can act on it."* SPEC § 6 lists *"Number of context switches"* among the
things the completion review must display. A proposal may not remove a SPEC requirement from the
screen SPEC assigned it to as an aside. **Action: keep it, or amend SPEC deliberately and record the
amendment in `DECISIONS.md`.**

**E.6 Kill criterion 2 contradicts the design it is meant to test.** It re-scopes the feature if the
departures list is empty in more than 8 of 10 Tier-0 sessions. But § 3.3 says *"at zero permissions
almost everything is `.consistent`, and that is correct behaviour, not degraded behaviour"*, and
§ 4.4 offers *"Nine of your 22 sessions had no departure Lggr could see"* as a **good** line. By the
design's own account, criterion 2 fires on a correct implementation. **Action: replace it with the
only test that matters — after ten sessions, does the user recognise the bar's shape and the
longest-stretch number as true? That is criterion 1. Delete criterion 2, and instead pre-commit to
shipping this as a Tier-1 feature per D.1.**

### Verdict

**KEEP WITH CHANGES** — the three-valued judgment, the duration-not-ratio primitive and the
correct-the-log-not-the-user response are genuinely right and worth building, but the feature is not
honest at Tier 0 until rule 7 requires a user-authored rule (D.1), the live counter is the
gamification SPEC bans and must leave the popover (E.1), cross-project title inference must be
ephemeral and unexported (B.4), corrections must be symmetric and non-destructive (D.2, D.3), sleep /
lock / fast-user-switch / timezone must be specified before any number is published (C.3–C.5), and
every citation in the document must be re-pointed at a file that exists (A.1).
