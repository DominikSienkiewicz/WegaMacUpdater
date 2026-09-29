import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Recovery errors are available without the UI localization module")
struct RecoveryErrorDescriptionTests {
    @Test func pendingInstallationProvidesActionableDescription() {
        let error = OperationCoordinator.LeaseError.externalInstallationPending
        let expected = "Wynik instalacji jest nieznany. Dalsze zmiany są zablokowane — sprawdź stan instalacji w Ustawieniach."

        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
        #expect(Translations.en[expected] != nil)
    }

    @Test func persistenceFailureProvidesSafeDescriptionWithoutDiagnosticDetails() {
        let error = UpdateOperationPersistenceError(detail: "Permission denied: /private/journal/operation.json")
        let expected = "Nie można zapisać dziennika odzyskiwania. Aktualizacja została odroczona — sprawdź wolne miejsce i uprawnienia. Szczegóły w logach."

        #expect(error.errorDescription == expected)
        #expect(error.localizedDescription == expected)
        #expect(Translations.en[expected] != nil)
    }
}
