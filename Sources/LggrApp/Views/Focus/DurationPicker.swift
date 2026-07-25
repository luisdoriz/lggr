import SwiftUI
import LggrKit

// The duration control of the start panel. See docs/_design/04-screens.md § 5.2:
//
//     ( 25m ) (● 50m ) ( Custom ) ( Open-ended )
//
// It sits *below* the outcome field and is set at `Type.secondary`, because the outcome is the only
// required field and the only one the user actually came here to type. Duration is the fourth thing
// in the hierarchy, and it looks like it.

/// What the user picked in the duration control.
///
/// `preset` and `custom` are deliberately distinct cases even though both are just minutes: the
/// segmented control has to know which chip is lit, and "50 minutes typed into Custom" and
/// "the 50m chip" are different states of the same control.
public enum DurationSelection: Hashable, Sendable {
    case preset(Int)
    case custom(Int)
    case openEnded

    /// The two chips offered before Custom. Two, not five — a row of preset durations is a settings
    /// screen wearing a form's clothes.
    public static let presetMinutes: [Int] = [25, 50]

    /// One minute to ten hours. The lower bound is what stops a zero-length session; the upper bound
    /// is what stops a typo ("500" for "50") from planning a three-week session. Both are enforced by
    /// clamping rather than by an error message.
    public static let customRange: ClosedRange<Int> = 1...600

    /// Where Custom starts if the user picks it without ever having typed a number.
    public static let defaultCustomMinutes = 45

