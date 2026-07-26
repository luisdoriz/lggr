import Foundation
import LggrKit
import UserNotifications

// Notifications. See docs/_design/SPEC.md § Notifications and docs/_design/04-screens.md § 4.7,
// § 10.12.
//
// ## The rule this file exists to enforce
//
// There are two kinds of notification and one destroys the other.
//
// **Useful:** your fifty minutes are up. You are halfway. Nothing has reached the machine for twenty
// minutes — shall I end the session at 12:04. Each of those helps the user finish something they
// started, and each of them is *caused by a thing that happened*.
//
// **Engagement-driven:** you have not tracked today. Keep your streak. Come back. Those exist to
// drag somebody back to an app, and Lggr does not send them — not one, not ever, not behind a
// toggle.
//
// The reason that distinction is load-bearing rather than tasteful is mechanical: **macOS grants one
// notification authorisation for the whole application.** There is no second channel to put the
// nagging in. If a single notification annoys the user they switch Lggr off in System Settings, and
// every useful one dies with it — silently, permanently, and where the app cannot ask again. So:
//
// - **No notification fires because time passed.** Every kind below is scheduled by an event: a
//   session started, a session ended, input stopped. There is no daily timer anywhere in this file.
// - **Every kind is individually switchable**, and switching one off cancels anything already
//   pending for it. One kind the user does not want must not cost them the others.
// - **Authorisation is requested only when the user enables a kind.** Never at launch. This is the
//   first permission Lggr has ever requested (`05-permissions.md`), and it is requested by the user
//   pressing something, once.
// - **Everything degrades silently when denied.** Nothing in the app waits on a notification, no
//   feature is gated behind one, and a denial produces one line of text in Settings and no second
//   ask. A permission prompt that reappears is a nag with a nice font.
// - **Every notification is actionable from itself** where macOS allows it. A notification whose
//   only affordance is to open a window has made work rather than saved it.
//
// ## The shape
//
// `NotificationService` is the protocol, `UserNotificationService` is the `UserNotifications`
// implementation, and `RecordingNotificationService` is the fake that records instead of posting —
// which is what the test suite and the snapshot renderer use, because neither may raise a real
// banner on a developer's screen.
//
// `NotificationGate` sits above all three and owns the part that is easy to get wrong: it holds the
// per-kind switches, it is the only thing that asks for authorisation, and it drops anything whose
// switch is off *before* the service is ever reached. Every scheduling call in the app goes through
// it, so "off means off" is one guard in one place rather than a convention.

// MARK: - Kinds

/// The notifications Lggr can send. There are no others, and adding one is a design decision rather
/// than an implementation detail.
///
/// `SPEC.md` names four. Three are here; the fourth — **planned session start** — is not, and its
/// absence is deliberate rather than pending. The spec qualifies it *"(if scheduled)"*, and Lggr has
/// no way to schedule a session: there is no future-dated session anywhere in the data model, so
/// there is no plan to announce. A kind for it would be an enum case nothing could ever construct,
/// and a toggle for it would be a control the user could move that changed nothing. It arrives with
/// scheduled sessions or it does not arrive.
public enum NotificationKind: String, CaseIterable, Sendable, Hashable {

    /// The session reached the duration the user planned for it. Scheduled when a session with a
    /// target starts; cancelled the moment it is paused, corrected, finished or discarded.
    case sessionCompleted

    /// Halfway through a planned session. Off by default even among the off-by-default set: it is
    /// the one kind that interrupts work that is going well.
    case halfway

    /// Input has been absent long enough that the session has stopped describing anything, and the
    /// app can offer to end it at the last thing it witnessed. Fires once per idle stretch.
    case longIdle

    /// The day's blocks that were never declared, offered once, at the end of the day.
    ///
    /// Scheduled by `ProactivePrompts`, and the cause is the record rather than the clock: the user's
    /// chosen time only opens the window in which Lggr is permitted to *look*, and this is posted
    /// only if the day actually holds blocks worth labelling. A well-declared day sends nothing —
    /// not a summary, and not a congratulation.
    case endOfDayReview

    /// A long stretch of work with no session running: *"Xcode, Terminal · 18m. What are you working
    /// on?"*, offered **once** for that stretch and never again.
    ///
    /// The one kind that arrives while the user is mid-thought, which makes it the highest-risk
    /// notification in the product. Its whole design is the three rules it cannot break: once per
    /// block, silent whenever Lggr has nothing to say, and dismissible in one press with *Stop
    /// asking* on the banner itself. See `UnlabelledWork.liveOffer(in:now:conditions:policy:)`, where
    /// every one of those is a case of an enum with a test on it.
    case unlabelledBlock

