import Foundation

/// Writes a file in a way that leaves either the old contents or the new contents behind, never a
/// half-written file.
///
/// The sequence is: write a sibling temporary file, flush it to stable storage, then hand it to
/// `FileManager.replaceItemAt`, which swaps it into place. A crash, a full disk or a kill signal at
/// any point in that sequence leaves the previous file untouched, so a failed save costs the last
/// change rather than the log.
///
/// The flush is not incidental. `Data.write(options: .atomic)` and `replaceItemAt` are renames, and
/// a rename returning success only means the change reached the buffer cache. Without
/// `F_FULLFSYNC`, a power loss shortly after a save can leave the file holding its previous
/// contents even though the app told the user the session was recorded. This is a local-first app
/// with no server copy, so "we said it was saved" has to mean it is on the platter.
public enum AtomicFileWriter {

    /// Writes `data` to `url`, creating intermediate directories as needed.
    ///
    /// - Throws: `StoreError.persistenceFailure` with the failing path and the underlying reason.
    public static func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not create \(directory.path): \(error.localizedDescription)"
            )
        }

        // A dot-prefixed sibling: same volume, so the replace is a rename rather than a copy, and
        // hidden from a user who happens to be looking at the folder mid-save.
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )

        do {
            try data.write(to: temporaryURL, options: .atomic)
            try flushToStableStorage(temporaryURL)
        } catch let error as StoreError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw StoreError.persistenceFailure(
                "Could not write \(temporaryURL.path): \(error.localizedDescription)"
            )
        }

        do {
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                // `replaceItemAt` requires something to replace, so the first ever write is a move.
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw StoreError.persistenceFailure(
                "Could not replace \(url.path): \(error.localizedDescription)"
            )
        }

        // Flush the directory as well, so the rename itself survives a power loss rather than the
        // file contents landing while the name still points at the old inode.
        flushDirectory(directory)
    }

    /// Forces the file's bytes out of the buffer cache and onto the device.
    ///
    /// `F_FULLFSYNC` rather than `fsync`: on macOS, `fsync` only guarantees the data left the OS
    /// cache, not that the drive committed it from its own write cache.
    private static func flushToStableStorage(_ url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not open \(url.path) to flush it: \(error.localizedDescription)"
            )
        }
        defer { try? handle.close() }

        guard fcntl(handle.fileDescriptor, F_FULLFSYNC) != -1 else {
            throw StoreError.persistenceFailure(
                "Could not flush \(url.path) to disk: \(String(cString: strerror(errno)))"
            )
        }
    }

    /// Best-effort: a directory that cannot be flushed is not worth failing an otherwise good save.
    private static func flushDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_FULLFSYNC)
    }
}
