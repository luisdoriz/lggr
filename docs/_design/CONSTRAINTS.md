# Hard environment constraints (empirically verified — non-negotiable)

Every design and implementation decision must live inside these facts. They were verified by
running the actual compiler on this machine, not assumed.

## Machine

- macOS 26.2 (build 25C56), Apple Silicon (arm64)
- Swift 6.2.1 (swiftlang-6.2.1.4.8), default target `arm64-apple-macosx26.0`
- macOS SDK 26.1 at `/Library/Developer/CommandLineTools/SDKs/MacOSX26.1.sdk`
- **Xcode is NOT installed.** Only Command Line Tools at `/Library/Developer/CommandLineTools`.
  `xcodebuild` does not exist. `xcrun --show-sdk-path` resolves to the CLT SDK.
- Deployment target for this project: **macOS 14**.

## What compiles today (verified by building a real SPM package)

- SwiftUI: `App`, `Scene`, `WindowGroup`, `MenuBarExtra`, `.menuBarExtraStyle(.window)`,
  `Settings`, `.windowStyle(.hiddenTitleBar)`, custom `EnvironmentKey`, `.keyboardShortcut`
- `@Observable` / `@Bindable` — `libObservationMacros.dylib` IS present in the CLT toolchain
- AppKit (`NSWorkspace`, `NSApplication`, …), UserNotifications, ServiceManagement, Charts
- swift-testing (`libTestingMacros.dylib` present) and XCTest
- SwiftPM: `swift build`, `swift test`, `.executableTarget`, `.target`, `.testTarget`
- `.app` bundle assembly by hand + `codesign --sign -` (ad-hoc) — verified working

## What CANNOT compile on this machine

`libSwiftDataMacros.dylib` and `libSwiftUIMacros.dylib` ship **only inside Xcode**, not with
Command Line Tools. The CLT plugin directory contains only `libObservationMacros.dylib`,
`libSwiftMacros.dylib` and `testing/libTestingMacros.dylib`.

Therefore these produce a hard compile error here:

- `@Model`, `@Relationship`, `@Attribute` (SwiftData macros)
- `#Predicate`
- `#Preview`

Exact error observed:

```
error: external macro implementation type 'SwiftDataMacros.PersistentModelMacro' could not be
found for macro 'Model()'; plugin for module 'SwiftDataMacros' not found
```

Note: the `SwiftData` *framework* itself is present in the SDK and `import SwiftData` is fine.
Only the macros are unavailable.

## Resolution (already decided — build within it, do not relitigate)

A three-target split that keeps the maximum amount of code compiled and tested **today**, while
still delivering the SwiftData model layer the spec requires.

### `LggrKit` — pure domain library

Value types, enums, and **all** business logic: timer/pause arithmetic, activity aggregation,
context-switch counting, planned-vs-reactive computation, classification rule matching, private
application redaction, session summary generation, weekly insight generation, Markdown/CSV export.
Also owns the repository/service **protocols** and the fixtures used by previews and tests.

No SwiftData. No `#Preview`. **Compiles and is unit-tested today via `swift test`.**

### `LggrApp` — SwiftUI application

All views, the menu bar experience, AppKit integration, keyboard handling. Views bind to
`@Observable` stores that sit behind the repository protocols from `LggrKit` — never directly to
persistence classes. No `@Model`, no `#Preview`.

**Compiles and runs today.** Shipped as a real `Lggr.app` bundle assembled by
`Scripts/make-app.sh` (Info.plist + entitlements + ad-hoc codesign).

### `LggrPersistence` — SwiftData adapter (Xcode-only)

The SwiftData `@Model` entities exactly as the spec requires, plus a `SwiftDataStore` that
conforms to `LggrKit`'s repository protocols and maps between `@Model` classes and domain value
types. This is a thin mapping layer, deliberately small.

It is conditionally added in `Package.swift` when the environment variable `LGGR_SWIFTDATA=1` is
set, and wired into the app through `#if canImport(LggrPersistence)`. With Command Line Tools it
is simply not built, so `swift build` stays green. With Xcode installed it compiles and becomes
the persistence backend with zero changes to views or domain logic.

### Default persistence that runs today

`LggrKit` ships a durable, dependency-free `JSONFileStore` implementing the same repository
protocols (atomic writes to `~/Library/Application Support/Lggr/`). This is what the app uses out
of the box, so the vertical slice genuinely persists across launches on this machine.

### Previews

`#Preview` cannot compile, so preview data lives in `LggrKit`'s `PreviewFixtures` and every view
takes injectable state. A documented Xcode-only file `Previews.swift` (excluded from the SPM
target) carries the real `#Preview` macros for when Xcode is available. Light/dark verification is
done through a dev-only gallery window driven by `.preferredColorScheme`.

## Rules for all agents

1. Never write `@Model`, `#Predicate`, or `#Preview` into a file that is part of `LggrKit` or
   `LggrApp`. Those macros belong exclusively in `Sources/LggrPersistence/` or the excluded
   `Previews.swift`.
2. `swift build` and `swift test` must stay green at every step. If you cannot compile it, do not
   claim it works.
3. No third-party dependencies. Apple frameworks only.
4. Avoid force unwraps (`!`) and `try!`. Handle errors explicitly.
5. Keep files small and focused; one primary type per file where practical.
6. Swift language mode: v5 for pragmatism with AppKit/timer code, `@MainActor` discipline on UI and
   service types. Domain value types must be `Sendable`.
