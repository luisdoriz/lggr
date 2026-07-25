import Foundation

/// How hard a write pushes before it claims to be done.
///
/// The two cases are not two levels of quality; they are two different promises, and which one a
/// record deserves depends on what losing it costs.
public enum FileDurability: Sendable, Equatable {

    /// The bytes are handed to the kernel. Any reader — this process or the next one — sees them
    /// immediately, and they survive a crash, a force quit and a `kill -9`. A power cut in the
    /// seconds that follow may not find them on the platter.
    case buffered

    /// The bytes are forced out of the buffer cache and onto the device with `F_FULLFSYNC` before
    /// this returns. Costs a physical disk sync — tens of milliseconds, and real energy on a laptop.
    case deviceSynced
}

/// Adds bytes to the end of a file without reading or rewriting what is already in it.
///
/// The sibling of `AtomicFileWriter`, and deliberately not a replacement for it. `AtomicFileWriter`
/// answers "this document must be either wholly the old one or wholly the new one, and it must be on
/// the platter" — which is what `store.json` needs, because a lost focus session is a lost hour of
/// the user's record with no server copy to fall back on. Nothing here weakens that.
///
/// This one answers a different question, asked by ambient telemetry. A day of app-switch history is
/// an append-only log: the only thing a flush does is add a few hundred bytes at the end. Rewriting
/// the whole day to do that is O(day) per flush, and forcing a device sync each time is 1,440
/// physical syncs a day for records whose worst-case loss — the last few seconds of which
/// application was frontmost — the timeline already renders honestly as an absence.
///
/// So: `O_APPEND` and an ordinary buffered write by default, `F_FULLFSYNC` only at the boundaries
/// where capture is about to stop and the loss would no longer be seconds.
///
/// **The cost is paid in the reader, not hidden.** A power cut mid-append can leave a partial record
/// at the end of the file, so any format written through here has to be one whose reader tolerates a
/// torn final record. `ActivityLog`'s day files are JSON Lines for exactly that reason.
public enum AppendOnlyFileWriter {

    /// Appends `data` to the end of `url`, creating the file and its directory if they are absent.
    ///
    /// `O_APPEND` rather than seek-then-write: the kernel resolves the offset and the write as one
    /// operation, so two writers — or one writer and a reader that just grew the file — cannot land
    /// on top of each other.
    ///
    /// - Throws: `StoreError.persistenceFailure` with the failing path and the underlying reason.
    public static func append(_ data: Data, to url: URL, durability: FileDurability) throws {
        guard !data.isEmpty else { return }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.persistenceFailure(
                "Could not create \(directory.path): \(error.localizedDescription)"
            )
        }

        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw StoreError.persistenceFailure(
                "Could not open \(url.path) to append: \(String(cString: strerror(errno)))"
            )
        }
        defer { close(descriptor) }

        try writeAll(data, to: descriptor, path: url.path)

        guard durability == .deviceSynced else { return }

        guard fcntl(descriptor, F_FULLFSYNC) != -1 else {
            throw StoreError.persistenceFailure(
                "Could not flush \(url.path) to disk: \(String(cString: strerror(errno)))"
            )
        }
        // The file may have been created by this very call, in which case its name lives only in the
        // directory. Best-effort, exactly as in `AtomicFileWriter`: a directory that cannot be
        // flushed is not worth failing an otherwise good write.
        flushDirectory(directory)
    }

    /// `write(2)` is allowed to accept fewer bytes than it was offered, and to be interrupted by a
    /// signal without having written anything. Neither is an error, and neither may be treated as a
    /// completed append — a short write that went unnoticed is precisely how a log grows a record
    /// that is missing its middle.
    private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
        try data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count

            while remaining > 0 {
                let written = write(descriptor, cursor, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw StoreError.persistenceFailure(
                        "Could not append to \(path): \(String(cString: strerror(errno)))"
                    )
                }
                if written == 0 {
                    throw StoreError.persistenceFailure(
                        "Could not append to \(path): the write made no progress."
                    )
                }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func flushDirectory(_ directory: URL) {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fcntl(descriptor, F_FULLFSYNC)
    }
}
