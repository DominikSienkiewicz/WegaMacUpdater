import AppKit
import Foundation
import MacUpdaterCore
import Testing
import WegaTestSupport
@testable import WegaMacUpdater

/// OBS-02 — the app-target half of the notification deep link: what a delivered destination
/// does to the window, and that every notification Wega posts actually carries one.
///
/// `OBS02NotificationRoutingTests` pins the payload contract in Core. This pins the two things
/// only reachable from the app target: the router writing the window's stored selection, and
/// the three posting sites having been wired to it at all — a perfectly correct router
/// attached to notifications that carry no payload would pass every test in Core and do
/// nothing whatsoever in the app.
@MainActor
@Suite("OBS-02 — the router moves the window, and every notification carries a destination")
struct OBS02NotificationRouterTests {

    /// The navigation itself. The window selects on `@AppStorage(SidebarSelection.storageKey)`,
    /// so writing that key is what moving the window means.
    @Test func aDeliveredDestinationBecomesTheWindowsSelection() {
        let (defaults, teardown) = TestDefaults.isolated("obs02-notification-router")
        defer { teardown() }
        defaults.set(SidebarSelection.updates(.all).rawValue, forKey: SidebarSelection.storageKey)

        let router = NotificationRouter(defaults: defaults)
        var activated = false
        router.activateApp = { activated = true }
        router.route(to: .logs)

        #expect(defaults.string(forKey: SidebarSelection.storageKey) == SidebarSelection.logs.rawValue)
        #expect(activated, "OBS-02: a click brings Wega forward as well as moving it")
    }

