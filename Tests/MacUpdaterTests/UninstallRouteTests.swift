import Foundation
import Testing
import WegaHelperKit

@testable import MacUpdaterCore

@Suite("Uninstall route")
struct UninstallRouteTests {
    private func facts(
        owner: UInt32 = 0, user: UInt32 = 501, writable: Bool = false,
        topLevel: Bool = true, bundleID: Bool = true, admin: Bool = true,
        helper: UninstallHelperAvailability = .enabled
    ) -> UninstallBundleFacts {
        UninstallBundleFacts(
            ownerUID: owner, currentUserUID: user, isWritableByUser: writable,
            isTopLevelInApplications: topLevel, hasBundleIdentifier: bundleID,
            isAdministrator: admin, helper: helper)
    }

    @Test func userOwnedBundleGoesToUserTrash() {
        #expect(UninstallRoute.preflight(facts(owner: 501)) == .userTrash)
    }

    @Test func writableRootOwnedBundleTriesUserTrashFirst() {
        #expect(UninstallRoute.preflight(facts(owner: 0, writable: true)) == .userTrash)
    }

    @Test func rootOwnedNotWritableFallsThroughToDeniedRouting() {
        #expect(UninstallRoute.preflight(facts()) == .helper)
    }

    @Test func userOwnedWritableDeniedNeedsAppManagement() {
        #expect(UninstallRoute.afterPermissionDenied(facts(owner: 501, writable: true)) == .blocked(.needsAppManagement))
    }

    /// The bundle or its folder is not writable, so App Management is not what blocks it.
    @Test func userOwnedNotWritableDeniedNeedsAdministratorRights() {
        #expect(UninstallRoute.afterPermissionDenied(facts(owner: 501, writable: false))
            == .blocked(.needsAdministratorRights))
    }

    @Test func foreignOwnerNeedsAdministratorRights() {
        #expect(UninstallRoute.afterPermissionDenied(facts(owner: 502)) == .blocked(.needsAdministratorRights))
    }

    @Test func nestedBundleNeedsAdministratorRights() {
        #expect(UninstallRoute.afterPermissionDenied(facts(topLevel: false)) == .blocked(.needsAdministratorRights))
    }

    @Test func rootOwnedWithoutBundleIDNeverUsesHelper() {
        #expect(UninstallRoute.afterPermissionDenied(facts(bundleID: false, helper: .enabled))
            == .blocked(.needsAdministratorRights))
    }

    @Test func helperNotSupportedNeedsAdministratorRights() {
        #expect(UninstallRoute.afterPermissionDenied(facts(helper: .notSupported))
            == .blocked(.needsAdministratorRights))
    }

    @Test func nonAdministratorNeedsAdministratorAccount() {
        #expect(UninstallRoute.afterPermissionDenied(facts(admin: false)) == .blocked(.needsAdministratorAccount))
    }

    @Test func helperOffNeedsHelper() {
        #expect(UninstallRoute.afterPermissionDenied(facts(helper: .off)) == .blocked(.needsHelper))
    }

    @Test func enabledHelperIsUsed() {
        #expect(UninstallRoute.afterPermissionDenied(facts()) == .helper)
    }

    @Test func nestedBundleIsNotTopLevel() {
        #expect(!WegaHelper.isTopLevelApplicationBundle(path: "/Applications/X.app/Contents/Library/Y.app"))
    }

    @Test func dotDotEscapeIsNotTopLevel() {
        #expect(!WegaHelper.isTopLevelApplicationBundle(path: "/Applications/../tmp/a.app"))
    }

    @Test func dotDotThatStaysInsideFollowsStandardizedPrecedent() {
        #expect(WegaHelper.isTopLevelApplicationBundle(path: "/Applications/Sub/../Foo.app"))
    }

    @Test func relativePathIsNotTopLevel() {
        #expect(!WegaHelper.isTopLevelApplicationBundle(path: "Applications/Foo.app"))
    }

    @Test func plainAndUtilitiesBundlesAreTopLevel() {
        #expect(WegaHelper.isTopLevelApplicationBundle(path: "/Applications/Foo.app"))
        #expect(WegaHelper.isTopLevelApplicationBundle(path: "/Applications/Utilities/Foo.app"))
    }

    @Test func lookalikeDirectoryIsNotTopLevel() {
        #expect(!WegaHelper.isTopLevelApplicationBundle(path: "/ApplicationsEvil/Foo.app"))
    }

    @Test func posixEPERMIsPermissionDenied() {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(UninstallRoute.isPermissionDenied(error))
    }

    @Test func underlyingEACCESIsPermissionDenied() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
                            userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(UninstallRoute.isPermissionDenied(error))
    }

    @Test func fileWriteNoPermissionIsPermissionDenied() {
        #expect(UninstallRoute.isPermissionDenied(CocoaError(.fileWriteNoPermission)))
    }

    @Test func fileNotFoundIsNot() {
        #expect(!UninstallRoute.isPermissionDenied(CocoaError(.fileNoSuchFile)))
    }
}
