import Foundation
import XCTest
@testable import SSHTunnelKit

/// Holds a checked continuation that only the cancellation path resolves —
/// models an `NWConnection`-style probe whose callback never fires on its own.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Never>?
    private var resumed = false

    func store(_ continuation: CheckedContinuation<String, Never>) {
        lock.lock()
        if resumed {
            lock.unlock()
            // Cancellation already won the race before we stored the
            // continuation; resume immediately so it isn't leaked.
            continuation.resume(returning: "cancelled-before-store")
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(returning value: String) {
        lock.lock()
        let pending = continuation
        continuation = nil
        resumed = true
        lock.unlock()
        pending?.resume(returning: value)
    }

    var didResume: Bool {
        lock.lock(); defer { lock.unlock() }
        return resumed
    }
}

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

    /// On the timeout branch the losing `work` task is cancelled. For an
    /// `NWConnection`-style probe whose continuation is *only* resolved by the
    /// cancellation path, that continuation must still be resumed — otherwise it
    /// leaks the task forever. Proves the contract the TCP probes rely on.
    func testWithTimeoutResumesWorkContinuationOnTimeoutViaCancellation() async {
        let box = ContinuationBox()

        let result = await withTimeout(seconds: 0.05, default: "timeout") {
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    box.store(cont)
                }
            } onCancel: {
                box.resume(returning: "cancelled")
            }
        }

        XCTAssertEqual(result, "timeout", "timeout must win when work never completes")

        // The cancelled work task runs its handler asynchronously; wait for it.
        var waited = 0
        while !box.didResume && waited < 200 {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        XCTAssertTrue(
            box.didResume,
            "work continuation must be resumed via cancellation, not leaked"
        )
    }

    /// A child that emits far more than the ~64 KiB OS pipe buffer must not
    /// deadlock: previously output was read only inside `terminationHandler`,
    /// so the child blocked on `write()` and was eventually killed, surfacing a
    /// bogus timeout with no output.
    func testRunProcessDrainsLargeStdoutWithoutDeadlock() async {
        let result = await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "50000"],
            timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0, "seq must run to completion, not time out")
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 50000, "all output must be captured, not truncated")
        XCTAssertEqual(lines.last.map(String.init), "50000")
    }

    func testRunProcessSynchronouslyDrainsLargeStdoutWithoutDeadlock() {
        let result = runProcessSynchronously(
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "50000"],
            timeout: 30
        )

        XCTAssertEqual(result.exitCode, 0)
        let lines = result.stdout.split(separator: "\n")
        XCTAssertEqual(lines.count, 50000)
        XCTAssertEqual(lines.last.map(String.init), "50000")
    }
}