import Foundation
import XCTest
@testable import MacUpdaterCore

final class CleanupGradleDetectorTests: XCTestCase {
    private let liveFileSystem = LiveCleanupFileSystem(trash: { _ in })

    private func detector(
        _ home: CleanupTempHome, processes: [CleanupProcess] = [], fileSystem: CleanupFileSystem? = nil
    ) -> CleanupGradleDetector {
        CleanupGradleDetector(
            fileSystem: fileSystem ?? liveFileSystem, home: home.home,
            inspector: FakeProcessInspector(processes: processes, bootTime: Date(timeIntervalSince1970: 0)),
            systemJDKDirectory: home.url("Library/Java/JavaVirtualMachines")
        )
    }

    /// A distribution as the wrapper unpacks it: `dists/<name>/<hash>/<name without type>/…`.
    @discardableResult
    private func distribution(_ home: CleanupTempHome, _ name: String) throws -> URL {
        try home.file(".gradle/wrapper/dists/\(name)/a1b2c3/gradle/lib/gradle-core.jar", size: 8192)
        return home.url(".gradle/wrapper/dists/\(name)")
    }

    private func wrapper(_ home: CleanupTempHome, project: String, distributionURL: String) throws -> CleanupProjectFile {
        let text = """
        distributionBase=GRADLE_USER_HOME
        distributionPath=wrapper/dists
        distributionUrl=\(distributionURL)
        zipStoreBase=GRADLE_USER_HOME
        zipStorePath=wrapper/dists

        """
        let url = try home.file("Dev/\(project)/gradle/wrapper/gradle-wrapper.properties", text: text)
        return CleanupProjectFile(url: url, kind: .gradleWrapperProperties, text: text)
    }

    private func wrapper(_ home: CleanupTempHome, project: String, version: String, type: String = "bin") throws -> CleanupProjectFile {
        try wrapper(home, project: project, distributionURL: "https\\://services.gradle.org/distributions/gradle-\(version)-\(type).zip")
    }

    private func projectFile(
        _ home: CleanupTempHome, _ relative: String, _ kind: CleanupProjectFileKind, _ text: String
    ) throws -> CleanupProjectFile {
        CleanupProjectFile(url: try home.file(relative, text: text), kind: kind, text: text)
    }

    private func finding(at url: URL, in findings: [CleanupFinding]) throws -> CleanupFinding {
        try XCTUnwrap(findings.first { $0.path.path == url.path }, "no finding for \(url.lastPathComponent)")
    }

    private func trashedPaths(_ finding: CleanupFinding) -> [String]? {
        guard case .trash(let urls) = finding.action else { return nil }
        return urls.map(\.path)
    }

    private func process(pid: Int32, executable: String, arguments: [String] = []) -> CleanupProcess {
        CleanupProcess(pid: pid, name: "java", executablePath: executable, arguments: arguments)
    }

    // MARK: Distributions

