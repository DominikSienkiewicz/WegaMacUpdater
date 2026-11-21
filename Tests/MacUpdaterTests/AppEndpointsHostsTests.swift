import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Endpoint hosts")
struct AppEndpointsHostsTests {
    /// The fixed hosts only: the update feeds read from installed apps, the npm registry and the
    /// App Store servers are not in `endpoints.json`, and the card says so.
    @Test func theFixedHostsAreEveryHostInTheBundledEndpoints() throws {
        let hosts = try AppEndpoints.loadBundled().connectionHosts
        #expect(hosts == (try hostsParsedFromBundledJSON()), "the same hosts, found without AppEndpoints")
        #expect(hosts == Array(Set(hosts)).sorted(), "unique and sorted")
        #expect(!hosts.contains { $0.contains("passmail") || $0.contains("{") }, "no e-mail, no template text")
        #expect(hosts.count > 20)
    }

    private func hostsParsedFromBundledJSON(file: String = #filePath) throws -> [String] {
        let root = URL(filePath: file, directoryHint: .notDirectory)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Sources/MacUpdaterCore/Resources/endpoints.json", directoryHint: .notDirectory)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String] ?? [:]
        let pattern = try Regex(#"^https?://([^/?:]+)"#)
        let hosts = object.values.compactMap { value in
            value.firstMatch(of: pattern)?.output[1].substring.map(String.init)
        }
        return Array(Set(hosts)).sorted()
    }
}
