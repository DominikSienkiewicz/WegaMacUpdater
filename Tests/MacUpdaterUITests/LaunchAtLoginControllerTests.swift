import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// BG-02 — the Settings toggle is backed by `LaunchAtLoginController`, which registers /
/// unregisters the app as a login item and always reports the *real* `SMAppService` status
/// afterwards. Driven here through a fake seam so the register/unregister/refresh logic is
/// exercised without touching the user's actual login items.
@MainActor
@Suite("LaunchAtLoginController")
struct LaunchAtLoginControllerTests {
    @Test func refreshReflectsTheRealSystemStatus() {
        let fake = FakeLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(service: fake)

        controller.refresh()

        #expect(controller.state == .enabled)
        #expect(controller.state.isOn)
    }

    @Test func enablingRegistersTheAppAsALoginItem() async {
        let fake = FakeLoginItemService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: fake)

        await controller.setEnabled(true)

        #expect(fake.registerCount == 1)
        #expect(controller.state == .enabled)
        #expect(controller.errorMessage == nil)
    }

    @Test func disablingUnregistersTheLoginItem() async {
        let fake = FakeLoginItemService(status: .enabled)
        let controller = LaunchAtLoginController(service: fake)

        await controller.setEnabled(false)

        #expect(fake.unregisterCount == 1)
        #expect(controller.state == .disabled)
        #expect(!controller.state.isOn)
    }

    /// A failed `register()` must not leave the toggle showing "on" — it reports the real
    /// status (still off) and surfaces the error, rather than pretending the item took.
    @Test func aFailedRegistrationSurfacesTheErrorAndLeavesTheItemOff() async {
        let fake = FakeLoginItemService(status: .notRegistered, registerError: FakeLoginItemError.boom)
        let controller = LaunchAtLoginController(service: fake)

        await controller.setEnabled(true)

        #expect(controller.errorMessage != nil)
        #expect(controller.state == .disabled)
        #expect(!controller.state.isOn)
    }

    @Test func openingLoginItemsSettingsRoutesThroughTheService() {
        let fake = FakeLoginItemService(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: fake)

        controller.openLoginItemsSettings()

        #expect(fake.openedSettings)
    }
}

private enum FakeLoginItemError: Error { case boom }

/// Lock-guarded fake of `LoginItemManaging`. Mirrors the real `SMAppService` transitions —
/// `register()` moves to `.enabled`, `unregister()` back to `.notRegistered` — so the
/// controller's post-action `refresh()` reads a status that actually changed.
private final class FakeLoginItemService: LoginItemManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: LoginItemService.Status
    private let registerError: Error?
    private var _registerCount = 0
    private var _unregisterCount = 0
    private var _openedSettings = false

    init(status: LoginItemService.Status, registerError: Error? = nil) {
        self._status = status
        self.registerError = registerError
    }

    var status: LoginItemService.Status { lock.withLock { _status } }
    var registerCount: Int { lock.withLock { _registerCount } }
    var unregisterCount: Int { lock.withLock { _unregisterCount } }
    var openedSettings: Bool { lock.withLock { _openedSettings } }

    func register() throws {
        try lock.withLock {
            _registerCount += 1
            if let registerError { throw registerError }
            _status = .enabled
        }
    }

    func unregister() async throws {
        lock.withLock {
            _unregisterCount += 1
            _status = .notRegistered
        }
    }

    func openLoginItemsSettings() {
        lock.withLock { _openedSettings = true }
    }
}
