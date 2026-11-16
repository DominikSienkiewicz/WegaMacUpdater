import Testing
@testable import MacUpdaterCore

@Suite("CleanupVersionMatcher")
struct CleanupVersionMatcherTests {
    struct PinCase: Sendable { let pin: String; let version: String; let expected: Bool }
    struct RangeCase: Sendable { let range: String; let version: String; let expected: Bool? }

    static let pinCases: [PinCase] = [
        PinCase(pin: "3.12", version: "3.12.12", expected: true),
        PinCase(pin: "3.12.12", version: "3.12.12", expected: true),
        PinCase(pin: "3.1", version: "3.12.0", expected: false),
        PinCase(pin: "3.12.1", version: "3.12.12", expected: false),
        PinCase(pin: "20", version: "20.1.0", expected: true),
        PinCase(pin: "2", version: "20.1.0", expected: false),
        PinCase(pin: "v20", version: "20.1.0", expected: true),
        PinCase(pin: "v20.1.0", version: "v20.1.0", expected: true),
        PinCase(pin: "18.x", version: "18.20.4", expected: true),
        PinCase(pin: "18.X", version: "18.20.4", expected: true),
        PinCase(pin: "18.*", version: "19.0.0", expected: false),
        PinCase(pin: "18.2.x", version: "18.2.9", expected: true),
        PinCase(pin: "18.2.x", version: "18.3.0", expected: false),
        PinCase(pin: "stable", version: "stable", expected: true),
        PinCase(pin: "stable", version: "stable-aarch64-apple-darwin", expected: true),
        PinCase(pin: "stable", version: "stable2", expected: false),
        PinCase(pin: "stable", version: "nightly", expected: false),
        PinCase(pin: "21.0.2-tem", version: "21.0.2-tem", expected: true),
        PinCase(pin: "21.0.2-tem", version: "21.0.2-zulu", expected: false),
        PinCase(pin: "myenv", version: "myenv", expected: true),
        PinCase(pin: "3.12", version: "stable", expected: false),
        PinCase(pin: "", version: "3.12.0", expected: false),
        PinCase(pin: "x", version: "3.12.0", expected: false),
        PinCase(pin: "99999999999999999999999", version: "1.0.0", expected: false)
    ]

