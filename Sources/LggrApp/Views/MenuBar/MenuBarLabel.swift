import SwiftUI
import LggrKit

// The menu bar label. See docs/_design/04-screens.md § 6 and docs/_design/SPIKE-menubar.md.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
//  THE ONE RULE THIS FILE EXISTS TO PROTECT
//
//  `MenuBarExtra`'s label is hosted by the system, outside the normal view tree. It redraws at
//  1 Hz — this was measured, 32 consecutive ticks at 1.000 ± 0.003 s — but ONLY because the label
//  view reads the observable date **inside its own body**. Observation invalidates the view that
//  performed the read and nothing else, so a parent that formats "32:41" and hands the string down
//  leaves this view with no tracked dependency, and the timer freezes at whatever it said when the
//  session started.
//
//  Therefore: `MenuBarLabel(manager:)` is the initialiser the scene uses, and every read of
//  `SessionManager` happens in `body` below, marked with a comment. `MenuBarLabel(state:)` exists
//  only for the headless snapshot renderer, which draws one frame and never ticks.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Everything the label draws, as one value: a symbol, optionally some digits, how to weight them,
/// and the sentence VoiceOver speaks.
///
/// Keeping it a plain `Sendable` value rather than a bundle of view properties is what lets the
/// snapshot gallery render all six states side by side without a store, a clock or a session.
public struct MenuBarLabelState: Equatable, Sendable {

    /// How the digits are weighted. Three cases and no fourth: the label has exactly one colour
    /// (`Palette.attention`, on roughly five characters of overtime) and one demotion (paused).
    public enum Emphasis: Equatable, Sendable {
        case normal
        case dimmed
        case attention
    }

    public let symbolName: String
    /// `nil` when there is nothing to count, and when the user has turned the timer off.
    public let timeText: String?
    public let emphasis: Emphasis
    /// The `accessibilityValue`. Never a bare number — see § 6.4.
    public let spokenValue: String

    public init(symbolName: String, timeText: String?, emphasis: Emphasis, spokenValue: String) {
        self.symbolName = symbolName
        self.timeText = timeText
        self.emphasis = emphasis
        self.spokenValue = spokenValue
    }

    public var isPaused: Bool { emphasis == .dimmed }
}

// MARK: - Deriving the state

extension MenuBarLabelState {

    /// No session, nothing awaiting review. Symbol only: no dot, no badge, no colour, and the same
    /// glyph a running session uses. The *presence of digits* is the state change.
    public static let idle = MenuBarLabelState(
        symbolName: Icon.MenuBar.idle,
        timeText: nil,
        emphasis: .normal,
        spokenValue: "No focus session running"
    )

    /// A session ended and "What happened?" has not been answered. Clicking opens the popover with
    /// `Review last session` on top.
    public static let awaitingReview = MenuBarLabelState(
        symbolName: Icon.MenuBar.awaitingReview,
        timeText: nil,
        emphasis: .normal,
        spokenValue: "A finished focus session is waiting for your review"
    )

    /// The whole state machine in one function, so the label and the snapshot gallery can never
    /// disagree about what a given session looks like.
    ///
    /// An active session outranks a pending review: if the user started something new before
    /// reviewing the last one, the running clock is the more useful thing to show.
    public static func resolve(
        activeSession: FocusSession?,
        awaitingReview: Bool,
        projectName: String?,
        now: Date,
        showTimer: Bool
    ) -> MenuBarLabelState {
        if let activeSession, !activeSession.isFinished {
            return active(
                session: activeSession,
                projectName: projectName,
                now: now,
                showTimer: showTimer
            )
        }
        return awaitingReview ? .awaitingReview : .idle
    }

    /// Running, paused, or overtime — the three sub-states of one live session.
    public static func active(
        session: FocusSession,
        projectName: String?,
        now: Date,
        showTimer: Bool
    ) -> MenuBarLabelState {
        let isPaused = session.isPaused
        let isOvertime = session.overrun(at: now) > 0

        // Paused wins over overtime. A session that ran past its plan and was then paused is,
        // to the user, paused; dimmed digits say that and orange digits would not.
        let emphasis: Emphasis
        if isPaused {
            emphasis = .dimmed
        } else if isOvertime {
            emphasis = .attention
        } else {
            emphasis = .normal
        }

        var spoken = (isPaused ? "Focus session paused" : "Focus session running")
            + ", " + spokenTimeValue(for: session, at: now)

        // The project is spoken but never drawn. VoiceOver output is private to the user; the
        // visible label is in every screen share and every over-the-shoulder glance (§ 6.3).
        // Overtime and paused already say enough, so the name rides only on the plain running case.
        if !isPaused, !isOvertime, let projectName, !projectName.isEmpty {
            spoken += ", " + projectName
        }

        return MenuBarLabelState(
            symbolName: isPaused ? Icon.MenuBar.paused : Icon.MenuBar.running,
            timeText: showTimer ? timeText(for: session, at: now) : nil,
            emphasis: emphasis,
            spokenValue: spoken
        )
    }

    // MARK: Digits

