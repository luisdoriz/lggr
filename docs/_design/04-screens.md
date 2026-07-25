# Lggr — Screens, Navigation, Interaction and the Visual Design System

> Deliverable 5 of the Phase 1 design set. Read `CONSTRAINTS.md`, `02-architecture.md` and
> `03-data-model.md` first. Every type name, field name and file path below is taken verbatim from
> those documents. Where I disagreed with them, the disagreement is recorded in § 12, not applied
> silently.
>
> This file is written so an engineer can build from it without inventing anything. Where a number
> is given, it is the number. Where copy is quoted, it is the string.

---

## 0. The feeling we are building for

Four references, four things we take from each:

| Reference | What we take |
|---|---|
| **Things** | Generous whitespace, one obvious action per screen, empty states that read like a person wrote them. |
| **Raycast** | The sub-five-second path: one keystroke, type, Return. No mouse anywhere in the critical flow. |
| **Linear** | Restraint in colour and chrome. Data is dense but never loud. Hairlines, not boxes. |
| **Craft** | Typography carries the hierarchy, not borders and not cards. |

And the thing none of them do, which is our whole product: **the app makes a claim about your day and
lets you correct it.** Every screen is evidence, never a score.

Three rules that resolve most detail arguments before they start:

1. **Space before lines, lines before boxes, boxes before colour.** Reach for 32pt of air first; a
   `Divider()` second; a card third; a tinted surface last and almost never.
2. **Colour means "which project", or it means nothing.** The only colour with semantic weight in
   the whole app is the project colour, and it is never the only carrier of that meaning.
3. **Nothing moves that the user did not move.** No pulsing, no shimmer, no attention-seeking.
   Numbers change; the layout holds still.

---

## 1. The navigation shell

### 1.1 Scene graph

Three scenes, exactly as declared in `02-architecture.md` § 5.1:

```
MenuBarExtra  ─ MenuBarContentView   ─ .menuBarExtraStyle(.window), 320pt wide
Window "Lggr" ─ RootWindow           ─ id: WindowID.main, default 1040 × 720
Settings      ─ SettingsWindow       ─ hosts the same SettingsView as the sidebar's row
```

`RootWindow` is a two-column `NavigationSplitView`:

```swift
// Views/Root/RootWindow.swift
NavigationSplitView(columnVisibility: $app.columnVisibility) {
    Sidebar(selection: $app.section)
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
} detail: {
    NavigationStack(path: $app.detailPath) {
        DetailContent(section: app.section)
    }
    .frame(minWidth: 640)
}
.navigationSplitViewStyle(.balanced)
```

The detail column owns a `NavigationStack` so Focus Sessions and Accomplishments can push a detail
view without a third column. A three-column split would leave the middle column empty on five of the
seven sections; two columns plus push is the calmer shape.

Window frame is persisted automatically by SwiftUI per scene `id`. Sidebar selection persists in
`UserDefaults` under `com.lggr.sidebar.section` via `AppModel`.

### 1.2 Sidebar sections

`File: Views/Root/SidebarSection.swift`

```swift
public enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case today, sessions, accomplishments, weeklyReview, projects, rules, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today:          return "Today"
        case .sessions:       return "Focus Sessions"
        case .accomplishments:return "Accomplishments"
        case .weeklyReview:   return "Weekly Review"
        case .projects:       return "Projects"
        case .rules:          return "Rules"
        case .settings:       return "Settings"
        }
    }

    public var symbolName: String {
        switch self {
        case .today:          return "sun.max"
        case .sessions:       return "timer"
        case .accomplishments:return "checkmark.seal"
        case .weeklyReview:   return "chart.bar.xaxis"
        case .projects:       return "folder"
        case .rules:          return "slider.horizontal.3"
        case .settings:       return "gearshape"
        }
    }

    /// ⌘1 … ⌘7, in declaration order.
    public var shortcutNumber: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
}
```

All seven symbols exist in SF Symbols 4 and render on macOS 14.

**Symbols stay in their outline variant, always.** The obvious Apple move is `.symbolVariant(.fill)`
on the selected row, but `timer` and `slider.horizontal.3` have no `.fill` variant, so selection
would change the shape of five rows and not two. Selection is carried entirely by the system
highlight. This is a real constraint, not a preference.

Sidebar row anatomy:

```
│  ⟨18pt symbol⟩  Today                    ● │
   └ 8pt gap ┘                      running dot
```

- Row height: system default for `.listStyle(.sidebar)`. Do not set a custom height.
- Symbol frame `width: 18, alignment: .center` so the labels align even though the glyphs differ.
- **No per-section tint.** A seven-colour sidebar is the single fastest way to look like enterprise
  software.
- **Running indicator:** when `sessionManager.active != nil`, the *Today* row shows a trailing 6pt
  filled circle in `Color.accentColor`. It does not pulse, does not animate in, and does not show a
  countdown. The live number lives in two places only — the menu bar and Today itself. A sidebar
  that reprints itself every second is the opposite of calm.
- Section grouping: one flat list, no `Section` headers. Seven items do not need headings.

`Settings` in the sidebar (required by `SPEC.md` § Navigation) and the `Settings` scene (required by
`02-architecture.md` § 5.1) both render the **same** `SettingsView` with `.formStyle(.grouped)`.
`⌘,` opens the scene because that is what every Mac user's hands expect; `⌘7` selects the sidebar
row. One view, two hosts, zero duplicated code.

### 1.3 Behaviour when the main window is closed

The menu bar experience is a separate scene and is untouched by window state. Specifically:

| Event | Behaviour |
|---|---|
| User presses `⌘W` / clicks the close button | Window closes. **The app does not quit.** `AppDelegate.applicationShouldTerminateAfterLastWindowClosed` returns `false`. |
| A session is running | The `TickTimer` keeps running, the menu bar label keeps counting, activity tracking continues. Nothing about the session is coupled to a window. |
| Global shortcut `⌘⇧Space` | Activates the app, opens the menu bar popover, and shows the **start panel inline in the popover** — the main window is *not* opened. Starting a session never forces a window at you. |
| `⌘N`, `⌘⇧A`, `⌘⇧I`, `⌘1`–`⌘7` | Still work. `LSUIElement` is `false` (`02-architecture.md` § 7.6), so the application menu bar survives with zero windows open, and menu commands survive with it. `⌘1`–`⌘7` open the window if it is closed, then select the section. |
| Clicking the Dock icon | `applicationShouldHandleReopen(_:hasVisibleWindows:)` calls `openWindow(id: WindowID.main)`. |
| Any "Open …" row in the popover | `openWindow(id: WindowID.main)` then `NSApp.activate(ignoringOtherApps: true)`, then sets `app.section`. |
| A session finishes while the window is closed | **We do not force the window open.** The session enters `.awaitingReview`, the menu bar symbol becomes `questionmark.circle`, and the popover's top row becomes `Review last session`. The completion notification's default action opens the window with `SessionReviewSheet` presented. |
| Notifications | Delivered normally; `UNUserNotificationCenter` does not care about windows. |
| App quits with a session running | No confirmation dialog. On next launch `store.loadActiveSession()` restores it and `elapsed(at:)` recomputes exactly (`03-data-model.md` § 3.5). |

Phase 6 adds a **Hide Dock icon** preference which calls `NSApp.setActivationPolicy(.accessory)`.
That loses the application menu bar, so when it is enabled the popover grows a `Preferences…` row
and the keyboard map degrades to popover-scoped shortcuts. This is documented in the preference's
help text, not discovered.

---

## 2. Design tokens

Four files, all in `Sources/LggrApp/DesignSystem/`, all listed in `02-architecture.md` § 3:
`Typography.swift`, `Theme.swift`, `Palette.swift`, `Motion.swift`, plus `Iconography.swift`.

### 2.0 The constraint that shapes all of this

`Lggr.app` is assembled by hand from `Scripts/make-app.sh`. **There is no asset catalog**, so there
is no `Color("CardBackground")` and no light/dark colour pair defined in Xcode. Every adaptive colour
must be constructed in code:

```swift
// DesignSystem/Palette.swift
import AppKit
import SwiftUI

extension NSColor {
    /// The only way to get a light/dark pair without an asset catalog.
    static func lggrDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}
```

Everywhere else, prefer a **system semantic colour** (`.windowBackgroundColor`, `.separatorColor`,
`Color.primary`, `.secondary`, `Color.accentColor`) over a literal. A system colour is already
correct in light mode, dark mode, increased contrast, and under vibrancy. Hand-rolled greys are not.

### 2.1 Type ramp

macOS text-style point sizes are fixed and small; the ramp below is built from text styles so
Dynamic Type works, with exactly **one** hard-coded size in the entire app.

`File: DesignSystem/Typography.swift`

| Token | SwiftUI value | pt (macOS default) | Role — where it appears |
|---|---|---|---|
| `Type.timerHero` | `.system(size: timerSize, weight: .medium, design: .rounded).monospacedDigit()` | 72, `@ScaledMetric(relativeTo: .largeTitle)` | The one dominant number: active session timer in the main window. Nowhere else. |
| `Type.screenTitle` | `.largeTitle.weight(.semibold)` | 26 | The detail column header — "Today", "Weekly Review". One per screen. |
| `Type.outcome` | `.title2.weight(.medium)` | 17 | The intended outcome. The second-most important text in the app; it sits directly under the timer and never truncates. |
| `Type.timerCompact` | `.title.weight(.medium).monospacedDigit()` | 22 | Timer inside the menu bar popover and the review sheet header. |
| `Type.sectionTitle` | `.title3.weight(.semibold)` | 15 | "Accomplishments", "Time allocation", "Day". |
| `Type.metricValue` | `.title2.weight(.medium).monospacedDigit()` | 17 | The number in a `MetricTile`. |
| `Type.rowTitle` | `.headline` | 13 semibold | Session titles, project names, accomplishment titles, rule descriptions. |
| `Type.body` | `.body` | 13 | Body copy, summary editor, form field contents, empty-state second line. |
| `Type.secondary` | `.subheadline` | 11 | Metadata: project name, time ranges, application lists, metric captions. |
| `Type.caption` | `.caption` | 10 | Timeline axis labels, keyboard hints, "built-in rule" tags. Nothing a user *must* read is set at this size. |
| `Type.menuBarTimer` | `.system(size: 12, weight: .regular, design: .rounded).monospacedDigit()` | 12 | The menu bar label only. Never used inside a window. |
| `Type.mono` | `.system(.body, design: .monospaced)` | 13 | Markdown export preview. |

Rules:

- `.rounded` design is used for **numerals under a clock only** (`timerHero`, `menuBarTimer`). It
  makes a timer feel like an instrument rather than a spreadsheet. Everything else is the system
  face.
- `.monospacedDigit()` is mandatory on every number that changes over time. This is what stops the
  menu bar and the hero timer from jittering horizontally once per second.
- Weight is never used to create a fifth hierarchy level. Four levels — hero / title / row / body —
  plus `.secondary` foreground for everything demoted.
- No letter-spacing, no all-caps section headers, no small-caps. Uppercase tracked-out labels are
  the visual signature of the enterprise dashboard we are refusing to build.

### 2.2 Spacing scale

4pt base. Eight steps, named, and that is the complete set.

```swift
// DesignSystem/Theme.swift
public enum Space {
    public static let xxs: CGFloat = 2    // symbol-to-text inside a badge
    public static let xs:  CGFloat = 4    // menu bar symbol → digits
    public static let s:   CGFloat = 8    // icon → label; chip padding
    public static let m:   CGFloat = 12   // between sibling cards; list row vertical padding
    public static let l:   CGFloat = 16   // card interior padding; form row spacing
    public static let xl:  CGFloat = 24   // detail column horizontal inset
    public static let xxl: CGFloat = 32   // between major sections on a screen
    public static let hero:CGFloat = 48   // above/below the hero timer; empty-state breathing room
}
```

Applied consistently:

