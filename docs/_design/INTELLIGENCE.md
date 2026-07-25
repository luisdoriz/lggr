# Lggr — The intelligence layer

> **Status:** decided. This supersedes the five exploratory proposals in this folder
> (`intel-reconstruction.md`, `intel-alignment.md`, `intel-zero-input.md`, `intel-invisible-work.md`,
> `intel-privacy-max.md`). Those remain as research; this is what gets built. Where they conflict,
> this document resolves the conflict and says which side lost and why.
>
> Binding inputs: `SPEC.md`, `CONSTRAINTS.md`, `DECISIONS.md`. Everything here is additive to the
> Phase 2 build that runs today (`JSONFileStore`, `SessionClock`, `SessionSummaryBuilder`, menu bar,
> Today, review sheet).

---

## 1. The core bet

**Lggr should be able to tell you what you did yesterday, even though you forgot to press start.**
Today the app knows only the work you were organised enough to announce in advance — which is, almost
by definition, the work you already remember. The bet is that a quiet, always-on record of which
application was in front of you, for how long, with the gaps marked honestly as gaps, is enough to
rebuild a day into eight or ten blocks that you recognise: *"9:04–9:58, Xcode and Terminal. 10:12–10:40,
away. 10:40–12:05, Chrome and Xcode."* Not a log of six hundred app switches — a day you can read in
fifteen seconds and turn into a session, an accomplishment, or a standup note with one keystroke. The
reason this and not the alternatives: every other idea in this folder is downstream of it. You cannot
measure whether you drifted from your intent (`intel-alignment`) without first knowing what the day
actually looked like. You cannot propose an outcome before the user types it (`intel-zero-input`)
without a memory of what they did in this situation before. You cannot count the pull requests a
manager reviewed (`intel-invisible-work`) without a timeline to hang them on. Reconstruction is the
substrate; the rest are features on top of it, and each of them is optional in a way the substrate is
not. And it is the one bet that pays out at **zero permissions**, on **day one**, for **every** user
in the spec's audience — which none of the others do.

The counterpart to the bet, and the thing the whole design is arranged around: **a confidently wrong
block is worse than no block at all.** People forgive "I don't know." Nobody forgives "you did X" when
they did Y, and worse, a plausible wrong block gets believed, exported, and pasted into a document
that matters. So every mechanism below exists to make the app willing to say nothing.

---

## 2. What I took from each proposal, and what I rejected

Nothing here is a survey. Each row is a decision.

### From `intel-reconstruction.md` — **the spine**

| Taken | Why |
|---|---|
| **`Episode` as the unit of product**, not `ActivityEvent`. Raw events are evidence; the block is the thing | This is the correct product primitive and the reason the feature is legible. Adopted wholesale |
| **The five-stage deterministic pipeline** (normalise → evidence → boundary score → absorb to fixed point → name) as a pure function in `LggrKit` | Compiles and is unit-testable today with no Xcode, no permissions, no running app. The risky part gets proved against fixtures before a view changes |
| **Glance collapsing** — a <8 s excursion that returns is an `interjection`, not a boundary | Removes 40–60% of raw activations. A cmd-tab to Slack and back is not a context switch in any sense a user recognises |
| **`sessionBoundary` is an infinite-weight cut** — an explicit session is ground truth | Keeps everything the app already does working, and makes reconstruction fill the space *between* sessions rather than compete with them |
| **The heartbeat and `Gap(.appNotRunning)`** | The single most important honesty mechanism in the plan. See §5 |
| **Refusing to assign below a margin** | "Unassigned" is a feature |
| **Sealed days** — after 04:00 a day's episodes are immutable except by explicit user edit | A timeline that silently rewrites its own past is not evidence |
| **Slice 0 measures before it builds** | Right instinct. Hardened per §4 |

| Rejected | Why |
|---|---|
| **The mic-hot CoreAudio signal** | KILLED. See §3.1 |
| **`FoundationModels` naming of last resort** | KILLED. See §3.2 |
| **Storing window titles for 30 days** | KILLED. See §3.3 — this is the biggest single change from the proposal |
| "The evidence expires, the reconstruction persists" | Backwards, as its own review found (2.2): the *label* is the quotable string. Resolved by never storing the title in the first place, so there is no inversion left to get wrong |
| `evidenceEventIDs: [UUID]` on every Episode | Its own review priced this at ~10 MB/year and noted the audit trail has a 30-day fuse. Replaced by an interval range + count |
| "~55% / ~85% / ~95%" permission-tier value table | Fabricated numbers in a document whose own first slice exists because nobody knows the answer. Deleted, not corrected |
| "Longest unbroken stretch" in the Recap footer | A personal record in a product that bans them. See §3.4 |

### From `intel-privacy-max.md` — **the capture discipline**

| Taken | Why |
|---|---|
| **`ShapeOfWork`: timing-only signals are the Tier-0 engine** — longest run, excursion/return latency, alternation bigrams with median gap, interruption-source ranking, switch rate vs personal baseline, circadian profile | This is the strongest technical argument in the folder. Four of SPEC §9's five example observations are exactly computable with no permission and no content. It is also the cheapest thing in the plan to write and test |
| **Inverting SPEC §4's window-title default from Stored to Derived** | A better default than the spec's own. Adopted and hardened: Derived is not a default, it is the *only* mode in v1 |
| **The type boundary** — no function anywhere returns a window title; `check-layering.sh` fails the build if one is added | The one mechanism that converts a privacy promise into something a reviewer can check |
| **"Lggr states its own blind spots on the screen where the number appears"** | Adopted as a copy law. A flatteringly low context-switch count the user cannot interpret is worse than no count |
| **The Record screen's content** — counts over the user's own file, field-by-field, delete controls | Genuinely good. Moved into Settings → Privacy per its own review (5.4); an eighth sidebar item breaks SPEC's ⌘1–⌘7 contract |
| **Idle must not define "unbroken"** | Its review *verified* that any process can zero `secondsSinceLastEventType` — Screen Sharing, jigglers, Karabiner, Zoom remote control. Frontmost-app continuity defines runs; idle is a display annotation with a confidence flag |
| **The refusal list** (no ScreenCaptureKit, no OCR, no event taps, no salted title hashes, no full URLs) | Adopted verbatim as project law |

| Rejected | Why |
|---|---|
| **The shipped "privacy self-test" canary button** | Its own review (5.5) is decisive: it tests a synthetic day in a temp directory with configuration the test controls, so it can report "passed, 0 hits" while the real store holds thousands of titles. Keep `PrivacyCanaryTests` in CI; the shipped button scans the **real** store and reports real counts |
| **The Record screen's "Network — no networking framework is linked" row** | Verified false: the entitlement is inert in an unsandboxed build and `URLSession` lives inside Foundation. Replaced with a `check-layering.sh` rule that no target may `import Network`/`CFNetwork`, plus one plain sentence with no fake mechanism attached |
| **Content-free tab counting via `kAXTitleChangedNotification`** | Verified not to exist at that permission level: title-change fires on unread-count churn at ~1 Hz, and a tab is not an `AXWindow`. The browser blind spot is accepted and stated, not mitigated by a capability we cannot build |
| **`reads.json` with `inputBytes`** | A per-read, per-second title-length time series — finer-grained than the store it audits, and covering private apps. Dropped |
| **Fragmentation index, warm-up latency, switch-rate ratio as *surfaced* numbers** | All three are scores. "It took you six minutes to start" is the most judgmental sentence in the folder. Computed internally where useful, never rendered |
| **"Not in a session today — 2 h 51 m" as a headline total** | The number that grows when you fail to comply with the app. §3.4 |
| The `CFStringFind` "never copied into Swift-managed memory" claim | Substantively false — a copy-out IPC deserialises into our address space; same heap, same crash report. Also trips this repo's own `as!` lint. The type boundary stands on its own without the false mechanism |

