import Foundation

/// Decides whether an installed runtime version satisfies a pin or range read from a
/// project file. Pure and total: untrusted text never traps, it just fails to match
/// (`false`) or fails to parse (`nil`).
public enum CleanupRangeGrammar: Sendable {
    /// `requires-python`: `>V` and `<=V` compare against V zero-padded.
    case pep440
    /// npm semver: a partial `>V` / `<=V` is an x-range (`>18` means `>=19.0.0`).
    case npm
}

public enum CleanupVersionMatcher {
    /// Components above this bound are treated as unparseable, so later `+ 1` cannot overflow.
    private static let componentLimit = 1_000_000_000_000

    public static func pin(_ pin: String, matches version: String) -> Bool {
        if let operand = numericOperand(pin) {
            let installed = installedComponents(version)
            return operand.isEmpty || (!installed.isEmpty && hasPrefix(installed, operand))
        }
        guard !pin.isEmpty else { return false }
        return version == pin || version.hasPrefix(pin + "-")
    }

    /// Dotted numbers, with an optional leading `v` and a trailing wildcard: `pin(_:matches:)`
    /// compares such a pin component by component. Any other pin must name a version exactly.
    public static func isVersionNumber(_ pin: String) -> Bool {
        numericOperand(pin) != nil
    }

    /// `nil` means the range could not be parsed.
    public static func range(_ range: String, isSatisfiedBy version: String, grammar: CleanupRangeGrammar) -> Bool? {
        var clauses: [[Comparator]] = []
        for rawClause in range.components(separatedBy: "||") {
            guard let clause = parseClause(rawClause, grammar: grammar) else { return nil }
            clauses.append(clause)
        }
        let installed = installedComponents(version)
        guard !installed.isEmpty else { return false }
        return clauses.contains { clause in clause.allSatisfy { $0.isSatisfied(by: installed) } }
    }

    // MARK: - Parsing

    private struct Operand {
        var components: [Int]
        var hasWildcard: Bool
        var isPartial: Bool { hasWildcard || components.count < 3 }
    }

    private enum Operator: String, CaseIterable {
        case greaterOrEqual = ">="
        case lessOrEqual = "<="
        case strictEqual = "=="
        case notEqual = "!="
        case compatible = "~="
        case greater = ">"
        case less = "<"
        case equal = "="
        case caret = "^"
        case tilde = "~"
    }

    private struct Comparator {
        let op: Operator
        let operand: Operand
        let grammar: CleanupRangeGrammar
        private var comparesPadded: Bool { grammar == .pep440 && !operand.hasWildcard }

        func isSatisfied(by version: [Int]) -> Bool {
            let target = operand.components
            switch op {
            case .equal: return hasPrefix(version, target)
            case .strictEqual: return operand.hasWildcard ? hasPrefix(version, target) : compare(version, target) == 0
            case .notEqual: return operand.hasWildcard ? !hasPrefix(version, target) : compare(version, target) != 0
            case .greaterOrEqual: return compare(version, target) >= 0
            case .less: return compare(version, target) < 0
            case .greater:
                guard !target.isEmpty else { return false }
                return !comparesPadded && operand.isPartial
                    ? compare(version, bumped(target, at: target.count - 1)) >= 0 : compare(version, target) > 0
            case .lessOrEqual:
                guard !target.isEmpty else { return true }
                return !comparesPadded && operand.isPartial
                    ? compare(version, bumped(target, at: target.count - 1)) < 0 : compare(version, target) <= 0
            case .compatible:
                return compare(version, target) >= 0 && hasPrefix(version, Array(target.dropLast()))
            case .caret:
                guard !target.isEmpty else { return true }
                let pivot = target.firstIndex { $0 != 0 } ?? target.count - 1
                return compare(version, target) >= 0 && compare(version, bumped(target, at: pivot)) < 0
            case .tilde:
                guard !target.isEmpty else { return true }
                return compare(version, target) >= 0
                    && compare(version, bumped(target, at: min(1, target.count - 1))) < 0
            }
        }
    }

    private static func parseClause(_ clause: String, grammar: CleanupRangeGrammar) -> [Comparator]? {
        var tokens = clause.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var comparators: [Comparator] = []
        while !tokens.isEmpty {
            var token = tokens.removeFirst()
            if Operator(rawValue: token) != nil {
                guard !tokens.isEmpty else { return nil }
                token += tokens.removeFirst()
            }
            guard let comparator = parseComparator(token, grammar: grammar) else { return nil }
            comparators.append(comparator)
        }
        return comparators.isEmpty ? nil : comparators
    }

