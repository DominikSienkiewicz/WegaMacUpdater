import Foundation

public struct MasOutdatedParser {
    public init() {}

    public func parse(_ output: String) -> [MasOutdatedApp] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { parseLine(String($0)) }
    }

    private func parseLine(_ line: String) -> MasOutdatedApp? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"^(\d+)\s+(.+?)\s+\((?:(.*?)\s*->\s*)?(.*?)\)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges == 5 else {
            return nil
        }

        let id = substring(in: trimmed, range: match.range(at: 1))
        let name = substring(in: trimmed, range: match.range(at: 2))
        let installed = substring(in: trimmed, range: match.range(at: 3)).nilIfEmpty
        let current = substring(in: trimmed, range: match.range(at: 4)).nilIfEmpty

        return MasOutdatedApp(
            appStoreID: id,
            name: name,
            installedVersion: installed,
            currentVersion: current
        )
    }

    private func substring(in value: String, range: NSRange) -> String {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: value) else {
            return ""
        }
        return String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