| Situation | Value |
|---|---|
| Detail column leading/trailing inset | `Space.xl` (24) |
| Detail column top inset (below the title) | `Space.xl` (24) |
| Between two major sections | `Space.xxl` (32) |
| Section title → its first row | `Space.m` (12) |
| Card interior padding | `Space.l` (16) |
| List row vertical padding | `Space.m` (12) top and bottom |
| Icon → label in a row | `Space.s` (8) |
| Sheet interior padding | `Space.xl` (24) |
| Popover interior padding | `Space.m` (12) |
| Between the hero timer and the outcome | `Space.l` (16) |
| Above/below the hero timer block | `Space.hero` (48) |

Nothing uses a value that is not in this list. If a layout wants 18pt, it wants 16 or 20 and the
designer was guessing.

### 2.3 Corner radii

```swift
public enum Radius {
    public static let chip:  CGFloat = 6    // duration segments, source chips, project badges
    public static let card:  CGFloat = 10   // cards, list rows with a hover fill, text fields
    public static let panel: CGFloat = 14   // sheets' inner panels, the popover's session block
}
```

Always `RoundedRectangle(cornerRadius:style: .continuous)`. Never the default `.circular` style —
continuous corners are what every native macOS surface uses and the difference is visible at 10pt.
Capsules (`Capsule()`) are used for exactly one thing: the progress ring's linear variant in the
popover.

### 2.4 Semantic colour roles

```swift
// DesignSystem/Palette.swift
public enum Surface {
    /// The detail column background. Sidebar background is left to the system.
    public static let canvas = Color(nsColor: .windowBackgroundColor)

    /// A raised card sitting on `canvas`. Lighter than the canvas in both modes.
    public static let raised = Color(nsColor: .lggrDynamic(
        light: .white,
        dark:  NSColor(white: 1.0, alpha: 0.055)   // composites over the dark window background
    ))

    /// A recessed well: text fields, the summary editor, the code-ish areas.
    public static let sunken = Color(nsColor: .controlBackgroundColor)

    /// Row hover. Also the pressed state at 1.5×.
    public static let hover = Color.primary.opacity(0.06)

    /// A selected, non-focused row (the focused one uses the system selection colour).
    public static let selected = Color.accentColor.opacity(0.14)
}

public enum Stroke {
    /// Structural separators. Always the system value; never a hand-mixed grey.
    public static let separator = Color(nsColor: .separatorColor)

    /// The hairline around a card.
    public static let card = Color(nsColor: .lggrDynamic(
        light: NSColor(white: 0.0, alpha: 0.07),
        dark:  NSColor(white: 1.0, alpha: 0.10)
    ))
}
```

**Text** uses only `.primary`, `.secondary`, `.tertiary`. `.quaternary` is permitted for *shapes*
(an empty progress track) and forbidden for text.

**Accent** is `Color.accentColor` — the user's system accent, never a hardcoded blue. If the user's
Mac is set to Graphite, Lggr is graphite. That is a native app behaving natively.

**Attention** — there is one non-project colour with meaning:

```swift
public enum Palette {
    /// Overtime digits, and the "at risk" outcome status glyph. Nothing else.
    /// Never used as a fill, never as a background, never on more than ~20 characters at a time.
    public static let attention = Color(nsColor: .systemOrange)

    /// Destructive confirmation buttons only. There is no red anywhere else in Lggr.
    public static let destructive = Color(nsColor: .systemRed)
}
```

Red appears in this app in exactly one place: the confirm button of a delete alert. Not on blocked
sessions, not on distraction time, not on missed outcomes. The spec asks for this explicitly and it
is the easiest principle to violate by accident.

### 2.5 Project colours

`Project.colorID` is a `String` token from `Project.colorIDs` (`03-data-model.md` § 2.1). The app
maps it to a system colour so the palette is already correct in light mode, dark mode and under
increased contrast:

```swift
public extension Palette {
    static func project(_ colorID: String) -> Color {
        switch colorID {
        case "blue":     return .blue
        case "purple":   return .purple
        case "pink":     return .pink
        case "red":      return .red
        case "orange":   return .orange
        case "yellow":   return .yellow
        case "green":    return .green
        case "teal":     return .teal
        case "graphite": return Color(nsColor: .systemGray)
        default:         return .blue          // unknown token from a future version
        }
    }
}
```

**Where a project colour may appear — the complete list:**

1. An 8pt filled circle immediately before a project name (`ProjectBadge`), with a
   `Color.primary.opacity(0.15)` 0.5pt inner stroke so yellow survives on white.
2. A 3pt full-height leading bar on a day-timeline block.
3. The tint of the project's own SF Symbol in `ProjectsView` and the project editor.
4. A segment fill in the Weekly Review's time-allocation bar, separated from its neighbours by a
   1pt `Surface.canvas` gap.
5. The 9-swatch picker in the project editor (28pt circles, checkmark on the selected one).

**Where it may not appear:** as a card background, as text colour, as a border on anything other than
(2), in a gradient, or as the only signal of which project a row belongs to. Every project dot is
followed by the project's name, so colour blindness costs nothing.

### 2.6 Materials

`.regularMaterial` and friends only where something genuinely floats. Three uses in the whole app:

| Surface | Material | Why |
|---|---|---|
| Menu bar popover background | System default for `.menuBarExtraStyle(.window)` | Do not override it. macOS gives the popover the correct vibrancy for the menu bar; anything we set fights it. |
| The "session running" strip pinned to the bottom of the detail column when a session runs and you are not on Today | `.thinMaterial` + a top `Divider()` | It overlaps scrolling content, so it must read as floating. |
| Sidebar background | System default via `.listStyle(.sidebar)` | Never set a background on a `NavigationSplitView` sidebar. |

Sheets get the system sheet background (opaque). Material over an opaque window is a grey rectangle
pretending to be interesting.

Under **Reduce transparency** the `.thinMaterial` strip becomes `Surface.raised`:

```swift
.background(reduceTransparency ? AnyShapeStyle(Surface.raised) : AnyShapeStyle(.thinMaterial))
```

### 2.7 Separators

In priority order — reach for the first that works:

1. **32pt of space** (`Space.xxl`) between sections. This is the default answer.
2. **A `Divider()`** when two lists of equal weight abut with no heading between them, and at the
   top edge of the floating session strip.
3. **List row separators**: `.listRowSeparator(.visible)`, `.listRowSeparatorTint(Stroke.separator)`,
   and the leading inset aligned to the *text* column, not the row edge — 44pt when the row has a
   leading icon, `Space.l` when it does not.
4. **A card hairline**: `.strokeBorder(Stroke.card, lineWidth: 1)` drawn on the *same*
   `RoundedRectangle(cornerRadius: Radius.card, style: .continuous)` used for the fill, so the stroke
   is crisp instead of blurred by a half-pixel mismatch.

Never a 2pt rule, never a coloured rule, never a separator inside a card.

Under **Increase contrast**
(`NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`): `Stroke.card` opacity goes
0.07 → 0.22 (light) and 0.10 → 0.28 (dark); `Surface.hover` goes 0.06 → 0.12.

### 2.8 Motion vocabulary

Five named animations. There is no sixth.

```swift
// DesignSystem/Motion.swift
public enum Motion {
    /// Hover, press, focus ring. Must feel like the control is already there.
    public static let tap    = Animation.easeOut(duration: 0.12)
    /// Cross-fades, selection moves, count changes, section collapse.
    public static let settle = Animation.easeInOut(duration: 0.22)
    /// Something appearing: a disclosure opening, a row inserting, panel content swapping.
    public static let reveal = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// The progress ring advancing one tick. Linear so a second looks like a second.
    public static let ring   = Animation.linear(duration: 1.0)
    /// Explicitly no animation. Used on the timer digits.
    public static let none: Animation? = nil
}
```

Reduce-motion is handled in one place, not at every call site:

```swift
public extension View {
    /// `.lggrAnimation(.reveal, value: isExpanded)`
    func lggrAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(LggrAnimationModifier(animation: animation, value: value))
    }
}

private struct LggrAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? .easeInOut(duration: 0.1) : animation, value: value)
    }
}
```

Under Reduce Motion: `reveal` and `settle` collapse to a 0.1s ease, `ring` updates discretely with
no interpolation, and `.contentTransition(.numericText())` becomes `.identity`.

Fixed rules:

- **The timer never animates its layout.** Digits use `.contentTransition(.numericText(countsDown: true))`
  on the hero timer only, and `Motion.none` for everything else about it. The menu bar label uses no
  content transition at all — it redraws once per second and a transition there is a battery cost
  with no benefit.
- Nothing scales. No `.scaleEffect` on press; buttons change fill, not size.
- Nothing repeats. `.repeatForever` does not appear in the codebase. That single rule eliminates
  pulsing dots, breathing rings and shimmer placeholders.
- Sheet and popover presentation animation is the system's. We do not customise it.

### 2.9 Light and dark

The mechanism, concretely:

- **System semantic colours** (`.windowBackgroundColor`, `.controlBackgroundColor`,
  `.separatorColor`, `.systemOrange`, `Color.primary/.secondary/.tertiary`, `Color.accentColor`)
  adapt with zero code. This covers roughly 90% of the surface area.
- **The two hand-made colours** (`Surface.raised`, `Stroke.card`) go through
  `NSColor.lggrDynamic(light:dark:)`, which reads the resolving `NSAppearance`. They are the only
  two, deliberately.
- **Project colours** are `Color.blue`, `.purple`, … — the SwiftUI system colours, which are already
  the adaptive `systemBlue` family.
- **SF Symbols** are template images tinted by `.foregroundStyle`, so they follow text.
- **Materials** adapt themselves.

Verification loop on a machine with no Xcode: `LGGR_GALLERY=1 ./Scripts/run.sh` opens
`Dev/PreviewGallery.swift`, which renders every registered view twice side by side —
`.preferredColorScheme(.light)` and `.preferredColorScheme(.dark)` — against
`AppEnvironment.fake()`. Every new view is added to the gallery in the same commit that adds the
view. That is the light/dark test, and it is a real running window, not a promise.

Two dark-mode traps we handle explicitly:

1. A white card on a dark canvas is a flashlight. `Surface.raised` in dark mode is a 5.5% white
   overlay, i.e. *slightly* lighter than the window, not brighter than the text around it.
2. Yellow and orange project dots vanish on a light canvas. The 0.5pt
   `Color.primary.opacity(0.15)` inner stroke on every project dot fixes this in one place.

### 2.10 Iconography

`File: DesignSystem/Iconography.swift`. Every SF Symbol name used by `LggrApp` that is not already
supplied by a domain enum lives here as a `static let`. Domain symbols come from the enums in
`03-data-model.md` § 1 (`WorkType.symbolName`, `SessionResultStatus.symbolName`,
`ActivityCategory.symbolName`, `AccomplishmentType.symbolName`, `InterruptionSource.symbolName`,
`SessionState.symbolName`) and are **never re-declared** in the app target.

```swift
public enum Icon {
    public static let startSession   = "play.circle"
    public static let quickTimer     = "bolt"
    public static let pause          = "pause.fill"
    public static let resume         = "play.fill"
    public static let finish         = "checkmark"
    public static let interruption   = "bell.badge"
    public static let addAccomplishment = "plus.circle"
    public static let export         = "square.and.arrow.up"
    public static let regenerate     = "arrow.clockwise"
    public static let more           = "ellipsis.circle"
    public static let search         = "magnifyingglass"
    public static let previousWeek   = "chevron.left"
    public static let nextWeek       = "chevron.right"
    public static let inbox          = "tray"
    public static let privacy        = "hand.raised"
    public static let accessibility  = "accessibility"
    public static let emptyToday     = "sun.max"
    public static let emptySessions  = "timer"
    public static let emptyDone      = "checkmark.seal"
    public static let emptyWeek      = "chart.bar.xaxis"
    public static let emptyProjects  = "folder"
    public static let emptyRules     = "slider.horizontal.3"
    public static let error          = "exclamationmark.triangle"
}
```

Symbols in body text use `.imageScale(.medium)` and inherit `.foregroundStyle`. Toolbar symbols use
the system default. Symbols never get a coloured circular background — no "icon chips".

---

