import XCTest
@testable import MacUpdaterCore

final class CleanupShellFileAttributionTests: XCTestCase {
    private var tmp: CleanupTempHome!
    private var recording: RecordingCleanupFileSystem!
    private var etc: URL!

    override func setUpWithError() throws {
        tmp = try CleanupTempHome()
        etc = try tmp.directory("etc")
        recording = RecordingCleanupFileSystem(wrapping: LiveCleanupFileSystem(trash: { _ in }))
    }

    private func attribution(shell: String? = "zsh") -> CleanupShellFileAttribution {
        let guarded = GuardedCleanupFileSystem(
            base: recording,
            guard: ProtectedLocationGuard(home: tmp.home, mounts: FixedMountTable(["/"]))
        )
        return CleanupShellFileAttribution(
            shell: shell, home: tmp.home, systemConfigurationDirectory: etc, fileSystem: guarded
        )
    }

    private func location(_ relative: String, _ line: Int) -> CleanupShellFileLocation {
        CleanupShellFileLocation(file: tmp.url(relative).path, line: line)
    }

    func testFindsEveryHomeSpellingAndSkipsComments() throws {
        let home = tmp.home.path
        try tmp.file(".zshrc", text: """
        # ~/.a
        export PATH="$HOME/.a:$PATH"
        path+=(~/.a)
        export PATH=${HOME}/.a/:$PATH
        PATH=\(home)/.a:$PATH
        """)

        let found = attribution().locations(of: "\(home)/.a")

        XCTAssertEqual(found, [2, 3, 4, 5].map { location(".zshrc", $0) })
    }

    func testMatchesWholeComponentsOnly() throws {
        try tmp.file(".zshrc", text: """
        export PATH=/opt/homebrew/bin2:$PATH
        export PATH=/usr/opt/homebrew/bin:$PATH
        export PATH=/opt/homebrew/bin/:$PATH
        """)

        XCTAssertEqual(attribution().locations(of: "/opt/homebrew/bin"), [location(".zshrc", 3)])
    }

    func testEntryIsNotAttributedToALongerPathUnderIt() throws {
        let home = tmp.home.path
        try tmp.file(".zshrc", text: """
        export PATH="$HOME/Library/pnpm/bin:$PATH"
        export PNPM_HOME="$HOME/Library/pnpm"
        path+=(~/.local/bin)
        export PATH=$HOME:$PATH
        export PATH=/opt/homebrew/bin/:$PATH
        export PATH="/opt/homebrew/bin/"
        """)

        let found = attribution()
        XCTAssertEqual(found.locations(of: home + "/Library/pnpm"), [location(".zshrc", 2)])
        XCTAssertEqual(found.locations(of: home), [location(".zshrc", 4)])
        XCTAssertEqual(found.locations(of: "/opt/homebrew/bin"), [location(".zshrc", 5), location(".zshrc", 6)])
    }

    func testTrailingSlashEntryIsAttributed() throws {
        try tmp.file(".zshrc", text: "export PATH=~/.a:$PATH\n")

        XCTAssertEqual(attribution().locations(of: tmp.home.path + "/.a/"), [location(".zshrc", 1)])
    }

    func testEntryFollowedByAParameterExpansionIsAttributed() throws {
        try tmp.file(".zshrc", text: """
        PATH="/opt/x${PATH:+:$PATH}"
        PATH=/opt/y$PATH
        export PATH=/opt/x2${PATH:+:$PATH}
        """)

        let found = attribution()
        XCTAssertEqual(found.locations(of: "/opt/x"), [location(".zshrc", 1)])
        XCTAssertEqual(found.locations(of: "/opt/y"), [location(".zshrc", 2)])
    }

    func testRootEntryIsNeverTrimmed() throws {
        try tmp.file(".zshrc", text: "export PATH=/:$PATH\nexport PATH=:$PATH\n")

        XCTAssertEqual(attribution().locations(of: "/"), [location(".zshrc", 1)])
    }

