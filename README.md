# Lggr

[![CI](https://github.com/luisdoriz/lggr/actions/workflows/ci.yml/badge.svg)](https://github.com/luisdoriz/lggr/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)

A native macOS app for understanding the gap between what you meant to work on and what you actually
did. Focus sessions with an intended outcome, ambient activity tracking that rebuilds the day you
forgot to log, and a running record of what you actually produced.

Everything stays on your Mac. No account, no server, no network code.

## Requirements

macOS 14 or newer. To build: a Swift 6 toolchain — Xcode, or Command Line Tools on their own.

## Install

Download `Lggr.app.zip` from the [latest release](https://github.com/luisdoriz/lggr/releases/latest),
unzip it, and drag `Lggr.app` to `/Applications`.

**The first launch needs one extra step.** The app is signed ad-hoc rather than notarized — that
requires a paid Apple Developer account — so macOS will refuse to open it and may say it is
*damaged*. It is not; that is what Gatekeeper says about any unnotarized download. Clear the
quarantine flag once:

```bash
xattr -d com.apple.quarantine /Applications/Lggr.app
```

Then open it normally. If you would rather not run a command you were told to run by a README —
which is a reasonable instinct — build it from source instead; it takes about a minute.

## Build from source

```bash
git clone https://github.com/luisdoriz/lggr.git
cd lggr
make check   # lint, build, run the tests
make run     # build Lggr.app and launch it
```

`make help` lists the rest. No Xcode required.

## What it does

**Focus sessions.** Pick a project, write one line about what you intend to get done, choose 25 / 50
minutes / custom / open-ended, and start. The timer lives in the menu bar. Pause and resume are exact
— durations are computed from stored dates, not counted, so a dropped tick, a relaunch, or a machine
that slept for an hour all resolve to the same number.

**Ambient tracking, no permissions.** The app records which application is in front of you and turns
hundreds of switches into eight or ten readable blocks with honest gaps between them. Open it at 4pm
having started no session all morning and the morning is still there.

**Session review.** When a session ends: what happened (completed, made progress, blocked,
interrupted, reprioritized), an editable generated summary, and the tangible result.

**A done log.** Accomplishments, by type — PR opened, PR reviewed, person unblocked, decision made,
incident resolved. Exportable as Markdown, which is what you want on Friday.

**Weekly review.** Where the time went, planned versus reactive, context switches, and neutral
observations derived from the data. No scores, no streaks, no grades.

## Privacy

There is no network code and no network entitlement. Nothing is uploaded. All data lives in
`~/Library/Application Support/Lggr/`.

Tracking records the frontmost application's name and bundle identifier. It never records keystrokes,
passwords, screenshots, document contents, message contents, or the clipboard.

**No window title is ever written to disk.** Titles are the sensitive part — a browser's window title
is the page title, a mail client's is the subject line — so the app does not store them, for any
length of time. When title-based classification arrives, titles are read in one function, reduced to
a category, and released.

Applications can be excluded entirely or marked private. A private application still contributes its
duration, so the time is not lost from your day, but is stored with no name and no identifier —
redaction happens where the data is captured, not where it is displayed. Tracking can be paused from
the menu bar, history can be deleted, and a retention limit prunes old activity automatically.

The app is not sandboxed. Reading window titles through the Accessibility API is incompatible with
the App Sandbox and no entitlement lifts it, so sandboxing would reduce the app to
application-name-only tracking for no privacy gain. `Resources/Lggr.entitlements` documents the
reasoning and how to build a sandboxed variant.

## Layout

```
Sources/LggrKit/         domain types and all business logic — Foundation only, no UI
Sources/LggrApp/         SwiftUI app, views, menu bar, capture services
Sources/LggrPersistence/ optional SwiftData backend (needs Xcode)
Tests/                   swift-testing suites
Scripts/                 build, test, packaging, layering checks
docs/                    design notes
```

`LggrKit` holds the logic and depends on nothing but Foundation, so the parts worth testing are
tested without a running app. `make lint` enforces that boundary.

## Testing

Run tests with `make test`, not `swift test`.

On a machine without Xcode, `swift test` builds the bundle, prints `Build complete!`, and exits
**zero having run nothing** — SwiftPM cannot find `Testing.framework`, which Command Line Tools
installs outside the SDK. `Scripts/test.sh` passes the search path explicitly and then asserts that
tests actually ran and that the count has not dropped. A green exit code with no tests executed is
worse than a red one.

## SwiftData

`LggrPersistence` implements the same storage protocol on SwiftData and is off by default: the
`@Model` macro ships only inside Xcode, so it cannot be compiled by Command Line Tools. Build with
`LGGR_SWIFTDATA=1` under Xcode and the app picks it up through a single `#if canImport` — no view or
domain code changes. It has never been compiled here, so expect to fix errors the first time you open
it in Xcode. Without it, storage is a JSON document, which is what the app uses out of the box.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). It covers the setup, where code goes, and a short list of
things that are deliberate so you don't spend time "fixing" them.

Design notes live in [`docs/_design/`](docs/_design) — including `DECISIONS.md`, which records the
calls made under pressure and why, and `INTELLIGENCE.md`, the roadmap for the automatic tracking.

## Status

Honest state of things:

- **What works:** focus sessions, the menu bar timer, ambient activity capture, the day timeline,
  session review, projects, the accomplishment log, interruption capture and inbox, classification
  rules, the weekly review, and Markdown/CSV export. 617 tests.
- **Not verified:** that a real working day produces blocks you recognise, and that the app stays out
  of "Apps Using Significant Energy" over eight hours on battery. Both need a real day and a human;
  neither is claimed as done. See `docs/_design/PHASE1-ACCEPTANCE.md`.
- **Never compiled:** the optional SwiftData backend. No toolchain on the machine this was built on
  can type-check it, so its conformance is asserted, not verified.

## License

MIT — see [LICENSE](LICENSE).
