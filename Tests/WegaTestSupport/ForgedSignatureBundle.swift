import Foundation

/// A throwaway `.app` whose ad-hoc signature claims a Team ID that no certificate carries.
///
/// `codesign --sign - --team-identifier` writes any Team ID into an ad-hoc code directory, and
/// the Security framework reads that claim back as the bundle's Team ID; even
/// `SecStaticCodeCheckValidity` without a requirement calls the signature valid. This is the
/// forgery a publisher check must refuse. The bundle wraps a copy of `/usr/bin/true`, so building
/// it needs no keychain, no signing identity and no network.
public struct ForgedSignatureBundle: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case codesign(status: Int32, message: String)

        public var description: String {
            switch self {
            case let .codesign(status, message): "codesign exited \(status): \(message)"
            }
        }
    }

    /// The signed `.app`.
    public let url: URL
    private let root: URL

    /// Builds and ad-hoc signs a bundle that claims `teamID`.
    public static func make(
        claimingTeamID teamID: String,
        bundleID: String = "com.example.forged"
    ) async throws -> ForgedSignatureBundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wega-forged-signature-\(UUID().uuidString)", isDirectory: true)
        let app = root.appendingPathComponent("Forged.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: macOS.appendingPathComponent("Forged")
        )
        let info: [String: String] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Forged",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        // `--force` replaces the platform signature `/usr/bin/true` arrives with.
        try await run("/usr/bin/codesign", ["--sign", "-", "--force", "--team-identifier", teamID, app.path])
        return ForgedSignatureBundle(url: app, root: root)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Waits for the child through its termination handler, so no thread of the cooperative
    /// pool is blocked while `codesign` runs.
    private static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw Failure.codesign(status: status, message: message)
        }
    }
}
