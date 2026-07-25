# Lggr — Permissions, Privacy and Data Lifecycle

> Deliverable 6 of the Phase 1 design set. Binding inputs, read in full before this document was
> written: `CONSTRAINTS.md`, `SPEC.md`, `02-architecture.md`, `03-data-model.md`. Type names, field
> names and folder paths below are taken from those files verbatim. Where this document proposes an
> addition or spots a contradiction between them, it is recorded in **§ 12 Open questions** rather
> than applied silently.

---

## 0. The stance in one paragraph

Lggr ships **unsandboxed**, signed with the **hardened runtime**, distributed outside the Mac App
Store. It requests exactly three system authorisations, all optional, all separately deniable:
**Accessibility** (window titles), **Automation** (browser domain, per browser), and
**Notifications**. It uses `SMAppService` for launch-at-login, which is a user setting rather than a
permission. It requests **nothing else** — no Screen Recording, no Input Monitoring, no Full Disk
Access, no network entitlement, no calendar or contacts. With every permission denied Lggr is still a
complete Toggl-plus-Pomodoro-plus-accomplishment-log with automatic per-application time tracking;
permissions only add resolution to a picture that is already useful. Data lives in one readable
directory in the user's home folder, activity capture is redacted **before it is read**, not before
it is displayed, and every destructive action offers an export first.

---

## 1. Permission and entitlement inventory

### 1.1 Accessibility — window titles

| | |
|---|---|
| **Why** | SPEC § 4 lists *window title when permission is available*. The title is the difference between "Xcode, 42 minutes" and "receipt deduplication, 42 minutes". It is what makes `SessionSummaryBuilder` produce the spec's example sentence and what makes `RuleMatchType.windowTitleContains` rules possible. |
| **Framework** | `import ApplicationServices` |
| **Status check (never prompts)** | `AXIsProcessTrusted() -> Bool` |
| **Request (prompts)** | `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)` |
| **Read** | `AXUIElementCreateApplication(pid)` → `AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window)` → `AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)` |
| **Info.plist key** | **None.** See the note below. |
| **Entitlement** | **None.** Incompatible with `com.apple.security.app-sandbox` — see § 2. |
| **User-visible prompt** | System-owned, not customisable: *“Lggr” would like to control this computer using accessibility features.* / *Grant access to this application in Privacy & Security settings, located in System Settings.* Buttons: **Open System Settings** · **Deny**. |
| **Grant location** | System Settings → Privacy & Security → Accessibility |
| **Without it** | `ActivityEvent.windowTitle` is always `nil`. Title-based classification rules never match. Session summaries name applications but not work items. Nothing else changes — application name, bundle identifier, timings, idle detection, context switches and every screen keep working. |
| **File** | `Sources/LggrApp/Services/WindowTitleReader.swift` [P3] |

Four properties of this API that the implementation must respect:

1. **There is no `NSAccessibilityUsageDescription` on macOS.** It is not a TCC usage-string
   permission; adding the key changes nothing about the prompt. `02-architecture.md` § 7.4 says the
   key must not be present. `Resources/Info.plist` currently *does* contain it — see § 12.
2. **The prompt appears at most once per code identity.** After the user dismisses it, further calls
   to `AXIsProcessTrustedWithOptions(prompt: true)` return `false` silently and show nothing. The
   API cannot nag even if we misused it, but it also means the UI must switch from "Enable" to
   **Open System Settings** once `didRequestAccessibilityPrompt` is set.
3. **Trust is revocable while the app runs.** Poll `AXIsProcessTrusted()` (cheap, no prompt) on
   `NSApplication.didBecomeActiveNotification` and once per activity-capture cycle. Never cache the
   answer for the lifetime of the process.
4. **Trust is keyed to the code signature.** `Scripts/make-app.sh` signs ad hoc (`--sign -`), whose
   cdhash changes on every rebuild, so macOS forgets the grant each time. Per
   `02-architecture.md` § 7.7, create a self-signed *Code Signing* certificate in the login keychain
   (Keychain Access → Certificate Assistant), name it `Lggr Dev`, and build with
   `LGGR_SIGN_IDENTITY="Lggr Dev"`. The current `make-app.sh` comment claims ad-hoc signing gives a
   stable identity; it does not — see § 12.

### 1.2 Automation / Apple Events — browser domain

| | |
|---|---|
| **Why** | SPEC § 4: *browser domain when technically and securely possible*; SPEC § 5 wants `GitHub → Code review`, `YouTube → Distraction`. Without a domain, all browser time is one undifferentiated block. Window titles do **not** contain the URL in any major browser, so Apple Events is the only path. |
| **Frameworks** | `import Foundation` (`NSAppleScript`, `NSAppleEventDescriptor`), `import AppKit` |
| **Status check (never prompts)** | `AEDeterminePermissionToAutomateTarget(&targetDesc, typeWildCard, typeWildCard, false)` → `noErr` = granted, `errAEEventNotPermitted` (−1743) = denied, `errAEEventWouldRequireUserConsent` (−1744) = not determined, `procNotFound` (−600) = browser not running |
| **Request (prompts)** | the same call with `askUserIfNeeded: true`, or simply executing the first `NSAppleScript` against that target |
| **Info.plist key** | **`NSAppleEventsUsageDescription`** (required) |
| **Entitlement** | **`com.apple.security.automation.apple-events`** = `true` (required because `make-app.sh` signs with `--options runtime`) |
| **User-visible prompt** | *“Lggr” wants access to control “Safari”. Allowing control will provide access to documents and data in “Safari”, and to perform actions within that app.* — followed by our `NSAppleEventsUsageDescription` string. Buttons: **Don't Allow** · **OK**. |
| **Grant location** | System Settings → Privacy & Security → Automation → Lggr → *(per target app)* |
| **Without the Info.plist key** | **The process is killed** by TCC on the first Apple Event with *“This app has crashed because it attempted to access privacy-sensitive data without a usage description.”* This is a hard crash, not a denial. |
| **Without the entitlement** (hardened runtime on) | Every Apple Event fails with `errAEEventNotPermitted`; no prompt is ever shown. |
| **Without user consent** | `ActivityEvent.domain` is `nil`. `RuleMatchType.domain` rules never match. Browser time is attributed to the browser application only. Everything else is unaffected. |
| **File** | `Sources/LggrApp/Services/BrowserDomainReader.swift` [P3] |

Consent is granted **per (Lggr, target browser) pair**. Safari and Google Chrome are two separate
prompts, tracked separately in `UserPreferences.browserAutomation` (see § 12).

Scripts used, and nothing else:

```applescript
-- Safari
tell application "Safari" to return URL of front document

-- Chromium family (Google Chrome, Brave Browser, Microsoft Edge, Arc, Chromium)
tell application "Google Chrome"
    if (mode of front window) is "incognito" then return ""
    return URL of active tab of front window
end tell
```

- **Firefox exposes no scriptable URL.** It is never queried; browser time in Firefox stays
  application-level. Documented, not worked around.
- **Chromium private windows are detected and skipped** via `mode of front window`. Safari and
  Firefox offer no equivalent property — Lggr cannot detect their private windows, and says so in
  the privacy statement (§ 10) rather than implying protection it does not have.
- **The full URL is never stored and never leaves the reader.** The returned string is passed
  immediately to a pure `LggrKit` function and only its host survives:

  ```swift
  // Sources/LggrKit/Domain/DomainExtractor.swift  [P3]
  public struct DomainExtractor: Sendable {
      /// Returns the lowercased host with a leading "www." removed.
      /// Path, query, fragment, port, username and password are discarded and never returned.
      /// Returns nil for non-http(s) schemes, for `about:`/`chrome:`/`file:` URLs, and for
      /// anything that does not parse.
      public static func host(from urlString: String) -> String?
  }
  ```
  Unit-tested in `Tests/LggrKitTests/DomainExtractorTests.swift`: query strings, credentials in the
  authority, IDN hosts, `file://`, `about:blank`, `chrome://newtab`, and the empty string.
- **Rate limit.** The browser is queried at most once per app activation, plus once every 15 seconds
  while it stays frontmost. Never when tracking is paused, never for a private or excluded browser,
  never when `trackBrowserDomains` is off.
- **Concurrency.** `NSAppleScript.executeAndReturnError` is synchronous IPC that can block for
  seconds if the target is busy or a consent sheet is up. `BrowserDomainReader` is therefore
  declared `actor`, not `@MainActor` — the single documented exception to
  `02-architecture.md` § 6.1's "the entire `LggrApp` target is `@MainActor`". It owns one cached
  compiled `NSAppleScript` per browser, serialises calls, and returns a `Sendable String?`. See § 12.

