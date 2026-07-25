import Testing
@testable import MacUpdaterCore

@Suite("Operation coordinator")
struct OperationCoordinatorTests {
    @Test func collidingWritesRunOneAtATimeInArrivalOrder() async {
        let coordinator = OperationCoordinator()
        let probe = OperationProbe()

        let first = Task {
            await coordinator.withWrite(label: "first") {
                await probe.begin("first")
                try? await Task.sleep(for: .milliseconds(40))
                await probe.end("first")
            }
        }
        await probe.waitUntilStarted("first")

        let second = Task {
            await coordinator.withWrite(label: "second") {
                await probe.begin("second")
                await probe.end("second")
            }
        }

        await first.value
        await second.value

        #expect(await probe.maximumActiveCount == 1)
        #expect(await probe.events == ["begin:first", "end:first", "begin:second", "end:second"])
    }

    @Test func readsMayOverlapButAQueuedWriteWaitsForEveryReader() async {
        let coordinator = OperationCoordinator()
        let probe = OperationProbe()

        let firstRead = Task {
            await coordinator.withRead(label: "read-1") {
                await probe.begin("read-1")
                try? await Task.sleep(for: .milliseconds(40))
                await probe.end("read-1")
            }
        }
        await probe.waitUntilStarted("read-1")

        let secondRead = Task {
            await coordinator.withRead(label: "read-2") {
                await probe.begin("read-2")
                try? await Task.sleep(for: .milliseconds(40))
                await probe.end("read-2")
            }
        }
        await probe.waitUntilStarted("read-2")

        let write = Task {
            await coordinator.withWrite(label: "write") {
                await probe.begin("write")
                await probe.end("write")
            }
        }

        await firstRead.value
        await secondRead.value
        await write.value

        #expect(await probe.maximumActiveCount == 2)
        let events = await probe.events
        let writeStart = events.firstIndex(of: "begin:write")
        let lastReadEnd = ["end:read-1", "end:read-2"].compactMap(events.firstIndex(of:)).max()
        #expect(writeStart != nil)
        #expect(lastReadEnd != nil)
        if let writeStart, let lastReadEnd {
            #expect(lastReadEnd < writeStart)
        }
    }
}

private actor OperationProbe {
    private(set) var events: [String] = []
    private(set) var maximumActiveCount = 0
    private var activeCount = 0

    func begin(_ label: String) {
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        events.append("begin:\(label)")
    }

    func end(_ label: String) {
        events.append("end:\(label)")
        activeCount -= 1
    }

    func waitUntilStarted(_ label: String) async {
        while !events.contains("begin:\(label)") {
            await Task.yield()
        }
    }
}
