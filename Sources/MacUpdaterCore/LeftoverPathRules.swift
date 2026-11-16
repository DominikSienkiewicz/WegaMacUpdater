import Darwin
import Foundation

/// Pure rules deciding which home-relative paths may ever be offered for the Trash.
enum LeftoverPathRules {
    private static let protectedRoots: [[String]] = [
        ["Desktop"], ["Documents"], ["Downloads"], ["Pictures"], ["Movies"], ["Music"], ["Public"],
        ["Library", "Mobile Documents"], ["Library", "CloudStorage"], ["Library", "Mail"],
        ["Library", "Messages"], ["Library", "Safari"], ["Library", "Keychains"],
    ]

    private static let droppedLibraryFolders: [String] = [
        "LaunchAgents", "Internet Plug-Ins", "Audio", "Services", "QuickLook", "PreferencePanes",
        "Fonts", "Input Methods", "Screen Savers", "Spotlight", "ColorPickers",
        "Contextual Menu Items", "Extensions",
    ]

    private static let applePrefix = "com.apple."
    static let recentDocumentsFolder = [
        "Library", "Application Support", "com.apple.sharedfilelist",
        "com.apple.LSSharedFileList.ApplicationRecentDocuments",
    ]

    private static let minimumLiteralScalarsInPattern = 3
    private static let slash: Unicode.Scalar = "/"
    private static let wildcardScalars = Set("*?[".unicodeScalars)
    private static let forbiddenScalars = Set("{}".unicodeScalars)

    /// Home-relative components of a `~/…` zap entry, or nil when the entry is not safely expressible.
    /// Every syntactic check runs on Unicode scalars: the filesystem splits on the `/` scalar even where
    /// a combining mark or prepended character would glue it to its neighbour as one `Character`.
    static func zapComponents(_ entry: String) -> [String]? {
        let scalars = Array(entry.unicodeScalars)
        guard scalars.starts(with: "~/".unicodeScalars) else { return nil }
        var parts = scalars.dropFirst(2).split(separator: slash, omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        let components = parts.map { String(String.UnicodeScalarView($0)) }
        for (index, component) in components.enumerated() {
            guard isWellFormed(component) else { return nil }
            let scalars = component.unicodeScalars
            if scalars.contains(where: forbiddenScalars.contains) { return nil }
            if hasDoubleStar(component) { return nil }
            if hasWildcard(component) {
                guard index == components.count - 1, hasEnoughLiterals(component) else { return nil }
            }
        }
        return components
    }

    static func isOfferable(_ components: [String]) -> Bool {
        guard components.allSatisfy(isWellFormed) else { return false }
        if let last = components.last, hasWildcard(last), !hasEnoughLiterals(last) { return false }
        let minimumDepth = equals(components.first, "Library") ? 3 : 2
        guard components.count >= minimumDepth else { return false }
        guard !protectedRoots.contains(where: { startsWith(components, $0) }) else { return false }
        if components.count >= 2, equals(components[0], "Library"),
           droppedLibraryFolders.contains(where: { equals(components[1], $0) }) {
            return false
        }
        if components.contains(where: containsApplePrefix) {
            return isRecentDocumentsFile(components)
        }
        return true
    }

    private static func isWellFormed(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        if scalars.isEmpty || scalars == ["."] || scalars == [".", "."] { return false }
        return !scalars.contains { $0 == slash || $0.value == 0 }
    }

    private static func hasDoubleStar(_ component: String) -> Bool {
        let scalars = Array(component.unicodeScalars)
        return zip(scalars, scalars.dropFirst()).contains { $0 == "*" && $1 == "*" }
    }

    /// Literal scalars outside `*`, `?` and `[…]`; bracket contents do not count.
    private static func hasEnoughLiterals(_ pattern: String) -> Bool {
        var literals = 0
        var insideBracket = false
        for scalar in pattern.unicodeScalars {
            switch scalar {
            case "[": insideBracket = true
            case "]": insideBracket = false
            case "*", "?": break
            default: if !insideBracket { literals += 1 }
            }
        }
        return literals >= minimumLiteralScalarsInPattern
    }

    private static func containsApplePrefix(_ component: String) -> Bool {
        component.range(of: applePrefix, options: .caseInsensitive) != nil
    }

    static func isInsideLibrary(_ components: [String]) -> Bool {
        equals(components.first, "Library")
    }

    static func hasWildcard(_ component: String) -> Bool {
        component.unicodeScalars.contains(where: wildcardScalars.contains)
    }

    static func matches(pattern: String, name: String) -> Bool {
        fnmatch(pattern, name, FNM_PERIOD | FNM_CASEFOLD) == 0
    }

    /// Case-folded, NFC-normalised join used for every path comparison.
    static func key(_ components: [String]) -> String {
        components.map(fold).joined(separator: "/")
    }

    private static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
            .precomposedStringWithCanonicalMapping
    }

    private static func isRecentDocumentsFile(_ components: [String]) -> Bool {
        guard components.count == recentDocumentsFolder.count + 1,
              startsWith(components, recentDocumentsFolder) else { return false }
        let file = components[components.count - 1]
        return matches(pattern: "*.sfl*", name: file) && !containsApplePrefix(file)
    }

    private static func startsWith(_ components: [String], _ root: [String]) -> Bool {
        components.count >= root.count && zip(components, root).allSatisfy { equals($0, $1) }
    }

    private static func equals(_ lhs: String?, _ rhs: String) -> Bool {
        lhs.map(fold) == fold(rhs)
    }
}