## 3. Shared components and shared state policy

`Sources/LggrApp/Components/`, all listed in `02-architecture.md` § 3.

```swift
Card(padding:)            // Surface.raised + Radius.card + Stroke.card hairline
SectionHeader(title:action:) // Type.sectionTitle + optional trailing borderless button
EmptyStateView(symbol:title:message:action:)
PrimaryButtonStyle        // accent fill, Radius.chip, ⌘⏎ hint rendered inline at .caption
MetricTile(value:label:)  // Type.metricValue over Type.secondary, .accessibilityElement(children: .combine)
ProjectBadge(project:)    // 8pt dot + name, Type.secondary
```

### 3.1 Empty-state anatomy — the shape every screen reuses

```
        ⟨28pt SF Symbol, .tertiary⟩

           Title sentence          ← Type.rowTitle, .primary
    One calm line of explanation.  ← Type.body, .secondary, max 2 lines
        [ Primary action ⌘X ]      ← only when there is one obvious next step
```

Centred in the available space, `Space.hero` of air above and below, max text width 340pt. **No
illustrations.** One symbol, two lines, at most one button. Copy is warm, brief, factual, and never
implies the user has failed to do something.

### 3.2 Loading policy — one rule for the whole app

The store is a local JSON file or a local SwiftData container; reads are measured in milliseconds.
Therefore:

1. **The chrome renders immediately.** Screen title, section headers and toolbar are never gated on
   data.
2. For the first **250ms** a section renders its normal layout with fixture-shaped content and
   `.redacted(reason: .placeholder)`. This keeps the layout from jumping when data lands.
3. After 250ms, and only then, a section may show a small centred `ProgressView().controlSize(.small)`.
4. **There is no full-screen spinner anywhere in Lggr**, and no skeleton shimmer (it would need
   `.repeatForever`, which is banned by § 2.8).

### 3.3 Error policy — one rule for the whole app

Errors from `LggrStore` surface as an inline `ErrorBanner` at the top of the detail column, inside
the content inset, above everything else:

```
┌──────────────────────────────────────────────────────────────┐
│ ⚠  Couldn't load today. Your work is still on disk.          │
│    [ Try again ]   [ Show in Finder ]                        │
└──────────────────────────────────────────────────────────────┘
```

- Symbol `Icon.error` in `.secondary`, **not** red. `Stroke.card` hairline, `Surface.raised` fill.
- One sentence. It says what failed and reassures about data, in that order.
- Always at least one recovery action.
- The banner is dismissible (`⌘.` or a trailing `xmark` on hover) and returns on the next failure.
- `StoreError.persistenceFailure` while *saving* is the only case that gets an `Alert`, because the
  user is about to lose input: "Couldn't save this session." / "Try again, or copy the summary so
  you don't lose it." / [Copy summary] [Try again].
- Alerts are used **only** for (a) unsaveable input and (b) destructive confirmation. Everything
  else is a banner.

---

## 4. The seven sidebar screens

Each block gives: primary action → wireframe → hierarchy → empty state → loading/error → hover and
context menus.

---

### 4.1 Today  `⌘1`

**Primary action:** **Start Focus** when nothing is running; **Finish** when a session is running.
One button, one place, it retitles.

```
┌────────────────────┬─────────────────────────────────────────────────────────┐
│ ☀ Today         ●  │  Today                     Thursday 24 July   [ ⤴ ⌄ ]   │
│ ⏱ Focus Sessions   │  ─────────────────────────────────────────────────────  │
│ ✓ Accomplishments  │  ┌───────────────────────────────────────────────────┐  │
│ ▥ Weekly Review    │  │ ● SOR engineering · Deep work                     │  │
│ 🗀 Projects        │  │ Finish the receipt deduplication PR               │  │
│ ⚙ Rules            │  │                                                   │  │
│ ⚙ Settings         │  │            32:41            ◔ 65%                 │  │
│                    │  │            remaining                              │  │
│                    │  │                                                   │  │
│                    │  │ Xcode · 4 switches · 1 interruption               │  │
│                    │  │ [ Pause ] [ Capture ⌘⇧I ]        [ Finish  ⌘⏎ ]   │  │
│                    │  └───────────────────────────────────────────────────┘  │
│                    │                                                         │
│                    │  Working toward                                         │
│                    │  ★ Improve receipt ingestion reliability   2h 10m today │
│                    │  ○ Unblock the mobile team                    35m today │
│                    │                                                         │
│                    │  Accomplishments                        [ Add   ⌘⇧A ]   │
│                    │  ✓ Opened the receipt deduplication PR          11:04   │
│                    │  ✓ Unblocked Omar on the ingestion retry        14:20   │
│                    │                                                         │
│                    │  Time allocation                                        │
│                    │  ┌────────┬────────┬────────┬────────┬────────┐         │
│                    │  │ 5h 12m │ 3h 40m │ 1h 05m │   4    │   17   │         │
│                    │  │tracked │focused │reactive│sessions│switches│         │
│                    │  └────────┴────────┴────────┴────────┴────────┘         │
│                    │  ▐coding 31%▐review 22%▐comms 19%▐mtg 14%▐other 14%▌    │
│                    │                                                         │
│                    │  Day                              9:00 ──────── 18:00   │
│                    │  ▐▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▓▓▓▓░░░▒▒▒▒▒▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▐        │
│                    │  9:00–9:52 · Receipt deduplication                      │
│                    │  Xcode, Terminal, GitHub · Completed                    │
│                    │                                                         │
│                    │  Interruptions · 2                       [ Review ]     │
│                    │  · Review Omar's blocked PR                     10:12   │
│                    │  · Reply to finance about the Q3 invoice        15:47   │
└────────────────────┴─────────────────────────────────────────────────────────┘
```

