import Foundation

/// The one definition of how stored history is ordered.
///
/// Both conformers of `LggrStore` call these. When each store sorted for itself, the in-memory fake
/// broke ties by `id` and the file-backed store did not, so two records saved in the same instant
/// came back in a different order depending on which backend was running — and the fake was what
/// every unit test exercised. `Swift.sort` is not documented as stable either, so "leave equal
/// elements alone" is not a behaviour a store can rely on across runs.
enum StoreOrdering {

    /// Newest first, ties broken by `id` so the order is stable across runs and across backends.
    static func newestFirst(_ lhs: FocusSession, _ rhs: FocusSession) -> Bool {
        lhs.startedAt == rhs.startedAt
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.startedAt > rhs.startedAt
    }

    static func newestFirst(_ lhs: Accomplishment, _ rhs: Accomplishment) -> Bool {
        lhs.timestamp == rhs.timestamp
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.timestamp > rhs.timestamp
    }

    static func newestFirst(_ lhs: Interruption, _ rhs: Interruption) -> Bool {
        lhs.timestamp == rhs.timestamp
            ? lhs.id.uuidString > rhs.id.uuidString
            : lhs.timestamp > rhs.timestamp
    }

    /// Newest week first, then most recently declared, then `id`.
    ///
    /// `createdAt` sits in the middle because every outcome belonging to one week carries the *same*
    /// `weekStartDate` — that is what the field is for. Ordering on the week alone would therefore
    /// leave the order of a week's own list entirely to whichever `UUID` sorts first: stable, but
    /// unrelated to anything the user did.
    static func newestFirst(_ lhs: WeeklyOutcome, _ rhs: WeeklyOutcome) -> Bool {
        if lhs.weekStartDate != rhs.weekStartDate { return lhs.weekStartDate > rhs.weekStartDate }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    /// Whether a timestamp belongs to a window.
    ///
    /// Half-open — `start <= date < end` — because `Calendar.dateInterval(of:for:)` hands back
    /// windows where one day's `end` is exactly the next day's `start`. `DateInterval.contains` is
    /// closed, so a record stamped at exactly midnight would appear in both days and a per-day
    /// breakdown would not add up to the week.
    static func contains(_ date: Date, in interval: DateInterval) -> Bool {
        date >= interval.start && date < interval.end
    }
}
