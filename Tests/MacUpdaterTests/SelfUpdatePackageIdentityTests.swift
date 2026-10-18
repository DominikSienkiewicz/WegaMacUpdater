import Foundation
import Testing
@testable import WegaHelperKit

@Suite("Self-update package product and version")
struct SelfUpdatePackageIdentityTests {
    @Test func rejectsAnOlderPackageFromTheExpectedPublisher() throws {
        let data = metadata(identifier: WegaHelper.appBundleID, version: "2.0")
        #expect(throws: PackagePayloadVerifier.Failure.self) {
            try PackagePayloadVerifier.validateMetadata(data, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0")
        }
    }

    @Test func rejectsAnotherProductAndAnUnexpectedInstallRoot() {
        for data in [metadata(identifier: "com.example.other", version: "3.0"),
                     metadata(identifier: WegaHelper.appBundleID, version: "3.0", location: "/tmp")] {
            #expect(throws: PackagePayloadVerifier.Failure.self) {
                try PackagePayloadVerifier.validateMetadata(data, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0")
            }
        }
    }

    @Test func acceptsOnlyWellFormedMatchingMetadata() throws {
        try PackagePayloadVerifier.validateMetadata(
            metadata(identifier: WegaHelper.appBundleID, version: "3.0"),
            bundleID: WegaHelper.appBundleID, expectedVersion: "3.0"
        )
        for xml in ["<pkg-info/>", "<pkg-info", "<wrapper><pkg-info/></wrapper>"] {
            #expect(throws: PackagePayloadVerifier.Failure.self) {
                try PackagePayloadVerifier.validateMetadata(Data(xml.utf8), bundleID: WegaHelper.appBundleID, expectedVersion: "3.0")
            }
        }
    }

    @Test func checksTheActualPayloadVersionNotJustPackageInfo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Payload/Applications/WegaMacUpdater.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try metadata(identifier: WegaHelper.appBundleID, version: "3.0").write(to: root.appendingPathComponent("PackageInfo"))
        try writeVersion("2.0", at: contents)
        #expect(throws: CodeSignatureVerifier.VerifyError.self) {
            try PackagePayloadVerifier.verifyExpanded(
                at: root, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0", verifySignature: { _ in }
            )
        }
        try writeVersion("3.0", at: contents)
        try PackagePayloadVerifier.verifyExpanded(
            at: root, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0", verifySignature: { _ in }
        )
    }

    @Test func installedVersionVerificationReadsReplacementBytesWithoutABundleCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try writeVersion("2.0", at: contents)
        #expect(throws: CodeSignatureVerifier.VerifyError.self) {
            try CodeSignatureVerifier.verifyVersion(ofBundleAt: root, expectedVersion: "3.0")
        }
        try writeVersion("3.0", at: contents)
        try CodeSignatureVerifier.verifyVersion(ofBundleAt: root, expectedVersion: "3.0")
    }

    @Test func aMatchingVersionCannotBypassPayloadIdentityOrSignatureVerification() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Payload/Applications/WegaMacUpdater.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try metadata(identifier: WegaHelper.appBundleID, version: "3.0").write(to: root.appendingPathComponent("PackageInfo"))
        let foreign = ["CFBundleIdentifier": "com.example.other", "CFBundleShortVersionString": "3.0"]
        try PropertyListSerialization.data(fromPropertyList: foreign, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        #expect(throws: PackagePayloadVerifier.Failure.self) {
            try PackagePayloadVerifier.verifyExpanded(
                at: root, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0", verifySignature: { _ in }
            )
        }
        try writeVersion("3.0", at: contents)
        #expect(throws: CodeSignatureVerifier.VerifyError.self) {
            try PackagePayloadVerifier.verifyExpanded(at: root, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0") { _ in
                throw CodeSignatureVerifier.VerifyError.teamIDMismatch(found: "FOREIGN", expected: WegaHelper.teamIdentifier)
            }
        }
    }

    @Test func verificationRefusesToStartWithoutAnExpectedIdentityAndVersion() {
        let package = URL(fileURLWithPath: "/nonexistent/update.pkg")
        let expectations: [(bundleID: String?, version: String?)] = [
            (nil, "3.0"), ("", "3.0"), (WegaHelper.appBundleID, nil), (WegaHelper.appBundleID, "")
        ]
        for expectation in expectations {
            let failure = Self.payloadFailure {
                try PackagePayloadVerifier.verify(
                    at: package, teamID: WegaHelper.teamIdentifier,
                    bundleID: expectation.bundleID, expectedVersion: expectation.version
                )
            }
            guard case .missingExpectation = failure else {
                Issue.record("expected missingExpectation for \(expectation), got \(String(describing: failure))")
                continue
            }
        }
    }

    @Test func aFileThatIsNotAPackageFailsExpansionInsteadOfBeingTrusted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("update.pkg")
        try Data("not a package".utf8).write(to: package)
        let failure = await offCooperativePool {
            Self.payloadFailure {
                try PackagePayloadVerifier.verify(
                    at: package, teamID: WegaHelper.teamIdentifier, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0"
                )
            }
        }
        guard case .expansionFailed = failure else {
            Issue.record("expected expansionFailed, got \(String(describing: failure))")
            return
        }
    }

    @Test func anAppBundleLinkedOutsideTheExpandedPackageIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let applications = root.appendingPathComponent("Payload/Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try metadata(identifier: WegaHelper.appBundleID, version: "3.0").write(to: root.appendingPathComponent("PackageInfo"))
        let foreignContents = outside.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: foreignContents, withIntermediateDirectories: true)
        try writeVersion("3.0", at: foreignContents)
        try FileManager.default.createSymbolicLink(
            at: applications.appendingPathComponent("WegaMacUpdater.app"), withDestinationURL: outside
        )
        let failure = Self.payloadFailure {
            try PackagePayloadVerifier.verifyExpanded(
                at: root, bundleID: WegaHelper.appBundleID, expectedVersion: "3.0", verifySignature: { _ in }
            )
        }
        guard case .unexpectedPackage = failure else {
            Issue.record("expected unexpectedPackage, got \(String(describing: failure))")
            return
        }
    }

    @Test func everyPayloadFailureNamesTheProblem() throws {
        let failures: [PackagePayloadVerifier.Failure] = [
            .missingExpectation, .unexpectedPackage("identyfikator aplikacji"), .expansionFailed("pkgutil: error")
        ]
        let descriptions = failures.compactMap(\.errorDescription)
        try #require(descriptions.count == failures.count)
        #expect(Set(descriptions).count == failures.count)
        #expect(descriptions[1].hasSuffix("identyfikator aplikacji"))
        #expect(descriptions[2].hasSuffix("pkgutil: error"))
    }

    private static func payloadFailure(of body: () throws -> Void) -> PackagePayloadVerifier.Failure? {
        do {
            try body()
            return nil
        } catch {
            return error as? PackagePayloadVerifier.Failure
        }
    }

    /// `verify` waits for `pkgutil` to exit; called straight from the test it would park a
    /// cooperative-pool thread for the child's whole lifetime.
    private func offCooperativePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: body()) }.start()
        }
    }

    private func metadata(identifier: String, version: String, location: String = "/") -> Data {
        Data("<pkg-info identifier=\"\(identifier)\" version=\"\(version)\" install-location=\"\(location)\"><payload/></pkg-info>".utf8)
    }

    private func writeVersion(_ version: String, at contents: URL) throws {
        let plist = ["CFBundleIdentifier": WegaHelper.appBundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
}
