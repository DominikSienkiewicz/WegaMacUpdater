import Foundation
import Testing

/// UX-04 regression guard for two destructive fallbacks hidden behind safer labels.
///
/// Both affected flows live in private SwiftUI methods, so — like the existing
/// TerminationDuringMutation and MigrationLeftoverCleanupDisabled suites — this suite
/// pins their wiring at the source boundary. RunningProcessService has separate command
/// construction tests for the process-level behavior.
@Suite("Explicit destructive fallbacks")
struct ExplicitDestructiveFallbackTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test func migrationRequestsGracefulQuitBeforeASeparateForceWarning() throws {
        let migration = try source("Sources/MacUpdater/MigrationView.swift")
        let service = try source("Sources/MacUpdaterCore/RunningProcessService.swift")

        #expect(migration.contains("requestGracefulTermination"),
                "UX-04: migration must ask the app to quit before considering killall")
        #expect(migration.contains(".alert(item: $pendingForceTermination)"),
                "UX-04: force-quit needs a separate, explicit warning")
        #expect(migration.contains("guard await processes.forceKill("),
                "UX-04: migration must stop when the consented force-quit fails")
        #expect(!migration.contains("await processes.kill("),
                "UX-04: migration must not invoke the best-effort kill path")

        #expect(service.contains("NSRunningApplication") && service.contains(".terminate()"),
                "UX-04: graceful quit must use the native application termination request, not killall")
        #expect(service.contains("public func forceKill") && service.contains("async -> Bool"),
                "UX-04: force-kill must expose a result the caller can honor")
    }

    @Test func failedZapNeverSilentlyFallsBackToForceOrSuccess() throws {
        let uninstall = try source("Sources/MacUpdater/UninstallView.swift")

        #expect(!uninstall.contains("uninstallCask(token: token, zap: false, force: true)"),
                "UX-04: a failed --zap must not silently retry with --force")
        #expect(uninstall.contains("Odinstalowanie niepełne — nie usunięto"),
                "UX-04: a failed requested zap must be reported as an explicit incomplete result")
        #expect(uninstall.contains("failed.append((app.name, zap))"),
                "UX-04: the failed zap must enter the failure result, never the success count")
    }
}