### From `intel-zero-input.md` — **the interaction law**

| Taken | Why |
|---|---|
| **Propose as ghost text, never as inserted text** | The best single interaction decision in the folder. A wrong proposal costs zero keystrokes because you were going to type anyway. Extended, per its own review (W1), to **every** inferred field — the project picker renders ghosted and unselected too, or it is not inferred at all |
| **Only typing and correcting move the weights; accepting adds almost nothing** | The anti-runaway rule. Without it the system trains on its own output and locks in early mistakes precisely because the interaction is frictionless |
| **`RecordOrigin` (`typed` / `accepted` / `acceptedEdited` / `corrected`)** | Makes "how much of this week is inference" answerable, which is what the user needs in order to know how much to trust the page |
| **Correction applies first, the rule offer comes after, quietly; Escape is a valid answer** | Correct ordering. The correction is saved either way |
| **Blast radius before consent** — *"this would also change 23 earlier blocks — 1h 40m"*, checkbox off by default | This is what makes a button labelled *Always* honest |
| **Transactional ⌘Z** — undo reverts the record *and* the weight *and* the ledger row, as one function with one test | Per its review (W3): an undo that leaves a `+4.0` behind teaches the system from an action the user retracted |
| **Rules are reversible with their cause attached** (`Remove and revert`) | A learning system you cannot un-teach is one you stop trusting the first time it learns wrong |
| **"Start a session on this ⌘⏎"** from the open block | The highest-leverage moment in the app: the user is already doing the work and we ask for one key instead of a form |

| Rejected | Why |
|---|---|
| **`.weak` candidates persisted** ("never shown; kept for the ledger") | KILLED. This writes the complete unparsed title of every window in every app with no grammar — Mail subject lines, Messages counterparties, `Termination letter - Alvarez.pdf` — into `candidates.json` in plaintext. A subject line *is* email content. `.weak` means **discarded**. Never persist an unparsed title, not for 24 hours, not for one second |
| **App Intents** (`StartFocusSessionIntent` et al.) | Verified: `appintentsmetadataprocessor` is an Xcode build phase and is not in the CLT. They compile green, ship, and never appear in Spotlight or Shortcuts. Cut until Xcode exists |
| **The `FoundationModels` summary rewriter** | §3.2 |
| **EventKit at Tier 3** | §3.5 |
| **`GitHeadReader` / `kAXDocumentAttribute` / chosen git roots** | Three separate failures in one feature: `.git` is a *file* in worktrees and submodules; detached HEAD offers `"Work on a1b2c3d4e5…"` as your intended outcome at shown confidence; security-scoped bookmarks are a sandbox mechanism that carries no TCC grant, so "no prompt Lggr did not cause" is not achievable by the stated means. A file path is also a directory tree of a person's life. Cut entirely |
| **`AccomplishmentDetector` from dwell time** | KILLED. §3.6 |
| **`ParsedTitle.author`** | Harvests a colleague's GitHub handle into memory, into an accomplishment title, into an exported Markdown. That surveils a **non-user**. If we ever need the user's own handle, they type it in Settings |
| **`Log all`** | One button creating eight machine-written sessions. Removed until per-block precision is measured |
| **`ProjectRule` as a sibling of `ClassificationRule`** | Two matchers, two histories, two revert flows. One `Rule` with an enum outcome — `.category(_)` / `.project(_)`. Cheaper now, before either exists |

### From `intel-alignment.md` — **the ethics of judgment**

| Taken | Why |
|---|---|
| **Three-valued relatedness: `onIntent` / `consistent` / `elsewhere`**, with `.consistent` the honest default | Two-valued classification forces the app to guess in the absence of evidence, and a guess about whether you were working is an accusation. This is the right shape |
| **Asymmetric evidence** — a term match can only ever produce `.onIntent`, never `.elsewhere` | A missed match costs a nicer sentence. It never accuses |
| **Private apps are absolutely invisible to judgment, rule 1, first** | The only way "mark as private" means anything |
| **"The app's response to detected drift is to offer to correct the record, never to correct the user"** | This is the best line in the folder. Drift becomes a saved keystroke: *"Most of this looked like Platform migration. Move this session?"* |
| **The `ⓘ` justification affordance**, showing only the **matched term** — which is always something the user typed themselves | Resolves its review's fork (B.2) without losing the property: the app can always be asked to justify itself, and never renders a captured string to do it |
| **The copy rules** — no contrastive conjunctions, no *only/just/wasted/lost*, no praise either ("Perfect focus!" and shame are the same mechanism), no percentage of intent anywhere | Adopted as a test over the copy catalogue, not a convention |
| **`.incident` sessions compute no departures** | An incident is definitionally everywhere and the app should say so rather than pretend |

| Rejected | Why |
|---|---|
| **The alignment score** — this was already rejected *by* the proposal, and I am ratifying it | False precision, a banned object, not actionable, and it collapses eleven Slack glances and one 22-minute detour into the same number when they need opposite remedies |
| **The live "18m in this stretch" counter in the running popover** | KILLED. §3.4 |
| **Rule 7 firing on `.defaultRule`** | Its review (D.1) is the most serious finding in that document and it is correct: Lggr ships default rules, so at Tier 0 — the default, the majority, the only tier the first phase ships — every "departure" would be manufactured by a table we shipped about an app the user never labelled. Departures require `.userRule` or `.manual`. The consequence is that departures are a Tier-1 feature, and that is fine |
| **`otherProjectTerms` — cross-project title matching, persisted** | This is the one thing in the folder that is genuinely surveillance rather than reconstruction: every project name in the store matched against every window title, producing a durable exportable claim of the form "you said A and you were doing B", which the user cannot even write a rule against (`RuleMatchType` has no negation). Kept only as an ephemeral, review-time, never-persisted, never-exported *offer to re-file*, never a `Departure` |
| **Persisting title-derived facts into `resultSummary`** | A user who set 30-day retention specifically to stop keeping a title trace would get a permanent sentence containing the words *window titles*. Under §3.3 there is no title to derive from, so this is moot — but the rule stands: no generated string may name the capture mechanism |
| **Retiring "context switches" from the review sheet** | SPEC §6 requires it. A proposal may not delete a spec requirement as an aside |
| Its `NLTokenizer` dependency | Splits on whitespace after the doc has already hand-written camelCase folding, stopwords and a length filter. `CharacterSet.alphanumerics` |

### From `intel-invisible-work.md` — **the architectural inversion**

