import Foundation

/// Built-in support for Bruno's official stable distribution, independent of Homebrew.
enum BrunoUpdateSupport {
    static let catalogEntry = GitHubCatalogEntry(
        bundleId: "com.usebruno.app", repo: "usebruno/bruno", caskToken: "bruno", selfUpdates: true
    )

    static func isOfficial(_ mapping: GitHubCatalogEntry) -> Bool {
        mapping.bundleId == catalogEntry.bundleId && mapping.repo == catalogEntry.repo
    }

    static func isStableVersion(_ version: String?) -> Bool {
        guard let version else { return false }
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 3 && components.allSatisfy { component in
            !component.isEmpty
                && (component.count == 1 || component.first != "0")
                && component.utf8.allSatisfy { (48...57).contains($0) }
                && Int(component) != nil
        }
    }

    static func isStableTag(_ tag: String) -> Bool {
        isStableVersion(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
    }
}
