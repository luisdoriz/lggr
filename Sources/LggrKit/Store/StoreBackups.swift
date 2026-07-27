import Foundation

/// Rotating local copies of `store.json`, so a bad write is survivable.
///
/// Lggr keeps the only copy of the user's working history. Atomic writes guarantee that a *failed*
/// write leaves the previous file intact, but they guarantee nothing about a write that succeeds and
/// is wrong — a second instance overwriting the file, a restore undone by a running app, a delete the
/// user did not mean. A backup is the only thing that covers those.
///
/// ### Why one per day, keeping seven
///
/// A copy per launch is the obvious design and the wrong one: Lggr is a menu bar app that gets
/// relaunched several times a day, so seven per-launch copies can cover an afternoon. Worse, a bad
/// write followed by two relaunches would rotate every good copy out within the hour — the backup
/// would reliably be destroyed by exactly the fault it exists for.
///
/// One dated copy per day, keeping seven, covers a week: long enough that a user who notices "my
/// Tuesday sessions are gone" on Friday still has Tuesday, and small enough that the folder holds
/// seven files of a few kilobytes each. The daily stamp also does the rotation for us — a second
/// launch on the same day finds the day's backup already there and leaves it alone, which is the
/// right answer rather than a shortcut: the earlier copy was taken before whatever went wrong today.
///
/// ### Why an empty document is not allowed to displace a full one
///
/// The defect these backups protect against — an instance that starts empty and writes its empty
/// snapshot over a full file — produces an *empty store*. If an empty store could take a backup slot,
/// the first launch after the fault would rotate out the one copy that could have saved the user. So
/// an empty document is never backed up while a backup with content exists, and rotation always sheds
/// empty backups before it touches one with content.
public enum StoreBackups {

    /// Subdirectory of the store's own folder. For the shipping store that is
    /// `LggrStoreLocation.baseDirectory()/backups`, so `LGGR_STORE_DIR` redirects the backups too and
    /// a test can never write into the real user's folder.
    public static let directoryName = "backups"

    /// One week of daily copies. See the type documentation for why seven and not "one per launch".
    public static let keepCount = 7

    private static let filePrefix = "store-"
    private static let fileSuffix = ".json"

    /// Where backups for the document at `storeURL` live.
    ///
    /// Derived from the document's own location rather than from `LggrStoreLocation` directly: the
    /// store may be opened at an arbitrary path (a test, an import), and a backup must always land
    /// beside the file it is a backup *of* — never in the real user's folder because a default was
    /// consulted.
    public static func directory(forStoreAt storeURL: URL) -> URL {
        storeURL
            .deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// The filename a backup taken on `date` gets.
    ///
    /// `yyyyMMdd` in UTC, fixed width, so sorting the names sorts the backups chronologically and no
    /// separate index is needed.
    public static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        return "\(filePrefix)\(formatter.string(from: date))\(fileSuffix)"
    }

    /// Every backup in `directory`, oldest first.
    public static func existingBackups(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(fileSuffix) }
            .sorted()
            .map { directory.appendingPathComponent($0, isDirectory: false) }
    }

    /// Copies the document at `storeURL` into the backups folder, then prunes.
    ///
    /// - Returns: the backup that was written, or `nil` when none was needed — no document yet, the
    ///   day's backup already taken, or an empty document that must not displace one with content.
    /// - Throws: `StoreError.persistenceFailure` if the folder or the copy could not be written.
    @discardableResult
    public static func capture(
        storeAt storeURL: URL,
        on date: Date = Date(),
        keeping keepCount: Int = StoreBackups.keepCount
    ) throws -> URL? {
        let limit = max(1, keepCount)
        let fileManager = FileManager.default

        // No document is not a failure: a genuine first launch has nothing to preserve.
        guard fileManager.fileExists(atPath: storeURL.path),
            let data = try? Data(contentsOf: storeURL)
        else {
            return nil
        }

        let directory = directory(forStoreAt: storeURL)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not create \(directory.path): \(error.localizedDescription)"
            )
        }

        let existing = existingBackups(in: directory)
        let destination = directory.appendingPathComponent(fileName(for: date), isDirectory: false)

        // The day's backup is already there. Leave it: it was taken before whatever happened since,
        // so it is the better copy of the two by definition.
        guard !fileManager.fileExists(atPath: destination.path) else { return nil }

        // The subtle rule. An empty document takes a slot only when there is no copy with content to
        // lose — otherwise the fault that empties the store would rotate out its own remedy.
        if !hasContent(data) && existing.contains(where: hasContent) { return nil }

        try AtomicFileWriter.write(data, to: destination)
        prune(in: directory, keeping: limit)
        return destination
    }

    /// Rotates the folder down to `limit` files.
    ///
    /// Empty backups go first, oldest first, and a backup with content is only removed once no empty
    /// one is left to remove. Plain oldest-first pruning would happily delete the last full copy while
    /// keeping six empty ones written by a broken instance.
    private static func prune(in directory: URL, keeping limit: Int) {
        var remaining = existingBackups(in: directory)

        while remaining.count > limit {
            let index =
                remaining.firstIndex { !hasContent($0) }
                ?? remaining.startIndex
            // Best effort: a backup that will not delete is not worth failing a good save over, and
            // the loop cannot spin because the entry is dropped from `remaining` either way.
            try? FileManager.default.removeItem(at: remaining[index])
            remaining.remove(at: index)
        }
    }

    /// Whether a document is worth keeping in preference to another.
    ///
    /// A file that cannot be decoded counts as content. It is the user's data in some form — a newer
    /// schema, a build we do not know — and the one thing we must not do is prefer to delete it
    /// because we could not read it.
    private static func hasContent(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return true }
        return hasContent(data)
    }

    private static func hasContent(_ data: Data) -> Bool {
        // Zero bytes is a truncated write, not a document. It has nothing to protect and must never
        // outrank something that does.
        guard !data.isEmpty else { return false }
        guard let snapshot = try? StoreSnapshot.makeDecoder().decode(StoreSnapshot.self, from: data)
        else {
            return true
        }
        return !snapshot.isEmpty
    }
}
