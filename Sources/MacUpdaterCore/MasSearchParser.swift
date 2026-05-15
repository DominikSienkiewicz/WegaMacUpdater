import Foundation

// Version is intentionally omitted — only ID and name are needed for matching.
public struct MasSearchResult: Equatable, Sendable {
    public let appStoreID: String
    public let name: String

    public init(appStoreID: String, name: String) {
        self.appStoreID = appStoreID
        self.name = name
    }
}

public struct MasSearchParser {
    private static let lineRegex = try? NSRegularExpression(pattern: #"^(\d+)\s+(.+?)\s{2,}\S.*$"#)

    public init() {}

    public func parse(_ output: String) -> [MasSearchResult] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private func parseLine(_ line: String) -> MasSearchResult? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let regex = Self.lineRegex else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
              match.numberOfRanges == 3 else { return nil }

        let id   = substring(in: trimmed, range: match.range(at: 1))
        let name = substring(in: trimmed, range: match.range(at: 2))
        guard !id.isEmpty, !name.isEmpty else { return nil }

        return MasSearchResult(appStoreID: id, name: name)
    }

    private func substring(in value: String, range: NSRange) -> String {
        guard range.location != NSNotFound,
              let swiftRange = Range(range, in: value) else { return "" }
        return String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
