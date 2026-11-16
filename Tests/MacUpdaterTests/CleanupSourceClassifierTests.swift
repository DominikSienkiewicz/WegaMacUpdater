import Foundation
import XCTest
@testable import MacUpdaterCore

final class CleanupSourceClassifierTests: XCTestCase {
    private let home = "/Users/tester"
    private let brew = "/opt/homebrew"

    private func url(_ path: String) -> URL {
        URL(filePath: path, directoryHint: .notDirectory)
    }

    private func classifier(brewPrefix: String? = "/opt/homebrew") -> CleanupSourceClassifier {
        CleanupSourceClassifier(
            home: URL(filePath: home, directoryHint: .isDirectory),
            brewPrefix: brewPrefix.map { URL(filePath: $0, directoryHint: .isDirectory) }
        )
    }

    private func classify(_ path: String, brewPrefix: String? = "/opt/homebrew") -> CleanupSource {
        classifier(brewPrefix: brewPrefix).classify(url(path))
    }

    func testClassifiesEverySourceInSpecOrder() {
        let cases: [(String, CleanupSource)] = [
            ("/opt/homebrew/Caskroom/claude-code/2.1.311/claude", .homebrewCask(token: "claude-code")),
            ("\(home)/Library/Application Support/Claude/claude-code/2.1.320/abc/claude.app/Contents/MacOS/claude",
             .appManaged(owner: "Claude")),
            ("\(home)/Library/Application Support/Claude/claude-code-vm/2.1.1/claude", .appManaged(owner: "Claude")),
            ("/Applications/Ollama.app/Contents/Resources/ollama", .appBundle(name: "Ollama")),
            ("\(home)/.local/bin/gh", .standalone),
            ("/opt/homebrew/Cellar/gh/2.104.0/bin/gh", .homebrewFormula(name: "gh")),
            ("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", .packageManager(.npm)),
            ("\(home)/.nvm/versions/node/v22.1.0/lib/node_modules/x/bin/x", .packageManager(.npm)),
            ("\(home)/.local/share/mise/installs/node/22.1.0/bin/node", .versionManager(.mise)),
            ("\(home)/.cargo/bin/rustc", .versionManager(.rustup)),
            ("\(home)/.cargo/bin/ripgrep", .packageManager(.cargo)),
            ("\(home)/Library/pnpm/global/5/node_modules/x/bin/x", .packageManager(.pnpm)),
            ("\(home)/Library/pnpm/nodejs/22.1.0/bin/node", .versionManager(.pnpmEnv)),
            ("\(home)/.local/pipx/venvs/black/bin/black", .packageManager(.pipx)),
            ("\(home)/.local/share/pipx/venvs/black/bin/black", .packageManager(.pipx)),
            ("\(home)/go/bin/gopls", .packageManager(.go)),
            ("\(home)/.bun/bin/bun", .packageManager(.bun)),
            ("\(home)/.local/share/claude/versions/2.1.325", .nativeVersionDirectory(tool: "claude")),
            ("/usr/bin/git", .system),
            ("/Library/Developer/CommandLineTools/usr/bin/git", .system),
            ("/Applications/Xcode-beta.app/Contents/Developer/usr/bin/git", .appBundle(name: "Xcode-beta")),
            ("/usr/local/bin/tool", .standalone),
        ]
        for (path, expected) in cases {
            XCTAssertEqual(classify(path), expected, path)
        }
    }

    func testVersionManagerRootsAreRecognised() {
        let cases: [(String, CleanupVersionManager)] = [
            ("\(home)/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin/python", .uv),
            ("\(home)/.local/share/uv/tools/ruff/bin/ruff", .uv),
            ("\(home)/.local/share/fnm/node-versions/v22.1.0/installation/bin/node", .fnm),
            ("\(home)/.fnm/node-versions/v20.0.0/installation/bin/node", .fnm),
            ("\(home)/.nvm/versions/node/v18.0.0/bin/node", .nvm),
            ("\(home)/.pyenv/versions/3.12.1/bin/python", .pyenv),
            ("\(home)/.sdkman/candidates/java/21/bin/java", .sdkman),
            ("\(home)/.rustup/toolchains/stable/bin/rustc", .rustup),
            ("\(home)/.asdf/installs/nodejs/22/bin/node", .asdf),
            ("\(home)/.volta/tools/image/node/22/bin/node", .volta),
        ]
        for (path, manager) in cases {
            XCTAssertEqual(classify(path), .versionManager(manager), path)
        }
    }

