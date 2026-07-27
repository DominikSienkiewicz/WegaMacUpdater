import Testing

@testable import WegaMacUpdater
import MacUpdaterCore

/// ARCH-08b — z wyłączonymi checkami agent nie ma po co budzić procesu.
///
/// Pętla wybudzała się co 5 minut niezależnie od ustawienia, żeby za każdym razem zapytać
/// `isDue()`, dostać `false` i zasnąć — 288 wybudzeń dziennie po to, by nic nie zrobić.
@Suite("ARCH-08b polling")
struct MenuBarAgentPollingTests {

    @Test func checksTurnedOffMeanNoLoopAtAll() {
        #expect(MenuBarAgent.shouldPoll(for: .off) == false)
    }

    @Test func everyEnabledIntervalKeepsPolling() {
        for interval in CheckInterval.allCases where interval != .off {
            #expect(MenuBarAgent.shouldPoll(for: interval), "\(interval) musi budzić pętlę")
        }
    }

    /// Decyzja idzie za `seconds`, więc dodanie nowego interwału nie wymaga pamiętania
    /// o osobnej liście — nie da się dodać interwału, który się rozjedzie.
    @Test func theDecisionFollowsTheIntervalItself() {
        for interval in CheckInterval.allCases {
            #expect(MenuBarAgent.shouldPoll(for: interval) == (interval.seconds != nil))
        }
    }
}