    static let rangeCases: [RangeCase] = [
        RangeCase(range: ">=3.10,<3.13", version: "3.12.12", expected: true),
        RangeCase(range: ">=3.10,<3.13", version: "3.13.0", expected: false),
        RangeCase(range: ">=3.10, <3.13", version: "3.9.9", expected: false),
        RangeCase(range: ">=18", version: "18.0.0", expected: true),
        RangeCase(range: ">= 18", version: "17.9.0", expected: false),
        RangeCase(range: ">18", version: "18.20.4", expected: false),
        RangeCase(range: ">18", version: "19.0.0", expected: true),
        RangeCase(range: ">18.1.0", version: "18.1.1", expected: true),
        RangeCase(range: ">18.1.0", version: "18.1.0", expected: false),
        RangeCase(range: "<=18", version: "18.20.4", expected: true),
        RangeCase(range: "<=18", version: "19.0.0", expected: false),
        RangeCase(range: "<=18.1.0", version: "18.1.1", expected: false),
        RangeCase(range: "<18", version: "17.9.9", expected: true),
        RangeCase(range: "<18", version: "18.0.0", expected: false),
        RangeCase(range: "==3.12.*", version: "3.12.7", expected: true),
        RangeCase(range: "==3.12.*", version: "3.13.0", expected: false),
        RangeCase(range: "==3.12.1", version: "3.12.1", expected: true),
        RangeCase(range: "==3.12.1", version: "3.12.2", expected: false),
        RangeCase(range: "==3.12", version: "3.12.0", expected: true),
        RangeCase(range: "=20.1.0", version: "20.1.0", expected: true),
        RangeCase(range: "=20", version: "20.5.0", expected: true),
        RangeCase(range: "!=3.11.*", version: "3.11.4", expected: false),
        RangeCase(range: "!=3.11.*", version: "3.12.0", expected: true),
        RangeCase(range: ">=3.10,!=3.11.*", version: "3.11.2", expected: false),
        RangeCase(range: "!=3.12.1", version: "3.12.1", expected: false),
        RangeCase(range: "~=3.10", version: "3.10.0", expected: true),
        RangeCase(range: "~=3.10", version: "3.12.4", expected: true),
        RangeCase(range: "~=3.10", version: "4.0.0", expected: false),
        RangeCase(range: "~=3.10", version: "3.9.9", expected: false),
        RangeCase(range: "~=3.10.2", version: "3.10.5", expected: true),
        RangeCase(range: "~=3.10.2", version: "3.11.0", expected: false),
        RangeCase(range: "~=3.10.2", version: "3.10.1", expected: false),
        RangeCase(range: "~=3", version: "3.1.0", expected: nil),
        RangeCase(range: "~=3.*", version: "3.1.0", expected: nil),
        RangeCase(range: "^20.0.0", version: "20.18.1", expected: true),
        RangeCase(range: "^20.0.0", version: "21.0.0", expected: false),
        RangeCase(range: "^20.0.0", version: "19.9.9", expected: false),
        RangeCase(range: "^0.2.3", version: "0.2.9", expected: true),
        RangeCase(range: "^0.2.3", version: "0.3.0", expected: false),
        RangeCase(range: "^0.0.3", version: "0.0.3", expected: true),
        RangeCase(range: "^0.0.3", version: "0.0.4", expected: false),
        RangeCase(range: "^0.x", version: "0.9.0", expected: true),
        RangeCase(range: "^0.x", version: "1.0.0", expected: false),
        RangeCase(range: "^1.x", version: "1.9.0", expected: true),
        RangeCase(range: "^1.x", version: "2.0.0", expected: false),
        RangeCase(range: "^18", version: "18.9.0", expected: true),
        RangeCase(range: "^18", version: "19.0.0", expected: false),
        RangeCase(range: "~18.2", version: "18.2.7", expected: true),
        RangeCase(range: "~18.2", version: "18.3.0", expected: false),
        RangeCase(range: "~18.2", version: "18.1.9", expected: false),
        RangeCase(range: "~18.2.3", version: "18.2.2", expected: false),
        RangeCase(range: "~18.2.3", version: "18.2.3", expected: true),
        RangeCase(range: "~18", version: "18.9.0", expected: true),
        RangeCase(range: "~18", version: "19.0.0", expected: false),
        RangeCase(range: "18.x || 20.x", version: "20.4.0", expected: true),
        RangeCase(range: "18.x || 20.x", version: "19.4.0", expected: false),
        RangeCase(range: "18.x || 20.x", version: "18.0.1", expected: true),
        RangeCase(range: ">=18 <21", version: "20.9.0", expected: true),
        RangeCase(range: ">=18 <21", version: "21.0.0", expected: false),
        RangeCase(range: ">=18 <21 || ^22", version: "22.3.0", expected: true),
        RangeCase(range: "20", version: "20.1.0", expected: true),
        RangeCase(range: "20", version: "21.0.0", expected: false),
        RangeCase(range: "3.12.*", version: "3.12.3", expected: true),
        RangeCase(range: "20.x", version: "20.0.0", expected: true),
        RangeCase(range: "20.x", version: "21.0.0", expected: false),
        RangeCase(range: "v20.1.0", version: "20.1.0", expected: true),
        RangeCase(range: "*", version: "1.2.3", expected: true),
        RangeCase(range: ">=3.14", version: "3.14.0rc1", expected: true),
        RangeCase(range: "<3.14.1", version: "3.14.0rc1", expected: true),
        RangeCase(range: ">=3.12", version: "3.14.0rc1", expected: true),
        RangeCase(range: ">=3.14.0rc1", version: "3.14.0", expected: true),
        RangeCase(range: ">=1.0.0-beta.1", version: "1.0.0", expected: true),
        RangeCase(range: ">=3.10", version: "stable", expected: false),
        RangeCase(range: ">=3.10", version: "", expected: false),
        RangeCase(range: "whatever", version: "3.12.0", expected: nil),
        RangeCase(range: ">= ", version: "3.12.0", expected: nil),
        RangeCase(range: "^", version: "3.12.0", expected: nil),
        RangeCase(range: "", version: "3.12.0", expected: nil),
        RangeCase(range: "||", version: "3.12.0", expected: nil),
        RangeCase(range: ">=18 ||", version: "20.0.0", expected: nil),
        RangeCase(range: "1 - 2", version: "1.5.0", expected: nil),
        RangeCase(range: "18.x || whatever", version: "18.1.0", expected: nil),
        RangeCase(range: ">=99999999999999999999", version: "1.0.0", expected: nil),
        RangeCase(range: ">=1", version: "99999999999999999999.0.0", expected: false)
    ]

    @Test("pin matching follows prefix and name rules", arguments: pinCases)
    func pinMatching(_ testCase: PinCase) {
        #expect(
            CleanupVersionMatcher.pin(testCase.pin, matches: testCase.version) == testCase.expected,
            "pin \(testCase.pin) vs \(testCase.version)"
        )
    }

    @Test("range matching covers PEP 440 and npm grammars", arguments: rangeCases)
    func rangeMatching(_ testCase: RangeCase) {
        #expect(
            CleanupVersionMatcher.range(testCase.range, isSatisfiedBy: testCase.version) == testCase.expected,
            "range \(testCase.range) vs \(testCase.version)"
        )
    }
}