    /// The `UNNotificationCategory` identifier, which is what carries the buttons.
    public var categoryIdentifier: String { "com.lggr.notification.\(rawValue)" }

    /// One pending notification per kind at a time. A second request for the same kind replaces the
    /// first rather than stacking on it — five "you are halfway" banners for one session is the
    /// behaviour that gets an app switched off.
    public var requestIdentifier: String { "com.lggr.notification.\(rawValue).pending" }

    /// Grouped in Notification Centre by kind, so a stack collapses into one row.
    public var threadIdentifier: String { "com.lggr.thread.\(rawValue)" }

    /// What the Alerts pane calls it.
    public var displayName: String {
        switch self {
        case .sessionCompleted: "Session finished"
        case .halfway: "Halfway through a session"
        case .longIdle: "No input during a session"
        case .endOfDayReview: "End-of-day review"
        // Named for what the user is doing, not for what is absent. The other four name an event —
        // "Session finished", "No input during a session" — and this one used to read "A long stretch
        // with no session": the only noun phrase in the list, the only one starting with an article,
        // and it never said that Lggr would ask what you were working on.
        case .unlabelledBlock: "Working without a session"
        }
    }

    /// One sentence stating what causes it. Every one of these names an event.
    public var causeDescription: String {
        switch self {
        case .sessionCompleted: "Sent when a session reaches the duration you planned for it."
        case .halfway: "Sent once, halfway through a session that has a planned duration."
        case .longIdle:
            "Sent when nothing has reached the machine for a while during a session, with the "
                + "option to end the session at the last input Lggr recorded."
        case .endOfDayReview:
            "Sent at the time you choose, and only if the day holds blocks with nothing declared "
                + "for them. A day with nothing unlabelled sends nothing."
        case .unlabelledBlock:
            "Sent once when you have been working a while with nothing running, asking what you "
                + "are working on. Answering it labels the time you already spent."
        }
    }
}

/// A button on the notification itself.
///
/// Each of these completes the thing the notification is about without the user opening a window,
/// which is the difference between a notification that saves work and one that makes it.
public enum NotificationActionKind: String, CaseIterable, Sendable, Hashable {

    /// Open the review sheet for the session that just ended (`04-screens.md` § 10.12).
    case review

    /// End the running session at the instant the notification names, and nothing else.
    case endAtLastInput

    /// Leave the session exactly as it is. Present so that dismissing is a decision the user makes
    /// rather than one they avoid — and so this kind does not ask twice.
    case keepGoing

    /// Open Today at the blocks in question.
    case openToday

    /// Open the queue of today's unlabelled blocks — `EndOfDayReviewSheet`.
    ///
    /// The end-of-day notification's only button, and it opens the thing that answers the question
    /// rather than the app. *"Open Today and find them yourself"* would be a notification that made
    /// work, which is the definition this file is arranged around.
    case reviewUnlabelled

    /// Label the stretch of work the notification is about, backdated to its real start.
    case labelBlock

    /// Leave this stretch alone. **Cheap and final for that block**: nothing is written, and the
    /// block is marked as answered so it is never offered again. Present so that dismissing is a
    /// decision the user makes in one press rather than a banner they have to out-wait.
    case dismissBlock

    /// Switch this kind of notification off, from the notification itself.
    ///
    /// The obvious way out, findable without hunting — which is the whole reason it is on the banner
    /// and not only in Settings. A user who has to go looking for the off switch goes to System
    /// Settings instead and takes every useful notification with them.
    case stopAsking

    public var identifier: String { "com.lggr.action.\(rawValue)" }

    public var title: String {
        switch self {
        case .review: "Review"
        case .endAtLastInput: "End the session"
        case .keepGoing: "Keep going"
        case .openToday: "Open Today"
        case .reviewUnlabelled: "Label them"
        case .labelBlock: "Label this"
        case .dismissBlock: "Not this one"
        case .stopAsking: "Stop asking"
        }
    }

    /// Whether pressing this brings Lggr to the front.
    ///
    /// False for the two answers that complete without a window. A notification whose *every* button
    /// activates the app has made the dismissal cost a context switch, and a dismissal that costs a
    /// context switch is one the user avoids by switching notifications off instead.
    public var activatesApp: Bool {
        switch self {
        case .review, .openToday, .reviewUnlabelled, .labelBlock: true
        case .endAtLastInput, .keepGoing, .dismissBlock, .stopAsking: false
        }
    }