| Taken | Why |
|---|---|
| **Ambient-first: capture runs continuously; a focus session is a *label applied to a span* of it, not a container for it** | This is the correct architecture and it is what makes reconstruction possible at all. `ActivityTrackingService` is continuous from the first line of code |
| **The price of the inversion, paid up front**: the menu bar icon must visibly distinguish tracking / paused / not tracking, and **Pause tracking** is the popover's first row, not a Settings toggle | Non-negotiable. If the app is always watching, the user must see that at a glance and stop it in one click. And per its review (2.5), "a subtle filled variant" is not perceptible — it is a distinct glyph |
| **"Ask, don't assert"** — the classifier emits a candidate with a confidence, never a fact | Adopted, and per its review (4.4), applied to the *high*-stakes claims too, not just the low-stakes ones |
| **"Under-claiming is the only acceptable failure direction"**, with the discipline made concrete: for every number that reaches an export, write down the adversarial input that inflates it and require a suppression rule; if you cannot write the rule, the number does not ship | Adopted as a review checklist item |
| **Fail closed to nothing** — a title matching no grammar produces zero evidence, never a best guess | A missing fact is recoverable; a wrong fact in a promo packet is not |
| **The probe-first structure with pre-agreed kill criteria** | The best engineering discipline in the folder |
| **"Every number links to the minutes behind it"** | A number the user cannot defend in the conversation that follows is worse than no number |
| **Out-of-hours copy law**: facts about the record, never about the person. *"Nothing was declared for this block"*, never *"you forgot to track this"* | The way you actually honour SPEC's ban on shaming is by never writing a sentence whose subject is the user's character |

| Rejected | Why |
|---|---|
| **The microphone HAL boolean** | KILLED. §3.1 |
| **`Copy evidence for… ▸ a person`** | KILLED. §3.7 |
| **The per-person ledger in v1** | Deferred behind everything else, and gated. Its own review found: the app has no idea who the user is, so every PR they *authored* is counted as support work for someone else — inflating SPEC §9's own flagship observation; and every colleague appears twice (`Omar Reyes` and `omar-reyes`) with half their time each, so the first weekly review a user ever sees is eight rows for four people, all wrong |
| **The CoreMediaIO camera signal** | Rejected by the proposal itself and then kept behind a flag. A flag is a promise to maintain a code path for a signal you have already decided is untrustworthy. Cut |
| **`switchRateZ`, `appSetEntropy`, the 10th-percentile hour-of-week histogram** | This is a model with hyperparameters wearing a rule table's clothes. It has a 28-day cold start (fires on everything in week one — exactly when trust is decided), a timezone failure (fly to Berlin and *every* episode is "outside your usual hours" for a week), and no way for a user to understand or correct why it fired. SPEC §5 asks for rules the user can correct into reusable rules; `appSetEntropy < threshold` cannot be corrected. **The boring version first:** an undeclared block worth asking about is one longer than 20 minutes not covered by a session. One rule, explainable in a sentence, works on day one, never fires on a flight |
| **The "3 undeclared blocks" count badge** | A streak counter run in reverse: a number on the default screen that goes up when you fail to comply and down when you perform triage. The copy underneath it is excellent; the number is the judgement |
| **"outside usual working hours" in the export** | Three surfacings, one of which leaves the machine. Once it is in a document a manager reads, it is a boast or a red flag depending entirely on the reader, and the user has lost the framing. The timestamp is already there |
| **`.document(app:name:)` and `.conversation(.channel)` as free text** | Raw titles wearing a type. `Q3 layoff planning`, `#incident-2026-07-payments-outage`, `PIP — Dani Okafor`. Under §3.3 neither ships as a stored string |
| Its `probe.jsonl` as specified | Five days of every window title of an engineering manager, plaintext, in a Time-Machine-backed, Spotlight-indexed, EDR-readable directory. Hardened beyond recognition in Phase 3 |

---

## 3. The adversarial findings that ended a feature

Every critique that said KILL is honoured below. None is quietly dropped.

### 3.1 The microphone HAL boolean — **killed**

Both `intel-reconstruction` (§2.2) and `intel-invisible-work` (§2.2) proposed reading
`kAudioDevicePropertyDeviceIsRunningSomewhere` to detect meetings with no TCC permission. Both reviews
said kill, for different reasons, and both are right:

- **It does not work.** The property is read at global scope on a *device*: any duplex device (AirPods,
  most USB interfaces) sets it when music plays; virtual devices (Krisp, Loopback, BlackHole) hold it
  true all day; and a meeting on a non-default input is missed entirely — so it produces false
  negatives for exactly the headset users who take the most calls.
- **The conjunction meant to save it is always true.** "a known conferencing bundle **is running**" is
  satisfied from login to logout for every engineering manager alive. The predicate reduces to
  `micRunning AND duration ≥ 4min → meeting, confidence .high`.
- **It fabricates days.** With the meeting test ordered before the sleep test, a lid closed on Friday
  with Krisp installed records 62 continuous hours of "active listening" as tracked time.
- **And it was chosen *because* it has no consent gate.** That is the disqualifying part. The orange
  indicator dot exists because Apple decided mic activity is information the user is owed; harvesting
  the same fact for a third party, persisting it, and rendering *"13:20–14:10 Meeting · mic active"* on
  a screen a colleague can see is not reconstruction. It captures the personal call, the therapy
  appointment, the recruiter call.

**Replacement:** meetings are detected from a frontmost conferencing bundle or a conferencing domain,
and that under-counts — a Zoom call on the second monitor while Xcode is focused is missed entirely.
That under-count is stated on the screen where the meeting time appears (§2, privacy-max's blind-spot
law) rather than papered over with a signal we cannot defend.

### 3.2 On-device inference (`FoundationModels`) — **cut entirely, not deferred**

Four of the five proposals reached for it. All four reviews rejected it, and the objections stack:

1. **It does not compile on this machine.** Verified independently in two reviews: `@Generable` and
   `@Guide` are macros from `FoundationModelsMacros`, and the CLT plugin directory contains only
   `libObservationMacros`, `libSwiftMacros` and `testing/libTestingMacros`. `#if canImport(FoundationModels)`
   is **true** — the framework ships in the SDK — so the guard does not save you; the file is compiled
   and fails exactly as `@Model` does. `CONSTRAINTS.md` rule 1 forbids this in `LggrKit` or `LggrApp`.
2. **It is non-deterministic, in a product whose central claim is that days are sealed and reproducible.**
   An LLM-generated label cannot be reproduced by a snapshot test and will differ between two runs over
   identical evidence.
3. **Its job is to improve on a rule-based name that the spec itself holds up as the target.**
   `SPEC.md` §7's worked example is literally `Xcode, Terminal, GitHub`.
4. **Availability is macOS 26 + Apple Silicon + Apple Intelligence enabled + supported region, against a
   macOS 14 deployment target.** A feature for a minority of machines, duplicating a component
   (`SessionSummaryBuilder`) that already ships and is already tested.

The `intel-privacy-max` argument settles it on principle rather than logistics, and it is the one worth
keeping: **the privacy question here was never the network, it was channel capacity.** Routing a title
into an 11-case rule table leaks about 3.5 bits. Routing it into a language model invites a `String`
output, and every product pressure to make that output "useful" is pressure to raise its capacity until
it is the title, paraphrased, on disk.