### 1.3 Notifications

| | |
|---|---|
| **Why** | SPEC § Notifications: session completed, optional halfway reminder, long idle period. |
| **Framework** | `import UserNotifications` |
| **Status check** | `await UNUserNotificationCenter.current().notificationSettings().authorizationStatus` → `.notDetermined` / `.denied` / `.authorized` / `.provisional` |
| **Request** | `try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])` |
| **Info.plist key** | **None.** |
| **Entitlement** | **None.** Sandbox-compatible. |
| **User-visible prompt** | *“Lggr” Would Like to Send You Notifications. Notifications may include alerts, sounds and icon badges. These can be configured in Settings.* Buttons: **Don't Allow** · **Allow**. |
| **Grant location** | System Settings → Notifications → Lggr |
| **Without it** | The three notification kinds are silently skipped. The menu bar icon still changes to `SessionState.awaitingReview`'s `questionmark.circle` when a planned duration elapses, and the review sheet is presented the next time the popover or main window is opened. No work is lost. |
| **File** | `Sources/LggrApp/Services/NotificationService.swift` [P6] |

Notes:

- `UNUserNotificationCenter.current()` **traps if the process is not a bundled application with a
  bundle identifier.** This is one of the reasons `02-architecture.md` § 7.3 forbids launching
  `.build/debug/LggrApp` directly. Always run `build/Lggr.app`.
- `.badge` is not requested. Lggr never badges its Dock icon; SPEC § Design direction rules out
  anything that nags.
- **`.provisional` was considered and rejected.** Provisional authorisation delivers without a
  prompt, but only quietly into Notification Center. A "your 50 minutes are up" alert that never
  appears on screen is worse than no alert at all, and the silent grant is a worse consent story
  than one honest question asked once.
- Only three of SPEC's four notification kinds exist in the MVP, matching the three toggles in
  `UserPreferences`. *Planned session start* requires scheduled sessions, which are not in the data
  model.

### 1.4 Launch at login

| | |
|---|---|
| **Why** | `UserPreferences.launchAtLogin`. A menu-bar timer that is not running has not tracked anything. |
| **Framework** | `import ServiceManagement` |
| **API** | `SMAppService.mainApp.status`, `try SMAppService.mainApp.register()`, `try SMAppService.mainApp.unregister()` |
| **Info.plist key** | **None** for the `mainApp` variant. (`BundleProgram` / `SMAppService.agent(plistName:)` are for helper executables; Lggr has none.) |
| **Entitlement** | **None.** |
| **User-visible prompt** | No prompt. macOS posts a system notification *“Lggr” was added. This item was added and can run in the background.* and the row appears in System Settings → General → Login Items. |
| **Statuses to handle** | `.enabled`, `.notRegistered`, `.requiresApproval` (the user disabled it in System Settings — show *Enable in System Settings* and call `SMAppService.openSystemSettingsLoginItems()`), `.notFound` |
| **Without it** | Nothing breaks; the user launches Lggr themselves. |
| **File** | `Sources/LggrApp/Services/LaunchAtLoginService.swift` [P6] |

`register()` throws (commonly when the app is not signed, or is running from a quarantined or
temporary location). Per `CONSTRAINTS.md` rule 4 the error is handled explicitly: the toggle reverts
and an inline caption appears — *Couldn't add Lggr to your login items. Move Lggr to your
Applications folder and try again.* Registering from `build/Lggr.app` inside the repository works but
breaks the moment the folder moves; the caption is not hypothetical.

### 1.5 Global hot key — deliberately permission-free

`GlobalShortcutService` [P6] uses Carbon `RegisterEventHotKey` / `InstallEventHandler`. This is the
only system-wide hot key API that requires **no** authorisation.

The alternative, `NSEvent.addGlobalMonitorForEvents(matching:handler:)`, silently delivers nothing
unless the app is an Accessibility client. Using it would make ⌘⇧Space depend on Accessibility, which
would quietly turn an optional permission into a required one and destroy the permission ladder in
§ 3. This is the entire justification for the one Carbon file in the codebase
(`02-architecture.md` § 8).

### 1.6 What Lggr never requests, and why that is a design decision

| Not requested | Would give us | Why we refuse |
|---|---|---|
| **Screen Recording** | Window titles via `CGWindowListCopyWindowInfo(_, kCGWindowName)` — a *working alternative* to Accessibility | It also grants pixel access to every window on the display. Asking for the ability to see the screen in order to read a string is disproportionate, and the prompt reads as surveillance. We take the narrower permission even though it is the harder one to explain. |
| **Input Monitoring** | `CGEvent.tapCreate` — keystroke and mouse event contents | SPEC § 4 explicitly forbids capturing keystrokes. Idle detection uses `CGEventSource.secondsSinceLastEventType`, which returns *how long since* an event, never the event, and needs no permission. |
| **Full Disk Access** | Reading other apps' data | No feature needs it. |
| **Network client / server** | Anything remote | SPEC principle 9 and 10. Both keys are present in `Lggr.entitlements` and explicitly `false`, so the absence of networking is a reviewable property of the build rather than a claim. Verify with `otool -L build/Lggr.app/Contents/MacOS/LggrApp`. |
| **Calendar, Contacts, Reminders, Photos, Microphone, Camera, Location** | — | No feature needs any of them. Lggr should never appear in those panes of System Settings. |

### 1.7 Consolidated Info.plist and entitlement table

`Resources/Info.plist`:

| Key | Value | Consequence if missing |
|---|---|---|
| `CFBundleIdentifier` | `com.luisdoriz.lggr` | No TCC identity; no permission can be granted or remembered. **Changing this after a grant loses every permission.** |
| `CFBundleExecutable` | `LggrApp` | Bundle does not launch. |
| `LSMinimumSystemVersion` | `14.0` | — |
| `LSUIElement` | `false` | See `02-architecture.md` § 7.6. |
| `NSAppleEventsUsageDescription` | *"Lggr asks your browser for the domain of the active tab so that web activity can be grouped by site. Only the domain is stored, never the full URL or page contents."* | **Process killed** on the first Apple Event. |
| `NSSupportsSuddenTermination` | `false` | macOS may kill the app mid-write and lose unflushed activity. **Currently absent — see § 12.** |
| `NSSupportsAutomaticTermination` | `false` | A running timer could be terminated. **Currently absent — see § 12.** |
| `NSHumanReadableCopyright` | *"Lggr. All data stays on this Mac."* | — |
| ~~`NSAccessibilityUsageDescription`~~ | — | Not a macOS TCC key. Has no effect. **Currently present — see § 12.** |

`Resources/Lggr.entitlements`:

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `false` | § 2. |
| `com.apple.security.automation.apple-events` | `true` | Required under the hardened runtime (`--options runtime`) for § 1.2. |
| `com.apple.security.network.client` | `false` | Declared false on purpose, as evidence. |
| `com.apple.security.network.server` | `false` | Same. |

Verify what actually shipped: `codesign -d --entitlements - build/Lggr.app`.

---

## 2. App Sandbox — the recommendation

**Recommendation: ship Lggr unsandboxed, with the hardened runtime, Developer ID signed and
notarised, distributed outside the Mac App Store.**

This confirms `02-architecture.md` § 7.7 and the reasoning already written into
`Resources/Lggr.entitlements`. The argument, stated once, in full:

**What is sandbox-safe.** `NSWorkspace.frontmostApplication` and
`didActivateApplicationNotification`; `CGEventSource.secondsSinceLastEventType`;
`UNUserNotificationCenter`; `SMAppService.mainApp`; Carbon `RegisterEventHotKey`; all file I/O inside
the container; `NSSavePanel` export with `com.apple.security.files.user-selected.read-write`. That is
the whole of Tier 0 in § 3 plus notifications and launch-at-login.

**What is not.** Reading the focused-window title of *another* process requires
`AXUIElementCreateApplication(pid)` against a target outside our container. Apple's position is that
applications which inspect or control other applications are not sandboxable; the calls fail with
`kAXErrorAPIDisabled` / `kAXErrorCannotComplete` even when `AXIsProcessTrusted()` returns `true`.
Apple Events under the sandbox require a
`com.apple.security.temporary-exception.apple-events` array naming each target bundle identifier —
a Mac App Store review flag, brittle across browser releases, and impossible to extend to a browser
we did not enumerate at build time.

