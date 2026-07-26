import MacUpdaterCore

/// UX-06 — builds the readiness-screen sentence and the results stamp from the sources a
/// scan actually covers, so neither can drift back to a hardcoded "brew + mas" that quietly
/// omits npm and the manual checkers.
///
/// The source→copy mapping lives at the view layer because it needs `tr(...)`: brew/mas/npm
/// are tool names shared by both languages and stay verbatim, but the manual checkers and
/// the sentence around them are localized.
enum SourceCommunication {
    /// A source's friendly name for the readiness sentence.
    static func readyName(_ source: ScanSource) -> String {
        switch source {
        case .homebrew: return "Homebrew"
        case .appStore: return "Mac App Store"
        case .npm:      return "npm"
        case .manual:   return tr("aplikacje sprawdzane ręcznie")
        }
    }

    /// A source's compact token for the monospaced results stamp.
    static func stampToken(_ source: ScanSource) -> String {
        switch source {
        case .homebrew: return "brew"
        case .appStore: return "mas"
        case .npm:      return "npm"
        case .manual:   return tr("apki")
        }
    }

    /// The readiness-screen sentence naming the sources Wega will check.
    static func readyMessage(for sources: [ScanSource]) -> String {
        trf("Wega zajrzy do %@ i powie, co warto odświeżyć.", joinedNames(sources))
    }

    /// The results-header stamp naming the sources behind the result on screen.
    static func stamp(for sources: [ScanSource]) -> String {
        sources.map(stampToken).joined(separator: " · ")
    }

    /// Joins source names as "A, B oraz C", with a localized final conjunction.
    private static func joinedNames(_ sources: [ScanSource]) -> String {
        let names = sources.map(readyName)
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        let head = names.dropLast().joined(separator: ", ")
        return trf("%@ oraz %@", head, last)
    }
}
