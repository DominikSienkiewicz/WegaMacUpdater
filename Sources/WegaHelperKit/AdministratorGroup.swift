import Darwin.membership
import Foundation

/// Membership of the macOS `admin` group, the gate for asking the helper to remove an app.
public enum AdministratorGroup {
    private static let adminGroupID: gid_t = 80

    /// Fails closed: any lookup error reads as "not an administrator".
    public static func contains(uid: uid_t) -> Bool {
        var userUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        var groupUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        guard mbr_uid_to_uuid(uid, &userUUID) == 0,
              mbr_gid_to_uuid(adminGroupID, &groupUUID) == 0 else {
            return false
        }
        var isMember: Int32 = 0
        guard mbr_check_membership(&userUUID, &groupUUID, &isMember) == 0 else { return false }
        return isMember != 0
    }
}
