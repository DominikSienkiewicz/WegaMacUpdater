import Foundation
import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

/// C2 stage 3 — while an update runs, the band says what it is doing: since when, the stage
/// the run is on, how many packages are done and how to stop it. The stage text is the one the
/// run bar under the list used, so the two never named the same step differently.
@Suite("Update band — the run") @MainActor
struct UpdateBandRunPresentationTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theRunSaysWhatItIsDoing() {
        let run = UpdateBandRunPresentation(progress: UpgradeProgress(completedUnits: 1, totalUnits: 5, stage: .installing(token: "slack")),
                                            startedAt: start, isStopping: false, logShown: true)
        let time = start.formatted(date: .omitted, time: .shortened)
        withLanguage(.pl) {
            #expect(run.eyebrow == "Trwa aktualizacja · od \(time)")
            #expect(run.headline == "Aktualizuję wybrane pakiety" && run.line == "Instaluję slack — 1 z 5")
            #expect(run.counter == "1 z 5" && run.completed == 1 && run.total == 5)
            #expect(run.stopLabel == "Zatrzymaj po rozpoczętych instalacjach")
        }
        withLanguage(.en) {
            #expect(run.eyebrow == "Updating · since \(time)" && run.line == "Installing slack — 1 of 5")
        }
        let early = UpdateBandRunPresentation(progress: nil, startedAt: nil, isStopping: true, logShown: false)
        withLanguage(.pl) {
            #expect(early.eyebrow == "Trwa aktualizacja" && early.line == "Przygotowuję kopie zapasowe…" && early.counter == nil)
            #expect(early.stopLabel == "Kończę rozpoczęte instalacje, nowych nie zaczynam")
        }
    }

    @Test func theStageLabelIsTheOneTheBarUsed() {
        withLanguage(.pl) {
            #expect(UpgradeProgressCopy.label(for: .init(completedUnits: 0, totalUnits: 3, stage: .preparing)) == "Przygotowuję kopie zapasowe…")
            #expect(UpgradeProgressCopy.label(for: .init(completedUnits: 1, totalUnits: 3, stage: .downloading(token: "zoom"))) == "Pobieram zoom — 1 z 3")
            #expect(UpgradeProgressCopy.label(for: .init(completedUnits: 1, totalUnits: 3, stage: .downloading(token: nil))) == "Pobieram pakiety — 1 z 3")
            #expect(UpgradeProgressCopy.label(for: .init(completedUnits: 2, totalUnits: 3, stage: .installing(token: nil))) == "Instaluję pakiety — 2 z 3")
        }
        withLanguage(.en) {
            #expect(UpdateRunCopy.lockNote == "The list stays locked until the update ends.")
            #expect(tr("Bieżącej instalacji nie przerywam w połowie.") == "I never stop an install halfway.")
        }
    }
}