    /// Which actions each kind offers, in the order they appear.
    ///
    /// The first action is also what a click on the banner body does (see `ActionDelegate`), so it is
    /// always the affirmative one.
    public static func actions(for kind: NotificationKind) -> [NotificationActionKind] {
        switch kind {
        case .sessionCompleted: [.review]
        case .halfway: []
        case .longIdle: [.endAtLastInput, .keepGoing]
        case .endOfDayReview: [.reviewUnlabelled]
        case .unlabelledBlock: [.labelBlock, .dismissBlock, .stopAsking]
        }
    }
}

// MARK: - Content

/// One notification, fully assembled, with no framework type in it.
///
/// A plain value so that the copy can be asserted in a test without a notification centre, and so
/// that `RecordingNotificationService` records exactly what the real one would have posted.
public struct NotificationContent: Equatable, Sendable {

    public let kind: NotificationKind
    public let title: String
    public let body: String
    /// Delivered after this many seconds. Zero means now.
    ///
    /// Never a calendar date. A time interval can only be relative to something that just happened,
    /// which is the property this whole file is arranged around.
    public let delay: TimeInterval

    public init(kind: NotificationKind, title: String, body: String, delay: TimeInterval = 0) {
        self.kind = kind
        self.title = title
        self.body = body
        self.delay = max(0, delay.isFinite ? delay : 0)
    }

    public var actions: [NotificationActionKind] { NotificationActionKind.actions(for: kind) }
}

// MARK: - Authorisation

/// What macOS has said about notifications, as much of it as Lggr needs to know.
public enum NotificationAuthorization: Equatable, Sendable {

    /// Nobody has been asked. The only state in which asking is permitted.
    case notRequested
    case allowed
    /// The user said no, here or in System Settings. **Terminal, as far as the app is concerned:**
    /// nothing re-asks, and the pane states it once with no button beside it.
    case denied
    /// There is no notification centre to talk to — an unbundled build, a test host, the snapshot
    /// renderer. Everything behaves exactly as it does when denied.
    case unavailable

    /// Notifications will actually arrive.
    public var isAllowed: Bool { self == .allowed }

    /// Asking is still a thing that could happen. False for `.denied`, which is why the pane's
    /// button disappears rather than greying out — a button that cannot succeed is not a button.
    public var canRequest: Bool { self == .notRequested }
}

// MARK: - The protocol

/// Somewhere to send a notification, or to pretend to.
///
/// `@MainActor` for the same reason every other service here is: `UNUserNotificationCenter`'s
/// delegate callbacks arrive on the main thread and the objects that react to an action — the
/// session manager, the window — are main-actor isolated.
@MainActor
public protocol NotificationService: AnyObject {

    /// The last known authorisation, without asking for it. Cheap, and safe to read on every frame.
    var authorization: NotificationAuthorization { get }

    /// Re-reads the authorisation from the system. Does not prompt.
    func refreshAuthorization() async

    /// Prompts, once. Only ever called because the user switched a notification on.
    @discardableResult
    func requestAuthorization() async -> NotificationAuthorization

    /// Registers the buttons. Idempotent; called before the first post.
    func registerCategories()

    /// Posts or schedules one notification, replacing any pending one of the same kind.
    func post(_ content: NotificationContent) async

    /// Withdraws anything pending for this kind, delivered or not.
    func cancel(_ kind: NotificationKind)

    /// Withdraws everything. Called when the app stops having anything to notify about.
    func cancelAll()

    /// Where a tapped button arrives. Set once, by the composition root.
    var onAction: (@MainActor (NotificationKind, NotificationActionKind) -> Void)? { get set }
}

// MARK: - The real one

/// `UNUserNotificationCenter`, with the two things that go wrong about it handled.
///
/// **It cannot be touched at all in an unbundled process.** `UNUserNotificationCenter.current()`
/// terminates a process with no bundle identifier, and this package builds an executable that is run
/// directly by `swift run`, by the snapshot renderer and by the test host. So the centre is resolved
/// lazily through `resolvedCentre`, which returns `nil` when there is no bundle to speak for, and
/// every method below degrades to doing nothing — which is the same behaviour as a denial, which the
/// app already handles everywhere.
///
/// **And authorisation must not be requested by accident.** `requestAuthorization` is the only
/// method that prompts, `refreshAuthorization` deliberately uses `notificationSettings` instead, and
/// nothing in this file calls the former. `NotificationGate` calls it, from one place, when a user
/// switches something on.
@MainActor
public final class UserNotificationService: NotificationService {

    public private(set) var authorization: NotificationAuthorization = .notRequested

