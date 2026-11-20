import AppKit
import Darwin
import Foundation

let english = !(Locale.preferredLanguages.first ?? "en").hasPrefix("pl")

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
