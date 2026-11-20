import Testing
import MacUpdaterCore
@testable import WegaMacUpdater

@Suite("Password prompt notice") @MainActor
struct PasswordPromptNoticeTests {
    @Test func warnsOnlyWhenNothingCanAskForThePassword() {
        #expect(PasswordPromptNotice.shouldWarn(installed: false, touchID: .available, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(installed: true, touchID: .available, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(installed: false, touchID: .enabled, queuedNeedingPassword: ["zoom"]))
        #expect(!PasswordPromptNotice.shouldWarn(installed: false, touchID: .available, queuedNeedingPassword: []))
    }

    @Test func theMessageNamesTheApp() {
        #expect(PasswordPromptNotice.message(firstApp: "zoom")
                == trf("Ta kopia Wegi nie umie poprosić o hasło administratora, więc %@ się nie zaktualizuje. Zainstaluj Wegę z pliku .pkg albo włącz Touch ID.", "zoom"))
    }
}
