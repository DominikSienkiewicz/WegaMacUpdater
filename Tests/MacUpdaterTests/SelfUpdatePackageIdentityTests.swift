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

    private func metadata(identifier: String, version: String, location: String = "/") -> Data {
        Data("<pkg-info identifier=\"\(identifier)\" version=\"\(version)\" install-location=\"\(location)\"><payload/></pkg-info>".utf8)
    }

    private func writeVersion(_ version: String, at contents: URL) throws {
        let plist = ["CFBundleIdentifier": WegaHelper.appBundleID, "CFBundleShortVersionString": version]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }
}
