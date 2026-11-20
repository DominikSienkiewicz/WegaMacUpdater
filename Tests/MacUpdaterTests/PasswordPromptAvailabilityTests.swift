import Testing
@testable import MacUpdaterCore

@Suite("Password prompt availability")
struct PasswordPromptAvailabilityTests {
    @Test func installedPayloadIsReadFromTheSystemResolver() {
        let direct = (try? AuthorizationComponentResolver().resolveAndVerify()) != nil
        #expect(PasswordPromptAvailability.isInstalled() == direct)
    }
}
