import Foundation
import Synchronization

struct ProcessExecution: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    static let timeoutExitCode: Int32 = -2
    static let spawnFailedExitCode: Int32 = -1
}

/// Runs an external process to completion or a hard timeout. On timeout the
/// process is sent SIGTERM, given 1 s, then SIGKILL'd if still running.
///
/// Replaces the four near-identical race-vs-timeout loops we used to have in
/// `ProcessSSHRunner.run`, `LocalPortAvailabilityChecker.runCapturing`, etc.
///
/// stdout/stderr are drained *concurrently* while the process runs (see
/// `ProcessBox.beginDraining`). Reading only inside `terminationHandler`
/// deadlocks any child that writes more than the ~64 KiB OS pipe buffer
/// (e.g. `ssh -G` on a large config, or `lsof -p`): the child blocks on
/// `write()`, so it never exits, so the termination handler never fires.
func runProcess(
    executable: URL,
    arguments: [String],
    timeout: TimeInterval
) async -> ProcessExecution {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let box = ProcessBox(process: process, stdout: stdoutPipe, stderr: stderrPipe)

    return await withTaskGroup(of: ProcessExecution?.self) { group in
        group.addTask {
            await withCheckedContinuation { (cont: CheckedContinuation<ProcessExecution, Never>) in
                box.process.terminationHandler = { proc in
                    let output = box.finishDraining()
                    // If the timeout branch already SIGTERM'd this child, its
                    // termination handler fires with the *signal* status and an
                    // empty stderr, racing — and usually beating — the timeout
                    // task's own result. Honour the timeout marker here so the
                    // "timed out" diagnostic isn't silently lost no matter which
                    // task wins the group race.
                    if box.didTimeOut {
                        cont.resume(returning: timeoutResult(timeout: timeout, partial: output))
                    } else {
                        cont.resume(returning: ProcessExecution(
                            exitCode: proc.terminationStatus,
                            stdout: output.stdout,
                            stderr: output.stderr
                        ))
                    }
                }
                do {
                    box.beginDraining()
                    try box.process.run()
                } catch {
                    // run() threw: no child was spawned, so the write ends of
                    // the pipes are still open in this process and `readToEnd()`
                    // would block forever. Just stop draining and report.
                    box.cancelDraining()
                    cont.resume(returning: ProcessExecution(
                        exitCode: ProcessExecution.spawnFailedExitCode,
                        stdout: "",
                        stderr: "\(error)"
                    ))
                }
            }
        }
        group.addTask {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                // Cancelled — *not* a real timeout. Tear down the subprocess so
                // the termination task above resumes with the real exit status,
                // and return nil so this task loses the race instead of
                // fabricating a bogus "process timed out" result.
                if box.process.isRunning {
                    box.process.terminate()
                }
                return nil
            }
            // Record the timeout *before* terminating so the termination
            // handler (which fires on SIGTERM) reports the timeout marker too,
            // not the raw signal status.
            box.markTimedOut()
            if box.process.isRunning {
                box.process.terminate()
                try? await Task.sleep(for: .seconds(1))
                if box.process.isRunning {
                    kill(box.process.processIdentifier, SIGKILL)
                }
            }
            // Hand back whatever we managed to drain before the timeout so the
            // failure is at least diagnosable, alongside the timeout marker.
            return timeoutResult(timeout: timeout, partial: box.bufferedOutput())
        }
        // Take the first *real* result. A nil means the timeout task observed
        // cancellation and bowed out; keep waiting for the genuine termination
        // result from the process task.
        var result: ProcessExecution?
        while result == nil {
            guard let next = await group.next() else { break }
            if let value = next {
                result = value
            }
        }
        group.cancelAll()
        return result ?? ProcessExecution(
            exitCode: ProcessExecution.spawnFailedExitCode, stdout: "", stderr: ""
        )
    }
}

/// Builds the timeout result (marker exit code + a "timed out" note appended to
/// whatever was drained) shared by the timeout task and the termination handler
/// so both report the failure identically regardless of which wins the race.
private func timeoutResult(
    timeout: TimeInterval,
    partial: (stdout: String, stderr: String)
) -> ProcessExecution {
    let note = "process timed out after \(Int(timeout))s"
    let stderr = partial.stderr.isEmpty ? note : "\(partial.stderr)\n(\(note))"
    return ProcessExecution(
        exitCode: ProcessExecution.timeoutExitCode,
        stdout: partial.stdout,
        stderr: stderr
    )
}

