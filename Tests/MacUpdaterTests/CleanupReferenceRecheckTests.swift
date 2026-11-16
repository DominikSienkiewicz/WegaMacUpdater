import XCTest
@testable import MacUpdaterCore

/// The project roots Settings holds right now; the live re-check reads them when it runs.
private final class ProjectRootsSetting: @unchecked Sendable {
    private let lock = NSLock()
    private var roots: [URL]

    init(_ roots: [URL]) {
        self.roots = roots
    }

    var current: [URL] {
        get { lock.withLock { roots } }
        set { lock.withLock { roots = newValue } }
    }
}

/// `CleanupLiveReferenceRecheck` over a temporary home: what appeared after the scan keeps a D6 or
/// D7 item, and what the re-check cannot read does not.
final class CleanupReferenceRecheckTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var fileSystem: CleanupFileSystem!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        fileSystem = GuardedCleanupFileSystem(
            base: LiveCleanupFileSystem(trash: { _ in }),
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
    }

    func testLiveRecheckSeesANewWrapper() async throws {
        let distribution = try gradleDistribution("gradle-8.10-bin")
        try tmp.file("Dev/app/settings.gradle.kts", text: "rootProject.name = \"app\"\n")
        let item = try leftoverFinding(distribution, detector: .gradle, tool: "gradle", reason: .unusedGradleDistribution)
        let recheck = liveRecheck(roots: ProjectRootsSetting([tmp.url("Dev")]))
        let beforeTheWrapper = try await recheck.isStillUnreferenced(item)
        XCTAssertTrue(beforeTheWrapper, "precondition: no wrapper names the distribution yet")

        try wrapper("Dev/app", distribution: "gradle-8.10-bin")
        let afterTheWrapper = try await recheck.isStillUnreferenced(item)

        XCTAssertFalse(afterTheWrapper)
    }

    /// The remover outlives a Settings change, so the roots are read when the re-check runs.
    func testLiveRecheckReadsTheProjectRootsWhenItRuns() async throws {
        let distribution = try gradleDistribution("gradle-8.10-bin")
        try wrapper("Work/app", distribution: "gradle-8.10-bin")
        let item = try leftoverFinding(distribution, detector: .gradle, tool: "gradle", reason: .unusedGradleDistribution)
        let roots = ProjectRootsSetting([tmp.url("Dev")])
        let recheck = liveRecheck(roots: roots)
        let withoutWork = try await recheck.isStillUnreferenced(item)
        XCTAssertTrue(withoutWork, "precondition: the wrapper lies outside the configured roots")

        roots.current = [tmp.url("Dev"), tmp.url("Work")]
        let withWork = try await recheck.isStillUnreferenced(item)

        XCTAssertFalse(withWork)
    }

    /// The JDK's major is read again the way the scan read it; a toolchain asking for that major,
    /// or a JDK that is no longer the major the scan saw, keeps it.
    func testLiveRecheckSeesANewToolchain() async throws {
        let jdk = try tmp.directory(".gradle/jdks/eclipse_adoptium-21-aarch64-os_x.2")
        try tmp.file(
            ".gradle/jdks/eclipse_adoptium-21-aarch64-os_x.2/jdk-21.0.5+11/Contents/Home/release",
            text: "IMPLEMENTOR=\"Eclipse Adoptium\"\nJAVA_VERSION=\"21.0.5\"\n"
        )
        let item = try leftoverFinding(jdk, detector: .gradle, tool: "java", reason: .unreferencedJDK(major: 21))
        let otherMajor = try leftoverFinding(jdk, detector: .gradle, tool: "java", reason: .unreferencedJDK(major: 17))
        try tmp.file("Dev/app/build.gradle.kts", text: "plugins { java }\n")
        let recheck = liveRecheck(roots: ProjectRootsSetting([tmp.url("Dev")]))
        let beforeTheToolchain = try await recheck.isStillUnreferenced(item)
        XCTAssertTrue(beforeTheToolchain, "precondition: no project asks for Java 21 yet")
        let notTheScannedJDK = try await recheck.isStillUnreferenced(otherMajor)
        XCTAssertFalse(notTheScannedJDK, "the JDK on disk is not the Java 17 the scan saw")

        try tmp.file("Dev/app/gradle/gradle-daemon-jvm.properties", text: "toolchainVersion=21\n")
        let afterTheToolchain = try await recheck.isStillUnreferenced(item)

        XCTAssertFalse(afterTheToolchain)
    }

    func testLiveRecheckSeesANewlyInstalledIDE() async throws {
        try ide("Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let folder = try jetBrainsFolder("Library/Caches/JetBrains/IntelliJIdea2025.3")
        let backup = try jetBrainsFolder("Library/Application Support/JetBrains/IntelliJIdea2025.3-backup")
        let items = [
            try leftoverFinding(folder, detector: .jetBrains, tool: "IntelliJIdea", reason: .ideVersionNotInstalled(installed: ["2026.3"])),
            try leftoverFinding(backup, detector: .jetBrains, tool: "IntelliJIdea", reason: .ideVersionNotInstalled(installed: ["2026.3"])),
        ]
        let recheck = liveRecheck(roots: ProjectRootsSetting([]))
        for item in items {
            let beforeTheInstall = try await recheck.isStillUnreferenced(item)
            XCTAssertTrue(beforeTheInstall, "precondition: \(item.path.lastPathComponent)")
        }

        try ide("Applications/IntelliJ IDEA 2025.3.app", dataDirectoryName: "IntelliJIdea2025.3")

        for item in items {
            let afterTheInstall = try await recheck.isStillUnreferenced(item)
            XCTAssertFalse(afterTheInstall, item.path.lastPathComponent)
        }
    }

    /// An IDE of the product whose product-info cannot be read could be this version, as in the scan.
    func testLiveRecheckLeavesAProductWithAnUnreadableIDEAlone() async throws {
        try ide("Applications/IntelliJ IDEA.app", dataDirectoryName: "IntelliJIdea2026.3")
        let folder = try jetBrainsFolder("Library/Caches/JetBrains/IntelliJIdea2025.3")
        let item = try leftoverFinding(folder, detector: .jetBrains, tool: "IntelliJIdea", reason: .ideVersionNotInstalled(installed: ["2026.3"]))
        let recheck = liveRecheck(roots: ProjectRootsSetting([]))
        let beforeTheInstall = try await recheck.isStillUnreferenced(item)
        XCTAssertTrue(beforeTheInstall, "precondition: only IntelliJ IDEA 2026.3 is installed")

        try tmp.file("Applications/IntelliJ IDEA 2025.app/Contents/MacOS/idea", size: 64, executable: true)
        let afterTheInstall = try await recheck.isStillUnreferenced(item)

        XCTAssertFalse(afterTheInstall)
    }

    /// A root that is missing or refused holds no reference the re-check can read; the user already
    /// confirmed an item that needed a decision, so only a reference it can read keeps the item.
    func testLiveRecheckCountsWhatItCannotReadAsUnreferenced() async throws {
        let distribution = try gradleDistribution("gradle-8.10-bin")
        try wrapper("Library/Mobile Documents/app", distribution: "gradle-8.10-bin")
        let item = try leftoverFinding(distribution, detector: .gradle, tool: "gradle", reason: .unusedGradleDistribution)
        let recheck = liveRecheck(roots: ProjectRootsSetting([tmp.url("Missing"), tmp.url("Library/Mobile Documents")]))

        let stillUnreferenced = try await recheck.isStillUnreferenced(item)

        XCTAssertTrue(stillUnreferenced)
    }

    // MARK: Helpers

    private func liveRecheck(roots: ProjectRootsSetting) -> CleanupLiveReferenceRecheck {
        CleanupLiveReferenceRecheck(
            fileSystem: fileSystem, home: tmp.home,
            inspector: FakeProcessInspector(processes: [], bootTime: Date(timeIntervalSince1970: 0)),
            projectRoots: { roots.current }, applicationDirectories: [tmp.url("Applications")]
        )
    }

    /// A D6 or D7 finding that trashes `url`, identified as the scan saw it.
    private func leftoverFinding(
        _ url: URL, detector: CleanupDetectorID, tool: String, reason: CleanupReason
    ) throws -> CleanupFinding {
        CleanupFinding(
            detector: detector, tool: tool, path: url, realpath: nil, source: nil, version: nil, size: nil,
            status: .unused, reason: reason, action: .trash([url]), risk: .low, bucket: .needsDecision,
            identity: try XCTUnwrap(fileSystem.entry(at: url), "nothing at \(url.path)").identity
        )
    }

    /// A distribution as the wrapper unpacks it: `dists/<name>/<hash>/<name without type>/…`.
    private func gradleDistribution(_ name: String) throws -> URL {
        try tmp.file(".gradle/wrapper/dists/\(name)/a1b2c3/gradle-8.10/lib/gradle-core.jar", size: 8192)
        return tmp.url(".gradle/wrapper/dists/\(name)")
    }

    private func wrapper(_ project: String, distribution: String) throws {
        try tmp.file(
            "\(project)/gradle/wrapper/gradle-wrapper.properties",
            text: "distributionBase=GRADLE_USER_HOME\ndistributionUrl=https\\://services.gradle.org/distributions/\(distribution).zip\n"
        )
    }

    private func jetBrainsFolder(_ relative: String) throws -> URL {
        try tmp.file("\(relative)/options/ide.general.xml", size: 2048)
        return tmp.url(relative)
    }

    private func ide(_ bundle: String, dataDirectoryName: String) throws {
        try tmp.file("\(bundle)/Contents/MacOS/idea", size: 64, executable: true)
        try tmp.file(
            "\(bundle)/Contents/Resources/product-info.json",
            text: #"{"name": "IntelliJ IDEA", "dataDirectoryName": "\#(dataDirectoryName)"}"#
        )
    }
}
