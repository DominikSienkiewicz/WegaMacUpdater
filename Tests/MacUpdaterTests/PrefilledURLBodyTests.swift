import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("PrefilledURLBody")
struct PrefilledURLBodyTests {

    @Test func encodesEverythingOutsideTheUnreservedSet() {
        #expect(PrefilledURLBody.percentEncoded("a b&c#d/e?f:g+h") ==
                "a%20b%26c%23d%2Fe%3Ff%3Ag%2Bh")
    }

    @Test func leavesUnreservedCharactersAlone() {
        #expect(PrefilledURLBody.percentEncoded("aZ0-._~") == "aZ0-._~")
    }

    @Test func truncationNeverSplitsAPercentTriplet() {
        let raw = String(repeating: "ł", count: 50)   // każdy znak koduje się na %C5%82
        for limit in 0...60 {
            let encoded = PrefilledURLBody.truncatedEncoded(raw, toEncodedLength: limit)
            #expect(encoded.count <= limit)
            #expect(encoded.count % 6 == 0, "granica musi wypadać na całym znaku")
        }
    }

    @Test func truncationKeepsTheLongestFittingPrefix() {
        #expect(PrefilledURLBody.truncatedEncoded("abcdef", toEncodedLength: 4) == "abcd")
    }
}
