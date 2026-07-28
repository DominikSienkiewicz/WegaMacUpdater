import Foundation
import MacUpdaterCore
import Testing
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
    @Test func aDeliveredDestinationBecomesTheWindowsSelection() throws {
        let suite = "wega.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
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
    @Test func aDeliveryWithoutADestinationLeavesTheWindowWhereItWas() throws {
        let suite = "wega.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(SidebarSelection.migration.rawValue, forKey: SidebarSelection.storageKey)

        let router = NotificationRouter(defaults: defaults)
        var activated = false
        router.activateApp = { activated = true }
        router.route(to: nil)

        #expect(defaults.string(forKey: SidebarSelection.storageKey) == SidebarSelection.migration.rawValue,
                "OBS-02: no destination means no navigation — never a fallback screen")
        #expect(activated, "OBS-02: an unroutable notification still brings Wega forward, as it always did")
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

    private func read(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
