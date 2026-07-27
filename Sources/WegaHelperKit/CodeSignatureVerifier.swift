import Foundation
import Security

/// Verifies the authenticity of code/installers Wega is about to run — the
/// missing in-app check behind finding **A1 / SEC-03**.
///
/// Threat model: Wega downloads its own update asset from GitHub Releases and
/// hands it to the system installer. Before SEC-03 the only guard was Gatekeeper
/// *at open time*; a compromised release (or a redirected endpoint) could still
/// stage a foreign — yet notarized — payload that the user, primed by "Wega is
/// updating itself", clicks through. This type closes that gap by **pinning the
/// expected Developer Team ID** and refusing to open anything that does not match.
///
/// Coverage by artifact kind (SEC-04 — every kind pins the Team ID; none of them
/// settles for "Gatekeeper said yes", because Gatekeeper answers *"notarized by some
/// Apple developer"*, not *"published by Wega"*):
/// - `.app` → `SecStaticCode` + a code requirement pinning `anchor apple generic`
///   and the leaf certificate's Team ID.
/// - `.pkg` → Gatekeeper install assessment **plus** the Team ID parsed from
///   `pkgutil --check-signature`. A package whose Team ID cannot be read is
///   **rejected**: an unreadable pin is not a weaker pin, it is no pin at all.
/// - `.dmg` → Gatekeeper open assessment, the Team ID of the image's own signature,
///   and — after mounting the image **read-only** — a full `SecStaticCode` pin
///   (Team ID + bundle ID) of the single `.app` it carries.
///
/// Where the caller knows which version it asked for, that version is matched against
/// the payload as well, so a correctly signed but stale artifact cannot be substituted
/// for the release the user was shown.
public enum CodeSignatureVerifier {

