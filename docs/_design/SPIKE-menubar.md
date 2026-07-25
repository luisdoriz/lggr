# Spike: does a `MenuBarExtra` label redraw at 1 Hz?

**Result: yes. Risk retired.** The `NSStatusItem` fallback in `06-checklist.md` § 11.1 is not needed,
and the app layer should build on `MenuBarExtra`.

This was the highest-likelihood risk to Phase 2: the label of a `MenuBarExtra` is hosted by the
system and rebuilt on its own schedule, and "my timer freezes in the menu bar" is a common report.
If it could not redraw once a second, SPEC Phase 2 item 4 — *display the timer in the menu bar* —
would be undeliverable, and the fix would be a rewrite onto AppKit. So it was tested before any view
work was built on top of it.

## Method

A throwaway app with a `MenuBarExtra` whose label view appends a timestamped line to a log file each
time its `body` is evaluated. Launched as a signed `LSUIElement` bundle and left running.

Body evaluation is a proxy for redraw, but a sound one for this question: if the label's `body` is
never re-evaluated, it cannot possibly show a new time, and if it is re-evaluated once a second with
new text, SwiftUI renders it.

## Measurement

32 consecutive label body evaluations. Intervals between them:

| Interval | Count |
|---|---|
| 0.999 s | 1 |
| 1.000 s | 28 |
| 1.001 s | 2 |
| 1.003 s | 1 |

No missed ticks, no drift, `elapsed` strictly monotonic from 0 through 21.

## The pattern that works

Three things together, all of them load-bearing:

```swift
@Observable
final class Ticker {
    var now: Date = Date()

    func start() {
        // .common, not the default mode. A timer on the default run-loop mode stops firing while
        // the menu is being tracked or a window is being resized, which is exactly when a user is
        // looking at the menu bar.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
```

1. **`@Observable`**, so SwiftUI tracks the `now` read inside the label body and invalidates it.
2. **`RunLoop.main.add(timer, forMode: .common)`** rather than `Timer.scheduledTimer`.
3. **The label view reads `ticker.now` directly in its own `body`** — not in a parent that passes a
   pre-formatted string down. Observation only invalidates the view that performed the read.

## Second spike: does the menu bar survive the main window closing?

**Result: yes, but only with an explicit delegate.** SPEC § Navigation requires that "the menu bar
experience should work even when the main window is closed".

Measured by having the app close every visible window itself after five seconds and report its state
six seconds later:

```
LAUNCHED  windows=2
CLOSING   count=3
ASKED_TERMINATE_AFTER_LAST_WINDOW
STILL_ALIVE windows=0 policy=0
```

The app was still running with zero visible windows and the menu bar item intact. The load-bearing
detail is the third line: AppKit *asked* whether to terminate, and the answer is what kept the
process alive. So `AppDelegate` must implement:

```swift
func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
```

Without it the app quits when the user closes the window, taking a running focus session with it.
This is not optional polish; it is the requirement.

## Third spike: how do we review the UI with no `#Preview`?

**Result: `ImageRenderer` works headlessly, in both appearances.** This replaces the previews the
spec asks for with something stronger — an image anyone can look at, produced by the build.

`#Preview` cannot compile here (CONSTRAINTS.md), which would otherwise leave the entire visual
design unreviewable until someone installs Xcode. Verified instead:

```swift
let renderer = ImageRenderer(content: SomeView().environment(\.colorScheme, .dark))
renderer.scale = 2
let png = renderer.nsImage…   // written straight to disk
```

Both appearances rendered correctly at 2×, with SF Symbols, system fonts and semantic colours all
resolving — the light render came back on a white background with dark text, the dark render on a
dark background with light text, from the same view. No screen-recording permission, no window, no
running app.

**How to wire it:** `LggrApp` gains a hidden launch mode — `LggrApp --snapshot <directory>` renders
each Phase 2 screen in light and dark, writes PNGs, and exits. A separate snapshot *target* is not
possible, because SwiftPM cannot import an executable target; a launch mode avoids restructuring the
app into a library just to photograph it.

**`ImageRenderer` draws a `ScrollView` as nothing at all.** Not a clipped viewport — nothing. Ink
counted off the bitmaps, same content and frame each time:

| Content | Ink |
|---|---|
| `VStack { rows }` | 1839 |
| `LazyVStack { rows }` | 1712 |
| `ScrollView { VStack { rows } }` | **0** |
| `ScrollView { … }.scrollDisabled(true)` | **0** |
| `ScrollView { … }.fixedSize(…)` | **0** |

Worth recording how this was first got wrong: the initial diagnosis blamed `LazyVStack` not
materialising rows without a viewport, and the "fix" was a taller frame. The table above is what
settled it — `LazyVStack` renders fine on its own, no frame height helps, and the plausible
explanation was simply wrong. `NSHostingView` in an offscreen window, via both `cacheDisplay` and
`CALayer.render(in:)`, comes back empty too.

**The fix** is `Components/ScrollingSection.swift`: a `ScrollView` in the app, a plain top-aligned
stack when `isGalleryMode` is set. Removing the scroll view is the correct rendering for a
photograph anyway — a snapshot wants full content height, not one 720 pt viewport. Behaviour in the
running app is unchanged.

**Still unphotographable:** `TextEditor` and `.buttonStyle(.borderless)` / `.link` render as
SwiftUI's yellow "unsupported view" placeholder. They are correct in the running app; they need an
AppKit host the renderer does not provide. A yellow block in a snapshot means *the camera could not
see this control*, not *this control is broken* — and the app must not be reshaped to photograph
better.

For anything the renderer cannot reach, screenshot the running app:

```bash
Scripts/make-app.sh debug && open build/Lggr.app
screencapture -x -o /tmp/shot.png
```

That path verifies more than a snapshot can. Reviewing Today this way confirmed a session running
11:00–11:52 with a five-minute pause displays **47m** rather than 52m — the pause arithmetic proved
end to end, from the JSON on disk through the domain layer to the rendered row.

## Not covered

Whether the label keeps counting *while the popover is open* was not measured, because it needs a
real click. `.common` run-loop mode is the specific mitigation for that case and is already applied.
Confirm it during the manual walkthrough in `06-checklist.md` § 5.3.