    /// Brief case 9: six distributions; the wrappers point to 9.3.0 (not downloaded), 9.7.0 and 9.8.2.
    func testUnusedDistributionsAreSafeTrash() throws {
        let home = try CleanupTempHome()
        var directories: [String: URL] = [:]
        for version in ["9.2.0", "9.6.0", "9.6.1", "9.7.0", "9.8.1", "9.8.2"] {
            directories[version] = try distribution(home, "gradle-\(version)-bin")
        }
        try home.file(".gradle/wrapper/dists/.DS_Store", size: 16)
        try home.directory(".gradle/wrapper/dists/gradle-9.8.2-src")
        let old = try wrapper(home, project: "old", version: "9.3.0")
        let api = try wrapper(home, project: "api", version: "9.7.0")
        let web = try wrapper(home, project: "web", version: "9.8.2")

        let found = detector(home).findings(projectFiles: [old, api, web], walkIsComplete: true)

        XCTAssertEqual(found.count, 6)
        for version in ["9.2.0", "9.6.0", "9.6.1", "9.8.1"] {
            let directory = try XCTUnwrap(directories[version])
            let candidate = try finding(at: directory, in: found)
            XCTAssertEqual(candidate.detector, .gradle)
            XCTAssertEqual(candidate.tool, "gradle")
            XCTAssertEqual(candidate.version, version)
            XCTAssertEqual(candidate.status, .unused, version)
            XCTAssertEqual(candidate.reason, .unusedGradleDistribution)
            XCTAssertEqual(trashedPaths(candidate), [directory.path])
            XCTAssertEqual(candidate.risk, .low)
            XCTAssertEqual(candidate.bucket, .safe, version)
            XCTAssertEqual(candidate.realpath?.path, directory.path)
            XCTAssertGreaterThan(candidate.size ?? 0, 0)
            XCTAssertEqual(candidate.identity, try liveFileSystem.entry(at: directory)?.identity)
        }
        let pinnedByAPI = try finding(at: XCTUnwrap(directories["9.7.0"]), in: found)
        XCTAssertEqual(pinnedByAPI.status, .pinned(by: [api.url.path]))
        XCTAssertEqual(pinnedByAPI.reason, .requiredByProjects)
        XCTAssertEqual(pinnedByAPI.action, .none)
        XCTAssertEqual(pinnedByAPI.bucket, .excluded)
        XCTAssertEqual(try finding(at: XCTUnwrap(directories["9.8.2"]), in: found).status, .pinned(by: [web.url.path]))
        XCTAssertEqual(Set(found.map(\.id)).count, found.count, "finding ids must be unique")
        XCTAssertEqual(
            detector(home).referencedDistributions(projectFiles: [old, api, web]),
            [
                CleanupGradleDistribution(version: "9.3.0", type: "bin"), CleanupGradleDistribution(version: "9.7.0", type: "bin"),
                CleanupGradleDistribution(version: "9.8.2", type: "bin"),
            ]
        )
    }

    func testTypeMustMatch() throws {
        let home = try CleanupTempHome()
        let all = try distribution(home, "gradle-9.8.2-all")
        let bin = try distribution(home, "gradle-9.8.2-bin")
        let first = try wrapper(home, project: "app", version: "9.8.2")
        let second = try wrapper(home, project: "lib", version: "9.8.2")

        let found = detector(home).findings(projectFiles: [second, first, second], walkIsComplete: true)

        let unreferenced = try finding(at: all, in: found)
        XCTAssertEqual(unreferenced.status, .unused)
        XCTAssertEqual(unreferenced.bucket, .safe)
        XCTAssertEqual(try finding(at: bin, in: found).status, .pinned(by: [first.url.path, second.url.path]))
    }

    /// Review Focus 4: an incomplete walk, or no project roots at all, cannot prove a distribution unused.
    func testIncompleteWalkDowngradesDistributionsToNeedsDecision() throws {
        let home = try CleanupTempHome()
        let unreferenced = try distribution(home, "gradle-9.7.0-bin")
        let referenced = try distribution(home, "gradle-9.8.2-bin")
        let web = try wrapper(home, project: "web", version: "9.8.2")

        let truncated = detector(home).findings(projectFiles: [web], walkIsComplete: false)

        let candidate = try finding(at: unreferenced, in: truncated)
        XCTAssertEqual(candidate.status, .unused)
        XCTAssertEqual(candidate.bucket, .needsDecision)
        XCTAssertEqual(trashedPaths(candidate), [unreferenced.path])
        XCTAssertEqual(try finding(at: referenced, in: truncated).bucket, .excluded)

        let withoutRoots = detector(home).findings(projectFiles: [], walkIsComplete: false)

        XCTAssertEqual(withoutRoots.count, 2)
        for found in withoutRoots {
            XCTAssertEqual(found.status, .unused)
            XCTAssertEqual(found.bucket, .needsDecision)
        }
    }

