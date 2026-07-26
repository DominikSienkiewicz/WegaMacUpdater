import Testing
import Foundation
@testable import MacUpdaterCore
// SEC-10: contract + validation moved to WegaHelperKit; these tests reach its
// internal seams (CodeSignatureVerifier.artifact, …).
@testable import WegaHelperKit

/// Pure-logic guards for the P0 security work (SEC-03 + FEAT-01). These do not
/// require the Security/ServiceManagement frameworks at runtime — they pin the
/// *shape* of the code requirements and the idempotency of the PAM writer, which
/// are the parts most dangerous to get subtly wrong.
@Suite("PrivilegedHelperSecurity")
struct PrivilegedHelperSecurityTests {

    // MARK: - SEC-03: code requirement string

    @Test func teamIDRequirementPinsAppleChainAndTeam() {
        let req = CodeSignatureVerifier.teamIDRequirement(teamID: "AB12CD34EF", bundleID: "com.wega.WegaMacUpdater")
        #expect(req.contains("anchor apple generic"))
        #expect(req.contains("identifier \"com.wega.WegaMacUpdater\""))
        #expect(req.contains("certificate leaf[subject.OU] = \"AB12CD34EF\""))
    }

    @Test func teamIDRequirementOmitsIdentifierWhenNil() {
        let req = CodeSignatureVerifier.teamIDRequirement(teamID: "AB12CD34EF")
        #expect(!req.contains("identifier"))
        #expect(req.contains("AB12CD34EF"))
    }

    @Test func artifactClassificationIsCaseInsensitive() {
        #expect(CodeSignatureVerifier.artifact(for: URL(fileURLWithPath: "/x/Foo.app")) == .app)
        #expect(CodeSignatureVerifier.artifact(for: URL(fileURLWithPath: "/x/Foo.PKG")) == .pkg)
        #expect(CodeSignatureVerifier.artifact(for: URL(fileURLWithPath: "/x/Foo.dmg")) == .dmg)
        #expect(CodeSignatureVerifier.artifact(for: URL(fileURLWithPath: "/x/Foo.zip")) == .other("zip"))
    }

    // MARK: - SEC-03 / QA-01: replaceBundle path gate