**Visual hierarchy, in priority order** (this is `SPEC.md` § 7's order, honoured exactly):

1. **Current or next focus session** — the only card on the screen. `Type.timerHero` for the number,
   `Type.outcome` for the intent. Everything else on Today is quieter than this by design.
2. **Working toward** — the week's outcomes with today's time against each. `[P5]`; in Phases 2–4
   this section is simply absent, not an empty placeholder.
3. **Accomplishments** — today's `Accomplishment` rows, newest last so the day reads top to bottom.
4. **Time allocation** — five `MetricTile`s plus one 6pt-tall stacked category bar. The bar has a
   legend inline in its labels; there is no separate legend block and no pie chart.
5. **Activity timeline** — a horizontal day strip with grouped blocks, plus the selected block's
   detail underneath in the exact shape `SPEC.md` § 7 asks for.
6. **Interruption inbox** — last, compact, count in the heading. `[P4]`.

The card is the *only* card. Sections 2–6 are headed lists on the bare canvas. This is the single
most important layout decision on this screen: a Today made of six cards is a dashboard, and a
dashboard is what we are not building.

**Timeline block grouping:** blocks come from `SessionTimelineBuilder` / `ActivityCoalescer`
(`LggrKit`), never from raw `ActivityEvent`s. A block is a contiguous run belonging to one session,
or a contiguous run of untracked-but-active time. Blocks shorter than 90 seconds are merged into
their neighbour. Idle time renders as a 40%-opacity version of the same fill. Clicking a block
selects it and updates the two lines beneath; `←`/`→` moves between blocks when the strip has focus.

**Empty states.**

Nothing at all today:

> **Nothing tracked yet today.**
> Start a session and this fills itself in.
> `[ Start Focus  ⌘N ]`

Sessions exist but no accomplishments:

> **No accomplishments logged today.**
> Add one when something ships, or let a finished session suggest it.
> `[ Add  ⌘⇧A ]`

Empty interruption inbox (the section hides entirely rather than showing a state — an empty inbox is
good news and does not need a paragraph about it).

No timeline data because tracking is paused:

> **Tracking is paused.**
> Sessions and accomplishments still record; application activity does not.
> `[ Resume tracking ]`

No timeline data because Accessibility was declined — the strip still renders from application-level
data; a single `.caption` `.secondary` line sits under it: "Window titles are off, so blocks are
grouped by application." No button. It is not a problem, it is a fact.

**Loading:** § 3.2. The session card renders instantly from `SessionManager` (in memory); only the
lower sections redact.

**Error:** § 3.3 banner. A failure to load history never hides a running session — the card comes
from memory, so the top of the screen keeps working.

**Hover:** accomplishment and interruption rows fill with `Surface.hover` over `Motion.tap` and
reveal a trailing `Icon.more` borderless button. Timeline blocks lift to 100% opacity from a resting
92% and show a tooltip after 600ms (`.help(…)`) with the exact time range.

**Context menus:**

- Session card: *Capture interruption* `⌘⇧I` · *Add accomplishment* `⌘⇧A` · *Copy outcome* ·
  *Change project ▸* · *Finish session* `⌘⏎`
- Completed session row: *Add accomplishment* `⌘⇧A` · *Edit summary…* · *Copy summary* ·
  *Change project ▸* · *Reveal in Focus Sessions* · — · *Delete session* (destructive, confirms)
- Accomplishment row: *Edit…* · *Copy as Markdown* · *Change type ▸* · *Change project ▸* · — ·
  *Delete* (destructive, confirms)
- Interruption row: *Convert to session* · *Convert to accomplishment* · *Mark resolved* ·
  *Dismiss*
- Timeline block: *Reclassify ▸* (the eleven `ActivityCategory` cases) · *Make this a rule…* ·
  *Mark application private* · *Exclude this application*

---

### 4.2 Focus Sessions  `⌘2`

**Primary action:** **New Focus Session** `⌘N`.

```
┌─────────────────────────────────────────────────────────────────┐
│  Focus Sessions        [ 🔍 Search  ⌘F ]  [ All projects ⌄ ] [+]│
│  ───────────────────────────────────────────────────────────── │
│  Today                                                          │
│  ● Finish the receipt deduplication PR                          │
│    SOR engineering · Deep work · 9:00–9:52 · 52m   ✓ Completed  │
│  ● Review the ingestion retry design                            │
│    SOR engineering · Code review · 10:30–11:12 · 42m  ↷ Progress│
│                                                                 │
│  Yesterday                                                      │
│  ● Triage the duplicate commission report                       │
│    Incidents · Incident · 14:05–14:55 · 50m       ✋ Blocked     │
│  ● Weekly planning                                              │
│    — · Planning · 16:00–16:25 · 25m               ✓ Completed   │
│                                                                 │
│  Tuesday 22 July                                                │
│  …                                                              │
└─────────────────────────────────────────────────────────────────┘
```

Selecting a row pushes `FocusSessionDetailView` onto the detail `NavigationStack`: the outcome as a
title, the session's stats grid, the summary (editable in place), blocker and next step if present,
the session's own timeline strip, its interruptions, and its accomplishments.

**Hierarchy:** 1. the intended outcome (`Type.rowTitle`) — this is what the user is scanning for.
2. the result status glyph + word, right-aligned. 3. project · work type · time range · duration, all
`Type.secondary`. Day headings are `Type.sectionTitle` and pinned while scrolling.

A session still `.awaitingReview` shows a `[ Review ]` button in place of the status. This is the
recovery path for "the app quit before I answered".

**Empty state:**

> **No focus sessions yet.**
> Your first one takes about five seconds to start.
> `[ New Focus Session  ⌘N ]`

Search with no matches:

> **Nothing matches "receipt".**
> Try a shorter phrase, or clear the project filter.

**Loading:** three redacted rows under each of two day headings. **Error:** § 3.3 banner.

**Hover:** row fills with `Surface.hover`, `Icon.more` appears trailing, and a disclosure chevron
fades in. **Context menu:** *Open* · *Add accomplishment* `⌘⇧A` · *Edit summary…* · *Copy summary* ·
*Change project ▸* · *Change work type ▸* · *Toggle reactive* · — · *Delete session* (destructive,
confirms; the confirm text names what else goes: "This also deletes the 214 activity records
captured during it.").

---

### 4.3 Accomplishments  `⌘3`

**Primary action:** **Add Accomplishment** `⌘⇧A`.

```
┌─────────────────────────────────────────────────────────────────┐
│  Accomplishments   [ 🔍 ⌘F ] [ All types ⌄ ] [ ⤴ Export ] [ + ] │
│  ───────────────────────────────────────────────────────────── │
│  This week                                                      │
│  ⤴ Opened the receipt deduplication PR                          │
│    ● SOR engineering · Thu 11:04                                │
│  ✓ Unblocked Omar on the ingestion retry                        │
│    ● SOR engineering · Thu 14:20                                │
│  🗎 Documented the new ingestion architecture                    │
│    ● SOR engineering · Wed 16:41                                │
│  ⚑ Resolved duplicate commission ingestion                      │
│    ● Incidents · Tue 09:30                                      │
│                                                                 │
│  Week of 14 July                                                │
│  …                                                              │
└─────────────────────────────────────────────────────────────────┘
```

Grouped by week, then ordered newest first inside the week. The leading glyph is
`AccomplishmentType.symbolName` in `.secondary` — never tinted by type, because eleven tinted glyphs
is a rainbow.

**Hierarchy:** 1. the title. 2. the type glyph. 3. project badge + timestamp.

**Empty state:**

> **Nothing logged yet.**
> This is the list you open on Friday to see what you actually delivered.
> `[ Add Accomplishment  ⌘⇧A ]`

**Loading / error:** standard. **Hover:** row fill + `Icon.more`. **Context menu:** *Edit…* ·
*Copy as Markdown* · *Open source session* (only when `isGeneratedFromSession`) · *Change type ▸* ·
*Change project ▸* · *Link to weekly outcome ▸* · — · *Delete* (destructive, confirms).

---

### 4.4 Weekly Review  `⌘4`

**Primary action:** **Export Review** `⌘⇧E`.

```
┌─────────────────────────────────────────────────────────────────┐
│  Weekly Review    ◀  Week of 21 July  ▶   [ This week ] [ ⤴ ⌘⇧E ]│
│  ───────────────────────────────────────────────────────────── │
│  Primary outcome                                                │
│  Improve receipt ingestion reliability                          │
│  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░  68% · In progress                  │
│  7 sessions · 8h 24m · 2 PRs opened · 3 PRs reviewed            │
│                                                                 │
│  Where the time went                                            │
│  ▐ SOR engineering 31% ▐ Code review 22% ▐ Comms 19% ▐ …  ▌     │
│  ● SOR engineering        8h 24m   31%                          │
│  ● Code review            5h 58m   22%                          │
│  ● Communication          5h 09m   19%                          │
│  ● Incidents              3h 47m   14%                          │
│  ● Planning               2h 26m    9%                          │
│  ● Other                  1h 21m    5%                          │
│                                                                 │
│  Planned vs reactive                                            │
│  ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 62% planned ▐░░░░░░░░░░ 38% reactive ▌       │
│                                                                 │
│  Focus                                                          │
│  18 sessions · 13 completed · 4 interrupted · 96 switches       │
│  Context switches per day                                       │
│  ▁▃▇▂▄  Mon Tue Wed Thu Fri                                     │
│                                                                 │
│  Accomplishments · 11                                           │
│  · Opened the receipt deduplication PR                          │
│  · Resolved duplicate commission ingestion                      │
│  · Reviewed three blocking pull requests                        │
│  … show all                                                     │
│                                                                 │
│  Observations                                                   │
│  Your longest uninterrupted sessions happened before 11:00.     │
│  Slack was the frontmost app at the start of 42% of the         │
│  interruptions you captured.                                    │
│  You spent 5h 09m reviewing and unblocking other engineers.     │
│  The primary outcome received 31% of tracked time.              │
└─────────────────────────────────────────────────────────────────┘
```

**Chart budget: two.** The stacked allocation bar and the context-switches-per-day bar chart. That
is the entire chart allowance for the application. Everything else — including planned vs reactive —
is a two-segment bar drawn with two `Rectangle`s, and everything else again is a number in a
sentence. Swift Charts appears in exactly one file (`Weekly/TimeAllocationChart.swift`).

**Hierarchy:** 1. primary outcome + progress. 2. where the time went. 3. planned vs reactive.
4. focus counts. 5. accomplishments. 6. observations.

**Observations** are plain sentences from `InsightGenerator`: `Type.body`, `.primary`, one per line,
`Space.s` apart, **no bullets, no icons, no colour, no ranking**. They are evidence, and dressing
evidence up as advice is how this screen would start to feel like a performance review. Language is
neutral and past tense; the generator never emits a comparative that implies failure.

**Empty state** (week with no data):

> **Nothing recorded this week.**
> Weekly Review fills in as you track. There's nothing to fix here.

Week with sessions but no weekly outcome set:

> **No outcome set for this week.**
> You can still review the time. Setting one makes the "primary outcome" line meaningful.
> `[ Set weekly outcome ]`

**Loading:** the week header renders immediately; all six sections redact. Aggregation over a week
of activity events is the one place that might exceed 250ms, so the `ProgressView` rule of § 3.2
genuinely applies here.

**Error:** § 3.3 banner with [ Try again ].

**Hover:** allocation legend rows highlight their bar segment to 100% while the rest drop to 55%
(`Motion.tap`). Accomplishment lines get `Surface.hover`. **Context menus:** on an allocation row —
*Show these sessions* (pushes a filtered Focus Sessions list); on an observation — *Copy*; on the
whole screen — *Copy review as Markdown* · *Export review…* `⌘⇧E`.

---

### 4.5 Projects  `⌘5`

**Primary action:** **New Project** `⌘N` (when Projects is the selected section).

```
┌─────────────────────────────────────────────────────────────────┐
│  Projects                                   [ Show inactive ] [+]│
│  ───────────────────────────────────────────────────────────── │
│  ● 🗀 SOR engineering                                            │
│      12 sessions · 8h 24m this week                             │
│  ● 🔧 Incidents                                                  │
│      4 sessions · 3h 47m this week                              │
│  ● 🗀 Mobile support                                             │
│      No sessions this week                                      │
└─────────────────────────────────────────────────────────────────┘

Editor sheet (420 wide):
┌──────────────────────────────────────────┐
│  New Project                             │
│                                          │
│  Name  ┌──────────────────────────────┐  │
│        │ SOR engineering              │  │
│        └──────────────────────────────┘  │
│                                          │
│  Colour  ● ● ● ● ● ● ● ● ●               │
│          blue purple pink red …          │
│                                          │
│  Icon    🗀 🔨 ▣ ▥ 👥 🔧 🛒 ▤ 🖌 📕        │
│                                          │
│  ☑ Active                                │
│                                          │
│  Cancel                    [ Save  ⌘⏎ ]  │
└──────────────────────────────────────────┘
```

**Hierarchy:** 1. project name with its colour dot and icon. 2. this week's usage. 3. the inactive
badge, when shown.

Inactive projects are hidden behind the `Show inactive` toggle and render at `.secondary` with the
word "Inactive" appended. They never disappear from history.

**Empty state:**

> **No projects yet.**
> Projects are optional — you can start a session without one — but they're how the weekly review
> splits your time.
> `[ New Project  ⌘N ]`

**Loading / error:** standard.

**Hover:** row fill, plus an inline `Active` toggle and `Icon.more` on the trailing edge. Colour
swatches in the editor scale their inner checkmark only (no bounce), `Motion.tap`.

**Context menu:** *Edit…* · *Start a session on this project* `⌘N` · *Duplicate* ·
*Mark inactive* / *Mark active* · — · *Delete project* (destructive; the confirm text is exact about
consequences: "Sessions and accomplishments keep their history and lose the project label. Nothing
is deleted." — this mirrors the `.nullify` rules in `03-data-model.md` § 5.1).

---

### 4.6 Rules  `⌘6`

**Primary action:** **New Rule**.

```
┌─────────────────────────────────────────────────────────────────┐
│  Rules                                             [ ⋯ ]  [ + ] │
│  ───────────────────────────────────────────────────────────── │
│  Your rules                                                     │
│  ☑  Window title contains "Pull request"  →  Code review        │
│     Any project · Any work type · Priority 20                   │
│  ☑  Browser domain github.com             →  Code review        │
│     Any project · Any work type · Priority 10                   │
│  ☑  Application name Claude               →  Coding             │
│     SOR engineering only · Priority 30                          │
│                                                                 │
│  Built in                                                       │
│  ☑  Application com.apple.dt.Xcode        →  Coding             │
│  ☑  Application com.tinyspeck.slackmacgap  →  Communication     │
│  ☑  Browser domain youtube.com            →  Distraction        │
│  …                                                              │
└─────────────────────────────────────────────────────────────────┘
```

**Hierarchy:** 1. the rule sentence, read left to right as `When … → Then …`. 2. its scope and
priority, `Type.secondary`. 3. the enabled checkbox.

Built-in rules (`isUserDefined == false`) render at `.secondary` and can be toggled but not edited;
editing one creates a user rule that shadows it (`priority` copied +5) and the original is switched
off. The `⋯` menu holds *Reset built-in rules* and *Reorder by priority*.

**Reclassify flow** (`Rules/ReclassifySheet.swift`, reached from any timeline block's context menu):
after the user picks a new category, a compact sheet offers "Always classify **Slack** as
**Communication**?" with `[ Not now ]` and `[ Create rule ]`. It is offered once per distinct match
value per session, never repeatedly.

**Empty state** (no user rules — built-ins are always present):

> **No rules of your own yet.**
> Lggr ships with sensible defaults. Correct a category on the timeline and it will offer to make
> the correction permanent.

**Loading / error:** standard.

**Hover:** row fill; a drag handle appears on the leading edge for priority reordering (user rules
only). **Context menu:** *Edit…* · *Duplicate* · *Disable* / *Enable* · *Move up* / *Move down* ·
— · *Delete rule* (destructive; built-in rules offer *Reset to default* instead).

---

### 4.7 Settings  `⌘7` (and `⌘,`)

**Primary action:** none — and this is deliberate. Settings is the one screen in Lggr without a
primary button, because its primary action *is* the control the user came here to change. Adding a
`Done` button to an always-live settings pane is theatre. The "one clear thing" on this screen is
the tab you landed on.

```
┌─────────────────────────────────────────────────────────────────┐
│  Settings                                                       │
│  ( General ) ( Tracking ) ( Privacy ) ( Shortcuts ) ( Alerts )   │
│  ───────────────────────────────────────────────────────────── │
│  Sessions                                                       │
│    Default duration            ( 25m ) (•50m) ( Custom  50 ▲▼ ) │
│    Remember the last project                              ☑     │
│                                                                 │
│  System                                                         │
│    Launch at login                                        ☐     │
│    Show the timer in the menu bar                         ☑     │
│    Hide the Dock icon                                     ☐     │
│    Hiding the Dock icon also hides the menu bar commands.       │
│                                                                 │
│  Data                                                           │
│    ~/Library/Application Support/Lggr        [ Show in Finder ] │
│    Keep activity for            ( 30 ) ( 90 ) ( 365 ) ( Forever)│
│                                        [ Delete activity… ]     │
└─────────────────────────────────────────────────────────────────┘
```

Five tabs, all `Form` + `.formStyle(.grouped)`:

| Tab | Contents |
|---|---|
| **General** | Default duration, remember last project, launch at login, show timer in menu bar, hide Dock icon, data location, retention, delete activity. |
| **Tracking** | Pause tracking (master switch), idle threshold, track window titles, read browser domains, Accessibility status + [Open System Settings]. |
| **Privacy** | Excluded applications list, private applications list, both with `[+]`/`[–]` and an application picker. A standing explanation of what is never captured. |
| **Shortcuts** | The global shortcut recorder, plus a read-only reference table of every in-app shortcut (§ 6). |
| **Alerts** | Session completed, halfway reminder, long idle. Each a plain toggle. Notification authorisation status with a single [Allow notifications] button that is never shown again once granted. |

**Empty state:** none — a settings screen with no settings is a bug. The excluded/private
application lists show an inline `.secondary` line instead of a full empty state: "No applications
excluded." / "No applications marked private."

**Loading:** preferences come from `UserDefaults` synchronously (`03-data-model.md` § 7); there is no
loading state.

**Error:** writes to `UserDefaults` do not fail meaningfully. Failures that *do* matter get inline
text next to the control that caused them, `.secondary`, one line: launch-at-login registration
("macOS declined to register Lggr as a login item.") and hot-key registration ("⌘⇧Space is already
taken by another app. Pick a different combination.").

**Hover:** rows in the application lists fill and reveal a trailing `–` button. **Context menu:** on
an application row — *Remove* · *Move to private* / *Move to excluded* · *Show in Finder*.

---

## 5. The four panels

---

### 5.1 The menu bar popover

`.menuBarExtraStyle(.window)`, fixed width **320**, `Space.m` interior padding, height fits content.
`Esc` dismisses. It has two states and one inline replacement mode (§ 5.2, § 5.4).

**Primary action, idle:** **Start Focus Session**.
**Primary action, running:** **Finish**.

**Idle** (`MenuBarIdleView`):

```
┌────────────────────────────────────────┐
│  ▶  Start Focus Session      ⌘⇧Space   │  ← accent-tinted row, Type.rowTitle
│                                        │
│  ⚡ Quick Timer            25m   50m    │
│  ⊕  Add Accomplishment          ⌘⇧A    │
│  ⌁  Capture Interruption        ⌘⇧I    │
│  ────────────────────────────────────  │
│  ☀  Open Today                   ⌘1    │
│  ▥  Open Weekly Review           ⌘4    │
│  ────────────────────────────────────  │
│  Today · 3h 40m focused · 2 sessions   │  ← Type.caption, .secondary, not a button
└────────────────────────────────────────┘
```

The six rows are exactly the six `SPEC.md` § 1 requires, in that order. Row height 28pt, `Radius.chip`
hover fill, symbol in an 18pt frame, shortcut hint right-aligned at `Type.caption` `.tertiary`.
`Quick Timer`'s two durations are inline segments — a quick timer that needs a submenu is not quick.
It starts immediately with the last project, the last work type and an empty outcome, and the
active view's outcome line becomes an inline editable field reading "Add an outcome" so nothing is
lost.

**Running** (`MenuBarActiveView`):

```
┌────────────────────────────────────────┐
│  ● SOR engineering · Deep work         │
│  Finish the receipt deduplication PR   │
│                                        │
│             32:41                      │  ← Type.timerCompact
│             remaining                  │  ← Type.caption, .secondary
│  ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░▌        │  ← 4pt Capsule track + accent fill
│                                        │
│  [   Pause   ]      [   Finish   ⌘⏎ ]  │
│  ────────────────────────────────────  │
│  ⌁  Capture Interruption        ⌘⇧I    │
│  ☀  Open Lggr                    ⌘1    │
└────────────────────────────────────────┘
```

Paused swaps `Pause` → `Resume` (`Icon.resume`), the progress fill drops to `.secondary`, and the
"remaining" caption becomes "paused". Overtime replaces `32:41 / remaining` with
`+4:12 / past 50 minutes`, digits in `Palette.attention`.

**Hierarchy:** 1. the timer. 2. the intended outcome. 3. Finish. 4. project and work type.
5. everything else.

**Empty state:** the idle view *is* the empty state; it never says "no session running".

**Loading:** the popover reads `SessionManager` from memory — instant, no state. The "Today ·
3h 40m focused" footer is the one async value; before it lands it renders as an empty string, not a
spinner. A spinner in a 320pt popover is noise.

**Error:** if the last store read failed, the footer reads "Today's totals are unavailable." at
`Type.caption` `.secondary`. Nothing else in the popover depends on the store.

**Keyboard:** on open, focus lands on the primary row (Start Focus Session / Pause). `↑`/`↓` moves
between rows, `Return` or `Space` activates, `Esc` dismisses. Every row also has its own
`.keyboardShortcut`, so the popover is fully operable without ever moving focus.

**Hover:** row fill `Surface.hover`, `Motion.tap`, `Radius.chip`. **Context menu:** the popover has
none — a context menu inside a popover is a trap. `Quit Lggr` lives in the application menu and, when
the Dock icon is hidden, in the popover's own footer.

---

### 5.2 The session-start panel  `⌘N` / `⌘⇧Space`

`Focus/StartSessionForm.swift`. **One view, two hosts:** 460pt wide as a `.sheet` on the main
window, 320pt wide rendered inline inside the popover (replacing `MenuBarIdleView`, because a
`.menuBarExtraStyle(.window)` popover cannot present a sheet). Layout is identical; only the frame
width differs.

**Primary action:** **Start Focus** `⌘⏎`. This is the most important button in the product.

```
┌──────────────────────────────────────────────────────┐
│  What are you working on?                            │  Type.sectionTitle
│                                                      │
│  ┌────────────────────────────────────────────────┐  │
│  │ Finish the receipt deduplication PR            │  │  Type.outcome, focused on open
│  └────────────────────────────────────────────────┘  │
│    Recent                                            │  appears while the field is focused
│    ↳ Finish the receipt deduplication PR             │  and the query matches ≥1 recent
│    ↳ Review the ingestion retry design               │
│                                                      │
│  ● SOR engineering  ⌄        🧠 Deep work  ⌄         │
│                                                      │
│  ( 25m ) (● 50m ) ( Custom ) ( Open-ended )          │
│                                                      │
│  ⌄ Link to a weekly outcome                          │  collapsed; only shown if outcomes exist
│                                                      │
│  Start without timer  ⌘⌥⏎          [ Start Focus ⌘⏎ ]│
└──────────────────────────────────────────────────────┘
```

**Hierarchy:** 1. the outcome field — it is `Type.outcome` (17pt) while every other field is 13pt,
because it is the only required one. 2. Start Focus. 3. project and work type. 4. duration.
5. the optional weekly-outcome link, which is collapsed by default (progressive disclosure).

**Intelligent defaults** (`SPEC.md` § 2, made exact):

| Field | Default |
|---|---|
| Project | `preferences.lastSelectedProjectID`; if it is missing or inactive, the most recently used active project; if there are none, "No project". |
| Work type | The work type of the user's most recent session; `.deepWork` on first run. |
| Duration | `workType.suggestedDuration` — 50m for deep work / code review / incident / planning, 25m for communication / administrative / management / meeting (`03-data-model.md` § 1). |
| Outcome | Empty. Never prefilled — a prefilled intent is not an intent. |

**The one rule that makes the defaults feel intelligent instead of annoying:** the panel keeps a
`durationWasEdited` flag. Changing the work type re-applies `suggestedDuration` **only while that
flag is false**. Once the user touches the duration control, the app stops moving it.

**Keyboard focus order** — this is the mouse-free path and it is exact:

```
open ──▶ ① Outcome field  (@FocusState, .defaultFocus, text selected if prefilled)
          │  ⏎  → start immediately (this is the five-second path)
          │  ↓  → move into the Recent list; ↑/↓ to browse; ⏎ accepts and returns focus to the field
          │  ⎋  → if Recent is open, close it; otherwise cancel the panel
          ⇥
         ② Project menu    ␣ or ↓ opens · type-to-select · ⏎ commits · ⎋ closes
          ⇥
         ③ Work type menu  same behaviour
          ⇥
         ④ Duration segments  ←/→ change the selection · ␣ commits
          ⇥ (only when Custom is selected)
         ⑤ Minutes stepper  ↑/↓ by 5 · type a number directly
          ⇥ (only when at least one weekly outcome exists this week)
         ⑥ Link to a weekly outcome  ␣ expands, then the menu behaves like ②
          ⇥
         ⑦ Start without timer   ␣ or ⏎ activates
          ⇥
         ⑧ Start Focus           ␣ or ⏎ activates
          ⇥ wraps back to ①
```

`⌘⏎` starts from anywhere in the panel, including from inside a menu. `⌘⌥⏎` starts without a timer
(`plannedDuration = nil`). `⎋` cancels and discards.

Tab-to-move requires the system's "Keyboard navigation" setting to include all controls, which we
cannot rely on. Therefore **every step above is also reachable without Tab**: the outcome field is
focused on open, `⏎` alone completes the flow, and the panel installs its own `@FocusState` chain so
`⇥` works within the panel regardless of the system setting.

**Validation:** `Start Focus` is disabled while the trimmed outcome is empty — reduced opacity, no
red, no error text. If `⌘⏎` is pressed anyway, focus returns to the outcome field and a single
`Type.caption` `.secondary` line appears beneath it: "Add an outcome to start." It disappears on the
first keystroke. Nothing shakes.

**Empty states inside the panel:**

- No projects: the project menu reads "No project" and its menu contains a single item,
  "New Project…", which opens the project editor as a nested sheet and returns. Starting with no
  project is fully supported and is not flagged.
- No recent outcomes: the Recent list simply does not render. No "no suggestions" message.
- No weekly outcomes: the "Link to a weekly outcome" row is absent, not disabled.

**Loading:** the panel opens instantly with defaults from `UserPreferences` (synchronous). Projects
and recent outcomes arrive from the store within a frame or two; while they are missing, the project
menu shows the remembered project's name from preferences and the Recent list is absent. **The panel
is never blocked on I/O.** That is what makes five seconds achievable.

**Error:** if the store cannot be read, the panel still starts sessions — `SessionManager` holds the
session in memory and the write is retried on the next flush. A `Type.caption` `.secondary` line sits
above the buttons: "Projects couldn't be loaded. You can still start a session." Losing the ability
to start a session because a file is locked would be indefensible.

**Hover:** menus and segments take `Surface.hover`; Recent rows take `Surface.hover` and are also
navigable by keyboard, with the keyboard-highlighted row using `Surface.selected` so the two never
disagree. **Context menu:** none. A start panel with a context menu is a start panel that got away
from us.

---

### 5.3 The session-completion review sheet

`Review/SessionReviewSheet.swift`. Presented as a `.sheet` on the main window, 520pt wide. Triggered
by Finish, by the completion notification, or by a `[ Review ]` button on an `.awaitingReview`
session.

**Primary action:** **Save** `⌘⏎`.

```
┌────────────────────────────────────────────────────────────┐
│  What happened?                                            │
│  Finish the receipt deduplication PR                       │  Type.outcome
│  ● SOR engineering · Deep work · 9:00–9:52                 │  Type.secondary
│                                                            │
│  ( ✓ Completed ) ( ↷ Made progress ) ( ✋ Blocked )         │
│  ( ⌁ Interrupted ) ( ⑂ Reprioritized )                     │
│                                                            │
│  52m active · 47m focused · 5m idle · 6 switches · 1 int.  │
│  Xcode 31m · Terminal 9m · Slack 7m · GitHub 5m            │
│                                                            │
│  Summary                                    ⟳ Regenerate ⌘R│
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Worked primarily in Xcode and Terminal on receipt    │  │
│  │ deduplication. Reviewed one GitHub pull request and  │  │
│  │ spent seven minutes in Slack.                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                            │
│  ▸ Add result, blocker or next step                        │
│                                                            │
│  Not now            [ Log accomplishment ]   [ Save  ⌘⏎ ]  │
└────────────────────────────────────────────────────────────┘
```

**Hierarchy:** 1. the five result options — this is the only required field. 2. the outcome being
judged. 3. the generated summary. 4. the statistics. 5. the optional fields.

**Interaction detail:**

- The five options are focused first. `←`/`→` moves, `Space` selects, and pressing **`1`–`5`**
  selects directly. Answer-and-Return finishes the sheet in two keystrokes.
- `Save` is disabled until a status is chosen. Same treatment as § 5.2: opacity, no red.
- When the chosen status has `needsFollowUp == true` (`03-data-model.md` § 1), the disclosure
  auto-expands with the relevant field focused — **Blocked** → *Blocker*, **Interrupted** and
  **Reprioritized** → *Next step*. No colour change, no warning icon, no "are you sure". The app
  asks a useful follow-up question and moves on.
- The summary is fully editable; `⌘R` regenerates from `SessionSummaryBuilder`, and regenerating
  after an edit asks nothing — the previous text is restorable with `⌘Z` because it is a normal
  `TextEditor`.
- `Log accomplishment` opens `AddAccomplishmentSheet` prefilled with the outcome as the title, the
  session's project, and a type guessed from the session's dominant category. On save it returns and
  saves both records.
- **`Esc` and `Not now` do not discard the session.** They leave it `.awaitingReview`: the menu bar
  symbol becomes `questionmark.circle`, the Today row and the Focus Sessions row grow a `[ Review ]`
  button. A finished session is never lost because a sheet was dismissed.

**Empty / degraded states:** with no activity data (Accessibility denied, or tracking paused), the
statistics line collapses to `52m active` and the application list is replaced by one
`Type.caption` `.secondary` line: "No application activity was recorded for this session." The
generated summary falls back to the deterministic outcome-only form: "Worked on receipt
deduplication for 52 minutes." Everything else is unchanged.

**Loading:** the sheet opens instantly with the session, the status picker and the fallback summary.
Statistics and the richer generated summary land when `ActivityAggregator` finishes; until then those
two blocks are redacted. **The user can answer and save before the statistics arrive** — the answer
is what matters and it is never gated on aggregation.

**Error:** a failed save is the one case in the app that gets an `Alert` (§ 3.3), because the user's
typed summary is at risk: "Couldn't save this session." / "Try again, or copy the summary so you
don't lose it." / `[ Copy summary ]` `[ Try again ]`. The sheet stays open.

**Hover:** the application-time chips highlight and offer a tooltip with the exact duration. **Context
menu** on the summary editor: the standard text-editing menu plus *Regenerate* `⌘R` and
*Copy as Markdown*.

---

### 5.4 The interruption capture field  `⌘⇧I`

`Focus/InterruptionCaptureSheet.swift`. **Primary action:** **Save** `⌘⏎`.

Two hosts, again the same view: a 420pt `.sheet` from the main window, and an inline replacement of
the popover body when triggered from the menu bar.

```
┌────────────────────────────────────────────┐
│  What came up?                             │
│  ┌──────────────────────────────────────┐  │
│  │ Review Omar's blocked PR             │  │  focused on open
│  └──────────────────────────────────────┘  │
│  From  Other ⌄                             │  appears after the first character
│                                            │
│  Cancel                     [ Save  ⌘⏎ ]   │
└────────────────────────────────────────────┘
```

Everything about this is designed around one fact: **the session keeps running.** So:

- **No timer is shown here.** Showing the clock while capturing an interruption invites the user to
  end the session, which is the exact opposite of the intent.
- One field. The `From` menu (`InterruptionSource`, eight cases) is collapsed to a single menu
  defaulting to `.other`, and it does not appear until the user has typed a character. Eight chips on
  screen before the user has typed anything is a form; one menu after they have is a refinement.
- `⏎` in the field saves (`.onSubmit`). `⌘⏎` saves from anywhere. `Esc` cancels and discards.
- On save the panel dismisses immediately with `Motion.settle`. **There is no toast.** The Today
  interruption count increments and the popover's inbox row updates; that is the confirmation.
  Interruption capture must cost less attention than the interruption did.
- `interruptionCount` on the running `FocusSession` increments (`03-data-model.md` § 2.3), and the
  new `Interruption` carries `focusSessionID`.
- Captured with no session running, it saves with `focusSessionID == nil` and still lands in the
  inbox. `⌘⇧I` is never unavailable.

**Empty state:** none — it is a single empty field by definition. Save is disabled while the trimmed
note is empty.

**Loading:** none. Nothing is read.

**Error:** if the write fails, the panel stays open with one `Type.caption` `.secondary` line above
the buttons: "Couldn't save that yet — try again." The text is never cleared.

**Hover / context menu:** standard text-field behaviour only.

---

### 5.5 Onboarding

`Views/Onboarding/`. A 640 × 460 `Window` scene shown once, gated on
`preferences.hasCompletedOnboarding`. Not a sheet — it is the first thing the user sees, and it
should own the screen rather than hover over an empty app.

Four pages. **Each page has exactly one primary action.** A `Skip setup` link sits bottom-left on
every page and sets `hasCompletedOnboarding = true` immediately.

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│                          ⏱                                   │
│                                                              │
│              Lggr keeps a quiet record of your work.         │
│                                                              │
│    Start a focus session, say what you intend to do, and     │
│    Lggr reconstructs where the time actually went. Nothing   │
│    leaves this Mac.                                          │
│                                                              │
│                                                              │
│  Skip setup                ● ○ ○ ○              [ Continue ] │
└──────────────────────────────────────────────────────────────┘

Page 2 — Privacy                     Page 3 — Accessibility
┌────────────────────────────┐       ┌────────────────────────────┐
│ What Lggr records          │       │            ♿              │
│                            │       │                            │
│ Recorded      Never        │       │ One optional permission    │
│ ─────────     ─────────    │       │                            │
│ App name      Keystrokes   │       │ macOS Accessibility lets   │
│ Bundle ID     Passwords    │       │ Lggr read the title of the │
│ Window title* Screenshots  │       │ frontmost window, which is │
│ Browser host* Documents    │       │ the difference between     │
│ Idle periods  Messages     │       │ "Chrome, 42 minutes" and   │
│ App switches  Clipboard    │       │ "reviewed three PRs".      │
│                            │       │                            │
│ * off until you turn it on │       │ Everything else works      │
│                            │       │ without it.                │
│ Skip  ○ ● ○ ○  [Continue]  │       │ Skip ○○●○ [Not now][Open   │
└────────────────────────────┘       │            System Settings]│
                                     └────────────────────────────┘

Page 4 — First project and shortcut
┌──────────────────────────────────────────────────────────────┐
│  One project and one shortcut, and you're done.              │
│                                                              │
│  Project  ┌──────────────────────┐  ● ● ● ● ● ● ● ● ●        │
│           │ Work                 │                           │
│           └──────────────────────┘                           │
│                                                              │
│  Start a session from anywhere    [  ⌘⇧Space  ]  Record…     │
│                                                              │
│  Skip setup                ○ ○ ○ ●     [ Start using Lggr ]  │
└──────────────────────────────────────────────────────────────┘
```

**Hierarchy per page:** 1. the single sentence that is the point of the page. 2. the primary button.
3. the supporting detail. The symbol is decorative and `.tertiary`.

**Page 3 is the permissions page and it obeys one rule: we ask once.** `[ Not now ]` is a first-class
button of equal visual weight to `[ Open System Settings ]`. If the user declines, Lggr never asks
again from onboarding, never shows a banner about it, and never degrades a screen into a permission
prompt. The only other time Accessibility is requested in the app's entire life is if the user
switches *Track window titles* on in Settings. That is two prompts, ever
(`02-architecture.md` § 7.7).

**Progress** is four 6pt dots. No numbers, no percentage, no "Step 2 of 4". A four-page flow that
needs a progress bar is too long.

**Empty state:** not applicable. **Loading:** not applicable — everything is local and synchronous.

**Error:** page 4's shortcut recorder is the only failure point: if `RegisterEventHotKey` reports the
combination is taken, an inline `Type.caption` `.secondary` line appears — "⌘⇧Space is already taken
by another app. Pick a different combination." — and `[ Start using Lggr ]` remains enabled, because
a hot-key conflict must not block onboarding. Project creation failing shows the same inline
treatment and still lets the user through; they can create a project later.

**Hover:** colour swatches and buttons only, `Motion.tap`. **Context menu:** none.

**Keyboard:** `⏎` = the primary button on every page. `⇧⇥`/`⇥` moves. `Esc` on any page is
equivalent to `Skip setup` and asks nothing. Onboarding you cannot escape from is a dark pattern.

---

## 6. Menu bar icon states

The label is `Views/MenuBar/MenuBarLabel.swift`, driven by `MenuBarManager.labelState`.

```swift
struct MenuBarLabel: View {
    let state: MenuBarLabelState
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: state.symbolName)
            if let text = state.timeText {
                Text(text)
                    .font(Type.menuBarTimer)
                    .foregroundStyle(state.isPaused ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(.primary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lggr")
        .accessibilityValue(state.spokenValue)
    }
}
```

### 6.1 The four states

| State | SF Symbol | Trailing text | Notes |
|---|---|---|---|
| **Idle** — no session | `timer` | *(none)* | Symbol only. No dot, no badge, no colour. Indistinguishable in weight from any system menu extra. |
| **Running** — countdown | `timer` | `32:41` | Same symbol as idle. The *presence of digits* is the state change, not a different glyph. This is the subtlety mechanism. |
| **Running** — open-ended | `timer` | `1:12:04` | Counts up. |
| **Paused** | `pause.circle` | `32:41` | Digits frozen and rendered `.secondary`. The symbol carries the meaning; the dimmed digits confirm it. |
| **Overtime** | `timer` | `+4:12` | Digits in `Palette.attention`. Still `timer` — overtime is a display sub-state of `.running`, not a new lifecycle state. |
| **Awaiting review** | `questionmark.circle` | *(none)* | The session ended and has no `resultStatus`. Clicking opens the popover with `Review last session` as the top row. |

The first four symbols are `SessionState.symbolName` from `03-data-model.md` § 1, used verbatim.
`SessionState.completed`'s `checkmark.circle` is never shown in the menu bar — a completed, reviewed
session returns the label to **Idle**. A permanent checkmark would be a reward, and rewards are
gamification.

### 6.2 Exact title format for the running timer

`DurationFormatting.menuBarString(_:)` in `LggrKit`, unit-tested:

| Condition | Format | Examples |
|---|---|---|
| `< 1 hour` | `m:ss`, **no** leading zero on minutes | `0:07`, `9:07`, `32:41` |
| `>= 1 hour` | `H:mm:ss` | `1:02:00`, `1:12:04` |
| Overtime | `+` prefix, same rules as above | `+0:31`, `+4:12`, `+1:02:00` |
| `showTimerInMenuBar == false` | *(no text in any state)* | symbol only |

Countdown shows `remaining(at:)`; open-ended shows `elapsed(at:)`; overtime shows `overrun(at:)`.
All three come from `FocusSession` (`03-data-model.md` § 3.4).

### 6.3 How it stays subtle

Seven specific decisions, each of which prevents a real failure mode:

1. **`.monospacedDigit()`** — the label's width is stable between `10:00` and `59:59`, so the menu
   bar does not reflow every second. This is the single biggest contributor to "subtle".
2. **`.rounded` at 12pt regular** — visually the same weight as the system clock sitting a few
   pixels to the right.
3. **The symbol does not change between idle and running.** Only the digits appear.
4. **No colour** except the overtime digits, and those are ~5 characters of orange.
5. **No animation, ever.** No content transition, no fade, no pulse. The label redraws once per
   second at `tolerance: 0.15` and that is all it does.
6. **No project name, no outcome text.** The menu bar is visible in every screen share and every
   over-the-shoulder glance. "Finish the receipt deduplication PR" is nobody else's business.
   Context lives in the popover, one click away.
7. **The `TickTimer` only exists while a session runs** (`02-architecture.md` § 6.2). Idle Lggr does
   zero work per second.

### 6.4 VoiceOver

`accessibilityLabel` is always `"Lggr"`. `accessibilityValue` is built by
`DurationFormatting.spokenDuration(_:)`:

| State | Spoken value |
|---|---|
| Idle | "No focus session running" |
| Running | "Focus session running, 32 minutes 41 seconds remaining, SOR engineering" |
| Running, open-ended | "Focus session running, 1 hour 12 minutes elapsed, SOR engineering" |
| Paused | "Focus session paused, 32 minutes 41 seconds remaining" |
| Overtime | "Focus session running, 4 minutes 12 seconds past the planned 50 minutes" |
| Awaiting review | "A finished focus session is waiting for your review" |

The project name is spoken because VoiceOver output is private to the user, unlike the visible label.

---

## 7. Keyboard map

### 7.1 The complete map

**System-wide**

| Shortcut | Action |
|---|---|
| `⌘⇧Space` | Start a focus session. Configurable in Settings → Shortcuts. Activates Lggr, opens the popover, shows the start panel inline. Does not open the main window. |

**Application-wide** — implemented as real menu commands in `App/AppCommands.swift`, so they work
from any window and are discoverable in the menu bar.

| Shortcut | Menu item | Action |
|---|---|---|
| `⌘N` | File → New Focus Session | Opens the start panel as a sheet on the main window (opening the window first if needed). In Projects, `⌘N` is New Project. |
| `⌘⇧N` | File → New Project | Opens the project editor. |
| `⌘⏎` | Session → *(retitles)* | **Contextual.** "Start Focus" while the start panel is open; "Save Review" while the review sheet is open; "Finish Session" while a session runs and nothing is presented. One item, one shortcut, three titles — this is how `SPEC.md`'s "⌘Return: Start or confirm" is honoured without collisions. |
| `⌘⌥⏎` | Session → Start Without Timer | Starts with `plannedDuration == nil`. |
| `Space` | Session → Pause / Resume | Only when the Active Session card holds keyboard focus and no text field is editing. Retitles between Pause and Resume. |
| `⌘⇧I` | Session → Capture Interruption | Always available, session or not. |
| `⌘⇧A` | File → Add Accomplishment | Always available. |
| `⌘1`–`⌘7` | View → *(section names)* | Selects the sidebar section; opens the main window if it is closed. |
| `⌘,` | Lggr → Settings | Opens the Settings scene. |
| `⌘F` | Edit → Find | Focuses the search field on Focus Sessions and Accomplishments. |
| `⌘⇧E` | File → Export… | Exports the current screen (Today → daily Markdown, Weekly Review → weekly Markdown, Accomplishments → log Markdown, Focus Sessions → CSV). |
| `⌘R` | Session → Regenerate Summary | Only inside the review sheet. |
| `⌘W` | Window → Close | Closes the window. Does not quit. |
| `⌘Q` | Lggr → Quit | Quits. A running session is restored on next launch. |
| `Esc` | — | Closes the frontmost popover, sheet or panel. Never destroys a finished session (§ 5.3). |
| `⌘.` | — | Dismisses the error banner. |

**Contextual, within a screen or panel**

| Shortcut | Where | Action |
|---|---|---|
| `⇥` / `⇧⇥` | Every panel | Moves through the panel's own `@FocusState` chain. |
| `↑` / `↓` | Sidebar, lists, popover rows, Recent list | Moves selection. |
| `←` / `→` | Segmented controls, timeline strip, week stepper | Changes value / block / week. |
| `⏎` | Outcome field, interruption field | Submits — the whole reason the flow is five seconds. |
| `1`–`5` | Review sheet | Selects the result status directly. |
| `⌘⌫` | Any list with a selection | Deletes the selected row after confirmation. |
| `⌘Z` / `⌘⇧Z` | Summary editor, all text fields | Standard text undo. Available because `LSUIElement` is `false` and the Edit menu exists. |

### 7.2 Making mouse-free real, not aspirational

Four things beyond the table, each of which is a real gap otherwise:

1. **`⌘⏎` retitles rather than collides.** The alternative — three different shortcuts for start,
   finish and save — is what makes keyboard-first apps unlearnable.
2. **Tab is not load-bearing.** macOS ships with keyboard navigation limited to text boxes and lists
   unless the user changes a system setting. Every panel therefore installs an explicit
   `@FocusState` chain plus `.defaultFocus`, and every flow can be completed with `⏎` and arrow keys
   alone. We never tell the user to go change a System Settings toggle.
3. **The popover is keyboard-complete.** It opens with focus on its primary row; `↑`/`↓` moves;
   every row additionally carries its own `.keyboardShortcut`, so the user can act without
   navigating at all.
4. **Shortcuts are discoverable in two places** — the application menu bar (which exists because
   `LSUIElement` is `false`) and a read-only reference table in Settings → Shortcuts. There is no
   cheat-sheet overlay and no `?` key modal; a Mac app's shortcuts belong in its menus.

---

## 8. Accessibility

### 8.1 Contrast

- All text is `.primary`, `.secondary` or `.tertiary`, which the system guarantees against
  `.windowBackgroundColor` in both appearances. `.quaternary` is used for shapes only, never text.
- The hero timer is `.primary` on `Surface.raised` — roughly 15:1. Body text on the same surface
  clears 4.5:1 in both modes; `Type.secondary` at 11pt clears 4.5:1 because `.secondary` on macOS is
  a ~60% alpha over a high-contrast base, not a light grey literal.
- Disabled controls use the system's disabled rendering. We never fake "disabled" with custom low
  opacity on text.
- The user's system accent is respected; we never assume blue, and never place text on an accent
  fill except in `PrimaryButtonStyle`, where the foreground is `Color.white` over the accent's own
  guaranteed-contrast fill (the same treatment as a native `.borderedProminent` button).
- **Colour is never the only signal.** Project colour always sits next to the project name; result
  status always shows a glyph *and* the word; overtime shows a `+` sign as well as orange; the
  allocation bar has a labelled legend.
- Under **Increase contrast**, `Stroke.card` and `Surface.hover` step up as specified in § 2.7, and
  the timeline's idle blocks go from 40% to 65% opacity.

### 8.2 VoiceOver

| Element | Label | Value / hint |
|---|---|---|
| Hero timer | "Time remaining" (or "Time elapsed" when open-ended, "Time past plan" in overtime) | `DurationFormatting.spokenDuration` → "32 minutes 41 seconds". Trait `.updatesFrequently`. **We never post an `AccessibilityNotification.Announcement` on a tick** — only once, at session completion. |
| Progress ring | "Session progress" | "65 percent" |
| Menu bar item | "Lggr" | § 6.4 |
| `MetricTile` | `.accessibilityElement(children: .combine)` | Reads "Focused, 3 hours 40 minutes" as one element. |
| Day timeline strip | "Activity timeline for Thursday 24 July" | One container element with `.accessibilityChildren`, each block labelled "9:00 to 9:52, receipt deduplication, Xcode, Terminal, GitHub, completed". |
| Allocation bar | — | `.accessibilityRepresentation` of a plain `List` of "SOR engineering, 31 percent". A chart is never exposed as a chart. |
| Icon-only buttons | Explicit `.accessibilityLabel` — "More actions", "Regenerate summary", "Previous week" | — |
| Project colour swatch | The colour's name — "Teal" | `.isSelected` trait when chosen |
| Result status option | The `displayName` | `.isSelected` trait |
| Error banner | "Error" | The message text; the recovery buttons are separate elements. |

Every screen sets `.accessibilityLabel` on its detail-column root so VoiceOver's rotor lists the
seven sections by name.

### 8.3 Dynamic Type

- Every font in § 2.1 derives from a text style, so all of them scale. The one fixed size — the hero
  timer — uses `@ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 72`.
- **No fixed row heights anywhere.** Rows are padding plus content, with
  `.fixedSize(horizontal: false, vertical: true)` on any multi-line text.
- `ViewThatFits` handles the three layouts that break first:
  - Today's five `MetricTile`s → 5 across → 3 + 2 → a vertical list.
  - The start panel's button row → side by side → `Start without timer` above `Start Focus`.
  - The review sheet's five status options → 3 + 2 → one per line.
- **Truncation policy:** the intended outcome never truncates — it wraps to at most three lines and
  the container grows. Project names truncate `.middle`. Application names in a statistics line
  truncate `.tail`. Nothing else truncates.
- The sidebar's minimum width of 180 is sized for "Accomplishments" at the default size; at larger
  sizes the sidebar can be dragged wider and the labels wrap to two lines rather than truncating.

### 8.4 Reduce Motion

`@Environment(\.accessibilityReduceMotion)`, funnelled through the single `.lggrAnimation` modifier
in § 2.8, so there is one place to audit.

| Normally | Under Reduce Motion |
|---|---|
| `Motion.reveal` spring | 0.1s ease-in-out |
| `Motion.settle` | 0.1s ease-in-out |
| `Motion.ring` linear interpolation | discrete update per tick, no interpolation |
| `.contentTransition(.numericText())` on the hero timer | `.identity` |
| Disclosure expansion | instant |
| Any `.scaleEffect` | *(there are none — § 2.8)* |
| Any repeating animation | *(there are none — § 2.8)* |

Sheet and window presentation animations belong to the system and already honour the setting; we do
not override them.

### 8.5 Reduce Transparency

`NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` → the floating session strip's
`.thinMaterial` becomes `Surface.raised`. That is the only material we own; the popover and sidebar
materials are the system's and adapt on their own.

### 8.6 Full keyboard navigation

§ 7 is the map; the guarantees are:

- Every action reachable by mouse is reachable by keyboard.
- Every panel focuses its primary field or button on open, via `.defaultFocus` + `@FocusState`.
- Focus rings are the system's. We never set `.focusEffectDisabled()`.
- Focus order matches visual order in every panel (§ 5.2 documents the start panel's chain
  explicitly because it is the one that matters most).
- The keyboard-highlighted row and the hover-highlighted row use different fills
  (`Surface.selected` vs `Surface.hover`) so the two inputs never contradict each other on screen.
- No flow depends on the system's "Keyboard navigation: all controls" setting being enabled.

---

## 9. What we deliberately avoid

Mapped to `SPEC.md` § Design direction. Listed so that no later phase adds them back "for
engagement".

| We do not build | Because |
|---|---|
| **Streaks, badges, levels, XP, confetti** | The product's claim is that it reconstructs your work honestly. A streak makes the user optimise for the streak. |
| **A productivity score** | There is no number that summarises a week of knowledge work, and inventing one turns the weekly review into a performance review. |
| **Shaming copy** | These words never appear in Lggr: *wasted, distracted, failed, behind, only, should have, missed, unproductive*. Observations are past tense and neutral. |
| **Red as an information colour** | Red exists in exactly one place: the confirm button of a delete alert. Blocked sessions, distraction time and at-risk outcomes are never red. |
| **Gradients** | Zero gradients. Not on buttons, not on cards, not on charts, not behind the timer. (The single exception is the linear mask that fades the timeline strip at its scroll edges, which is a mask, not a fill.) |
| **Cards everywhere** | Exactly one card on Today, one in the popover. A card means "this container has its own primary action". Everything else is a headed list on the bare canvas. |
| **Dashboard clutter** | Hard budget: at most 5 metrics on Today, at most 2 charts in the entire application, both on Weekly Review, zero charts on every other screen. |
| **Unnecessary charts** | Planned-vs-reactive is two rectangles. Time by category is one stacked bar. If a number reads better as a sentence, it is a sentence. |
| **Tiny text** | Nothing below 10pt exists, and nothing a user *must* read is below 11pt. `Type.caption` is for axis labels and shortcut hints. |
| **Modal dialogs for common actions** | Start, capture, add and review are panels and sheets that `Esc` dismisses with no loss. Alerts appear for exactly two reasons: unsaveable input, and destructive confirmation. |
| **Toasts, snackbars and "Saved!" banners** | The result of an action is visible in the data. Interruption capture increments a count; that is the receipt. |
| **Coach marks, tooltips-on-first-run, "Did you know?"** | Onboarding is four pages and then it is over. |
| **Repeated permission prompts** | Accessibility is requested at most twice in the application's lifetime (`02-architecture.md` § 7.7). |
| **Emoji and exclamation marks in UI copy** | Not one, anywhere. |
| **Empty-state illustrations** | One SF Symbol, two lines of text, at most one button. |
| **Generic web-app styling** | No custom shadows, no hand-mixed greys, no 4pt-radius rectangles pretending to be Material Design, no all-caps tracked-out labels. |
| **Notifications that interrupt to say nothing** | Four kinds, all optional, all configurable, none of them repeating (`SPEC.md` § Notifications). |

---

## 10. Exact user-facing copy — Phase 2

Every string the Phase 2 vertical slice renders. Concise, natural, no exclamation marks, no corporate
voice. English strings are written inline; there is no localisation catalogue in the MVP
(`02-architecture.md` § 8).

### 10.1 Navigation and chrome

| Key | String |
|---|---|
| Sidebar rows | `Today` · `Focus Sessions` · `Accomplishments` · `Weekly Review` · `Projects` · `Rules` · `Settings` |
| Window title | `Lggr` |
| Today header date | `Thursday 24 July` (`.dateTime.weekday(.wide).day().month(.wide)`) |

### 10.2 Menu bar popover

| Key | String |
|---|---|
| Idle primary row | `Start Focus Session` |
| Quick timer row | `Quick Timer` |
| Add accomplishment row | `Add Accomplishment` |
| Capture interruption row | `Capture Interruption` |
| Open today row | `Open Today` |
| Open weekly review row | `Open Weekly Review` |
| Idle footer, with data | `Today · 3h 40m focused · 2 sessions` |
| Idle footer, nothing yet | `Nothing tracked yet today` |
| Idle footer, store error | `Today's totals are unavailable` |
| Active: remaining caption | `remaining` |
| Active: elapsed caption (open-ended) | `elapsed` |
| Active: paused caption | `paused` |
| Active: overtime caption | `past 50 minutes` (the planned duration, formatted) |
| Pause / Resume buttons | `Pause` · `Resume` |
| Finish button | `Finish` |
| Open the app row | `Open Lggr` |
| Awaiting-review top row | `Review last session` |

### 10.3 Start panel

| Key | String |
|---|---|
| Title | `What are you working on?` |
| Outcome placeholder | `Finish the receipt deduplication PR` |
| Recent list heading | `Recent` |
| No-project menu label | `No project` |
| New project menu item | `New Project…` |
| Duration segments | `25m` · `50m` · `Custom` · `Open-ended` |
| Custom minutes suffix | `minutes` |
| Weekly outcome disclosure | `Link to a weekly outcome` |
| Primary button | `Start Focus` |
| Secondary button | `Start without timer` |
| Empty-outcome hint | `Add an outcome to start.` |
| Store-unavailable note | `Projects couldn't be loaded. You can still start a session.` |

### 10.4 Active session

| Key | String |
|---|---|
| Remaining label | `remaining` |
| Elapsed label | `elapsed` |
| Overtime label | `past 50 minutes` |
| Paused label | `paused` |
| Buttons | `Pause` · `Resume` · `Finish` · `Capture` |
| Live activity line | `Xcode · 4 switches · 1 interruption` |
| Live activity, no data | `No activity recorded yet` |
| Quick-timer outcome placeholder | `Add an outcome` |

### 10.5 Review sheet

| Key | String |
|---|---|
| Title | `What happened?` |
| Status options | `Completed` · `Made progress` · `Blocked` · `Interrupted` · `Reprioritized` |
| Stats line | `52m active · 47m focused · 5m idle · 6 switches · 1 interruption` |
| Stats, no activity data | `No application activity was recorded for this session.` |
| Summary heading | `Summary` |
| Regenerate button | `Regenerate` |
| Disclosure | `Add result, blocker or next step` |
| Field labels | `Tangible result` · `Blocker` · `Next step` |
| Field placeholders | `What exists now that didn't before?` · `What's in the way?` · `What's the next concrete step?` |
| Buttons | `Save` · `Log accomplishment` · `Not now` |
| Save failure alert title | `Couldn't save this session.` |
| Save failure alert body | `Try again, or copy the summary so you don't lose it.` |
| Save failure buttons | `Copy summary` · `Try again` |

### 10.6 Interruption capture

| Key | String |
|---|---|
| Title | `What came up?` |
| Placeholder | `Review Omar's blocked PR` |
| Source label | `From` |
| Buttons | `Save` · `Cancel` |
| Save failure | `Couldn't save that yet — try again.` |

### 10.7 Add accomplishment

| Key | String |
|---|---|
| Title (manual) | `Add an accomplishment` |
| Title (from session) | `Log what you delivered` |
| Field labels | `What happened` · `Type` · `Project` · `Details` |
| Details placeholder | `Optional` |
| Buttons | `Save` · `Cancel` |

### 10.8 Today

| Key | String |
|---|---|
| Section headings | `Working toward` · `Accomplishments` · `Time allocation` · `Day` · `Interruptions` |
| Metric labels | `tracked` · `focused` · `reactive` · `sessions` · `switches` |
| Add accomplishment button | `Add` |
| Empty — nothing today | **`Nothing tracked yet today.`** / `Start a session and this fills itself in.` / `Start Focus` |
| Empty — no accomplishments | **`No accomplishments logged today.`** / `Add one when something ships, or let a finished session suggest it.` / `Add` |
| Empty — tracking paused | **`Tracking is paused.`** / `Sessions and accomplishments still record; application activity does not.` / `Resume tracking` |
| Titles-off note | `Window titles are off, so blocks are grouped by application.` |
| Load error banner | `Couldn't load today. Your work is still on disk.` / `Try again` · `Show in Finder` |

### 10.9 Projects

| Key | String |
|---|---|
| Editor titles | `New Project` · `Edit Project` |
| Field labels | `Name` · `Colour` · `Icon` · `Active` |
| Name placeholder | `SOR engineering` |
| Usage line | `12 sessions · 8h 24m this week` |
| Usage line, none | `No sessions this week` |
| Inactive tag | `Inactive` |
| Show inactive toggle | `Show inactive` |
| Empty state | **`No projects yet.`** / `Projects are optional — you can start a session without one — but they're how the weekly review splits your time.` / `New Project` |
| Delete confirm title | `Delete "SOR engineering"?` |
| Delete confirm body | `Sessions and accomplishments keep their history and lose the project label. Nothing is deleted.` |
| Delete confirm buttons | `Cancel` · `Delete Project` |

### 10.10 Focus Sessions

| Key | String |
|---|---|
| Search placeholder | `Search outcomes` |
| Project filter | `All projects` |
| Review button | `Review` |
| Day headings | `Today` · `Yesterday` · `Tuesday 22 July` |
| Empty state | **`No focus sessions yet.`** / `Your first one takes about five seconds to start.` / `New Focus Session` |
| No search results | **`Nothing matches "receipt".`** / `Try a shorter phrase, or clear the project filter.` |
| Delete confirm title | `Delete this session?` |
| Delete confirm body | `This also deletes the 214 activity records captured during it.` |

### 10.11 Accomplishments

| Key | String |
|---|---|
| Search placeholder | `Search accomplishments` |
| Type filter | `All types` |
| Export button | `Export` |
| Group headings | `This week` · `Week of 14 July` |
| Empty state | **`Nothing logged yet.`** / `This is the list you open on Friday to see what you actually delivered.` / `Add Accomplishment` |

### 10.12 Notifications (Phase 2 sends only the first)

| Key | String |
|---|---|
| Session completed — title | `Session finished` |
| Session completed — body | `Finish the receipt deduplication PR · 50 minutes` |
| Session completed — action | `Review` |

---

## 11. Phase 2 build order for this document

The subset of § 4 and § 5 that must exist for the vertical slice in `SPEC.md` § Implementation order,
matched to the `[P2]` files in `02-architecture.md` § 3:

1. `Theme.swift`, `Typography.swift`, `Palette.swift`, `Motion.swift`, `Iconography.swift` — § 2 in
   full. Nothing else can be built consistently until these exist.
2. `Card`, `SectionHeader`, `EmptyStateView`, `PrimaryButtonStyle`, `ProjectBadge` — § 3.
3. `RootWindow`, `Sidebar`, `SidebarSection` — § 1, with five of seven sections rendering an
   `EmptyStateView` placeholder that says what the section will hold.
4. `ProjectsView` + `ProjectEditor` — § 4.5.
5. `StartSessionForm` and its four pickers — § 5.2. The five-second path is the product.
6. `ActiveSessionView`, `TimerDisplay`, `SessionControls` — the Today card in § 4.1.
7. `MenuBarLabel`, `MenuBarContentView`, `MenuBarIdleView`, `MenuBarActiveView` — § 5.1 and § 6.
8. `SessionReviewSheet`, `ResultStatusPicker`, `SummaryEditor` — § 5.3 without the statistics grid.
9. `TodayView`, `TodayHeader`, `CompletedSessionRow` — § 4.1 sections 1 and 3 only.
10. `AddAccomplishmentSheet` — § 10.7.
11. `PreviewGallery` entries for every view above, light and dark.

Empty states, error banners and the full keyboard map ship with each view, not in a Phase 6 cleanup.
A screen without its empty state is not finished.

---

## 12. Open questions

Recorded rather than silently resolved, per the brief.

1. **`LggrStore` has two different signatures in the binding documents.**
   `02-architecture.md` § 4.2 declares `allProjects()`, `upsert(_:)`, `sessions(in:)`, a `Sendable`
   protocol backed by `actor`s, and a `flush()` method. `03-data-model.md` § 4 declares
   `loadProjects()`, `saveProject(_:)`, `loadSessions(in:)`, `loadActiveSession()`, a `@MainActor`
   `AnyObject` protocol, and no `flush()`. **I built against `03-data-model.md`**, since it declares
   itself the keystone and the single source of truth for signatures, and because
   `loadActiveSession()` is required by the relaunch-recovery behaviour I specify in § 1.3. This
   needs one amendment in one file before implementation starts.

2. **SwiftData class prefix.** `02-architecture.md` says `Stored*` (`StoredProject`);
   `03-data-model.md` says `SD*` (`SDProject`). I used `SD*`. Nothing in this document depends on
   it, but the mapping files do.

3. **State object names.** `02-architecture.md` § 3 lists `TodayModel`, `ProjectsModel`,
   `AppModel`; `03-data-model.md` § 4 refers to `TodayStore`, `SessionStore`. I used the
   `02-architecture.md` file names, since they are the ones on disk in the folder tree.

4. **Settings exists twice.** `SPEC.md` § Navigation puts Settings in the sidebar;
   `02-architecture.md` § 5.1 declares a `Settings` scene. I render one `SettingsView` in both hosts
   (§ 1.2). It costs nothing, but if only one is wanted, the sidebar row is the one the spec named.

5. **A `.menuBarExtraStyle(.window)` popover cannot present a `.sheet`.** That is why the start panel
   and the interruption capture render *inline inside the popover* rather than as sheets when
   triggered from the menu bar (§ 5.2, § 5.4). The alternative — opening the main window to start a
   session — would break the "under five seconds, no window required" promise. I am confident this is
   right, but it is a real behavioural difference between the two hosts and worth confirming.

6. **Today's second section is empty until Phase 5.** `SPEC.md` § 7 puts "daily intended outcomes"
   second in the hierarchy, but `WeeklyOutcome` is a `[P5]` type. In Phases 2–4 that section is
   absent rather than showing a placeholder. If the intent was a lighter-weight "today's intents"
   list independent of weekly outcomes, that is a different feature and should be added to the data
   model.

7. **`Space` to pause is scoped.** `SPEC.md` says "Space: Pause or resume active session when
   appropriate". I defined "appropriate" as: the Active Session card holds keyboard focus and no text
   field is editing (§ 7.1). In the popover, `Space` activates the focused Pause button, which
   produces the same result by a different mechanism. Flagging it because the scoping is my
   interpretation of "when appropriate".

8. **Dynamic Type on macOS is partial.** macOS has no per-app text-size control equivalent to iOS.
   Building the ramp from text styles (§ 2.1) means Lggr will scale correctly wherever the system
   does scale, and `@ScaledMetric` handles the one fixed size — but this is less testable on macOS
   than the spec's "Dynamic Type where applicable" might imply. `LGGR_GALLERY=1` should grow a
   `.dynamicTypeSize(.accessibility3)` column so the `ViewThatFits` fallbacks in § 8.3 are actually
   exercised.

9. **Adaptive colours without an asset catalog.** Because `Lggr.app` is assembled by
   `Scripts/make-app.sh` with no `Assets.xcassets`, the two hand-made colours must be built with
   `NSColor(name:dynamicProvider:)` (§ 2.0). This works, but it means colour changes are code
   changes and there is no visual colour editor. Called out so nobody adds an asset catalog halfway
   through and splits the source of truth.