**Why not sandbox and simply drop those two features.** Because they are the product. SPEC's own
example of a good summary is *"Worked primarily in Xcode and Terminal on receipt deduplication.
Reviewed one GitHub pull request"* — the work item comes from a window title and the *GitHub* comes
from a domain. Without them Lggr answers "which applications did I have open" instead of "what did I
work on", and SPEC's promise that the user can *"open the app on Friday and immediately see evidence
of what they delivered"* does not survive. SPEC says *"sandboxed where practical"*. With title
capture in scope, it is not practical.

**What we owe the user in exchange for the missing sandbox badge.** Five things, each verifiable:

1. **No network code at all.** No networking framework is linked and no request is made. Provable
   with `otool -L`, declared `false` in the entitlements, and stated in the README.
2. **A readable, documented, deletable storage location** (§ 4). No hidden database, no keychain
   items, no `/Library` writes, no launch agent, no helper process, no XPC service.
3. **Both high-risk captures are opt-in and independently switchable**, and neither is even
   *attempted* without both permission and preference (§ 6).
4. **A full degradation path** (§ 3) that leaves a genuinely useful app when everything is denied.
5. **Hardened runtime, Developer ID signature and notarisation** for any distributed build. For a
   non-App-Store utility that is the real trust signal, and it is what Gatekeeper actually checks.

**The sandboxed build is kept buildable, not shipped.** Flipping
`com.apple.security.app-sandbox` to `true` and adding
`com.apple.security.files.user-selected.read-write` produces a build that is exactly **Tier 0 + N +
L** from § 3 — everything except window titles and browser domains. Keeping that configuration one
line away means the degraded mode is a real code path we can build and test, not a paragraph.

**One thing to verify empirically rather than assume.** This repository's culture is that
`CONSTRAINTS.md` facts were produced by running the compiler, not by recollection. The claim
"a sandboxed process cannot read another application's AX attributes" is Apple's documented position
and matches every shipping app in this category, but it has not been run on this machine. Phase 3
should include a ten-minute check: build with the sandbox on, grant Accessibility, call
`AXUIElementCopyAttributeValue` against Finder, and record the exact `AXError` in `CONSTRAINTS.md`.
If the result contradicts the assumption, this section is the one to revisit.

---

## 3. The permission ladder

Read this table as: *everything above stays working when the row below is denied.* Denying a lower
row never disables an upper row. There is no combination of denials that produces a broken app.

| Tier | Requires | Unlocks | What is lost without it | Asked for when |
|---|---|---|---|---|
| **0 — Zero permissions** *(the default; a complete product)* | Nothing | • Projects, focus sessions, intended outcome, work type, 25/50/custom/open-ended durations<br>• Pause, resume, finish, result status, generated + editable summary<br>• Menu bar timer and popover, global hot key ⌘⇧Space, full keyboard workflow<br>• **Automatic per-application tracking**: frontmost app name + bundle id via `NSWorkspace`<br>• **Idle detection** via `CGEventSource` → focused vs idle time<br>• **Context switches** counted at application granularity<br>• Classification by `.application` and `.applicationName` rules<br>• Interruption inbox, accomplishment log, Today, weekly outcomes, weekly review, insights<br>• All four exports; all data persisted | — | — |
| **1 — Accessibility** | System Settings → Privacy & Security → Accessibility | • `ActivityEvent.windowTitle` populated<br>• `RuleMatchType.windowTitleContains` rules match<br>• Timeline rows read *"Xcode — ReceiptDeduplication.swift"* instead of *"Xcode"*<br>• `SessionSummaryBuilder` can name the work item, not just the app | Titles are `nil`; title rules never match; summaries name applications only | Onboarding screen 3, **or** the Settings → Privacy toggle, **or** one dismissible banner. Never otherwise. |
| **2 — Automation** *(per browser)* | Automation consent for that specific browser | • `ActivityEvent.domain` populated for that browser<br>• `RuleMatchType.domain` rules match → *GitHub → Code review*, *YouTube → Distraction*<br>• Browser time splits by site in Today and the weekly review | Domains are `nil`; all browser time is one block attributed to the browser | Onboarding screen 4, **or** the Settings → Privacy per-browser toggle, **or** the same single banner. Never otherwise. |
| **N — Notifications** *(orthogonal)* | Notification authorisation | Session-completed, halfway and long-idle alerts | Alerts are skipped; the menu bar icon still changes state and the review sheet appears on next open | Onboarding screen 5, **or** the first session start if onboarding was skipped, **or** a Settings toggle. Once, ever. |
| **L — Launch at login** *(orthogonal)* | `SMAppService` registration | Lggr is running when the user starts working | The user launches it themselves | Only from the Settings toggle. |

Tier 2 depends on Tier 1 for *nothing*: a user may grant Automation and refuse Accessibility, and
domains will be captured while titles stay `nil`. The onboarding order is a narrative convenience,
not a dependency.

**Testing the ladder without touching TCC.** The app reads `LGGR_PERMISSIONS` from the process
environment in debug builds and, when present, injects `StubPermissionsService` with a forced tier:

```bash
LGGR_PERMISSIONS=none    ./Scripts/run.sh     # Tier 0
LGGR_PERMISSIONS=ax      ./Scripts/run.sh     # Tier 0 + 1
LGGR_PERMISSIONS=ax+ae   ./Scripts/run.sh     # Tier 0 + 1 + 2
LGGR_PERMISSIONS=all     ./Scripts/run.sh     # everything
```

For the real thing, reset actual grants between manual tests:

```bash
tccutil reset Accessibility com.luisdoriz.lggr
tccutil reset AppleEvents   com.luisdoriz.lggr
tccutil reset All           com.luisdoriz.lggr
defaults delete com.luisdoriz.lggr            # clears UserPreferences, re-arms onboarding
```

---

## 4. The `PermissionsService` contract

`02-architecture.md` § 4 names `PermissionsProviding` + `SystemPermissionsService` +
`StubPermissionsService` but does not give the shape. It is this.

`File: Sources/LggrApp/Services/PermissionsService.swift` [P6, stub available from P3]

```swift
import Foundation

public enum PermissionStatus: String, Sendable, CaseIterable {
    /// Granted and usable right now.
    case granted
    /// The user has refused, or the system refuses on their behalf.
    case denied
    /// Never asked. Only this state may trigger a system prompt.
    case notDetermined
    /// Not applicable on this machine (e.g. the browser is not installed).
    case unavailable
}

@MainActor
public protocol PermissionsProviding: AnyObject {

    // Accessibility
    var accessibility: PermissionStatus { get }
    /// Non-prompting refresh. Safe to call on every app activation and every capture cycle.
    func refreshAccessibility()
    /// Shows the system prompt. MUST be called only from a control the user just pressed.
    func requestAccessibility()
    func openAccessibilitySettings()

    // Automation, per target browser bundle identifier
    func automation(forBundleIdentifier id: String) -> PermissionStatus
    /// Non-prompting: AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)
    func refreshAutomation(forBundleIdentifier id: String)
    /// Shows the system prompt for that one target. User-action only.
    func requestAutomation(forBundleIdentifier id: String) async -> PermissionStatus
    func openAutomationSettings()

    // Notifications
    var notifications: PermissionStatus { get }
    func refreshNotifications() async
    /// UNUserNotificationCenter.requestAuthorization. User-action only, at most once.
    func requestNotifications() async -> PermissionStatus
    func openNotificationSettings()
}
```

**Deriving `notDetermined` for Accessibility.** `AXIsProcessTrusted()` returns only `true` or
`false`; the API has no third state. `SystemPermissionsService` therefore reports:

```
AXIsProcessTrusted() == true                          → .granted
AXIsProcessTrusted() == false && !didRequestAXPrompt  → .notDetermined
AXIsProcessTrusted() == false &&  didRequestAXPrompt  → .denied
```

where `didRequestAXPrompt` is the persisted `UserPreferences.didRequestAccessibilityPrompt` (§ 12).
This distinction is what lets the UI say *"Enable window titles"* the first time and
*"Open System Settings"* afterwards — which matters, because macOS will not show the prompt twice.

**System Settings deep links.** These URLs are stable across macOS 14–26 but undocumented. Every one
is opened with `NSWorkspace.shared.open(_:)` and its `Bool` result checked; on `false` we fall back
to opening System Settings at its top level and the caption reads *Open System Settings → Privacy &
Security → Accessibility.* No force unwraps, no silent failure.

| Target | URL |
|---|---|
| Accessibility | `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` |
| Automation | `x-apple.systempreferences:com.apple.preference.security?Privacy_Automation` |
| Notifications | `x-apple.systempreferences:com.apple.preference.notifications` |
| Login Items | `SMAppService.openSystemSettingsLoginItems()` (real API, not a URL) |