A documented-but-unshipped LLM path is an invitation. This is not deferred to a later phase; it is out
of scope for the intelligence layer, and `SPEC.md`'s closing line ("do not implement advanced analytics
or AI summaries until the core tracking workflow is functional, polished, persistent and tested")
covers the rest.

### 3.3 Storing window titles — **killed, including the 30-day tier**

`intel-reconstruction` proposed persisting titles for 30 days. `intel-zero-input` proposed persisting
unparsed ones for 24 hours. Both reviews found the same thing and it is not a corner case, it is the
median title:

- A browser window title is the page `<title>`: `Kaiser Permanente — Your test results`,
  `Greenhouse — Interview: Senior Engineer`, `Divorce lawyer San Jose — Google Search`.
- Mail's window title is the message subject. Messages' is the person. Zoom's is the meeting topic.
  SPEC §4's ban on email contents and message contents is defeated by subject lines.
- It lands in `~/Library/Application Support/Lggr/` — unsandboxed, unencrypted, no container,
  `cat`-able by every process the user runs. Safari's history is behind Full Disk Access. Chrome's is a
  locked SQLite file. **A privacy-first app would be delivering a net reduction in the user's privacy
  posture.**

**The resolution — one line, and it is the strongest privacy claim in the plan:**

> **Lggr never writes a window title to disk. Not for 30 days, not for 24 hours, not once.**

Titles are read in one function, matched against grammars, reduced to typed `Evidence` (a repo slug, an
issue key, a category) and released. The type boundary from `intel-privacy-max` §2.3(a) enforces it:
no public API on `FocusedContextReader` returns a `String`, and `check-layering.sh` fails the build if
one is added or if `kAXTitleAttribute` appears outside that file. The `intel-invisible-work` extractor
shape is adopted (`Evidence` as a closed enum), minus its two free-text cases.

Three consequences accepted openly:

- `RuleMatchType.windowTitleContains` still exists, because **the user typed the match string
  themselves** — authored text is categorically different from captured text. But per
  `intel-privacy-max`'s own review (2.1), the *rule identity is never persisted per interval*: an
  interval stores `classificationSource: .titleRule` and no rule id, so the timeline cannot be joined
  back against the rules table to reconstruct "when was a document containing ACME frontmost."
- A **shipped default deny list** — Mail, Messages, Notes, 1Password, Keychain Access, Preview, Photos,
  Calendar, Contacts, FaceTime, Books — where titles are never read at all, gated *before* the AX call.
  Not merely user-configurable exclusions.
- Browser title reading is **separately opt-in from Accessibility**, per app, off by default. The
  browser is where the sensitive titles live.

### 3.4 Every live or headline number that behaves like a score — **removed**

Four separate proposals independently invented one, and three of the four reviews caught it. The
mechanism is what is banned, not the noun:

- **`intel-alignment`'s live "18m in this stretch"** in the running popover, justified in its own text
  as *"a thing you would rather not reset"* — which names loss aversion out loud. A visible, live,
  monotonically increasing number that resets on the behaviour you are trying to avoid is a score with
  a loss condition. **Removed from the popover.** The stretch is shown after the session ends, where it
  informs and cannot pressure.
- **`intel-reconstruction`'s "longest unbroken stretch 1h 25m"** in the daily recap footer. A daily
  maximum is a high score; it goes down on bad days. **Removed.** It appears in the weekly review as a
  distribution, never as a maximum.
- **`intel-privacy-max`'s fragmentation index, warm-up latency and switch-rate ratio.** Self-relative
  scores are still scores; "compared to your own median" is the standard framing of every gamified
  tracker on the market. Computed where they inform a boundary decision, **never rendered**.
- **`intel-invisible-work`'s "3 undeclared blocks" badge** and **`intel-privacy-max`'s "Not in a
  session today — 2h 51m"** total. Both are the number that grows when you fail to comply with the app.
  **The section ships without a count and without a total.** It is titled *Also today*, it lists the
  blocks, and unresolved blocks age out silently into neutral tracked time.

### 3.5 EventKit — **not requested, claim preserved**

`intel-zero-input` §2.9 and `intel-invisible-work` §4.4 both proposed it, both honestly, and
`intel-invisible-work`'s API surface analysis is the most accurate technical writing in the folder
(`requestFullAccessToEvents()`, the macOS 14 `.authorized`→`.fullAccess` rename,
`NSCalendarsFullAccessUsageDescription` being a *crash* rather than a denial, no entitlement while
unsandboxed). I am rejecting it anyway, on the grounds `intel-alignment` states best: **the promise is
worth more than the feature.**

There is no per-calendar TCC granularity. Full access is every event on every account — medical
appointments, personal calendars, other people's shared calendars — and app-side filtering is a promise
we keep, not a wall the OS enforces. In exchange for the reviewable emptiness of Lggr's TCC footprint
being a product claim, we lose meeting names and attendee identities. That is the right trade for the
first two years of this product.

Anyone who wants it later must ship it as a separate, off-by-default, clearly-labelled opt-in, amend
the never-requested list in the open, and rewrite the README's privacy claim in the same change.

### 3.6 Auto-generated accomplishments — **killed**

`intel-zero-input` §2.8 proposed `pullRequestOpened`, `incidentResolved` and `documentWritten` from
dwell thresholds. Its review is right that this is categorically worse than a wrong summary, and the
failure chain is short: mis-segmented block → wrong PR number → "Opened the receipt deduplication PR"
→ accepted without reading → exported to a manager. A blank summary costs twenty seconds of typing. A
fabricated accomplishment in a performance-review artifact costs credibility that cannot be recovered,
and **the user will not know it happened.**

It is also unmeasurable under the same document's own capture rule: a Chrome tab switch produces no
`NSWorkspace` activation, so "≥ 8 min active on that identifier" is computed over a title sampled once,
at t=0, and forty minutes across three pull requests is attributed to whichever one was open when the
user switched in.

**The law, which applies to every generated string in the product:**

> A summary may state **durations and application names** — facts Lggr observed. It may never assert an
> **outcome**: *opened*, *reviewed*, *resolved*, *wrote*, *shipped*. Tangible result stays
> human-authored, always.

Dwell proves attention. It never proves completion.

### 3.7 `Copy evidence for… ▸ a person` — **killed**

`intel-invisible-work` §5.5 names the risk correctly — *"the ledger is a document about other people
who never consented to it"* — and then §3.3 ships a menu command whose entire purpose is to generate
exactly that, per named individual, formatted for pasting into a 1:1. The only thing standing between
it and a performance-management artifact is a copy convention enforced in code review, and copy
conventions do not survive contact with a feature request for "just a bit more detail for the review
cycle."

Per-person *rows* inside the app, ordered by the user's own time, are defensible self-accounting. A
one-keystroke shareable file about a named subordinate is not. Cut, and the exported weekly review is
aggregate-only (`5h 12m supporting 4 engineers`) with names visible in-app only.

### 3.8 Findings that changed the design rather than killing a feature

