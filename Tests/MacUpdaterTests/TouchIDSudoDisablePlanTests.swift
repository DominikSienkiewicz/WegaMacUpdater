import Foundation
import Testing
@testable import WegaHelperKit

/// Which lines turning Touch ID for `sudo` off removes from `sudo_local`, decided on bytes alone.
///
/// Only a line byte for byte equal to the directive goes, and only when every other line is blank
/// or a full comment, so the file that remains means what Apple's template means: nothing.
@Suite("Turning off Touch ID for sudo: what is removed")
struct TouchIDSudoDisablePlanTests {
    let wega = TouchIDSudoConfigurator.pamDirective
    let template = "# sudo_local: local config file which survives system update and is included for sudo\n"
        + "# uncomment following line to enable Touch ID for sudo\n"
        + "#auth       sufficient     pam_tid.so\n"

    private func plan(_ text: String) -> TouchIDSudoDisablePlan {
        TouchIDSudoConfigurator.contentsDisablingTouchID(current: Data(text.utf8))
    }

    private func removal(_ text: String, lines: Int) -> TouchIDSudoDisablePlan {
        .remove(lines: lines, contents: Data(text.utf8))
    }

    // MARK: - Removed

    @Test func theTemplateWithTheDirectiveBecomesExactlyTheTemplate() {
        #expect(plan(template + wega + "\n") == removal(template, lines: 1))
        #expect(plan(wega + "\n") == removal("", lines: 1), "an empty file, never a deleted one")
        #expect(plan(wega) == removal("", lines: 1))
        #expect(plan(wega + "\n# c\n" + wega + "\n") == removal("# c\n", lines: 2), "every copy goes")
        #expect(plan("# c\n" + wega) == removal("# c\n", lines: 1), "a last directive without its newline leaves the comment's")
    }

    @Test func blankLinesAndCommentsStayByteForByte() {
        let kept = "\n   \n\t\n   # komentarz\n\r# komentarz\n\u{0B}\u{0C}# x\n#auth sufficient pam_tid.so\n"
        #expect(plan(kept + wega + "\n") == removal(kept, lines: 1))
        #expect(plan(wega + "\n" + kept) == removal(kept, lines: 1))
    }

    // MARK: - Nothing to remove

    @Test func aVariantAloneIsNotTheDirective() {
        let variants = [
            "auth\tsufficient\tpam_tid.so", wega + "\r", "AUTH       sufficient     pam_tid.so",
            "auth sufficient pam_tid.so", wega + ".2", wega + " # x", " " + wega, "#" + wega, wega + " ",
        ]
        #expect(plan(template) == .nothingToRemove)
        #expect(plan("") == .nothingToRemove)
        for variant in variants {
            #expect(plan(template + variant + "\n") == .nothingToRemove, "\(variant.debugDescription)")
            #expect(plan(variant + "\r\n") == .nothingToRemove, "\(variant.debugDescription)")
        }
    }

    // MARK: - Refused: other active lines (RC1)

    @Test func anyOtherActiveLineRefusesTheRemoval() {
        let others = [
            "auth       required       pam_deny.so",
            "auth       optional       /opt/homebrew/lib/pam/pam_reattach.so",
            "auth\tsufficient\tpam_tid.so",
            "account    required       pam_permit.so",
            wega + "\r",
            "AUTH       sufficient     pam_tid.so",
        ]
        for other in others {
            #expect(plan(wega + "\n" + other + "\n") == .refused(.otherDirectivesPresent), "\(other.debugDescription)")
            #expect(plan(other + "\n" + wega + "\n") == .refused(.otherDirectivesPresent), "\(other.debugDescription)")
            #expect(plan(template + other + "\n" + wega) == .refused(.otherDirectivesPresent), "\(other.debugDescription)")
        }
    }

    // MARK: - Refused: backslash anywhere (RC2)

