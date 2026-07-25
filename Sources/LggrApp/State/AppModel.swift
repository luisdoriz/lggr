import AppKit
import Foundation
import SwiftUI

/// Where the user is, and what is on top of it.
///
/// `AppModel` holds navigation only: the selected sidebar section, the detail column's push stack,
/// and which panel is presented. It owns no data and never touches the store — that is
/// `SessionManager`'s job, and keeping the two apart is what lets a panel be opened from the menu
/// bar without any of it depending on a window existing.
@MainActor
@Observable
public final class AppModel {

    // MARK: - Panels

    /// The four panels the main window can present.
    ///
    /// One enum rather than four booleans: two sheets can never be true at once, and the compiler
    /// should be the thing that guarantees it.
    public enum SheetRoute: Identifiable, Hashable, Sendable {
        /// "What are you working on?" — the start panel, as a sheet on the main window.
        case startSession
        /// "What happened?" for `SessionManager.pendingReview`.
        case sessionReview
        /// The accomplishment editor. `sessionID` is set when it was offered by a finished session,
        /// so the sheet can pre-fill the title and the project.
        case addAccomplishment(sessionID: UUID?)
        /// The project editor. `nil` means a new project.
        case projectEditor(projectID: UUID?)
        /// "What came up?" — interruption capture. Carries nothing: the running session is read from
        /// `SessionManager` when the note is saved, and the panel deliberately knows nothing about it.
        case captureInterruption
        /// The accomplishment editor, opened from an inbox row that is turning into one. Separate
        /// from `addAccomplishment` because saving it also has to settle the interruption.
        case interruptionAccomplishment(interruptionID: UUID)

        public var id: String {
            switch self {
            case .startSession: "startSession"
            case .sessionReview: "sessionReview"
            case .addAccomplishment(let sessionID): "addAccomplishment-\(sessionID?.uuidString ?? "new")"
            case .projectEditor(let projectID): "projectEditor-\(projectID?.uuidString ?? "new")"
            case .captureInterruption: "captureInterruption"
            case .interruptionAccomplishment(let id): "interruptionAccomplishment-\(id.uuidString)"
            }
        }
    }

    /// What the menu bar popover is showing.
    ///
    /// A `.menuBarExtraStyle(.window)` popover cannot present a `.sheet`, so the start panel is
    /// rendered *inline* in place of the idle menu when it is invoked from the menu bar
    /// (`04-screens.md` § 5.2). The alternative — opening the main window in order to start a
    /// session — would break the promise that starting takes five seconds and no window.
    public enum PopoverMode: Hashable, Sendable {
        case menu
        case startSession
        /// Interruption capture, rendered *inline* in place of the menu for the same reason the start
        /// panel is: a popover cannot present a sheet, and capturing an interruption must never be
        /// the thing that opens a window at somebody mid-session (`04-screens.md` § 5.4).
        case captureInterruption
    }

    // MARK: - Navigation state

    /// The selected sidebar section. Persisted, so reopening the app lands where the user left.
    ///
    /// Written through explicit `access`/`withMutation` rather than a `didSet`: the `@Observable`
    /// macro synthesises the accessors for a stored property, and a property cannot have both
    /// synthesised accessors and observers. This is the pattern Observation documents for custom
    /// storage, and it is the only property in the app that needs it.
    public var section: SidebarSection {
        get {
            access(keyPath: \.section)
            return sectionStorage
        }
        set {
            guard newValue != sectionStorage else { return }
            withMutation(keyPath: \.section) { sectionStorage = newValue }
            // A pushed detail belongs to the section it was pushed from. Leaving it on the path would
            // mean selecting Accomplishments and still being shown a focus session, with a back button
            // that returns to a screen the sidebar says you are not on.
            if !detailPath.isEmpty { detailPath = NavigationPath() }
            defaults.set(newValue.rawValue, forKey: Self.sectionKey)
        }
    }

    public var columnVisibility: NavigationSplitViewVisibility = .all

    /// The detail column's push stack. `NavigationPath` so a section can push its own detail type
    /// without every section agreeing on one.
    public var detailPath = NavigationPath()

    /// The panel presented on the main window, if any.
    public var sheet: SheetRoute?

    /// What the menu bar popover is currently showing.
    public var popover: PopoverMode = .menu

