import Foundation
import Testing
@testable import WegaHelperKit

@Suite("Installer output does not block completion")
struct InstallerOutputDrainTests {
    @Test(.timeLimit(.minutes(1))) func drainsMoreThanAPipeBufferAndRetainsOnlyATail() async throws {
        // Bound the test child itself: a regression that stops draining pipes also blocks
        // the synchronous runner, so cooperative task cancellation alone cannot end it.
        // 12 000 lines per stream is ~140 KB, more than twice a 64 KB pipe buffer.
        let script = """
        writer=$$
        (sleep 15; kill -TERM "$writer") >/dev/null 2>&1 &
        watchdog=$!
        i=0
        while [ $i -lt 12000 ]; do
            echo stderr-line >&2
            echo stdout-line
            i=$((i+1))
        done
        echo final-diagnostic >&2
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        exit 7
        """
        let result = try await offCooperativePool {
            try InstallerProcess.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                outputLimit: 1024
            )
        }
        #expect(result.exitCode == 7)
        #expect(result.standardError.utf8.count <= 1024)
        #expect(result.standardError.contains("final-diagnostic"))
    }

    /// `InstallerProcess.run` blocks its caller until the child exits. Called straight from an
    /// async test it parks a cooperative-pool thread for seconds, which on a narrow CI runner
    /// starves the timing-sensitive suites running beside it.
    @Test func testsNeverBlockTheCooperativePoolOnTheInstaller() throws {
        let testsRoot = packageRoot().appendingPathComponent("Tests")
        let files = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        let blockingCall = try Regex(#"InstallerProcess\.run\("#)
        let isolatedCall = try Regex(#"offCooperativePool \{\s*try InstallerProcess\.run\("#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let blockingCalls = source.matches(of: blockingCall).count
            let isolatedCalls = source.matches(of: isolatedCall).count
            #expect(
                blockingCalls == isolatedCalls,
                "\(file.lastPathComponent) calls InstallerProcess.run without offCooperativePool"
            )
        }
    }

    private func offCooperativePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Thread { continuation.resume(with: Result { try body() }) }.start()
        }
    }

    private func packageRoot(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