    /// The wrapper file may carry credentials in `distributionUrl`; only its file name's version and
    /// type may reach a finding or an export.
    func testDistributionUrlNeverLeaves() throws {
        let home = try CleanupTempHome()
        let pinned = try distribution(home, "gradle-9.8.2-bin")
        try distribution(home, "gradle-9.2.0-bin")
        let file = try wrapper(home, project: "app", distributionURL: "https\\://user:token@host/gradle/distributions/gradle-9.8.2-bin.zip")

        let found = detector(home).findings(projectFiles: [file], walkIsComplete: true)

        XCTAssertEqual(try finding(at: pinned, in: found).status, .pinned(by: [file.url.path]))
        XCTAssertEqual(
            CleanupGradleRequirements.distribution(inWrapperProperties: file.text), CleanupGradleDistribution(version: "9.8.2", type: "bin")
        )
        let report = CleanupReport(
            createdAt: Date(timeIntervalSince1970: 0),
            path: CleanupPathSnapshot(entries: [], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: false),
            findings: found, notes: [], skippedProtected: []
        )
        let json = String(decoding: try CleanupReportRenderer.json(report, home: home.home), as: UTF8.self)
        let text = CleanupReportRenderer.text(
            report, home: home.home, reasonText: { String(describing: $0) }, statusText: { String(describing: $0) }
        )
        XCTAssertTrue(json.contains("~/.gradle/wrapper/dists/gradle-9.8.2-bin"), "precondition: the export lists the distribution")
        for secret in ["user", "token", "host"] {
            XCTAssertFalse(json.contains(secret), "the JSON export carries \(secret)")
            XCTAssertFalse(text.contains(secret), "the text export carries \(secret)")
        }
        XCTAssertFalse(String(describing: found).contains("user:token@"), "a finding carries the URL's user-info")
    }

    /// Gradle names the folder after the URI's decoded path (`URI.getPath()`, last `/` piece), so a
    /// query, a fragment or percent-encoding still names `gradle-<v>-<type>`; none of it leaves.
    func testQueryFragmentAndPercentEncodingNameTheDistributionGradleUses() throws {
        let home = try CleanupTempHome()
        let queried = try distribution(home, "gradle-8.5-bin")
        let fragmented = try distribution(home, "gradle-8.6-all")
        let encoded = try distribution(home, "gradle-8.7-bin")
        let withQuery = try wrapper(home, project: "a", distributionURL: "https\\://mirror/dist/gradle-8.5-bin.zip?token=q-secret-1")
        let withFragment = try wrapper(home, project: "b", distributionURL: "https\\://mirror/dist/gradle-8.6-all.zip#f-secret-2/part")
        let percentEncoded = try wrapper(home, project: "c", distributionURL: "https\\://mirror/dist/gradle-8.7%2Dbin.zip")

        let found = detector(home).findings(projectFiles: [withQuery, withFragment, percentEncoded], walkIsComplete: true)

        XCTAssertEqual(try finding(at: queried, in: found).status, .pinned(by: [withQuery.url.path]))
        XCTAssertEqual(try finding(at: fragmented, in: found).status, .pinned(by: [withFragment.url.path]))
        XCTAssertEqual(try finding(at: encoded, in: found).status, .pinned(by: [percentEncoded.url.path]))
        XCTAssertEqual(
            CleanupGradleRequirements.distribution(inWrapperProperties: "distributionUrl=https\\://mirror/dist%2Fgradle-8.8-bin.zip\n"),
            CleanupGradleDistribution(version: "8.8", type: "bin")
        )
        XCTAssertNil(CleanupGradleRequirements.distribution(inWrapperProperties: "distributionUrl=https\\://mirror/gradle-8.9%ZZbin.zip\n"))
        let report = CleanupReport(
            createdAt: Date(timeIntervalSince1970: 0),
            path: CleanupPathSnapshot(entries: [], ignoredEntries: [], shell: nil, capturedAt: nil, isApproximate: false),
            findings: found, notes: [], skippedProtected: []
        )
        let json = String(decoding: try CleanupReportRenderer.json(report, home: home.home), as: UTF8.self)
        for secret in ["q-secret-1", "f-secret-2", "mirror"] {
            XCTAssertFalse(json.contains(secret), "the JSON export carries \(secret)")
            XCTAssertFalse(String(describing: found).contains(secret), "a finding carries \(secret)")
        }
    }

