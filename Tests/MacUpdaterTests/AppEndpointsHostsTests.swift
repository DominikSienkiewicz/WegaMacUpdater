import Testing
@testable import MacUpdaterCore

@Suite("Endpoint hosts")
struct AppEndpointsHostsTests {
    @Test func theFullListIsEveryHostWegaUses() {
        let hosts = AppEndpoints.shared.connectionHosts
        for host in ["api.github.com", "raw.githubusercontent.com", "formulae.brew.sh", "data.services.jetbrains.com"] {
            #expect(hosts.contains(host), "\(host)")
        }
        #expect(hosts == Array(Set(hosts)).sorted(), "unique and sorted")
        #expect(!hosts.contains { $0.contains("passmail") || $0.contains("{") }, "no e-mail, no template text")
    }
}
