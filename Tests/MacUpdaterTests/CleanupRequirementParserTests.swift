import XCTest
@testable import MacUpdaterCore

final class CleanupRequirementParserTests: XCTestCase {
    private func parse(_ kind: CleanupProjectFileKind, _ text: String) -> [CleanupRequirement] {
        let url = URL(filePath: "/p/file", directoryHint: .notDirectory)
        return CleanupRequirementParser.requirements(in: CleanupProjectFile(url: url, kind: kind, text: text))
    }

    private func pairs(_ reqs: [CleanupRequirement]) -> [String] {
        reqs.map { "\($0.tool)=\($0.spec)" }
    }

    func testPythonVersionOnePinPerLineDroppingSystemAndComments() {
        let reqs = parse(.pythonVersion, "# note\n3.12.4\n\nsystem\n3.11\n")
        XCTAssertEqual(pairs(reqs), ["python=pin(\"3.12.4\")", "python=pin(\"3.11\")"])
    }

    func testNvmrcAndNodeVersionStripLeadingV() {
        XCTAssertEqual(pairs(parse(.nvmrc, "v20.1.0\n")), ["node=pin(\"20.1.0\")"])
        XCTAssertEqual(pairs(parse(.nodeVersion, "18\n")), ["node=pin(\"18\")"])
    }

    func testNvmrcAliasesAreUnresolvable() {
        for alias in ["lts/*", "lts/iron", "node", "stable", "latest"] {
            XCTAssertEqual(parse(.nvmrc, alias + "\n").map(\.spec), [.unresolvable(alias)], alias)
        }
    }

    func testToolVersionsPinsEachVersionAndDropsSystemRefPath() {
        let text = "nodejs 20.1.0 18.0.0\npython system\nruby ref:master\njava path:/x\nrust 1.80.0 # c\n"
        XCTAssertEqual(pairs(parse(.toolVersions, text)),
                       ["node=pin(\"20.1.0\")", "node=pin(\"18.0.0\")", "rust=pin(\"1.80.0\")"])
    }

    func testMiseTomlToolsForms() {
        let text = """
        [env]
        X = "1"
        [tools]
        node = "20"
        python = ["3.12", "3.11"]
        java = { version = "21" }
        rust = { components = "x" }
        go = "latest"
        Erlang = "lts"
        [other]
        zig = "0.1"
        """
        XCTAssertEqual(pairs(parse(.miseToml, text)), [
            "node=pin(\"20\")", "python=pin(\"3.12\")", "python=pin(\"3.11\")", "java=pin(\"21\")",
            "rust=unresolvable(\"{ components = \\\"x\\\" }\")", "go=unresolvable(\"latest\")", "erlang=unresolvable(\"lts\")"
        ])
    }

    func testPyprojectRanges() {
        let text = """
        [project]
        name = "x"
        requires-python = ">=3.10"
        [tool.poetry.dependencies]
        python = "^3.11"
        requests = "^2"
        """
        XCTAssertEqual(pairs(parse(.pyprojectToml, text)), ["python=range(\">=3.10\")", "python=range(\"^3.11\")"])
    }

    func testPackageJsonEnginesAndVolta() {
        let text = #"{"engines":{"node":">=18"},"volta":{"node":"20.5.0"}}"#
        XCTAssertEqual(pairs(parse(.packageJson, text)), ["node=range(\">=18\")", "node=pin(\"20.5.0\")"])
    }

    func testSdkmanrc() {
        let text = "# c\njava=21.0.2-tem\ngradle=8.5\n"
        XCTAssertEqual(pairs(parse(.sdkmanrc, text)), ["java=pin(\"21.0.2-tem\")", "gradle=pin(\"8.5\")"])
    }

    func testRustToolchainFiles() {
        XCTAssertEqual(pairs(parse(.rustToolchain, "\n1.75.0\nignored\n")), ["rust=pin(\"1.75.0\")"])
        XCTAssertEqual(pairs(parse(.rustToolchainToml, "[toolchain]\nchannel = \"nightly-2024-01-01\"\n")),
                       ["rust=pin(\"nightly-2024-01-01\")"])
    }

    func testPyvenvCfgHomeIsAPath() {
        let text = "home = /opt/homebrew/bin\ninclude-system-site-packages = false\n"
        XCTAssertEqual(pairs(parse(.pyvenvCfg, text)), ["python=path(\"/opt/homebrew/bin\")"])
    }

    func testGradleKindsYieldNothing() {
        for kind in [CleanupProjectFileKind.gradleWrapperProperties, .gradleDaemonJvmProperties, .gradleBuildScript] {
            XCTAssertTrue(parse(kind, "x=1").isEmpty)
        }
    }

    func testGarbageYieldsNoRequirementsNotACrash() {
        let binary = String(decoding: [0, 255, 254, 1, 2, 0x5B, 0x74] as [UInt8], as: UTF8.self)
        let huge = String(repeating: "a", count: 300_000)
        let garbage = ["[tools\nnode = \"2", "{\"engines\": {", binary, huge, "= = =\n[[[", "node = [\"a\""]
        for kind in [CleanupProjectFileKind.miseToml, .pyprojectToml, .packageJson, .rustToolchainToml, .toolVersions, .sdkmanrc, .pyvenvCfg] {
            for text in garbage { _ = parse(kind, text) }
        }
        XCTAssertTrue(parse(.packageJson, "{\"engines\": {").isEmpty)
        XCTAssertTrue(parse(.miseToml, binary).isEmpty)
        XCTAssertTrue(parse(.pyprojectToml, "[project\nrequires-python = ").isEmpty)
    }

    func testRequirementsCarryTheirSourceFile() {
        let url = URL(filePath: "/proj/.nvmrc", directoryHint: .notDirectory)
        let reqs = CleanupRequirementParser.requirements(in: CleanupProjectFile(url: url, kind: .nvmrc, text: "20\n"))
        XCTAssertEqual(reqs.map(\.source), [url])
    }
}
