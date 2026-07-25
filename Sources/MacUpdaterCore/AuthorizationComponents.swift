import Foundation

struct AuthorizationComponents: Equatable, Sendable {
    let askpassExecutable: URL
    let sudoShimDirectory: URL
}

enum AuthorizationComponentError: Error, LocalizedError {
    case missingExecutable(String)
    case unsafeExecutable(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            return "Brak komponentu autoryzacji \(name) w podpisanym bundle."
        case .unsafeExecutable(let name):
            return "Komponent autoryzacji \(name) nie jest zwykłym plikiem wykonywalnym."
        }
    }
}

/// Locates the two compiled authorization helpers inside the application bundle.
/// Every resolution revalidates their code signatures, which cryptographically checks
/// the Mach-O bytes before their paths are attached to a child process environment.
struct AuthorizationComponentResolver {
    typealias CodeVerifier = (URL, String) throws -> Void

    private let helpersDirectory: URL
    private let fileManager: FileManager
    private let verifyCode: CodeVerifier

    init(
        helpersDirectory: URL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true),
        fileManager: FileManager = .default,
        verifyCode: @escaping CodeVerifier = { url, signingID in
            try CodeSignatureVerifier.verifyStaticCode(
                at: url,
                expectedTeamID: WegaHelper.teamIdentifier,
                bundleID: signingID
            )
        }
    ) {
        self.helpersDirectory = helpersDirectory
        self.fileManager = fileManager
        self.verifyCode = verifyCode
    }

    func resolveAndVerify() throws -> AuthorizationComponents {
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
