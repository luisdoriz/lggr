import Carbon.HIToolbox
import Foundation
import LggrKit

// Carbon, deliberately and with a reason worth writing down.
//
// `RegisterEventHotKey` is still the supported way to claim a system-wide key combination, and it is
// the only one that needs **no permission at all**. The modern-looking alternative, `CGEventTap`,
// requires an Accessibility grant — and Lggr requests zero permissions today, which is a property of
// this app worth more than the aesthetics of the API that keeps it.
//
// Everything here is a shell. All of the knowledge — which token maps to which virtual key code, what
// a combination looks like on screen, whether it is safe to register at all — lives in
// `LggrKit/Model/GlobalShortcut.swift`, where it is unit-tested. AppKit-bound code cannot be tested
// on this machine, so the code that cannot be tested is kept too thin to be wrong.

/// Registers the global hot keys and dispatches each one to a handler.
///
/// Three rules shape this type:
///
/// 1. **A registration that failed is reported, never swallowed.** A combination already claimed by
///    another application cannot be registered, and the only alternative to telling the user is
///    leaving them to press a dead key and conclude the app is broken. `failures` is observable and
///    Settings renders it.
/// 2. **A key that cannot be mapped fails visibly.** `virtualKeyCode` returning `nil` produces a
///    `Failure`, not a skipped iteration. Binding nothing quietly is the exact defect this feature
///    was written to end.
/// 3. **`apply(_:)` is the whole state.** It unregisters everything before it registers anything, so
///    changing one shortcut cannot leak the previous one — and calling it twice with the same
///    bindings leaves the same registrations, not two sets of them.
@MainActor
@Observable
public final class GlobalShortcutService {

    // MARK: - Failures

    /// Why one registration did not happen.
    public enum FailureReason: Hashable, Sendable {

        /// The key token has no virtual key code — a shortcut naming a key this build cannot register.
        case unmappableKey

        /// No `⌘`, `⌃` or `⌥`, so registering it would swallow ordinary typing system-wide.
        case unsafeCombination

        /// Another application — or the system — already holds this combination.
        case alreadyTaken

        /// Another Lggr action is bound to the same keys, and it was registered first.
        case duplicateBinding(GlobalShortcutAction)

        /// No handler was installed for the action, so registering it would produce a dead key.
        ///
        /// This is a wiring mistake rather than anything the user did, and it is surfaced rather than
        /// tolerated for that reason: a hot key with nothing behind it is indistinguishable, from the
        /// outside, from a hot key the system refused.
        case noHandler

        /// `RegisterEventHotKey` refused for some other reason, carrying its `OSStatus`.
        case systemRefused(Int32)
    }

    /// One failed registration, in the shape Settings lists.
    public struct Failure: Identifiable, Hashable, Sendable {

        public let action: GlobalShortcutAction
        public let shortcut: GlobalShortcut
        public let reason: FailureReason

        public var id: GlobalShortcutAction { action }

        /// One plain sentence, and a way out of it.
        ///
        /// Phrased as `04-screens.md` § 5.5 phrases it, because that is the copy the onboarding page
        /// and the Shortcuts pane both show.
        public var message: String {
            switch reason {
            case .alreadyTaken:
                "\(shortcut.displayString) is already taken by another app. Pick a different "
                    + "combination."
            case .duplicateBinding(let owner):
                "\(shortcut.displayString) is already used for \"\(owner.title)\". Pick a different "
                    + "combination."
            case .unsafeCombination:
                "\(shortcut.displayString) needs ⌘, ⌃ or ⌥ to work as a global shortcut."
            case .unmappableKey:
                "Lggr can't use \(shortcut.displayString) as a global shortcut. Pick a different "
                    + "combination."
            case .noHandler:
                "\(shortcut.displayString) isn't connected to anything yet, so it hasn't been "
                    + "registered."
            case .systemRefused:
                "macOS declined to register \(shortcut.displayString). Pick a different combination."
            }
        }
    }

    // MARK: - Observable state

    /// Every registration that did not happen, in action-declaration order. Empty is the good case.
    public private(set) var failures: [Failure] = []

    /// The actions whose hot key is live right now.
    public private(set) var registeredActions: Set<GlobalShortcutAction> = []

    // MARK: - Collaborators

    /// What each action does. Set once by the composition root; independent of the bindings, which the
    /// user changes.
    @ObservationIgnored private var handlers: [GlobalShortcutAction: @MainActor () -> Void] = [:]

    /// The live Carbon registrations, so every one of them can be handed back.
    @ObservationIgnored private var live: [GlobalShortcutAction: LiveRegistration] = [:]

    /// The bindings currently asked for, so `reapply()` can repeat them after handlers change.
    @ObservationIgnored private var requested: [GlobalShortcutAction: GlobalShortcut] = [:]

    private struct LiveRegistration {
        let hotKeyID: UInt32
        let reference: EventHotKeyRef
    }

    public init() {}

    // MARK: - Wiring

    /// Connects an action to what it does.
    ///
    /// Separate from `apply(_:)` because the two change on different schedules: handlers are installed
    /// once at launch and never again, bindings change whenever the user edits one.
    public func setHandler(
        for action: GlobalShortcutAction,
        _ handler: @escaping @MainActor () -> Void
    ) {
        handlers[action] = handler
    }

    /// Whether an action has somewhere to go. Settings uses it to explain a `.noHandler` row.
    public func hasHandler(for action: GlobalShortcutAction) -> Bool {
        handlers[action] != nil
    }

    // MARK: - Registering

