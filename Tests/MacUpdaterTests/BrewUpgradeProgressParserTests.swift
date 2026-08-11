import Testing
@testable import MacUpdaterCore

/// The markers were read off the installed Homebrew (`cask/installer.rb:172` and `:252`,
/// `upgrade.rb:214`, `cask/upgrade.rb:405`, `curl_download_strategy.rb:67`,
/// `formula_installer.rb:1479`), so these lines are transcripts, not inventions.
@Suite("BrewUpgradeProgressParser")
struct BrewUpgradeProgressParserTests {

    @Test func namesTheCaskAnUpgradeStarts() {
        #expect(BrewUpgradeProgressParser.event(for: "==> Upgrading firefox")
                == .packageStarted(token: "firefox"))
        #expect(BrewUpgradeProgressParser.event(for: "==> Installing Cask firefox")
                == .packageStarted(token: "firefox"))
    }

    @Test func namesTheFormulaAnUpgradeStarts() {
        #expect(BrewUpgradeProgressParser.event(for: "==> Upgrading homebrew/core/node")
                == .packageStarted(token: "homebrew/core/node"))
        #expect(BrewUpgradeProgressParser.event(for: "==> Upgrading python@3.12")
                == .packageStarted(token: "python@3.12"))
    }

    /// A batch header reaches the same prefix as a package. A count is not a package.
    @Test func readsABatchHeaderAsNoPackageAtAll() {
        #expect(BrewUpgradeProgressParser.event(for: "==> Upgrading 3 outdated packages:") == nil)
    }

    /// Downloads run in parallel by default, so a bare download line may not be attributed
    /// to any package — but brew names the formula it fetches for.
    @Test func reportsADownloadWithoutInventingAPackage() {
        #expect(BrewUpgradeProgressParser.event(for: "==> Downloading https://cdn.example.com/Firefox.dmg")
                == .downloadStarted(token: nil))
        #expect(BrewUpgradeProgressParser.event(for: "==> Fetching downloads for: node")
                == .downloadStarted(token: "node"))
    }

    @Test func closesACaskOnItsOwnSuccessLine() {
        #expect(BrewUpgradeProgressParser.event(for: "🍺  firefox was successfully upgraded!")
                == .packageFinished(token: "firefox"))
        #expect(BrewUpgradeProgressParser.event(for: "firefox was successfully installed!")
                == .packageFinished(token: "firefox"))
    }

    /// A formula closes with its Cellar path, not its name — crediting that would credit a
    /// package called `/opt/homebrew/Cellar/git/2.45.0:`.
    @Test func ignoresTheCellarPathAFormulaEndsWith() {
        #expect(BrewUpgradeProgressParser.event(for: "🍺  /opt/homebrew/Cellar/git/2.45.0: 1,600 files, 50MB")
                == nil)
        // The line above is turned away by the success-suffix check before the parser ever
        // looks at the token. This one carries the suffix, so a path really does reach the
        // rule that rejects it — the guard the first line was believed to exercise.
        #expect(BrewUpgradeProgressParser.event(for: "🍺  /opt/homebrew/Cellar/git/2.45.0 was successfully installed!")
                == nil)
    }

    @Test func ignoresEverythingElseBrewPrints() {
        let noise = [
            "==> Purging files for version 139.0 of Cask firefox",
            "==> Pouring node--24.0.0.arm64_sequoia.bottle.tar.gz",
            "Warning: firefox 140 is already installed",
            "Error: Failure while executing; `/usr/bin/ditto` exited with 1.",
            ""
        ]
        for line in noise {
            #expect(BrewUpgradeProgressParser.event(for: line) == nil, "unexpected event for: \(line)")
        }
    }
}
