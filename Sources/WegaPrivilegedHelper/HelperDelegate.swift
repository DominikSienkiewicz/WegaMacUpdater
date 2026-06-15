import Foundation
import MacUpdaterCore

/// Accepts XPC connections only from the genuine, correctly-signed app, then
/// vends the whitelisted operations object.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Pin the client: Apple chain + app identifier + Team ID. The kernel
        // enforces this against the peer's audit token (not a forgeable PID).
        // macOS 13+. Refuse everything if the Team ID hasn't been configured.
        guard WegaHelper.isTeamIDConfigured else { return false }
        newConnection.setCodeSigningRequirement(WegaHelper.clientRequirement())

        newConnection.exportedInterface = NSXPCInterface(with: WegaPrivilegedOps.self)
        newConnection.exportedObject = PrivilegedOps()
        newConnection.resume()
        return true
    }
}

/// The whitelist. Each method does ONE bounded, well-defined privileged action,
/// validating its inputs as root. No generic command execution.
final class PrivilegedOps: NSObject, WegaPrivilegedOps, @unchecked Sendable {

    func helperVersion(withReply reply: @escaping @Sendable (String) -> Void) {
        reply(WegaHelper.version)
    }

    func enableTouchIDForSudo(withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            try TouchIDSudoConfigurator.writeSudoLocalEnablingTouchID()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func installVerifiedPackage(atPath path: String, withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        let url = URL(fileURLWithPath: path)

        // Defense in depth: the helper re-verifies the package as root before
        // installing — never trust the path the client handed over.
        do {
            try CodeSignatureVerifier.verify(installerAt: url, expectedTeamID: WegaHelper.teamIdentifier)
        } catch {
            reply(false, "Weryfikacja pakietu nie powiodła się: \(error.localizedDescription)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", path, "-target", "/"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                reply(true, nil)
            } else {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "installer zakończył się kodem \(process.terminationStatus)"
                reply(false, message)
            }
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func replaceBundle(atPath targetPath: String, withSnapshotAtPath snapshotPath: String, withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        let fileManager = FileManager.default
        let target = URL(fileURLWithPath: targetPath)
        let snapshot = URL(fileURLWithPath: snapshotPath)

        // Twarda walidacja — to NIE jest generyczne „nadpisz cokolwiek jako root".
        guard targetPath.hasSuffix(".app"), snapshotPath.hasSuffix(".app") else {
            reply(false, "Dozwolone tylko bundle .app."); return
        }
        guard targetPath.hasPrefix("/Applications/") else {
            reply(false, "Cel poza /Applications — odrzucono."); return
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: snapshotPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            reply(false, "Brak prawidłowego snapshotu do przywrócenia."); return
        }
        // Defense in depth: przywracamy tylko prawidłowo podpisaną aplikację.
        guard CodeSignatureVerifier.passesGatekeeperForExecution(at: snapshot) else {
            reply(false, "Snapshot nie przeszedł oceny Gatekeeper."); return
        }
        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: snapshot)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }
}
