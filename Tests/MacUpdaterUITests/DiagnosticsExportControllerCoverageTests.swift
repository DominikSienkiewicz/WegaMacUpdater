import Foundation
import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Diagnostics export controller helpers")
@MainActor
struct DiagnosticsExportControllerCoverageTests {
    @Test func absentSourceReportsProduceNoDiagnosticsRows() {
        #expect(DiagnosticsExportController.sourceResults(nil).isEmpty)
    }

    @Test func everySourceOutcomeGetsAStableDiagnosticsRepresentation() {
        let reports = ScanSourceReports(
            brewMetadata: ScanSourceReport(outcome: .succeeded),
            brew: ScanSourceReport(outcome: .notInstalled),
            mas: ScanSourceReport(outcome: .failed("fallback"), error: "specific"),
            npm: ScanSourceReport(outcome: .failed("reason")),
            manual: ScanSourceReport(outcome: .succeeded)
        )

        let results = DiagnosticsExportController.sourceResults(reports)

        #expect(results == [
            .init(source: "Homebrew metadata", outcome: "succeeded", error: nil),
            .init(source: "Homebrew", outcome: "not installed", error: nil),
            .init(source: "Mac App Store", outcome: "failed", error: "specific"),
            .init(source: "npm", outcome: "failed", error: "reason"),
            .init(source: "manual checkers", outcome: "succeeded", error: nil),
        ])
    }

    @Test func everyHelperStatusHasAStableLabel() {
        #expect(DiagnosticsExportController.helperStatusLabel(.notRegistered) == "not registered")
        #expect(DiagnosticsExportController.helperStatusLabel(.requiresApproval) == "requires approval")
        #expect(DiagnosticsExportController.helperStatusLabel(.enabled) == "enabled")
        #expect(DiagnosticsExportController.helperStatusLabel(.notFound) == "not found")
        #expect(DiagnosticsExportController.helperStatusLabel(.unknown) == "unknown")
    }

    @Test func architectureReportsTheCurrentMachine() {
        #expect(!DiagnosticsExportController.architecture().isEmpty)
    }

    @Test func toolVersionHandlesMissingEmptyAndMultilineOutput() async {
        let missing = await DiagnosticsExportController.toolVersion(
            locator: { nil },
            arguments: []
        )
        let empty = await DiagnosticsExportController.toolVersion(
            locator: { URL(fileURLWithPath: "/usr/bin/true") },
            arguments: []
        )
        let multiline = await DiagnosticsExportController.toolVersion(
            locator: { URL(fileURLWithPath: "/usr/bin/printf") },
            arguments: ["tool 1.2\nsecond line\n"]
        )

        #expect(missing == nil)
        #expect(empty == nil)
        #expect(multiline == "tool 1.2")
    }

    @Test func signatureSnapshotAlwaysNamesTheWegaBundle() {
        let records = DiagnosticsExportController.signatures()

        #expect(records.first?.subject == "Wega bundle")
        #expect(records.first?.verdict.isEmpty == false)
    }

    @Test func snapshotGathersACompleteLocalDiagnosticsPicture() async {
        let snapshot = await DiagnosticsExportController().snapshot()

        #expect(!snapshot.appVersion.isEmpty)
        #expect(!snapshot.appBuild.isEmpty)
        #expect(!snapshot.bundleIdentifier.isEmpty)
        #expect(!snapshot.osVersion.isEmpty)
        #expect(!snapshot.architecture.isEmpty)
        #expect(snapshot.processorCount > 0)
        #expect(snapshot.managers.map(\.name) == ["Homebrew", "mas-cli", "npm"])
        #expect(!snapshot.helper.status.isEmpty)
    }

    @Test func missingLogDirectoryProducesNoExportEntries() {
        let files = DiagnosticsExportController.logFiles()

        #expect(files.allSatisfy { ["wega.log", "wega.log.1"].contains($0.name) })
    }

    @Test func revealWithoutAPreviousExportIsANoOp() {
        DiagnosticsExportController().revealLastExport()
    }
}
