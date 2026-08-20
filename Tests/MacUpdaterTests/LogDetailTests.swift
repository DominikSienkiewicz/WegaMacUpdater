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

    @Test func dropsOutputLinesOnlyWhenSerializedSizeExceeds8000() {
        // Arithmetic: field line = prefix(3) + key(3) + sep(2) + value(2500) = 2508 chars.
        // Three fields = 7524. Marker = 6. Output (40 lines of ~22 chars) = ~861.
        // Separators (43) = 43. Total = 7524 + 6 + 861 + 43 = 8434 > 8000.
        // cappedSerialization must drop output lines to fit under the limit.
        // (With 1500-char values, total is ~5434, which never exceeds 8000.)
        let longValue = String(repeating: "x", count: 2500)
        let detail = LogDetail(fields: [
            .init(key: "cmd", value: longValue),
            .init(key: "sub", value: longValue),
            .init(key: "src", value: longValue),
        ], output: String(repeating: "output line content\n", count: 100))

        let lines = detail.continuationLines
        let serialized = lines.joined(separator: "\n")

        // 1. Serialized length respects the cap
        #expect(serialized.count <= LogDetail.maxSerializedCharacters)

        // 2. Every field line survives — trimming drops output lines only, never fields
        let fieldCount = lines.filter { line in
            line.contains(": ") && !line.contains(LogDetail.outputMarker)
        }.count
        #expect(fieldCount == 3)

        // 3. The marker survives (trimming stops at/before marker, not past it)
        #expect(lines.contains { $0.contains(LogDetail.outputMarker) })

        // 4. Output lines were actually trimmed (regression guard: cappedSerialization
        // must not be a no-op; output after marker is strictly less than the 40-line cap)
        if let markerIndex = lines.firstIndex(of: "\(LogDetail.continuationPrefix)\(LogDetail.outputMarker)") {
            let outputLineCount = lines.count - markerIndex - 1
            #expect(outputLineCount < LogDetail.maxOutputLines)
        }
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

@Suite("LogDetail redaction")
struct LogDetailRedactionTests {

    @Test func redactionReachesBothFieldsAndOutput() {
        let detail = LogDetail(
            fields: [.init(key: "command", value: "cp /Users/ala/Desktop/a.app /Applications")],
            output: "token=ghp_0123456789abcdefghij failed"
        )
        let redacted = detail.redacted(using: LogRedaction.redact)
        #expect(redacted.fields.first?.value.contains("/Users/ala") == false)
        #expect(redacted.fields.first?.value.contains(LogRedaction.pathPlaceholder) == true)
        #expect(redacted.output?.contains("ghp_0123456789abcdefghij") == false)
    }
}