---

## 5. Onboarding

Six screens in a single `OnboardingWindow` (`Sources/LggrApp/Views/Onboarding/` [P6]) — 560 × 460,
`.hiddenTitleBar`, no sidebar, no Dock-level modality. One idea per screen, one primary action per
screen (SPEC principle 6), a visible **Skip** on every permission screen (SPEC § Permissions).

Shown once, gated on `UserPreferences.hasCompletedOnboarding`. Reachable again from **Help → Show
Welcome…**. Reaching the last screen sets the flag regardless of how much was skipped. Closing the
window early also sets it — a user who closes an onboarding window has told us something.

Screen 4 is **omitted entirely** if no scriptable browser is installed (`NSWorkspace.urlForApplication(withBundleIdentifier:)`
returns `nil` for all of Safari, Chrome, Brave, Edge, Arc, Chromium). Never ask for something that
cannot be used.

`⌘↩` advances. `Esc` closes. Full keyboard traversal (SPEC § Keyboard experience).

---

### Screen 1 — Welcome

> ### Lggr
> **A record of what you actually worked on.**
>
> Start a focus session in under five seconds, and Lggr fills in the rest — what you worked in, how
> long, how often you were pulled away, and what you finished.
>
> It takes about a minute to set up.

**Primary:** `Continue` · **Tertiary, bottom-left:** `Skip setup`

---

### Screen 2 — What Lggr records

This screen requests nothing. It is the honest disclosure, and it comes *before* the first ask.

> ### Everything stays on this Mac
>
> **What Lggr records**
> - The application you're using, and when you switched
> - How long you were away from the keyboard
> - The focus sessions, notes and accomplishments you write yourself
> - Optionally, the title of your current window and the domain of your current browser tab — only
>   if you turn those on in the next two steps
>
> **What Lggr never records**
> - Keystrokes or passwords
> - Screenshots or screen contents
> - The contents of documents, messages or email
> - Your clipboard
> - Full web addresses — only the domain, never the page
>
> **Where it lives**
> One folder in your home directory: `~/Library/Application Support/Lggr`. Lggr has no account, no
> server and no network code. Nothing is uploaded, because there is nothing to upload to.
>
> **You stay in control**
> Pause tracking any time from the menu bar. Hide any app from tracking, or record it as
> "Private activity" with no name attached. Delete a session, a day, or everything — and export it
> first if you want to keep a copy.

**Primary:** `Continue`

---

### Screen 3 — Window titles (Accessibility)

> ### See what you worked on, not just where
>
> With permission, Lggr reads the **title of the window you're working in** — the file in your
> editor, the pull request in your browser, the document you're writing.
>
> That's the difference between:
>
> > Chrome — 42 minutes
>
> and
>
> > Reviewed the receipt deduplication pull request — 42 minutes
>
> macOS calls this **Accessibility**. It's a broad-sounding permission with a narrow use here: Lggr
> reads one string, the title of the frontmost window. It does not read your keystrokes, your
> screen, or the contents of anything.
>
> You can turn this off at any time in Settings → Privacy, and revoke it in System Settings.

**Primary:** `Enable window titles` — calls `permissions.requestAccessibility()`, the only place in
the app besides the Settings toggle where the system prompt is fired.
**Secondary:** `Not now` — advances. `trackWindowTitles` stays `true` so that the feature turns
itself on if the permission is ever granted later; nothing is captured until it is.

*After the prompt is dismissed, the screen updates in place rather than advancing:*

- **Granted** → a green `checkmark.circle` and *Window titles are on. You can turn them off in
  Settings → Privacy.* Primary becomes `Continue`.
- **Not granted** → *No problem — Lggr will track applications and timings without them.* Primary
  becomes `Continue`; a quiet secondary `Open System Settings…` appears. **We do not re-prompt, and
  we do not repeat the pitch.**

---

### Screen 4 — Browser domains (Automation) *(shown only if a scriptable browser exists)*

> ### Tell your browser time apart
>
> Browser time is usually several different jobs wearing one icon. With permission, Lggr asks
> **Safari** and **Chrome** for the domain of the tab you're on, so that `github.com` can count as
> code review and `youtube.com` doesn't.
>
> **Only the domain is stored** — `github.com`, never the full address, never the page title from
> the tab, never the contents. Private and Incognito windows in Chrome are skipped entirely.
>
> macOS will ask you separately for each browser, and the wording it uses is broad. Lggr sends
> exactly one command to each: *what is the address of the front tab?*

**Primary:** `Enable for Safari` / `Enable for Chrome` — one button per installed browser, each
firing that browser's prompt on click, each showing its own result inline.
**Secondary:** `Not now`

*After each prompt:* granted → `checkmark.circle` next to that browser. Denied → *Skipped. Browser
time will be tracked as “Safari”.* Never re-asked.

---

### Screen 5 — Notifications

> ### A quiet nudge when time's up
>
> Lggr can let you know when a session finishes, when you've been away from the keyboard for a
> while, and — if you want it — at the halfway mark.
>
> Three notifications, all optional, all switchable in Settings. No badges, no streaks, no reminders
> to be more productive.

**Primary:** `Enable notifications` · **Secondary:** `Not now`

If skipped, the request is made once, later, immediately **after** the user's first focus session has
already started — so it can never sit between the user and the five-second start path — and never
again.

---

### Screen 6 — Your first project

> ### One last thing
>
> Focus sessions belong to a project. Name the thing you spend most of your time on; you can add
> more later.

A single text field, pre-filled placeholder *e.g. Receipt ingestion*, plus the nine-colour picker
from `Project.colorIDs` and the icon row from `Project.iconIDs`.

**Primary:** `Start using Lggr` (disabled until the field is non-empty)
**Secondary:** `Skip` — creates a project named **General**, so the user is never dropped into an
app with an empty required picker.

On completion: `hasCompletedOnboarding = true`, the window closes, the main window opens on Today,
and the menu bar popover flashes once (`Motion.attention`) to teach where the app lives.

---

### 5.1 The re-ask policy, exactly

The rules below are absolute. Any code that prompts must be traceable to one of these.

1. **Never on launch. Never on a timer. Never on session start. Never on window focus. Never after
   an update.**
2. **A system prompt may only be fired from a control the user pressed in the same interaction.**
   Exactly three call sites exist in the app, and `Scripts/check-layering.sh` greps for them:
   - `OnboardingPermissionScreen` primary button
   - `PrivacySettingsView` toggle transitioning off → on
   - `PermissionBanner` primary button (rule 4)
3. **Once per permission, ever, from the app's side.** After `requestAccessibility()` has been
   called once, `didRequestAccessibilityPrompt` is persisted and every subsequent affordance becomes
   *Open System Settings*, which navigates rather than prompts. Same for
   `didRequestNotificationAuthorization`. Automation is once **per browser**.
4. **Exactly one dismissible banner per permission, for the lifetime of the installation.** It
   appears at the top of the Today view — never as a modal, never in the menu bar popover, never
   during an active session — when **all** of these hold:
   - the permission is `.notDetermined` or `.denied`, **and**
   - the user has finished **at least three** focus sessions (they have enough context to judge),
     **and**
   - `didDismissAccessibilityBanner` / `didDismissAutomationBanner` is `false`, **and**
   - no other permission banner is currently visible.

   Accessibility banner copy:

   > Lggr is tracking applications and timings. Turning on window titles would let it name what you
   > worked on.
   > `Enable window titles`   `Not interested`

   `Not interested` sets the dismissal flag permanently. **The banner never returns.** Not on the
   next launch, not next week, not after twenty sessions. The only remaining route is Settings →
   Privacy, which the user goes to on purpose.
5. **A denial is a decision, not a state to be recovered from.** The word *"Denied"* never appears in
   the UI; the Settings row reads *Off* with a quiet *Open System Settings…* link. No red, no
   warning triangle, no "reduced functionality" nag (SPEC § Design direction).
6. **Detecting a grant made outside the app.** `refreshAccessibility()` runs on
   `NSApplication.didBecomeActiveNotification`. If the status flips to `.granted` while Settings →
   Privacy is open, the row animates to *On* and window-title capture begins on the next interval —
   no relaunch, no confirmation dialog, no toast.

---

## 6. Private and excluded applications

### 6.1 Three levels of control, and the exact difference

This is the mental model the Settings screen teaches, in this order:

| Control | Recorded? | What the day shows |
|---|---|---|
| **Pause tracking** (`trackingPaused`) | Nothing, for any app | The whole period is absent. The session clock keeps running if a session is open. |
| **Excluded application** (`excludedApplications`) | No event at all for that app | A gap. Time appears under **Untracked**; the app's existence is never written to disk. |
| **Private application** (`privateApplications`) | An event with no identity | An anonymous **Private activity** block on the timeline with real start and end times. |

Said plainly for the Settings caption: *Pausing hides that you were working. Excluding an app hides
that you used it. Marking it private records that you were busy, without recording what you were
doing.*

### 6.2 Excluded vs private, field by field

| | **Excluded** | **Private** |
|---|---|---|
| `ActivityEvent` created | **No** | Yes |
| Window title read from the AX API | **Never called** | **Never called** |
| Browser URL requested via Apple Events | **Never called** | **Never called** |
| `applicationName` on disk | — | `"Private activity"` (`ActivityEvent.privatePlaceholder`) |
| `bundleIdentifier` on disk | — | `""` |
| `windowTitle` on disk | — | `nil` |
| `domain` on disk | — | `nil` |
| `category` on disk | — | `.unknown` |
| `classificationSource` on disk | — | `.unclassified` |
| `startedAt` / `endedAt` / `isIdle` on disk | — | Preserved |
| Counts toward total tracked time | **No** | Yes |
| Counts toward focused / reactive / category totals | No | No (`.unknown` counts as neither) |
| Counts as a context switch | **No** | Yes |
| Classification rules evaluated | n/a | No — `ClassificationRule.matches` already returns `false` for `event.isPrivate` (`03-data-model.md` § 2.7) |
| Appears on the timeline | No | Yes, unnamed |
| Reversible | Nothing was ever written | The original was never written |

**Precedence:** if a bundle identifier appears in both lists, **excluded wins**. It is the stronger
guarantee, and a user who put an app in both lists meant the stronger one.

**Both lists are empty by default.** Lggr ships with no opinion about which of the user's
applications are sensitive. The Settings screen offers a one-click *Suggest…* that proposes
password managers, banking apps and messaging apps found on the machine — as **checkboxes the user
must tick**, never pre-applied.

### 6.3 The excluded-application gap, and the bug it would otherwise cause

The obvious implementation — "skip excluded apps" — silently attributes the excluded time to
whichever app was frontmost before, because the previous interval is still open. That would be both
a wrong number and a privacy failure. The rule:

> **When the frontmost application is excluded, the tracker closes the open interval at the switch
> instant and opens no new interval.** A new interval opens only when a non-excluded application
> becomes frontmost.

Worked example — 1Password is excluded:

```
09:00  Xcode becomes frontmost         → open interval A (Xcode, startedAt 09:00)
09:12  1Password becomes frontmost     → close A at 09:12.  No interval opened.
09:14  Xcode becomes frontmost         → open interval B (Xcode, startedAt 09:14)
09:30  session finished

Session elapsed         30:00     (09:00 → 09:30, no pauses)
Sum of activity         28:00     (A = 12:00, B = 16:00)
Untracked                2:00     shown as "Untracked" on Today — never added to Xcode
Context switches             0     Xcode → Xcode
```

Two consequences that must be preserved:

1. **`ActivityCoalescer` must not merge across a gap.** `02-architecture.md` describes it as "merge
   adjacent same-app intervals". Adjacent must mean *touching*: merge A and B only when
   `B.startedAt - A.endedAt <= 2 seconds` (the switch-notification latency allowance). Merging
   across the 2-minute hole above would absorb the excluded application's time into Xcode and
   destroy the exclusion. This is a named unit test:
   `ActivityCoalescerTests.doesNotMergeAcrossAnExcludedGap`.
2. **Context switches are counted at 0, and that is deliberate.** Counting the round trip as two
   switches would put a number on screen that only makes sense if something happened in between —
   telling the user's manager, or the user's screenshot, that an unnamed application ran. Exclusion
   hides *what*; a gap in the timeline still reveals *that*. A user who wants to hide *that* pauses
   tracking. This trade-off is stated in the privacy statement rather than hidden.

### 6.4 Redaction is enforced at capture — four mechanisms, in order

The requirement is that this must be *impossible to get wrong later*, not merely documented. Four
independent mechanisms, arranged so that any single one failing still yields a correct file on disk.

**Mechanism 1 — a separate capture type, so a title cannot reach the store by accident.**

`ActivityTrackingService` never constructs an `ActivityEvent`. It accumulates a distinct raw type,
and the only sanctioned conversion is a pure function that takes the preferences with it:

```swift
// Sources/LggrKit/Model/ActivitySample.swift  [P3]
/// Raw, unredacted capture. Never Codable, never persisted, never leaves the tracker.
public struct ActivitySample: Sendable, Hashable {
    public var applicationName: String
    public var bundleIdentifier: String
    public var windowTitle: String?
    public var domain: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var isIdle: Bool
}

// Sources/LggrKit/Domain/PrivacyRedactor.swift  [P3]
public struct PrivacyRedactor: Sendable {

    /// The ONLY sanctioned way to turn captured data into a persistable event.
    /// Returns nil when the application is excluded — there is nothing to store.
    /// Returns a fully redacted event when the application is private.
    public static func event(
        from sample: ActivitySample,
        preferences: UserPreferences,
        focusSessionID: UUID?
    ) -> ActivityEvent?

    /// True when the tracker must not read a title or a URL for this bundle identifier.
    /// Consulted BEFORE the AX / Apple Event call, never after.
    public static func mustNotInspect(
        bundleIdentifier: String,
        preferences: UserPreferences
    ) -> Bool
}
```

Note that `ActivitySample` is deliberately **not** `Codable`. It cannot be written to any store, to
`UserDefaults`, or to a JSON export, because it has no encoder.

**Mechanism 2 — a private application's title and URL are never read in the first place.**

This is the primary guarantee, and it is stronger than the `redactedIfPrivate()` described in
`03-data-model.md` § 2.4. Redaction is not *capture then strip*; it is *do not capture*. The exact
capture pipeline, in order — the order is the mechanism:

```
frontmost-app change, or idle threshold crossed
 1. close the open interval at t                              (always, even if paused)
 2. if preferences.trackingPaused                → stop. No new interval.
 3. if preferences.isExcluded(bundleID)          → stop. No new interval.      ← EXCLUSION FIRST
 4. open ActivitySample(app, bundleID, startedAt: t)
 5. if PrivacyRedactor.mustNotInspect(bundleID, preferences)
        → do NOT call WindowTitleReader
        → do NOT call BrowserDomainReader                                      ← NEVER READ
    else
        → if trackWindowTitles && permissions.accessibility == .granted
              sample.windowTitle = WindowTitleReader.focusedTitle(pid:)
        → if trackBrowserDomains && isBrowser && automation(for: bundleID) == .granted
              sample.domain = await BrowserDomainReader.host(for: bundleID)
 6. on close: PrivacyRedactor.event(from:preferences:focusSessionID:) → ActivityEvent?
 7. buffer; on flush, re-evaluate exclusion against the CURRENT preferences
 8. store.saveActivityEvents(events)
```

Step 7 gives **retroactive exclusion for anything still in the buffer**: a user who adds an app to
the excluded list mid-session drops the not-yet-written events for that app. Step 5 means a private
app's title never exists as a `String` in this process — it is not read, not held, not logged, not
passed to a formatter.

**Mechanism 3 — the write boundary re-asserts the invariant.**

Callers can be wrong; the last function before the bytes hit the disk cannot be. Every conformer of
`LggrStore` re-applies redaction on entry:

```swift
public func saveActivityEvents(_ events: [ActivityEvent]) async throws {
    // Idempotent: redactedIfPrivate() is a no-op on an already-redacted event and on a
    // non-private one. Applying it here means no code path in the application, present or
    // future, can write a private application's title or bundle identifier to disk.
    let safe = events.map { $0.redactedIfPrivate() }
    ...
}
```

This is required in `JSONFileStore`, `InMemoryStore` **and** `SwiftDataStore`, and it is asserted by
the shared `LggrStoreContractTests` (`03-data-model.md` § 6): construct an `ActivityEvent` with
`isPrivate == true` and a populated `windowTitle`, `bundleIdentifier`, `domain` and `category`; save
it through each backend; read it back; assert the title and domain are `nil`, the bundle identifier
is `""`, the name is `"Private activity"` and the category is `.unknown`.

**Mechanism 4 — mechanical guards, so review is not the safety net.**

