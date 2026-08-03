import Foundation
import Testing
import MacUpdaterCore
import WegaTestSupport
@testable import WegaMacUpdater

/// QA-01 — the app-target singletons (`UpdatePolicyStore`, `LocalizationManager`,
/// `MenuBarAgent`) gained an `init(defaults:)` so their persistence can be driven from a
/// throwaway suite instead of the process-wide `.standard` domain. These pin that the
/// *injected* `UserDefaults` is the one actually read and written — a regression where a
/// store silently reverts to `.standard` is invisible at the screen until a test isolates it.
///
/// The suite also demonstrates the point the coverage-exclusion comment now makes: the
/// `WegaMacUpdater` executable target IS reachable via `@testable import`, so its
/// orchestrators are testable and belong in the coverage metric.
@Suite("Store defaults injection")
@MainActor
struct StoreDefaultsInjectionTests {

    @Test func updatePolicyStoreReadsAndWritesInjectedDefaults() {
        let (defaults, teardown) = TestDefaults.isolated("qa01-update-policy-store")
        defer { teardown() }

        let store = UpdatePolicyStore(defaults: defaults)
        store.ignore(key: "c:foo", name: "Foo")

        #expect(store.policy(for: "c:foo") == .ignored)
        // Persisted into the injected domain…
        #expect(defaults.data(forKey: "wega.updatePolicies") != nil)
        // …and a fresh store over the same domain recovers the decision.
        let reloaded = UpdatePolicyStore(defaults: defaults)
        #expect(reloaded.policy(for: "c:foo") == .ignored)
    }

    @Test func localizationManagerReadsAndWritesInjectedDefaults() {
        let (defaults, teardown) = TestDefaults.isolated("qa01-localization-manager")
        defer { teardown() }

        // `language`'s didSet mutates the global `LocalizedStrings.current`; restore it so this
        // test cannot bleed into `tr()`-based assertions elsewhere in the suite.
        let previousLanguage = LocalizedStrings.current
        defer { LocalizedStrings.current = previousLanguage }

        let manager = LocalizationManager(defaults: defaults)
        manager.language = .en
        #expect(defaults.string(forKey: "wega.language") == AppLanguage.en.rawValue)

        let reloaded = LocalizationManager(defaults: defaults)
        #expect(reloaded.language == .en)
    }

    @Test func menuBarAgentReadsAndWritesInjectedDefaults() {
        let (defaults, teardown) = TestDefaults.isolated("qa01-menu-bar-agent")
        defer { teardown() }

        let agent = MenuBarAgent(defaults: defaults)
        agent.interval = .daily
        #expect(defaults.string(forKey: "wega.menubar.interval") == CheckInterval.daily.rawValue)

        // The notification-answer watermark persists through the same injected domain
        // (`declineNotifications` never touches the system dialog, so it is safe headless).
        agent.declineNotifications()
        #expect(defaults.string(forKey: "wega.notifications.inAppAnswer") == "declined")

        // A fresh agent over the same domain reads the persisted interval back.
        let reloaded = MenuBarAgent(defaults: defaults)
        #expect(reloaded.interval == .daily)
    }
}
