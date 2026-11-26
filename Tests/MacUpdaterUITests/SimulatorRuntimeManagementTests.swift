import Foundation
import Testing

@Suite("Simulator runtime management")
struct SimulatorRuntimeManagementTests {
    @Test func eachRuntimeOffersItsOwnXcodeManagementAction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appending(path: "Sources/MacUpdater/SimulatorRuntimeReviewView.swift"), encoding: .utf8)
        let row = try #require(sheet.range(of: "ForEach(groups[platform] ?? [], id:"))
        #expect(sheet[row.upperBound...].contains("managementAction(for: runtime)"),
                "Each runtime row should offer a management action for that runtime.")
    }
}
