import Foundation
import MacUpdaterCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var brewPath: String = "Not found"
    @Published var masPath: String = "Not found"
    @Published var statusError: String?

    let brewService: BrewService
    let masService: MasService

    private let locator: BinaryLocator

    init(
        locator: BinaryLocator = BinaryLocator(),
        brewService: BrewService = BrewService(),
        masService: MasService = MasService()
    ) {
        self.locator = locator
        self.brewService = brewService
        self.masService = masService
    }

    func refreshSystemStatus() async {
        let locations = locator.locateToolchain()
        brewPath = locations.brew?.path ?? "Not found"
        masPath = locations.mas?.path ?? "Not installed"
    }
}