    private static func parseComparator(_ token: String, grammar: CleanupRangeGrammar) -> Comparator? {
        let op = Operator.allCases.first { token.hasPrefix($0.rawValue) } ?? .equal
        let text = op == .equal && !token.hasPrefix("=") ? token : String(token.dropFirst(op.rawValue.count))
        guard let operand = parseOperand(text) else { return nil }
        if op == .compatible, operand.hasWildcard || operand.components.count < 2 { return nil }
        if operand.components.isEmpty, !operand.hasWildcard { return nil }
        return Comparator(op: op, operand: operand, grammar: grammar)
    }

    /// Dotted numbers, an optional leading `v`, wildcards only as the final components, and
    /// a suffix of a known shape: PEP 440 `aN`/`bN`/`cN`/`rcN` glued to the last number,
    /// `.devN`/`.postN`, a semver `-pre` after a full `X.Y.Z`, or `+build`. Anything else is `nil`.
    private static func parseOperand(_ text: String) -> Operand? {
        var body = Substring(text)
        if let first = body.first, first == "v" || first == "V" { body = body.dropFirst() }
        var core = body
        var tailSeparator: Character?
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            let tail = body[body.index(after: cut)...]
            guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-+".contains($0)) })
            else { return nil }
            core = body[..<cut]
            tailSeparator = body[cut]
        }
        var parts = core.split(separator: ".", omittingEmptySubsequences: false)
        var tagged = false
        while parts.count > 1, let last = parts.last, isTagWithNumber(last, prefixes: ["dev", "post"]) {
            parts.removeLast()
            tagged = true
        }
        var components: [Int] = []
        for (index, part) in parts.enumerated() {
            let isLast = index == parts.count - 1
            if isWildcard(part) {
                guard isLast, !tagged, tailSeparator == nil else { return nil }
                return Operand(components: components, hasWildcard: true)
            }
            if let number = strictNumber(part) {
                components.append(number)
            } else if isLast, let number = numberWithPreReleaseTag(part) {
                components.append(number)
                tagged = true
            } else {
                return nil
            }
        }
        if tailSeparator == "-", tagged || components.count != 3 { return nil }
        return Operand(components: components, hasWildcard: false)
    }

    private static func strictNumber(_ part: Substring) -> Int? {
        guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(part), number < componentLimit else { return nil }
        return number
    }

    private static func isTagWithNumber(_ part: Substring, prefixes: [String]) -> Bool {
        prefixes.contains { prefix in
            part.hasPrefix(prefix) && strictNumber(part.dropFirst(prefix.count)) != nil
        }
    }

    private static func numberWithPreReleaseTag(_ part: Substring) -> Int? {
        let digits = part.prefix { $0.isASCII && $0.isNumber }
        let rest = part.dropFirst(digits.count)
        guard let number = strictNumber(digits),
              ["rc", "a", "b", "c"].contains(where: { rest.hasPrefix($0) && strictNumber(rest.dropFirst($0.count)) != nil })
        else { return nil }
        return number
    }

    private static func numericOperand(_ pin: String) -> [Int]? {
        var body = Substring(pin)
        if let first = body.first, first == "v" || first == "V" { body = body.dropFirst() }
        var components: [Int] = []
        for part in body.split(separator: ".", omittingEmptySubsequences: false) {
            if isWildcard(part) { return components }
            guard let value = leadingNumber(part), !value.hasSuffix else { return nil }
            components.append(value.number)
        }
        return components
    }

    private static func installedComponents(_ version: String) -> [Int] {
        var body = Substring(version)
        if let first = body.first, first == "v" || first == "V" { body = body.dropFirst() }
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = body[..<cut] }
        var components: [Int] = []
        for part in body.split(separator: ".", omittingEmptySubsequences: false) {
            guard let value = leadingNumber(part) else { return components }
            components.append(value.number)
            if value.hasSuffix { break }
        }
        return components
    }

    private static func isWildcard(_ part: Substring) -> Bool {
        part == "x" || part == "X" || part == "*"
    }

    private static func leadingNumber(_ part: Substring) -> (number: Int, hasSuffix: Bool)? {
        let digits = part.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits), number < componentLimit else { return nil }
        return (number, digits.count < part.count)
    }

    // MARK: - Comparison

    private static func hasPrefix(_ version: [Int], _ prefix: [Int]) -> Bool {
        version.count >= prefix.count && Array(version.prefix(prefix.count)) == prefix
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        let (left, right) = paddedComponents(lhs, rhs)
        for (a, b) in zip(left, right) where a != b { return a < b ? -1 : 1 }
        return 0
    }

    private static func bumped(_ components: [Int], at index: Int) -> [Int] {
        var result = Array(components.prefix(index + 1))
        result[index] += 1
        return result
    }
}