    /// A daemon's classpath and agent are `:`/`=`-joined, so no argument is an absolute path on its own.
    func testDaemonReferencingADistributionIsInUse() throws {
        let home = try CleanupTempHome()
        let used = try distribution(home, "gradle-9.6.1-bin")
        let idle = try distribution(home, "gradle-9.6.0-bin")
        let daemon = process(
            pid: 4242, executable: "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin/java",
            arguments: [
                "--add-opens=java.base/java.util=ALL-UNNAMED",
                "-javaagent:\(used.path)/a1b2c3/gradle-9.6.1/lib/agents/gradle-instrumentation-agent-9.6.1.jar",
                "-cp", "lib/extra.jar:\(used.path)/a1b2c3/gradle-9.6.1/lib/gradle-daemon-main-9.6.1.jar",
                "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "9.6.1",
            ]
        )

        let found = detector(home, processes: [daemon]).findings(projectFiles: [], walkIsComplete: true)

        let busy = try finding(at: used, in: found)
        XCTAssertEqual(busy.status, .inUse([daemon]))
        XCTAssertEqual(busy.bucket, .needsDecision)
        XCTAssertEqual(trashedPaths(busy), [used.path])
        XCTAssertEqual(try finding(at: idle, in: found).status, .unused)
    }

    func testReferencingMatchesArgumentPiecesOnComponentBoundaries() {
        let directory = URL(filePath: "/g/dists/gradle-9.6.1-bin", directoryHint: .isDirectory)
        let agent = process(pid: 1, executable: "/j/bin/java", arguments: ["-javaagent:/g/dists/gradle-9.6.1-bin/h/agent.jar"])
        let classpath = process(pid: 2, executable: "/j/bin/java", arguments: ["-cp", "/a.jar:/g/dists/gradle-9.6.1-bin/lib/x.jar"])
        let property = process(pid: 3, executable: "/j/bin/java", arguments: ["-Dgradle.home=/g/dists/gradle-9.6.1-bin"])
        let sibling = process(pid: 4, executable: "/j/bin/java", arguments: ["-Dx=/g/dists/gradle-9.6.1-bin-old/lib/x.jar"])
        let relative = process(pid: 5, executable: "/j/bin/java", arguments: ["-cp", "g/dists/gradle-9.6.1-bin/lib/x.jar"])
        let executableOnly = process(pid: 6, executable: "/g/dists/gradle-9.6.1-bin/h/bin/tool")

        let matched = CleanupInUseMatcher.processes(
            referencing: directory, among: [agent, classpath, property, sibling, relative, executableOnly]
        )

        XCTAssertEqual(matched.map(\.pid), [1, 2, 3])
        XCTAssertEqual(CleanupInUseMatcher.processes(referencing: URL(filePath: "/", directoryHint: .isDirectory), among: [agent]), [])
    }

    // MARK: JDKs