- `Scripts/check-layering.sh` gains two greps that fail the build:
  - the argument label `windowTitle:` appearing outside `ActivityEvent.swift`,
    `PrivacyRedactor.swift`, `ActivitySample.swift`, `PreviewFixtures.swift`,
    `Sources/LggrPersistence/Mapping/` and `Tests/`;
  - `AXUIElementCopyAttributeValue` or `NSAppleScript` appearing outside
    `WindowTitleReader.swift` and `BrowserDomainReader.swift`.
- `ActivityEvent` conforms to `CustomDebugStringConvertible` in `LggrKit`, printing
  `ActivityEvent(Xcode, 09:00–09:12, private: false)` and **never** the title or domain. Without
  this, one `print(event)` in a debug session or one swift-testing failure message writes a window
  title into a log file or a CI transcript. (Adding `debugDescription` is safe; the trap flagged in
  `03-data-model.md` § 2.5 concerns a *stored property* named `description`.)
- **No `os_log`, `print` or `NSLog` call ever takes `windowTitle` or `domain` as an argument**, at
  any level, public or private. There is no diagnostic value that justifies the risk.

### 6.5 Changing the lists does not rewrite history — and we say so

Marking an application private or excluded applies **from the next captured interval onward**. Events
already on disk are not rewritten or deleted. The confirmation says exactly that, rather than letting
the user assume otherwise:

> **Mark Slack as private?**
> From now on, time in Slack will be recorded as "Private activity" with no name and no window
> title.
> Records already saved are not changed. To remove them, use **Delete all activity history** in
> Settings → Privacy.
> `Cancel`   `Mark as private`

This is a deliberate MVP boundary — a retroactive per-application purge would need a new store method
and a progress UI for a case that arises once. It is the one item in this document worth revisiting
after real use (§ 12).

---

## 7. Data lifecycle

### 7.1 Where the store lives

Unsandboxed, so this is the real path with no container indirection:

```
~/Library/Application Support/Lggr/
├── projects.json
├── weekly-outcomes.json
├── sessions.json
├── activity.json          ← the only privacy-sensitive file
├── interruptions.json
├── accomplishments.json
└── rules.json
```

Preferences are **not** here. Per `03-data-model.md` § 7, `UserPreferences` is one JSON blob in
`UserDefaults` under the key `com.lggr.userPreferences.v1`, backed by
`~/Library/Preferences/com.luisdoriz.lggr.plist`.

Under Xcode with `LGGR_SWIFTDATA=1`, `SwiftDataStore` replaces the JSON files with a SQLite store in
the same directory. The directory, the permissions rules below, and every delete operation in this
section are identical either way.

**File permissions are set explicitly, not left to the umask.** Unsandboxed, the default umask
produces `0755` directories and `0644` files, readable by every other local account on the Mac. That
is unacceptable for `activity.json`:

- the directory is created with `[.posixPermissions: 0o700]`;
- `AtomicFileWriter` sets `[.posixPermissions: 0o600]` on the temporary file **before**
  `FileManager.replaceItemAt`, so the replacement inherits it and there is no window in which a
  world-readable copy exists.

Asserted in `JSONFileStoreTests.storeFilesAreOwnerReadableOnly`.

**Backups are honest, not hidden.** `~/Library/Application Support` is included in Time Machine.
Lggr does not set `NSURLIsExcludedFromBackupKey`, because losing the log to a disk failure is worse
than having it in a local backup the user controls. It is not synced by iCloud Drive. The privacy
statement says so.

**Settings → Privacy has a `Reveal Data Folder in Finder` button.** The user can open the files, read
them, copy them, and delete them without the app. Being inspectable is the main thing an unsandboxed
app can offer in place of a sandbox badge, and it is also the zero-code lossless backup path.

### 7.2 Retention

`UserPreferences.dataRetentionDays: Int?` — default **90**, `nil` = keep forever. Settings offers
30 / 90 / 180 / 365 days / Keep everything. The cutoff helper already exists
(`03-data-model.md` § 2.8):

```swift
public func retentionCutoff(from now: Date, calendar: Calendar = .current) -> Date?
```

**Retention prunes `ActivityEvent` and nothing else.** This is the most important sentence in this
section. Focus sessions, accomplishments, interruptions, weekly outcomes and projects are the user's
authored record and are **never** deleted automatically, at any retention setting, ever. It is why
`deleteActivityEvents(startedBefore:)` is the only date-based delete on `LggrStore`. A user who set
"90 days" three years ago and opens Lggr on a Friday still sees every accomplishment they ever
logged; what they lose is the minute-by-minute application trace behind them.

The Settings caption states the scope so nobody has to infer it:

> Activity records older than this are deleted automatically. Your sessions, accomplishments and
> notes are always kept.

### 7.3 The pruning job

`File: Sources/LggrApp/Services/RetentionPruner.swift` [P4]

```swift
@MainActor
final class RetentionPruner {
    private var task: Task<Void, Never>?

    func start() {
        task = Task { @MainActor [weak self] in
            // Never on the launch critical path: the UI is up and the first frame is drawn first.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.pruneIfNeeded(reason: .scheduled)
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}
```

Runs on exactly four triggers:

1. **20 seconds after launch** — off the critical path, after the first frame.
2. **Every 6 hours** while the app runs.
3. **On wake** (`NSWorkspace.didWakeNotification`, via the existing `SleepWakeObserver`) if more than
   6 hours have passed since `lastPruneAt`. A Mac that sleeps every night would otherwise never
   reach trigger 2.
4. **Immediately** when the user *lowers* `dataRetentionDays` in Settings, after the confirmation in
   § 7.4. Raising it or choosing "Keep everything" prunes nothing.

Behaviour:

- `guard let cutoff = preferences.retentionCutoff(from: clock.now) else { return }` — `nil` means
  keep forever and the job is a no-op.
- `try await store.deleteActivityEvents(startedBefore: cutoff)`.
- The cutoff is applied to **`startedAt`**, matching the protocol's `startedBefore:` label. An
  interval that began before the cutoff and ended after it is deleted. At a 90-day boundary that is
  at most one interval; the alternative — splitting an interval at midnight ninety days ago — is
  complexity with no user-visible payoff.
- **Idempotent** and safe to run at any time. It cannot touch the currently open interval, which has
  `startedAt == now`.
- Runs whether or not a session is active. The store is an actor; there is no contention to avoid.
- Writes `lastPruneAt` to `UserPreferences` on success (§ 12).
- **Failure is never surfaced.** Logged via `os_log` at `.error` with a count and a reason, and
  retried on the next trigger. A user does not need an alert about housekeeping.
- **Never runs during onboarding** — `hasCompletedOnboarding == false` short-circuits it, so a
  first-run import (none today, but the door is open) cannot be pruned before it is seen.

### 7.4 Deletion, at four granularities

Every one of these is available from the UI, and every one of them offers an export first (§ 7.5).

**a. One session** — `Focus Sessions` → row context menu → *Delete Session*, and the detail view's
toolbar.

`store.deleteSession(id:)`. Per `03-data-model.md` § 5.1 this is the schema's **only cascade**:
deleting a session deletes its `ActivityEvent`s. That is intentional and is exactly the privacy
behaviour a user expects — deleting a session must not leave that session's captured window titles on
disk. Accomplishments and interruptions created during it **survive** with their `focusSessionID`
nullified, because they are authored content.

> **Delete this session?**
> The session, its summary and its 1,204 activity records will be removed. The 2 accomplishments you
> logged from it are kept.
> `Cancel`   `Export…`   `Delete`

**b. One session's activity, keeping the session** — detail view → *Delete Activity for This
Session*. For the case "I don't want the window titles from that afternoon, but I want the record of
the work." Requires `deleteActivityEvents(sessionID:)` (§ 12). The session keeps its duration,
result, summary, blocker, next step and `interruptionCount`; its timeline strip becomes an empty
state reading *Activity for this session was deleted.*

**c. One day** — Today, and any day in Focus Sessions → *Delete This Day's Activity*. Requires
`deleteActivityEvents(in:)` (§ 12), passing that day's `DateInterval` from `CalendarWindows`.
Sessions and accomplishments for the day are untouched.

**d. All activity history** — Settings → Privacy → *Delete All Activity History*. This is SPEC § 4's
*Delete activity history*, and its scope is exactly its name: `store.deleteAllActivityEvents()`
removes every `ActivityEvent` and **nothing else**.

The confirmation states the count, the span, and — importantly — what is *lost* as well as what is
kept, because "activity history" sounds harmless and the derived metrics are not:

