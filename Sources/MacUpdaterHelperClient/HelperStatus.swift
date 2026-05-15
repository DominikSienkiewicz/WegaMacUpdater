import MacUpdaterCore
import Foundation

public enum HelperRegistrationStatus: String, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unavailable
}

public struct HelperIdentity: Equatable, Sendable {
    public var plistName: String
    public var machServiceName: String

    public init(
        plistName: String = "\(AppMetadata.helperIdentifier).plist",
        machServiceName: String = AppMetadata.helperIdentifier
    ) {
        self.plistName = plistName
        self.machServiceName = machServiceName
    }
}
