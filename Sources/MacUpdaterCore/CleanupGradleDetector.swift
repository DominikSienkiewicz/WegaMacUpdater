import Foundation

/// A Gradle distribution as the wrapper names it, `gradle-<version>-<type>` with type `bin` or
/// `all`. It is all D6 keeps of a `distributionUrl`, which may carry credentials.
public struct CleanupGradleDistribution: Hashable, Sendable {
    public let version: String
    public let type: String

    public init(version: String, type: String) {
        self.version = version
        self.type = type
    }

    private static let namePrefix = Array("gradle-".unicodeScalars)
    private static let types = ["bin", "all"]

    /// Parses `gradle-<version>-<bin|all>`. The version starts with a digit and holds only ASCII
    /// letters, digits, `.`, `-`, `+` and `_`, so it compares the same by scalars and by `String`.
    static func named(_ name: String) -> CleanupGradleDistribution? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.starts(with: namePrefix) else { return nil }
        for type in types {
            let suffix = Array("-\(type)".unicodeScalars)
            guard scalars.count > namePrefix.count + suffix.count, scalars.reversed().starts(with: suffix.reversed()) else {
                continue
            }
            let version = scalars[namePrefix.count..<(scalars.count - suffix.count)]
            guard isVersion(version) else { return nil }
            return CleanupGradleDistribution(version: String(String.UnicodeScalarView(version)), type: type)
        }
        return nil
    }

    private static func isVersion(_ scalars: ArraySlice<Unicode.Scalar>) -> Bool {
        guard let first = scalars.first, ("0"..."9").contains(first) else { return false }
        return scalars.allSatisfy { scalar in
            ("0"..."9").contains(scalar) || ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                || scalar == "." || scalar == "-" || scalar == "+" || scalar == "_"
        }
    }
}

/// Reads what Gradle projects ask for out of the files the project walk handed over. The text comes
/// from user projects, so anything unparseable yields fewer requirements, never a failure. A
/// wrapper's `distributionUrl` is reduced to its file name's version and type here and nothing else
/// of it leaves.
public enum CleanupGradleRequirements {
    private static let maxLineLength = 4096
    private static let maxMajorDigits = 4
    private static let byteOrderMark: Unicode.Scalar = "\u{FEFF}"

    /// The distribution the wrapper downloads: the last `distributionUrl`, `\:` unescaped, named the
    /// way Gradle names its folder — from the URI's path as `URI.getPath()` gives it (query and
    /// fragment dropped, percent-decoded), whose last `/` piece must be `gradle-<version>-<bin|all>.zip`.
    public static func distribution(inWrapperProperties text: String) -> CleanupGradleDistribution? {
        guard let url = properties(text).last(where: { isSame($0.key, "distributionUrl") })?.value,
              let path = String(String.UnicodeScalarView(url.unicodeScalars.prefix { $0 != "?" && $0 != "#" })).removingPercentEncoding
        else { return nil }
        let fileName = String(String.UnicodeScalarView(
            path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring.UnicodeScalarView()
        ))
        guard let name = dropping(".zip", from: fileName) else { return nil }
        return CleanupGradleDistribution.named(name)
    }

    /// `toolchainVersion=<N>` in `gradle/gradle-daemon-jvm.properties`.
    public static func toolchainMajors(inDaemonJvmProperties text: String) -> [Int] {
        properties(text).filter { isSame($0.key, "toolchainVersion") }.compactMap { positiveInteger(Array($0.value.unicodeScalars)[...]) }
    }

    /// The integers in `JavaLanguageVersion.of(<N>)` and `jvmToolchain(<N>)`, quoted or not.
    public static func toolchainMajors(inBuildScript text: String) -> [Int] {
        let scalars = Array(text.unicodeScalars)
        return ["JavaLanguageVersion.of(", "jvmToolchain("].flatMap { integers(after: $0, in: scalars) }
    }

