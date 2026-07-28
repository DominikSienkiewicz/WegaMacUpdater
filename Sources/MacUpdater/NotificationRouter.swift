import AppKit
import MacUpdaterCore
import UserNotifications

/// OBS-02 — turns a clicked notification into the screen it is about.
///
/// The routing decision itself is `NotificationRouting` in Core, and is pure. This is the thin
/// half that cannot be: reading the response, bringing the app forward, and moving the window.
///
/// The window's selection lives in `@AppStorage(SidebarSelection.storageKey)`, so writing that
/// key *is* the navigation — SwiftUI observes `UserDefaults` and follows. Going through the
/// stored value rather than a shared observable means this works whether or not the window is
/// open yet: a notification clicked while Wega is closed lands on the right screen when the
/// window finally appears, instead of being delivered to nobody.
///
/// The delivery callback is `nonisolated` because the system calls it from its own context.
/// The payload is decoded there, while it is still the system's dictionary, and only the
/// decoded destination — a `Sendable` value — crosses onto the main actor. `[AnyHashable: Any]`
/// could not cross it, and copying it out would be a race dressed as a conversion.
///
/// The stored state is one `let`, and `UserDefaults` is documented as thread-safe, so the
/// `@unchecked Sendable` conformance describes what is actually true here.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()

    /// The one AppKit touch-point, held as a property so a test can stand in for it —
    /// activation needs a running `NSApplication`, which a unit-test process does not have.
    /// The same shape `AppDelegate` uses for its two. Production value is the real one.
    @MainActor
    var activateApp: @MainActor () -> Void = { NSApp?.activate() }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Installs the router. Called once at startup — before anything can be clicked, because a
    /// notification delivered while no delegate is set is dropped, not queued.
    ///
    /// `UNUserNotificationCenter.current()` requires a bundled app and raises
    /// `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") when there is
    /// no bundle identifier — it does not return nil, it aborts the process. So the same guard
    /// every other notification call site here already carries applies: under `swift run`, and
    /// in the subprocess `ScanControlLayoutTests` drives, there is no bundle and nothing to
    /// install into. Skipping costs nothing, because an unbundled process cannot receive a
    /// notification to route in the first place.
    @MainActor
    static func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let destination = NotificationRouting.destination(
            from: response.notification.request.content.userInfo
        )
        let finish = UncheckedCompletion(completionHandler)
        Task { @MainActor in
            route(to: destination)
            finish.run()
        }
    }

    /// The half worth naming separately: what a delivered destination does to the window.
    ///
    /// A notification with no destination — one posted by an older build and still sitting in
    /// Notification Center — brings Wega forward and changes nothing. Moving the user somewhere
    /// they did not ask to go is worse than the default behaviour this replaces.
    @MainActor
    func route(to destination: SidebarSelection?) {
        activateApp()
        guard let destination else { return }
        defaults.set(destination.rawValue, forKey: SidebarSelection.storageKey)
    }
}

/// The system hands back a plain `@escaping () -> Void`; it is called exactly once, on the
/// main actor, and never stored. Wrapping it is how that promise is stated to the compiler.
private struct UncheckedCompletion: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func run() { body() }
}
