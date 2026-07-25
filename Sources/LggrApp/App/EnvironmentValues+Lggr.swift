import Foundation
import LggrKit
import SwiftUI

// `@Entry` is a SwiftUI macro and `libSwiftUIMacros.dylib` ships only inside Xcode
// (`CONSTRAINTS.md`), so every key below is written out by hand. That is the whole reason this file
// exists rather than five one-line declarations.
//
// The two reference-type keys are **optional**, and deliberately so. `EnvironmentKey.defaultValue`
// is read from a non-isolated context, and `SessionManager` and `AppModel` are `@MainActor`, so
// neither can supply a real default without either constructing a main-actor object off the main
// actor or force-unwrapping at every call site. An optional default of `nil` is honest: it says
// "this was not injected", and a view can decide what that means instead of trapping.
//
// Both objects are also `@Observable`, so `.environment(sessionManager)` /
// `@Environment(SessionManager.self)` works with no declarations at all. `lggrEnvironment(_:_:)`
// below installs both routes at once, so a view may use whichever reads better.

// MARK: - Session manager

private struct SessionManagerKey: EnvironmentKey {
    // Computed rather than `static let`: a stored global of a non-`Sendable` type is a concurrency
    // hazard the compiler is right to complain about, and there is nothing to store.
    static var defaultValue: SessionManager? { nil }
}

// MARK: - App model

private struct AppModelKey: EnvironmentKey {
    static var defaultValue: AppModel? { nil }
}

// MARK: - Clock

private struct ClockKey: EnvironmentKey {
    /// `DateProviding` is `Sendable` and `SystemClock` is a value type, so this one *can* have a real
    /// default. A leaf view that formats a date does not need the whole environment rebuilt to be
    /// handed a fixed clock.
    static var defaultValue: any DateProviding { SystemClock() }
}

// MARK: - Gallery mode

private struct GalleryModeKey: EnvironmentKey {
    /// True inside the `LGGR_GALLERY=1` window, where views render against fixtures and must not
    /// start timers or write to the store.
    static var defaultValue: Bool { false }
}

extension EnvironmentValues {

    public var sessionManager: SessionManager? {
        get { self[SessionManagerKey.self] }
        set { self[SessionManagerKey.self] = newValue }
    }

    public var appModel: AppModel? {
        get { self[AppModelKey.self] }
        set { self[AppModelKey.self] = newValue }
    }

    public var clock: any DateProviding {
        get { self[ClockKey.self] }
        set { self[ClockKey.self] = newValue }
    }

    public var isGalleryMode: Bool {
        get { self[GalleryModeKey.self] }
        set { self[GalleryModeKey.self] = newValue }
    }
}

extension View {

    /// Installs the app's two state objects, by key path *and* by Observable type.
    ///
    /// Applied once per scene. Doing both is a few bytes and removes an entire category of "it
    /// compiled but the environment was empty" bug, because a view may read either
    /// `@Environment(\.sessionManager)` or `@Environment(SessionManager.self)` and get the same
    /// instance.
    public func lggrEnvironment(_ sessionManager: SessionManager, _ appModel: AppModel) -> some View {
        self
            .environment(\.sessionManager, sessionManager)
            .environment(\.appModel, appModel)
            .environment(sessionManager)
            .environment(appModel)
    }
}
