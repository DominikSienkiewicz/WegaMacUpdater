import Foundation

public enum InstallationCheckStatus: String, Sendable {
    case notChecked, current, updateAvailable, failed, noSource, excluded, stale

    public var needsAttention: Bool {
        switch self {
        case .notChecked, .failed, .noSource, .stale: true
        case .current, .updateAvailable, .excluded: false
        }
    }
}

public struct InstallationSourceCheck: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case current, outdated, failed, notChecked
    }
    public var source: String
    public var outcome: Outcome
    public var availableVersion: String?
    public var policyKey: String?

    public init(source: String, outcome: Outcome, availableVersion: String? = nil, policyKey: String? = nil) {
        self.source = source
        self.outcome = outcome
        self.availableVersion = availableVersion
        self.policyKey = policyKey
    }

    init(source: String, result: ManualCheckResult) {
        switch result {
        case .upToDate: self.init(source: source, outcome: .current)
        case .outdated(let app):
            self.init(source: source, outcome: .outdated, availableVersion: app.availableVersion, policyKey: app.policyKey)
        case .failed, .unavailable: self.init(source: source, outcome: .failed)
        case .notApplicable: self.init(source: source, outcome: .notChecked)
        }
    }
}

/// Evidence about one bundle at one path. Absence is never evidence that it is current.
public struct InstallationCheck: Codable, Equatable, Sendable {
    public let path: URL
    public let bundleIdentifier: String?
    public let version: String?
    public let buildVersion: String?
    public let checkedAt: Date
    public var lastSuccessfulCheck: Date?
    public var sources: [InstallationSourceCheck]
    public var caskToken: String?
    public var isManagedByMas: Bool

    public init(app: ApplicationInfo, sources: [InstallationSourceCheck], checkedAt: Date) {
        path = app.path
        bundleIdentifier = app.bundleIdentifier
        version = app.version
        buildVersion = app.buildVersion
        self.checkedAt = checkedAt
        self.sources = sources
        caskToken = nil
        isManagedByMas = app.isManagedByMas
        lastSuccessfulCheck = nil
        stampSuccess()
    }

    mutating func stampSuccess() {
        if !sources.isEmpty, sources.allSatisfy({ $0.outcome == .current || $0.outcome == .outdated }) {
            lastSuccessfulCheck = checkedAt
        }
    }

    public func status(for app: ApplicationInfo, policies: [String: UpdatePolicy] = [:], now: Date = Date()) -> InstallationCheckStatus {
        guard InstallationIdentity(path: path) == app.installation, bundleIdentifier == app.bundleIdentifier else { return .notChecked }
        guard version == app.version, buildVersion == app.buildVersion,
              now.timeIntervalSince(checkedAt) <= 86_400, checkedAt <= now else { return .stale }
        let updates = sources.filter { $0.outcome == .outdated }
        if updates.contains(where: { check in
            guard let key = check.policyKey else { return true }
            return !UpdatePlanner.isSuppressed(key: key, availableVersion: check.availableVersion, policies: policies)
        }) { return .updateAvailable }
        if sources.contains(where: { $0.outcome == .failed }) { return .failed }
        if !updates.isEmpty { return .excluded }
        if sources.contains(where: { $0.outcome == .notChecked }) { return .notChecked }
        if sources.contains(where: { $0.outcome == .current }) { return .current }
        return .noSource
    }

    public static func retainingLastSuccess(_ current: [Self], previous: [Self]) -> [Self] {
        let previousByPath = Dictionary(previous.map { (InstallationIdentity(path: $0.path), $0) }, uniquingKeysWith: { _, last in last })
        return current.map { check in
            var updated = check
            if let old = previousByPath[InstallationIdentity(path: check.path)],
               old.bundleIdentifier == check.bundleIdentifier, old.version == check.version, old.buildVersion == check.buildVersion,
               check.lastSuccessfulCheck == nil {
                updated.lastSuccessfulCheck = old.lastSuccessfulCheck
            }
            return updated
        }
    }

    public static func resolvingManagers(
        _ checks: [Self], reports: ScanSourceReports, brew: BrewOutdated?
    ) -> [Self] {
        checks.map { check in
            var updated = check
            if let token = check.caskToken {
                let pending = brew?.casks.first { $0.name == token }
                let target = pending?.currentVersion
                let outcome: InstallationSourceCheck.Outcome
                if reports.brew?.didFail == true || reports.brewMetadata?.didFail == true { outcome = .failed }
                else if reports.brew?.outcome == .succeeded { outcome = pending == nil ? .current : .outdated }
                else { outcome = .notChecked }
                updated.sources.removeAll { $0.source == "Homebrew" }
                updated.sources.append(.init(source: "Homebrew", outcome: outcome, availableVersion: target, policyKey: "c:" + token))
            } else if check.isManagedByMas, reports.mas?.didFail == true {
                updated.sources = [.init(source: "App Store", outcome: .failed)]
            }
            updated.stampSuccess()
            return updated
        }
    }
}