    /// Opens the main window and brings Lggr forward.
    ///
    /// `OpenWindowAction` can only be obtained from the SwiftUI environment, and the menu bar
    /// popover has no window whose environment we could read — so the scene that declares the window
    /// hands the action down instead of this model reaching for it. **The app scene must set this**;
    /// without it, presenting a sheet from the menu bar while every window is closed silently does
    /// nothing.
    @ObservationIgnored public var openMainWindow: (@MainActor () -> Void)?

    @ObservationIgnored private var sectionStorage: SidebarSection
    @ObservationIgnored private let defaults: UserDefaults

    private static let sectionKey = "com.lggr.sidebar.section"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.sectionKey)
        self.sectionStorage = stored.flatMap(SidebarSection.init(rawValue:)) ?? .today
    }

    // MARK: - Section selection

    /// Selects a section, opening the main window first if it is closed.
    ///
    /// This is what `⌘1`–`⌘7` and every "Open …" row in the popover call: the section is useless if
    /// there is no window to show it in (`04-screens.md` § 1.3).
    public func select(_ section: SidebarSection) {
        showMainWindow()
        self.section = section
    }

    // MARK: - Presenting panels

    /// Presents a panel on the main window, opening the window first if it is closed.
    ///
    /// This is the case worth being careful about. `⌘⇧A` and the popover's own rows are available
    /// with every window shut, and a sheet has nothing to attach to until a window exists. Opening
    /// the window and then setting `sheet` in the same turn works because SwiftUI evaluates the
    /// window's body after the scene is installed, by which point `sheet` is already set.
    public func present(_ route: SheetRoute) {
        popover = .menu
        showMainWindow()
        sheet = route
    }

    /// The start panel. From the menu bar it replaces the popover's contents; from the window it is
    /// a sheet. Same view, two hosts, and no window is forced open for the menu bar case.
    public func presentStartPanel(inPopover: Bool) {
        if inPopover {
            popover = .startSession
        } else {
            present(.startSession)
        }
    }

    public func presentReview() {
        present(.sessionReview)
    }

    public func presentAccomplishmentEditor(sessionID: UUID? = nil) {
        present(.addAccomplishment(sessionID: sessionID))
    }

    public func presentProjectEditor(projectID: UUID? = nil) {
        present(.projectEditor(projectID: projectID))
    }

    /// Interruption capture. From the menu bar it replaces the popover's contents; from anywhere else
    /// it is a sheet on the main window.
    ///
    /// The menu bar case is the one that matters: someone is in the middle of a session, and opening
    /// a window in front of them to take one line would cost more attention than the interruption
    /// did. `⌘⇧I` is never unavailable, with or without a session (`04-screens.md` § 5.4).
    public func presentCapture(inPopover: Bool) {
        if inPopover {
            popover = .captureInterruption
        } else {
            present(.captureInterruption)
        }
    }

    /// The interruption inbox, pushed onto Today rather than presented as a sheet.
    ///
    /// Processing the inbox is a place you go, not a dialogue you answer: it is a list you work
    /// through, one row at a time, and a modal that has to be dismissed before you can look at
    /// anything else is the wrong shape for that. `Today` is its parent because that is where
    /// `SPEC.md` § 7 puts the inbox.
    public func presentInbox() {
        popover = .menu
        showMainWindow()
        section = .today
        detailPath = NavigationPath()
        detailPath.append(InboxRoute.inbox)
    }

    /// Dismisses whatever panel is up. `Esc` and every Cancel button route through here.
    public func dismissSheet() {
        sheet = nil
    }

    /// Returns the popover to its idle menu. Called when the popover closes and after an inline
    /// panel finishes, so it never reopens mid-flow.
    public func resetPopover() {
        popover = .menu
    }

    // MARK: - Window

    /// AppKit is used for activation only: a menu bar popover can open a window but cannot bring the
    /// application forward, and `NSApplication.activate()` is the only thing that does.
    public func showMainWindow() {
        openMainWindow?()
        NSApp.activate()
    }
}

// MARK: - Push destinations

/// The detail column's push destinations.
///
/// One case so far. It is an enum rather than a bare marker type because `NavigationPath` matches on
/// the value's type, and a named case is what makes the destination readable at the call site.
public enum InboxRoute: Hashable, Sendable {
    /// The interruption inbox, pushed on top of Today.
    case inbox
}
