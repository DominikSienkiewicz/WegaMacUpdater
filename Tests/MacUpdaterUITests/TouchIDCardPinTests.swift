import Foundation
import Testing

@testable import WegaMacUpdater

/// Source pins for the Touch ID card in `InfoView`, which SwiftUI keeps out of reach of a unit test:
/// which command each part of the card shows and hands to Terminal (RC2-8).
@Suite("Touch ID — the card's commands")
struct TouchIDCardPinTests {
    private func source(_ relativePath: String, file: String = #filePath) throws -> String {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relativePath, directoryHint: .notDirectory), encoding: .utf8)
    }

    private func slice(_ text: String, from start: String, to end: String) throws -> String {
        let lower = try #require(text.range(of: start)).upperBound
        let upper = try #require(text[lower...].range(of: end)).lowerBound
        return String(text[lower..<upper])
    }

    /// The Terminal button opens the command it was given, all the way to the dependency; nothing on
    /// the way names a command of its own.
    @Test func terminalGetsTheCommandItWasHandedAllTheWay() throws {
        let info = try source("Sources/MacUpdater/InfoView.swift")
        let forward = try slice(info, from: "private func openInTerminal(_ command: TouchIDManualCommand) {", to: "}")
        #expect(forward.contains("touchIDController.openInTerminal(command)"))
        #expect(!info.contains("TouchIDSudoConfigurator.manualEnableTerminalCommand"), "the card shows text only through the enum")
        #expect(!info.contains("TouchIDSudoConfigurator.manualDisableTerminalCommand"))
        let controller = try source("Sources/MacUpdater/TouchIDSetupController.swift")
        let open = try slice(controller, from: "func openInTerminal(_ command: TouchIDManualCommand) {", to: "}")
        #expect(open.contains("dependencies.openInTerminal(command)"))
        let live = try slice(controller, from: "static let live", to: "@Published private(set) var state")
        #expect(live.contains("openInTerminal: { command in") && live.contains("command.text"))
    }
}