> **Delete all activity history?**
> This removes **41,208 activity records** covering **87 days**.
>
> **Kept:** every focus session, its summary and result; every accomplishment, interruption, project
> and weekly outcome.
>
> **Lost:** the timeline for past days, and the per-application, per-category and context-switch
> figures calculated from it. Those numbers will read zero for days before today.
>
> This cannot be undone.
> `Cancel`   `Export activity first…`   `Delete 41,208 records`

**e. Everything** — Settings → Privacy → *Delete All Lggr Data*, in a visually separated block at the
bottom of the pane.

Removes the entire `~/Library/Application Support/Lggr/` directory, calls
`UserDefaults.standard.removePersistentDomain(forName: "com.luisdoriz.lggr")`, unregisters
`SMAppService.mainApp` if it was registered, and quits. It does **not** touch TCC grants — an app
cannot revoke its own permissions, and the sheet says so with a link to System Settings.

> **Delete all Lggr data?**
> Every project, session, accomplishment, note and setting will be removed from this Mac, and Lggr
> will quit. Nothing is kept anywhere else, because Lggr has never sent your data anywhere.
>
> The Accessibility and Automation permissions you granted stay in System Settings until you remove
> them there.
> `Cancel`   `Export everything first…`   `Delete everything and quit`

Deletion order matters: files first, then defaults, then quit — so an interrupted delete leaves an
app with no data rather than data with no app to read it.

### 7.5 Export before delete

Every destructive confirmation carries an **Export…** button between Cancel and the destructive
action, so the safe path is the one your eye lands on first.

| Action | What Export… writes |
|---|---|
| Delete one session | That session as Markdown (`DailySummaryMarkdown` scoped to one session) |
| Delete a day's activity | That day's summary as Markdown + that day's activity as CSV |
| Delete all activity history | **Activity CSV** for the full range |
| Delete all Lggr data | A folder containing the four SPEC exports (daily summaries, weekly reviews, accomplishment log, sessions CSV) **plus a copy of the raw JSON store directory** |

`ActivityCSVExporter` (`Sources/LggrKit/Export/ActivityCSVExporter.swift` [P4]) is the one export not
named in SPEC § Export. It exists because it is the *only* export that captures what these dialogs
are about to destroy — offering "export first" and then handing back a file that omits the deleted
data would be a lie. Columns:
`startedAt, endedAt, durationSeconds, applicationName, bundleIdentifier, windowTitle, domain, category, classificationSource, isIdle, isPrivate, focusSessionID`.
Private rows export exactly as stored — `"Private activity"`, empty bundle identifier, empty title —
because there is nothing else to export.

For (e), the raw JSON copy is a plain `FileManager.copyItem` of the store directory. It is lossless,
costs nothing to implement, and matches what the user could do themselves from the *Reveal Data
Folder* button.

All exports go through `ExportService` → `NSSavePanel`. Unsandboxed, no entitlement is needed; the
sandboxed variant would need `com.apple.security.files.user-selected.read-write`.

### 7.6 Durability around the lifecycle

- `NSSupportsSuddenTermination` = `false` and `NSSupportsAutomaticTermination` = `false` so macOS
  cannot kill the process mid-write (currently missing from `Resources/Info.plist` — § 12).
- `AppDelegate.applicationWillTerminate` flushes the store, per `02-architecture.md` § 6.5.
- `JSONFileStore` coalesces writes on a 500 ms debounce and writes atomically via
  `AtomicFileWriter` (temp file + `replaceItemAt`), so a crash leaves either the previous complete
  file or the new complete file — never a truncated one.
- `StoreSnapshot.schemaVersion` guards against a newer file: the MVP refuses to load it and logs
  clearly rather than migrating or, worse, overwriting.

---

## 8. Settings → Privacy — the screen this document implies

`Sources/LggrApp/Views/Settings/PrivacySettingsView.swift` [P6]. Every control named in SPEC § 4
*Privacy controls*, in this order, so the destructive things are at the bottom:

1. **Tracking** — `Pause tracking` toggle (`trackingPaused`), mirrored in the menu bar popover.
2. **Window titles** — `trackWindowTitles` toggle, with a status row: *On* / *Off* /
   *Off — Accessibility permission needed* + `Enable…` or `Open System Settings…`.
3. **Browser domains** — `trackBrowserDomains` toggle plus one row per installed scriptable browser
   with its own Automation status and action.
4. **Idle threshold** — `idleThreshold`, 1 / 3 / 5 / 10 / 15 minutes.
5. **Private applications** — an editable list with an app picker and a `Suggest…` action.
6. **Excluded applications** — same, with the one-sentence difference restated inline.
7. **Data retention** — `dataRetentionDays` picker with the scope caption from § 7.2, and a
   read-only line: *Oldest activity record: 12 March 2026 · 41,208 records · 3.1 MB.*
8. **Your data** — `Reveal Data Folder in Finder`, `Export…`.
9. **Danger zone**, visually separated — `Delete All Activity History`, `Delete All Lggr Data`.

The privacy statement of § 10 sits at the top of the pane in a `Card`, above control 1. It is the
first thing on the screen, not a link to a document nobody opens.

---

## 9. Verification checklist

Runnable checks, not intentions. These belong in `06-checklist.md` under Phase 6.

```bash
# No networking is linked into the binary.
otool -L build/Lggr.app/Contents/MacOS/LggrApp | grep -iE 'CFNetwork|Network\.framework|Security\.framework/.*Transport'   # expect no output

# The entitlements that actually shipped.
codesign -d --entitlements - build/Lggr.app

# Info.plist is well-formed and carries the Apple Events usage string.
plutil -lint  build/Lggr.app/Contents/Info.plist
plutil -extract NSAppleEventsUsageDescription raw build/Lggr.app/Contents/Info.plist

# Exercise every denial path from a clean slate.
tccutil reset Accessibility com.luisdoriz.lggr
tccutil reset AppleEvents   com.luisdoriz.lggr
defaults delete com.luisdoriz.lggr

# Watch TCC decisions live while clicking through onboarding.
log stream --predicate 'subsystem == "com.apple.TCC"' --info

# Store files are not world-readable.
ls -le ~/Library/Application\ Support/Lggr/     # expect -rw------- and drwx------
```

Manual passes, each done twice — once at Tier 0, once fully granted:

- Complete onboarding declining **every** permission. Run a full session, finish it, log an
  accomplishment, open the weekly review, run all four exports. Nothing is disabled; nothing shows an
  error; the word "denied" appears nowhere.
- Grant Accessibility from System Settings **while the app is running**; confirm titles begin
  appearing on the next interval without a relaunch and without a dialog.
- Revoke Accessibility mid-session; confirm titles become `nil`, no crash, no prompt, no banner.
- Mark an app private, use it, quit the app, and `grep` `activity.json` for that app's name, bundle
  identifier and a distinctive window title. **Zero hits** is the pass condition.
- Exclude an app, use it for two minutes inside a session, and confirm: the neighbouring app's total
  did not grow, `Untracked` shows two minutes, and context switches did not increase.
- Set retention to 30 days with older data present; confirm the prune runs, `activity.json` shrinks,
  and every session and accomplishment older than 30 days is still listed.
- Delete all activity history; confirm sessions, summaries and accomplishments are intact and the
  timeline is empty.

Unit tests this document adds to `Tests/LggrKitTests/`:

| Test file | Covers |
|---|---|
| `PrivacyRedactorTests` | excluded → `nil`; private → all six fields cleared; non-private untouched; excluded-beats-private precedence; case-insensitive bundle matching; `mustNotInspect` |
| `DomainExtractorTests` | host extraction, `www.` stripping, credentials and ports discarded, query/fragment discarded, `file:`/`about:`/`chrome:` → `nil`, malformed input |
| `ActivityCoalescerTests` | `doesNotMergeAcrossAnExcludedGap`, merges within the 2 s tolerance, never merges different bundle identifiers |
| `RetentionTests` | `retentionCutoff` at each setting and at `nil`; prune deletes only `ActivityEvent`; prune is idempotent; prune never touches an open interval |
| `LggrStoreContractTests` *(extended)* | a private event with a populated title cannot be persisted by any of the three backends |
| `ActivityEventTests` *(extended)* | `debugDescription` contains neither `windowTitle` nor `domain` |

---

## 10. The privacy statement

Plain language, shown at the top of Settings → Privacy and reachable from Help → Privacy. No legal
register, no defined terms, no "we may".

