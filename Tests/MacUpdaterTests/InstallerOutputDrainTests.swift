import Foundation
import Testing
@testable import WegaHelperKit

@Suite("Installer output does not block completion")
struct InstallerOutputDrainTests {
    @Test(.timeLimit(.minutes(1))) func drainsMoreThanAPipeBufferAndRetainsOnlyATail() async throws {
        // Bound the test child itself: a regression that stops draining pipes also blocks
        // the synchronous runner, so cooperative task cancellation alone cannot end it.
        let script = """
        writer=$$
        (sleep 15; kill -TERM "$writer") >/dev/null 2>&1 &
        watchdog=$!
        i=0
        while [ $i -lt 20000 ]; do
            echo stderr-line >&2
            echo stdout-line
            i=$((i+1))
        done
        echo final-diagnostic >&2
        kill "$watchdog" 2>/dev/null
        wait "$watchdog" 2>/dev/null
        exit 7
        """
        let result = try InstallerProcess.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            outputLimit: 1024
        )
        #expect(result.exitCode == 7)
        #expect(result.standardError.utf8.count <= 1024)
        #expect(result.standardError.contains("final-diagnostic"))
    }
}
