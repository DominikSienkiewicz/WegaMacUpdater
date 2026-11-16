import Foundation

/// Joins the notes an uninstall run can leave behind so none overwrites another.
enum UninstallOutcomeMessage {
    static func compose(failure: String?, leftoverNote: String?, skippedNames: [String]) -> String? {
        let skippedNote = skippedNames.isEmpty ? nil : trf(
            "Pominięto, bo aplikacja nadal działa lub jej proces jest niejednoznaczny: %@",
            skippedNames.joined(separator: ", ")
        )
        let parts = [failure, leftoverNote, skippedNote].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