| Finding | Resolution |
|---|---|
| **`NSWorkspace.screensDidLockNotification` does not exist** (verified twice) | Use `DistributedNotificationCenter` `com.apple.screenIsLocked` / `screenIsUnlocked`, documented in code as an undocumented-but-stable SPI with the risk stated, cross-checked against `CGSessionCopyCurrentDictionary()`'s `kCGSSessionOnConsoleKey`. Not silently, and not as `screensDidSleep` |
| **`AXObserver` registered from a Swift concurrency task never fires** — the cooperative pool has no `CFRunLoop`, so registration returns `kAXErrorSuccess` and silently does nothing | One dedicated `Thread` running `CFRunLoopRun()` for the process lifetime, owning all AX observation. Written down as the second named exception to `02-architecture.md`'s isolation model, alongside `BrowserDomainReader` |
| **AX reads on the main actor stall the UI** — synchronous mach IPC, 250 ms per activation against a beachballed app, in bursts | All AX reads on that dedicated thread, hopping back to the main actor with the result. `AXUIElementSetMessagingTimeout(0.25)` set **per element**, including on `AXUIElementCreateSystemWide()` |
| **`kAXTitleChangedNotification` fires on the *window* element, not the application element** | Two observers with re-registration on every focused-window change, and teardown on `didTerminateApplication`. Budgeted, not hand-waved |
| **Chromium/Electron accessibility mode is process-wide, sticky, and lands in *their* renderer, not ours** | Measured in the Phase 3 probe before any dependency on Electron titles. If Chrome gets slower after installing Lggr, that is our bug even though it will not show in our Energy Impact |
| **Idle is forgeable by any process** (verified: a single synthetic `mouseMoved` zeroes both `.combinedSessionState` and `.hidSystemState`) | Idle never defines an unbroken run. `idleConfidence: .high/.low`, cross-checked against `CGDisplayIsAsleep` and console state |
| **Idle backdating collides with sleep** — on wake, `secondsSinceLastEvent` includes the sleep duration, so `T − S` lands before `willSleep` fired | Clamp to `max(T − S, lastWakeAt)`; precedence written down and fixture-tested |
| **`.systemSleep` and `.appNotRunning` collide every single night** | Explicit precedence: a heartbeat gap that is fully covered by a sleep/wake pair is a sleep gap. The honesty mechanism must not mislabel the most common event in the corpus |
| **`willSleepNotification` is not delivered on power loss or panic** | The heartbeat is what closes the interval — at *last heartbeat*, never at launch time |
| **Power Nap delivers `didWake` with the lid shut** | Never reopen an interval on `didWake` alone; gate on display active or screen unlock |
| **Fast user switching manufactures activity** — `NSWorkspace` keeps reporting a background session's frontmost app and the other user's typing zeroes your idle timer | Hard capture stop between `sessionDidResignActiveNotification` and `sessionDidBecomeActiveNotification`. Absent from four of five proposals |
| **No timezone anywhere in the data model**; DST and travel corrupt every circadian claim and can render a 23-minute stretch as `1:52–1:15` | `tzOffsetMinutes` persisted per interval; hour buckets use the offset in effect at capture; **every duration computed from a monotonic source** (`ContinuousClock`), with `Date` for display only, and both carried so a disagreement can be detected and the interval dropped |
| **Cold start guarantees over-assignment** — with one project, `runnerUp = 0` and the 1.5× margin test passes trivially | Require a runner-up to exist, plus an absolute floor. No project inference at all until ≥ 4 labelled sessions exist |
| **The correction loop trains on its own output** | Only sessions where the user *changed* the pre-filled project, or created one cold, donate to a signature. Accepting a suggestion is worth strictly less than authoring one |
| **`didActivateApplication` never fires for the app already frontmost at launch** | Seed from `NSWorkspace.shared.frontmostApplication` |
| **`activeSpaceDidChangeNotification` is unused** in every proposal | Observed. Two Xcode windows on two Spaces are not one continuous run |
| **Ad-hoc signing invalidates every TCC grant on every build** — Lggr stays checked in System Settings while `AXIsProcessTrusted()` returns false | Stated in the docs, surfaced as a Settings diagnostic that detects "listed but not trusted" and offers `tccutil reset Accessibility`, and a Developer ID is obtained **before** any multi-day dogfood. Otherwise "we ask exactly once" is false for the only build configuration this project can produce, and the probe silently dies |
| **The kill criteria in all five proposals were incapable of returning "kill"** — N=1, unblinded, self-rated, by the author, over five days, on observations the author's own builder pre-selected | Rewritten in §4: blinded decoys, ≥150 scored blocks, two ground-truth diff days, a median-time-to-accept floor, and a run on at least one non-developer |
| **The whole title-parsing thesis is tuned for one persona** — Xcode, Terminal, GitHub, Linear — and SPEC names engineering managers *first* | Stated plainly. Phase 1 and 2 are persona-neutral by construction (they use no titles at all). Phase 3's probe reports coverage **by persona** and its kill criterion must be evaluated on a non-engineer's week |

---

## 4. The phases

Each phase is independently shippable and each leaves the tree green. `swift build` and `swift test`
pass at every commit; nothing in Phases 1–2 requires Xcode, a permission, or a macro.

### Phase 1 — The day you didn't log *(≈1 week)*

**What the user can newly do:** open Today at 4pm, having started no session all morning, and see the
morning — eight or ten named blocks with honest gaps between them. This is the phase that must be
noticeable on its own, and it is: the app goes from "empty unless you pressed start" to "there when you
forgot."

**APIs and permissions:** **none.**
`NSWorkspace.shared.notificationCenter` (`didActivateApplication`, `didLaunchApplication`,
`didTerminateApplication`, `willSleep`, `didWake`, `screensDidSleep`, `screensDidWake`,
`sessionDidResignActive`, `sessionDidBecomeActive`, `activeSpaceDidChange`);
`CGEventSource.secondsSinceLastEventType`; `DistributedNotificationCenter` for
`com.apple.screenIsLocked`; `CGSessionCopyCurrentDictionary` for console state; a 60 s heartbeat to its
own 40-byte file (**never** into `snapshot.json` — that would be 1,440 full-snapshot rewrites a day).

**What ships:**
- `LggrApp/Services/ActivitySampler.swift` — continuous from launch, not session-scoped. Ambient-first
  from the first line.
- `LggrApp/Services/IdleMonitor.swift` — one `DispatchSourceTimer`, 15 s, `leeway ≥ 3 s`, backing off
  to 60 s once already idle, suspended on lock and sleep. One timer, not two.
- `LggrKit/Domain/ActivityInterval.swift` — `(bundleIdentifier, displayName, start, end, isIdle,
  idleConfidence, tzOffsetMinutes)`. **No title field exists in the type.**
- `LggrKit/Domain/EpisodeBuilder.swift` — the five-stage pipeline with the evidence bag reduced to
  `{bundleID}` plus satellite groups (Xcode↔Terminal↔Simulator is one triad). Pure, no clock, no I/O.
- `LggrKit/Domain/ShapeOfWork.swift` — longest run by frontmost continuity, excursion/return pairs,
  alternation bigrams, interruption-source ranking. Single-pass, not O(n²).
- `LggrKit/Domain/DayTimeline.swift` — episodes plus typed gaps (`idle`, `displaySleep`, `systemSleep`,
  `locked`, `fastUserSwitched`, `appNotRunning`, `trackingPaused`, `excludedApplication`).
- The Today timeline strip, populated all day; the menu bar's tracking-state glyph and one-click
  **Pause tracking**; app exclusion and private-app lists in Settings.

