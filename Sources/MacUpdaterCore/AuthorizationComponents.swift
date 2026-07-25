import Darwin
import Foundation

struct AuthorizationComponents: Equatable, Sendable {
    let askpassExecutable: URL
    let sudoShimDirectory: URL
}

enum AuthorizationComponentError: Error, LocalizedError {
    case missingExecutable(String)
    case unsafeExecutable(String)
    case untrustedLocation(String)
    case locationInspectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            return "Brak komponentu autoryzacji \(name) w podpisanym bundle."
        case .unsafeExecutable(let name):
            return "Komponent autoryzacji \(name) nie jest zwykłym plikiem wykonywalnym."
        case .untrustedLocation(let path):
            return "Ścieżka komponentu autoryzacji jest modyfikowalna: \(path)."
        case .locationInspectionFailed(let path):
            return "Nie można zweryfikować ścieżki komponentu autoryzacji: \(path)."
        }
    }
}

struct AuthorizationPathMetadata: Equatable, Sendable {
    let ownerID: UInt32
    let permissions: Int
    let isSymbolicLink: Bool
    let isWritableByCurrentUser: Bool
}

/// Establishes a location invariant that remains true after code-signature validation.
/// A same-user process cannot replace a component when every path element is root-owned
/// and not group/world-writable. A genuinely read-only mounted filesystem provides the
/// equivalent guarantee even when its archived numeric ownership differs.
struct AuthorizationPathTrustValidator {
    typealias MetadataProvider = (URL) throws -> AuthorizationPathMetadata
    typealias ReadOnlyVolumeProvider = (URL) throws -> Bool

    private let metadataAt: MetadataProvider
    private let volumeIsReadOnly: ReadOnlyVolumeProvider

    init(
        metadataAt: @escaping MetadataProvider = Self.liveMetadata,
        volumeIsReadOnly: @escaping ReadOnlyVolumeProvider = Self.liveVolumeIsReadOnly
    ) {
        self.metadataAt = metadataAt
        self.volumeIsReadOnly = volumeIsReadOnly
    }

    func validate(_ executable: URL) throws {
        let standardized = executable.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw AuthorizationComponentError.untrustedLocation(executable.path)
        }

        let entries = try pathChain(to: standardized).map { url in
            (url, try metadataAt(url))
        }
        if let symbolicLink = entries.first(where: { $0.1.isSymbolicLink }) {
            throw AuthorizationComponentError.untrustedLocation(symbolicLink.0.path)
        }

        if try volumeIsReadOnly(standardized) {
            return
        }

        for (url, metadata) in entries {
            let writableByNonRoot = metadata.permissions & 0o022 != 0
            guard metadata.ownerID == 0,
                  !writableByNonRoot,
                  !metadata.isWritableByCurrentUser else {
                throw AuthorizationComponentError.untrustedLocation(url.path)
            }
        }
    }

    private func pathChain(to url: URL) -> [URL] {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var result = [current]
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            result.append(current)
        }
        return result
    }

    private static func liveMetadata(at url: URL) throws -> AuthorizationPathMetadata {
        var information = stat()
        guard Darwin.lstat(url.path, &information) == 0 else {
            throw AuthorizationComponentError.locationInspectionFailed(url.path)
        }
        let mode = Int(information.st_mode)
        return AuthorizationPathMetadata(
            ownerID: UInt32(information.st_uid),
            permissions: mode & 0o7777,
            isSymbolicLink: mode & Int(S_IFMT) == Int(S_IFLNK),
            isWritableByCurrentUser: Darwin.access(url.path, W_OK) == 0
        )
    }

    private static func liveVolumeIsReadOnly(at url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        guard let isReadOnly = values.volumeIsReadOnly else {
            throw AuthorizationComponentError.locationInspectionFailed(url.path)
        }
        return isReadOnly
    }
}

/// Locates the two compiled authorization helpers in an immutable installed or bundled path.
/// Every resolution validates that invariant and their code signatures before the paths are
/// attached to a child process environment.
struct AuthorizationComponentResolver {
    typealias CodeVerifier = (URL, String) throws -> Void
    typealias LocationValidator = (URL) throws -> Void