    func testPathsFilesAreAttributed() throws {
        try tmp.file("etc/paths", text: "/usr/local/bin\n/usr/bin\n")
        try tmp.file("etc/paths.d/10-pkg", text: "/pkg/env/global/bin\n")

        let found = attribution()
        XCTAssertEqual(found.locations(of: "/usr/local/bin"), [location("etc/paths", 1)])
        XCTAssertEqual(found.locations(of: "/pkg/env/global/bin"), [location("etc/paths.d/10-pkg", 1)])
    }

    func testBashReadsBashFilesOnly() throws {
        try tmp.file(".bash_profile", text: "export PATH=/x/y:$PATH\n")
        try tmp.file(".zshrc", text: "export PATH=/x/y:$PATH\n")
        try tmp.file("etc/paths", text: "/x/y\n")

        XCTAssertEqual(
            attribution(shell: "bash").locations(of: "/x/y"),
            [location(".bash_profile", 1), location("etc/paths", 1)]
        )
        XCTAssertEqual(attribution(shell: "fish").locations(of: "/x/y"), [location("etc/paths", 1)])
        XCTAssertEqual(attribution(shell: nil).locations(of: "/x/y"), [location("etc/paths", 1)])
    }

    func testZshFilesAreReadInShellOrder() throws {
        try tmp.file(".zshrc", text: "PATH=/x/y\n")
        try tmp.file(".zshenv", text: "PATH=/x/y\n")
        try tmp.file("etc/zprofile", text: "PATH=/x/y\n")

        XCTAssertEqual(
            attribution().locations(of: "/x/y"),
            [location("etc/zprofile", 1), location(".zshenv", 1), location(".zshrc", 1)]
        )
    }

    func testCRLFAndMissingFinalNewlineKeepLineNumbers() throws {
        try tmp.file(".zshrc", text: "a\r\nexport PATH=/x/y")

        XCTAssertEqual(attribution().locations(of: "/x/y"), [location(".zshrc", 2)])
    }

    func testMatchingIsLiteral() throws {
        try tmp.file(".zshrc", text: "export PATH=/opt/homebrew/opt/pythonX3.12/libexec/bin:$PATH\n")

        XCTAssertEqual(attribution().locations(of: "/opt/homebrew/opt/python@3.12/libexec/bin"), [])
        XCTAssertEqual(attribution().locations(of: "/opt/homebrew/opt/python.3.12/libexec/bin"), [])
    }

    func testOversizedFileIsSkipped() throws {
        let filler = String(repeating: "a", count: CleanupShellFileAttribution.maximumFileBytes - 10)
        try tmp.file(".zshrc", text: "PATH=/x/y\n" + filler + "\nPATH=/x/y")

        XCTAssertEqual(attribution().locations(of: "/x/y"), [])
    }

    func testShellFileLinkedIntoDocumentsIsNeverRead() throws {
        let target = try tmp.file("Documents/dotfiles/zshrc", text: "PATH=/x/y\n")
        try tmp.symlink(".zshrc", to: target.path)

        let found = attribution()

        XCTAssertEqual(found.locations(of: "/x/y"), [])
        XCTAssertFalse(found.skippedProtected.isEmpty)
        XCTAssertFalse(recording.touched.contains { $0.hasPrefix(tmp.home.path + "/Documents") })
    }

    func testTextNeverLeavesTheType() throws {
        try tmp.file(".zshrc", text: "export TOKEN=SENTINEL_9f3\n")
        let found = attribution()
        var dumped = ""
        dump(found, to: &dumped)

        XCTAssertFalse(String(describing: found).contains("SENTINEL_9f3"))
        XCTAssertFalse(String(reflecting: found).contains("SENTINEL_9f3"))
        XCTAssertFalse(dumped.contains("SENTINEL_9f3"))
        XCTAssertTrue(String(describing: found).contains("1"))
    }
}
