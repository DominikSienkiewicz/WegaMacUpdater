import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Operation controller state machines")
@MainActor
struct CoordinatorStateMachineTests {
    @Test func selfUpdateCheckPublishesTheResult() async {
        let expected = WegaSelfUpdateChecker.Result.upToDate
        let controller = SelfUpdateController(dependencies: .init(
            check: { expected },
            download: { $0 },
            verify: { _ in },
            installOrOpen: { _ in false },
            openFallback: {}
        ))

        await controller.check()

        #expect(controller.state == .result(expected))
        #expect(!controller.isChecking)
    }

    @Test func touchIDPermissionFailureBecomesAnExplicitState() async {
        let controller = TouchIDSetupController(dependencies: .init(
            currentState: { .available },
            helperIsEnabled: { false },
            enableWithHelper: {},
            authorizeFallback: { .permissionDenied },
            openInTerminal: { _ in }
        ))

        await controller.enable { _ in }

        #expect(controller.state == .permissionDenied(.available))
        #expect(controller.wasPermissionDenied)
        #expect(!controller.isEnabling)
    }
}
