import Foundation
import MacUpdaterCore
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

    private func card() throws -> String {
        try slice(source("Sources/MacUpdater/InfoView.swift"), from: "private var touchIDCard: some View", to: "// MARK: - GitHub token")
    }

    private func expectOrder(_ text: String, _ pieces: String...) throws {
        var position = text.startIndex
        for piece in pieces {
            let found = try #require(text[position...].range(of: piece), "\(piece)")
            position = found.upperBound
        }
    }

    /// E.6: the disable command is shown only through `showsDisableCommand`, once, with the
    /// `/usr/local` warning under it; otherwise the card says what the app's own read found.
    @Test func theDisableCommandIsShownOnlyThroughItsGate() throws {
        let card = try card()
        #expect(card.components(separatedBy: "command: .disable)").count - 1 == 1, "one way onto the card")
        try expectOrder(card, "if touchIDController.showsDisableCommand {",
                        "intro: tr(\"Bez pomocnika Wegi wyłączysz Touch ID dla sudo tym poleceniem w Terminalu. Usuwa tylko dokładną dyrektywę i niczego nie zmienia, jeśli plik wygląda inaczej:\")",
                        "command: .disable)", "localDirectoryWarning", "} else if let line = TouchIDDisableCopy.withoutCommand(",
                        "touchIDNote(line)")
        try expectOrder(card, "case .helperOutdated:", "touchIDNote(TouchIDDisableCopy.outdatedHelper)", "disableWithoutHelper(otherwise: nil)",
                        "case .helperMissing:", "disableWithoutHelper(otherwise: tr(\"Bez pomocnika Wegi wyłączysz je ręcznie.\"))")
    }

    /// RC2-7: the helper's disable button only through `offersDisableButton`, which no reason allows.
    @Test func theDisableButtonIsShownOnlyThroughItsGate() throws {
        let card = try card()
        try expectOrder(card, "case .available:", "if touchIDController.offersDisableButton {",
                        "Label(tr(\"Wyłącz Touch ID dla sudo\"), systemImage: \"touchid\")", ".disabled(disablingTouchID)",
                        "localDirectoryWarning")
        try expectOrder(card, "if let reason = touchIDController.recoveryOnlyReason {", "} else if touchIDController.showsEnableCommand {",
                        "} else if touchIDController.offersEnableButton {", "} else if touchIDState == .enabled {",
                        "if touchIDState == .enabled {", "Link(tr(\"Jak wyłączyć Touch ID dla sudo\")")
    }

    /// One view for both commands: it shows, copies and opens exactly the command it was given.
    @Test func theCommandViewShowsCopiesAndOpensTheCommandItIsGiven() throws {
        let info = try source("Sources/MacUpdater/InfoView.swift")
        let view = try slice(info, from: "private func manualCommand(intro: String, command: TouchIDManualCommand) -> some View {",
                             to: "private func openInTerminal(")
        try expectOrder(view, "Text(intro)", "Text(command.text)", "NSPasteboard.general.setString(command.text, forType: .string)",
                        "Label(tr(\"Skopiuj polecenie\"), systemImage: \"doc.on.doc\")", "openInTerminal(command)",
                        "Label(tr(\"Otwórz w Terminalu\"), systemImage: \"terminal\")", "Button(tr(\"Sprawdź ponownie\"))",
                        "touchIDController.refresh()", "await touchIDController.refreshDisableOffer()")
        #expect(!info.contains("manualEnableFallback"))
        withLanguage(.en) {
            #expect(tr("Skopiuj polecenie") == "Copy command")
            #expect(tr("Bez pomocnika Wegi wyłączysz Touch ID dla sudo tym poleceniem w Terminalu. Usuwa tylko dokładną dyrektywę i niczego nie zmienia, jeśli plik wygląda inaczej:")
                    == "Without the Wega helper, you can turn off Touch ID for sudo with this command in Terminal. It removes only the exact directive and changes nothing if the file looks different:")
        }
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
