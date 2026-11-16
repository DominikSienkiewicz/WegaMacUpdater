import Testing

@testable import WegaHelperKit

@Suite("Administrator group membership")
struct AdministratorGroupTests {
    @Test func rootIsAnAdministrator() {
        #expect(AdministratorGroup.contains(uid: 0))
    }

    @Test func unknownUIDIsNot() {
        #expect(!AdministratorGroup.contains(uid: 4_000_000_000))
    }
}
