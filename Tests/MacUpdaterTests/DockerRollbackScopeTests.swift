import Foundation
import Testing
@testable import MacUpdaterCore

struct DockerRollbackScopeTests {
    @Test(arguments: ["docker", "docker-desktop", "homebrew/cask/docker", "homebrew/cask/docker-desktop"])
    func dockerSnapshotDisclosesApplicationBundleOnly(token: String) {
        #expect(RollbackProtection.scope(token: token) == .dockerAppBundleOnly)
        let profile = CaskArtifactProfile(token: token, artifacts: [CaskArtifact(kind: .app)])
        #expect(RollbackProtection.evaluate(profile: profile) == .protected)
    }

    @Test(arguments: ["slack", "docker-compose", "docker-toolbox", "my-docker-desktop"])
    func unrelatedCasksKeepTheirExistingBundleProtection(token: String) {
        #expect(RollbackProtection.scope(token: token) == .appBundleOnly)
    }

    @Test func retainedDockerSnapshotCarriesTheSameLimitedScopeWithoutChangingItsIdentity() {
        let operationID = UUID()
        let snapshot = UndoableUpdate(
            operationID: operationID,
            token: "docker-desktop",
            appPath: "/Applications/Docker.app",
            restoredVersion: "4.96.0",
            updatedAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 200)
        )
        #expect(snapshot.rollbackScope == .dockerAppBundleOnly)
        #expect(snapshot.id == "\(operationID.uuidString):docker-desktop")
        #expect(snapshot.restoredVersion == "4.96.0")
    }
}
