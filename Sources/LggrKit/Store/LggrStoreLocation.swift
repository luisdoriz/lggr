import Foundation

/// Where Lggr keeps everything it has recorded.
///
/// One definition, read by all three writers — the document store, the activity log and the
/// heartbeat — so an override cannot move two of them and leave the third writing into the real
/// user's folder.
///
/// `LGGR_STORE_DIR` exists so a smoke test that launches the real app cannot touch a real working
/// history. Before it existed, verifying a build meant deleting the support folder afterwards to
/// avoid leaving fixture data behind: harmless on an empty machine, destructive on anyone who
/// actually uses the app. Making the safe path available beats trusting everyone to remember the
/// dangerous one.
public enum LggrStoreLocation {

    public static let overrideKey = "LGGR_STORE_DIR"

    /// The directory holding `store.json` and the `activity` folder.
    public static func baseDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        do {
            return try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Lggr", isDirectory: true)
        } catch {
            throw StoreError.persistenceFailure(
                "Could not locate the Application Support directory: \(error.localizedDescription)"
            )
        }
    }

    /// True when the location has been redirected, so the app can say so rather than letting someone
    /// wonder why their history is missing.
    public static var isOverridden: Bool {
        let value = ProcessInfo.processInfo.environment[overrideKey]
        return !(value ?? "").isEmpty
    }
}
