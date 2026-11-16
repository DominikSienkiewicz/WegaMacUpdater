import Foundation
import Testing
@testable import MacUpdaterCore

@Suite
struct CaskZapPathsTests {
    @Test
    func readsTrashAndDeleteInBothSpellings() throws {
        let json = """
        [{"zap":[{"trash":["~/Library/A","~/Library/B"],"delete":"~/Library/C","rmdir":"~/Library/D","launchctl":"x"}]},
         {"uninstall":[{"delete":"/Applications/X.app"}]}]
        """
        let artifacts = try JSONDecoder().decode([JSONValue].self, from: Data(json.utf8))

        #expect(CaskArtifacts.zapTrashPaths(in: artifacts) == ["~/Library/A", "~/Library/B", "~/Library/C"])
    }

    @Test
    func decodesZapPathsFromHomebrewJSON() throws {
        let json = """
        {"token":"obsidian","name":["Obsidian"],
         "artifacts":[{"zap":[{"trash":["~/Library/Application Support/obsidian"]}]}]}
        """
        let cask = try JSONDecoder().decode(BrewCask.self, from: Data(json.utf8))

        #expect(cask.zapTrashPaths == ["~/Library/Application Support/obsidian"])
    }

    @Test
    func roundTripsZapPathsThroughCacheShape() throws {
        let cask = BrewCask(token: "t", name: [], zapTrashPaths: ["~/x/y"])
        let data = try JSONEncoder().encode(cask)

        #expect(try JSONDecoder().decode(BrewCask.self, from: data) == cask)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["zapTrashPaths"] != nil)
        #expect(object["artifacts"] == nil)
    }

    @Test
    func cacheFileIsVersionFour() {
        #expect(AppScanDirectories.caskDatabaseCacheURL.lastPathComponent == "casks-v4.json")
    }
}
