import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("LogDetail")
struct LogDetailTests {

    @Test func serializesFieldsAndOutputWithTheContinuationPrefix() {
        let detail = LogDetail(command: "brew upgrade --cask foo", exitCode: 1, stderr: "boom\nsecond")
        #expect(detail?.continuationLines == [
            "\t| command: brew upgrade --cask foo",
            "\t| exit: 1",
            "\t| ---",
            "\t| boom",
            "\t| second",
        ])
    }

    @Test func roundTripsThroughContinuationLines() throws {
        let original = try #require(LogDetail(
            command: "/usr/bin/env brew",
            exitCode: 2,
            stderr: "Error: something: with a colon",
            subject: "foo",
            source: "cask"
        ))
        #expect(LogDetail.parse(continuationLines: original.continuationLines) == original)
    }

    @Test func outputContainingTheFieldSeparatorIsNotMistakenForAField() {
        let detail = LogDetail(fields: [], output: "key: value")
        let parsed = LogDetail.parse(continuationLines: detail.continuationLines)
        #expect(parsed?.fields.isEmpty == true)
        #expect(parsed?.output == "key: value")
    }

    @Test func keepsTheTailOfAnOverlongOutput() throws {
        let lines = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let detail = LogDetail(fields: [], output: lines)
        let kept = try #require(detail.output).split(separator: "\n")
        #expect(kept.count == LogDetail.maxOutputLines)
        #expect(kept.last == "line 200", "the tail matters — the failure is at the end")
    }

    @Test func capsOutputCharacterCount() {
        let detail = LogDetail(fields: [], output: String(repeating: "x", count: 10_000))
        #expect((detail.output ?? "").count <= LogDetail.maxOutputCharacters)
    }

    @Test func capsTheWholeSerializedDetail() {
        let fat = (1...100).map { _ in String(repeating: "y", count: 200) }.joined(separator: "\n")
        let detail = LogDetail(fields: [.init(key: "command", value: "brew")], output: fat)
        #expect(detail.continuationLines.joined(separator: "\n").count <= LogDetail.maxSerializedCharacters)
    }

    @Test func flattensNewlinesInsideAFieldValue() {
        let detail = LogDetail(fields: [.init(key: "command", value: "a\nb")], output: nil)
        #expect(detail.continuationLines == ["\t| command: a b"])
    }

    @Test func emptyInputParsesToNil() {
        #expect(LogDetail.parse(continuationLines: []) == nil)
    }

    @Test func aDetailWithNeitherFieldsNorOutputIsNil() {
        #expect(LogDetail(command: nil, exitCode: nil, stderr: nil) == nil)
    }
}
