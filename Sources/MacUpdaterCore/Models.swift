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

        public var priority: Int {
            switch self {
            case .jetbrains: return 4
            case .github:    return 3
            case .synology:  return 3
            case .cask:      return 2
            case .sparkle:   return 1
            case .mas:       return 0
            }
        }
    }

    public var name: String
    public var path: URL
    public var installedVersion: String?
    public var availableVersion: String?
    public var source: UpdateSource

    public init(name: String, path: URL, installedVersion: String?, availableVersion: String?, source: UpdateSource) {
        self.name = name
        self.path = path
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.source = source
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
