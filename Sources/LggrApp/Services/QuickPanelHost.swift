import AppKit
import Foundation
import SwiftUI

// The non-activating panel. This file is the difference between "instant" and "jarring".
//
// The whole promise of a global hot key is: press it, act, go back to work. A panel that activates
// Lggr breaks that promise in the most annoying way available — the user's editor loses focus, the
// window they were reading dims, and getting back costs a ⌘⇥. So the panel is an `NSPanel` with
// `.nonactivatingPanel`, which is the one style mask that lets a window take keyboard input *without*
// its application becoming active. Nothing here ever calls `NSApp.activate()`.
//
// Three consequences follow, and all three are requirements rather than side effects:
//
//   - No Dock icon bounce, because the app never activates.
//   - No space switch, because `collectionBehavior` includes `.canJoinAllSpaces` — the panel joins
//     the space the user is on rather than dragging them to Lggr's.
//   - No dependence on a window. The panel is built from nothing, so `⌃⇧L` works with the main window
//     closed, which is the state a menu bar app spends most of its life in.

/// A way for the panel's own content to close it.
///
/// A value type wrapping a `@Sendable @MainActor` closure rather than a bare closure: an
/// `EnvironmentKey`'s default is read from a non-isolated context, and this is what makes that legal
/// without a force unwrap or an optional every view has to check.
public struct QuickPanelDismissAction: Sendable {

    private let handler: @Sendable @MainActor () -> Void

    public init(handler: @escaping @Sendable @MainActor () -> Void = {}) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction() {
        handler()
    }
}

// `@Entry` is unavailable without Xcode (`CONSTRAINTS.md`), so the key is written out by hand, in the
// same style as `EnvironmentValues+Lggr.swift`.
private struct QuickPanelDismissKey: EnvironmentKey {
    /// Computed rather than stored, for the reason the other keys in this app document: a stored
    /// global is a concurrency hazard, and there is nothing worth storing.
    static var defaultValue: QuickPanelDismissAction { QuickPanelDismissAction() }
}

extension EnvironmentValues {

    /// Closes the quick panel the view is being shown in. Does nothing anywhere else, so a view can
    /// call it unconditionally.
    public var dismissQuickPanel: QuickPanelDismissAction {
        get { self[QuickPanelDismissKey.self] }
        set { self[QuickPanelDismissKey.self] = newValue }
    }
}

/// Shows a SwiftUI view in a floating panel that does not steal focus.
///
/// One host, one panel at a time. Presenting while something is already up replaces it, because two
/// quick panels on screen at once is never what a hot key meant.
@MainActor
@Observable
public final class QuickPanelHost {

    /// Whether a panel is on screen. Observable, so the menu bar and the hot-key handlers can treat a
    /// second press as a dismissal.
    public private(set) var isPresented = false

    @ObservationIgnored private var panel: QuickPanel?

    /// Who was in front when the panel opened, so focus can be handed back on dismiss.
    ///
    /// Usually nothing needs handing back: a non-activating panel never took the frontmost
    /// application's activation in the first place. This exists for the case where something else
    /// activated Lggr while the panel was up — then leaving the user in Lggr, with no window, would
    /// be the app quietly interrupting them after all.
    @ObservationIgnored private var previousApplication: NSRunningApplication?

    @ObservationIgnored private var resignObserver: (any NSObjectProtocol)?

    @ObservationIgnored private var onDismiss: (@MainActor () -> Void)?

    /// Default width. Wide enough for a sentence of intended outcome, narrow enough to read in one
    /// eye movement.
    ///
    /// `nonisolated` because it is a default argument of `present(width:…)`, and a default argument is
    /// evaluated at the call site — which the compiler has no reason to believe is on the main actor.
    /// A `CGFloat` needs no isolation to be read safely.
    nonisolated public static let defaultWidth: CGFloat = 560

    /// How far down the screen the panel sits, as a fraction of the visible height.
    ///
    /// Not centred. A panel in the middle of the screen covers whatever the user was looking at; near
    /// the top it sits in the same place Spotlight does, which is a place people already expect a
    /// summoned field to appear.
    private static let topInsetFraction: CGFloat = 0.18

    public init() {}

    // MARK: - Presenting

