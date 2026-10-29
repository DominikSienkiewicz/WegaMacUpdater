import Foundation

/// An installed cask or formula and the tap Homebrew installed it from.
public struct InstalledPackageOrigin: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case cask
        case formula
    }

    public let kind: Kind
    /// The cask token or formula name, without its tap.
    public let name: String
    /// `<user>/<repo>`, as the receipt records it.
    public let tap: String

    public init(kind: Kind, name: String, tap: String) {
        self.kind = kind
        self.name = name
        self.tap = tap
    }
}

/// Reads which tap every installed package came from, out of Homebrew's install receipts.
///
/// The tap-trust remedy depends on this answer: a tap something installed came from gets the
/// narrowest trust, an unused one gets untapped. A token or formula name says nothing about
/// it — `cmux` is installed here from `homebrew/cask`, not from the `manaflow-ai/cmux` tap that
/// shares its name — so the decision is taken from the record Homebrew itself consults
/// (`cask.tab.tap`, `keg.tab.tap`):
///
/// * casks: `<prefix>/Caskroom/<token>/.metadata/INSTALL_RECEIPT.json`
/// * formulae: `<prefix>/Cellar/<name>/<version>/INSTALL_RECEIPT.json`
///
/// Each receipt's `source.tap` names the tap. A package with no receipt, an unreadable one or
/// no tap in it is left out: its origin is unknown, and attributing it to a tap would be a guess.
public struct HomebrewInstallReceipts {
    static let fileName = "INSTALL_RECEIPT.json"

    private let prefix: URL
    private let fileManager: FileManager

    /// - Parameter prefix: Homebrew's prefix (`/opt/homebrew`, `/usr/local`), the directory
    ///   holding `Caskroom` and `Cellar`.
    public init(prefix: URL, fileManager: FileManager = .default) {
        self.prefix = prefix
        self.fileManager = fileManager
    }

    public func installedPackages() -> [InstalledPackageOrigin] {
        installedCasks() + installedFormulae()
    }

    private func installedCasks() -> [InstalledPackageOrigin] {
        subdirectories(of: prefix.appendingPathComponent("Caskroom")).compactMap { cask in
            let receipt = cask.appendingPathComponent(".metadata").appendingPathComponent(Self.fileName)
            return tap(inReceiptAt: receipt).map {
                InstalledPackageOrigin(kind: .cask, name: cask.lastPathComponent, tap: $0)
            }
        }
    }

    /// One origin per distinct tap among a formula's kegs: two installed versions can come
    /// from different taps when a formula moved, and each of them still loads from its own.
    private func installedFormulae() -> [InstalledPackageOrigin] {
        subdirectories(of: prefix.appendingPathComponent("Cellar")).flatMap { rack in
            let taps = Set(subdirectories(of: rack).compactMap { keg in
                tap(inReceiptAt: keg.appendingPathComponent(Self.fileName))
            })
            return taps.map { InstalledPackageOrigin(kind: .formula, name: rack.lastPathComponent, tap: $0) }
        }
    }

    private func subdirectories(of directory: URL) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func tap(inReceiptAt url: URL) -> String? {
        guard let data = fileManager.contents(atPath: url.path),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              let tap = receipt.source?.tap, !tap.isEmpty else { return nil }
        return tap
    }

    private struct Receipt: Decodable {
        struct Source: Decodable {
            let tap: String?
        }

        let source: Source?
    }
}
