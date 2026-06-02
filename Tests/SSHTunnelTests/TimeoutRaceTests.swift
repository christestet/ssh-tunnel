import XCTest
@testable import SSHTunnelKit

final class TimeoutRaceTests: XCTestCase {

    @MainActor
    func testWithTimeoutReturnsFallbackWhenWorkNeverResumes() async {
        let didFinish = expectation(description: "withTimeout returned")

        Task { @MainActor in
            let result = await withTimeout(seconds: 0.05, default: "timed-out") {
                await withUnsafeContinuation { (_: UnsafeContinuation<String, Never>) in
                    // Intentionally never resumed. This models APIs whose
                    // cancellation does not immediately complete the callback.
                }
            }
            XCTAssertEqual(result, "timed-out")
            didFinish.fulfill()
        }

        await fulfillment(of: [didFinish], timeout: 1.0)
    }

    /// A cancelled `runProcess` must NOT report a fabricated "process timed
    /// out" (`timeoutExitCode`). Previously `try? await Task.sleep` swallowed
    /// the cancellation and returned an instant bogus timeout, which sent the
    /// reconnect loop into a tight `ssh -O check` storm.
    func testRunProcessDoesNotReportTimeoutWhenCancelled() async {
        let started = expectation(description: "process task started")
        let finished = expectation(description: "runProcess returned")

        let task = Task<ProcessExecution, Never> {
            started.fulfill()
            // Long timeout so a real timeout cannot occur within the test.
            return await runProcess(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 30
            )
        }

        await fulfillment(of: [started], timeout: 1.0)
        // Give the subprocess a moment to actually launch, then cancel.
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let result = await task.value
        finished.fulfill()
        await fulfillment(of: [finished], timeout: 1.0)

        XCTAssertNotEqual(
            result.exitCode,
            ProcessExecution.timeoutExitCode,
            "cancellation must not be reported as a timeout"
        )
    }
}