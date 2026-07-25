import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("SEC-05 final authorization regressions")
struct SEC05FinalSecurityRegressionTests {
    @Test func inheritedAskpassIsDroppedWhenTrustedResolverProvidesNoOverride() {
        let result = AuthorizationEnvironment.sanitized(
            inherited: [
                "HOME": "/Users/tester",
                "PATH": "/tmp/attacker-bin",
                "SUDO_ASKPASS": "/tmp/attacker-askpass"
            ]
        )

        #expect(result["HOME"] == "/Users/tester")
        #expect(result["PATH"] == nil)
        #expect(result["SUDO_ASKPASS"] == nil)
    }

    @Test func productionResolverUsesOnlyTheRootOwnedSystemPayload() {
        let resolver = AuthorizationComponentResolver()
        let directories = Mirror(reflecting: resolver).children.first {
            $0.label == "helperDirectories"
        }?.value as? [URL]

        #expect(directories == [
            URL(
                fileURLWithPath: "/Library/Application Support/WegaMacUpdater/Authorization",
                isDirectory: true
            )
        ])
    }
}
