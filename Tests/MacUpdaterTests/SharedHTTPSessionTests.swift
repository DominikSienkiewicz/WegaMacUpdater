import Foundation
import Testing

@testable import MacUpdaterCore

/// ARCH-08e — sondy HEAD mają korzystać ze współdzielonej `URLSession`.
///
/// `makeDefaultSession()` był domyślnym argumentem `HTTPClient` i `DownloadSizeProbe`, a
/// domyślne argumenty wyliczają się przy każdym wywołaniu — więc każda sonda dostawała własną
/// sesję i własną pulę połączeń. Skan sondujący kilkanaście hostów otwierał kilkanaście sesji
/// i nie reużywał ani jednego połączenia.
@Suite("ARCH-08e shared session")
struct SharedHTTPSessionTests {

    @Test func theSharedSessionIsOneInstance() {
        #expect(HTTPClient.sharedSession === HTTPClient.sharedSession)
    }

    /// Fabryka zostaje dla testów, które świadomie chcą izolowanej sesji — i musi nadal
    /// zwracać nową, inaczej ta możliwość znika.
    @Test func theFactoryStillProducesAnIsolatedSession() {
        #expect(HTTPClient.makeDefaultSession() !== HTTPClient.sharedSession)
        #expect(HTTPClient.makeDefaultSession() !== HTTPClient.makeDefaultSession())
    }

    /// Konfiguracja współdzielonej sesji to ta sama konfiguracja, którą projekt już uzgodnił:
    /// limity czasu i pominięcie URLCache, bo rewalidację robimy sami przez ETag.
    @Test func theSharedSessionKeepsTheAgreedConfiguration() {
        let config = HTTPClient.sharedSession.configuration
        #expect(config.timeoutIntervalForRequest == 15)
        #expect(config.timeoutIntervalForResource == 30)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }
}
