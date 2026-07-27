import AppKit
import Foundation
import LggrKit

/// Stops a second Lggr from opening onto the same data folder.
///
/// ### Why this exists
///
/// Two instances of Lggr are not two windows on one document; they are two whole-document writers with
/// no coordination between them. `JSONFileStore` now refuses to overwrite a file that changed
/// underneath it, so the second instance can no longer erase the first one's history — but the user is
/// left with two apps arguing over one file and a notice explaining it. Not launching the second one is
/// the better outcome, and the real-world trigger is mundane: a copy in `/Applications` and a
/// development build, or a relaunch while the old process is still winding down.
///
/// ### The mechanism, and how it survives a crash
///
/// A `flock` advisory lock on `instance.lock` in the store folder. The lock lives on an open file
/// descriptor, and the kernel closes every descriptor a process owns when the process dies — a clean
/// quit, an uncaught crash, a `SIGKILL`, a force-quit, a panic. There is therefore **no such thing as a
/// stale lock**: the file may be left behind, but the lock on it is not, and the next launch acquires
/// it immediately. A lock implemented as "a file exists" or "a pid is written down" would need
/// liveness checks and a recovery path, and would lock the user out of their own app the first time one
/// of them was wrong.
///
/// The pid is written into the file, but only as a hint for *activating* the other instance. It is
/// verified through `NSRunningApplication` before it is used, and nothing about correctness depends on
/// it being accurate.
///
/// ### Why the store folder and not the bundle identifier
///
/// The resource being protected is the data folder, not the application. Keying on the folder means a
/// development build and the shipped copy exclude each other — they share a folder and a bundle
/// identifier is no help there — while `Scripts/smoke.sh`, which points `LGGR_STORE_DIR` at a throwaway
/// directory, gets its own lock and can still be run while the user's real Lggr is open.
@MainActor
enum SingleInstanceGuard {

    enum Outcome: Equatable {
        /// This process owns the folder.
        case acquired
        /// Another live process owns it. The pid is a hint, not a guarantee.
        case alreadyRunning(pid: pid_t?)
        /// The lock could not be used at all. Launch anyway — see `installOrExit`.
        case unavailable(reason: String)
    }

    static let lockFileName = "instance.lock"

    /// Held for the life of the process. Closing it would release the lock, so it is never closed.
    private static var lockDescriptor: Int32?

    /// The launch-time check. Called before any scene is built.
    ///
    /// A failure to lock is never allowed to stop a launch. If the folder cannot be locked the app
    /// starts anyway: the store's own external-change refusal is the guarantee that data survives, and
    /// this guard is only here to spare the user the situation. Refusing to launch because a lock file
    /// could not be opened would be trading a rare annoyance for a total loss of the app.
    static func installOrExit() {
        guard let directory = try? LggrStoreLocation.baseDirectory() else { return }

        switch acquire(for: directory) {
        case .acquired, .unavailable:
            return
        case .alreadyRunning(let pid):
            activate(pid: pid)
            // Not `NSApp.terminate`: no application object is running yet, and the running instance
            // must not be sent a terminate reply meant for this one.
            exit(0)
        }
    }

    /// Takes the lock on `directory`, creating it if needed.
    static func acquire(for directory: URL) -> Outcome {
        if lockDescriptor != nil { return .acquired }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }

        let url = directory.appendingPathComponent(lockFileName, isDirectory: false)
        let descriptor = open(url.path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            return .unavailable(reason: String(cString: strerror(errno)))
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            let pid = readPID(from: descriptor)
            close(descriptor)
            // `EWOULDBLOCK` is the only answer that means "somebody else has it". Anything else is a
            // filesystem that does not support locking — a network volume, say — and must not be read
            // as another instance, or the app would refuse to launch for good.
            return failure == EWOULDBLOCK
                ? .alreadyRunning(pid: pid)
                : .unavailable(reason: String(cString: strerror(failure)))
        }

        lockDescriptor = descriptor
        writePID(to: descriptor)
        return .acquired
    }

    /// Brings the instance that owns the folder to the front, so the user sees their app rather than
    /// nothing at all happening.
    private static func activate(pid: pid_t?) {
        if let pid, let running = NSRunningApplication(processIdentifier: pid) {
            running.activate(options: [.activateAllWindows])
            return
        }

        // The pid in the file was stale or unusable. Fall back to the bundle identifier, which is
        // right in the common case of two launches of the same build.
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        others.first?.activate(options: [.activateAllWindows])
    }

    private static func writePID(to descriptor: Int32) {
        guard ftruncate(descriptor, 0) == 0 else { return }
        let text = "\(ProcessInfo.processInfo.processIdentifier)\n"
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return pwrite(descriptor, base, buffer.count, 0)
        }
    }

    private static func readPID(from descriptor: Int32) -> pid_t? {
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            return pread(descriptor, base, pointer.count, 0)
        }
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        guard let value = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid_t(value)
    }
}
