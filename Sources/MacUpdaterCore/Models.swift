import Foundation

public struct RestartInfo: Equatable, Sendable {
    public var processName: String
    public var appName: String

    public init(processName: String, appName: String) {
        self.processName = processName
        self.appName = appName
    }
}

public struct BrewCask: Codable, Equatable, Sendable {
    public var token: String
    public var name: [String]

    public init(token: String, name: [String]) {
        self.token = token
        self.name = name
    }
}

public struct ApplicationInfo: Identifiable, Equatable, Sendable {
    public var id: String { path.path }

    public var path: URL
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?
    public var installDate: Date?
    public var updateDate: Date?
    public var isManagedByBrew: Bool
    public var caskToken: String?
    public var isManagedByMas: Bool
    public var masAppID: String?

    public init(
        path: URL,
        name: String,
        bundleIdentifier: String?,
        version: String?,
        installDate: Date?,
        updateDate: Date?,
        isManagedByBrew: Bool,
        caskToken: String? = nil,
        isManagedByMas: Bool = false,
        masAppID: String? = nil
    ) {
        self.path = path
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.installDate = installDate
        self.updateDate = updateDate
        self.isManagedByBrew = isManagedByBrew
        self.caskToken = caskToken
        self.isManagedByMas = isManagedByMas
        self.masAppID = masAppID
    }
}

public struct BrewOutdated: Equatable, Sendable {
    public var formulae: [BrewOutdatedItem]
    public var casks: [BrewOutdatedItem]

    public init(formulae: [BrewOutdatedItem], casks: [BrewOutdatedItem]) {
        self.formulae = formulae
        self.casks = casks
    }

    public var totalCount: Int {
        formulae.count + casks.count
    }
}

public struct BrewOutdatedItem: Equatable, Sendable {
    public var name: String
    public var installedVersions: [String]
    public var currentVersion: String?
    public var pinned: Bool?
    public var autoUpdates: Bool?

    public init(
        name: String,
        installedVersions: [String],
        currentVersion: String?,
        pinned: Bool? = nil,
        autoUpdates: Bool? = nil
    ) {
        self.name = name
        self.installedVersions = installedVersions
        self.currentVersion = currentVersion
        self.pinned = pinned
        self.autoUpdates = autoUpdates
    }
}

public struct MasOutdatedApp: Equatable, Sendable {
    public var appStoreID: String
    public var name: String
    public var installedVersion: String?
    public var currentVersion: String?

    public init(
        appStoreID: String,
        name: String,
        installedVersion: String?,
        currentVersion: String?
    ) {
        self.appStoreID = appStoreID
        self.name = name
        self.installedVersion = installedVersion
        self.currentVersion = currentVersion
    }
}

public struct MasInstalledApp: Equatable, Sendable {
    public var appStoreID: String
    public var name: String
    public var version: String?

    public init(appStoreID: String, name: String, version: String?) {
        self.appStoreID = appStoreID
        self.name = name
        self.version = version
    }
}

public struct ManualOutdatedApp: Equatable, Sendable {
    public enum UpdateSource: Equatable, Sendable {
        case sparkle
        case cask(token: String)
        case mas(appStoreID: String)
        case jetbrains(caskToken: String)
        case github(repo: String)
        case synology(downloadPage: String)
        /// Antigravity IDE — self-updating app whose Homebrew cask is stale;
        /// detected via Google's own update endpoint.
        case antigravity
        /// Parallels Desktop — self-updating; Homebrew cask `parallels` lags
        /// upstream by days/weeks. Detected via `update.parallels.com` XML.
        case parallels
        /// Google Drive for desktop — self-updating via GoogleSoftwareUpdate.
        /// Brew cask `google-drive` lags upstream. Detected via Google's
        /// public release-notes page.
        case googleDrive
        /// ChatGPT desktop — self-updating via Sparkle from a runtime-resolved
        /// feed. Brew cask `chatgpt` is `auto_updates` and its metadata lags.
        /// Detected via OpenAI's public appcast.
        case chatgpt
        /// Postman — self-updating via Squirrel.Mac (no Sparkle feed). Brew cask
        /// `postman` is `auto_updates` and its version lags the real channel.
        /// Detected via Postman's own Squirrel feed (`dl.pstmn.io`).
        case postman

        public var priority: Int {
            switch self {
            case .antigravity: return 5
            case .parallels:   return 5
            case .googleDrive: return 5
            case .chatgpt:     return 5
            case .postman:     return 5
            case .jetbrains:   return 4
            case .github:      return 3
            case .synology:    return 3
            case .cask:        return 2
            case .sparkle:     return 1
            case .mas:         return 0
            }
        }
    }

    public var name: String
    public var path: URL
    public var installedVersion: String?
    public var availableVersion: String?
    public var source: UpdateSource
    /// Install provenance (Brew / App Store / manual), classified by ``AppOrigin/of(_:)``
    /// — the SAME function the Inventory window uses for its "ŹRÓDŁO" badge. The Updates
    /// window groups by this, not by `source`, so a Homebrew cask whose update is
    /// surfaced by a vendor checker (Postman, ChatGPT…) is still presented as Brew in
    /// both windows. Stamped by `ManualUpdateScanner`; defaults to `.manual`.
    public var origin: AppOrigin
    /// FEAT-06: release notes (when a source provides them, e.g. GitHub `body`) —
    /// fed to `ReleaseNotesTriage` for the advisory "possible security fix" badge.
    public var releaseNotes: String?

    public init(
        name: String,
        path: URL,
        installedVersion: String?,
        availableVersion: String?,
        source: UpdateSource,
        origin: AppOrigin = .manual,
        releaseNotes: String? = nil
    ) {
        self.name = name
        self.path = path
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.source = source
        self.origin = origin
        self.releaseNotes = releaseNotes
    }
}

public struct BrewCaskInstallationInfo: Equatable, Sendable {
    public var token: String
    public var appArtifacts: [String]

    public init(token: String, appArtifacts: [String]) {
        self.token = token
        self.appArtifacts = appArtifacts
    }
}

/// Pre-install download transparency for a cask (**FEAT-03 / I-2**): where the
/// artifact comes from and whether Homebrew will verify its checksum.
/// `sha256 == "no_check"` means the cask installs WITHOUT checksum verification
/// (common for auto-updating apps) — a power-user safety signal worth surfacing.
public struct CaskDownloadInfo: Equatable, Sendable {
    public var token: String
    public var url: String?
    public var sha256: String?

    public init(token: String, url: String?, sha256: String?) {
        self.token = token
        self.url = url
        self.sha256 = sha256
    }

    /// Homebrew verifies the download only when a concrete sha256 is present.
    public var hasChecksum: Bool {
        guard let sha256 else { return false }
        let value = sha256.lowercased()
        return value != "no_check" && !value.isEmpty
    }

    /// Download host — the "where does this actually come from?" signal.
    public var host: String? { url.flatMap { URL(string: $0)?.host } }
}