    func testWithoutBrewPrefixCellarRulesAreDisabledButNpmStillMatches() {
        XCTAssertEqual(classify("/opt/homebrew/Cellar/gh/2.104.0/bin/gh", brewPrefix: nil), .standalone)
        XCTAssertEqual(
            classify("/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", brewPrefix: nil),
            .packageManager(.npm)
        )
    }

    func testPrefixMatchingUsesWholeCaseSensitiveComponents() {
        XCTAssertEqual(classify("/usr/binary/git"), .standalone)
        XCTAssertEqual(classify("/opt/homebrew/Cellarx/gh/1/bin/gh"), .standalone)
        XCTAssertEqual(classify("\(home)/.bunker/bin/bun"), .standalone)
        XCTAssertEqual(classify("/opt/homebrew/cellar/gh/1/bin/gh"), .standalone)
        XCTAssertEqual(classify("/opt/homebrew/Cellar"), .standalone)
        XCTAssertEqual(classify("/opt/homebrew/lib/node_modulesx/a"), .standalone)
        XCTAssertEqual(classify("/Applications/Tool.app/Resources/x"), .standalone)
        XCTAssertEqual(classify("/Applications/Tool.application/Contents/x"), .standalone)
    }

    func testCombiningMarkAfterSlashDoesNotFakeAComponentBoundary() {
        XCTAssertEqual(classify("/usr/bin/\u{301}git"), .system)
        XCTAssertEqual(classify("/usr/bin\u{301}/git"), .standalone)
    }

    func testCustomSystemPrefixesAndXcodeWildcard() {
        let custom = CleanupSourceClassifier(
            home: URL(filePath: home, directoryHint: .isDirectory),
            brewPrefix: nil,
            systemPrefixes: ["/opt/sys", "/Applications/Xcode*.app/Contents/Developer"]
        )
        XCTAssertEqual(custom.classify(url("/opt/sys/bin/x")), .system)
        XCTAssertEqual(custom.classify(url("/usr/bin/git")), .standalone)
        XCTAssertEqual(CleanupSourceClassifier.rustupProxyNames.count, 13)
    }

    func testKnownLayoutsExposeExactValues() {
        XCTAssertEqual(
            CleanupKnownLayouts.nativeVersionDirectories,
            [CleanupNativeLayout(
                tool: "claude", versionsDirectory: ".local/share/claude/versions", pointer: ".local/bin/claude"
            )]
        )
        XCTAssertEqual(
            CleanupKnownLayouts.appManagedLocations,
            [
                CleanupAppManagedLocation(owner: "Claude", path: "Library/Application Support/Claude/claude-code"),
                CleanupAppManagedLocation(owner: "Claude", path: "Library/Application Support/Claude/claude-code-vm"),
            ]
        )
    }

    func testExtractsVersionsOnlyFromKnownPathShapes() {
        func version(_ path: String, _ source: CleanupSource) -> String? {
            CleanupVersionExtractor.version(fromRealpath: url(path), source: source)
        }
        XCTAssertEqual(
            version("/opt/homebrew/Caskroom/claude-code/2.1.311/claude", .homebrewCask(token: "claude-code")),
            "2.1.311"
        )
        XCTAssertEqual(
            version("/opt/homebrew/Cellar/gh/2.104.0/bin/gh", .homebrewFormula(name: "gh")), "2.104.0"
        )
        XCTAssertEqual(
            version("\(home)/.local/share/claude/versions/2.1.325", .nativeVersionDirectory(tool: "claude")),
            "2.1.325"
        )
        XCTAssertEqual(
            version(
                "\(home)/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin/python3",
                .versionManager(.uv)
            ),
            "3.12.12"
        )
        XCTAssertEqual(
            version("\(home)/.local/share/fnm/node-versions/v22.1.0/installation/bin/node", .versionManager(.fnm)),
            "22.1.0"
        )
        XCTAssertEqual(
            version("\(home)/.nvm/versions/node/v18.0.0/bin/node", .versionManager(.nvm)), "18.0.0"
        )
        XCTAssertNil(version("\(home)/.local/bin/gh", .standalone))
        XCTAssertNil(version("/opt/homebrew/Cellar/gh", .homebrewFormula(name: "gh")))
        XCTAssertNil(version("/opt/homebrew/Cellar/other/1.0/bin/x", .homebrewFormula(name: "gh")))
        XCTAssertNil(version("\(home)/.local/share/mise/installs/node/22.1.0/bin/node", .versionManager(.mise)))
    }
}
