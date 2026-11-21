import AppKit
import Darwin
import Foundation
import MacUpdaterCore

let english = !(Locale.preferredLanguages.first ?? "en").hasPrefix("pl")

// Owner decision 2026-11-21: by the time `sudo` runs this, it has read its settings, and while
// they cannot be trusted a password typed here could reach a module someone added there. A
// process of its own, it reads them itself and asks for nothing; `sudo` then fails.
if SudoPasswordPromptGate.liveReason() != nil {
    let refusal = english
        ? "Wega: the settings sudo reads can't be trusted right now, so I'm not asking for the password. The Touch ID card in Wega's Settings says what to do."
        : "Wega: ustawieniom, które czyta sudo, nie można teraz ufać, więc nie pytam o hasło. Co zrobić, mówi karta Touch ID w Ustawieniach Wegi."
    FileHandle.standardError.write(Data((refusal + "\n").utf8))
    exit(EXIT_FAILURE)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.activate(ignoringOtherApps: true)

let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
let alert = NSAlert()
alert.alertStyle = .warning
alert.messageText = "Wega Mac Updater"
alert.informativeText = english
    ? "Homebrew needs your administrator password to finish the update."
    : "Homebrew potrzebuje hasła administratora, żeby dokończyć aktualizację."
alert.accessoryView = passwordField
alert.addButton(withTitle: "OK")
alert.addButton(withTitle: english ? "Cancel" : "Anuluj")

guard alert.runModal() == .alertFirstButtonReturn else {
    exit(EXIT_FAILURE)
}
FileHandle.standardOutput.write(Data((passwordField.stringValue + "\n").utf8))
