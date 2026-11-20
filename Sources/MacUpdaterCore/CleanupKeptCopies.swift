import Foundation

/// The user's "keep this copy" choices, one per tool (lowercased name), stored locally in
/// UserDefaults as JSON. They are never part of a report or an export.
public enum CleanupKeptCopies {
    public static let defaultsKey = "cleanup.keptCopies"

    /// The stored choices; nothing stored, or anything unreadable, is no choice at all.
    public static func load(from defaults: UserDefaults) -> [String: CleanupKeptCopy] {
        guard let data = defaults.data(forKey: defaultsKey),
              let copies = try? JSONDecoder().decode([String: CleanupKeptCopy].self, from: data) else { return [:] }
        return copies
    }

    /// A choice that cannot be encoded is not written, so the stored ones stay readable.
    public static func save(_ copies: [String: CleanupKeptCopy], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(copies) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
