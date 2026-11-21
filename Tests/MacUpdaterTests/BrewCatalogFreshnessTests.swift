import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Brew catalog freshness")
struct BrewCatalogFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func aCatalogYoungerThanHalfAnHourIsKeptAtLaunch() {
        #expect(!BrewCatalogFreshness.refreshesAtLaunch(lastRefreshedAt: now.addingTimeInterval(-29 * 60), now: now))
        #expect(BrewCatalogFreshness.refreshesAtLaunch(lastRefreshedAt: now.addingTimeInterval(-30 * 60), now: now))
        #expect(BrewCatalogFreshness.refreshesAtLaunch(lastRefreshedAt: now.addingTimeInterval(-31 * 60), now: now))
    }

    @Test func aMissingOrFutureStampRefreshes() {
        #expect(BrewCatalogFreshness.refreshesAtLaunch(lastRefreshedAt: nil, now: now))
        #expect(BrewCatalogFreshness.refreshesAtLaunch(lastRefreshedAt: now.addingTimeInterval(120), now: now), "clock skew")
    }

    @Test func theAgeIsCountedInWholeMinutesAndIsNeverZero() {
        #expect(BrewCatalogFreshness.ageMinutes(refreshedAt: now.addingTimeInterval(-(12 * 60 + 40)), scanStartedAt: now) == 12)
        #expect(BrewCatalogFreshness.ageMinutes(refreshedAt: now.addingTimeInterval(-10), scanStartedAt: now) == 1)
    }
}