    private static let installedHelpersDirectory = URL(
        fileURLWithPath: "/Library/Application Support/WegaMacUpdater/Authorization",
        isDirectory: true
    )

    private let helperDirectories: [URL]
    private let fileManager: FileManager
    private let verifyCode: CodeVerifier
    private let validateLocation: LocationValidator

    init(fileManager: FileManager = .default) {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
        self.init(
            helperDirectories: [Self.installedHelpersDirectory, bundled],
            fileManager: fileManager,
            verifyCode: { url, signingID in
                try CodeSignatureVerifier.verifyStaticCode(
                    at: url,
                    expectedTeamID: WegaHelper.teamIdentifier,
                    bundleID: signingID
                )
            },
            validateLocation: { url in
                try AuthorizationPathTrustValidator().validate(url)
            }
        )
    }

    init(
        helpersDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.init(
            helperDirectories: [helpersDirectory],
            fileManager: fileManager,
            verifyCode: { url, signingID in
                try CodeSignatureVerifier.verifyStaticCode(
                    at: url,
                    expectedTeamID: WegaHelper.teamIdentifier,
                    bundleID: signingID
                )
            },
            validateLocation: { url in
                try AuthorizationPathTrustValidator().validate(url)
            }
        )
    }

    /// Signature-focused test seam. Production uses the initializer above, which also
    /// enforces the immutable-location invariant before returning any executable path.
    init(
        helpersDirectory: URL,
        fileManager: FileManager = .default,
        verifyCode: @escaping CodeVerifier
    ) {
        self.init(
            helperDirectories: [helpersDirectory],
            fileManager: fileManager,
            verifyCode: verifyCode,
            validateLocation: { _ in }
        )
    }

    init(
        helperDirectories: [URL],
        fileManager: FileManager,
        verifyCode: @escaping CodeVerifier,
        validateLocation: @escaping LocationValidator
    ) {
        self.helperDirectories = helperDirectories
        self.fileManager = fileManager
        self.verifyCode = verifyCode
        self.validateLocation = validateLocation
    }

    func resolveAndVerify() throws -> AuthorizationComponents {
        var lastError: Error?
        for directory in helperDirectories {
            do {
                return try resolveAndVerify(in: directory)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AuthorizationComponentError.missingExecutable("WegaAskpass")
    }

    private func resolveAndVerify(in helpersDirectory: URL) throws -> AuthorizationComponents {
        let askpass = helpersDirectory.appendingPathComponent("WegaAskpass")
        let sudoDirectory = helpersDirectory.appendingPathComponent(
            "sudo-shim",
            isDirectory: true
        )
        let sudo = sudoDirectory.appendingPathComponent("sudo")

        try validate(askpass, signingID: WegaHelper.askpassSigningID)
        try validate(sudo, signingID: WegaHelper.sudoShimSigningID)
        return AuthorizationComponents(
            askpassExecutable: askpass,
            sudoShimDirectory: sudoDirectory
        )
    }

    private func validate(_ url: URL, signingID: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw AuthorizationComponentError.missingExecutable(url.lastPathComponent)
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              fileManager.isExecutableFile(atPath: url.path) else {
            throw AuthorizationComponentError.unsafeExecutable(url.lastPathComponent)
        }
        try validateLocation(url)
        try verifyCode(url, signingID)
    }
}

/// Environment accepted by authorization-bearing child processes. Anything outside this
/// finite list is removed, including loader injection variables and `WEGA_SUDO_REAL`.
public enum AuthorizationEnvironment {
    private static let allowedKeys: Set<String> = [
        "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "PATH",
        "SUDO_ASKPASS", "TMPDIR", "USER"
    ]

    public static func sanitized(
        inherited: [String: String],
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var result = inherited.filter { allowedKeys.contains($0.key) }
        for (key, value) in overrides where allowedKeys.contains(key) {
            result[key] = value
        }
        return result
    }
}