**Acceptance criteria:**
1. Force-quit Lggr for 90 minutes; the timeline shows a `.appNotRunning` gap of exactly that span, not
   90 minutes in the last app.
2. Close the lid at 18:00, open at 09:00; one sleep gap. Not a fifteen-hour Xcode block. Not a
   `.appNotRunning` gap mislabelling a night the app slept normally.
3. Pull the power cord mid-session; on relaunch the open interval is closed at last heartbeat.
4. Fast-user-switch away for an hour; zero intervals recorded for that hour.
5. A real working day produces **≤ 14 blocks**, and the tester recognises ≥ 80% of them without
   explanation.
6. A synthetic day with a DST transition and a timezone change produces no negative durations and no
   overlapping blocks.
7. `swift test` covers each pipeline stage against three hand-built fixture days.
8. Lggr does not appear in Activity Monitor's "Apps Using Significant Energy" over an 8-hour battery
   day. This is a Phase 1 gate, not a Phase 6 nicety.

**Size:** ~1 week. Roughly 600 lines of new `LggrKit`, 300 of `LggrApp`, 40 tests.

---

### Phase 2 — Turn a block into a session *(≈4 days)*

**What the user can newly do:** press ⌘⏎ on a block and have it become a real session with the project
and duration filled in; and see a session review sheet that has evidence in it instead of a blank page.

**APIs and permissions:** none new.

**What ships:**
- The menu bar popover header reads `Untracked · Xcode, Terminal · 41m` with
  `[ Start a session on this ⌘⏎ ]`.
- `FocusSession.provenance: .declared | .reconstructed` and `RecordOrigin`. Reconstructed sessions are
  **`isReactive = true`**, are **excluded from the "focus sessions completed" count**, and render
  distinctly **forever**, not just on the day. Without this, reconstruction silently inflates planned
  time and corrupts the one analysis the product exists to produce.
- One undo: `Undo today's reconstruction`, transactional.
- The review sheet's evidence panel: session length, longest unbroken run, app breakdown with visit
  counts and median return time, context switches (kept — SPEC §6 requires it), one canonical
  switch definition shared by Today and the sheet.
- `SessionSummaryBuilder` gains its evidence parameter, defaulted, per its own doc comment.

**Acceptance criteria:**
1. A reconstructed session is visually distinguishable from a declared one in Today, in Focus Sessions,
   and in the weekly review, a month later.
2. Weekly "planned vs reactive" is unchanged by reconstruction — reconstruction adds reactive time only.
3. The generated summary contains no outcome verb. A test asserts the banned-verb list over the copy
   catalogue.
4. Three real days: the tester accepts ≥ 1 reconstructed block per day and rejects ≤ 1 per week.

**Size:** ~4 days.

---

### Phase 3 — The title probe *(2–3 days of work, then 3 weeks of waiting)*

This phase builds nothing a user sees. It exists because the dominant remaining risk is a
**measurement** question — do window titles actually carry work identifiers? — and every proposal in
this folder assumed an answer.

**APIs and permissions:** Accessibility, on the author's machine only, in a `LGGR_PROBE=1` build.

**What ships:** a probe that samples via `AXObserver` on `kAXFocusedWindowChanged` and
`kAXTitleChanged` (**not** activation-only — activation sampling under-counts distinct entities by
5–10× for a browser-heavy reviewer, which would kill a live hypothesis on bad instrumentation), and
writes, per sample: bundle id, title **length**, which grammar matched, which identifier tokens were
extracted, and a **redacted shape** (`"Aa · Pull Request #NNN · aa/aa"`). Raw titles only for bundle
ids explicitly allowlisted by the operator. File mode `0600` in a `0700` directory,
`NSURLIsExcludedFromBackupKey` set, refuses to append past day 15, overwrite-before-unlink.

**Kill criteria, pre-registered, and capable of returning "kill":**

| Result | Decision |
|---|---|
| < 50% of active-time minutes carry an identifier token | The ambitious version is dead. Lggr ships Tier-0 app-mix blocks permanently — a smaller and perfectly honest product |
| Identifier coverage is ≥ 50% for the developer week but < 30% for the non-developer week | Ship names for developers, say so in the docs, and narrow the claimed audience. Do not present a developer-only capability as universal |
| Chrome/Slack/VS Code show measurable renderer-process regression under sustained AX observation | Electron titles are out. Native apps only |
| ≥ 50% coverage across **both** personas, no Electron regression | Proceed to Phase 4 |

Run for **three weeks**, not five days, and on **at least one non-developer's** machine. A 4%
confabulation rate — two bad blocks a month, easily enough to destroy trust — is indistinguishable from
zero at n=50.

**Size:** 2–3 days of code. The waiting is the point.

---

### Phase 4 — Names *(≈2 weeks, gated on Phase 3)*

**What the user can newly do:** blocks are called `SOR-482 Deduplicate receipts` instead of
`Xcode, Terminal`, and get assigned to the right project without being told which one.

**APIs and permissions:** **Accessibility.** Asked once, in onboarding, with the honest statement that
macOS has no narrow Accessibility grant — `AXIsProcessTrusted()` authorises reading and controlling
every application and Lggr needs a thousandth of it. Browser title reading is a **separate** per-app
opt-in, default off.

**What ships:**
- `FocusedContextReader` — the only function in the codebase permitted to touch `kAXTitleAttribute`,
  with no `String` in its public signature, on the dedicated AX run-loop thread. Enforced by
  `check-layering.sh`.
- `TitleGrammar` as versioned **data** with fixtures, not a switch statement. Fail closed to nothing.
- `EvidenceExtractor` → the closed `Evidence` enum. Identifier tokens only; free-text document names
  and channel names do not ship.
- The shipped default deny list (§3.3), gated *before* the AX call.
- Project inference: naive Bayes over identifier tokens, ~80 lines, deterministic, snapshot-tested.
  Assigns only above an absolute floor **and** a margin over an existing runner-up, and not at all
  until ≥ 4 labelled sessions exist. Inferred assignments render with a dotted underline and one-click
  confirm; only *changed* or *cold* assignments train the signature.
- The correction loop: ghost text everywhere, correction-then-quiet-rule-offer, blast radius before
  consent, `SuppressedSuggestion`, `Remove and revert`, transactional ⌘Z.
- The `ⓘ` audit popover: the intervals, the matched **term** (always something the user typed), and why
  this project was chosen. Never the surrounding string.

**Acceptance criteria:**
1. `PrivacyCanaryTests` in CI: a synthetic run where every title is `CANARY-EE7F11` produces zero hits
   in `store.json`, in any log, in any error message, in any `Codable` type.
2. `check-layering.sh` fails on `kAXTitleAttribute` outside one file, on any `-> String` added to
   `FocusedContextReader`, and on `import Network`/`CFNetwork` anywhere.
3. AX reads never occur on the main actor; a fixture with a deliberately wedged target app does not
   stall the menu bar tick.
4. Over 150 scored blocks: **zero invented blocks.** Not "approximately zero."
5. Median time from proposal-shown to accept > 400 ms. Below that the user is reflex-accepting and the
   acceptance rate means nothing.
