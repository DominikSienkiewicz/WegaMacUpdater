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

    /// Opens the main window. Registered by `MenuBarLabel`, which is always alive, and by the
    /// main window's root, whichever appeared last — so a click can bring the window back even
    /// after the user closed it, and even if the menu-bar label never appeared. An action
    /// captured from a window that has since closed still opens a new one.
    @MainActor
    var openMainWindow: @MainActor () -> Void = {}

    /// The main window already open, visible or in the Dock, if there is one.
    @MainActor
    var findMainWindow: @MainActor () -> (any MainWindowPresenting)? = { MainWindowLookup.existing() }

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
        _: UNUserNotificationCenter,
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
    /// Brings the main window forward: the one already open — on screen or in the Dock — when
    /// there is one, a new one only when there is none. `openWindow` on an open `WindowGroup`
    /// makes a second window, whose appearance re-binds the store's sinks and leaves the first
    /// window's badges and Wega frozen. `open` overrides the registered opener for callers that
    /// hold their own, such as the menu's „Otwórz Wega”.
    @MainActor
    func showMainWindow(opening open: (@MainActor () -> Void)? = nil) {
        if let window = findMainWindow() {
            window.bringToFront()
        } else {
            (open ?? openMainWindow)()
        }
    }

    @MainActor
    func route(to destination: SidebarSelection?) {
        activateApp()
        showMainWindow()
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

/// A main window that is already open. A protocol so a test can stand in for `NSWindow`.
@MainActor
protocol MainWindowPresenting: AnyObject {
    func bringToFront()
}

extension NSWindow: MainWindowPresenting {
    func bringToFront() {
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
    }
}

/// Finds the windows of `WindowGroup(id: "main")`. SwiftUI names them after the group's id
/// (`main-AppWindow-1`, `main-AppWindow-2`, …), which is what identifies them — not a title,
/// which follows the selected destination and the language.
@MainActor
enum MainWindowLookup {
    static let groupID = "main"

    static func isMainWindow(identifier: String?) -> Bool {
        guard let identifier else { return false }
        return identifier == groupID || identifier.hasPrefix(groupID + "-")
    }

    /// A closed window is left out even if AppKit still lists it: bringing it back would show a
    /// window SwiftUI has already torn down.
    static func existing(in windows: [NSWindow] = NSApp?.windows ?? []) -> NSWindow? {
        windows.first { window in
            isMainWindow(identifier: window.identifier?.rawValue) && (window.isVisible || window.isMiniaturized)
        }
    }
}
