import Foundation
import WegaHelperKit

/// Z14, review RC2: a helper registered from a dragged copy before Wega refused such copies stays
/// exposed — launchd can still start a binary swapped into that copy as root — while Wega no longer
/// uses it. It is removed when the running copy is refused, a registration is there, and no copy
/// LaunchServices knows passes `HelperBundleGate`. A trusted copy may own the registration, because
/// launchd finds the bundle by identifier, so then it stays. An entry that could not be read decides
/// nothing, for this copy or any other: it may be a bundle a pkg install is replacing.
public enum HelperLeftoverRegistration {
    public static func shouldUnregister(
        status: PrivilegedHelperClient.Status, ownTrust: HelperBundleTrust, copies: [HelperBundleTrust]
    ) -> Bool {
        guard status == .enabled || status == .requiresApproval, isDefinitiveRefusal(ownTrust) else { return false }
        return copies.allSatisfy(isDefinitiveRefusal)
    }

    private static func isDefinitiveRefusal(_ trust: HelperBundleTrust) -> Bool {
        switch trust {
        case .trusted, .refused(.unreadable): false
        case .refused: true
        }
    }
}
