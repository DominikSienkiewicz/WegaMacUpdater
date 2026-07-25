import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("SEC-05 authorization location regressions")
struct SEC05AuthorizationLocationTests {
    @Test func packageKeepsRootOwnedAuthorizationComponentsExecutableButNotWritable() throws {
        let script = try String(
            contentsOf: packageRoot().appendingPathComponent("scripts/build-pkg.sh"),
            encoding: .utf8
        )

        #expect(script.contains(#"chmod 0755 "$CONTENTS/Helpers" "$CONTENTS/Helpers/sudo-shim""#))
        #expect(script.contains(#"chmod 0555 "$CONTENTS/Helpers/WegaAskpass" "$CONTENTS/Helpers/sudo-shim/sudo""#))
        #expect(script.contains(#"PKG_AUTHORIZATION_DIR="$PKG_ROOT/Library/Application Support/WegaMacUpdater/Authorization""#))
        #expect(script.contains(#"cp "$CONTENTS/Helpers/WegaAskpass" "$PKG_AUTHORIZATION_DIR/WegaAskpass""#))
        #expect(script.contains(#"cp "$CONTENTS/Helpers/sudo-shim/sudo" "$PKG_AUTHORIZATION_DIR/sudo-shim/sudo""#))
        #expect(script.contains(#"--root "$PKG_ROOT""#))
        #expect(script.contains(#"--ownership recommended"#))
        #expect(!script.contains(#"chmod -R u+w "$APP_BUNDLE""#))
    }

    @Test func userOwnedWritableBundleLocationFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wega-user-owned-authorization-\(UUID().uuidString)",
            isDirectory: true
        )
        let executable = root.appendingPathComponent("WegaAskpass")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("signed bytes would be here".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: executable.path
        )

        #expect(throws: AuthorizationComponentError.self) {
            try AuthorizationPathTrustValidator().validate(executable)
        }
    }

    @Test func productionResolverRejectsWritableLocationBeforeSignatureValidation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wega-user-owned-resolver-\(UUID().uuidString)",
            isDirectory: true
        )
        let sudoDirectory = root.appendingPathComponent("sudo-shim", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: sudoDirectory,
            withIntermediateDirectories: true
        )
        for executable in [
            root.appendingPathComponent("WegaAskpass"),
            sudoDirectory.appendingPathComponent("sudo")
        ] {
            try Data("not signed".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o555)],
                ofItemAtPath: executable.path
            )
        }

        #expect(throws: AuthorizationComponentError.self) {
            try AuthorizationComponentResolver(helpersDirectory: root).resolveAndVerify()
        }
    }

    @Test func rootOwnedNonWritablePathChainIsTrusted() throws {
        let validator = AuthorizationPathTrustValidator(
            metadataAt: { _ in rootOwnedMetadata() },
            volumeIsReadOnly: { _ in false }
        )

        try validator.validate(authorizationExecutable())
    }

    @Test func oneUserOwnedAncestorRejectsTheWholeWritablePathChain() {
        let validator = AuthorizationPathTrustValidator(
            metadataAt: { url in
                if url.path == "/Applications/WegaMacUpdater.app" {
                    return AuthorizationPathMetadata(
                        ownerID: 501,
                        permissions: 0o755,
                        isSymbolicLink: false,
                        isWritableByCurrentUser: true
                    )
                }
                return rootOwnedMetadata()
            },
            volumeIsReadOnly: { _ in false }
        )

        #expect(throws: AuthorizationComponentError.self) {
            try validator.validate(authorizationExecutable())
        }
    }

    @Test func effectiveWriteAccessRejectsRootOwnedPathDespiteSafeModeBits() {
        let validator = AuthorizationPathTrustValidator(
            metadataAt: { url in
                if url.lastPathComponent == "Contents" {
                    return AuthorizationPathMetadata(
                        ownerID: 0,
                        permissions: 0o755,
                        isSymbolicLink: false,
                        isWritableByCurrentUser: true
                    )
                }
                return rootOwnedMetadata()
            },
            volumeIsReadOnly: { _ in false }
        )

        #expect(throws: AuthorizationComponentError.self) {
            try validator.validate(authorizationExecutable())
        }
    }

    @Test func genuinelyReadOnlyVolumeIsTrustedRegardlessOfArchivedOwner() throws {
        let validator = AuthorizationPathTrustValidator(
            metadataAt: { _ in
                AuthorizationPathMetadata(
                    ownerID: 501,
                    permissions: 0o755,
                    isSymbolicLink: false,
                    isWritableByCurrentUser: true
                )
            },
            volumeIsReadOnly: { _ in true }
        )

        try validator.validate(authorizationExecutable())
    }

    @Test func symbolicLinkIsRejectedEvenOnAReadOnlyVolume() {
        let validator = AuthorizationPathTrustValidator(
            metadataAt: { url in
                AuthorizationPathMetadata(
                    ownerID: 0,
                    permissions: 0o755,
                    isSymbolicLink: url.lastPathComponent == "Helpers",
                    isWritableByCurrentUser: false
                )
            },
            volumeIsReadOnly: { _ in true }
        )

        #expect(throws: AuthorizationComponentError.self) {
            try validator.validate(authorizationExecutable())
        }
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func authorizationExecutable() -> URL {
        URL(fileURLWithPath: "/Applications/WegaMacUpdater.app/Contents/Helpers/WegaAskpass")
    }

    private func rootOwnedMetadata() -> AuthorizationPathMetadata {
        AuthorizationPathMetadata(
            ownerID: 0,
            permissions: 0o755,
            isSymbolicLink: false,
            isWritableByCurrentUser: false
        )
    }
}
