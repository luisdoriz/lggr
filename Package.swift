// swift-tools-version: 6.0
import PackageDescription
import Foundation

// The SwiftData layer depends on `libSwiftDataMacros.dylib`, which ships only inside Xcode and is
// absent from the Command Line Tools toolchain. Building it without Xcode fails with
// "plugin for module 'SwiftDataMacros' not found", so the target is opt-in.
//
//   swift build                      → LggrKit + LggrApp + tests   (works with CLT alone)
//   LGGR_SWIFTDATA=1 swift build     → additionally builds LggrPersistence (requires Xcode)
//
// The app picks the backend up through `#if canImport(LggrPersistence)`, so no other file changes.
let swiftDataEnabled = ProcessInfo.processInfo.environment["LGGR_SWIFTDATA"] == "1"

let commonSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .enableUpcomingFeature("ExistentialAny"),
]

// Command Line Tools ships Testing.framework outside the SDK, in a directory SwiftPM does not
// search, and without an rpath entry — so `swift test` fails to compile and then to dlopen it.
// Point the compiler and the dynamic loader at it, but only when Xcode is absent: with Xcode
// installed SwiftPM resolves the framework itself and these flags would shadow it.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

// Matches Xcode.app, Xcode-beta.app and side-by-side versioned installs alike. Checking only the
// exact path "/Applications/Xcode.app" would miss a beta and then point the compiler at the Command
// Line Tools copy of Testing.framework, shadowing Xcode's own.
let hasXcode =
    ((try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? [])
    .contains { $0.hasPrefix("Xcode") && $0.hasSuffix(".app") }

// Escape hatch for an Xcode installed outside /Applications: LGGR_NO_CLT_TESTING_FLAGS=1.
let cltFlagsDisabled = ProcessInfo.processInfo.environment["LGGR_NO_CLT_TESTING_FLAGS"] == "1"

let needsCLTTestingFrameworks =
    FileManager.default.fileExists(atPath: "\(cltFrameworks)/Testing.framework")
    && !hasXcode
    && !cltFlagsDisabled

// Importing Foundation and Testing in the same file pulls in the _Testing_Foundation cross-import
// overlay, which Command Line Tools ships without a .swiftmodule — so the import fails outright.
// Disabling overlay resolution costs nothing here: the overlay only adds Foundation conveniences the
// suite does not use.
let cltTestingFlags = ["-F", cltFrameworks, "-Xfrontend", "-disable-cross-import-overlays"]

let testSwiftSettings: [SwiftSetting] =
    commonSwiftSettings + (needsCLTTestingFrameworks ? [.unsafeFlags(cltTestingFlags)] : [])
let testLinkerSettings: [LinkerSetting] =
    needsCLTTestingFrameworks
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks])]
    : []

var appDependencies: [Target.Dependency] = ["LggrKit"]
if swiftDataEnabled {
    appDependencies.append("LggrPersistence")
}

var targets: [Target] = [
    .target(
        name: "LggrKit",
        swiftSettings: commonSwiftSettings
    ),
    .executableTarget(
        name: "LggrApp",
        dependencies: appDependencies,
        swiftSettings: commonSwiftSettings
    ),
    .testTarget(
        name: "LggrKitTests",
        dependencies: ["LggrKit"],
        swiftSettings: testSwiftSettings,
        linkerSettings: testLinkerSettings
    ),
    // Phase 1 acceptance criteria 1–4 are properties of the capture layer, which lives in the
    // executable target. Without a test target that can import it, those criteria can only ever be
    // asserted by reading the code — which is exactly the failure mode this project has been bitten
    // by. SwiftPM can test an executable target on Darwin, so it is tested.
    .testTarget(
        name: "LggrAppTests",
        dependencies: ["LggrApp", "LggrKit"],
        swiftSettings: testSwiftSettings,
        linkerSettings: testLinkerSettings
    ),
]

if swiftDataEnabled {
    targets.append(
        .target(
            name: "LggrPersistence",
            dependencies: ["LggrKit"],
            swiftSettings: commonSwiftSettings
        )
    )
}

let package = Package(
    name: "Lggr",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LggrApp", targets: ["LggrApp"]),
        .library(name: "LggrKit", targets: ["LggrKit"]),
    ],
    targets: targets
)
