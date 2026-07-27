import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// SEC-04 — the downloaded payload is pinned to the release the user was **shown**.
///
/// A valid Developer ID signature proves "Wega published this", not "Wega published this
/// *as version X*". Without the version travelling into verification, an attacker who can
/// choose which of Wega's own published bytes reach a client could answer an offer of
/// 0.9.0 with a genuinely signed, genuinely notarized 0.1.0 — a downgrade to a build whose
/// fixes are known and public, indistinguishable from a normal update.
@Suite("SEC-04 self-update version pin")
@MainActor
struct SEC04SelfUpdateVersionPinTests {
    private struct Rejected: Error {}

    @Test func theOfferedVersionTravelsIntoSignatureVerification() async throws {
        let payload = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec04-selfupdate-\(UUID().uuidString).pkg")
        #expect(FileManager.default.createFile(atPath: payload.path, contents: Data("payload".utf8)))
        defer { try? FileManager.default.removeItem(at: payload) }

        let asset = ReleaseAsset(
            name: "Wega.pkg",
            url: try #require(URL(string: "https://example.com/Wega.pkg"))
        )
        let offered = WegaSelfUpdateChecker.Result.updateAvailable(
            version: "9.9.9",
            assets: [asset],
            releaseURL: try #require(URL(string: "https://example.com/release")),
            notes: ""
        )
        let recorder = VersionRecorder()

        let controller = SelfUpdateController(dependencies: .init(
            check: { offered },
            download: { _ in payload },
            verify: { _, expectedVersion in
                recorder.record(expectedVersion)
                // Stop here: what is under test is the argument, not the install that follows.
                throw Rejected()
            },
            installOrOpen: { _, _ in true },
            openFallback: {},
            relaunch: {},
            isBusy: { false },
            fetchHistory: { _ in .unavailable }
        ))

        await controller.check()
        await controller.apply(.install(pkg: asset), version: "9.9.9") { _ in }

        #expect(recorder.wasCalled)
        #expect(recorder.expectedVersion == "9.9.9")
    }
}

/// `Dependencies.verify` is `@Sendable` but not main-actor isolated, so the recorder it
/// writes into cannot be either — it guards its own state instead.
private final class VersionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false
    private var version: String?

    func record(_ version: String?) {
        lock.withLock {
            self.called = true
            self.version = version
        }
    }

    var wasCalled: Bool { lock.withLock { called } }
    var expectedVersion: String? { lock.withLock { version } }
}
