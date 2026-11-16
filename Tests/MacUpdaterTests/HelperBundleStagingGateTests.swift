import Foundation
import Testing
import WegaHelperKit

/// The pure gates in front of the helper verb that moves a root-owned application out of
/// `/Applications` into a staging slot owned by the calling administrator, so the app can then
/// put it in the Trash as that user.
///
/// The daemon runs only as root and no test target reaches it, so every decision it makes before
/// the move is pinned here: who is asking, which path, what the filesystem says about it, whether
/// the entry changed in between, and whether the staging root is still root's alone. Each
/// rejection is paired with a positive control, so the gates refuse the unsafe input rather
/// than every input.
@Suite("Helper bundle staging gates")
struct HelperBundleStagingGateTests {

    // MARK: - Lexical gate

    @Test func acceptsATopLevelApplicationAndOneInAPlainFolder() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Foo.app") == nil)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Utilities/Foo.app") == nil)
    }

    @Test func rejectsAPathOutsideApplications() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/tmp/Foo.app") == .notTopLevelApplication)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Library/Foo.app") == .notTopLevelApplication)
    }

    @Test func rejectsADotDotThatEscapesApplications() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/../tmp/evil.app")
            == .notTopLevelApplication)
    }

    /// Stricter than `isTopLevelApplicationBundle`, which accepts this path because it
    /// standardizes back to `/Applications/Foo.app`: the helper takes no `..` at all.
    @Test func rejectsADotDotEvenWhenItStandardizesBackInsideApplications() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Sub/../Foo.app")
            == .notTopLevelApplication)
    }

    @Test func rejectsADotComponent() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/./Foo.app")
            == .notTopLevelApplication)
    }

    /// A combining mark right after a `/` joins it into one Swift `Character`, so a split on
    /// `Character("/")` would not see the `..` that the kernel does. The gate reads bytes.
    @Test func rejectsADotDotHiddenBehindACombiningMark() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Sub/../\u{301}Foo.app")
            == .notTopLevelApplication)
    }

    @Test func rejectsABundleNestedInABundle() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/X.app/Y.app")
            == .notTopLevelApplication)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/X.app/Contents/Library/Y.app")
            == .notTopLevelApplication)
    }

    @Test func rejectsAnApplicationTwoFoldersDeep() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/A/B/C.app")
            == .notTopLevelApplication)
    }

    /// Decided: refused. With a trailing slash `lstat` follows a symlink in the last component,
    /// so the "is it a symlink" fact would describe the link's target instead of the entry.
    @Test func rejectsATrailingSlash() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Foo.app/")
            == .notTopLevelApplication)
    }

    @Test func rejectsAnEmptyComponent() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications//Foo.app")
            == .notTopLevelApplication)
    }

    @Test func rejectsALookalikeDirectory() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/ApplicationsEvil/Foo.app")
            == .notTopLevelApplication)
    }

    @Test func rejectsARelativePath() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "Applications/Foo.app") == .notTopLevelApplication)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "Foo.app") == .notTopLevelApplication)
    }

    @Test func rejectsSomethingThatIsNotAnApplication() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications") == .notTopLevelApplication)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Utilities") == .notTopLevelApplication)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Foo.pkg") == .notTopLevelApplication)
        #expect(WegaHelper.bundleStagingRejection(targetPath: "") == .notTopLevelApplication)
    }

    /// The C path the daemon hands to `lstat` and `rename` ends at the NUL; the string the gate
    /// approved does not. The two must never name different entries.
    @Test func rejectsAnEmbeddedNul() {
        #expect(WegaHelper.bundleStagingRejection(targetPath: "/Applications/Foo.app\u{0}.app")
            == .notTopLevelApplication)
    }

    // MARK: - Facts gate: accepted

    @Test func acceptsRootOwnedTopLevelAppForAdminConsoleCaller() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts()) == nil)
        #expect(WegaHelper.bundleStagingRejection(facts: facts(
            path: "/Applications/Utilities/Foo.app", resolved: "/Applications/Utilities/Foo.app")) == nil)
    }

    // MARK: - Facts gate: caller

    @Test func rejectsWhenNobodyIsLoggedIn() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(consoleUserUID: nil)) == .noConsoleUser)
    }

    /// Fast user switching: the request comes from a session that is not at the console.
    @Test func rejectsCallerWhoIsNotTheConsoleUser() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(callerUID: 502, consoleUserUID: 501))
            == .callerNotConsoleUser)
    }

    @Test func rejectsCallerWhoIsNotAnAdministrator() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(callerIsAdministrator: false))
            == .callerNotAdministrator)
    }

    // MARK: - Facts gate: location

    @Test func rejectsASymlinkedTarget() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(isSymlink: true)) == .symlinkedTarget)
    }

    /// The target itself is an ordinary directory, but a parent is a link: `realpath` differs
    /// from the path the lexical gate approved, even while it stays inside `/Applications`.
    @Test func rejectsATargetReachedThroughASymlinkedParent() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(
            path: "/Applications/Utilities/Foo.app", resolved: "/Applications/Other/Foo.app"))
            == .symlinkedTarget)
        #expect(WegaHelper.bundleStagingRejection(facts: facts(resolved: "/private/tmp/evil/Foo.app"))
            == .symlinkedTarget)
    }

    /// Safari in `/Applications` is a root-owned link into the system cryptex.
    @Test func rejectsAnApplicationThatResolvesIntoTheSystemVolume() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(
            path: "/Applications/Safari.app",
            resolved: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
            isSymlink: true)) == .systemLocation)
        #expect(WegaHelper.bundleStagingRejection(facts: facts(resolved: "/System/Applications/Foo.app"))
            == .systemLocation)
    }

    /// The facts gate does not lean on the lexical gate having run: a resolved path outside
    /// `/Applications` is refused even when it equals the path that was asked for.
    @Test func factsGateRefusesAPathTheLexicalGateWouldRefuse() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(path: "/Library/Foo.app", resolved: "/Library/Foo.app"))
            == .notTopLevelApplication)
    }

    // MARK: - Facts gate: ownership

    /// A user-owned bundle never needs root: when the user cannot trash it, App Management is
    /// what blocks it, and the helper must not override a permission the user left off.
    @Test func rejectsUserOwnedBundle() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(ownerUID: 501)) == .notOwnedByRoot)
        #expect(WegaHelper.bundleStagingRejection(facts: facts(ownerUID: 502)) == .notOwnedByRoot)
    }

    // MARK: - Facts gate: identity

    @Test func rejectsMissingBundleID() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(bundleID: nil)) == .identityMismatch)
    }

    @Test func rejectsADifferentApplicationThanTheOneTheUserSaw() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(bundleID: "com.acme.other")) == .identityMismatch)
    }

    @Test func rejectsAnEmptyBundleIDEvenWhenItIsWhatWasAskedFor() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(bundleID: "", expectedBundleID: ""))
            == .identityMismatch)
    }

    /// Wega's own bundle carries the helper; removing it is never this verb's job. Bundle
    /// identifiers are case-insensitive to Launch Services, so the exclusion is too.
    @Test func rejectsWegaItself() {
        let wega = WegaHelper.appBundleID
        #expect(WegaHelper.bundleStagingRejection(facts: facts(bundleID: wega, expectedBundleID: wega))
            == .wegaItself)
        let shouted = wega.uppercased()
        #expect(WegaHelper.bundleStagingRejection(facts: facts(bundleID: shouted, expectedBundleID: shouted))
            == .wegaItself)
    }

    // MARK: - Facts gate: order of checks

    /// A caller who is not allowed to ask learns nothing about the target.
    @Test func aNonAdministratorLearnsNothingAboutTheTarget() {
        let everythingWrong = facts(
            resolved: "/private/tmp/Foo.app", isSymlink: true, ownerUID: 501, bundleID: nil,
            callerIsAdministrator: false)
        #expect(WegaHelper.bundleStagingRejection(facts: everythingWrong) == .callerNotAdministrator)
    }

    @Test func noConsoleUserIsCheckedFirst() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(
            isSymlink: true, consoleUserUID: nil, callerIsAdministrator: false)) == .noConsoleUser)
    }

    @Test func theConsoleUserIsCheckedBeforeAdministratorMembership() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(
            callerUID: 502, consoleUserUID: 501, callerIsAdministrator: false)) == .callerNotConsoleUser)
    }

    @Test func locationIsCheckedBeforeOwnership() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(isSymlink: true, ownerUID: 501)) == .symlinkedTarget)
    }

    @Test func ownershipIsCheckedBeforeIdentity() {
        #expect(WegaHelper.bundleStagingRejection(facts: facts(ownerUID: 501, bundleID: "com.acme.other"))
            == .notOwnedByRoot)
    }

    // MARK: - Identity re-check

    @Test func rejectsATargetSwappedBeforeTheMove() {
        let validated = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        #expect(WegaHelper.bundleStagingRejection(
            validated: validated, current: .init(device: 16_777_233, inode: 7_777)) == .targetSwapped)
        #expect(WegaHelper.bundleStagingRejection(
            validated: validated, current: .init(device: 16_777_234, inode: 4_242)) == .targetSwapped)
    }

    @Test func acceptsAnUnchangedTarget() {
        let identity = PackageStaging.ArtifactIdentity(device: 16_777_233, inode: 4_242)
        #expect(WegaHelper.bundleStagingRejection(validated: identity, current: identity) == nil)
    }

    // MARK: - Staging root

    @Test func stagingRootSitsInWegasSystemApplicationSupport() {
        #expect(UninstallStaging.root.path == "/Library/Application Support/com.wega.WegaMacUpdater/UninstallStaging")
    }

    /// `0711`: only root lists or writes it, and each caller can still reach the slot it owns.
    @Test func rootModeMustBeExactly0711() {
        #expect(UninstallStaging.rootRejection(ownerUID: 0, permissions: 0o711) == nil)
        #expect(UninstallStaging.rootRejection(ownerUID: 0, permissions: 0o755) == .stagingRootUnsafe)
        #expect(UninstallStaging.rootRejection(ownerUID: 0, permissions: 0o700) == .stagingRootUnsafe)
        #expect(UninstallStaging.rootRejection(ownerUID: 0, permissions: 0o733) == .stagingRootUnsafe)
        #expect(UninstallStaging.rootRejection(ownerUID: 0, permissions: 0o1711) == .stagingRootUnsafe)
        #expect(UninstallStaging.rootRejection(ownerUID: 0, permissions: 0o4711) == .stagingRootUnsafe)
    }

    @Test func stagingRootMustBeOwnedByRoot() {
        #expect(UninstallStaging.rootRejection(ownerUID: 501, permissions: 0o711) == .stagingRootUnsafe)
    }

    // MARK: - Fixture

    /// Facts that clear every check, so each test changes exactly the dimension it is about.
    private func facts(
        path: String = "/Applications/Foo.app",
        resolved: String? = nil,
        isSymlink: Bool = false,
        ownerUID: UInt32 = 0,
        bundleID: String? = "com.acme.foo",
        expectedBundleID: String = "com.acme.foo",
        callerUID: UInt32 = 501,
        consoleUserUID: UInt32? = 501,
        callerIsAdministrator: Bool = true
    ) -> BundleStagingFacts {
        BundleStagingFacts(
            targetPath: path,
            targetResolvedPath: resolved ?? path,
            targetIsSymlink: isSymlink,
            targetOwnerUID: ownerUID,
            targetBundleID: bundleID,
            expectedBundleID: expectedBundleID,
            callerUID: callerUID,
            consoleUserUID: consoleUserUID,
            callerIsAdministrator: callerIsAdministrator
        )
    }
}
