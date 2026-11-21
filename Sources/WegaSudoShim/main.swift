import Darwin
import Foundation
import MacUpdaterCore

// Owner decision 2026-11-21: `sudo` reads its settings before it asks, so while they cannot be
// trusted the shim lets it ask for nothing. A process of its own, it reads them itself.
let promptsAllowed = SudoPasswordPromptGate.liveReason() == nil

let sudo = Process()
sudo.executableURL = SystemPaths.sudo
sudo.arguments = HomebrewEnvironment.sudoShimArguments(
    forwarding: Array(CommandLine.arguments.dropFirst()), promptsAllowed: promptsAllowed
)
sudo.environment = AuthorizationEnvironment.sanitized(
    inherited: ProcessInfo.processInfo.environment,
    overrides: HomebrewEnvironment.trustedSudoShimOverrides(promptsAllowed: promptsAllowed)
)

do {
    try sudo.run()
    sudo.waitUntilExit()
    exit(sudo.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("Nie udało się uruchomić /usr/bin/sudo.\n".utf8))
    exit(EXIT_FAILURE)
}
