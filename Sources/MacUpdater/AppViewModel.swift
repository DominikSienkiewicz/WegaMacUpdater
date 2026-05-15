import Foundation
import MacUpdaterCore
import MacUpdaterHelperClient

@MainActor
final class AppViewModel: ObservableObject {
    @Published var brewPath: String = "Not found"
    @Published var masPath: String = "Not found"
    @Published var helperStatus: HelperRegistrationStatus = .unavailable
    @Published var statusError: String?

    let brewService: BrewService
    let masService: MasService

    private let locator: BinaryLocator
    private let helperClient: PrivilegedHelperClient

    init(
        locator: BinaryLocator = BinaryLocator(),
        helperClient: PrivilegedHelperClient = SMAppServiceHelperClient(),
        brewService: BrewService = BrewService(),
        masService: MasService = MasService()
    ) {
        self.locator = locator
        self.helperClient = helperClient
        self.brewService = brewService
        self.masService = masService
    }

    func refreshSystemStatus() async {
        let locations = locator.locateToolchain()
        brewPath = locations.brew?.path ?? "Not found"
        masPath = locations.mas?.path ?? "Not installed"
        helperStatus = helperClient.status()
    }

    func registerHelper() {
        do {
            try helperClient.register()
            helperStatus = helperClient.status()
            statusError = nil
        } catch {
            statusError = error.localizedDescription
        }
    }
}
