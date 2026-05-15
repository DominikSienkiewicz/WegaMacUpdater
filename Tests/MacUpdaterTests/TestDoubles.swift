import Foundation
@testable import MacUpdaterCore

final class StubProcessRunner: ProcessRunning {
    let result: ProcessResult
    init(result: ProcessResult) { self.result = result }
    func run(_ request: ProcessRequest) async throws -> ProcessResult { result }
    func events(for request: ProcessRequest) -> AsyncThrowingStream<ProcessOutputEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