    /// Brief case 10: Gradle downloaded JDKs 25 and 26; the projects ask for 21; Temurin 27 is the system's.
    func testUnreferencedJDKsNeedDecision() throws {
        let home = try CleanupTempHome()
        let jdk25 = try home.directory(".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2")
        try home.file(
            ".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2/jdk-25.0.1+9/Contents/Home/release",
            text: "IMPLEMENTOR=\"Eclipse Adoptium\"\nJAVA_VERSION=\"25.0.1\"\nJAVA_VERSION_DATE=\"2025-10-21\"\n"
        )
        try home.file(".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2/provisioned.ok", size: 0)
        let jdk26 = try home.directory(".gradle/jdks/eclipse_adoptium-26-aarch64-os_x.2")
        try home.file(".gradle/jdks/eclipse_adoptium-26-aarch64-os_x.2/release", text: "JAVA_VERSION=\"26\"\n")
        try home.file(".gradle/jdks/eclipse_adoptium-26-aarch64-os_x.2/lib/modules", size: 4096)
        try home.file(".gradle/jdks/eclipse_adoptium-27-aarch64-os_x.2.lock", size: 0)
        let temurin = try home.directory("Library/Java/JavaVirtualMachines/temurin-27.jdk")
        try home.file("Library/Java/JavaVirtualMachines/temurin-27.jdk/Contents/Home/release", text: "JAVA_VERSION=\"27.0.1\"\n")
        let script = try projectFile(home, "Dev/app/build.gradle.kts", .gradleBuildScript, "kotlin {\n    jvmToolchain(21)\n}\n")

        let found = detector(home).findings(projectFiles: [script], walkIsComplete: true)

        XCTAssertEqual(found.count, 3)
        for (directory, major) in [(jdk25, 25), (jdk26, 26)] {
            let candidate = try finding(at: directory, in: found)
            XCTAssertEqual(candidate.detector, .gradle)
            XCTAssertEqual(candidate.tool, "java")
            XCTAssertEqual(candidate.version, "\(major)")
            XCTAssertEqual(candidate.status, .unused)
            XCTAssertEqual(candidate.reason, .unreferencedJDK(major: major))
            XCTAssertEqual(trashedPaths(candidate), [directory.path])
            XCTAssertEqual(candidate.risk, .medium)
            XCTAssertEqual(candidate.bucket, .needsDecision)
            XCTAssertGreaterThan(candidate.size ?? 0, 0)
            XCTAssertEqual(candidate.identity, try liveFileSystem.entry(at: directory)?.identity)
        }
        let system = try finding(at: temurin, in: found)
        XCTAssertEqual(system.status, .info)
        XCTAssertEqual(system.source, .system)
        XCTAssertEqual(system.reason, .systemJDK(major: 27))
        XCTAssertEqual(system.action, .none)
        XCTAssertEqual(system.bucket, .excluded)
        XCTAssertEqual(detector(home).requiredJavaMajors(projectFiles: [script]), [21])
    }

    func testJDKOfUnknownVersionIsNeverACandidate() throws {
        let home = try CleanupTempHome()
        let unknown = try home.directory(".gradle/jdks/custom-runtime")
        try home.file(".gradle/jdks/custom-runtime/release", text: "IMPLEMENTOR=\"Someone\"\n")

        let found = detector(home).findings(projectFiles: [], walkIsComplete: true)

        let info = try finding(at: unknown, in: found)
        XCTAssertEqual(info.status, .info)
        XCTAssertEqual(info.reason, .unknownVersionDirectory)
        XCTAssertEqual(info.action, .none)
        XCTAssertEqual(info.bucket, .excluded)
    }

    func testDaemonJvmAndToolchainCallsPinJDKs() throws {
        let home = try CleanupTempHome()
        let jdk17 = try home.directory(".gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2")
        try home.file(
            ".gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2/jdk-17.0.9+9/Contents/Home/release", text: "JAVA_VERSION=\"17.0.9\"\n"
        )
        let jdk21 = try home.directory(".gradle/jdks/jdk-21.0.2+13")
        let jdk8 = try home.directory(".gradle/jdks/corretto_legacy")
        try home.file(".gradle/jdks/corretto_legacy/release", text: "JAVA_VERSION=\"1.8.0_392\"\n")
        let jdk25 = try home.directory(".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2")
        let daemon = try projectFile(
            home, "Dev/app/gradle/gradle-daemon-jvm.properties", .gradleDaemonJvmProperties,
            "#This file is generated by updateDaemonJvm\ntoolchainVendor=ADOPTIUM\ntoolchainVersion=17\n"
        )
        let groovy = try projectFile(
            home, "Dev/app/build.gradle", .gradleBuildScript,
            "java {\n    toolchain {\n        languageVersion = JavaLanguageVersion.of(\"21\")\n    }\n}\n"
        )
        let convention = try projectFile(
            home, "Dev/app/buildSrc/src/main/kotlin/java-conventions.gradle.kts", .gradleBuildScript,
            "java.toolchain.languageVersion.set(JavaLanguageVersion.of( 8 ))\n"
        )
        let files = [daemon, groovy, convention]

        let found = detector(home).findings(projectFiles: files, walkIsComplete: true)

        XCTAssertEqual(try finding(at: jdk17, in: found).status, .pinned(by: [daemon.url.path]))
        XCTAssertEqual(try finding(at: jdk21, in: found).status, .pinned(by: [groovy.url.path]))
        let pinnedLegacy = try finding(at: jdk8, in: found)
        XCTAssertEqual(pinnedLegacy.status, .pinned(by: [convention.url.path]))
        XCTAssertEqual(pinnedLegacy.reason, .requiredByProjects)
        XCTAssertEqual(pinnedLegacy.action, .none)
        XCTAssertEqual(pinnedLegacy.bucket, .excluded)
        XCTAssertEqual(try finding(at: jdk25, in: found).status, .unused)
        XCTAssertEqual(detector(home).requiredJavaMajors(projectFiles: files), [8, 17, 21])
    }