6. Two days of independent manual logging diffed against what Lggr proposed, yielding **precision**,
   not acceptance rate.

**Size:** ~2 weeks.

---

### Phase 5 — Friday *(≈1 week)*

**What the user can newly do:** open the app on Friday and read a neutral, evidence-backed account of
the week, and copy it as Markdown.

**APIs and permissions:** none new.

**What ships:**
- Weekly observations, deterministic, each pairing a timing fact with authored text:
  *"Your longest unbroken blocks started before 11:00 on four of five days."*
  *"Blocks containing Slack averaged 11 minutes; blocks without it averaged 34."*
  *"38% of tracked time was inside a browser. Lggr sees a browser as one application, so the switch
  count on this page does not include anything that happened between tabs."*
- The blind-spot line is not a footnote; it is a design commitment enforced in review.
- Markdown export: aggregate-only for anything involving other people, no out-of-hours phrasing, no
  untracked-time totals, no warm-up latency.
- Settings → Privacy → **Record**: counts computed over the user's own file at render time, the
  field-by-field table (`Window title — 0 of 6,412 — never stored`), the delete controls, and a button
  that scans the **real** store and reports real counts against the **actual** configuration.
- Every number links to the minutes behind it.

**Acceptance criteria:**
1. The tester pastes the weekly Markdown into a document without editing it. If they edit it first, the
   numbers are not yet trustworthy and the phase is not done.
2. A copy test asserts the banned-word list (*only, just, wasted, lost, failed, distracted, should,
   but, however, despite*) and the banned-verb list over every generated string.
3. No aggregate score of any kind appears anywhere, at any level of the UI or the export.

**Size:** ~1 week.

---

## 5. What we are not building, and why

An intelligence layer is exactly where a codebase drowns. `SPEC.md` principle 11 forbids
overengineering and principle 12 asks for the smallest polished slice. The following are all things at
least one proposal wanted, and all of them are out:

- **No model of any kind.** No on-device LLM, no embeddings, no z-scores, no entropy thresholds, no
  learned classifier with hyperparameters. Every decision in this plan is a rule with a constant, a
  test, and a sentence that explains it. `SPEC.md` §5 asks that a user be able to correct a
  classification and get a reusable rule out of it; `appSetEntropy < threshold` cannot be corrected.
- **No calendar, no microphone, no camera, no screen recording, no input monitoring, no full disk
  access, no network.** The reviewable emptiness of Lggr's TCC footprint is a product claim, and it is
  worth more than any feature on the other side of it.
- **No people graph in v1.** No `Person`, no `Workstream`, no alias merge queue, no per-person ledger,
  no per-person export. It is the most valuable idea in the folder for one persona and the most
  dangerous artifact in it for everyone.
- **No auto-generated accomplishments.** The log stays human-authored.
- **No second rule system.** One `Rule` with an enum outcome, one matcher, one history, one revert.
- **No knobs on the segmenter.** All weights live in one struct with documented defaults, tuned once
  against fixtures and frozen. A user who has to tune a segmenter has been handed our problem.
- **No gap-attribution triage queue.** Gaps are attributed automatically where possible (display asleep
  + >20 min ⇒ away, no buttons), and at most the single largest gap is ever asked about, once, in the
  weekly review.
- **No App Intents, no Shortcuts, no Spotlight integration** until Xcode exists to generate the
  metadata that makes them real.
- **No retroactive backfill.** Granting Accessibility in week three does not rewrite week one. Sealed
  days stay sealed, and the weekly review labels tier-mixed weeks rather than silently averaging them.
- **No SwiftData migration in this work.** The store split (activity intervals into
  `Activity/YYYY-MM.json`, loaded a month at a time) lands with Phase 1 rather than after the first
  10 MB snapshot makes cold start visible — but `snapshot.json` is untouched, so there is no migration
  for existing data.

---

## 6. Rules versus models — where the line is, and why

**A rule suffices, and a model is forbidden, for every one of these:** segmentation, boundary scoring,
episode absorption, naming, category classification, project inference, meeting detection, idle
evaluation, summary generation, weekly observations, and the drift judgment. Not one of them is a
pattern-recognition problem. They are all problems of *thresholds over a small number of observed
quantities*, and a rule beats a model on every axis that matters here: it is reproducible (a sealed day
must re-derive identically), it is snapshot-testable on a machine with no Xcode, it is auditable in the
`ⓘ` popover, and — the decisive one — **it is correctable into a reusable rule**, which `SPEC.md` §5
requires and a model cannot offer.

Naive Bayes over an identifier-token bag for project inference is the most statistical thing in the
plan, and it stays because it is eighty lines of pure Swift, fully deterministic, and its failure mode
is refusing to assign.

**On-device inference does not earn its place anywhere in this layer.** The gating fact is
`FoundationModels`, macOS 26+, plus Apple Silicon, plus Apple Intelligence enabled, plus a supported
region, plus a downloaded model — against a **macOS 14** deployment target. But version-gating is not
the argument that decides it. The argument that decides it is the one from `intel-privacy-max` §4.1:
*if the deterministic fallback is adequate, the model was unnecessary; if it is not, the app is broken
for most users.* `SessionSummaryBuilder` already exists and is already tested, and `SPEC.md` §7 offers
the app-mix name as its own worked example of a good label. There is no gap for a model to fill that
does not consist of raising the channel capacity of a component whose whole job is to reduce it.

If someone revisits this: the bar is a measured user complaint about rule-based names, plus Xcode
installed so `@Generable` compiles, plus a design that keeps the model off the critical path and out of
any sealed artifact. Nothing less.

---

## 7. The honest risk list

1. **Titles are worse than assumed — the biggest technical risk.** Slack sometimes reports just
   `Slack`. Electron AX trees are flaky and may refuse observer registration. A manager's day is Gmail,
   Docs, Calendar, Zoom and Slack, and of those only Slack has a grammar — and Slack's titles are the
   worst in the corpus. If this is true, Phase 4 never delivers and Lggr is a Tier-0 product forever.
   That is still a real product, which is why Phases 1–2 are built first and contain no titles at all.
   **Phase 3 exists solely to find this out in three weeks instead of a quarter.**

2. **The user says no to Accessibility.** Most users will. Everything through Phase 2 works without it,
   and the ask happens exactly once, in onboarding, with the honest statement about how broad the grant
   is. There is no permission banner in the review sheet, no *Enable* button after every session, and
   no recurring line in the weekly review. A permission button that appears after every session is a
   nag with a nice font.

3. **Ad-hoc signing makes "we ask once" false.** Every rebuild is a new app to TCC. Lggr stays checked
   in System Settings while `AXIsProcessTrusted()` returns false, with no user-visible explanation.
   This will break the probe and any multi-day dogfood. **Get a Developer ID before Phase 3**, or the
   measurement phase silently produces no data and we misdiagnose it as an AX bug.

4. **Confidently wrong blocks.** The killer failure is not messy output; it is a plausible block that
   did not happen. Mitigations are structural: visible confidence tiers, the `ⓘ` audit trail, refusing
   to assign below a margin, never auto-creating an accomplishment, hard gaps rendered as gaps rather
   than smeared into neighbours, and reconstructed sessions marked forever.

