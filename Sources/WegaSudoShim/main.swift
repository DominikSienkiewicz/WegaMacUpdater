import Darwin
import Foundation
import MacUpdaterCore

let sudo = Process()
sudo.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
sudo.arguments = ["-A"] + Array(CommandLine.arguments.dropFirst())
sudo.environment = AuthorizationEnvironment.sanitized(
    inherited: ProcessInfo.processInfo.environment
)

do {
    try sudo.run()
    sudo.waitUntilExit()
    exit(sudo.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("Nie udało się uruchomić /usr/bin/sudo.\n".utf8))
    exit(EXIT_FAILURE)
}