    public var onAction: (@MainActor (NotificationKind, NotificationActionKind) -> Void)?

    private var hasRegisteredCategories = false
    private let delegate = ActionDelegate()

    /// `nil` in any process that has no bundle identifier. See the type's documentation.
    private let centre: UNUserNotificationCenter?

    public init() {
        // Guarded rather than tried: `current()` does not throw on an unbundled process, it kills
        // it. `Bundle.main.bundleIdentifier` is the documented way to know in advance.
        if Bundle.main.bundleIdentifier != nil {
            let centre = UNUserNotificationCenter.current()
            self.centre = centre
            centre.delegate = delegate
        } else {
            self.centre = nil
            authorization = .unavailable
        }
        delegate.onAction = { [weak self] kind, action in
            self?.onAction?(kind, action)
        }
    }

    // MARK: Authorisation

    public func refreshAuthorization() async {
        guard let centre else {
            authorization = .unavailable
            return
        }
        let settings = await centre.notificationSettings()
        authorization = Self.authorization(from: settings.authorizationStatus)
    }

    @discardableResult
    public func requestAuthorization() async -> NotificationAuthorization {
        guard let centre else {
            authorization = .unavailable
            return authorization
        }

        // Ask the system first. A grant that already exists must not produce a second prompt, and a
        // denial that already exists must not produce one at all — `requestAuthorization` on a
        // denied app is silent, but asking is still the wrong thing to have written down.
        await refreshAuthorization()
        guard authorization.canRequest else { return authorization }

        do {
            let granted = try await centre.requestAuthorization(options: [.alert, .sound])
            authorization = granted ? .allowed : .denied
        } catch {
            // A failed request is not a denial the user made, and it is not a reason to show an
            // error either: nothing the user asked for is broken, they simply will not get banners.
            // Re-reading is the honest way to find out which state they are actually in.
            await refreshAuthorization()
        }
        return authorization
    }

    private static func authorization(
        from status: UNAuthorizationStatus
    ) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notRequested
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .denied
        }
    }

    // MARK: Categories

    public func registerCategories() {
        guard let centre, !hasRegisteredCategories else { return }
        hasRegisteredCategories = true

        let categories = NotificationKind.allCases.map { kind in
            UNNotificationCategory(
                identifier: kind.categoryIdentifier,
                actions: NotificationActionKind.actions(for: kind).map { action in
                    UNNotificationAction(
                        identifier: action.identifier,
                        title: action.title,
                        // `[]` rather than `[.foreground]` for the two answers that finish without a
                        // window — dismissing a block and switching the kind off both complete in the
                        // notification centre, and activating Lggr to do them would make the cheap
                        // answer the expensive one.
                        options: action.activatesApp ? [.foreground] : []
                    )
                },
                intentIdentifiers: [],
                options: []
            )
        }
        centre.setNotificationCategories(Set(categories))
    }

    // MARK: Posting

    public func post(_ content: NotificationContent) async {
        guard let centre, authorization.isAllowed else { return }
        registerCategories()

        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        payload.categoryIdentifier = content.kind.categoryIdentifier
        payload.threadIdentifier = content.kind.threadIdentifier
        // No sound and no badge. A count on the Dock icon is the same mechanism as a streak: a
        // number that grows while the user does not comply.
        payload.sound = nil

        // `nil` means deliver now. `UNTimeIntervalNotificationTrigger` rejects intervals below one
        // second, so anything that small is simply immediate.
        let trigger: UNTimeIntervalNotificationTrigger? =
            content.delay >= 1
            ? UNTimeIntervalNotificationTrigger(timeInterval: content.delay, repeats: false)
            : nil

        // Replacing by identifier rather than adding: one pending notification per kind, so a
        // session restarted three times leaves one banner and not three.
        centre.removePendingNotificationRequests(
            withIdentifiers: [content.kind.requestIdentifier]
        )
        let request = UNNotificationRequest(
            identifier: content.kind.requestIdentifier,
            content: payload,
            trigger: trigger
        )
        // A failed add is silent for the reason a failed heartbeat write is: the only consumer is a
        // banner the user may never have seen, and an alert about a missing alert is worse than the
        // missing alert.
        try? await centre.add(request)
    }

    public func cancel(_ kind: NotificationKind) {
        guard let centre else { return }
        centre.removePendingNotificationRequests(withIdentifiers: [kind.requestIdentifier])
        centre.removeDeliveredNotifications(withIdentifiers: [kind.requestIdentifier])
    }

    public func cancelAll() {
        for kind in NotificationKind.allCases { cancel(kind) }
    }

    /// The delegate is its own object rather than the service itself.
    ///
    /// `UNUserNotificationCenterDelegate` is an `NSObject` protocol whose callbacks are not
    /// main-actor annotated, and making `UserNotificationService` an `NSObject` to conform would
    /// spread that isolation problem across a `@MainActor @Observable` type. One small adaptor,
    /// hopping to the main actor once, keeps it in one place.
    private final class ActionDelegate: NSObject, UNUserNotificationCenterDelegate {

        var onAction: (@MainActor (NotificationKind, NotificationActionKind) -> Void)?

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            let categoryIdentifier = response.notification.request.content.categoryIdentifier
            let actionIdentifier = response.actionIdentifier
            let handler = onAction

            Task { @MainActor in
                defer { completionHandler() }
                guard
                    let kind = NotificationKind.allCases.first(where: {
                        $0.categoryIdentifier == categoryIdentifier
                    })
                else { return }
                guard
                    let action = NotificationActionKind.allCases.first(where: {
                        $0.identifier == actionIdentifier
                    })
                else {
                    // The notification itself was clicked, or it was dismissed. The default action
                    // for the two kinds that have a destination is that destination; for the rest
                    // there is nothing to do, which is correct rather than missing.
                    if actionIdentifier == UNNotificationDefaultActionIdentifier,
                        let fallback = NotificationActionKind.actions(for: kind).first
                    {
                        handler?(kind, fallback)
                    }
                    return
                }
                handler?(kind, action)
            }
        }

        /// Show the banner even while Lggr is frontmost.
        ///
        /// The session timer is not always on screen — the window is closed most of the time and the
        /// menu bar label is four characters — so suppressing the banner because the app happens to
        /// be active would drop exactly the notification the user switched on.
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler:
                @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner])
        }
    }
}