    /// The major of `JAVA_VERSION="<v>"` in a JDK's `release` file (`1.8.0_392` → 8).
    public static func javaMajor(inReleaseFile text: String) -> Int? {
        guard let value = properties(text).last(where: { isSame($0.key, "JAVA_VERSION") })?.value else { return nil }
        let unquoted = value.unicodeScalars.filter { $0 != "\"" && $0 != "'" }
        return major(ofVersion: Array(unquoted)[...])
    }

    /// The major after the first `-` that a digit follows (`eclipse_adoptium-25-aarch64-os_x.2` → 25,
    /// `jdk-25.0.1+9` → 25).
    public static func javaMajor(inDirectoryName name: String) -> Int? {
        let scalars = Array(name.unicodeScalars)
        let dash = scalars.indices.first { index in
            scalars[index] == "-" && index + 1 < scalars.count && isDigit(scalars[index + 1])
        }
        guard let dash else { return nil }
        return major(ofVersion: scalars[(dash + 1)...])
    }

    // MARK: Plumbing

    /// The leading number, or the second one for the legacy `1.<major>` spelling.
    private static func major(ofVersion scalars: ArraySlice<Unicode.Scalar>) -> Int? {
        let leading = scalars.prefix(while: isDigit)
        guard let first = positiveInteger(leading) else { return nil }
        let rest = scalars.dropFirst(leading.count)
        if first == 1, rest.first == ".", let legacy = positiveInteger(rest.dropFirst().prefix(while: isDigit)) {
            return legacy
        }
        return first
    }

    /// The `key=value`, `key:value` and `key value` lines of a Java properties file. Comment lines
    /// and lines over `maxLineLength` are skipped; a backslash escape in the value is undone.
    private static func properties(_ text: String) -> [(key: String, value: String)] {
        lines(text).compactMap { line in
            let content = line.drop(while: isBlank)
            guard let first = content.first, first != "#", first != "!" else { return nil }
            let keyEnd = content.firstIndex { isBlank($0) || $0 == "=" || $0 == ":" } ?? content.endIndex
            var rest = content[keyEnd...].drop(while: isBlank)
            if let separator = rest.first, separator == "=" || separator == ":" {
                rest = rest.dropFirst().drop(while: isBlank)
            }
            return (String(String.UnicodeScalarView(content[..<keyEnd])), unescaped(rest))
        }
    }

    private static func lines(_ text: String) -> [Substring.UnicodeScalarView] {
        var scalars = Substring(text).unicodeScalars
        if scalars.first == byteOrderMark { scalars = scalars.dropFirst() }
        return scalars.split { $0 == "\n" || $0 == "\r" }.filter { $0.count <= maxLineLength }
    }

    private static func unescaped(_ scalars: Substring.UnicodeScalarView) -> String {
        var result = String.UnicodeScalarView()
        var isEscaping = false
        for scalar in scalars {
            if isEscaping || scalar != "\\" {
                result.append(scalar)
                isEscaping = false
            } else {
                isEscaping = true
            }
        }
        while let last = result.last, isBlank(last) { result.removeLast() }
        return String(result)
    }

    private static func integers(after marker: String, in scalars: [Unicode.Scalar]) -> [Int] {
        let marker = Array(marker.unicodeScalars)
        var found: [Int] = []
        var index = 0
        while index + marker.count <= scalars.count {
            guard scalars[index..<(index + marker.count)].elementsEqual(marker) else {
                index += 1
                continue
            }
            index += marker.count
            if let value = parenthesisedInteger(scalars[index...]) { found.append(value) }
        }
        return found
    }

