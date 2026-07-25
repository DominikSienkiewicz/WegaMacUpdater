import Foundation
import Testing
@testable import MacUpdaterCore

/// OBS-01 — failures that only reach Unified Logging cannot answer "why did my update fail?"
/// from Wega's Logs tab. The behavior of `WegaLog` itself is covered by `LogStoreTests`;
/// this suite pins the app/helper wiring that is otherwise behind AppKit and root XPC.
@Suite("Observability logging")
struct ObservabilityLoggingTests {
    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources(under relativePath: String) throws -> [(name: String, text: String)] {
        let root = packageRoot().appendingPathComponent(relativePath)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var sources: [(name: String, text: String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            sources.append((
                name: url.path.replacingOccurrences(of: packageRoot().path + "/", with: ""),
                text: try String(contentsOf: url, encoding: .utf8)
            ))
        }
        return sources
    }

    @Test func appFailuresDoNotBypassWegaLog() throws {
        let allowedInfrastructure = [
            "Sources/MacUpdaterCore/AppLogger.swift",
            "Sources/MacUpdaterCore/WegaLog.swift",
        ]
        let sources = try swiftSources(under: "Sources/MacUpdaterCore")
            + swiftSources(under: "Sources/MacUpdater")
        let bypasses = sources
            .filter { !allowedInfrastructure.contains($0.name) && $0.text.contains("AppLogger.") }
            .map(\.name)

        #expect(bypasses.isEmpty,
                "OBS-01: direct AppLogger calls bypass the Logs tab and wega.log: \(bypasses)")
    }

    @Test func rollbackAndSelfUpdateRejectionsUseThePersistentLog() throws {
        let rollback = try source("Sources/MacUpdater/CaskRollbackGuard.swift")
        #expect(rollback.contains("WegaLog.error(.helper"))
        #expect(rollback.contains("Rollback przez helper nie powiódł się"))

        let info = try source("Sources/MacUpdater/InfoView.swift")
        let compactInfo = info.filter { !$0.isWhitespace }
        #expect(compactInfo.contains("WegaLog.error(.app,"))
        #expect(info.contains("Self-update odrzucony przez weryfikację podpisu"))
        #expect(compactInfo.contains("WegaLog.error(.helper,"))
        #expect(info.contains("Instalacja przez helper nie powiodła się"))
    }

    @Test func backgroundAndMenuBarKeepSourceDiagnostics() throws {
        let background = try source("Sources/MacUpdater/BackgroundUpdater.swift")
        #expect(background.contains("brewOutcome.errorLines"),
                "OBS-01: background brew stderr must be copied into WegaLog")
        #expect(background.contains("WegaLog.error(.homebrew"))

        let menuBar = try source("Sources/MacUpdaterCore/MenuBarUpdateChecker.swift")
        #expect(!menuBar.contains("catch { failed += 1 }"),
                "OBS-01: count-only catches discard the error/stderr text")
        #expect(menuBar.contains("WegaLog.error(.homebrew"))
        #expect(menuBar.contains("WegaLog.error(.app"))
        #expect(menuBar.contains("WegaLog.error(.network"))
    }

    @Test func rootHelperAuditsConnectionAndEveryPermittedOperation() throws {
        let helper = try source("Sources/WegaPrivilegedHelper/HelperDelegate.swift")
        #expect(helper.contains("import OSLog"))
        #expect(helper.contains("Logger(subsystem:"))
        #expect(helper.contains("Odrzucono połączenie XPC"))
        for operation in [
            "helperVersion",
            "enableTouchIDForSudo",
            "installVerifiedPackage",
            "replaceBundle",
        ] {
            #expect(helper.contains("\(operation): sukces"),
                    "OBS-01: helper must log the successful result of \(operation)")
        }
        for operation in [
            "enableTouchIDForSudo",
            "installVerifiedPackage",
            "replaceBundle",
        ] {
            #expect(helper.contains("\(operation): błąd"),
                    "OBS-01: helper must log the failed result of \(operation)")
        }
    }
}
