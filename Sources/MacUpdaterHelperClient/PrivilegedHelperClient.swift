import Foundation
import ServiceManagement

public protocol PrivilegedHelperClient {
    func status() -> HelperRegistrationStatus
    func register() throws
}

public final class SMAppServiceHelperClient: PrivilegedHelperClient {
    private let identity: HelperIdentity

    public init(identity: HelperIdentity = HelperIdentity()) {
        self.identity = identity
    }

    public func status() -> HelperRegistrationStatus {
        let service = SMAppService.daemon(plistName: identity.plistName)

        switch service.status {
        case .notRegistered:
            return .notRegistered
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notFound
        @unknown default:
            return .unavailable
        }
    }

    public func register() throws {
        let service = SMAppService.daemon(plistName: identity.plistName)
        try service.register()
    }
}
