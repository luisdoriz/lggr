import SwiftUI
import LggrKit

// The work type field of the start panel. See docs/_design/04-screens.md § 5.2.
//
// This control has a side effect the others do not: changing the work type re-selects that type's
// `suggestedDuration` — but only while the user has not touched the duration themselves. The flag
// that governs it lives in `StartSessionForm`; this view just reports the change.

/// The work type menu: the type's own SF Symbol, its display name, and a chevron.
///
/// Symbols come from `WorkType.symbolName` in `LggrKit` rather than from `Icon`, so there is exactly
/// one source of truth for what "Deep work" looks like across the whole application.
@MainActor
public struct WorkTypePicker: View {

    @Binding private var selection: WorkType
    private let onChange: (WorkType) -> Void

    /// - Parameter onChange: called when *the user* picks a different type, so the panel can
    ///   re-apply the suggested duration. Not called for programmatic changes.
    public init(selection: Binding<WorkType>, onChange: @escaping (WorkType) -> Void = { _ in }) {
        self._selection = selection
        self.onChange = onChange
    }

    public var body: some View {
        Menu {
            ForEach(WorkType.allCases) { workType in
                Toggle(workType.displayName, isOn: binding(for: workType))
            }
        } label: {
            StartPanelFieldChrome {
                Image(systemName: selection.symbolName)
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: Layout.symbolColumnWidth, alignment: .center)
                    .accessibilityHidden(true)
                Text(selection.displayName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Work type")
        .accessibilityValue(selection.displayName)
    }

    private func binding(for workType: WorkType) -> Binding<Bool> {
        Binding(
            get: { selection == workType },
            set: { isOn in
                guard isOn, selection != workType else { return }
                selection = workType
                onChange(workType)
            }
        )
    }
}
