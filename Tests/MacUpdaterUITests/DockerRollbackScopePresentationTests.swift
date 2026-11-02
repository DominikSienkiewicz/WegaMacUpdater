import MacUpdaterCore
import Testing
@testable import WegaMacUpdater

struct DockerRollbackScopePresentationTests {
    @Test func dockerDisclosureNamesTheBundleAndEveryExcludedEnvironmentComponent() throws {
        let notice = try #require(RollbackScopePresentation.notice(for: .dockerAppBundleOnly))
        #expect(notice.title == "Cofanie obejmuje tylko Docker.app")
        #expect(notice.details.contains("ustawień"))
        #expect(notice.details.contains("maszyny wirtualnej"))
        #expect(notice.details.contains("woluminów"))
        #expect(notice.details.contains("danych kontenerów"))
        #expect(notice.details.contains("nie tworzy ani nie weryfikuje"))
        #expect(notice.migrationWarning.contains("nie gwarantuje zgodności danych"))
        #expect(notice.migrationWarning.contains("migracji"))
    }

    @Test func englishDisclosureMakesTheSameLimitedRecoveryPromise() throws {
        let notice = try #require(RollbackScopePresentation.notice(for: .dockerAppBundleOnly))
        #expect(Translations.en[notice.title] == "Rollback covers Docker.app only")
        let details = try #require(Translations.en[notice.details])
        #expect(details.contains("settings"))
        #expect(details.contains("virtual machine"))
        #expect(details.contains("volumes"))
        #expect(details.contains("container data"))
        #expect(details.contains("does not create or verify"))
        let warning = try #require(Translations.en[notice.migrationWarning])
        #expect(warning.contains("does not guarantee data compatibility"))
        #expect(warning.contains("migrations"))
    }

    @Test func genericApplicationsDoNotReceiveDockerSpecificWarnings() {
        #expect(RollbackScopePresentation.notice(for: .appBundleOnly) == nil)
    }
}
