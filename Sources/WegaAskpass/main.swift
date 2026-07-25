import AppKit
import Darwin
import Foundation

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.activate(ignoringOtherApps: true)

let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
let alert = NSAlert()
alert.alertStyle = .warning
alert.messageText = "Wega Mac Updater"
alert.informativeText = "Homebrew prosi o hasło administratora, aby dokończyć operację."
alert.accessoryView = passwordField
alert.addButton(withTitle: "OK")
alert.addButton(withTitle: "Anuluj")

guard alert.runModal() == .alertFirstButtonReturn else {
    exit(EXIT_FAILURE)
}
FileHandle.standardOutput.write(Data((passwordField.stringValue + "\n").utf8))