    /// `<blanks><optional quote><digits><same quote><blanks>)`.
    private static func parenthesisedInteger(_ scalars: ArraySlice<Unicode.Scalar>) -> Int? {
        var rest = scalars.drop(while: isBlank)
        let quote: Unicode.Scalar? = rest.first.flatMap { $0 == "\"" || $0 == "'" ? $0 : nil }
        if quote != nil { rest = rest.dropFirst() }
        let digits = rest.prefix(while: isDigit)
        rest = rest.dropFirst(digits.count)
        if let quote {
            guard rest.first == quote else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.drop(while: isBlank).first == ")" else { return nil }
        return positiveInteger(digits)
    }

    private static func positiveInteger(_ digits: ArraySlice<Unicode.Scalar>) -> Int? {
        guard !digits.isEmpty, digits.count <= maxMajorDigits, digits.allSatisfy(isDigit),
              let value = Int(String(String.UnicodeScalarView(digits))), value > 0
        else { return nil }
        return value
    }

    private static func dropping(_ suffix: String, from name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        let suffix = Array(suffix.unicodeScalars)
        guard scalars.count > suffix.count, scalars.reversed().starts(with: suffix.reversed()) else { return nil }
        return String(String.UnicodeScalarView(scalars.dropLast(suffix.count)))
    }

    static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.elementsEqual(rhs.unicodeScalars)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\u{0C}"
    }
}

/// D6: the distributions the Gradle wrapper downloaded into `~/.gradle/wrapper/dists` and the JDKs
/// Gradle provisioned into `~/.gradle/jdks`, checked against the wrappers, daemon JVM criteria and
/// toolchain calls the project walk found. A distribution no wrapper names is safe to trash (the
/// wrapper downloads it again on demand) only when the walk was complete; a JDK no project needs
/// always needs a decision; a JDK whose major is unknown and every system JDK are context only.
/// Never reads any `gradle.properties`.
public struct CleanupGradleDetector: Sendable {
    private static let distributionsDirectory = ".gradle/wrapper/dists"
    private static let jdksDirectory = ".gradle/jdks"
    private static let releaseFileLocations = ["release", "Contents/Home/release"]
    private static let maxReleaseFileBytes = 262_144

    /// A directory as listed, with its physical path when it resolves.
    private struct Item {
        let entry: CleanupEntry
        let realpath: URL?
        var url: URL { entry.url }
    }

    private struct Distribution {
        let item: Item
        let distribution: CleanupGradleDistribution
        let sources: [String]
    }

    private struct JDK {
        let item: Item
        let major: Int?
        let sources: [String]
    }

    private struct Verdict {
        let status: CleanupStatus
        let reason: CleanupReason
        let action: CleanupAction
        let risk: CleanupRisk
        let bucket: CleanupBucket
        let sized: Bool
    }

    private let fileSystem: CleanupFileSystem
    private let home: URL
    private let inspector: ProcessInspecting
    private let systemJDKDirectory: URL

    public init(
        fileSystem: CleanupFileSystem, home: URL, inspector: ProcessInspecting,
        systemJDKDirectory: URL = URL(filePath: "/Library/Java/JavaVirtualMachines", directoryHint: .isDirectory)
    ) {
        self.fileSystem = fileSystem
        self.home = home
        self.inspector = inspector
        self.systemJDKDirectory = systemJDKDirectory
    }

    /// `walkIsComplete` is false when no project root was walked or the walk was cut short; a
    /// distribution then needs a decision, because a wrapper the walk missed may still name it.
    public func findings(projectFiles: [CleanupProjectFile], walkIsComplete: Bool) -> [CleanupFinding] {
        let wrappers = Self.wrapperSources(projectFiles)
        let toolchains = Self.toolchainSources(projectFiles)
        let distributions = directories(in: home.appending(path: Self.distributionsDirectory, directoryHint: .isDirectory))
            .compactMap { item -> Distribution? in
                guard let distribution = CleanupGradleDistribution.named(Self.name(of: item.url)) else { return nil }
                return Distribution(item: item, distribution: distribution, sources: wrappers[distribution] ?? [])
            }
        let jdks = directories(in: home.appending(path: Self.jdksDirectory, directoryHint: .isDirectory)).map { item in
            let major = javaMajor(ofJDK: item.url)
            return JDK(item: item, major: major, sources: major.flatMap { toolchains[$0] } ?? [])
        }
        let hasCandidates = distributions.contains { $0.sources.isEmpty } || jdks.contains { $0.major != nil && $0.sources.isEmpty }
        let processes = hasCandidates ? inspector.userProcesses() : []
        return distributions.map { finding(for: $0, processes: processes, walkIsComplete: walkIsComplete) }
            + jdks.map { finding(for: $0, processes: processes, walkIsComplete: walkIsComplete) }
            + systemJDKFindings()
    }

