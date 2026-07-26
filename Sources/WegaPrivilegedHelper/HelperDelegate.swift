import Foundation
import WegaHelperKit
import OSLog

private enum HelperAuditLog {
    static let logger = Logger(subsystem: WegaHelper.helperSigningID, category: "PrivilegedHelper")
}

/// Accepts XPC connections only from the genuine, correctly-signed app, then
/// vends the whitelisted operations object.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Pin the client: Apple chain + app identifier + Team ID. The kernel
        // enforces this against the peer's audit token (not a forgeable PID).
        // macOS 13+. Refuse everything if the Team ID hasn't been configured.
        guard WegaHelper.isTeamIDConfigured else {
            HelperAuditLog.logger.error("Odrzucono połączenie XPC: Team ID helpera nie jest skonfigurowany.")
            return false
        }
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
        HelperAuditLog.logger.info("helperVersion: sukces")
        reply(WegaHelper.version)
    }

    func enableTouchIDForSudo(withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        do {
            try TouchIDSudoConfigurator.writeSudoLocalEnablingTouchID()
            HelperAuditLog.logger.info("enableTouchIDForSudo: sukces")
            reply(true, nil)
        } catch {
            HelperAuditLog.logger.error("enableTouchIDForSudo: błąd")
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
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
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
                HelperAuditLog.logger.info("installVerifiedPackage: sukces")
                reply(true, nil)
            } else {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? "installer zakończył się kodem \(process.terminationStatus)"
                HelperAuditLog.logger.error("installVerifiedPackage: błąd")
                reply(false, message)
            }
        } catch {
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
            reply(false, error.localizedDescription)
        }
    }

    func replaceBundle(atPath targetPath: String, withSnapshotAtPath snapshotPath: String, withReply reply: @escaping @Sendable (Bool, String?) -> Void) {
        let fileManager = FileManager.default
        let target = URL(fileURLWithPath: targetPath)
        let snapshot = URL(fileURLWithPath: snapshotPath)

        // Twarda walidacja — to NIE jest generyczne „nadpisz cokolwiek jako root".
        // Sama decyzja o ścieżce mieszka w `WegaHelper` (Core), więc jest pokryta testem;
        // tu zostają tylko efekty uboczne (log + reply) i sprawdzenia stanu FS/Gatekeepera.
        switch WegaHelper.bundleReplacementRejection(targetPath: targetPath, snapshotPath: snapshotPath) {
        case .notBundle:
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Dozwolone tylko bundle .app."); return
        case .outsideApplications:
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Cel poza /Applications — odrzucono."); return
        case .symlinkedTarget, .identityMismatch:
            // Not reachable from the lexical gate, which never inspects the filesystem.
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Cel odrzucony przez walidację ścieżki."); return
        case nil:
            break
        }

        // SEC-03: everything above is a decision about strings. These are the facts only the
        // filesystem can answer, gathered as root immediately before the replacement.
        switch WegaHelper.bundleReplacementRejection(facts: Self.facts(target: target, snapshot: snapshot)) {
        case .symlinkedTarget:
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Cel jest dowiązaniem lub prowadzi przez dowiązanie — odrzucono."); return
        case .identityMismatch:
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Snapshot nie pochodzi z tej samej aplikacji — odrzucono."); return
        case .notBundle, .outsideApplications:
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Cel odrzucony przez walidację ścieżki."); return
        case nil:
            break
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: snapshotPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Brak prawidłowego snapshotu do przywrócenia."); return
        }
        // Defense in depth: przywracamy tylko prawidłowo podpisaną aplikację.
        guard CodeSignatureVerifier.passesGatekeeperForExecution(at: snapshot) else {
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, "Snapshot nie przeszedł oceny Gatekeeper."); return
        }
        do {
            _ = try fileManager.replaceItemAt(target, withItemAt: snapshot)
            HelperAuditLog.logger.info("replaceBundle: sukces")
            reply(true, nil)
        } catch {
            HelperAuditLog.logger.error("replaceBundle: błąd")
            reply(false, error.localizedDescription)
        }
    }

    /// SEC-03: reads, as root, the filesystem facts the pure gate decides on.
    ///
    /// `lstat` rather than `stat` on purpose — `stat` follows the link and would report on
    /// whatever it points at, which is precisely the substitution being guarded against.
    private static func facts(target: URL, snapshot: URL) -> WegaHelper.BundleReplacementFacts {
        var status = stat()
        let isSymlink = lstat(target.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK

        // `realpath` resolves every component, so a swapped parent directory shows up here even
        // when the target itself is an ordinary directory.
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path

        return WegaHelper.BundleReplacementFacts(
            targetResolvedPath: resolved,
            targetIsSymlink: isSymlink,
            targetBundleID: bundleIdentifier(at: target),
            targetTeamID: CodeSignatureVerifier.teamID(ofAppAt: target),
            snapshotBundleID: bundleIdentifier(at: snapshot),
            snapshotTeamID: CodeSignatureVerifier.teamID(ofAppAt: snapshot)
        )
    }

    /// `CFBundleIdentifier` straight from `Info.plist`. Returns `nil` when the bundle is
    /// unreadable or carries no identifier — the gate treats that as a rejection.
    private static func bundleIdentifier(at bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plist),
              let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = parsed as? [String: Any] else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
    }
}
