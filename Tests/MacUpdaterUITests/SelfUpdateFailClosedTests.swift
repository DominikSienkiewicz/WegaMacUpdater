import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

/// QA-01j — regression guard for the **fail-closed self-update** branch.
///
/// Anchors the audit scenario "gałąź fail-closed self-update" from QA-01's
/// "🎯 Najważniejsze nowe scenariusze" list (finding SEC-04). The guarantee is
/// implemented by `SelfUpdateController.apply`, which routes every
/// self-update through `CodeSignatureVerifier` (the A1/SEC-03 signature pin):
/// when the downloaded asset fails verification the controller must **fail
/// closed** — it must never hand the unverified payload to the installer/opener,
/// it must delete the payload rather than leave it on disk, it must surface the
/// signature-rejection alert, and it must divert the user to the release page.
///
/// A refactor that let a verification failure fall through to `installOrOpen`
/// (dropping the early `return`, or reordering install before verify) would
/// silently reopen the gap; this test fails the moment that happens.
@Suite("Self-update fail-closed")
@MainActor
struct SelfUpdateFailClosedTests {
    /// Stands in for any `CodeSignatureVerifier.VerifyError`: a thrown `verify`
    /// is exactly what a failed signature check looks like to the controller.
    private struct SignatureRejected: Error {}

    @Test func unverifiedSelfUpdateFailsClosedInsteadOfInstalling() async {
        let stagedPayload = FileManager.default.temporaryDirectory
            .appendingPathComponent("qa01j-selfupdate-\(UUID().uuidString).pkg")
        let created = FileManager.default.createFile(
            atPath: stagedPayload.path,
            contents: Data("unverified payload".utf8)
        )
        #expect(created, "setup: the staged payload must exist before verification runs")
        defer { try? FileManager.default.removeItem(at: stagedPayload) }

        let installProbe = CallProbe()
        let fallbackProbe = CallProbe()
        let states = WegaStateRecorder()

        let controller = SelfUpdateController(dependencies: .init(
            check: { .upToDate },
            download: { _ in stagedPayload },
            verify: { _ in throw SignatureRejected() },
            installOrOpen: { _, _ in
                installProbe.record()
                return true
            },
            openFallback: { fallbackProbe.record() },
            relaunch: {},
            isBusy: { false },
            fetchHistory: { _ in .unavailable }
        ))

        let asset = ReleaseAsset(name: "Wega.pkg", url: URL(fileURLWithPath: "/tmp/Wega.pkg"))
        await controller.apply(.install(pkg: asset), version: "1.0.1") { state in
            states.record(state)
        }

        // Fail closed: an unverified payload is never handed to the installer/opener.
        #expect(!installProbe.didRun)
        // ...and it is not left lying on disk for anyone to open later.
        #expect(!FileManager.default.fileExists(atPath: stagedPayload.path))
        // The user is diverted to the release page instead of a broken install.
        #expect(fallbackProbe.didRun)
        // ...and told why, via the signature-rejection alert (the final state shown).
        #expect(states.last == WegaState(
            pose: .alert,
            line: tr("Aktualizacja nie przeszła weryfikacji podpisu — otwieram stronę wydania.")
        ))
    }
}

@MainActor
private final class CallProbe {
    private(set) var didRun = false
    func record() { didRun = true }
}

@MainActor
private final class WegaStateRecorder {
    private(set) var states: [WegaState] = []
    func record(_ state: WegaState) { states.append(state) }
    var last: WegaState? { states.last }
}
