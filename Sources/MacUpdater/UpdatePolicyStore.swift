import Foundation
import MacUpdaterCore

/// Persists the user's ignore / pin decisions (UserDefaults, JSON). The pure
/// filtering lives in `MacUpdaterCore.UpdatePlanner`; this just stores the rules
/// and exposes them as an observable map the views filter through.
@MainActor
final class UpdatePolicyStore: ObservableObject {
    static let shared = UpdatePolicyStore()

    private static let defaultsKey = "wega.updatePolicies"

    @Published private(set) var entries: [String: UpdatePolicyEntry]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([UpdatePolicyEntry].self, from: data) {
            entries = Dictionary(decoded.map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
        } else {
            entries = [:]
        }
    }

    /// Map consumed by `UpdatePlanner.applyPolicies`.
    var policiesMap: [String: UpdatePolicy] { entries.mapValues(\.policy) }

    var sortedEntries: [UpdatePolicyEntry] {
        entries.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var isEmpty: Bool { entries.isEmpty }

    func policy(for key: String) -> UpdatePolicy? { entries[key]?.policy }

    func ignore(key: String, name: String) {
        set(UpdatePolicyEntry(key: key, displayName: name, policy: .ignored))
    }

    func pin(key: String, name: String, version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        set(UpdatePolicyEntry(key: key, displayName: name, policy: .pinned(version: trimmed)))
    }

    func remove(key: String) {
        entries[key] = nil
        persist()
    }

    private func set(_ entry: UpdatePolicyEntry) {
        entries[entry.key] = entry
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
