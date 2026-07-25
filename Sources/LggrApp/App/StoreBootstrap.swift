import Foundation
import LggrKit

#if canImport(LggrPersistence)
    import LggrPersistence
#endif

/// Chooses the persistence backend at launch.
///
/// This is the only file in the app that knows whether the SwiftData layer was compiled in. The
/// layering check in `Scripts/check-layering.sh` fails the build if that conditional appears
/// anywhere else, because a codebase with the same `#if` scattered through it ends up with two
/// persistence paths that quietly drift apart.
///
/// `LggrPersistence` is present only when the package was built with `LGGR_SWIFTDATA=1`, which
/// requires Xcode — the `@Model` macro cannot compile with Command Line Tools alone. Everywhere
/// else, `JSONFileStore` provides the same `LggrStore` contract against a JSON document.
@MainActor
public enum StoreBootstrap {

    public enum Backend: String, Sendable {
        case swiftData
        case jsonFile
        case inMemory

        public var displayName: String {
            switch self {
            case .swiftData: "SwiftData"
            case .jsonFile: "Local file"
            case .inMemory: "In memory (not saved)"
            }
        }
    }

    /// Not `Sendable`: it carries a live `any LggrStore`, and `LggrStore` is `@MainActor` rather than
    /// `Sendable` — the store is only ever touched from the main actor. Declaring the result sendable
    /// would claim the opposite and is a hard error under the Swift 6 language mode.
    public struct Result {
        public let store: any LggrStore
        public let backend: Backend
        /// Set when the preferred backend could not be opened and a fallback was used. The app shows
        /// this in Settings rather than failing to launch: losing the ability to record work is a
        /// worse outcome than recording it somewhere unexpected, but the user still has to be told.
        public let degradedReason: String?
    }

    /// Opens the best available store, falling back rather than throwing.
    ///
    /// Launch must never be blocked by a persistence failure. If the on-disk store cannot be opened
    /// the app still starts, with an in-memory store and a visible explanation, so a running session
    /// can be finished and exported instead of lost.
    public static func makeStore() -> Result {
        #if canImport(LggrPersistence)
            do {
                return Result(store: try SwiftDataStore(), backend: .swiftData, degradedReason: nil)
            } catch {
                return fileStore(
                    degradedReason: "The SwiftData store could not be opened, so Lggr is using its "
                        + "local file store instead. \(error.localizedDescription)"
                )
            }
        #else
            return fileStore(degradedReason: nil)
        #endif
    }

    private static func fileStore(degradedReason: String?) -> Result {
        do {
            return Result(
                store: try JSONFileStore(),
                backend: .jsonFile,
                degradedReason: degradedReason
            )
        } catch {
            return Result(
                store: InMemoryStore(),
                backend: .inMemory,
                degradedReason: "Lggr could not open its data file, so nothing recorded in this "
                    + "session will be saved. \(error.localizedDescription)"
            )
        }
    }
}
