import Foundation
import Testing
@testable import MacUpdaterCore

@Suite("Vendor diagnostic evidence")
struct VendorDiagnosticTraceTests {
    @Test func candidateRecordsComparedVersionsAndPreservesOutdatedResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticTraceStore(directory: directory)
        let run = DiagnosticRun(trigger: "vendor-test", subjects: ["example"], store: store)
        let checker = TraceVendorChecker(evaluation: .candidate(.init(latest: "2.0", installed: "1.0", source: .signal)))

        let result = await UpdateDiagnostics.$current.withValue(run) {
            await checker.check(app: Self.app)
        }
        run.finish()

        guard case .outdated(let item) = result else {
            Issue.record("Expected the existing outdated outcome")
            return
        }
        #expect(item.availableVersion == "2.0")
        let events = store.events(runID: run.id)
        #expect(events.contains {
            $0.event == "vendor.parse" && $0.fields["installed"] == "1.0" && $0.fields["latest"] == "2.0"
        })
        #expect(events.contains { $0.event == "vendor.completed" && $0.fields["outcome"] == "outdated" })
    }

    @Test func failedEvaluationIsNotReportedAsCurrent() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DiagnosticTraceStore(directory: directory)
        let run = DiagnosticRun(trigger: "vendor-test", subjects: ["example"], store: store)

        let result = await UpdateDiagnostics.$current.withValue(run) {
            await TraceVendorChecker(evaluation: .decided(.failed)).check(app: Self.app)
        }
        run.finish()

        #expect(result == .failed)
        #expect(store.events(runID: run.id).contains {
            $0.event == "vendor.completed" && $0.fields["outcome"] == "failed"
        })
    }

    private static let app = ApplicationInfo(
        path: URL(fileURLWithPath: "/Applications/Example.app"), name: "Example", bundleIdentifier: "test.example",
        version: "1.0", installDate: nil, updateDate: nil, isManagedByBrew: false
    )
}

private struct TraceVendorChecker: VendorUpdateChecker {
    let evaluation: VendorEvaluation
    let client = HTTPClient(transport: TraceVendorTransport(), maxRetries: 0)

    func plan(for app: ApplicationInfo) -> VendorCheckPlan? {
        VendorCheckPlan(request: HTTPRequest(url: URL(string: "https://example.test/latest")!)) { _ in evaluation }
    }
}

private struct TraceVendorTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
