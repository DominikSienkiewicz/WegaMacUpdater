import Foundation

/// Decides whether an installed runtime version satisfies a pin or range read from a
/// project file. Pure and total: untrusted text never traps, it just fails to match
/// (`false`) or fails to parse (`nil`).
public enum CleanupVersionMatcher {
    /// Components above this bound are treated as unparseable, so later `+ 1` cannot overflow.
    private static let componentLimit = 1_000_000_000_000

    public static func pin(_ pin: String, matches version: String) -> Bool {
        if let operand = numericOperand(pin) {
            let installed = installedComponents(version)
            return !operand.isEmpty && !installed.isEmpty && hasPrefix(installed, operand)
        }
        guard !pin.isEmpty else { return false }
        return version == pin || version.hasPrefix(pin + "-")
    }

    /// `nil` means the range could not be parsed.
    public static func range(_ range: String, isSatisfiedBy version: String) -> Bool? {
        var clauses: [[Comparator]] = []
        for rawClause in range.components(separatedBy: "||") {
            guard let clause = parseClause(rawClause) else { return nil }
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
                return operand.isPartial ? compare(version, bumped(target, at: target.count - 1)) >= 0
                    : compare(version, target) > 0
            case .lessOrEqual:
                guard !target.isEmpty else { return true }
                return operand.isPartial ? compare(version, bumped(target, at: target.count - 1)) < 0
                    : compare(version, target) <= 0
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

    private static func parseClause(_ clause: String) -> [Comparator]? {
        var tokens = clause.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        var comparators: [Comparator] = []
        while !tokens.isEmpty {
            var token = tokens.removeFirst()
            if Operator(rawValue: token) != nil {
                guard !tokens.isEmpty else { return nil }
                token += tokens.removeFirst()
            }
            guard let comparator = parseComparator(token) else { return nil }
            comparators.append(comparator)
        }
        return comparators.isEmpty ? nil : comparators
    }

    private static func parseComparator(_ token: String) -> Comparator? {
        let op = Operator.allCases.first { token.hasPrefix($0.rawValue) } ?? .equal
        let text = op == .equal && !token.hasPrefix("=") ? token : String(token.dropFirst(op.rawValue.count))
        guard let operand = parseOperand(text) else { return nil }
        if op == .compatible, operand.hasWildcard || operand.components.count < 2 { return nil }
        if operand.components.isEmpty, !operand.hasWildcard { return nil }
        return Comparator(op: op, operand: operand)
    }

    /// Dotted numbers with an optional wildcard tail; a pre-release or build suffix
    /// (`-beta.1`, `+build`, `rc1`) is dropped, so only numeric components compare.
    private static func parseOperand(_ text: String) -> Operand? {
        var body = Substring(text)
        if let first = body.first, first == "v" || first == "V" { body = body.dropFirst() }
        if let cut = body.firstIndex(where: { $0 == "-" || $0 == "+" }) { body = body[..<cut] }
        guard !body.isEmpty else { return nil }
        var components: [Int] = []
        for part in body.split(separator: ".", omittingEmptySubsequences: false) {
            if isWildcard(part) { return Operand(components: components, hasWildcard: true) }
            guard let value = leadingNumber(part) else { return nil }
            components.append(value.number)
            if value.hasSuffix { break }
        }
        return Operand(components: components, hasWildcard: false)
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