    public func referencedDistributions(projectFiles: [CleanupProjectFile]) -> Set<CleanupGradleDistribution> {
        Set(Self.wrapperSources(projectFiles).keys)
    }

    public func requiredJavaMajors(projectFiles: [CleanupProjectFile]) -> Set<Int> {
        Set(Self.toolchainSources(projectFiles).keys)
    }

    // MARK: Requirements

    /// Each referenced distribution with the wrapper files naming it, sorted and de-duplicated.
    private static func wrapperSources(_ files: [CleanupProjectFile]) -> [CleanupGradleDistribution: [String]] {
        var sources: [CleanupGradleDistribution: [String]] = [:]
        for file in files where file.kind == .gradleWrapperProperties {
            guard let distribution = CleanupGradleRequirements.distribution(inWrapperProperties: file.text) else { continue }
            sources[distribution, default: []].append(file.url.path)
        }
        return sources.mapValues(sortedUnique)
    }

    /// Each required Java major with the daemon JVM files and build scripts asking for it.
    private static func toolchainSources(_ files: [CleanupProjectFile]) -> [Int: [String]] {
        var sources: [Int: [String]] = [:]
        for file in files {
            let majors: [Int]
            switch file.kind {
            case .gradleDaemonJvmProperties: majors = CleanupGradleRequirements.toolchainMajors(inDaemonJvmProperties: file.text)
            case .gradleBuildScript: majors = CleanupGradleRequirements.toolchainMajors(inBuildScript: file.text)
            default: continue
            }
            for major in Set(majors) { sources[major, default: []].append(file.url.path) }
        }
        return sources.mapValues(sortedUnique)
    }

    // MARK: Disk

    /// The directories directly inside `directory`; links and files are not candidates.
    private func directories(in directory: URL) -> [Item] {
        guard let entries = try? fileSystem.contents(of: directory) else { return [] }
        return entries.filter { $0.kind == .directory }.map { Item(entry: $0, realpath: try? fileSystem.realpath($0.url)) }
    }

    /// From the `release` file, in the JDK or in its only subdirectory (Gradle unpacks a JDK inside
    /// a vendor-named folder), else from the directory's name.
    private func javaMajor(ofJDK directory: URL) -> Int? {
        if let major = releaseMajor(in: directory) ?? soleSubdirectory(of: directory).flatMap(releaseMajor(in:)) {
            return major
        }
        return CleanupGradleRequirements.javaMajor(inDirectoryName: Self.name(of: directory))
    }

    private func releaseMajor(in directory: URL) -> Int? {
        for location in Self.releaseFileLocations {
            let release = directory.appending(path: location, directoryHint: .notDirectory)
            if let text = try? fileSystem.readText(release, maxBytes: Self.maxReleaseFileBytes),
               let major = CleanupGradleRequirements.javaMajor(inReleaseFile: text) {
                return major
            }
        }
        return nil
    }

    private func soleSubdirectory(of directory: URL) -> URL? {
        guard let entries = try? fileSystem.contents(of: directory) else { return nil }
        let subdirectories = entries.filter { $0.kind == .directory }
        return subdirectories.count == 1 ? subdirectories.first?.url : nil
    }

    // MARK: Findings

    /// A referenced distribution carries no action: it is context, and nothing may trash it.
    private func finding(for candidate: Distribution, processes: [CleanupProcess], walkIsComplete: Bool) -> CleanupFinding {
        let status: CleanupStatus
        let reason: CleanupReason
        let action: CleanupAction
        if candidate.sources.isEmpty {
            let users = Self.users(of: candidate.item, among: processes)
            status = users.isEmpty ? .unused : .inUse(users)
            reason = .unusedGradleDistribution
            action = .trash([candidate.item.url])
        } else {
            status = .pinned(by: candidate.sources)
            reason = .requiredByProjects
            action = .none
        }
        let bucket = CleanupBucketPolicy.bucket(status: status, kind: .gradleDistribution, evidenceComplete: walkIsComplete)
        return makeFinding(candidate.item, tool: "gradle", version: candidate.distribution.version, source: nil, verdict: Verdict(
            status: status, reason: reason, action: action, risk: .low, bucket: bucket, sized: true
        ))
    }

