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
        // SEC-03: the client's path points into a directory user processes can write to, so it
        // is never verified and never installed. It is only ever *copied from* — once — and
        // everything after that happens on the helper's own copy.
        let staged: URL
        do {
            staged = try Self.stageForInstallation(clientPath: path)
        } catch {
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
            reply(false, "Nie udało się przygotować pakietu do instalacji: \(error.localizedDescription)")
            return
        }
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }

        if let rejection = PackageStaging.rejectionForInstallPath(
            staged.path, bundleID: WegaHelper.appBundleID
        ) {
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
            reply(false, Self.message(for: rejection)); return
        }

        // Identity is captured BEFORE the signature check, not after, so the comparison further
        // down spans the verification itself — the window this card exists to close. Reading it
        // twice in a row after the check would compare the file to itself and prove nothing.
        guard let beforeVerification = Self.identity(of: staged) else {
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
            reply(false, "Nie udało się odczytać tożsamości pakietu."); return
        }

        // Defense in depth: the helper re-verifies the package as root before installing.
        do {
            try CodeSignatureVerifier.verify(installerAt: staged, expectedTeamID: WegaHelper.teamIdentifier)
        } catch {
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
            reply(false, "Weryfikacja pakietu nie powiodła się: \(error.localizedDescription)")
            return
        }

        // Same bytes verified, same bytes installed. The root-owned `0700` staging is what makes
        // the exchange impractical; this check is what makes it detectable if the directory's
        // guarantees ever regress.
        guard let beforeInstallation = Self.identity(of: staged),
              PackageStaging.rejection(
                  verified: beforeVerification, installing: beforeInstallation
              ) == nil else {
            HelperAuditLog.logger.error("installVerifiedPackage: błąd")
            reply(false, Self.message(for: .identityChanged)); return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/installer")
        process.arguments = ["-pkg", staged.path, "-target", "/"]
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

    /// SEC-03: copies the client's artifact into a root-owned staging directory and returns the
    /// copy. Every later step — signature check, identity capture, `installer` — sees only this.
    ///
    /// A fresh sub-directory per installation, created with `0700` *at creation time* rather
    /// than relaxed afterwards, so there is no instant during which it is readable by anyone
    /// else. The whole sub-directory is removed when the operation ends.
    private static func stageForInstallation(clientPath: String) throws -> URL {
        let fileManager = FileManager.default
        let root = PackageStaging.directory(bundleID: WegaHelper.appBundleID)
        try fileManager.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700), .ownerAccountID: NSNumber(value: 0)]
        )

        // The directory may predate this call; enforce the invariant instead of assuming it.
        let attributes = try fileManager.attributesOfItem(atPath: root.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value ?? 0xFFFF_FFFF
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        if let rejection = PackageStaging.rejection(ownerUID: owner, permissions: permissions) {
            throw StagingError.rejected(rejection)
        }

        let slot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: slot, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700), .ownerAccountID: NSNumber(value: 0)]
        )
        let destination = slot.appendingPathComponent(
            URL(fileURLWithPath: clientPath).lastPathComponent, isDirectory: false
        )
        try fileManager.copyItem(at: URL(fileURLWithPath: clientPath), to: destination)
        return destination
    }

    enum StagingError: Error, LocalizedError {
        case rejected(PackageStaging.Rejection)

        var errorDescription: String? {
            switch self {
            case .rejected(let rejection):
                return PrivilegedOps.message(for: rejection)
            }
        }
    }

    /// `st_dev` + `st_ino` of a file, or `nil` when it cannot be read.
    private static func identity(of url: URL) -> PackageStaging.ArtifactIdentity? {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return nil }
        return PackageStaging.ArtifactIdentity(
            device: UInt64(status.st_dev), inode: UInt64(status.st_ino)
        )
    }

    static func message(for rejection: PackageStaging.Rejection) -> String {
        switch rejection {
        case .notOwnedByRoot:
            return "Katalog stagingu nie należy do roota — instalacja odrzucona."
        case .permissionsTooOpen:
            return "Katalog stagingu ma zbyt szerokie uprawnienia — instalacja odrzucona."
        case .identityChanged:
            return "Pakiet zmienił się po weryfikacji — instalacja odrzucona."
        case .outsideStaging:
            return "Pakiet spoza katalogu stagingu — instalacja odrzucona."
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
