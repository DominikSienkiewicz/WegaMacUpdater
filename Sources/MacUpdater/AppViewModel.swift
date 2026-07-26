import Foundation
import MacUpdaterCore

@MainActor
final class AppViewModel: ObservableObject {
    let brewService: BrewService
    let masService: MasService
    let npmService: NpmGlobalService

    init(
        brewService: BrewService = BrewService(),
        masService: MasService = MasService(),
        npmService: NpmGlobalService = NpmGlobalService()
    ) {
        self.brewService = brewService
        self.masService = masService
        self.npmService = npmService
    }
}
