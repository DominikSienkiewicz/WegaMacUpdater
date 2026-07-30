import Foundation
import MacUpdaterCore
import Testing

@testable import WegaMacUpdater

@Suite("Update policy store coverage")
@MainActor
struct UpdatePolicyStoreCoverageTests {
    @Test func malformedPersistenceStartsWithAnEmptyStore() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: "wega.updatePolicies")

        let store = UpdatePolicyStore(defaults: defaults)

        #expect(store.isEmpty)
        #expect(store.sortedEntries.isEmpty)
        #expect(store.policiesMap.isEmpty)
    }

    @Test func pinSkipOverwriteSortAndRemovePersistExactly() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UpdatePolicyStore(defaults: defaults)

        store.pin(key: "c:zulu", name: "Zulu", version: "  2.0  ")
        store.skip(key: "c:alpha", name: "alpha", version: " 3.0\n")
        store.ignore(key: "c:middle", name: "Middle")
        store.pin(key: "c:empty", name: "Empty", version: "  \n")
        store.skip(key: "c:empty", name: "Empty", version: "")

        #expect(store.policy(for: "c:zulu") == .pinned(version: "2.0"))
        #expect(store.policy(for: "c:alpha") == .skipped(version: "3.0"))
        #expect(store.policy(for: "c:empty") == nil)
        #expect(store.sortedEntries.map(\.displayName) == ["alpha", "Middle", "Zulu"])
        #expect(store.policiesMap.count == 3)

        store.skip(key: "c:zulu", name: "Zulu", version: "4.0")
        store.remove(key: "c:middle")

        let reloaded = UpdatePolicyStore(defaults: defaults)
        #expect(reloaded.policy(for: "c:zulu") == .skipped(version: "4.0"))
        #expect(reloaded.policy(for: "c:middle") == nil)
        #expect(!reloaded.isEmpty)
    }

    @Test func duplicatePersistedKeysKeepTheLastEntry() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let entries = [
            UpdatePolicyEntry(key: "c:dup", displayName: "Old", policy: .ignored),
            UpdatePolicyEntry(key: "c:dup", displayName: "New", policy: .pinned(version: "9")),
        ]
        defaults.set(try JSONEncoder().encode(entries), forKey: "wega.updatePolicies")

        let store = UpdatePolicyStore(defaults: defaults)

        #expect(store.entries.count == 1)
        #expect(store.entries["c:dup"]?.displayName == "New")
        #expect(store.policy(for: "c:dup") == .pinned(version: "9"))
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = "wega.tests.policy-coverage.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
