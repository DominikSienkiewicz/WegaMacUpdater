import Foundation
import Testing
import WegaTestSupport
@testable import WegaHelperKit

/// `verifyStaticCode` decides whether Wega trusts its own code: the `.dmg` and the app inside it,
/// the `.pkg` payload (in the app and again in the helper), the bundle the installer left in
/// `/Applications`, and the askpass helpers. It used `SecStaticCodeCheckValidity` with default
/// flags, which hash only the slice this Mac runs and none of the nested code, and a requirement
/// that the same team's Apple Development or Apple Distribution certificate also meets.
@Suite("Wega's own code: strict signature check")
struct OwnCodeStrictSignatureTests {

    /// The helper demands `clientRequirement()` of the app on every XPC connection, and the app
    /// demands `helperRequirement()` of the helper. An update that meets a looser requirement
    /// installs a Wega the helper refuses, for example one signed with the team's Apple
    /// Development certificate, which any team member can make in Xcode.
    @Test func wegasOwnCodeMustMeetWhatTheAppAndTheHelperDemandOfEachOther() {
        let team = WegaHelper.teamIdentifier

        #expect(CodeSignatureVerifier.teamIDRequirement(teamID: team, bundleID: WegaHelper.appBundleID)
            == WegaHelper.clientRequirement())
        #expect(CodeSignatureVerifier.teamIDRequirement(teamID: team, bundleID: WegaHelper.helperSigningID)
            == WegaHelper.helperRequirement())
    }

    /// Measured on a copy of Wega 0.8.0: the default flags accept a flipped byte in the x86_64
    /// slice on an arm64 Mac.
    @Test(.enabled(if: !DeveloperIDApp.installed.isEmpty, "needs a universal Developer ID app with nested code"))
    func aTamperedSliceThisMacDoesNotRunIsRefused() async throws {
        let rejection = try await rejectionOfATamperedCopy(.sliceThisMacDoesNotRun)

        #expect(rejection.isSignatureInvalid, "got \(rejection)")
    }

    /// Measured on a copy of Wega 0.8.0: the default flags accept a flipped byte in the nested
    /// root helper `WegaPrivilegedHelper` and in `WegaAskpass`, which the bundle seals by
    /// code directory hash only.
    @Test(.enabled(if: !DeveloperIDApp.installed.isEmpty, "needs a universal Developer ID app with nested code"))
    func aTamperedNestedExecutableIsRefused() async throws {
        let rejection = try await rejectionOfATamperedCopy(.nestedCode)

        #expect(rejection.isSignatureInvalid, "got \(rejection)")
    }

    /// The tests above need an app with nested code installed. Where there is none, this keeps the
    /// flags from quietly going back to the defaults.
    @Test func theCheckHashesEveryArchitectureAndNestedCodeStrictly() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/WegaHelperKit/CodeSignatureVerifier.swift"),
            encoding: .utf8
        )
        let check = try #require(source.range(
            of: "public static func verifyStaticCode(at url: URL, expectedTeamID: String, bundleID: String? = nil) throws {"
        ))

        #expect(source[check.upperBound...].prefix(300).contains("flags: publisherValidationFlags"))
    }

    /// The first of up to three installed apps that passes the check untouched, so a check that
    /// refused genuine Developer ID code fails the tests instead of passing them for the wrong
    /// reason. Chosen once: validating an Electron app's nested framework takes over a second.
    private static let untouchedApp: DeveloperIDApp? = DeveloperIDApp.installed.prefix(3)
        .first { verify($0.url, as: $0) == .passed }

    private func rejectionOfATamperedCopy(_ tamper: DeveloperIDApp.Tamper) async throws -> Rejection {
        try await offTheCooperativePool {
            guard let app = Self.untouchedApp else {
                return .noUntouchedAppPassed(DeveloperIDApp.installed.prefix(3).map(\.url.lastPathComponent))
            }
            let copy = try app.tamperedCopy(tamper)
            defer { copy.remove() }
            return Self.verify(copy.url, as: app)
        }
    }

    private static func verify(_ url: URL, as app: DeveloperIDApp) -> Rejection {
        do {
            try CodeSignatureVerifier.verifyStaticCode(at: url, expectedTeamID: app.teamID, bundleID: app.signingIdentifier)
            return .passed
        } catch let error as CodeSignatureVerifier.VerifyError {
            return .refused(error)
        } catch {
            return .unexpected(String(describing: error))
        }
    }

    private enum Rejection: Equatable, Sendable {
        case passed
        case refused(CodeSignatureVerifier.VerifyError)
        case unexpected(String)
        case noUntouchedAppPassed([String])

        var isSignatureInvalid: Bool {
            if case .refused(.signatureInvalid) = self { return true }
            return false
        }
    }
}

/// Runs `work` on a thread of its own, so the cooperative pool is not blocked while it copies and hashes.
private func offTheCooperativePool<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try work() }) }.start()
    }
}