// MARK: - The fake

/// Records what would have been posted, and posts nothing.
///
/// Used by the test suite and by any host with no business raising a banner — the snapshot renderer
/// and the gallery both construct an environment, and a screenshot pass that fires notifications on
/// a developer's machine is the sort of thing that makes people stop running the screenshot pass.
///
/// It is a faithful fake, not a stub: it enforces the same one-pending-per-kind rule the real one
/// does, it refuses to record anything while unauthorised, and `authorization` starts at
/// `.notRequested` so a test that forgets to grant sees exactly what an un-prompted user sees.
@MainActor
public final class RecordingNotificationService: NotificationService {

    /// Everything that was actually posted, in order.
    public private(set) var posted: [NotificationContent] = []
    /// Kinds that were cancelled, in order, including cancellations of nothing.
    public private(set) var cancelled: [NotificationKind] = []
    /// How many times authorisation was requested. The assertion behind "asked once, and only on a
    /// user action" is a count.
    public private(set) var authorizationRequests = 0
    public private(set) var registeredCategories = false

    public private(set) var authorization: NotificationAuthorization

    public var onAction: (@MainActor (NotificationKind, NotificationActionKind) -> Void)?

    /// What the system will answer when asked. Set to `.denied` to test the degraded path.
    public var responseToRequest: NotificationAuthorization

    public init(
        authorization: NotificationAuthorization = .notRequested,
        responseToRequest: NotificationAuthorization = .allowed
    ) {
        self.authorization = authorization
        self.responseToRequest = responseToRequest
    }

    /// The notification pending for a kind, if any.
    public func pending(_ kind: NotificationKind) -> NotificationContent? {
        posted.last { $0.kind == kind }
    }

    public func refreshAuthorization() async {}

    @discardableResult
    public func requestAuthorization() async -> NotificationAuthorization {
        authorizationRequests += 1
        guard authorization.canRequest else { return authorization }
        authorization = responseToRequest
        return authorization
    }

    public func registerCategories() { registeredCategories = true }

    public func post(_ content: NotificationContent) async {
        guard authorization.isAllowed else { return }
        posted.removeAll { $0.kind == content.kind }
        posted.append(content)
    }

    public func cancel(_ kind: NotificationKind) {
        cancelled.append(kind)
        posted.removeAll { $0.kind == kind }
    }

    public func cancelAll() {
        for kind in NotificationKind.allCases { cancel(kind) }
    }

    /// Drives `onAction` as if the user had pressed the button. The seam the app's action handling is
    /// tested through, since a real button press cannot be synthesised.
    public func simulateAction(_ action: NotificationActionKind, for kind: NotificationKind) {
        onAction?(kind, action)
    }
}

// MARK: - The switches

