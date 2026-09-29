import Foundation
import Testing
@testable import WegaHelperKit

@Suite("Helper installations survive lost clients")
struct PackageInstallationRegistryTests {
    @Test func repeatedRequestsNeverLaunchASecondInstaller() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID()
        #expect(try fixture.registry.begin(id))
        #expect(try !fixture.registry.begin(id))
        #expect(throws: PackageInstallationRegistry.Failure.self) { try fixture.registry.begin(UUID()) }
        #expect(try fixture.registry.status(id).phase == .running)
        try fixture.registry.finish(id, succeeded: true, message: nil)
        #expect(try fixture.registry.status(id).phase == .succeeded)
        #expect(try !fixture.registry.begin(id))
    }

    @Test func anEarlyStatusQueryPreventsALateRequestFromStarting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID()
        #expect(try fixture.registry.status(id).phase == .notStarted)
        #expect(try !fixture.registry.begin(id))
    }

    @Test func daemonRestartIsUnknownUntilAMachineRestartProvesTheProcessEnded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID()
        #expect(try fixture.registry.begin(id))
        let sameBoot = try PackageInstallationRegistry(fileURL: fixture.file, bootID: "first-boot")
        #expect(try sameBoot.status(id).phase == .unknown)
        #expect(throws: PackageInstallationRegistry.Failure.self) { try sameBoot.begin(UUID()) }
        let newBoot = try PackageInstallationRegistry(fileURL: fixture.file, bootID: "second-boot")
        #expect(try newBoot.status(id).phase == .failed)
        #expect(try newBoot.begin(UUID()))
    }

    @Test func completedResultsSurviveClientAndHelperRestarts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let id = UUID()
        #expect(try fixture.registry.begin(id))
        try fixture.registry.finish(id, succeeded: false, message: "Installer rejected the package")
        let restored = try PackageInstallationRegistry(fileURL: fixture.file, bootID: "first-boot")
        #expect(try restored.status(id).phase == .failed)
        #expect(try restored.status(id).message == "Installer rejected the package")
    }

    @Test func failureToPersistDoesNotAdmitAnInstallation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.file.deletingLastPathComponent().appendingPathComponent("not-a-directory"))
        let registry = try PackageInstallationRegistry(
            fileURL: fixture.file.deletingLastPathComponent().appendingPathComponent("not-a-directory/state.json"), bootID: "first-boot"
        )
        #expect(throws: (any Error).self) { try registry.begin(UUID()) }
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let registry: PackageInstallationRegistry
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            file = root.appendingPathComponent("installations.json")
            registry = try PackageInstallationRegistry(fileURL: file, bootID: "first-boot")
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