    /// A well-formed target under `/Applications` with a `.app` snapshot clears the gate,
    /// so the daemon proceeds to its filesystem + Gatekeeper checks. Extracting this decision
    /// out of the root-only `HelperDelegate.replaceBundle` is what lets a unit test reach it
    /// at all — before QA-01 no test target depended on `WegaPrivilegedHelper`.
    @Test func replaceBundleGateAdmitsBundlesUnderApplications() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Foo.app",
                snapshotPath: "/private/tmp/wega/Foo.app"
            ) == nil
        )
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Nested/Foo.app",
                snapshotPath: "/tmp/Foo.app"
            ) == nil
        )
    }

    @Test func replaceBundleGateRejectsNonBundlePaths() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Foo",
                snapshotPath: "/tmp/Foo.app"
            ) == .notBundle
        )
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Foo.app",
                snapshotPath: "/tmp/Foo"
            ) == .notBundle
        )
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Foo.pkg",
                snapshotPath: "/tmp/Foo.app"
            ) == .notBundle
        )
    }

    @Test func replaceBundleGateRejectsTargetsOutsideApplications() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Users/me/Applications/Foo.app",
                snapshotPath: "/tmp/Foo.app"
            ) == .outsideApplications
        )
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/tmp/evil.app",
                snapshotPath: "/tmp/Foo.app"
            ) == .outsideApplications
        )
    }

    /// SEC-03 — the traversal the audit named. `/Applications/../tmp/evil.app` resolves to
    /// `/tmp/evil.app`, so it must not clear the gate. This assertion was deliberately pinned
    /// the other way round while the gap existed; the hardening flips it, exactly as the
    /// characterization comment promised it would.
    @Test func replaceBundleGateRejectsDotDotTraversal_SEC03() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/../tmp/evil.app",
                snapshotPath: "/tmp/Foo.app"
            ) == .outsideApplications
        )
    }

    /// A `..` that stays inside `/Applications` is legitimate — canonicalisation must not
    /// turn the gate into a blanket ban on the character sequence.
    @Test func replaceBundleGateAdmitsDotDotResolvingBackIntoApplications() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/Utilities/../Foo.app",
                snapshotPath: "/tmp/Foo.app"
            ) == nil
        )
    }

    /// `/Applications` reached through a relative path is not a path the helper accepts:
    /// the daemon's cwd is not part of the trust boundary.
    @Test func replaceBundleGateRejectsRelativeTargets() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "Applications/Foo.app",
                snapshotPath: "/tmp/Foo.app"
            ) == .outsideApplications
        )
    }

    /// A target whose first two components are not `/` + `Applications` is rejected even when
    /// the string starts with the right characters — `/ApplicationsEvil/Foo.app` must not pass
    /// a prefix test.
    @Test func replaceBundleGateComparesPathComponentsNotPrefixes() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/ApplicationsEvil/Foo.app",
                snapshotPath: "/tmp/Foo.app"
            ) == .outsideApplications
        )
    }

    // MARK: - SEC-03: filesystem facts (symlinks + snapshot↔target identity)

    private func facts(
        resolved: String = "/Applications/Foo.app",
        isSymlink: Bool = false,
        targetBundleID: String? = "com.acme.foo",
        targetTeamID: String? = "TEAM123456",
        snapshotBundleID: String? = "com.acme.foo",
        snapshotTeamID: String? = "TEAM123456"
    ) -> WegaHelper.BundleReplacementFacts {
        .init(
            targetResolvedPath: resolved,
            targetIsSymlink: isSymlink,
            targetBundleID: targetBundleID,
            targetTeamID: targetTeamID,
            snapshotBundleID: snapshotBundleID,
            snapshotTeamID: snapshotTeamID
        )
    }

    @Test func matchingIdentityOnARealDirectoryIsAccepted() {
        #expect(WegaHelper.bundleReplacementRejection(facts: facts()) == nil)
    }

    @Test func aSymlinkedTargetIsRejected() {
        #expect(WegaHelper.bundleReplacementRejection(facts: facts(isSymlink: true)) == .symlinkedTarget)
    }

    /// The target itself is an ordinary directory, but a symlinked parent redirects the write
    /// outside `/Applications`. Resolving only the final component would miss this.
    @Test func aTargetReachedThroughASymlinkedParentIsRejected() {
        #expect(
            WegaHelper.bundleReplacementRejection(facts: facts(resolved: "/tmp/evil/Foo.app"))
                == .symlinkedTarget
        )
    }

    @Test func aSnapshotOfADifferentApplicationIsRejected() {
        #expect(
            WegaHelper.bundleReplacementRejection(facts: facts(snapshotBundleID: "com.evil.other"))
                == .identityMismatch
        )
    }

    /// Same bundle identifier, different publisher — the takeover case SEC-02 tracks, refused
    /// here as well so a re-signed impostor cannot ride in as a "restore".
    @Test func aSnapshotSignedByADifferentTeamIsRejected() {
        #expect(
            WegaHelper.bundleReplacementRejection(facts: facts(snapshotTeamID: "OTHER99999"))
                == .identityMismatch
        )
    }

    /// Unsigned or unreadable input fails closed: a missing Team ID is exactly what an
    /// attacker-supplied bundle looks like.
    @Test func missingIdentityFailsClosed() {
        #expect(WegaHelper.bundleReplacementRejection(facts: facts(targetTeamID: nil)) == .identityMismatch)
        #expect(WegaHelper.bundleReplacementRejection(facts: facts(snapshotBundleID: nil)) == .identityMismatch)
    }

    // MARK: - FEAT-01: XPC peer requirements

    @Test func helperRequirementsPinTeamAndIdentifiers() {
        #expect(WegaHelper.clientRequirement().contains(WegaHelper.appBundleID))
        #expect(WegaHelper.clientRequirement().contains("anchor apple generic"))
        #expect(WegaHelper.helperRequirement().contains(WegaHelper.helperSigningID))
        #expect(WegaHelper.helperRequirement().contains("anchor apple generic"))
        // Both directions pin the same configured Team ID token.
        #expect(WegaHelper.clientRequirement().contains(WegaHelper.teamIdentifier))
        #expect(WegaHelper.helperRequirement().contains(WegaHelper.teamIdentifier))
    }

    @Test func teamIDConfiguredFlagReflectsPlaceholder() {
        // Default ships with the placeholder → fail-closed paths must see "not configured".
        #expect(WegaHelper.isTeamIDConfigured == (WegaHelper.teamIdentifier != "REPLACE_TEAMID"))
    }

    @Test func teamIDIsARealAppleTeamID() {
        // A regression back to the placeholder would silently kill XPC pinning and
        // self-update verification (fail-closed) — pin the configured state and the
        // Apple Team ID shape (exactly 10 alphanumerics) so CI catches it.
        #expect(WegaHelper.isTeamIDConfigured)
        #expect(WegaHelper.teamIdentifier.count == 10)
        #expect(WegaHelper.teamIdentifier.allSatisfy { $0.isLetter || $0.isNumber })
    }

    // MARK: - FEAT-01: root-side PAM writer (pure content)

    @Test func pamContentsAppendOnceAndAreIdempotent() {
        let fromEmpty = TouchIDSudoConfigurator.contentsEnablingTouchID(current: nil)
        #expect(fromEmpty.contains("pam_tid.so"))
        // Re-applying must not duplicate the directive.
        let again = TouchIDSudoConfigurator.contentsEnablingTouchID(current: fromEmpty)
        #expect(again == fromEmpty)
        let occurrences = again.components(separatedBy: "pam_tid.so").count - 1
        #expect(occurrences == 1)
    }

    @Test func pamContentsPreserveExistingLines() {
        let existing = "auth       sufficient     pam_smartcard.so\n"
        let result = TouchIDSudoConfigurator.contentsEnablingTouchID(current: existing)
        #expect(result.contains("pam_smartcard.so")) // never clobber other lines
        #expect(result.contains("pam_tid.so"))
    }
}
