import Foundation
import Testing
@testable import MacUpdaterCore
@testable import WegaHelperKit

/// SEC-04 / QA-01j — **self-update pins the publisher, and a stable release cannot be
/// published unverified.**
///
/// The gap this suite closes: the self-update preferred the `.dmg`, and a `.dmg` was
/// accepted on a Gatekeeper verdict alone. Gatekeeper answers *"notarized by some Apple
/// developer"* — never *"published by Wega"* — so any notarized image from any developer
/// could be presented as a Wega update. The `.pkg` path had the mirror-image problem: its
/// Team ID pin ran only when `pkgutil` happened to answer, so an unreadable signature was
/// silently downgraded to no check at all. And at the end of the chain, the release
/// workflow published unsigned, unnotarized artifacts as a *stable* release — the very
/// thing the client is supposed to trust.
@Suite("SEC-04 self-update publisher pin")
struct SEC04SelfUpdatePublisherPinTests {

    // MARK: - Channel preference: the offered asset is the pinnable one

    @Test func prefersThePkgOverTheDmg() {
        #expect(
            SelfUpdatePlanner.preferredAssetName(from: ["WegaMacUpdater.dmg", "WegaMacUpdater.pkg"])
                == "WegaMacUpdater.pkg"
        )
    }

    @Test func fallsBackToTheDmgOnlyWhenNoPkgIsPublished() {
        #expect(SelfUpdatePlanner.preferredAssetName(from: ["WegaMacUpdater.dmg"]) == "WegaMacUpdater.dmg")
    }

    @Test func refusesToPickAnAssetItCannotVerify() {
        #expect(SelfUpdatePlanner.preferredAssetName(from: ["WegaMacUpdater.zip", "notes.txt"]) == nil)
        #expect(SelfUpdatePlanner.preferredAssetName(from: []) == nil)
    }

    @Test func assetPreferenceIgnoresExtensionCase() {
        #expect(SelfUpdatePlanner.preferredAssetName(from: ["Wega.DMG", "Wega.PKG"]) == "Wega.PKG")
    }

    /// With a `.pkg` on offer and the helper enabled, the whole update is a headless,
    /// fully pinned install — the reason the preference was inverted in the first place.
    @Test func thePreferredAssetIsTheOneTheHelperCanInstallHeadlessly() throws {
        let name = try #require(SelfUpdatePlanner.preferredAssetName(from: ["Wega.dmg", "Wega.pkg"]))
        let url = try #require(URL(string: "https://example.com/\(name)"))
        #expect(SelfUpdatePlanner.action(helperEnabled: true, assetURL: url) == .install)
    }

    // MARK: - The payload is pinned to the version the user was shown

    @Test func availableVersionIsCarriedForVerification() {
        let result = WegaSelfUpdateChecker.Result.updateAvailable(
            version: "0.2.0",
            assetURL: URL(string: "https://example.com/Wega.pkg")!,
            releaseURL: URL(string: "https://example.com/release")!,
            notes: ""
        )
        #expect(result.availableVersion == "0.2.0")
        #expect(WegaSelfUpdateChecker.Result.upToDate.availableVersion == nil)
        #expect(WegaSelfUpdateChecker.Result.failed.availableVersion == nil)
    }

    // MARK: - Disk images: read-only mount + a single, identified payload

    @Test func diskImageIsMountedReadOnlyAndInvisibly() {
        let arguments = CodeSignatureVerifier.attachArguments(
            imagePath: "/tmp/Wega.dmg",
            mountPoint: "/tmp/mount"
        )
        #expect(arguments.contains("-readonly"))
        // Nothing may be shown to, or auto-opened for, the user before it is vetted.
        #expect(arguments.contains("-nobrowse"))
        #expect(arguments.contains("-noautoopen"))
        // An explicit mount point keeps the payload out of /Volumes and off the desktop.
        #expect(arguments.contains("-mountpoint"))
        #expect(arguments.contains("/tmp/mount"))
    }

    @Test func exactlyOneApplicationOnTheImageIsAccepted() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeBundle(named: "WegaMacUpdater.app", in: root, version: "0.2.0")

        let app = try CodeSignatureVerifier.containedApp(inMountedRoot: root)
        #expect(app.lastPathComponent == "WegaMacUpdater.app")
    }

    /// An image carrying no application, or several, is not a Wega release. Refusing beats
    /// guessing which bundle to trust — the guess is exactly what an attacker would aim at.
    @Test func anImageWithoutASingleUnambiguousApplicationIsRejected() throws {
        let empty = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: CodeSignatureVerifier.VerifyError.self) {
            _ = try CodeSignatureVerifier.containedApp(inMountedRoot: empty)
        }

        let crowded = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: crowded) }
        try makeBundle(named: "WegaMacUpdater.app", in: crowded, version: "0.2.0")
        try makeBundle(named: "NotWega.app", in: crowded, version: "0.2.0")
        #expect(throws: CodeSignatureVerifier.VerifyError.self) {
            _ = try CodeSignatureVerifier.containedApp(inMountedRoot: crowded)
        }
    }

    @Test func payloadVersionIsReadableForTheVersionPin() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = try makeBundle(named: "WegaMacUpdater.app", in: root, version: "0.2.0")

        #expect(CodeSignatureVerifier.shortVersion(ofBundleAt: app) == "0.2.0")
        // A bundle without a readable Info.plist yields nil, which the version pin treats
        // as a mismatch rather than as "no expectation".
        #expect(CodeSignatureVerifier.shortVersion(ofBundleAt: root) == nil)
    }

    // MARK: - Fail-closed branches (source inspection: the live paths need real signatures)

    /// `verify` shells out to `spctl`/`pkgutil`/`hdiutil` and needs real Developer ID
    /// artifacts, so its branches cannot be exercised in a unit test. What *can* be pinned
    /// is that the fail-open shapes never come back: a `.pkg` whose Team ID is unknown must
    /// be rejected, and a `.dmg` must not be waved through on a Gatekeeper verdict alone.
    @Test func verifierHasNoFailOpenBranchLeft() throws {
        let source = try contents(of: "Sources/WegaHelperKit/CodeSignatureVerifier.swift")

        // The old .pkg branch: `if let found = pkgTeamID(...), found != expected { throw }`
        // — an unreadable Team ID skipped the pin entirely.
        #expect(!source.contains("if let found = pkgTeamID"))
        #expect(source.contains("guard let found = pkgTeamID(at: url) else {"))
        #expect(source.contains("throw VerifyError.teamIDUnavailable(expected: expectedTeamID)"))

        // The old .dmg branch was a bare Gatekeeper assessment.
        #expect(source.contains("case .dmg:"))
        #expect(source.contains("try verifyDiskImage("))
        // …which now pins the image's own Team ID and the contained bundle's.
        #expect(source.contains("try verifyStaticCode(at: url, expectedTeamID: expectedTeamID)"))
        #expect(source.contains("try verifyStaticCode(at: app, expectedTeamID: expectedTeamID, bundleID: bundleID)"))
    }

    // MARK: - Release gate: unverified artifacts are never a stable release

    @Test func stableReleaseRequiresSigningNotarizationAndTheInstallerCertificate() throws {
        let release = try contents(of: ".github/workflows/release.yml")

        // One switch decides stable vs prerelease, and it needs all three secrets.
        #expect(release.contains("STABLE_RELEASE:"))
        #expect(release.contains("secrets.DEVELOPER_ID_CERT_P12 != ''"))
        #expect(release.contains("secrets.DEVELOPER_ID_INSTALLER_IDENTITY != ''"))
        #expect(release.contains("secrets.AC_API_KEY_P8 != ''"))
    }

    @Test func anUnverifiableBuildIsPublishedAsAPrereleaseTheSelfUpdateIgnores() throws {
        let release = try contents(of: ".github/workflows/release.yml")

        // Publishing is downgraded rather than blocked, so the pipeline stays runnable
        // without an Apple Developer account…
        #expect(release.contains("--prerelease"))
        #expect(release.contains("RELEASE_FLAGS+=(--prerelease)"))
        #expect(release.contains("if [[ \"$STABLE_RELEASE\" != \"true\" ]]; then"))

        // …and the client already refuses prereleases, which is what makes the downgrade a
        // real security boundary rather than a label.
        let checker = try contents(of: "Sources/MacUpdaterCore/WegaSelfUpdateChecker.swift")
        #expect(checker.contains("guard !release.draft, !release.prerelease else { return .upToDate }"))
    }

    @Test func theArtifactGateRunsFailClosedForAStableRelease() throws {
        let release = try contents(of: ".github/workflows/release.yml")
        let gate = try contents(of: "scripts/verify-bundle.sh")

        // The workflow arms the gate's fail-closed mode from the same switch.
        #expect(release.contains("REQUIRE_SIGNED: ${{ env.STABLE_RELEASE }}"))

        // The gate implements it: skips become failures, and the publisher pin is checked
        // against the same constant the app pins its self-update against.
        #expect(gate.contains("REQUIRE_SIGNED"))
        #expect(gate.contains("EXPECTED_TEAM_ID"))
        #expect(gate.contains("Sources/WegaHelperKit/WegaHelperProtocol.swift"))
        #expect(gate.contains("teamIdentifier"))
        #expect(gate.contains("TeamIdentifier="))
        #expect(gate.contains("pkgutil --check-signature"))
    }

    // MARK: - Helpers

    @discardableResult
    private func makeBundle(named name: String, in root: URL, version: String) throws -> URL {
        let bundle = root.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.wega.WegaMacUpdater",
            "CFBundleShortVersionString": version
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sec04-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func contents(of relativePath: String) throws -> String {
        try String(contentsOf: packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