func runProcessSynchronously(
    executable: URL,
    arguments: [String],
    timeout: TimeInterval
) -> ProcessExecution {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Drain concurrently on Foundation's internal queue so the child never
    // blocks on a full pipe while this thread is polling `isRunning`.
    let outBuffer = OutputBuffer()
    let errBuffer = OutputBuffer()
    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { outBuffer.append(chunk) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        if chunk.isEmpty { handle.readabilityHandler = nil } else { errBuffer.append(chunk) }
    }

    do {
        try process.run()
    } catch {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return ProcessExecution(
            exitCode: ProcessExecution.spawnFailedExitCode,
            stdout: "",
            stderr: "\(error)"
        )
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return ProcessExecution(
            exitCode: ProcessExecution.timeoutExitCode,
            stdout: outBuffer.string(),
            stderr: "process timed out after \(Int(timeout))s"
        )
    }

    // Process exited normally: stop draining and pick up any final bytes the
    // termination raced ahead of.
    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    if let rest = try? stdoutPipe.fileHandleForReading.readToEnd() { outBuffer.append(rest) }
    if let rest = try? stderrPipe.fileHandleForReading.readToEnd() { errBuffer.append(rest) }
    return ProcessExecution(
        exitCode: process.terminationStatus,
        stdout: outBuffer.string(),
        stderr: errBuffer.string()
    )
}

/// Generic race-vs-timeout. Returns whichever finishes first; if `work` times
/// out, returns `fallback`. The losing task is cancelled but caller is
/// responsible for any external resource cleanup (e.g. cancelling NWConnection).
func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    default fallback: T,
    work: @Sendable @escaping () async -> T
) async -> T {
    await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
        let race = TimeoutRace(continuation: continuation)
        let workTask = Task {
            let result = await work()
            race.finish(result, winner: .work)
        }
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            race.finish(fallback, winner: .timeout)
        }
        race.setTasks(work: workTask, timeout: timeoutTask)
    }
}

private enum TimeoutWinner {
    case work
    case timeout
}

private final class TimeoutRace<T: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, Never>?
        var workTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
    }

    private let state: Mutex<State>

    init(continuation: CheckedContinuation<T, Never>) {
        state = Mutex(State(continuation: continuation))
    }

    func setTasks(work: Task<Void, Never>, timeout: Task<Void, Never>) {
        let alreadyFinished = state.withLock { state -> Bool in
            guard state.continuation != nil else { return true }
            state.workTask = work
            state.timeoutTask = timeout
            return false
        }
        if alreadyFinished {
            work.cancel()
            timeout.cancel()
        }
    }

    func finish(_ value: T, winner: TimeoutWinner) {
        let outcome = state.withLock { state -> (CheckedContinuation<T, Never>?, Task<Void, Never>?) in
            guard let continuation = state.continuation else {
                return (nil, nil)
            }
            state.continuation = nil
            let loser = winner == .work ? state.timeoutTask : state.workTask
            state.workTask = nil
            state.timeoutTask = nil
            return (continuation, loser)
        }
        outcome.1?.cancel()
        outcome.0?.resume(returning: value)
    }
}

/// Confines the `@unchecked Sendable` shortcut for Foundation's non-Sendable
/// `Process`/`Pipe` types to one small object shared by the race branches.
/// Output is accumulated into `Mutex`-guarded buffers as it arrives.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe
    private let outBuffer = OutputBuffer()
    private let errBuffer = OutputBuffer()
    private let timedOut = Mutex(false)

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Set by the timeout branch before it SIGTERMs the child, so the
    /// termination handler can tell a deliberate timeout-kill apart from a
    /// natural exit. Mutex-guarded: written on the timeout task, read on the
    /// pipe/termination queue.
    func markTimedOut() { timedOut.withLock { $0 = true } }
    var didTimeOut: Bool { timedOut.withLock { $0 } }

    /// Start draining both pipes as data arrives, so a chatty child never
    /// blocks on a full pipe waiting for us to read.
    func beginDraining() {
        let out = outBuffer
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { out.append(chunk) }
        }
        let err = errBuffer
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { err.append(chunk) }
        }
    }

    /// Stop draining without reading — used on spawn failure where the write
    /// ends are still open and `readToEnd()` would block.
    func cancelDraining() {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
    }

    /// Stop draining and capture anything still buffered. Safe once the process
    /// has exited: the write ends are closed, so the final read returns EOF.
    func finishDraining() -> (stdout: String, stderr: String) {
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        if let rest = try? stdout.fileHandleForReading.readToEnd() { outBuffer.append(rest) }
        if let rest = try? stderr.fileHandleForReading.readToEnd() { errBuffer.append(rest) }
        return (outBuffer.string(), errBuffer.string())
    }

    /// A snapshot of what has been drained so far, without stopping draining.
    func bufferedOutput() -> (stdout: String, stderr: String) {
        (outBuffer.string(), errBuffer.string())
    }
}

/// Thread-safe accumulator for subprocess output. `Mutex` confines the only
/// mutable state so the surrounding `@unchecked Sendable` box stays honest.
private final class OutputBuffer: Sendable {
    private let storage = Mutex<Data>(Data())

    func append(_ chunk: Data) {
        storage.withLock { $0.append(chunk) }
    }

    func string() -> String {
        storage.withLock { String(data: $0, encoding: .utf8) ?? "" }
    }
}
