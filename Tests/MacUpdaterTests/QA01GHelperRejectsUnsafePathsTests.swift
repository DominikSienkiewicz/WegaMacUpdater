import Foundation
import Testing

@testable import WegaHelperKit

/// QA-01g — regression guard for the guarantee `SEC-03` restored: the privileged
/// helper **rejects** the three inputs the audit named — a `..` traversal, a
/// symlink (or symlinked parent), and an artifact swapped out from under it
/// between validation and the write.
///
/// The daemon (`WegaPrivilegedHelper`) runs only as root and is unreachable from
/// any test target — which is exactly how the `..` traversal in `replaceBundle`
/// survived until an audit found it by reading code. `SEC-03` lifted each of
/// these decisions out of the root-only daemon into pure functions on
/// `WegaHelper` / `PackageStaging`, so the very decision the helper makes as root
/// is pinned here as a scenario-level regression guard.
///
/// The `SEC-03` marker points straight at the case this suite exists to keep
/// closed: "test `\"/Applications/../tmp/evil.app\"` obnażyłby tę lukę
/// natychmiast". Each rejection is paired with a positive control so the guard
/// proves the helper refuses the *unsafe* input, not every input.
///
/// Related: `SEC-03`, `QA-01`.
@Suite("QA-01g: helper rejects `..`, symlink and a swapped artifact")
struct QA01GHelperRejectsUnsafePathsTests {

    // MARK: - `..` — the traversal the audit named

    /// `/Applications/../tmp/evil.app` resolves to `/tmp/evil.app`; the exact string
    /// the `SEC-03` marker calls out must never clear the `replaceBundle` gate.
    @Test func helperRejectsDotDotTraversalOnReplaceBundleTarget() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/../tmp/evil.app",
                snapshotPath: "/private/tmp/Foo.app"
            ) == .outsideApplications
        )
    }

    /// The same traversal class on the install path — `installer` is only ever handed a
    /// path inside the bundle's root-owned staging, never one that `..`-escapes it.
    @Test func helperRejectsDotDotTraversalOnInstallPath() {
        #expect(
            PackageStaging.rejectionForInstallPath(
                "/Library/Application Support/com.wega.WegaMacUpdater/staging/../../../tmp/evil.pkg",
                bundleID: "com.wega.WegaMacUpdater"
            ) == .outsideStaging
        )
    }

    /// The gate refuses the traversal because it *resolves outside* `/Applications`,
    /// not because the string contains `..`: a `..` that resolves back inside the
    /// install root is legitimate and must still be accepted.
    @Test func helperAcceptsDotDotThatResolvesBackIntoApplications() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Utilities/../Foo.app",
                snapshotPath: "/private/tmp/Foo.app"
            ) == nil
        )
    }

    // MARK: - symlink — the resolved path, not the approved one

    /// A target that is itself a symbolic link is refused: the path the lexical gate
    /// approved is not the path `replaceItemAt` would land on.
    @Test func helperRejectsASymlinkedTarget() {
        #expect(
            WegaHelper.bundleReplacementRejection(facts: unsafeFacts(isSymlink: true))
                == .symlinkedTarget
        )
    }

    /// A symlinked *parent* leaves the target an ordinary directory while still
    /// redirecting the write outside `/Applications`. Resolving the whole path — not
    /// just the final component — is what catches it.
    @Test func helperRejectsATargetReachedThroughASymlinkedParent() {
        #expect(
            WegaHelper.bundleReplacementRejection(facts: unsafeFacts(resolved: "/private/tmp/evil/Foo.app"))
                == .symlinkedTarget
        )
    }

    /// Positive control: a real, non-symlinked target of the same application clears the
    /// filesystem gate, so the guard refuses the symlink, not every target.
    @Test func helperAcceptsARealNonSymlinkedTargetOfTheSameApp() {
        #expect(WegaHelper.bundleReplacementRejection(facts: unsafeFacts()) == nil)
    }

    // MARK: - swapped artifact — the entry validated must be the entry written

    /// `replaceBundle`: the entry validated and the entry overwritten must be the same
    /// file on disk. A device/inode pair that changed in between is a swap, and refused.
    @Test func helperRejectsATargetSwappedBetweenValidationAndWrite() {
        let validated = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        let swapped = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 7_777)
        #expect(
            WegaHelper.bundleReplacementRejection(validated: validated, replacing: swapped)
                == .targetSwapped
        )
    }

    /// `installVerifiedPackage`: the artifact whose signature was verified and the
    /// artifact `installer` runs must be the same file — a swap after verification
    /// changes the inode even when the path is unchanged.
    @Test func helperRejectsAPackageSwappedAfterVerification() {
        let verified = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        let swapped = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 9_999)
        #expect(
            PackageStaging.rejection(verified: verified, installing: swapped)
                == .identityChanged
        )
    }

    /// Positive control: an unchanged artifact is accepted on both paths, so the swap
    /// checks refuse a substitution rather than refusing everything.
    @Test func helperAcceptsAnUnchangedArtifact() {
        let identity = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        #expect(WegaHelper.bundleReplacementRejection(validated: identity, replacing: identity) == nil)
        #expect(PackageStaging.rejection(verified: identity, installing: identity) == nil)
    }

    // MARK: - Fixture

    /// A `BundleReplacementFacts` value that clears every filesystem check by default,
    /// so each test perturbs exactly one dimension (symlink / resolved path) and the
    /// rejection it asserts is unambiguously caused by that one change.
    private func unsafeFacts(
        resolved: String = "/Applications/Foo.app",
        isSymlink: Bool = false,
        targetBundleID: String? = "com.acme.foo",
        targetTeamID: String? = "TEAM123456",
        snapshotBundleID: String? = "com.acme.foo",
        snapshotTeamID: String? = "TEAM123456",
        targetOwnerUID: UInt32 = 501,
        consoleUserUID: UInt32? = 501
    ) -> WegaHelper.BundleReplacementFacts {
        .init(
            targetResolvedPath: resolved,
            targetIsSymlink: isSymlink,
            targetBundleID: targetBundleID,
            targetTeamID: targetTeamID,
            snapshotBundleID: snapshotBundleID,
            snapshotTeamID: snapshotTeamID,
            targetOwnerUID: targetOwnerUID,
            consoleUserUID: consoleUserUID
        )
    }
}
