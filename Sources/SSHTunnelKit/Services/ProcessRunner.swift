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
                    let outData = (try? box.stdout.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? box.stderr.fileHandleForReading.readToEnd()) ?? Data()
                    cont.resume(returning: ProcessExecution(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
                }
                do {
                    try box.process.run()
                } catch {
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
            if box.process.isRunning {
                box.process.terminate()
                try? await Task.sleep(for: .seconds(1))
                if box.process.isRunning {
                    kill(box.process.processIdentifier, SIGKILL)
                }
            }
            return ProcessExecution(
                exitCode: ProcessExecution.timeoutExitCode,
                stdout: "",
                stderr: "process timed out after \(Int(timeout))s"
            )
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

    do {
        try process.run()
    } catch {
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
        return ProcessExecution(
            exitCode: ProcessExecution.timeoutExitCode,
            stdout: "",
            stderr: "process timed out after \(Int(timeout))s"
        )
    }

    let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
    let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
    return ProcessExecution(
        exitCode: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
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
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    let stdout: Pipe
    let stderr: Pipe

    init(process: Process, stdout: Pipe, stderr: Pipe) {
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
    }
}
