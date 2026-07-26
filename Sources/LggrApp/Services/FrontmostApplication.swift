import AppKit
import Foundation

/// The application in front of the user, reduced to the only two things Lggr records about it.
///
/// A value rather than an `NSRunningApplication` for two reasons. It is what makes the capture layer
/// injectable — and that matters more than it sounds, because "which application is frontmost" is a
/// fact about the real machine: a CI runner has no logged-in graphical session and therefore no
/// frontmost application at all, so a test that drives the sampler and expects an interval passes on
/// a developer's desk and fails on every runner. And it is a hard stop on scope creep: there is
/// nowhere in this type to put a window title, so no future change can quietly start recording one.
public struct FrontmostApplication: Equatable, Sendable {
    public let bundleIdentifier: String
    public let displayName: String

    public init(bundleIdentifier: String, displayName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
    }

    /// `nil` when nothing is frontmost, or when what is frontmost has no bundle identifier — the
    /// login window, a modal system panel, a helper process. Such a process cannot be keyed, named
    /// later or excluded by the user, so the sampler records the span as unexplained rather than
    /// putting an unfalsifiable row on the timeline.
    @MainActor
    public static var current: FrontmostApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            let bundleIdentifier = application.bundleIdentifier
        else {
            return nil
        }
        return FrontmostApplication(
            bundleIdentifier: bundleIdentifier,
            displayName: application.localizedName ?? bundleIdentifier
        )
    }
}