> ### Your work log stays on your Mac
>
> Lggr has no account, no server, and no network code. Nothing you record is uploaded, because there
> is nowhere for it to go.
>
> **What Lggr records.** Which application is in front and when you switched. How long you were away
> from the keyboard. The projects, sessions, notes and accomplishments you write yourself. If you
> turn them on: the title of your current window, and the domain — not the address — of your current
> browser tab.
>
> **What Lggr never records.** Keystrokes. Passwords. Screenshots or anything on your screen. The
> contents of documents, messages or email. Your clipboard. Full web addresses.
>
> **Where it lives.** One folder you can open, read and delete:
> `~/Library/Application Support/Lggr`. It is readable only by your account, and it is included in
> your Time Machine backups.
>
> **What you control.** Pause tracking from the menu bar at any time. Hide an application completely,
> or record it as "Private activity" with no name and no title attached — for private applications,
> Lggr never even asks the system what the window is called. Delete a session, a day, or everything.
> Choose how long activity records are kept; your sessions and accomplishments are always kept.
>
> **What Lggr can't do.** It can't tell that a Safari or Firefox window is a private window; if that
> matters, add the browser to your private list. Hiding an application hides *what* you were doing,
> not *that* you were doing something — a gap still shows on the timeline. Pause tracking if you want
> the gap gone too. And Lggr can't remove the permissions you granted; those live in System Settings
> and only you can take them back.
>
> Lggr is meant to help you reconstruct your week, not to watch you.

---

## 11. Phase mapping

| Phase | Permissions and privacy work |
|---|---|
| **P2** | Store directory created with `0700`; `AtomicFileWriter` writes `0600`. `NSSupportsSuddenTermination` / `NSSupportsAutomaticTermination` added to `Info.plist`; `NSAccessibilityUsageDescription` removed. `StubPermissionsService` exists so the gallery can render every permission state. |
| **P3** | `ActivitySample`, `PrivacyRedactor`, `DomainExtractor` and their tests. `WindowTitleReader` gated on `AXIsProcessTrusted()`. `BrowserDomainReader` as an `actor`, gated on Automation status and `trackBrowserDomains`. Redaction re-asserted in all three `saveActivityEvents` implementations. `ActivityCoalescer` gap rule. `check-layering.sh` guards. Sandbox-vs-AX empirical check recorded in `CONSTRAINTS.md`. |
| **P4** | `RetentionPruner`. Per-day and per-session activity deletion. `ActivityCSVExporter`. Export-before-delete on every destructive confirmation. |
| **P6** | `SystemPermissionsService`. Onboarding, all six screens with the copy above. `PrivacySettingsView`. The single-banner re-ask policy. `LaunchAtLoginService`. The privacy statement in the UI. |

---

## 12. Open questions

Recorded rather than silently applied, per the brief. Items 1–4 are contradictions between binding
documents or between a binding document and the repository as it stands today; 5–9 are additions this
strategy needs.

1. **`LggrStore` is declared two different ways.** `02-architecture.md` § 4.2 defines it as
   `protocol LggrStore: Sendable` with `actor` conformers and methods named `allProjects()`,
   `upsert(_:)`, `deleteActivity(before:)`, plus `preferences()` / `save(_ preferences:)`.
   `03-data-model.md` § 4 defines it as `@MainActor protocol LggrStore: AnyObject` with
   `loadProjects()`, `saveProject(_:)`, `deleteActivityEvents(startedBefore:)`, and explicitly
   excludes preferences. This document uses **`03`'s names and signatures** on the stated rule that
   `03` is the keystone for type and field names. `02` § 6.1's "the store is an `actor`" and
   `03` § 4's `@MainActor` cannot both hold. Needs one owner to reconcile.

2. **Store file layout.** `02` § 7.7 says `~/Library/Application Support/Lggr/store.json` (one file);
   `03` § 4 says the same directory with "one JSON file per aggregate". § 7.1 above follows `03`. The
   privacy consequence is the same either way, but the onboarding copy and the *Reveal Data Folder*
   affordance should name whichever is real.

3. **Bundle identifier and executable name.** `02` § 7.4 specifies `CFBundleIdentifier` =
   `com.lggr.Lggr` and `CFBundleExecutable` = `Lggr`, with the plist and entitlements under
   `Scripts/`. The repository actually ships `com.luisdoriz.lggr` and `LggrApp`, with both files
   under `Resources/`. This document follows the **repository**, because the bundle identifier is the
   TCC identity and changing it after a permission grant silently discards every grant. `02` § 7.4
   should be amended to match rather than the other way round.

4. **Three defects in the files on disk today.**
   - `Resources/Info.plist` contains `NSAccessibilityUsageDescription`, which `02` § 7.4 explicitly
     says must not be there. It is harmless but it implies a permission model macOS does not have.
     Remove it.
   - `Resources/Info.plist` is missing `NSSupportsSuddenTermination` and
     `NSSupportsAutomaticTermination`, both of which `02` § 6.5 and § 7.4 require and which protect
     unflushed activity. Add them as `false`.
   - `Scripts/make-app.sh` comments that an ad-hoc signature "gives the bundle a stable code identity
     so macOS remembers the Accessibility permission across rebuilds". It does not — an ad-hoc
     signature's cdhash changes whenever the binary changes, which is exactly the wrinkle `02` § 7.7
     documents and solves with a self-signed `Lggr Dev` identity. The comment should be corrected
     before someone trusts it and spends an afternoon on it.

5. **`BrowserDomainReader` must be an `actor`, not `@MainActor`.** `02` § 6.1 makes the whole
   `LggrApp` target `@MainActor` and § 6.7 forbids background queues. `NSAppleScript` is blocking IPC
   that can stall for seconds behind a consent sheet or a busy browser; running it on the main actor
   would freeze the timer and the menu bar. § 1.2 above declares it an `actor` and returns a
   `Sendable String?`. This is one documented exception to a rule that is otherwise absolute, and it
   needs to be written into `02` § 6.1 rather than discovered later.

6. **Four new `UserPreferences` fields.** All with explicit defaults, all preserving the "one JSON
   blob, no key migration" design of `03` § 7. `03` warns that fields added after v1 ships need a
   `decodeIfPresent` path; these are added **before** v1 ships, so no migration is required today.
   - `trackBrowserDomains: Bool = false` — the master switch for § 1.2. Defaults to `false`, unlike
     `trackWindowTitles`, because the Automation prompt's wording ("access to documents and data") is
     alarming enough that it should follow an explicit yes rather than precede one.
   - `browserAutomation: [String: Bool] = [:]` — bundle identifier → user intent, so a browser the
     user declined is never queried again and a second browser installed later starts clean.
   - `didRequestAccessibilityPrompt: Bool = false`, `didRequestNotificationAuthorization: Bool =
     false`, `didDismissAccessibilityBanner: Bool = false`, `didDismissAutomationBanner: Bool =
     false` — these four *are* the re-ask policy of § 5.1. Without persistence, "once, ever" is
     "once per launch", which is nagging.
   - `lastPruneAt: Date? = nil` — so the wake trigger in § 7.3 can tell 6 hours from 6 minutes.

   Note the reconciliation this implies: `02` § 7.7 says title and domain capture are "opt-in, off
   until the user enables them", while `03` defaults `trackWindowTitles` to `true`. Both are correct
   under the rule **permission is the gate, preference is the switch** — nothing is captured until
   Accessibility is granted, and the `true` default means the feature simply works the moment the
   user grants it. That reading should be stated in `03` § 2.8 so nobody "fixes" the default.

7. **Two new `LggrStore` methods**, needed by § 7.4(b) and § 7.4(c) and trivially implementable in
   all three backends:
   ```swift
   func deleteActivityEvents(in interval: DateInterval) async throws
   func deleteActivityEvents(sessionID: UUID) async throws
   ```

8. **Retroactive per-application purge is deliberately out of scope.** Marking an application private
   or excluded applies going forward only, and § 6.5 says so in the confirmation copy. The honest
   alternative — a `deleteActivityEvents(bundleIdentifier:)` method plus a progress UI — is one more
   store method and one more sheet for a case that arises about once per install. Worth revisiting
   after real use; the copy is written so that shipping without it is not misleading.

9. **The sandbox-versus-Accessibility claim has not been run on this machine.** § 2 states Apple's
   documented position, which matches every shipping app in this category, but this repository's
   standard is that constraints are verified by execution. The ten-minute Phase 3 check is specified
   at the end of § 2; its result belongs in `CONSTRAINTS.md`. If it comes back the other way, the
   sandbox recommendation is the one conclusion in this document that would change.
