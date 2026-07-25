import SwiftUI
import LggrKit

// The one dominant number in the application. See docs/_design/04-screens.md § 4.1 and § 8.2.
//
// Two things about this file are load-bearing and neither is obvious:
//
// 1. **The clock is read inside this view's own `body`.** `SPIKE-menubar.md` measured why: Observation
//    invalidates the view that performed the read, and only that view. A parent that formats the time
//    and passes a `String` down makes the *parent* redraw once a second — the whole Today card,
//    including the outcome text and both buttons — and leaves this view's own tracking empty. So the
//    instant arrives as a closure that is called here, and nothing above this view ticks.
//
// 2. **The number is never counted, only computed.** Every value comes from `SessionClock`'s pure
//    functions over the session's stored dates, so a dropped tick, a display sleep or a relaunch
//    mid-session all resolve to the same digits.

/// The active session's clock: large rounded monospaced digits, one quiet caption beneath.
///
/// Counts **down** against a planned duration, **up** when the session is open-ended, and switches to
/// a `+M:SS` overtime reading once the plan is spent. Overtime is a fact, not an alarm: the digits
/// pick up `Palette.attention`, the caption states the plan that was passed, and nothing pulses,
/// flashes or turns red.
///
/// ```swift
/// TimerDisplay(session: session, now: { sessionManager.now })
/// TimerDisplay(session: PreviewFixtures.runningSession, now: { PreviewFixtures.now })
/// ```
public struct TimerDisplay: View {

    private let session: FocusSession
    private let now: () -> Date

    /// - Parameters:
    ///   - session: The running or paused session. All durations are derived from it.
    ///   - now: Reads the observable instant. Pass `{ sessionManager.now }`; the closure is called
    ///     inside this view's `body` so Observation invalidates this view and no other.
    public init(session: FocusSession, now: @escaping () -> Date) {
        self.session = session
        self.now = now
    }

    public var body: some View {
        // The one read that makes this view tick.
        let instant = now()
        let elapsed = session.elapsed(at: instant)
        let overrun = session.overrun(at: instant)
        let remaining = session.remaining(at: instant)
        let progress = session.progress(at: instant)
        let isOvertime = overrun > 0

        return VStack(spacing: Space.s) {
            digits(elapsed: elapsed, remaining: remaining, overrun: overrun, isOvertime: isOvertime)

            HStack(spacing: Space.s) {
                if let progress {
                    SessionProgressRing(progress: progress, isPaused: session.isPaused)
                }
                Text(caption(isOvertime: isOvertime))
                    .font(Type.secondary)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Digits

    private func digits(
        elapsed: TimeInterval,
        remaining: TimeInterval?,
        overrun: TimeInterval,
        isOvertime: Bool
    ) -> some View {
        let text = clockText(elapsed: elapsed, remaining: remaining, overrun: overrun)
        let spoken = Self.spoken(isOvertime ? overrun : (remaining ?? elapsed))

        // The hidden template is what reserves the width. Monospaced digits already stop `32:41`
        // becoming `32:40` from reflowing, but they do nothing about `10:00` becoming `9:59` — the
        // string loses a character and a centred layout jumps. The template is the widest string this
        // session can produce, laid out invisibly underneath, so the container never resizes.
        return ZStack {
            Text(widthTemplate(elapsed: elapsed, overrun: overrun))
                .heroTimerFont()
                .hidden()
                .accessibilityHidden(true)

            Text(text)
                .heroTimerFont()
                .foregroundStyle(isOvertime ? Palette.attention : Color.primary)
                .lggrNumericText(countsDown: !session.isOpenEnded && !isOvertime)
                // Motion.none, explicitly: the digits change, the layout does not move.
                .lggrAnimation(Motion.none, value: text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(isOvertime: isOvertime))
        .accessibilityValue(spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func clockText(
        elapsed: TimeInterval,
        remaining: TimeInterval?,
        overrun: TimeInterval
    ) -> String {
        guard let remaining else { return DurationFormatting.timerClock(elapsed) }
        return DurationFormatting.countdown(remaining: remaining, overrun: overrun)
    }

    /// The widest reading this session can currently produce.
    ///
    /// For a planned session the `+` is reserved from the start, so crossing into overtime does not
    /// nudge the digits sideways at the exact moment the user is most likely to be looking at them.
    /// Reserving extra width costs nothing visually: both strings are centred in the same stack.
    private func widthTemplate(elapsed: TimeInterval, overrun: TimeInterval) -> String {
        guard let planned = session.plannedDuration else {
            return DurationFormatting.timerClockTemplate(upTo: elapsed)
        }
        return "+" + DurationFormatting.timerClockTemplate(upTo: max(planned, overrun))
    }

    // MARK: - Caption

    /// `04-screens.md` § 10.4, verbatim.
    private func caption(isOvertime: Bool) -> String {
        if session.isPaused { return "paused" }
        if isOvertime, let planned = session.plannedDuration {
            return "past " + DurationFormatting.prose(planned)
        }
        return session.isOpenEnded ? "elapsed" : "remaining"
    }

    // MARK: - VoiceOver

    private func accessibilityLabel(isOvertime: Bool) -> String {
        if isOvertime { return "Time past plan" }
        return session.isOpenEnded ? "Time elapsed" : "Time remaining"
    }

    /// "32 minutes 41 seconds".
    ///
    /// `DurationFormatting` has no spoken form — its strings are all built for a fixed-width display,
    /// and "32:41" is read aloud as a ratio. This is the only place a duration is spoken, so it lives
    /// here rather than widening the domain library's API.
    private static func spoken(_ duration: TimeInterval) -> String {
        let clamped = duration.isFinite ? max(0, duration) : 0
        let total = Int(clamped.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if minutes > 0 { parts.append("\(minutes) \(minutes == 1 ? "minute" : "minutes")") }
        if seconds > 0 || parts.isEmpty {
            parts.append("\(seconds) \(seconds == 1 ? "second" : "seconds")")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Progress ring

/// The session's progress against its plan, as a quiet ring beside the timer's caption.
///
/// **There is no percentage next to it, deliberately.** The wireframe in § 4.1 shows `◔ 65%`, but the
/// countdown directly above it already states the same fact in the most useful form; a ring, a
/// percentage and a countdown are three renderings of one number, and two of them are decoration.
/// The percentage survives where it is actually useful — `04-screens.md` § 8.2 asks for it as the
/// ring's VoiceOver value, and that is exactly where it is.
///
/// Sized to `Layout.symbolColumnWidth` because that is what it is: a glyph on the caption's baseline,
/// in the same column any SF Symbol would occupy.
public struct SessionProgressRing: View {

    private let progress: Double
    private let isPaused: Bool

    public init(progress: Double, isPaused: Bool = false) {
        self.progress = min(1, max(0, progress))
        self.isPaused = isPaused
    }

    /// Two hairlines. Thin enough to read as a line rather than a dial.
    private var lineWidth: CGFloat { Layout.hairline * 2 }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Stroke.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                // Twelve o'clock, clockwise — the direction every clock on the machine turns.
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: Layout.symbolColumnWidth, height: Layout.symbolColumnWidth)
        .lggrAnimation(Motion.ring, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    /// A paused session's ring drops to `.secondary`, matching the popover in § 5.1: the colour is
    /// the state, and no second badge is needed to say so.
    private var fill: Color {
        isPaused ? Color.secondary : Color.accentColor
    }
}
