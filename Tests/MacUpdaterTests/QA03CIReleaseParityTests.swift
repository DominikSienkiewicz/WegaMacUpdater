import Foundation
import Testing

/// QA-03 — CI/release rozjechane: `macos-15` vs `macos-26`, brak lint w release, zero wydań.
///
/// `swift build`/`swift test`/`swiftlint` only see Swift code, so a release workflow that drifts
/// from CI — a different runner, an unpinned toolchain, missing quality gates — is invisible to the
/// whole gate. These regressions pin the release pipeline to CI: one shared reusable workflow, one
/// unified pinned toolchain, and a release that cannot outrun the quality and artifact gates.
@Suite("QA-03 CI/release parity")
struct QA03CIReleaseParityTests {
    // MARK: - Shared reusable workflow

    @Test func ciAndReleaseShareOneReusableBuildWorkflow() throws {
        let reusable = try contents(of: ".github/workflows/build.yml")
        let ci = try contents(of: ".github/workflows/ci.yml")
        let release = try contents(of: ".github/workflows/release.yml")

        // The reusable workflow is callable…
        #expect(reusable.contains("workflow_call"))
        // …and both CI and release invoke that single source of truth.
        #expect(ci.contains("uses: ./.github/workflows/build.yml"))
        #expect(release.contains("uses: ./.github/workflows/build.yml"))
    }

    // MARK: - Unified runner (no more macos-15 in release)

    @Test func releaseNoLongerBuildsOnMacos15() throws {
        let reusable = try contents(of: ".github/workflows/build.yml")
        let release = try contents(of: ".github/workflows/release.yml")

        // The project and CI declare macOS 26; release must not build on a different runner.
        #expect(!release.contains("macos-15"))
        #expect(reusable.contains("runs-on: macos-26"))
        #expect(release.contains("runs-on: macos-26"))
    }

    // MARK: - Pinned toolchain (Xcode + SwiftLint), despite `--strict`

    @Test func toolchainIsPinnedNotFloating() throws {
        let reusable = try contents(of: ".github/workflows/build.yml")
        let release = try contents(of: ".github/workflows/release.yml")

        // `xcode-version: latest-stable` lets a new Xcode reach the build silently; pin it to a
        // concrete version (docs: Xcode 26). Match the actual usage, not a comment that may
        // mention the anti-pattern it replaced.
        #expect(!reusable.contains("xcode-version: latest-stable"))
        #expect(!release.contains("xcode-version: latest-stable"))
        #expect(reusable.contains("xcode-version: '26"))
        #expect(release.contains("xcode-version: '26"))

        // A floating SwiftLint under `--strict` fails the day it ships a new rule. Pin the version
        // (.swiftlint.yml already references 0.65.0) and install it from a fixed release asset
        // instead of whatever `brew install swiftlint` has today.
        #expect(reusable.contains("0.65.0"))
        #expect(reusable.contains("releases/download/"))
    }

    // MARK: - Release cannot outrun the quality gates

    @Test func releasePublishDependsOnTheQualityGate() throws {
        let release = try contents(of: ".github/workflows/release.yml")

        // The publishing job must `needs:` the reusable build job, so lint/tests/catalog/bundle
        // verification all pass before any Release is cut.
        #expect(release.contains("needs: build"))
    }

    @Test func releasePathRunsLintAndCatalogVerificationNotOnlySwiftTest() throws {
        let reusable = try contents(of: ".github/workflows/build.yml")

        // Both live in the reusable workflow, so the release path inherits them instead of running
        // a bare `swift test` the way the old release.yml did.
        #expect(reusable.contains("swiftlint"))
        #expect(reusable.contains("verify-catalog.sh"))
        #expect(reusable.contains("swift test"))
    }

    // MARK: - Release gate verifies the artifact, not just the tests

    @Test func releaseGateVerifiesBundleLayoutSignatureNotarizationAndResources() throws {
        let script = try contents(of: "scripts/verify-bundle.sh")
        let reusable = try contents(of: ".github/workflows/build.yml")
        let release = try contents(of: ".github/workflows/release.yml")

        // The gate is wired into both the shared build and the release job.
        #expect(reusable.contains("verify-bundle.sh"))
        #expect(release.contains("verify-bundle.sh"))

        // Bundle layout + required resources (a missing endpoints.json crashes the shipped app).
        #expect(script.contains("Info.plist"))
        #expect(script.contains("app-catalog.json"))
        #expect(script.contains("endpoints.json"))
        // Helper signature.
        #expect(script.contains("WegaPrivilegedHelper"))
        #expect(script.contains("codesign"))
        // Notarization + stapling (enforced once a Developer ID is configured).
        #expect(script.contains("stapler"))
        #expect(script.contains("spctl"))
    }

    // MARK: - Helpers

    private func contents(of relativePath: String) throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
