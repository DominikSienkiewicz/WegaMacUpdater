import Foundation

/// Only observed text formats are accepted. Microsoft documents the plist flag, not its schema.
enum MicrosoftAutoUpdateOutput {
    private static let productNames = [
        "MSWD2019": "Word", "XCEL2019": "Excel", "PPT32019": "PowerPoint",
        "OPIM2019": "Outlook", "ONMC2019": "OneNote",
    ]

    static func parse(_ result: ProcessResult) -> MicrosoftAutoUpdateReport {
        guard result.exitCode == 0, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.stdout.contains("No result returned from Update Assistant") else { return .init(status: .failed) }
        let progress = Set(["Checking for updates...", "Update Assistant: Idle", "Update Assistant: Checking"])
        var text = result.stdout.replacingOccurrences(of: "\u{001B}[2K", with: "")
            .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !progress.contains($0) }.joined(separator: " ")
        if text.hasPrefix("Checking for updates... ") { text.removeFirst("Checking for updates... ".count) }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if text == "No updates available" { return .init(status: .noUpdatesReported) }
        guard text.hasPrefix("Updates available:") else { return .init(status: .unrecognizedOutput) }
        text = String(text.dropFirst("Updates available:".count)).trimmingCharacters(in: .whitespaces)
        guard let offers = offers(in: text) else { return .init(status: .unrecognizedOutput) }
        return .init(status: .updatesReported, offers: offers)
    }

    static func isNumericVersion(_ version: String) -> Bool {
        version.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}$"#, options: .regularExpression) != nil
    }

    private static func offers(in text: String) -> [MicrosoftAutoUpdateOffer]? {
        let pattern = #"([A-Z][A-Z0-9]{3,20}) ([A-Za-z][A-Za-z ]*?) Update ([0-9]+(?:\.[0-9]+){1,3})(?: \(([0-9]{8})\))?(?= |$)"#
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        var end = 0
        var seen: Set<String> = []
        var offers: [MicrosoftAutoUpdateOffer] = []
        for match in matches {
            guard source.substring(with: NSRange(location: end, length: match.range.location - end))
                .trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            end = NSMaxRange(match.range)
            let applicationID = source.substring(with: match.range(at: 1))
            guard seen.insert(applicationID).inserted else { return nil }
            guard let name = productNames[applicationID] else { continue }
            guard source.substring(with: match.range(at: 2)) == name else { return nil }
            let buildRange = match.range(at: 4)
            offers.append(.init(applicationID: applicationID, version: source.substring(with: match.range(at: 3)),
                build: buildRange.location == NSNotFound ? nil : source.substring(with: buildRange)))
        }
        guard end == source.length else { return nil }
        return offers
    }
}