/// Which kinds the user has switched on.
///
/// A value rather than four reads of `UserPreferences`, so the gate can be handed a set of switches
/// in a test and so `isEnabled(_:)` is one function instead of a `switch` repeated at every call
/// site. Everything defaults to off; `UserPreferences` carries the reasoning.
public struct NotificationSwitches: Codable, Equatable, Sendable {

    public var sessionCompleted: Bool
    public var halfway: Bool
    public var longIdle: Bool
    public var endOfDayReview: Bool
    public var unlabelledBlock: Bool

    public init(
        sessionCompleted: Bool = false,
        halfway: Bool = false,
        longIdle: Bool = false,
        endOfDayReview: Bool = false,
        unlabelledBlock: Bool = false
    ) {
        self.sessionCompleted = sessionCompleted
        self.halfway = halfway
        self.longIdle = longIdle
        self.endOfDayReview = endOfDayReview
        self.unlabelledBlock = unlabelledBlock
    }

    /// Every switch off — what a fresh install has, and what a `RecordingNotificationService` in a
    /// test starts from unless the test says otherwise.
    public static let allOff = NotificationSwitches()

    public func isEnabled(_ kind: NotificationKind) -> Bool {
        switch kind {
        case .sessionCompleted: sessionCompleted
        case .halfway: halfway
        case .longIdle: longIdle
        case .endOfDayReview: endOfDayReview
        case .unlabelledBlock: unlabelledBlock
        }
    }

    public mutating func setEnabled(_ enabled: Bool, for kind: NotificationKind) {
        switch kind {
        case .sessionCompleted: sessionCompleted = enabled
        case .halfway: halfway = enabled
        case .longIdle: longIdle = enabled
        case .endOfDayReview: endOfDayReview = enabled
        case .unlabelledBlock: unlabelledBlock = enabled
        }
    }

    /// Any kind at all is on, which is the only condition under which authorisation is worth having.
    public var hasAnyEnabled: Bool { NotificationKind.allCases.contains { isEnabled($0) } }

    /// The kinds the Alerts pane offers a row for.
    ///
    /// **All of them, now that all of them have a scheduler.** `.endOfDayReview` and
    /// `.unlabelledBlock` arrive with `ProactivePrompts`, which is what makes a row for them a control
    /// that moves something — the condition the previous build stated and could not yet meet. A test
    /// asserts that this list and `NotificationKind.allCases` agree, so a kind added without a
    /// scheduler fails the suite instead of shipping as a dead switch.
    ///
    /// The order is the order the pane draws: the two that concern a session the user started, then
    /// the two that concern work they did not declare.
    public static let switchableKinds: [NotificationKind] = [
        .sessionCompleted, .halfway, .longIdle, .unlabelledBlock, .endOfDayReview,
    ]

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case sessionCompleted
        case halfway
        case longIdle
        case endOfDayReview
        case unlabelledBlock
    }

    /// Tolerant of missing keys, and the fallback is **off** in every case.
    ///
    /// The same tolerance `UserPreferences` extends, and here it carries a promise as well as
    /// compatibility: a build that adds a fifth kind must not switch it on for anybody whose stored
    /// value predates it. An upgrade may never grant itself a notification.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionCompleted: try container.decodeIfPresent(
                Bool.self, forKey: .sessionCompleted) ?? false,
            halfway: try container.decodeIfPresent(Bool.self, forKey: .halfway) ?? false,
            longIdle: try container.decodeIfPresent(Bool.self, forKey: .longIdle) ?? false,
            endOfDayReview: try container.decodeIfPresent(
                Bool.self, forKey: .endOfDayReview) ?? false,
            unlabelledBlock: try container.decodeIfPresent(
                Bool.self, forKey: .unlabelledBlock) ?? false
        )
    }
}

// MARK: - The gate

/// The one thing that decides whether a notification is sent, and the only thing that asks for
/// permission to send one.
///
/// Every scheduling call in the app goes through here rather than through a `NotificationService`
/// directly, because three rules have to hold at every call site and none of them survives being a
/// convention:
///
/// 1. **A kind that is switched off is dropped before the service sees it**, and anything already
///    pending for it is withdrawn. Switching something off has to take effect now, not at the next
///    session.
/// 2. **Authorisation is requested when, and only when, a switch is turned on.** `setEnabled(_:for:)`
///    is the sole caller of `requestAuthorization()` in the whole app.
/// 3. **A denial changes nothing except whether banners appear.** The switches stay where the user
///    put them, every scheduling call still returns normally, and nothing is re-asked.
@MainActor
@Observable
public final class NotificationGate {

