import Testing
@testable import MacUpdaterCore

@Suite("Version display keeps a row's versions short and readable")
struct VersionDisplayTests {
    @Test func aHomebrewBuildHashIsDroppedWhenTheVersionsDiffer() {
        let pair = VersionDisplay.pair(
            from: "6.6395.1,8fc566f7b97e371bae421fc79c260de86c6a4106",
            to: "6.28899.2,155ca43c0ad5a4bd5734795688543b65b464cf47"
        )
        #expect(pair.from == "6.6395.1")
        #expect(pair.to == "6.28899.2")
    }

    @Test func aParenthesisedBuildNumberIsDroppedWhenTheVersionsDiffer() {
        let pair = VersionDisplay.pair(from: "26.1111.71704 (29030)", to: "26.1117.31558 (29513)")
        #expect(pair.from == "26.1111.71704")
        #expect(pair.to == "26.1117.31558")
    }

    @Test func theBuildIsKeptShortWhenOnlyTheBuildDiffers() {
        let pair = VersionDisplay.pair(from: "1.2.0,8fc566f7b97e", to: "1.2.0,155ca43c0ad5")
        #expect(pair.from == "1.2.0 (8fc566f)")
        #expect(pair.to == "1.2.0 (155ca43)")
    }

    @Test func plainVersionsAndPlaceholdersPassThrough() {
        let plain = VersionDisplay.pair(from: "1.2", to: "1.3")
        #expect(plain.from == "1.2")
        #expect(plain.to == "1.3")
        let missing = VersionDisplay.pair(from: "—", to: "2.0")
        #expect(missing.from == "—")
        #expect(missing.to == "2.0")
    }
}