5. **Nobody looks.** A reconstruction with no destination is a log that rots. This is why Phase 2 —
   turning a block into a session, one keystroke — ships four days after Phase 1 rather than in a later
   quarter. Capture without a retrieval moment is not a feature.

6. **The browser blind spot is structural and flattering.** Chrome tab switches produce no `NSWorkspace`
   notification and there is no content-free tab-switch signal in the Accessibility API. Switch counts
   are systematically undercounted for browser-centric workers — the worst kind of error. There is no
   fix inside the permission budget. It is stated on every screen where the number appears.

7. **One frontmost app, one display.** Lggr cannot see the second monitor. A Zoom call on display 2
   while Xcode is focused on display 1 is logged as coding. Every category total inherits a systematic
   error for multi-monitor users, who are the target persona. Also unfixable; also stated.

8. **Reconstruction cannibalises the product it belongs to.** If the app reliably rebuilds your day,
   not starting a session becomes the cheaper path, and the session is the thing `SPEC.md` is actually
   about. The resolution is deliberate: sessions remain the **primary action** and the only thing that
   captures *intent*, which no reconstruction can infer; reconstruction is marked as reactive
   everywhere and is never counted as a focus session. If Phase 2's data shows declared sessions
   falling week over week, that is a signal to make the session cheaper, not the reconstruction richer.

9. **Manual entry goes up instead of down.** Every proposal in this folder added a decision queue while
   claiming to remove typing. A decision queue is data entry with the typing removed. The counts and
   totals are gone (§3.4), the gap triage is gone, the rule offers are suppressible forever, and every
   net-adding surface defaults to off. Watch this number: if a normal day contains more decisions after
   Phase 2 than before it, the phase failed regardless of what the timeline looks like.

**What would tell us early that the bet is wrong:**

- Phase 1's proof test: each morning for a week, write down from memory what you did yesterday, in
  blocks; then open Lggr and score (a) blocks it found that you had forgotten, and (b) blocks it
  invented. **If (a) is zero, memory is sufficient and this feature solves a problem the user does not
  have.** If (b) is non-zero at Tier 0, the segmenter is confabulating with nothing to blame but the
  algorithm — fix it before a single window title is ever read.
- Phase 2: if reconstructed blocks are accepted at under ~1/day, or if the tester is clicking through
  the triage panel to make it go away, the retrieval moment is wrong.
- Phase 3: the pre-registered coverage floor, on two personas.
- At any point: if a wrong block ever reaches an exported document, stop and re-derive the confidence
  floors before shipping anything else.

---

## 8. The first thing to build on Monday

**`EpisodeBuilder` and its fixture days, in `LggrKit`, with no capture and no UI.**

Not the sampler. The sampler is a morning's work and is not in doubt; the function that turns six
hundred activations into nine blocks is the entire engineering risk, and it can be written and proved
with no permissions, no Xcode, no running app, and no user.

**Create:**

```
Sources/LggrKit/Domain/ActivityInterval.swift
Sources/LggrKit/Domain/Episode.swift
Sources/LggrKit/Domain/Gap.swift
Sources/LggrKit/Domain/DayTimeline.swift
Sources/LggrKit/Domain/SegmentationWeights.swift
Sources/LggrKit/Domain/EpisodeBuilder.swift
Tests/LggrKitTests/EpisodeBuilderTests.swift
Tests/LggrKitTests/Fixtures/DayFixtures.swift
```

**`ActivityInterval`** is a `Sendable` value type: `bundleIdentifier`, `displayName`, `start: Date`,
`end: Date`, `monotonicDuration: TimeInterval`, `isIdle: Bool`, `idleConfidence: IdleConfidence`,
`tzOffsetMinutes: Int`. **There is no `windowTitle` field, and there will not be one** — Phase 4 adds
`derivedCategory` and `identifiers: [String]`, never a title. Durations come from
`monotonicDuration`; `start`/`end` are for display and bucketing only, so a clock step cannot inflate a
run.

**`EpisodeBuilder.build(intervals:sessions:weights:) -> DayTimeline`** is a pure static function. No
clock, no I/O, no actor, no `Date()` anywhere inside it. Five stages:

0. **Normalise.** Drop intervals < 2 s into the following neighbour. Merge adjacent same-bundle
   intervals. **Glance collapsing:** an activation < 8 s that returns to the immediately preceding
   bundle is not an interval — it increments `interjections` on the interval it interrupted.
1. **Evidence.** At this phase the bag is `{bundleIdentifier}` plus its satellite group. Ship three
   groups as data: `{Xcode, Terminal, Simulator, Instruments}`, `{Slack, Messages, Mail}`,
   `{Zoom, Teams, FaceTime}`.
2. **Boundary score.** Between interval *i* and *i+1*:
   `w_gap · gapScore + w_evidence · (1 − jaccard) + w_category · categoryDistance + w_session · sessionBoundary − w_satellite · satelliteBonus − w_return · returnWithin(120s)`.
   `sessionBoundary` is `.infinity`. Cut when the score exceeds θ. All constants in
   `SegmentationWeights`, none exposed in the UI.
3. **Absorb to a fixed point.** Any segment shorter than `minEpisodeDuration` (4 min) merges into
   whichever neighbour shares more evidence, unless bounded on both sides by hard gaps. Iterate; each
   pass strictly reduces the segment count so termination is guaranteed; cap at 10 passes anyway.
4. **Name.** Strict precedence, first match wins: (1) overlaps a session by ≥ 60% → the session's
   `intendedOutcome`, verbatim; (2) — reserved for Phase 4 identifiers; (3) dominant category; (4)
   the app roster by descending time, capped at three plus "+2 more". Set `labelConfidence` accordingly.

**Write four fixture days first, by hand, before the builder compiles.** Each is a literal
`[ActivityInterval]` with an asserted expected `DayTimeline`, and each is a design claim made
falsifiable:

- **`normalDeveloperDay`** — 380 intervals, tight Xcode↔Terminal alternation with a 22 s median, two
  Slack excursions, one lunch gap. Asserts: **9 ± 2 episodes**, the Xcode/Terminal alternation is one
  episode and not forty-six, the two Slack visits are `interjections` and not blocks.
- **`overnightSleepDay`** — intervals stop at 18:04, a `systemSleep` gap, resume at 09:12. Asserts: two
  days' worth of episodes, one sleep gap, **no fifteen-hour block**, and no `.appNotRunning` gap
  overlapping the sleep gap.
- **`crashedAppDay`** — a heartbeat that stops at 14:30 and an interval stream that resumes at 16:10.
  Asserts: a `.appNotRunning` gap of exactly 100 minutes, and the preceding episode closed at the last
  heartbeat, not at 16:10.
- **`fragmentedManagerDay`** — Chrome, Slack and Zoom only, 40 activations, no satellite structure.
  Asserts: **≤ 8 episodes** and that no episode is named anything more specific than its app roster.
  This is the persona-neutrality test, and it should be written by someone who is not a developer.

Then write the builder until the four fixtures pass. When they do, the riskiest thing in this document
is proved in code, on a laptop, in a day, and every phase above it is ordinary work.

**Do not write `ActivitySampler` until the fixtures pass.** If the builder cannot turn a fixture day
into blocks a human recognises, no amount of capture will save it — and finding that out costs one day
instead of one month.
