import Foundation

/// Mozilla release versions: numeric stable/ESR and `bN` beta sequences.
struct MozillaReleaseVersion {
    let components: [Int]
    let beta: Int?

    init?(_ version: String) {
        guard version.range(of: #"^[0-9]+(?:\.[0-9]+){1,3}(?:b[0-9]+|esr)?$"#,
                            options: .regularExpression) != nil else { return nil }
        let withoutESR = version.hasSuffix("esr") ? String(version.dropLast(3)) : version
        let parts = withoutESR.split(separator: "b", omittingEmptySubsequences: false)
        let numeric = parts[0].split(separator: ".")
        components = numeric.compactMap { Int($0) }
        guard components.count == numeric.count else { return nil }
        if parts.count == 2 {
            guard let beta = Int(parts[1]) else { return nil }
            self.beta = beta
        } else {
            beta = nil
        }
    }
}