    private func finding(for jdk: JDK, processes: [CleanupProcess], walkIsComplete: Bool) -> CleanupFinding {
        let status: CleanupStatus
        let reason: CleanupReason
        let action: CleanupAction
        if let major = jdk.major {
            if jdk.sources.isEmpty {
                let users = Self.users(of: jdk.item, among: processes)
                status = users.isEmpty ? .unused : .inUse(users)
                reason = .unreferencedJDK(major: major)
                action = .trash([jdk.item.url])
            } else {
                status = .pinned(by: jdk.sources)
                reason = .requiredByProjects
                action = .none
            }
        } else {
            status = .info
            reason = .unknownVersionDirectory
            action = .none
        }
        let bucket = CleanupBucketPolicy.bucket(status: status, kind: .gradleJDK, evidenceComplete: walkIsComplete)
        return makeFinding(jdk.item, tool: "java", version: jdk.major.map { String($0) }, source: nil, verdict: Verdict(
            status: status, reason: reason, action: action, risk: .medium, bucket: bucket, sized: true
        ))
    }

    /// `/Library/Java/JavaVirtualMachines/*.jdk`: context for the JDK rows, never a candidate.
    private func systemJDKFindings() -> [CleanupFinding] {
        directories(in: systemJDKDirectory).filter { Self.hasSuffix(Self.name(of: $0.url), ".jdk") }.map { item in
            let major = javaMajor(ofJDK: item.url)
            let reason = major.map { CleanupReason.systemJDK(major: $0) } ?? .unknownVersionDirectory
            let bucket = CleanupBucketPolicy.bucket(status: .info, kind: .gradleJDK, evidenceComplete: true)
            return makeFinding(item, tool: "java", version: major.map { String($0) }, source: .system, verdict: Verdict(
                status: .info, reason: reason, action: .none, risk: .low, bucket: bucket, sized: false
            ))
        }
    }

    private func makeFinding(_ item: Item, tool: String, version: String?, source: CleanupSource?, verdict: Verdict) -> CleanupFinding {
        CleanupFinding(
            detector: .gradle, tool: tool, path: item.url, realpath: item.realpath, source: source, version: version,
            size: verdict.sized ? try? fileSystem.allocatedSize(of: item.url) : nil,
            status: verdict.status, reason: verdict.reason, action: verdict.action, risk: verdict.risk,
            bucket: verdict.bucket, identity: item.entry.identity
        )
    }

    /// A process runs from the directory or names it in an argument (a Gradle daemon's classpath
    /// and agent), under the listed path or the physical one.
    private static func users(of item: Item, among processes: [CleanupProcess]) -> [CleanupProcess] {
        let roots = [item.url] + (item.realpath.map { [$0] } ?? [])
        let matched = Set(roots.flatMap { root in
            CleanupInUseMatcher.processes(using: root, isDirectory: true, among: processes)
                + CleanupInUseMatcher.processes(referencing: root, among: processes)
        }.map(\.pid))
        return processes.filter { matched.contains($0.pid) }
    }

    private static func name(of url: URL) -> String {
        CleanupPathText.components(of: url.path).last ?? ""
    }

    private static func hasSuffix(_ name: String, _ suffix: String) -> Bool {
        name.unicodeScalars.count > suffix.unicodeScalars.count
            && name.unicodeScalars.reversed().starts(with: suffix.unicodeScalars.reversed())
    }

    /// Sorted and de-duplicated by Unicode scalars, the way the kernel compares path text.
    private static func sortedUnique(_ paths: [String]) -> [String] {
        paths.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
            .reduce(into: []) { unique, path in
                if unique.last.map({ CleanupGradleRequirements.isSame($0, path) }) != true {
                    unique.append(path)
                }
            }
    }
}
