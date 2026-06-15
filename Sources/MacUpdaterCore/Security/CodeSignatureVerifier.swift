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
/// Coverage by artifact kind:
/// - `.app` → `SecStaticCode` + a code requirement pinning `anchor apple generic`
///   and the leaf certificate's Team ID. Strongest (Team ID pinned).
/// - `.pkg` → Gatekeeper install assessment (`SecAssessment`) **plus** a
///   best-effort Team ID pin parsed from `pkgutil --check-signature`.
/// - `.dmg` → Gatekeeper open assessment. The contained `.app` is additionally
///   Gatekeeper-checked by the system on first launch. (Team ID is not pinned for
///   the disk image itself — prefer the `.pkg`/`.app` channel for a full pin.)
public enum CodeSignatureVerifier {

    public enum VerifyError: Error, Equatable, LocalizedError {
        case unreadable(OSStatus)
        case badRequirement
        case signatureInvalid(OSStatus)
        case gatekeeperRejected(String)
        case teamIDMismatch(found: String?, expected: String)
        case unsupportedArtifact(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let s):        return "Nie można odczytać podpisu (OSStatus \(s))."
            case .badRequirement:           return "Niepoprawny ciąg wymagania podpisu."
            case .signatureInvalid(let s):  return "Podpis nieważny (OSStatus \(s))."
            case .gatekeeperRejected(let m): return "Gatekeeper odrzucił artefakt: \(m)"
            case .teamIDMismatch(let f, let e):
                return "Team ID nie pasuje: znaleziono \(f ?? "—"), oczekiwano \(e)."
            case .unsupportedArtifact(let ext):
                return "Nieobsługiwany typ artefaktu: .\(ext)"
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

    /// Verifies `url` is genuine and (where the kind allows) signed by `expectedTeamID`.
    /// Throws on any failure — callers MUST treat a throw as "do not open".
    public static func verify(installerAt url: URL, expectedTeamID: String, bundleID: String? = nil) throws {
        switch artifact(for: url) {
        case .app:
            try verifyStaticCode(at: url, expectedTeamID: expectedTeamID, bundleID: bundleID)
        case .pkg:
            try assessGatekeeper(at: url, operation: kSecAssessmentOperationTypeInstall)
            // Best-effort additional pin; only fails on a *mismatching* Team ID.
            if let found = pkgTeamID(at: url), found != expectedTeamID {
                throw VerifyError.teamIDMismatch(found: found, expected: expectedTeamID)
            }
        case .dmg:
            try assessGatekeeper(at: url, operation: kSecAssessmentOperationTypeOpenDocument)
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

    // MARK: - SecAssessment (pkg / dmg → Gatekeeper)

    /// Ask Gatekeeper whether it would allow `operation` on `url`. A non-nil
    /// assessment means "approved"; a nil result carries the rejection reason.
    public static func assessGatekeeper(at url: URL, operation: SecAssessmentOperationType) throws {
        var unmanagedError: Unmanaged<CFError>?
        let assessment = SecAssessmentCreate(url as CFURL, operation, SecAssessmentFlags(), &unmanagedError)
        if assessment != nil { return } // approved
        let message = (unmanagedError?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
            ?? "odrzucony przez politykę systemu"
        throw VerifyError.gatekeeperRejected(message)
    }

    // MARK: - pkg Team ID (best effort)

    /// Parses the leaf Team ID out of `pkgutil --check-signature`. Best-effort:
    /// returns nil when the tool/output shape is unavailable, so callers should
    /// fail-closed only on an explicit *mismatch*, not on nil.
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
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Developer ID leaf line looks like: "Developer ID Installer: Name (TEAMID)"
        // Grab the parenthesised 10-char alphanumeric Team ID.
        guard let match = text.range(of: #"\(([A-Z0-9]{10})\)"#, options: .regularExpression) else { return nil }
        return String(text[match].dropFirst().dropLast())
    }
}