    @Test func aBackslashAnywhereRefusesTheRemoval() {
        #expect(plan("\\ # c\n" + wega + "\n") == .refused(.lineContinuation), "a continued line before the directive")
        #expect(plan("# a \\ b\n" + wega + "\n") == .refused(.lineContinuation), "inside a comment")
        #expect(plan(wega + "\n# c \\") == .refused(.lineContinuation), "in the last line")
        #expect(plan("# a\\b\n" + wega + "\n") == .refused(.lineContinuation), "in the middle of a line")
        #expect(plan("# \\\n" + template) == .nothingToRemove, "without the directive there is nothing to refuse")
        #expect(plan("\\\nauth required pam_deny.so\n" + wega + "\n") == .refused(.lineContinuation),
                "a backslash is decided before the other lines, whose ends it makes uncertain")
    }

    // MARK: - Refused: unreadable, too large

    @Test func unreadableAndOversizedFilesAreRefused() {
        #expect(TouchIDSudoConfigurator.contentsDisablingTouchID(current: Data([0xFF, 0xFE, 0x0A]) + Data(wega.utf8))
                == .refused(.unreadable), "not UTF-8")
        #expect(TouchIDSudoConfigurator.contentsDisablingTouchID(current: Data((wega + "\n").utf8) + Data([0x00]))
                == .refused(.unreadable), "a NUL byte")
        #expect(TouchIDSudoConfigurator.contentsDisablingTouchID(current: Data([0xC0, 0xAF])) == .refused(.unreadable),
                "an overlong encoding")

        let head = wega + "\n#"
        let largest = head + String(repeating: "x", count: TouchIDSudoDisabler.maximumSize - head.utf8.count - 1) + "\n"
        #expect(largest.utf8.count == 65_536)
        #expect(plan(largest) == removal(String(largest.dropFirst(wega.count + 1)), lines: 1))
        #expect(plan(largest + "\n") == .refused(.tooLarge), "65 537 bytes")
    }

    // MARK: - Properties (a)–(f)

    /// A fixed generator over blank lines, comments and the directive, so every run checks the
    /// same few hundred files.
    @Test func theRemovalKeepsItsPropertiesOverADeterministicCorpus() {
        let pool = [wega, "", "   ", "# c", "\t# t", "\r# r", "#" + wega, "#auth sufficient pam_tid.so", " # s"]
        var generator = FixedGenerator(seed: 0x5EED)
        var removals = 0
        for _ in 0..<600 {
            let lines = (0..<generator.next(below: 9)).map { _ in pool[generator.next(below: pool.count)] }
            let text = lines.joined(separator: "\n") + (generator.next(below: 2) == 0 ? "" : "\n")
            let input = Data(text.utf8)
            let hits = referenceLines(input).filter { $0.elementsEqual(wega.utf8) }.count
            guard case .remove(let count, let output) = TouchIDSudoConfigurator.contentsDisablingTouchID(current: input) else {
                #expect(hits == 0, "\(text.debugDescription)")
                continue
            }
            removals += 1
            #expect(referenceLines(output) == referenceLines(input).filter { !$0.elementsEqual(wega.utf8) },
                    "(a) \(text.debugDescription)")
            #expect(count == hits, "(b) \(text.debugDescription)")
            #expect(TouchIDSudoConfigurator.contentsDisablingTouchID(current: output) == .nothingToRemove,
                    "(c) \(text.debugDescription)")
            #expect(isSubsequence(output, of: input), "(d) \(text.debugDescription)")
            #expect(referenceLines(output).allSatisfy(isBlankOrComment), "(f) \(text.debugDescription)")
        }
        #expect(removals > 100, "the corpus must exercise removals")
    }

    /// (e): turning Touch ID on and off again gives back a file of blank lines and comments exactly.
    @Test func enablingThenDisablingGivesBackTheFile() {
        let pool = ["", "   ", "# c", "\t# t", "#" + wega, "#auth sufficient pam_tid.so", " # s"]
        var generator = FixedGenerator(seed: 0xE)
        for _ in 0..<300 {
            let lines = (0..<generator.next(below: 7)).map { _ in pool[generator.next(below: pool.count)] + "\n" }
            let original = lines.joined()
            let enabled = TouchIDSudoConfigurator.contentsEnablingTouchID(current: original)
            #expect(plan(enabled) == removal(original, lines: 1), "\(original.debugDescription)")
        }
    }

    // MARK: - Reference

    /// A plain split, independent of the implementation's own line reader.
    private func referenceLines(_ data: Data) -> [ArraySlice<UInt8>] {
        var lines = [UInt8](data).split(separator: 0x0A, omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    private func isBlankOrComment(_ line: ArraySlice<UInt8>) -> Bool {
        guard let first = line.first(where: { ![0x20, 0x09, 0x0B, 0x0C, 0x0D].contains($0) }) else { return true }
        return first == 0x23
    }

    private func isSubsequence(_ needle: Data, of haystack: Data) -> Bool {
        var remaining = haystack[...]
        for byte in needle {
            guard let index = remaining.firstIndex(of: byte) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }
}

/// A linear congruential generator: the same sequence on every run and every machine.
struct FixedGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}
