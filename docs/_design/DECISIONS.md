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

---

## D9. A file that changed underneath us is never overwritten

**Decision.** `JSONFileStore` records the store file's **modification date and size** when it reads
it, and re-checks both before every write. If they no longer match, the write is refused: the file on
disk is left byte-for-byte as whatever changed it left it, the document that was not written is
preserved beside it as `store-unwritten-<stamp>.json`, `externalChangeNotice` is set so the app can
tell the user, the in-memory document is dropped and re-read, and the mutation throws.

**Why it came up.** The store loaded once and treated its in-memory snapshot as authoritative
forever, writing the whole thing back on every save. Any change made by anything else was silently
erased by the next save. Two ordinary routes: two instances (the copy in `/Applications` plus a
development build — the second starts empty and its first write erases the history), and restoring a
backup while the app is open. Observed: a running instance overwrote a file that had been replaced
underneath it and re-seeded the default classification rules on top, believing itself to be on a
first launch.

**Why date *and* size.** Two writes inside one timestamp tick leave the date identical, so size
catches those; an edit that keeps the length leaves the size identical, so the date catches those.
Either alone has a blind spot. The file is stat'd *before* its bytes are read, never after: if it
changes between the two, the recorded identity then describes an older file than the bytes we hold
and the next write is refused — the safe direction.

**Why refuse rather than resolve.** Taking the disk copy discards records this instance already told
the user were saved. Keeping memory is the defect. Merging is worse than both: with whole-document
saves there is no way to distinguish "deleted over there" from "not there yet", so a union would
resurrect rows the user deleted and a per-collection pick would silently choose one edit over
another. Keeping *both* copies and writing neither is the only resolution that cannot destroy a
record the user believes is saved. Failing the mutation is the same contract as D6.

**The reload is generation-guarded.** Reloading re-arms the identity check, so a second save already
in flight from the pre-reload document would have sailed through it. Every document carries a
generation; a refusal raises the writer's floor above it, so everything descended from a refused
document is refused too.

**Enforced by** `StoreFileGuardTests` — `changeBetweenLoadAndWriteIsRefused`,
`sameSecondDifferentSizeIsAChange`, `sameSizeLaterDateIsAChange`, `shorterReplacementIsRefused`,
`deletedFileIsRefused`, `refusedDocumentIsPreserved`, `refusalReloadsFromDisk`,
`saveAfterRefusalSucceeds`.

---

## D10. One dated backup per day, keeping seven, and an empty store never displaces a full one

**Decision.** Before its first write, each launch copies the document it found into
`LggrStoreLocation.baseDirectory()/backups` as `store-<yyyyMMdd>.json`, keeping seven. A backup of an
empty document is refused while any backup with content exists, and rotation sheds empty backups
before it touches one with content.

**Why it came up.** Atomic writes make a *failed* write survivable and say nothing about one that
succeeds and is wrong. Nothing in the app covered a bad write, a second instance, or a delete the
user did not mean.

**Why one per day and seven.** A copy per launch is the obvious design and the wrong one: a menu bar
app is relaunched several times a day, so seven per-launch copies can cover an afternoon — and a bad
write followed by two relaunches would rotate every good copy out within the hour. Seven daily copies
cover a week, which is long enough that "my Tuesday sessions are gone", noticed on Friday, is still
recoverable, and small enough to be seven files of a few kilobytes. The daily stamp also does the
rotation: a second launch the same day finds the day's copy already there and leaves it, which is
correct rather than a shortcut — that copy predates whatever went wrong today.

**Why the empty-store rule.** The fault these backups exist for *produces an empty store*. If an
empty document could take a slot, the first launch after the fault would rotate out the one copy that
could have saved the user — the remedy destroyed by the fault it is the remedy for.

**Enforced by** `StoreBackupsTests.emptyStoreDoesNotDisplaceContent`,
`emptyStoreDoesNotDisplaceTheLastFullBackup`, `zeroLengthStoreDoesNotDisplaceContent`,
`rotationPrefersToDeleteEmptyBackups`, `rotationKeepsTheMostRecent`,
`launchBackupPrecedesTheFirstWrite`.

---

## D11. A second launch activates the running instance instead of opening a second window

**Decision.** `SingleInstanceGuard` takes a `flock` on `instance.lock` in the store folder before any
scene is built. If another process holds it, the running instance is brought to the front and this
one exits. If the lock cannot be used at all, the app launches anyway.

**Why a `flock` and not a pid file or a lock directory.** The lock lives on an open file descriptor,
and the kernel closes every descriptor a process owns when it dies — clean quit, crash, `SIGKILL`,
force-quit. **There is no such thing as a stale lock:** the file may be left behind, the lock on it
is not, and the next launch acquires it immediately. Verified by hard-killing an instance and
relaunching. A lock meaning "this file exists" or "this pid is written down" needs liveness checks
and a recovery path, and locks the user out of their own app the first time one of them is wrong. The
pid in the file is only a hint for finding the window to activate, verified through
`NSRunningApplication` before it is used.

**Why the store folder, not the bundle identifier.** The protected resource is the data folder. A
development build and the shipped copy share a folder and a bundle identifier, so keying on the
folder excludes them from each other — while `Scripts/smoke.sh`, whose `LGGR_STORE_DIR` points at a
throwaway directory, gets its own lock and can run while the real Lggr is open.

**Why a lock failure never blocks launch.** `EWOULDBLOCK` is the only answer that means "somebody
else has it". Anything else means a filesystem that does not support locking, and reading that as
another instance would refuse to launch Lggr for good. D9 is what guarantees the data survives; this
guard only spares the user the situation.
