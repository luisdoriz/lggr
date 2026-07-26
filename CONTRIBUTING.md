# Contributing

Thanks for taking a look.

## Getting set up

```bash
git clone https://github.com/luisdoriz/lggr.git
cd lggr
make check
```

`make check` runs the layering check, builds every target and runs the test suite. If that passes you
have a working setup. `make run` builds `Lggr.app` and launches it.

You do **not** need Xcode. Command Line Tools alone is enough for everything except the optional
SwiftData backend.

## Run the tests with `make test`, not `swift test`

On a machine without Xcode, `swift test` builds the test bundle, prints `Build complete!` and exits
**zero having run nothing** — SwiftPM cannot find `Testing.framework`, which Command Line Tools
installs outside the SDK. `Scripts/test.sh` passes the search path explicitly and then asserts that
tests actually ran and that the count has not dropped.

If you add tests, raise `MINIMUM_TESTS` in `Scripts/test.sh`. If a change legitimately removes tests,
lower it in the same commit so the reduction is visible in review.

## Where code goes

| Target | Contents | Rule |
|---|---|---|
| `LggrKit` | Domain types and all business logic | **Foundation only.** No SwiftUI, no AppKit, no SwiftData |
| `LggrApp` | Views, menu bar, capture services | No `@Model`, no `#Predicate`, no `#Preview` |
| `LggrPersistence` | SwiftData entities and adapter | Xcode only; excluded from the default build |

`make lint` enforces these mechanically, plus a ban on `try!` and `as!`. It is not advisory — a stray
`#Preview` breaks the build for every contributor without Xcode, which is why it is checked rather
than trusted.

Logic belongs in `LggrKit`, where it can be tested without a running app. If you find yourself
computing something in a view, that is the signal.

## Things that are deliberate, so please don't "fix" them

- **No window title is ever written to disk.** Not for a day, not for a minute. A browser's window
  title is a page title and a mail client's is a subject line, so storing them would mean writing a
  log of someone's reading and correspondence into an unencrypted file. Titles may be matched in
  memory against a string the *user* typed, then released.
- **Durations come from stored dates, never from a counted tick.** A dropped timer tick, a relaunch
  or a machine that slept must all produce the same number.
- **Activity intervals do not go in `store.json`.** That document is rewritten whole on every save.
  Intervals live in append-only per-day files.
- **A confidently wrong block is worse than no block.** Where the evidence does not support a claim,
  the app says nothing — an unassigned block, a gap marked as unexplained. Please keep it that way.
- **No scores, streaks, grades or leaderboards.** The app reports evidence; the user draws
  conclusions. This is a product decision, not an oversight.

`docs/_design/DECISIONS.md` records decisions that were made under pressure and the reasoning behind
them. Worth a look before changing storage or timing behaviour.

## Pull requests

- Keep `make check` green.
- One concern per PR.
- If a test exposes a real defect, fix the implementation rather than the assertion.
- Explain *why* in the commit message. What changed is visible in the diff; why it changed is not.

## Reporting a bug

Include your macOS version, whether you have Xcode installed, and the output of `make check`. If it
involves recorded activity, please **do not** paste your `store.json` — describe the shape of the
problem instead. It is your data and there is no reason for it to be in an issue.