    /// Puts `content` on screen without activating Lggr.
    ///
    /// - Parameters:
    ///   - width: the panel's width. Height is measured from the content.
    ///   - takesKeyboardFocus: `true` for a panel with something to type into. The panel becomes key —
    ///     which, for a `.nonactivatingPanel`, means it receives keystrokes while the user's own
    ///     application stays active and stays looking active. `false` for a panel that is only read.
    ///   - onDismiss: called once, however the panel closed — `Esc`, a click outside, or `dismiss()`.
    ///   - content: the view. It is handed `\.dismissQuickPanel` so it can close itself when it is
    ///     done, which is what makes a one-field panel a single keystroke.
    public func present<Content: View>(
        width: CGFloat = QuickPanelHost.defaultWidth,
        takesKeyboardFocus: Bool = true,
        onDismiss: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        // Replacing rather than reusing: the previous panel's SwiftUI state belongs to the last time
        // the hot key was pressed, and a half-typed interruption reappearing tomorrow is a bug.
        tearDownPanel(restoringFocus: false)

        previousApplication = NSWorkspace.shared.frontmostApplication
        self.onDismiss = onDismiss

        let dismiss = QuickPanelDismissAction { [weak self] in self?.dismiss() }
        let hosting = NSHostingView(
            rootView: content().environment(\.dismissQuickPanel, dismiss)
        )

        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 1))
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.contentView = hosting
        panel.setContentSize(Self.measure(hosting, width: width))
        panel.setFrameOrigin(Self.origin(for: panel.frame.size))

        // A panel that resigns key has been left: the user clicked their own document, another window,
        // or another application. Any of those means they are done with it. This is also the whole of
        // "click outside dismisses" — and it needs no event monitor, and therefore no Accessibility
        // permission, which is the point.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }

        self.panel = panel
        isPresented = true

        if takesKeyboardFocus {
            // Key, but not active. `becomesKeyOnlyIfNeeded` governs clicks; this is the explicit
            // request that lets the user start typing the instant the panel appears.
            panel.makeKeyAndOrderFront(nil)
        } else {
            // `orderFrontRegardless`, not `orderFront`: `orderFront` does nothing for an application
            // that is not active, which is exactly the situation this whole type is built for.
            panel.orderFrontRegardless()
        }
    }

    /// Closes the panel and gives focus back. Safe to call when nothing is up.
    public func dismiss() {
        guard panel != nil else { return }
        let callback = onDismiss
        tearDownPanel(restoringFocus: true)
        callback?()
    }

    // MARK: - Teardown

    private func tearDownPanel(restoringFocus: Bool) {
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        onDismiss = nil

        guard let panel else {
            isPresented = false
            return
        }
        self.panel = nil
        isPresented = false

        // The observer is already gone, so this cannot re-enter `dismiss()`.
        panel.onCancel = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()

        let previous = previousApplication
        previousApplication = nil

        // Only when Lggr genuinely ended up in front. Activating an application that is already
        // active makes its windows flash, so the common path — where the panel never took activation
        // from anyone — deliberately does nothing at all.
        guard restoringFocus, NSApp.isActive, let previous else { return }
        guard !previous.isEqual(NSRunningApplication.current) else { return }
        previous.activate()
    }

    // MARK: - Geometry

    /// The content size, measured from the SwiftUI view rather than guessed.
    private static func measure(_ hosting: NSHostingView<some View>, width: CGFloat) -> NSSize {
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        hosting.layoutSubtreeIfNeeded()
        let fitted = hosting.fittingSize
        let available = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.height ?? 600
        // A minimum so a panel whose content has not laid out yet is still a window rather than a
        // sliver; a maximum so content that measures badly cannot produce a panel taller than the
        // screen.
        let height = min(max(fitted.height, 44), available - 80)
        return NSSize(width: width, height: max(height, 44))
    }

    /// Centred horizontally, high up, on the screen the user is actually looking at.
    ///
    /// `NSScreen.main` is the screen with the keyboard focus — not the largest and not the first —
    /// which for a hot key pressed inside another application is the screen that application is on.
    private static func origin(for size: NSSize) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return NSPoint(x: 0, y: 0) }

        let x = frame.midX - size.width / 2
        let y = frame.maxY - frame.height * topInsetFraction - size.height
        return NSPoint(
            x: min(max(x, frame.minX), max(frame.maxX - size.width, frame.minX)),
            y: min(max(y, frame.minY), max(frame.maxY - size.height, frame.minY))
        )
    }
}

// MARK: - The panel

/// The window itself.
///
/// A subclass for two reasons, both of which are one-line overrides that cannot be expressed through
/// configuration: a panel has to be told it may become key, and `Esc` arrives as
/// `cancelOperation(_:)` rather than as a key equivalent SwiftUI can see.
private final class QuickPanel: NSPanel {

    /// Called for `Esc`. Cleared before teardown so closing cannot re-enter.
    var onCancel: (@MainActor () -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // `.nonactivatingPanel` is the requirement. `.titled` and `.fullSizeContentView` are what
            // give a rounded, shadowed, vibrancy-capable window whose content fills it — there is no
            // asset catalog and no window chrome to draw by hand (`CONSTRAINTS.md`).
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // Clicks on the panel's own controls do not take keyboard focus; only a view that actually
        // needs it, such as a text field, gets it. Presenting explicitly calls
        // `makeKeyAndOrderFront`, which is a separate request and still works.
        becomesKeyOnlyIfNeeded = true
        level = .floating
        // Joins the space the user is on instead of pulling them to Lggr's, and coexists with a
        // full-screen application rather than forcing it aside.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The panel outlives a deactivation on purpose: the app is never active while it is up.
        hidesOnDeactivate = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        // `close()` is called during teardown while this object is still referenced from the stack.
        isReleasedWhenClosed = false
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    /// Without this a panel created with these flags will not accept keystrokes, and the entire
    /// feature reduces to a window you can look at.
    override var canBecomeKey: Bool { true }

    /// Never. Becoming main is what would make Lggr look like the frontmost application.
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
