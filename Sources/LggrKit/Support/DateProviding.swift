import Foundation

/// Supplies "now".
///
/// Every duration in Lggr is derived from stored `Date`s rather than from an incrementing counter,
/// so the only thing tests need in order to drive a session through hours of behaviour in
/// microseconds is control over this one value.
public protocol DateProviding: Sendable {
    var now: Date { get }
}

/// The real clock.
public struct SystemClock: DateProviding {
    public init() {}
    public var now: Date { Date() }
}

/// A clock that stands still until moved, for tests and fixtures.
///
/// Reference semantics are deliberate: a `SessionManager` handed this clock and a test holding the
/// same instance must observe the same time, so that advancing it from the test is visible to the
/// code under test.
public final class FixedClock: DateProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date) {
        self.current = start
    }

    public var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Moves the clock forward. Negative intervals are allowed so that backwards clock adjustments
    /// — a user correcting their timezone, an NTP step — can be exercised.
    public func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}
