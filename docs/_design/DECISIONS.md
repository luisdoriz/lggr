# Decisions taken during implementation

Design decisions that were not settled by `DESIGN.md` and had to be made while building Phase 2.
Each one came out of a defect or a contradiction found in review, and each is enforced by a test.

---

## D1. Deletes are idempotent

**Decision.** Deleting an id that is not present succeeds and does nothing. No conformer of
`LggrStore` may throw `notFound` from a delete.

**Why it came up.** `InMemoryStore` threw `StoreError.notFound`; `JSONFileStore` removed silently.
Both behaviours were locked in by passing tests, and the fake is what every unit test runs against —
so the suite was green about semantics production did not have. UI written against the fake would
handle an error the real store never raises.

**Why this way.** The caller's intent is that the record should not exist, and after the call it does
not. A `notFound` carries nothing the caller can act on, and it turns two benign cases into visible
failures: deleting twice, and deleting from a list rendered before another change landed.

**Enforced by** `InMemoryStoreTests.deleteMissingRecordIsIdempotent`,
`repeatedDeleteIsIdempotent`, and the contract note on `LggrStore`.

---

## D2. Interval filtering is half-open

**Decision.** A record belongs to a window when `start <= timestamp < end`.

**Why it came up.** Both stores used `DateInterval.contains`, which is closed at both ends.

**Why this way.** `Calendar.dateInterval(of: .day, for:)` produces adjacent windows where one day's
`end` is exactly the next day's `start`. Under closed filtering a record stamped at midnight is
returned for *both* days, so a per-day breakdown of a week does not add up to the week total — and
the weekly review is the product. Midnight stops being an exotic value the moment an accomplishment
can be back-dated with a date picker, which defaults to exactly that.

**Enforced by** `InMemoryStoreTests.intervalFilteringIsHalfOpen` and `adjacentWindowsPartition`.

---

## D3. Ordering lives in one place

**Decision.** Both stores call `StoreOrdering`. Newest first, ties broken by `id`.

**Why it came up.** The fake broke ties by `id` and documented it; the file store did not break ties
at all and relied on `Swift.sort` leaving equal elements alone — which is not a documented guarantee,
so its tie order was not even stable run to run. The two backends returned different orders for the
same data, and `loadActiveSession` picked *different sessions* when two were unfinished at the same
instant.

**Enforced by** `JSONFileStoreDurabilityTests.bothStoresAgreeOnTieOrdering` and
`bothStoresAgreeOnActiveSession`, which assert the two backends agree rather than asserting each
separately — the only shape of test that can catch a divergence.

---

## D4. Dates are stored as seconds, not ISO-8601

**Decision.** `StoreSnapshot` encodes dates with `.deferredToDate`.

**Why it came up.** ISO-8601 truncates fractional seconds, so every save-and-reload cycle silently
rewrote the user's timestamps and changed recorded session lengths.

**Why this way.** Correctness over readability. Exact round-tripping is testable and load-bearing;
a human-readable timestamp in the JSON is a convenience. The cost is that `store.json` now holds
`806636433.802637` rather than `2026-07-25T01:38:54Z`. The file stays diffable and pretty-printed.

---

## D5. An unreadable file is preserved, and the user is told

**Decision.** Three distinct outcomes rather than one:

| On disk | Outcome |
|---|---|
| No file | Empty store, silently — a genuine first launch |
| Zero bytes | Moved aside, user told |
| Not JSON at all | Moved aside, user told |
| Valid JSON, value this build cannot interpret | **Refused**, file untouched, user told to update |
| Valid JSON, newer `schemaVersion` | **Refused**, file untouched, user told to update |

**Why it came up.** Three separate holes. A zero-length file read as "new user", so the next save
overwrote a truncated-but-recoverable file. One unknown enum raw value — the normal consequence of
running an older build after a newer one wrote a session — sent the *entire* document to quarantine.
And quarantine returned an ordinary empty snapshot, so nothing anywhere told the user their file had
been moved; they saw an empty app and concluded the data was gone.

**Why this way.** This writer cannot produce a zero-length file, so zero bytes always means
truncation. And well-formed JSON is intact data: refusing it leaves a file that re-updating recovers
completely, where quarantining would rename it out from under the user over one unknown string.
`JSONFileStore.quarantineNotice` carries the message to the UI.

**Enforced by** `JSONFileStoreDurabilityTests.emptyFileIsQuarantined`,
`unknownEnumValueRefusesRatherThanQuarantines`, `nonJSONIsQuarantined`.

**Consequence for versioning:** adding a case to any stored enum is additive for the writer but a
hard decode failure for every older reader, so it requires a `schemaVersion` bump.

---

## D6. A failed write rolls the in-memory document back

**Decision.** `mutate` restores the previous document if the write throws, unless a newer mutation
has already replaced it.

**Why it came up.** The store published the change to memory and *then* wrote. On a full disk the
user saw the project disappear from the UI, an error banner saying the delete failed, and the project
back again on next launch — three states that disagreed, with no way to tell which was true.

**Enforced by** `JSONFileStoreDurabilityTests.failedWriteRollsBack`.

---

## D7. Lazy loading re-checks after every suspension

**Decision.** `loaded()` loops, re-reading `snapshot` after each `await` rather than returning the
value the disk read produced.

**Why it came up.** Two saves overlapping the *first* load lost one of them, permanently. The second
caller received the document as it was on disk rather than as it had just become in memory, built its
mutation on that stale copy, and wrote it back. The app reaches this on ordinary launches: a global
shortcut starting a session while `bootstrap()` is still loading is exactly this interleaving.

**Enforced by** `JSONFileStoreDurabilityTests.concurrentFirstSavesBothSurvive` and
`manyConcurrentSavesSurvive`.

---

## D8. Writes are sequenced and flushed

**Decision.** Each mutation takes a sequence number; the writer drops any write that arrives out of
order. Every write is flushed with `F_FULLFSYNC`, and the containing directory is flushed after the
rename.

**Why it came up.** Two claims in the code that the code did not deliver. The file's own comment
promised ordered application, but overlapping callers exist — `togglePause` fires an unawaited
`Task` — and actor jobs are not guaranteed to run in enqueue order, so an older document could land
last. Separately, `Data.write(options: .atomic)` and `replaceItemAt` are renames: they return success
once the bytes reach the buffer cache, not the device.

**Why it matters here more than usual.** Lggr has no server copy. "We said it was saved" has to mean
it survives a power loss, not just a clean quit. Saves happen a handful of times an hour — on start,
pause and finish — so the cost of a full flush is irrelevant next to what it buys.