    public enum VerifyError: Error, Equatable, LocalizedError {
        case unreadable(OSStatus)
        case badRequirement
        case signatureInvalid(OSStatus)
        case gatekeeperRejected(String)
        case teamIDMismatch(found: String?, expected: String)
        /// SEC-04 — the artifact's Team ID could not be established at all. Fail-closed:
        /// "no answer" must never be treated as "the right answer".
        case teamIDUnavailable(expected: String)
        case unsupportedArtifact(String)
        case diskImageMountFailed(String)
        case diskImageContentUnexpected(String)
        case versionMismatch(found: String?, expected: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let s):        return "Nie można odczytać podpisu (OSStatus \(s))."
            case .badRequirement:           return "Niepoprawny ciąg wymagania podpisu."
            case .signatureInvalid(let s):  return "Podpis nieważny (OSStatus \(s))."
            case .gatekeeperRejected(let m): return "Gatekeeper odrzucił artefakt: \(m)"
            case .teamIDMismatch(let f, let e):
                return "Team ID nie pasuje: znaleziono \(f ?? "—"), oczekiwano \(e)."
            case .teamIDUnavailable(let e):
                return "Nie udało się odczytać Team ID artefaktu (oczekiwano \(e)) — odrzucono."
            case .unsupportedArtifact(let ext):
                return "Nieobsługiwany typ artefaktu: .\(ext)"
            case .diskImageMountFailed(let m):
                return "Nie udało się zamontować obrazu tylko do odczytu: \(m)"
            case .diskImageContentUnexpected(let m):
                return "Nieoczekiwana zawartość obrazu: \(m)"
            case .versionMismatch(let f, let e):
                return "Wersja artefaktu nie pasuje: znaleziono \(f ?? "—"), oczekiwano \(e)."
            }
        }
    }

    // MARK: - Pure helpers (unit-tested without the Security framework)

    /// Designated code requirement pinning the Apple chain + a specific Team ID.
    /// Pure string construction so it can be unit-tested in isolation.
    public static func teamIDRequirement(teamID: String, bundleID: String? = nil) -> String {
        var parts = ["anchor apple generic"]
        if let bundleID, !bundleID.isEmpty {
            parts.append("identifier \"\(bundleID)\"")
        }
        // OU of the leaf certificate carries the Team ID for Developer ID signing.
        parts.append("certificate leaf[subject.OU] = \"\(teamID)\"")
        return parts.joined(separator: " and ")
    }

    enum Artifact: Equatable { case app, pkg, dmg, other(String) }

    /// Classify by path extension (case-insensitive). Pure → testable.
    static func artifact(for url: URL) -> Artifact {
        switch url.pathExtension.lowercased() {
        case "app":  return .app
        case "pkg":  return .pkg
        case "dmg":  return .dmg
        case let ext: return .other(ext)
        }
    }

    // MARK: - Public entry point

    /// Verifies `url` is genuine and signed by `expectedTeamID`.
    /// Throws on any failure — callers MUST treat a throw as "do not open".
    ///
    /// - Parameter expectedVersion: when the caller knows which version it asked for
    ///   (`CFBundleShortVersionString`), the payload must carry exactly that version.
    public static func verify(
        installerAt url: URL,
        expectedTeamID: String,
        bundleID: String? = nil,
        expectedVersion: String? = nil
    ) throws {
        switch artifact(for: url) {
        case .app:
            try verifyStaticCode(at: url, expectedTeamID: expectedTeamID, bundleID: bundleID)
            try verifyVersion(ofBundleAt: url, expectedVersion: expectedVersion)
        case .pkg:
            try assessGatekeeper(at: url, type: "install")
            // SEC-04 — fail-closed. This pin used to run only when `pkgutil` happened to
            // answer, so any notarized package with an unreadable signature block sailed
            // through on the Gatekeeper verdict alone.
            guard let found = pkgTeamID(at: url) else {
                throw VerifyError.teamIDUnavailable(expected: expectedTeamID)
            }
            guard found == expectedTeamID else {
                throw VerifyError.teamIDMismatch(found: found, expected: expectedTeamID)
            }
        case .dmg:
            try verifyDiskImage(
                at: url,
                expectedTeamID: expectedTeamID,
                bundleID: bundleID,
                expectedVersion: expectedVersion
            )
        case .other(let ext):
            throw VerifyError.unsupportedArtifact(ext)
        }
    }

    // MARK: - SecStaticCode (apps)

    /// Validate a bundle/executable against an `anchor apple generic` + Team ID requirement.
    public static func verifyStaticCode(at url: URL, expectedTeamID: String, bundleID: String? = nil) throws {
        var code: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard createStatus == errSecSuccess, let code else { throw VerifyError.unreadable(createStatus) }

        let reqString = teamIDRequirement(teamID: expectedTeamID, bundleID: bundleID)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw VerifyError.badRequirement }

        let checkStatus = SecStaticCodeCheckValidity(code, [], requirement)
        guard checkStatus == errSecSuccess else { throw VerifyError.signatureInvalid(checkStatus) }
    }

    /// Team ID of a signed `.app` (reused by Smart Mapping / watchdog — FEAT-02/FEAT-04).
    public static func teamID(ofAppAt url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - Disk images (SEC-04)

    /// Full verification of a `.dmg` self-update asset.
    ///
    /// Gatekeeper alone accepts **any** notarized image from **any** developer, so a foreign
    /// notarized artifact could be presented as a Wega update. Three checks close that:
    /// the image's own signature is pinned to `expectedTeamID`, the image is mounted
    /// **read-only** (and `-nobrowse`/`-noautoopen`, so nothing is shown to or opened by the
    /// user before it has been vetted), and the `.app` it carries is put through the same
    /// `SecStaticCode` requirement as any other bundle — Team ID, bundle ID and version.
    public static func verifyDiskImage(
        at url: URL,
        expectedTeamID: String,
        bundleID: String? = nil,
        expectedVersion: String? = nil
    ) throws {
        try assessGatekeeper(at: url, type: "open", primarySignatureContext: true)
        // The image itself carries a Developer ID signature (build-pkg.sh signs it); pin it.
        try verifyStaticCode(at: url, expectedTeamID: expectedTeamID)

        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-selfupdate-\(UUID().uuidString)", isDirectory: true)
        try attachReadOnly(image: url, at: mountPoint)
        defer { detachQuietly(mountPoint) }

        let app = try containedApp(inMountedRoot: mountPoint)
        try verifyStaticCode(at: app, expectedTeamID: expectedTeamID, bundleID: bundleID)
        try verifyVersion(ofBundleAt: app, expectedVersion: expectedVersion)
    }

    /// `hdiutil attach` arguments. Pure → the read-only/nobrowse guarantee is unit-tested
    /// instead of living only in a comment.
    static func attachArguments(imagePath: String, mountPoint: String) -> [String] {
        ["attach", imagePath, "-mountpoint", mountPoint, "-readonly", "-nobrowse", "-noautoopen", "-quiet"]
    }

    static func detachArguments(mountPoint: String) -> [String] {
        ["detach", mountPoint, "-force", "-quiet"]
    }

    /// The single `.app` at the root of a mounted image. An image carrying zero or several
    /// applications is not a Wega release — refuse rather than guess which one to trust.
    static func containedApp(inMountedRoot root: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let apps = entries
            .filter { $0.pathExtension.lowercased() == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard apps.count == 1, let app = apps.first else {
            throw VerifyError.diskImageContentUnexpected(
                "obraz zawiera \(apps.count) aplikacji .app w katalogu głównym — oczekiwano dokładnie jednej"
            )
        }
        return app
    }

    /// `CFBundleShortVersionString` of a bundle. Pure filesystem read → testable.
    static func shortVersion(ofBundleAt url: URL) -> String? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["CFBundleShortVersionString"] as? String
    }

    private static func verifyVersion(ofBundleAt url: URL, expectedVersion: String?) throws {
        guard let expectedVersion else { return }
        let found = shortVersion(ofBundleAt: url)
        guard found == expectedVersion else {
            throw VerifyError.versionMismatch(found: found, expected: expectedVersion)
        }
    }

    private static func attachReadOnly(image: URL, at mountPoint: URL) throws {
        do {
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        } catch {
            throw VerifyError.diskImageMountFailed(error.localizedDescription)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = attachArguments(imagePath: image.path, mountPoint: mountPoint.path)
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw VerifyError.diskImageMountFailed(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: mountPoint)
            throw VerifyError.diskImageMountFailed(
                (message?.isEmpty == false) ? message! : "hdiutil attach zakończył się kodem \(process.terminationStatus)")
        }
    }

    private static func detachQuietly(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = detachArguments(mountPoint: mountPoint.path)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: mountPoint)
    }

    // MARK: - SecAssessment (pkg / dmg → Gatekeeper)

    /// Gatekeeper assessment via `spctl --assess` (the SecAssessment C API is not
    /// bridged into Swift on this SDK). `type` is the spctl policy type: "exec"
    /// (apps), "install" (pkgs), "open" (documents/disk images). Throws on rejection.
    public static func assessGatekeeper(at url: URL, type: String, primarySignatureContext: Bool = false) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
        var arguments = ["--assess", "--type", type]
        if primarySignatureContext { arguments += ["--context", "context:primary-signature"] }
        arguments.append(url.path)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        do { try process.run() } catch { throw VerifyError.gatekeeperRejected(error.localizedDescription) }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw VerifyError.gatekeeperRejected(
                (message?.isEmpty == false) ? message! : "spctl odrzucił artefakt (kod \(process.terminationStatus))")
        }
    }

    /// Convenience: does Gatekeeper approve launching the app at `url`? Used by the
    /// post-upgrade canary (FEAT-05).
    public static func passesGatekeeperForExecution(at url: URL) -> Bool {
        (try? assessGatekeeper(at: url, type: "exec")) != nil
    }

    // MARK: - pkg Team ID

    /// Parses the leaf Team ID out of `pkgutil --check-signature`. Returns `nil` when the
    /// package is unsigned or the tool/output shape is unavailable — and SEC-04 requires
    /// callers to treat that `nil` as a **rejection**, not as a skipped check.
    public static func pkgTeamID(at url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--check-signature", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // An unsigned package exits non-zero; treat it as "no Team ID" rather than
        // scanning its output for something that looks like one.
        guard process.terminationStatus == 0 else { return nil }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Developer ID leaf line looks like: "Developer ID Installer: Name (TEAMID)"
        // Grab the parenthesised 10-char alphanumeric Team ID.
        guard let match = text.range(of: #"\(([A-Z0-9]{10})\)"#, options: .regularExpression) else { return nil }
        return String(text[match].dropFirst().dropLast())
    }
}