    /// What the user has switched on. Written through `setEnabled(_:for:)`, which is what makes the
    /// authorisation request and the cancellation happen; assigning wholesale is for restoring saved
    /// preferences at launch, which must never prompt.
    public private(set) var switches: NotificationSwitches

    /// What macOS has said, so the pane can state it without asking for it.
    ///
    /// A stored property mirrored from the service rather than a computed read of it, and the
    /// difference is visible: `NotificationService` is not `@Observable`, so a computed passthrough
    /// would leave the Alerts pane showing "macOS will ask the first time…" after the user had
    /// already answered. The mirror is what makes the sentence live.
    public private(set) var authorization: NotificationAuthorization

    /// Notifications will actually arrive: something is switched on and macOS has agreed.
    public var isDelivering: Bool { switches.hasAnyEnabled && authorization.isAllowed }

    @ObservationIgnored private let service: any NotificationService
    /// Persists a changed switch. Injected, so the gate does not need to know that
    /// `AppPreferences` exists or that preferences are mirrored into two places.
    @ObservationIgnored private let persist: (@MainActor (NotificationSwitches) -> Void)?

    public init(
        service: any NotificationService,
        switches: NotificationSwitches = .allOff,
        persist: (@MainActor (NotificationSwitches) -> Void)? = nil
    ) {
        self.service = service
        self.switches = switches
        self.persist = persist
        self.authorization = service.authorization
    }

    /// Reads the current authorisation without prompting, and registers the buttons.
    ///
    /// Safe to call at launch, and called there: knowing that the user granted this last week is not
    /// the same as asking them again, and the pane has to be able to say which state they are in.
    public func prepare() async {
        await service.refreshAuthorization()
        authorization = service.authorization
        service.registerCategories()
        // A user who has switched everything off since the last launch should have nothing left
        // pending from it. Cheap, and it closes the one window in which a cancelled kind could still
        // fire.
        for kind in NotificationKind.allCases where !switches.isEnabled(kind) {
            service.cancel(kind)
        }
    }

    /// Turns a kind on or off.
    ///
    /// **This is the only place in Lggr that requests a permission.** Turning something on is the
    /// explicit user action that authorises the ask; turning something off withdraws whatever was
    /// pending for it immediately. Nothing here reverts the switch when the user declines: they asked
    /// for the notification, macOS is the thing saying no, and silently unticking the box they just
    /// ticked would leave them with no way to see what they had chosen.
    public func setEnabled(_ enabled: Bool, for kind: NotificationKind) async {
        guard switches.isEnabled(kind) != enabled else { return }
        switches.setEnabled(enabled, for: kind)
        persist?(switches)

        guard enabled else {
            service.cancel(kind)
            return
        }
        // Only when it could succeed. `canRequest` is false once the user has answered, in either
        // direction, which is what makes "we ask exactly once" true rather than aspirational.
        if authorization.canRequest {
            authorization = await service.requestAuthorization()
        }
        service.registerCategories()
    }

    /// Replaces every switch at once, without prompting. For restoring saved preferences.
    public func restore(_ switches: NotificationSwitches) {
        self.switches = switches
    }

    /// Sends a notification, if the user asked for this kind.
    ///
    /// Returns nothing and reports nothing: a caller must not be able to branch on whether a banner
    /// appeared, because that is how a notification stops being optional.
    public func post(_ content: NotificationContent) async {
        guard switches.isEnabled(content.kind) else {
            // Not merely skipped — actively withdrawn. A kind switched off mid-session must not
            // leave a banner armed from before.
            service.cancel(content.kind)
            return
        }
        await service.post(content)
    }

    public func cancel(_ kind: NotificationKind) {
        service.cancel(kind)
    }

    public func cancelAll() {
        service.cancelAll()
    }

    /// Where a pressed button is delivered. Assigned by the composition root.
    public var onAction: (@MainActor (NotificationKind, NotificationActionKind) -> Void)? {
        get { service.onAction }
        set { service.onAction = newValue }
    }
}

// MARK: - Copy

/// Every string Lggr can put in a notification, in one place.
///
/// Here rather than at the call sites for the reason `04-screens.md` § 10 gives for the whole copy
/// catalogue: these sentences are read out of context, by somebody who is doing something else, and
/// they are the one part of the app a test can check for the words it must never contain. Facts
/// about the record, never about the person — no sentence below has the user's character as its
/// subject, none of them names a streak, and none of them asserts an outcome.
public enum NotificationCopy {