    /// What `SessionManager.startSession(plannedDuration:)` is handed. `nil` means open-ended.
    public var plannedDuration: TimeInterval? {
        switch self {
        case .preset(let minutes), .custom(let minutes): TimeInterval(minutes) * 60
        case .openEnded: nil
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    /// The selection that best represents a stored duration.
    ///
    /// A corrupt or absurd stored value resolves to a sane preset instead of propagating: the start
    /// panel is the one screen that must never refuse to work.
    public static func matching(_ duration: TimeInterval?) -> DurationSelection {
        guard let duration else { return .openEnded }
        guard duration.isFinite, duration > 0 else { return .preset(50) }
        let raw = Int((duration / 60).rounded())
        let minutes = min(max(raw, customRange.lowerBound), customRange.upperBound)
        return presetMinutes.contains(minutes) ? .preset(minutes) : .custom(minutes)
    }
}

/// `25m · 50m · Custom · Open-ended`, plus the minutes entry that Custom reveals.
///
/// Keyboard: the segment row is one focus stop; `←`/`→` move the selection, `Space`/`Return` commit
/// the focused chip. The minutes field is the next stop, and only exists while Custom is selected —
/// progressive disclosure, so the common case is four chips and nothing else.
@MainActor
public struct DurationPicker: View {

    @Binding private var selection: DurationSelection
    @FocusState.Binding private var focus: StartPanelField?
    private let onManualChange: () -> Void

    /// The minutes Custom remembers between visits, so switching away and back does not reset it.
    @State private var customMinutes = DurationSelection.defaultCustomMinutes
    /// The field's literal contents. Kept as text rather than bound through a formatter so that a
    /// half-typed number is never round-tripped into a nonsense value while the user is still typing.
    @State private var customText = String(DurationSelection.defaultCustomMinutes)

    /// - Parameter onManualChange: called whenever *the user* moves this control. The start panel
    ///   uses it to stop re-applying `WorkType.suggestedDuration`; once the user has touched the
    ///   duration, the app stops moving it.
    public init(
        selection: Binding<DurationSelection>,
        focus: FocusState<StartPanelField?>.Binding,
        onManualChange: @escaping () -> Void
    ) {
        self._selection = selection
        self._focus = focus
        self.onManualChange = onManualChange
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            segments
            if selection.isCustom {
                customEntry
            }
        }
        .lggrAnimation(Motion.reveal, value: selection.isCustom)
        .onAppear(perform: adoptIncomingSelection)
    }

    // MARK: - Segments

    private var segments: some View {
        HStack(spacing: Space.xxs) {
            ForEach(DurationSelection.presetMinutes, id: \.self) { minutes in
                DurationSegment(
                    title: "\(minutes)m",
                    isSelected: selection == .preset(minutes),
                    action: { select(.preset(minutes)) }
                )
            }
            DurationSegment(
                title: "Custom",
                isSelected: selection.isCustom,
                action: { select(.custom(customMinutes)) }
            )
            DurationSegment(
                title: "Open-ended",
                isSelected: selection == .openEnded,
                action: { select(.openEnded) }
            )
        }
        .padding(Space.xxs)
        .overlay(focusRing)
        .focusable()
        .focused($focus, equals: .duration)
        .onMoveCommand(perform: move)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Duration")
    }

    /// A quiet accent outline while the row holds focus. The chips themselves are borderless, so
    /// without this the keyboard would be moving an invisible cursor.
    @ViewBuilder private var focusRing: some View {
        if focus == .duration {
            Theme.shape(Radius.chip + Space.xxs)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: Layout.hairline)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let count = DurationSelection.presetMinutes.count + 2
        let current = segmentIndex(of: selection)
        let next: Int
        switch direction {
        case .left: next = max(0, current - 1)
        case .right: next = min(count - 1, current + 1)
        default: return
        }
        guard next != current else { return }
        select(selectionForSegment(next))
    }

    private func segmentIndex(of selection: DurationSelection) -> Int {
        switch selection {
        case .preset(let minutes): DurationSelection.presetMinutes.firstIndex(of: minutes) ?? 0
        case .custom: DurationSelection.presetMinutes.count
        case .openEnded: DurationSelection.presetMinutes.count + 1
        }
    }

    private func selectionForSegment(_ index: Int) -> DurationSelection {
        if index < DurationSelection.presetMinutes.count {
            return .preset(DurationSelection.presetMinutes[index])
        }
        return index == DurationSelection.presetMinutes.count ? .custom(customMinutes) : .openEnded
    }

    // MARK: - Custom minutes

    private var customEntry: some View {
        HStack(spacing: Space.s) {
            TextField("", text: $customText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(Type.secondary)
                .monospacedDigit()
                .frame(width: Layout.symbolColumnWidth * 3)
                .focused($focus, equals: .customMinutes)
                .onChange(of: customText) { _, newValue in sanitize(newValue) }
                .onSubmit(restoreIfBlank)
                .accessibilityLabel("Custom duration in minutes")

            Text("minutes")
                .font(Type.secondary)
                .foregroundStyle(.secondary)

            Stepper("Custom duration in minutes", value: minutesBinding, in: DurationSelection.customRange, step: 5)
                .labelsHidden()
        }
        .padding(.leading, Space.xxs)
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { customMinutes },
            set: { commit(minutes: $0) }
        )
    }

    /// Digits only, at most three of them, then clamped. A negative or absurd value is unreachable
    /// because neither a minus sign nor a fourth digit can ever be typed into the field.
    private func sanitize(_ raw: String) {
        let digits = String(raw.filter(\.isNumber).prefix(3))
        if digits != raw {
            customText = digits
            return
        }
        guard let typed = Int(digits) else { return }
        let clamped = min(max(typed, DurationSelection.customRange.lowerBound), DurationSelection.customRange.upperBound)
        if clamped != typed {
            customText = String(clamped)
            return
        }
        guard clamped != customMinutes else { return }
        customMinutes = clamped
        selection = .custom(clamped)
        onManualChange()
    }

    /// An emptied field is a field mid-edit, not a request for a zero-minute session.
    private func restoreIfBlank() {
        guard Int(customText) == nil else { return }
        customText = String(customMinutes)
    }

    private func commit(minutes: Int) {
        let clamped = min(max(minutes, DurationSelection.customRange.lowerBound), DurationSelection.customRange.upperBound)
        customMinutes = clamped
        customText = String(clamped)
        selection = .custom(clamped)
        onManualChange()
    }

    // MARK: - Selection

    private func select(_ newValue: DurationSelection) {
        if case .custom(let minutes) = newValue {
            customMinutes = minutes
            customText = String(minutes)
        }
        guard newValue != selection else { return }
        selection = newValue
        onManualChange()
    }

    /// If the panel opened on a custom duration, adopt it rather than showing the placeholder 45.
    private func adoptIncomingSelection() {
        if case .custom(let minutes) = selection {
            customMinutes = minutes
        }
        customText = String(customMinutes)
    }
}

// MARK: - One chip

/// A single duration chip. Selected is `Surface.selected` with accent text; hover is `Surface.hover`.
/// Nothing scales, nothing pulses, and there is no border — the fill is the whole affordance.
private struct DurationSegment: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Type.secondary)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .background(fill, in: Theme.chipShape)
                .contentShape(Theme.chipShape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .lggrAnimation(Motion.tap, value: isHovering)
        .lggrAnimation(Motion.settle, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var fill: Color {
        if isSelected { return Surface.selected }
        return isHovering ? Surface.hover : .clear
    }
}