    /// The exact title format from § 6.2: `m:ss` below an hour, `H:mm:ss` at or above it, `+` in
    /// front once the plan is spent. Countdown sessions show what is left, open-ended ones count up.
    ///
    /// Both branches go through `DurationFormatting`, which is unit-tested in `LggrKit`, rather than
    /// through `DateComponentsFormatter`, whose separators and unit elision vary by locale and would
    /// reflow the menu bar mid-tick.
    public static func timeText(for session: FocusSession, at now: Date) -> String {
        if session.isOpenEnded {
            return DurationFormatting.timerClock(session.elapsed(at: now))
        }
        return DurationFormatting.countdown(
            remaining: session.remaining(at: now) ?? 0,
            overrun: session.overrun(at: now)
        )
    }

    // MARK: Speech

    /// "32 minutes 41 seconds remaining", "1 hour 12 minutes elapsed",
    /// "4 minutes 12 seconds past the planned 50 minutes".
    ///
    /// Shared with the popover's timer so a screen reader hears the same sentence in both places.
    public static func spokenTimeValue(for session: FocusSession, at now: Date) -> String {
        let overrun = session.overrun(at: now)
        if overrun > 0, let planned = session.plannedDuration {
            return spokenDuration(overrun) + " past the planned " + DurationFormatting.prose(planned)
        }
        if let remaining = session.remaining(at: now) {
            return spokenDuration(remaining) + " remaining"
        }
        return spokenDuration(session.elapsed(at: now)) + " elapsed"
    }

    /// A duration as words: "23 minutes", "32 minutes 41 seconds", "1 hour 12 minutes".
    ///
    /// Seconds are spoken only below an hour. "One hour twelve minutes four seconds" is a mouthful
    /// that changes every second, and past the hour mark the seconds are not what the user is
    /// listening for. Zero units are omitted entirely rather than read as "0 hours".
    ///
    /// `DurationFormatting.prose` is deliberately not reused here: it spells small numbers as words
    /// ("seven minutes") and collapses long spans to one decimal ("1.4 hours"), which is right
    /// inside a generated sentence and wrong for a clock being read aloud.
    public static func spokenDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite, duration > 0 else { return "0 seconds" }
        let total = Int(min(duration, TimeInterval(Int32.max)).rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if hours == 0, seconds > 0 { parts.append(unit(seconds, "second")) }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }

    private static func unit(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }
}

// MARK: - The label

/// The symbol and the live digits that sit in the menu bar.
///
/// Nothing here animates. No content transition, no fade, no pulse: the label redraws once a second
/// and that is the entire behaviour (§ 6.3).
@MainActor
public struct MenuBarLabel: View {

    private let manager: SessionManager?
    private let fixedState: MenuBarLabelState?

    /// **The initialiser the scene uses.** The manager is held, never read at init time — every read
    /// happens in `body`, which is the whole reason the timer ticks.
    ///
    /// Optional because `EnvironmentValues.sessionManager` is optional by construction: a
    /// `@MainActor` type cannot supply a non-isolated `EnvironmentKey.defaultValue`. A `nil` manager
    /// renders `.idle`, which is the honest thing for "nothing was injected".
    public init(manager: SessionManager?) {
        self.manager = manager
        self.fixedState = nil
    }

    /// A frozen state, for the headless snapshot renderer and the light/dark gallery.
    ///
    /// **Never use this in the scene graph.** A pre-computed state means this view reads nothing
    /// observable, so nothing ever invalidates it and the clock stops at the first frame.
    public init(state: MenuBarLabelState) {
        self.manager = nil
        self.fixedState = state
    }

    public var body: some View {
        // ┌───────────────────────────────────────────────────────────────────────────────────┐
        // │  THE READS. All of them, here, in this view's own body. See SPIKE-menubar.md.      │
        // │  `now` is assigned once a second by SessionManager's TickTimer while — and only    │
        // │  while — a session is advancing, so an idle Lggr does no work per second.          │
        // └───────────────────────────────────────────────────────────────────────────────────┘
        let now = manager?.now ?? Date()
        let session = manager?.activeSession
        let hasPendingReview = manager?.pendingReview != nil
        let showTimer = manager?.preferences.showTimerInMenuBar ?? true
        let projectName = manager?.projectName(for: session?.projectID)

        let state = fixedState ?? MenuBarLabelState.resolve(
            activeSession: session,
            awaitingReview: hasPendingReview,
            projectName: projectName,
            now: now,
            showTimer: showTimer
        )

        return HStack(spacing: Space.xs) {
            Image(systemName: state.symbolName)

            if let text = state.timeText {
                // `verbatim`: these are digits, not a localisable phrase, and routing a
                // once-a-second string through a `LocalizedStringKey` lookup is pure overhead.
                Text(verbatim: text)
                    // 12pt regular rounded, monospaced digits: the same visual weight as the system
                    // clock a few pixels to the right, and a width that does not change between
                    // 10:00 and 59:59. That stability is most of what makes this subtle.
                    .font(Type.menuBarTimer)
                    .foregroundStyle(Self.digitStyle(state.emphasis))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lggr")
        .accessibilityValue(state.spokenValue)
    }

    private static func digitStyle(_ emphasis: MenuBarLabelState.Emphasis) -> AnyShapeStyle {
        switch emphasis {
        case .normal:
            return AnyShapeStyle(.primary)
        case .dimmed:
            return AnyShapeStyle(.secondary)
        case .attention:
            return AnyShapeStyle(Palette.attention)
        }
    }
}