    /// `04-screens.md` § 10.12, verbatim: `Session finished` / `Finish the receipt deduplication PR
    /// · 50 minutes`.
    public static func sessionCompleted(
        outcome: String,
        duration: TimeInterval,
        delay: TimeInterval = 0
    ) -> NotificationContent {
        let described = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = DurationFormatting.prose(duration)
        return NotificationContent(
            kind: .sessionCompleted,
            title: "Session finished",
            body: described.isEmpty ? detail : "\(described) · \(detail)",
            delay: delay
        )
    }

    /// The session ended because the app closed it, and the sentence says where the end came from.
    ///
    /// A separate body from the ordinary completion, because presenting an app-adjusted time as an
    /// observed one is the thing `SessionAutoClose` exists to avoid — and the notification is the
    /// first place the user sees the number.
    public static func sessionAutoClosed(
        outcome: String,
        decision: SessionAutoClose.Decision,
        closedAtText: String
    ) -> NotificationContent {
        let described = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = decision.sentence(closedAtText: closedAtText)
        return NotificationContent(
            kind: .sessionCompleted,
            title: "Session finished",
            body: described.isEmpty ? sentence : "\(described) · \(sentence)"
        )
    }

    public static func halfway(
        outcome: String,
        remaining: TimeInterval,
        delay: TimeInterval = 0
    ) -> NotificationContent {
        let described = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = "\(DurationFormatting.prose(remaining)) to go"
        return NotificationContent(
            kind: .halfway,
            title: "Halfway",
            body: described.isEmpty ? detail : "\(described) · \(detail)",
            delay: delay
        )
    }

    /// The offer, not the accusation. It states what the record shows and what the app can do about
    /// it, and the answer is allowed to be "keep going".
    public static func longIdle(
        silence: TimeInterval,
        proposedEndText: String
    ) -> NotificationContent {
        NotificationContent(
            kind: .longIdle,
            title: "No input for \(DurationFormatting.prose(silence))",
            body: "This session is still running. It can end at \(proposedEndText) instead."
        )
    }

    /// *"Today's record / 3 blocks from today aren't labelled — about 2 minutes."*
    ///
    /// Three properties, and each of them is the difference between a notification the user keeps and
    /// one that costs Lggr its authorisation:
    ///
    ///   * **It states the size of the offer.** A prompt that hides its cost is answered once. "About
    ///     two minutes" is what makes it answerable now rather than later, and it is rounded *up* so
    ///     the estimate can only be generous.
    ///   * **It reports, and never implies anybody failed.** The subject of the sentence is the
    ///     blocks. There is no *forgot*, no *missed*, no *don't forget*, no count of days.
    ///   * **It is not sent at all when the count is zero.** `UnlabelledWork.reviewOffer` returns
    ///     `.silent(.nothingUnlabelled)` for a well-declared day, so there is no "all caught up"
    ///     banner — a congratulation is the same interruption wearing a compliment.
    ///
    /// - Parameter report: the day's unlabelled blocks. A caller with an empty report has nothing to
    ///   post, and the returned content says so with an empty body rather than inventing a sentence.
    public static func endOfDayReview(_ report: UnlabelledWork.Report) -> NotificationContent {
        NotificationContent(
            kind: .endOfDayReview,
            title: "Today's record",
            body: report.sentence
        )
    }

    /// *"Xcode, Terminal · 18m / No session is running. What are you working on?"*
    ///
    /// An offer, not a question demanding an answer. The first line is the evidence — what the app
    /// saw, so the user can recognise the stretch without opening anything — and the second states
    /// the fact about the record and then asks. It never says *you have not started a session*,
    /// because a sentence whose subject is the user's conduct is the sentence that gets the app
    /// switched off.
    ///
    /// Never carries a sound (nothing in this file does) and never arrives twice for the same stretch.
    public static func unlabelledBlock(
        blockLabel: String,
        duration: TimeInterval
    ) -> NotificationContent {
        let described = blockLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = DurationFormatting.compact(duration)
        return NotificationContent(
            kind: .unlabelledBlock,
            title: described.isEmpty ? elapsed : "\(described) · \(elapsed)",
            body: "No session is running. What are you working on?"
        )
    }

    /// Words no generated notification may contain, asserted over the catalogue by a test.
    ///
    /// The first group is `INTELLIGENCE.md` §3.4's copy law — nothing that reads as a verdict on the
    /// person. The second is the mechanism this file bans outright: a notification that mentions a
    /// streak, or that the user has not done something, is engagement-driven whatever else it says.
    public static let bannedWords: [String] = [
        "only", "just", "wasted", "lost", "failed", "distracted", "should",
        "streak", "don't forget", "haven't", "reminder to", "come back",
    ]
}
