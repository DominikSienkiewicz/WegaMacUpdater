import Combine
import Foundation

/// A durable record of explicit permission to update one cask without the user present.
public struct BackgroundUpdateConsent: Codable, Equatable, Identifiable, Sendable {
    public var id: String { token }

    public let token: String
    public let grantedAt: Date

    public init(token: String, grantedAt: Date) {
        self.token = token
        self.grantedAt = grantedAt
    }
}

/// Persistent, observable consent ledger shared by the update-row toggle, Settings and the
/// background updater. Entries are independent of the current outdated list, so a consent
/// remains auditable and revocable after the package disappears from that list.
@MainActor
public final class BackgroundUpdateOptInStore: ObservableObject {
    public static let shared = BackgroundUpdateOptInStore()

    private static let defaultsKey = "wega.backgroundUpdate.consents.v2"
    private static let legacyDefaultsKey = "wega.backgroundUpdate.optIn"

    private let defaults: UserDefaults
    private let now: () -> Date

    @Published public private(set) var consents: [BackgroundUpdateConsent]

    public var tokens: Set<String> { Set(consents.map(\.token)) }

    public init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.now = now

        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode([BackgroundUpdateConsent].self, from: data)
        {
            consents = Self.normalized(decoded)
        } else if let legacyTokens = defaults.stringArray(forKey: Self.legacyDefaultsKey) {
            let migratedAt = now()
            consents = Self.normalized(
                legacyTokens.map { BackgroundUpdateConsent(token: $0, grantedAt: migratedAt) }
            )
            persist()
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        } else {
            consents = []
        }
    }

    public func isOptedIn(_ token: String) -> Bool {
        consents.contains { $0.token == token }
    }

    public func setOptedIn(_ optedIn: Bool, token: String) {
        if optedIn {
            grant(token: token)
        } else {
            revoke(token: token)
        }
    }

    public func revoke(token: String) {
        let previousCount = consents.count
        consents.removeAll { $0.token == token }
        if consents.count != previousCount {
            persist()
        }
    }

    private func grant(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isOptedIn(trimmed) else { return }
        consents.append(BackgroundUpdateConsent(token: trimmed, grantedAt: now()))
        consents.sort { $0.token < $1.token }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(consents) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func normalized(
        _ values: [BackgroundUpdateConsent]
    ) -> [BackgroundUpdateConsent] {
        var earliestByToken: [String: BackgroundUpdateConsent] = [:]
        for consent in values {
            let token = consent.token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            let normalized = BackgroundUpdateConsent(token: token, grantedAt: consent.grantedAt)
            if let existing = earliestByToken[token], existing.grantedAt <= consent.grantedAt {
                continue
            }
            earliestByToken[token] = normalized
        }
        return earliestByToken.values.sorted { $0.token < $1.token }
    }
}

/// Stable metadata verdict shown next to a durable consent in Settings. Runtime vetoes such
/// as a running process, a policy, resource pressure or snapshot failure are intentionally
/// re-evaluated immediately before every background update and described separately by the UI.
public enum BackgroundUpdateConsentQualification: Equatable, Sendable {
    case eligible
    case ineligible(BackgroundUpdateEligibility.Rejection)
    case metadataUnavailable

    public static func evaluate(
        profile: CaskArtifactProfile?,
        download: CaskDownloadInfo?
    ) -> BackgroundUpdateConsentQualification {
        guard let profile else { return .metadataUnavailable }
        switch BackgroundUpdateEligibility.evaluate(profile: profile, download: download) {
        case .eligible:
            return .eligible
        case .ineligible(let rejection):
            return .ineligible(rejection)
        }
    }
}
