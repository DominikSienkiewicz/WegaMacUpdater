import Foundation
import Testing
import WegaTestSupport

@testable import MacUpdaterCore

@Suite("Background update consent management")
@MainActor
struct BackgroundUpdateConsentManagementTests {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        TestDefaults.isolated("bg05-consent")
    }

    private func profile(
        token: String = "iterm2",
        kinds: [CaskArtifactKind] = [.app]
    ) -> CaskArtifactProfile {
        CaskArtifactProfile(
            token: token,
            artifacts: kinds.map { CaskArtifact(kind: $0) }
        )
    }

    private func download(token: String = "iterm2", checksum: Bool = true) -> CaskDownloadInfo {
        CaskDownloadInfo(
            token: token,
            url: "https://example.com/app.zip",
            sha256: checksum ? String(repeating: "a", count: 64) : nil
        )
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func grantDatePersistsAndARepeatedGrantDoesNotRewriteIt() {
        let (defaults, teardown) = isolatedDefaults()
        defer { teardown() }
        let grantedAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let store = BackgroundUpdateOptInStore(defaults: defaults, now: { grantedAt })

        store.setOptedIn(true, token: "iterm2")
        store.setOptedIn(true, token: "iterm2")

        #expect(store.consents == [BackgroundUpdateConsent(token: "iterm2", grantedAt: grantedAt)])
        let reloaded = BackgroundUpdateOptInStore(
            defaults: defaults,
            now: { grantedAt.addingTimeInterval(86_400) }
        )
        #expect(reloaded.consents == store.consents)
    }

    @Test func consentSurvivesDisappearingFromCandidatesAndCanStillBeRevoked() {
        let (defaults, teardown) = isolatedDefaults()
        defer { teardown() }
        let store = BackgroundUpdateOptInStore(defaults: defaults)
        store.setOptedIn(true, token: "ghost-app")

        let eligible = BackgroundUpdatePlanner.eligibleTokens(
            .init(
                candidates: [],
                profiles: [:],
                downloads: [:],
                optedIn: store.tokens,
                runningProcessTokens: [],
                policies: [:]
            ))

        #expect(eligible.isEmpty)
        #expect(store.consents.map(\.token) == ["ghost-app"])
        store.setOptedIn(false, token: "ghost-app")
        #expect(store.consents.isEmpty)
        #expect(BackgroundUpdateOptInStore(defaults: defaults).consents.isEmpty)
    }

    @Test func legacyTokenArrayMigratesWithoutLosingExistingConsent() {
        let (defaults, teardown) = isolatedDefaults()
        defer { teardown() }
        defaults.set(["zed", "iterm2"], forKey: "wega.backgroundUpdate.optIn")
        let migratedAt = Date(timeIntervalSinceReferenceDate: 710_000_000)

        let store = BackgroundUpdateOptInStore(defaults: defaults, now: { migratedAt })

        #expect(store.consents.map(\.token) == ["iterm2", "zed"])
        #expect(store.consents.allSatisfy { $0.grantedAt == migratedAt })
        #expect(defaults.stringArray(forKey: "wega.backgroundUpdate.optIn") == nil)
        #expect(BackgroundUpdateOptInStore(defaults: defaults).consents == store.consents)
    }

    @Test func qualificationExplainsEveryStableEligibilityOutcome() {
        #expect(
            BackgroundUpdateConsentQualification.evaluate(profile: nil, download: nil)
                == .metadataUnavailable
        )
        #expect(
            BackgroundUpdateConsentQualification.evaluate(
                profile: profile(kinds: []), download: download())
                == .ineligible(.noArtifacts)
        )
        #expect(
            BackgroundUpdateConsentQualification.evaluate(
                profile: profile(kinds: [.binary]), download: download())
                == .ineligible(.noAppBundle)
        )
        #expect(
            BackgroundUpdateConsentQualification.evaluate(
                profile: profile(kinds: [.app, .pkg]), download: download())
                == .ineligible(.privilegedArtifact)
        )
        #expect(
            BackgroundUpdateConsentQualification.evaluate(
                profile: profile(), download: download(checksum: false))
                == .ineligible(.noChecksum)
        )
        #expect(
            BackgroundUpdateConsentQualification.evaluate(profile: profile(), download: download())
                == .eligible
        )
    }

    @Test func settingsOwnTheCompleteConsentListAndRevocationAction() throws {
        let root = packageRoot()
        let info = try String(
            contentsOf: root.appendingPathComponent("Sources/MacUpdater/InfoView.swift"),
            encoding: .utf8
        )
        let card = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/MacUpdater/BackgroundUpdateConsentSettingsCard.swift"),
            encoding: .utf8
        )

        #expect(info.contains("BackgroundUpdateConsentSettingsCard()"))
        #expect(card.contains("ForEach(store.consents)"))
        #expect(card.contains("consent.grantedAt"))
        #expect(card.contains("store.setOptedIn(false, token: consent.token)"))
        #expect(card.contains("case .noArtifacts"))
        #expect(card.contains("case .noAppBundle"))
        #expect(card.contains("case .privilegedArtifact"))
        #expect(card.contains("case .noChecksum"))
        #expect(card.contains("case .metadataUnavailable"))
    }
}
