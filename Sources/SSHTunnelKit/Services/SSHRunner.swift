import Foundation
import Synchronization

struct SSHResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    static let timeoutExitCode: Int32 = -2
}

protocol SSHLongRunningProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
    func killHard()
    func waitForExit() async -> Int32
    func collectStderr() -> String
}

protocol SSHRunning: Sendable {
    func run(arguments: [String], timeout: TimeInterval) async -> SSHResult
    func startLongRunning(arguments: [String]) throws -> SSHLongRunningProcess
}

extension SSHRunning {
    func run(arguments: [String]) async -> SSHResult {
        await run(arguments: arguments, timeout: 10)
    }
}

protocol SSHMasterClienting: Sendable {
    func resolveOptions(forHost host: String) async -> SSHHostOptions?
    func check(host: String, controlPath: String, timeout: TimeInterval) async -> SSHResult
    func startMaster(host: String, controlPath: String) throws -> SSHLongRunningProcess
    func exit(host: String, controlPath: String) async -> SSHResult
    func exitSynchronously(host: String, controlPath: String, timeout: TimeInterval) -> SSHResult
    func addForward(remotePort: Int, localPort: Int, target: SSHControlTarget, controlPath: String) async -> SSHResult
    func removeForward(remotePort: Int, localPort: Int, target: SSHControlTarget, controlPath: String) async -> SSHResult
}

struct SSHControlTarget: Equatable, Sendable {
    let host: String
    let user: String?
    let port: String?
    let readsSSHConfig: Bool

    static func configured(hostAlias: String) -> SSHControlTarget {
        SSHControlTarget(host: hostAlias, user: nil, port: nil, readsSSHConfig: true)
    }

    static func resolved(options: SSHHostOptions, fallbackHostAlias: String) -> SSHControlTarget {
        SSHControlTarget(
            host: options.hostname.isEmpty ? fallbackHostAlias : options.hostname,
            user: options.user.isEmpty ? nil : options.user,
            port: options.port.isEmpty ? nil : options.port,
            readsSSHConfig: false
        )
    }

    var arguments: [String] {
        var args: [String] = []
        if !readsSSHConfig {
            args += ["-F", "/dev/null"]
        }
        if let user {
            args += ["-l", user]
        }
        if let port {
            args += ["-p", port]
        }
        args.append(host)
        return args
    }
}

struct OpenSSHMasterClient: SSHMasterClienting {
    private let runner: SSHRunning
    private let inspector: SSHConfigInspector

    init(runner: SSHRunning = ProcessSSHRunner()) {
        self.runner = runner
        self.inspector = SSHConfigInspector(runner: runner)
    }

    func resolveOptions(forHost host: String) async -> SSHHostOptions? {
        await inspector.resolveOptions(forHost: host)
    }

    func check(host: String, controlPath: String, timeout: TimeInterval) async -> SSHResult {
        await runner.run(arguments: [
            "-S", controlPath,
            "-O", "check",
            host
        ], timeout: timeout)
    }

    func startMaster(host: String, controlPath: String) throws -> SSHLongRunningProcess {
        try runner.startLongRunning(arguments: [
            "-N", "-M",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=10",
            "-S", controlPath,
            host
        ])
    }

    func exit(host: String, controlPath: String) async -> SSHResult {
        await runner.run(arguments: [
            "-S", controlPath,
            "-O", "exit",
            host
        ], timeout: 3)
    }

    func exitSynchronously(host: String, controlPath: String, timeout: TimeInterval) -> SSHResult {
        let result = runProcessSynchronously(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-S", controlPath,
                "-O", "exit",
                host
            ],
            timeout: timeout
        )
        return SSHResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    func addForward(remotePort: Int, localPort: Int, target: SSHControlTarget, controlPath: String) async -> SSHResult {
        await runner.run(arguments: [
            "-S", controlPath,
            "-O", "forward",
            "-L", "\(localPort):localhost:\(remotePort)"
        ] + target.arguments, timeout: 5)
    }

