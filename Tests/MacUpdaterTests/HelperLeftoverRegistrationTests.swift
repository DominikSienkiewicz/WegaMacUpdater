import Testing
import WegaHelperKit
@testable import MacUpdaterCore

/// Z14, review RC2: a helper registered from a dragged copy before this change stays exposed to the
/// swapped-binary attack until it is removed, and Wega no longer uses it. It is removed at launch
/// when this copy is refused and no copy LaunchServices knows passes the gate; when one does, the
/// registration may be that copy's, and it stays.
@Suite("Leftover helper registration")
struct HelperLeftoverRegistrationTests {
    private static let refused = HelperBundleTrust.refused(.notOwnedByRoot(.bundle))

    @Test(arguments: [PrivilegedHelperClient.Status.enabled, .requiresApproval])
    func aRegistrationFromARefusedCopyWithNoTrustedCopyIsRemoved(status: PrivilegedHelperClient.Status) {
        #expect(HelperLeftoverRegistration.shouldUnregister(status: status, ownTrust: Self.refused, copies: []))
        #expect(HelperLeftoverRegistration.shouldUnregister(
            status: status, ownTrust: Self.refused, copies: [Self.refused, .refused(.notInApplications)]
        ))
    }

    @Test func aTrustedCopyKeepsTheRegistration() {
        #expect(!HelperLeftoverRegistration.shouldUnregister(
            status: .enabled, ownTrust: Self.refused, copies: [Self.refused, .trusted]
        ))
    }

    /// Final security review, finding 1: an entry that could not be read may be a bundle a pkg
    /// install is replacing, so it decides nothing — for this copy or for any listed copy. A dragged
    /// copy refuses as not owned by root and a Downloads copy as not in /Applications, so this loses
    /// nothing.
    @Test(arguments: HelperBundleEntry.allCases)
    func anUnreadableEntryCannotDecide(entry: HelperBundleEntry) {
        #expect(!HelperLeftoverRegistration.shouldUnregister(status: .enabled, ownTrust: .refused(.unreadable(entry)), copies: []))
        #expect(!HelperLeftoverRegistration.shouldUnregister(
            status: .enabled, ownTrust: Self.refused, copies: [Self.refused, .refused(.unreadable(entry))]
        ))
    }

    @Test func aTrustedRunningCopyNeverRemovesIt() {
        #expect(!HelperLeftoverRegistration.shouldUnregister(status: .enabled, ownTrust: .trusted, copies: []))
    }

    @Test(arguments: [PrivilegedHelperClient.Status.notRegistered, .notFound, .unknown])
    func withoutARegistrationThereIsNothingToRemove(status: PrivilegedHelperClient.Status) {
        #expect(!HelperLeftoverRegistration.shouldUnregister(status: status, ownTrust: Self.refused, copies: []))
    }
}
