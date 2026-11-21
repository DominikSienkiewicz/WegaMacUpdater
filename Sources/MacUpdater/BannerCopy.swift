import Foundation
import MacUpdaterCore

enum BannerCopy {
    struct FailureText: Equatable { let message: String; let fullMessage: String? }

    /// At most three names; more read "A, B i N inne" and carry the full list.
    static func names(_ names: [String]) -> (short: String, full: String?) {
        guard names.count > 3 else { return (names.joined(separator: ", "), nil) }
        let short = names.prefix(2).joined(separator: ", ") + " " + trp("i %@ innych", names.count - 2)
        return (short, names.joined(separator: ", "))
    }

    /// For failures a button resolves: the permission comes first, and neither the log nor a
    /// retry is mentioned, because a retry fails again until the permission is granted.
    static func permissionNeeded(names: [String]) -> FailureText {
        guard !names.isEmpty else {
            return FailureText(
                message: tr("Nie zaktualizowałam części pakietów — macOS potrzebuje Twojej zgody."), fullMessage: nil)
        }
        let template = "Nie zaktualizowałam: %@ — macOS potrzebuje Twojej zgody."
        let (short, full) = Self.names(names)
        return FailureText(message: trf(template, short), fullMessage: full.map { trf(template, $0) })
    }
}