    /// Registers exactly `bindings` and nothing else.
    ///
    /// Every previous registration is handed back first, so this is the one call that changes what is
    /// live: there is no `add` and no `remove`, and therefore no way to accumulate a stale hot key
    /// that no setting mentions. Idempotent.
    ///
    /// - Returns: the failures, also published on `failures`, so a caller that wants to react at once
    ///   does not have to observe.
    @discardableResult
    public func apply(_ bindings: [GlobalShortcutAction: GlobalShortcut]) -> [Failure] {
        requested = bindings
        unregisterAll()

        var problems: [Failure] = []
        var claimed: [GlobalShortcut: GlobalShortcutAction] = [:]

        // Declaration order, not dictionary order: which of two colliding actions is told to pick
        // something else has to be the same on every launch.
        for action in GlobalShortcutAction.allCases {
            guard let shortcut = bindings[action] else { continue }

            if let owner = claimed[shortcut] {
                problems.append(
                    Failure(action: action, shortcut: shortcut, reason: .duplicateBinding(owner)))
                continue
            }

            if let reason = register(action: action, shortcut: shortcut) {
                problems.append(Failure(action: action, shortcut: shortcut, reason: reason))
            } else {
                claimed[shortcut] = action
            }
        }

        failures = problems
        registeredActions = Set(live.keys)
        return problems
    }

    /// Repeats the last `apply(_:)`.
    ///
    /// For the one ordering that otherwise bites: handlers installed after the first `apply` would
    /// leave `.noHandler` failures standing for hot keys that are now perfectly connected.
    @discardableResult
    public func reapply() -> [Failure] {
        apply(requested)
    }

    /// Hands back every registration. The handlers stay — they are wiring, not state.
    public func stop() {
        unregisterAll()
        failures = []
        registeredActions = []
    }

    /// The failure for one action, for the inline line under its row in Settings.
    public func failure(for action: GlobalShortcutAction) -> Failure? {
        failures.first { $0.action == action }
    }

    // MARK: - Carbon

    /// - Returns: `nil` on success, or why it failed.
    private func register(action: GlobalShortcutAction, shortcut: GlobalShortcut) -> FailureReason? {
        guard let keyCode = shortcut.virtualKeyCode else { return .unmappableKey }
        guard shortcut.isValidGlobalCombination else { return .unsafeCombination }
        guard handlers[action] != nil else { return .noHandler }

        let hotKeyID = HotKeyDispatch.shared.nextID()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            shortcut.modifiers.carbonMask,
            EventHotKeyID(signature: Self.signature, id: hotKeyID),
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            // -9878. Returned when the combination is already held; the honest caveat is that some
            // system-reserved combinations register successfully and then simply never fire, which no
            // API on macOS lets us detect. Those we cannot report, and do not pretend to.
            if status == OSStatus(eventHotKeyExistsErr) { return .alreadyTaken }
            return .systemRefused(status)
        }

        HotKeyDispatch.shared.setHandler(id: hotKeyID) { [weak self] in
            self?.handlers[action]?()
        }
        live[action] = LiveRegistration(hotKeyID: hotKeyID, reference: reference)
        return nil
    }

    private func unregisterAll() {
        for registration in live.values {
            UnregisterEventHotKey(registration.reference)
            HotKeyDispatch.shared.removeHandler(id: registration.hotKeyID)
        }
        live.removeAll()
    }

    /// `'lggr'` as a four-character code, written as the integer it is so there is no unwrapping to
    /// get from a `String` to an `OSType`.
    private static let signature: OSType = 0x6C67_6772
}

// MARK: - Dispatch

/// The bridge between a C callback and a Swift closure.
///
/// `InstallEventHandler` takes a bare C function pointer, which cannot capture anything, so the
/// mapping from hot-key id to closure has to live somewhere reachable without context. This is that
/// somewhere: one handler installed on the application event target, one table, ids that are unique
/// for the life of the process.
///
/// A table rather than an `Unmanaged` pointer to the service: a dangling pointer in an event callback
/// is a crash in the one code path that is meant to feel instant, and the table cannot dangle.
@MainActor
private final class HotKeyDispatch {

    static let shared = HotKeyDispatch()

    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var lastID: UInt32 = 0

    /// Monotonic, and never reused inside a run. Reusing an id would let a hot key unregistered a
    /// moment ago deliver into the closure of its replacement.
    func nextID() -> UInt32 {
        lastID += 1
        return lastID
    }

    func setHandler(id: UInt32, _ handler: @escaping () -> Void) {
        install()
        handlers[id] = handler
    }

    func removeHandler(id: UInt32) {
        handlers[id] = nil
        if handlers.isEmpty { uninstall() }
    }

    func dispatch(id: UInt32) {
        handlers[id]?()
    }

    private func install() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // A failure here is not recoverable and not worth a banner: no hot key can have been
        // registered yet, so `apply(_:)` will report every one of them as refused.
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventCallback,
            1,
            &spec,
            nil,
            &eventHandler
        )
    }

    private func uninstall() {
        guard let eventHandler else { return }
        RemoveEventHandler(eventHandler)
        self.eventHandler = nil
    }
}

/// The C entry point. Carbon delivers hot keys on the main run loop, and the `Thread.isMainThread`
/// branch is there so that a delivery from anywhere else hops instead of trapping.
private func hotKeyEventCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    if Thread.isMainThread {
        MainActor.assumeIsolated { HotKeyDispatch.shared.dispatch(id: id) }
    } else {
        Task { @MainActor in HotKeyDispatch.shared.dispatch(id: id) }
    }
    return noErr
}