    func removeForward(remotePort: Int, localPort: Int, target: SSHControlTarget, controlPath: String) async -> SSHResult {
        await runner.run(arguments: [
            "-S", controlPath,
            "-O", "cancel",
            "-L", "\(localPort):localhost:\(remotePort)"
        ] + target.arguments, timeout: 5)
    }
}

struct ProcessSSHRunner: SSHRunning {
    private let logger: any TunnelLogging

    init(logger: any TunnelLogging = TunnelLog.shared) {
        self.logger = logger
    }

    func run(arguments: [String], timeout: TimeInterval) async -> SSHResult {
        logger.log(.debug, .ssh, "exec: ssh \(arguments.joined(separator: " ")) (timeout \(Int(timeout))s)")
        let result = await runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: arguments,
            timeout: timeout
        )
        let trimmedErr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            logger.log(.debug, .ssh, "exit 0: ssh \(SSHRunnerLog.summary(of: arguments))")
        } else {
            let detail = trimmedErr.isEmpty ? "(no stderr)" : trimmedErr
            logger.log(.notice, .ssh, "exit \(result.exitCode): ssh \(SSHRunnerLog.summary(of: arguments)) — \(detail)")
        }
        return SSHResult(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr)
    }

    func startLongRunning(arguments: [String]) throws -> SSHLongRunningProcess {
        logger.log(.info, .master, "spawn master: ssh \(arguments.joined(separator: " "))")
        let handle = ProcessSSHLongRunning(arguments: arguments)
        do {
            try handle.start()
        } catch {
            logger.log(.error, .master, "spawn master failed: \(error)")
            throw error
        }
        return handle
    }
}

/// Small helpers for rendering ssh invocations compactly in logs.
enum SSHRunnerLog {
    /// Condenses an ssh argument vector to the operation + host so result logs
    /// stay scannable (e.g. `-O check <host>`), instead of repeating the full
    /// `-S <controlPath>` boilerplate already printed at exec time.
    static func summary(of arguments: [String]) -> String {
        if let idx = arguments.firstIndex(of: "-O"), idx + 1 < arguments.count {
            let op = arguments[idx + 1]
            let host = arguments.last ?? ""
            return "-O \(op) \(host)"
        }
        return arguments.last ?? arguments.joined(separator: " ")
    }
}

/// Long-running `ssh -N -M` master handle.
///
/// `Process` is not `Sendable`, so the class is `@unchecked Sendable`. All
/// *mutable* state (exit code + waiter continuations) lives inside a
/// `Synchronization.Mutex`, so the shortcut is contained to Foundation's
/// non-Sendable types rather than smuggling raw mutable state across actors.
private final class ProcessSSHLongRunning: SSHLongRunningProcess, @unchecked Sendable {
    private let process = Process()
    private let stderrPipe = Pipe()
    private let nullPipe = Pipe()
    private let stderrBuffer = StderrBuffer()
    private let state = Mutex(State())

    private struct State {
        var exitCode: Int32?
        var waiters: [CheckedContinuation<Int32, Never>] = []
    }

    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardError = stderrPipe
        process.standardOutput = nullPipe

        let buffer = stderrBuffer
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
        }

        process.terminationHandler = { [weak self] proc in
            self?.handleExit(code: proc.terminationStatus)
        }
    }

    func start() throws {
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    func killHard() {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let alreadyExited: Int32? = state.withLock { s in
                if let code = s.exitCode {
                    return code
                }
                s.waiters.append(cont)
                return nil
            }
            if let code = alreadyExited {
                cont.resume(returning: code)
            }
        }
    }

    func collectStderr() -> String {
        stderrBuffer.snapshot()
    }

    private func handleExit(code: Int32) {
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let pending = state.withLock { s -> [CheckedContinuation<Int32, Never>] in
            s.exitCode = code
            let copy = s.waiters
            s.waiters.removeAll()
            return copy
        }
        for cont in pending {
            cont.resume(returning: code)
        }
    }
}

private final class StderrBuffer: Sendable {
    private let storage = Mutex<Data>(Data())

    func append(_ chunk: Data) {
        storage.withLock { data in
            data.append(chunk)
            if data.count > 16_384 {
                data = data.suffix(8_192)
            }
        }
    }

    func snapshot() -> String {
        storage.withLock { data in
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}
