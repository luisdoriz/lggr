import Foundation

/// What a file looked like the last time we read it, so a writer can tell whether it is still
/// looking at the same file it loaded.
///
/// **Modification date *and* size.** A same-second rewrite — a `cp` of a backup, a sync client, a
/// second instance saving twice in quick succession — can leave the modification date byte-identical
/// to what we recorded, because the filesystem's timestamp resolution is not guaranteed to be finer
/// than the interval between the two writes. Size catches the rewrites that the date misses, and the
/// date catches the rewrites that keep the size (an edited outcome string of the same length). Either
/// one alone has a blind spot; together they have none that matters at this scale.
///
/// An unreadable-but-present file reports `.absent`. That is deliberate: it makes the comparison fail
/// rather than succeed, and a failed comparison refuses to write. Every ambiguity in this type must
/// resolve towards "do not overwrite".
public enum StoreFileIdentity: Equatable, Sendable, CustomStringConvertible {

    /// No file — either never written, or moved aside, or deleted underneath us.
    case absent

    /// A file we could stat. `size` is `-1` when the attribute was present but not a number, which
    /// again makes comparisons fail rather than pass.
    case present(modifiedAt: Date?, size: Int)

    /// Stats `url` now.
    public static func read(_ url: URL) -> StoreFileIdentity {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .absent
        }

        let size: Int
        if let number = attributes[.size] as? NSNumber {
            size = number.intValue
        } else if let value = attributes[.size] as? Int {
            size = value
        } else {
            size = -1
        }

        return .present(modifiedAt: attributes[.modificationDate] as? Date, size: size)
    }

    public var isAbsent: Bool {
        self == .absent
    }

    /// Phrased for a user reading an alert, not for a log.
    public var description: String {
        switch self {
        case .absent:
            return "no file"
        case .present(let modifiedAt, let size):
            let bytes = size >= 0 ? "\(size) bytes" : "an unreadable size"
            guard let modifiedAt else { return bytes }
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            return "\(bytes), last changed \(formatter.string(from: modifiedAt))"
        }
    }
}

/// Remembers the identity of the file a document was loaded from, and refuses to agree that a
/// different file is the same one.
///
/// This is the whole of the fix for the defect it exists to close: a store that loads once and then
/// writes its in-memory snapshot back forever will silently erase anything another writer put in the
/// file — a second copy of the app, a second launch, or a user restoring a backup while the app is
/// open. The guard turns that silent overwrite into a refusal.
public struct StoreFileGuard: Sendable {

    /// The answer to "is this still the file I read?".
    public enum Verdict: Equatable, Sendable {
        case unchanged
        case changed(expected: StoreFileIdentity, found: StoreFileIdentity)
    }

    /// `nil` until something has actually been read or written.
    public private(set) var expectedIdentity: StoreFileIdentity?

    public init(expecting identity: StoreFileIdentity? = nil) {
        self.expectedIdentity = identity
    }

    /// Records what the file looked like at the moment its contents were taken.
    public mutating func adopt(_ identity: StoreFileIdentity) {
        expectedIdentity = identity
    }

    /// Stats `url` and records the result.
    @discardableResult
    public mutating func adoptIdentity(of url: URL) -> StoreFileIdentity {
        let identity = StoreFileIdentity.read(url)
        expectedIdentity = identity
        return identity
    }

    /// Compares an already-stat'd identity against the recorded one.
    ///
    /// With nothing recorded, an absent file is unchanged — that is the genuine first write, which
    /// has to be allowed to create the file. A file that *exists* while we have recorded nothing is
    /// a change: it is content we have never read, and writing over it would lose it.
    public func verify(against found: StoreFileIdentity) -> Verdict {
        guard let expectedIdentity else {
            return found.isAbsent ? .unchanged : .changed(expected: .absent, found: found)
        }
        return expectedIdentity == found
            ? .unchanged
            : .changed(expected: expectedIdentity, found: found)
    }

    /// Stats `url` and compares.
    public func verify(_ url: URL) -> Verdict {
        verify(against: StoreFileIdentity.read(url))
    }
}

/// A write that was refused because the file no longer matched what was loaded, and what happened to
/// the document that was not written.
///
/// The refused document is preserved rather than dropped. Neither copy may be destroyed here: the
/// file on disk may hold records this instance has never seen, and the in-memory document may hold
/// records the user was told were saved.
public struct StoreFileChange: Equatable, Sendable {

    /// What the file looked like when this instance read it.
    public let expected: StoreFileIdentity

    /// What the file looks like now.
    public let found: StoreFileIdentity

    /// The filename the unwritten document was preserved under, when it could be preserved.
    public let preservedAs: String?

    /// Why the unwritten document could not be preserved, when it could not be.
    public let preserveFailure: String?

    public init(
        expected: StoreFileIdentity,
        found: StoreFileIdentity,
        preservedAs: String? = nil,
        preserveFailure: String? = nil
    ) {
        self.expected = expected
        self.found = found
        self.preservedAs = preservedAs
        self.preserveFailure = preserveFailure
    }
}
