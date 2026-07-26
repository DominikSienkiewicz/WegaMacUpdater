import Testing
import Foundation
@testable import MacUpdaterCore

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

    /// SEC-03 characterization — KNOWN GAP, pinned deliberately.
    ///
    /// The gate is a *string* prefix/suffix check with no `..` canonicalization, so
    /// `/Applications/../tmp/evil.app` (which resolves to `/tmp/evil.app`) currently clears
    /// it. This is exactly the case the audit flagged: "a test `/Applications/../tmp/evil.app`
    /// would expose this gap immediately". Asserting the *current* (permissive) behavior keeps
    /// the suite green today while making the gap impossible to miss; SEC-03's hardening will
    /// flip this expectation to `.outsideApplications`, turning this assertion RED until it does.
    @Test func replaceBundleGateStillAdmitsDotDotTraversal_SEC03() {
        #expect(
            WegaHelper.bundleReplacementRejection(
                targetPath: "/Applications/../tmp/evil.app",
                snapshotPath: "/tmp/Foo.app"
            ) == nil
        )
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
