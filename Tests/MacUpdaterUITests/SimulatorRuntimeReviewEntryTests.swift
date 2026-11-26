import Foundation
import Testing

@Suite("Simulator runtime review entry point")
struct SimulatorRuntimeReviewEntryTests {
    @Test func xcodeCleanupOffersAnExplicitRuntimeReviewAlongsideFileResults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let screen = try String(contentsOf: root.appending(path: "Sources/MacUpdater/CleanupFileReviewView.swift"), encoding: .utf8)
        #expect(screen.contains("SimulatorRuntimeReviewView("), "The Xcode cleanup page needs an explicit simulator runtime review.")
        #expect(screen.contains("if page == .xcode {"))
        #expect(screen.contains("Button { showsRuntimes = true }"))
        #expect(screen.contains(".sheet(isPresented: $showsRuntimes)"))
        #expect(screen.contains("results(files)"))
    }
}