    /// A notification from an older build carries no destination. It must bring Wega forward
    /// and leave the window exactly where the user left it — the old behaviour, not a guess.
    @Test func aDeliveryWithoutADestinationLeavesTheWindowWhereItWas() {
        let (defaults, teardown) = TestDefaults.isolated("obs02-notification-router")
        defer { teardown() }
        defaults.set(SidebarSelection.migration.rawValue, forKey: SidebarSelection.storageKey)

        let router = NotificationRouter(defaults: defaults)
        var activated = false
        router.activateApp = { activated = true }
        router.route(to: nil)

        #expect(defaults.string(forKey: SidebarSelection.storageKey) == SidebarSelection.migration.rawValue,
                "OBS-02: no destination means no navigation — never a fallback screen")
        #expect(activated, "OBS-02: an unroutable notification still brings Wega forward, as it always did")
    }

    /// UXP-05 — a click used to only activate the app; with the window closed nothing opened.
    @Test func routingOpensTheMainWindow() {
        let (defaults, teardown) = TestDefaults.isolated("obs02-notification-router-window")
        defer { teardown() }
        let router = NotificationRouter(defaults: defaults)
        var opened = 0
        router.activateApp = {}
        router.findMainWindow = { nil }
        router.openMainWindow = { opened += 1 }
        router.route(to: .updates(.all))
        #expect(opened == 1)
    }

    /// I1 — opening unconditionally gave an open window a twin (`main-AppWindow-2`), whose
    /// appearance re-bound the store's sinks and left the first window's badges frozen. An
    /// open window — visible or in the Dock — is brought forward instead.
    @Test func routingBringsAnOpenWindowForwardInsteadOfOpeningASecond() {
        let (defaults, teardown) = TestDefaults.isolated("obs02-notification-router-window")
        defer { teardown() }
        let router = NotificationRouter(defaults: defaults)
        let window = FakeMainWindow()
        var opened = 0
        var activated = false
        router.activateApp = { activated = true }
        router.findMainWindow = { window }
        router.openMainWindow = { opened += 1 }

        router.route(to: .updates(.all))

        #expect(opened == 0, "I1: an open window must not get a second one")
        #expect(window.broughtToFront == 1)
        #expect(activated)
    }

    /// The menu's „Otwórz Wegę” had the same unconditional `openWindow`.
    @Test func theOpenCommandUsesTheSameLookup() throws {
        let router = NotificationRouter(defaults: TestDefaults.isolated("obs02-notification-router-window").0)
        let window = FakeMainWindow()
        var opened = 0
        router.findMainWindow = { window }
        router.showMainWindow(opening: { opened += 1 })
        #expect(opened == 0 && window.broughtToFront == 1)

        router.findMainWindow = { nil }
        router.showMainWindow(opening: { opened += 1 })
        #expect(opened == 1)

        let menuBar = try read("Sources/MacUpdater/MenuBarScene.swift")
        let command = try #require(menuBar.range(of: "Button(tr(\"Otwórz Wegę\"))"))
        #expect(menuBar[command.upperBound...].prefix(250).contains("NotificationRouter.shared.showMainWindow("),
                "I1: „Otwórz Wegę” goes through the router's lookup")
        #expect(!menuBar.contains("openWindow(id: \"main\")\n            NSApplication"),
                "I1: the menu no longer opens a window unconditionally")
    }

    /// F2 — a hidden app (⌘H) reports its window as neither visible nor miniaturised, so a
    /// lookup made before activation misses it and opens a twin. Both entry points activate
    /// first, then look.
    @Test func bothEntryPointsActivateBeforeLookingForTheWindow() throws {
        let router = NotificationRouter(defaults: TestDefaults.isolated("obs02-notification-router-order").0)
        var events: [String] = []
        router.activateApp = { events.append("activate") }
        router.findMainWindow = { events.append("find"); return nil }
        router.openMainWindow = { events.append("open") }
        router.route(to: nil)
        #expect(events == ["activate", "find", "open"])

        let menuBar = try read("Sources/MacUpdater/MenuBarScene.swift")
        let command = try #require(menuBar.range(of: "Button(tr(\"Otwórz Wegę\"))"))
        let body = menuBar[command.upperBound...].prefix(250)
        let activate = try #require(body.range(of: "NSApplication.shared.activate("))
        let show = try #require(body.range(of: "NotificationRouter.shared.showMainWindow("))
        #expect(activate.lowerBound < show.lowerBound, "F2: „Otwórz Wegę” activates before it looks for the window")
    }

    /// Only the windows of the main group count, and only while they are on screen or in the
    /// Dock — a closed window is left to `openWindow`.
    @Test func onlyAnOnScreenWindowOfTheMainGroupCounts() {
        #expect(MainWindowLookup.isMainWindow(identifier: "main-AppWindow-1"))
        #expect(MainWindowLookup.isMainWindow(identifier: "main-AppWindow-2"))
        #expect(MainWindowLookup.isMainWindow(identifier: "main"))
        #expect(!MainWindowLookup.isMainWindow(identifier: "com_apple_SwiftUI_Settings_window"))
        #expect(!MainWindowLookup.isMainWindow(identifier: "mainframe"))
        #expect(!MainWindowLookup.isMainWindow(identifier: nil))

        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        defer { window.close() }
        #expect(MainWindowLookup.existing(in: [window]) == nil, "a closed window is not brought back")
        window.orderFrontRegardless()
        #expect(MainWindowLookup.existing(in: [window]) === window)
    }

    /// The registration that makes a click work while the window is closed must not depend on
    /// the menu-bar label alone: the main window's root registers it too.
    @Test func theMainWindowAlsoRegistersTheOpener() throws {
        let content = try read("Sources/MacUpdater/ContentView.swift")
        #expect(content.contains("NotificationRouter.shared.openMainWindow = { openWindow(id: \"main\") }"))
        let menuBar = try read("Sources/MacUpdater/MenuBarScene.swift")
        #expect(menuBar.contains("NotificationRouter.shared.openMainWindow = { openWindow(id: \"main\") }"))
    }

    // MARK: Every notification carries one

    /// All three posting sites attach a payload, and startup installs the delegate. Asserted at
    /// source level because posting a real notification needs a bundled app, a login session
    /// and a granted permission — none of which a unit test has.
    ///
    /// Red before the fix: none of the four call sites existed, so a click did the system
    /// default and the destination went nowhere.
    @Test(arguments: [
        ("Sources/MacUpdater/MenuBarAgent.swift", "wega.updates"),
        ("Sources/MacUpdater/UpdateOperationRecovery.swift", "wega.update-recovery"),
        ("Sources/MacUpdater/BackgroundUpdater.swift", "wega.background-updates"),
    ])
    func everyPostedNotificationCarriesADestination(site: (path: String, identifier: String)) throws {
        let source = try read(site.path)

        let request = try #require(source.range(of: "UNNotificationRequest(identifier: \"\(site.identifier)\""),
                                   "sanity: \(site.path) still posts \(site.identifier)")
        let payload = try #require(source.range(of: "content.userInfo = NotificationRouting.payload("),
                                   "OBS-02: \(site.identifier) is posted without a destination, so clicking it goes nowhere")

        #expect(payload.lowerBound < request.lowerBound,
                "OBS-02: the payload is attached to the content before the request is built from it")
    }

    /// The delegate has to be installed at startup: a notification delivered while none is set
    /// is dropped, not queued, so a late install loses the very click it exists for.
    @Test func startupInstallsTheRouter() throws {
        let source = try read("Sources/MacUpdater/MacUpdaterApp.swift")
        let launch = try #require(source.range(of: "func applicationDidFinishLaunching"))
        let install = try #require(source.range(of: "NotificationRouter.install()"),
                                   "OBS-02: nothing installs the delegate, so no click is ever delivered")

        #expect(launch.lowerBound < install.lowerBound,
                "OBS-02: the router is installed during launch")
    }

    /// Every reach for `UNUserNotificationCenter` in the app target sits behind the bundle
    /// guard. That class does not fail softly when there is no bundle identifier — it raises
    /// `NSInternalInconsistencyException` ("bundleProxyForCurrentProcess is nil") and the
    /// process aborts. So an unguarded call is a crash at launch for every unbundled run:
    /// `swift run`, and the subprocess `ScanControlLayoutTests` drives.
    ///
    /// Red before the fix: `NotificationRouter.install()` called `current()` unguarded, which
    /// killed the layout regression app on `main`. The rest of the app target already knew —
    /// `MenuBarAgent` carries the guard and says why — which is exactly why the rule is pinned
    /// here rather than left as a thing to remember.
    @Test func everyNotificationCentreCallSiteIsBehindTheBundleGuard() throws {
        var offenders: [String] = []

        for url in try appTargetSources() {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("UNUserNotificationCenter.current()") else { continue }
            guard !text.contains("Bundle.main.bundleIdentifier != nil") else { continue }
            offenders.append(url.lastPathComponent)
        }

        #expect(offenders.isEmpty,
                """
                OBS-02: \(offenders.joined(separator: ", ")) reaches UNUserNotificationCenter \
                without checking Bundle.main.bundleIdentifier first. That call aborts the \
                process when the app is not bundled — it does not return nil.
                """)
    }

    private func appTargetSources(file: String = #filePath) throws -> [URL] {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources/MacUpdater"),
            includingPropertiesForKeys: nil
        )
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { urls.append(url) }
        }
        return urls
    }

    private func read(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

@MainActor
private final class FakeMainWindow: MainWindowPresenting {
    private(set) var broughtToFront = 0
    func bringToFront() { broughtToFront += 1 }
}