    func testRequirementParsersReadOnlyTheirKeys() {
        XCTAssertEqual(
            Set(CleanupGradleRequirements.toolchainMajors(inBuildScript: "jvmToolchain( 17 )\nJavaLanguageVersion.of('11')\njvmToolchain(x)\n")),
            [17, 11]
        )
        XCTAssertEqual(CleanupGradleRequirements.toolchainMajors(inDaemonJvmProperties: "toolchainVersion=21\ntoolchainVendor=ADOPTIUM\n"), [21])
        XCTAssertEqual(CleanupGradleRequirements.toolchainMajors(inDaemonJvmProperties: "#toolchainVersion=21\n"), [])
        XCTAssertEqual(CleanupGradleRequirements.javaMajor(inReleaseFile: "JAVA_VERSION_DATE=\"2025\"\nJAVA_VERSION=\"1.8.0_392\"\n"), 8)
        XCTAssertEqual(CleanupGradleRequirements.javaMajor(inDirectoryName: "eclipse_adoptium-25-aarch64-os_x.2"), 25)
        XCTAssertEqual(CleanupGradleRequirements.javaMajor(inDirectoryName: "jdk-25.0.1+9"), 25)
        XCTAssertNil(CleanupGradleRequirements.javaMajor(inDirectoryName: "custom-runtime"))
        XCTAssertNil(CleanupGradleRequirements.distribution(
            inWrapperProperties: "#distributionUrl=https\\://services.gradle.org/distributions/gradle-9.8.2-bin.zip\n"
        ))
        XCTAssertNil(CleanupGradleRequirements.distribution(
            inWrapperProperties: "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.8.2-src.zip\n"
        ))
    }

    func testJavaRunningFromAJDKMarksItInUse() throws {
        let home = try CleanupTempHome()
        let jdk = try home.directory(".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2")
        let java = try home.file(
            ".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2/jdk-25.0.1+9/Contents/Home/bin/java", size: 4096, executable: true
        )
        let running = process(pid: 77, executable: java.path)

        let found = detector(home, processes: [running]).findings(projectFiles: [], walkIsComplete: true)

        let busy = try finding(at: jdk, in: found)
        XCTAssertEqual(busy.status, .inUse([running]))
        XCTAssertEqual(busy.bucket, .needsDecision)
    }

    /// Brief §5.9: `gradle.properties` can hold credentials and is never read, wherever it lies.
    func testNeverReadsGradleProperties() throws {
        let home = try CleanupTempHome()
        try distribution(home, "gradle-9.8.2-bin")
        try home.directory(".gradle/jdks/eclipse_adoptium-25-aarch64-os_x.2")
        try home.file(".gradle/gradle.properties", text: "repoPassword=secret\n")
        try home.file(".gradle/jdks/gradle.properties", text: "repoPassword=secret\n")
        let recording = RecordingCleanupFileSystem(wrapping: liveFileSystem)

        let found = detector(home, fileSystem: recording).findings(projectFiles: [], walkIsComplete: true)

        XCTAssertEqual(found.count, 2)
        XCTAssertFalse(recording.touched.isEmpty, "precondition: the detector reads through the injected file system")
        XCTAssertFalse(recording.touched.contains { $0.hasSuffix("/gradle.properties") }, "a gradle.properties was touched")
    }
}
