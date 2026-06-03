import Foundation
import XCTest
@testable import SSHTunnelKit

// MARK: - Loopback TCP listener for probe tests

/// Binds a real TCP listener on 127.0.0.1 with an OS-assigned port. Used so
/// the TCP probe in TunnelController.checkTunnelHealth has something to
/// connect to.
final class LoopbackListener {
    let port: Int
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "LoopbackListener", code: Int(errno)) }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // ask kernel for a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackListener", code: Int(errno))
        }
        guard listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackListener", code: Int(errno))
        }

        var assigned = sockaddr_in()
        var assignedLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &assignedLen)
            }
        }
        guard getResult == 0 else {
            Darwin.close(fd)
            throw NSError(domain: "LoopbackListener", code: Int(errno))
        }

        self.fd = fd
        self.port = Int(UInt16(bigEndian: assigned.sin_port))
    }

    func close() {
        _ = Darwin.close(fd)
    }
}

// MARK: - Test doubles

final class FakeLongRunning: SSHLongRunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _isRunning: Bool = true
    private var exitCode: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    var stderr: String = ""

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    func terminate() { finish(code: 0) }
    func killHard() { finish(code: 9) }

    func simulateUnexpectedExit(code: Int32, stderr: String = "") {
        self.stderr = stderr
        finish(code: code)
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            lock.lock()
            if let code = exitCode {
                lock.unlock()
                cont.resume(returning: code)
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func collectStderr() -> String { stderr }

    private func finish(code: Int32) {
        lock.lock()
        guard _isRunning else { lock.unlock(); return }
        _isRunning = false
        exitCode = code
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for cont in pending {
            cont.resume(returning: code)
        }
    }
}

final class StubSSHRunner: SSHRunning, @unchecked Sendable {
    private var results: [SSHResult]
    private(set) var calls: [[String]] = []
    private(set) var longRunningCalls: [[String]] = []
    var longRunningFactory: (@Sendable ([String]) -> FakeLongRunning) = { _ in FakeLongRunning() }
    var startLongRunningError: Error?

    init(results: [SSHResult]) {
        self.results = results
    }

    func run(arguments: [String], timeout: TimeInterval) async -> SSHResult {
        calls.append(arguments)
        if results.isEmpty {
            return SSHResult(exitCode: 1, stdout: "", stderr: "missing stub result")
        }
        return results.removeFirst()
    }

    func startLongRunning(arguments: [String]) throws -> SSHLongRunningProcess {
        longRunningCalls.append(arguments)
        if let e = startLongRunningError { throw e }
        return longRunningFactory(arguments)
    }
}

final class StubPortChecker: PortAvailabilityChecking, @unchecked Sendable {
    /// Map of port → conflict, consulted by both `firstConflict` and
    /// `conflicts(among:)` when their respective override queues are empty.
    var conflictsByPort: [Int: PortConflict] = [:]
    var conflictResults: [PortConflict?] = []
    /// Queue of full conflict lists, dequeued by `conflicts(among:)`.
    var conflictsListResults: [[PortConflict]] = []
    var freePorts: [Int] = []
    var shouldFailFindFreePort = false
    private(set) var queries: [[Int]] = []

    func conflicts(among ports: [Int]) async -> [PortConflict] {
        if !conflictsListResults.isEmpty {
            return conflictsListResults.removeFirst()
        }
        return ports.compactMap { conflictsByPort[$0] }
    }

    func firstConflict(among ports: [Int]) async -> PortConflict? {
        queries.append(ports)
        if !conflictResults.isEmpty {
            return conflictResults.removeFirst()
        }
        for p in ports {
            if let c = conflictsByPort[p] { return c }
        }
        return nil
    }

    func findFreePort(in range: ClosedRange<Int>) async -> Int? {
        if shouldFailFindFreePort { return nil }
        if !freePorts.isEmpty {
            return freePorts.removeFirst()
        }
        return range.lowerBound
    }
}

final class StubForwardHealthChecker: ForwardHealthChecking, @unchecked Sendable {
    var unreachablePorts: [Int] = []
    /// When non-empty, each probe dequeues one set of unreachable ports. Lets a
    /// test model a forward that is dead on the first probe and healthy after a
    /// repair attempt.
    var unreachableSequence: [[Int]] = []
    private(set) var checks: [([Int], TimeInterval)] = []

    func firstUnreachablePort(among ports: [Int], timeout: TimeInterval) async -> Int? {
        checks.append((ports, timeout))
        let unreachable: [Int]
        if !unreachableSequence.isEmpty {
            unreachable = unreachableSequence.removeFirst()
        } else {
            unreachable = unreachablePorts
        }
        return ports.first { unreachable.contains($0) }
    }
}

final class StubSSHMasterClient: SSHMasterClienting, @unchecked Sendable {
    var resolvedOptions: [SSHHostOptions?] = []
    var checkResults: [SSHResult] = []
    /// When non-empty, each `addForward` dequeues one result; lets a test model
    /// a forward that fails to establish. Defaults to exit 0 when empty.
    var addForwardResults: [SSHResult] = []
    var startMasterError: Error?
    var masterFactory: (@Sendable () -> FakeLongRunning) = { FakeLongRunning() }

    private(set) var resolveHosts: [String] = []
    private(set) var checkCalls: [(host: String, controlPath: String, timeout: TimeInterval)] = []
    private(set) var exitCalls: [(host: String, controlPath: String)] = []
    private(set) var synchronousExitCalls: [(host: String, controlPath: String, timeout: TimeInterval)] = []
    private(set) var startCalls: [(host: String, controlPath: String, clearConfigForwards: Bool)] = []
    private(set) var addForwardCalls: [(remotePort: Int, localPort: Int, remoteHost: String, target: SSHControlTarget, controlPath: String)] = []
    private(set) var removeForwardCalls: [(remotePort: Int, localPort: Int, target: SSHControlTarget, controlPath: String)] = []

    func resolveOptions(forHost host: String) async -> SSHHostOptions? {
        resolveHosts.append(host)
        if resolvedOptions.isEmpty { return nil }
        return resolvedOptions.removeFirst() ?? nil
    }

    func check(host: String, controlPath: String, timeout: TimeInterval) async -> SSHResult {
        checkCalls.append((host, controlPath, timeout))
        if checkResults.isEmpty {
            return SSHResult(exitCode: 1, stdout: "", stderr: "missing stub result")
        }
        return checkResults.removeFirst()
    }

    func startMaster(host: String, controlPath: String, clearConfigForwards: Bool) throws -> SSHLongRunningProcess {
        startCalls.append((host, controlPath, clearConfigForwards))
        if let startMasterError { throw startMasterError }
        return masterFactory()
    }

    func exit(host: String, controlPath: String) async -> SSHResult {
        exitCalls.append((host, controlPath))
        return SSHResult(exitCode: 0, stdout: "", stderr: "")
    }

    func exitSynchronously(host: String, controlPath: String, timeout: TimeInterval) -> SSHResult {
        synchronousExitCalls.append((host, controlPath, timeout))
        return SSHResult(exitCode: 0, stdout: "", stderr: "")
    }

    func addForward(remotePort: Int, localPort: Int, remoteHost: String, target: SSHControlTarget, controlPath: String) async -> SSHResult {
        addForwardCalls.append((remotePort, localPort, remoteHost, target, controlPath))
        if addForwardResults.isEmpty {
            return SSHResult(exitCode: 0, stdout: "", stderr: "")
        }
        return addForwardResults.removeFirst()
    }

    func removeForward(remotePort: Int, localPort: Int, target: SSHControlTarget, controlPath: String) async -> SSHResult {
        removeForwardCalls.append((remotePort, localPort, target, controlPath))
        return SSHResult(exitCode: 0, stdout: "", stderr: "")
    }
}

final class SpyTunnelNotifier: TunnelNotifying {
    struct CheckResult: Equatable {
        let host: String
        let ok: Bool
        let detail: String
    }

    /// The real notifier now requests authorization lazily as part of
    /// delivering a notification (rather than per-controller at init), so this
    /// flips the first time any notification is sent.
    private(set) var didRequestAuthorization = false
    private(set) var interruptedHosts: [String] = []
    private(set) var failedResults: [CheckResult] = []
    private(set) var checkResults: [CheckResult] = []

    func sendTunnelInterruptedNotification(for settings: TunnelSettings) {
        didRequestAuthorization = true
        interruptedHosts.append(settings.hostAlias)
    }

    func sendTunnelFailedNotification(for settings: TunnelSettings, detail: String) {
        didRequestAuthorization = true
        failedResults.append(CheckResult(host: settings.hostAlias, ok: false, detail: detail))
    }

    func sendCheckResultNotification(for settings: TunnelSettings, ok: Bool, detail: String) {
        didRequestAuthorization = true
        checkResults.append(CheckResult(host: settings.hostAlias, ok: ok, detail: detail))
    }
}

@MainActor
final class SpyLoginItemManager: LoginItemManaging {
    private(set) var isEnabled: Bool
    private(set) var setEnabledCalls: [Bool] = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func setEnabled(_ enabled: Bool) {
        setEnabledCalls.append(enabled)
        isEnabled = enabled
    }
}

// MARK: - Shared factory & constants

@MainActor
func makeTestSettings(controlPath: String = "~/.ssh/test-control") -> TunnelSettings {
    TunnelSettings(
        id: UUID(),
        name: "Test Tunnel",
        hostAlias: "test-host",
        controlPath: controlPath,
        healthCheckInterval: 999,
        maxBackoff: 999,
        autostartOnLogin: false
    )
}

/// Polls `condition` on the main actor until it becomes true or `timeout`
/// elapses. Sleeping yields the main actor, letting an in-flight
/// `Task { await controller.startTunnel() }` advance to its suspension point
/// (e.g. the port-conflict prompt continuation). Returns false on timeout.
@MainActor
@discardableResult
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Starts the tunnel, waits for the port-conflict prompt to appear, answers it
/// once with `localPort` (nil = cancel), and waits for the start flow to
/// finish. Use for single-config-forward conflict scenarios.
@MainActor
func startTunnelResolvingConflict(
    _ controller: TunnelController,
    with localPort: Int?,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let task = Task { await controller.startTunnel() }
    let appeared = await waitUntil { controller.pendingPortConflict != nil }
    if appeared {
        controller.resolvePortConflict(localPort: localPort)
    }
    await task.value
}

/// `ssh -G` empty success — used wherever the test doesn't care about the
/// resolved options themselves.
let gEmpty = SSHResult(exitCode: 0, stdout: "", stderr: "")
let masterReady = SSHResult(exitCode: 0, stdout: "", stderr: "")
/// `-O check` returning exit 1 — no live master at this control path. Stubbed
/// between resolveOptions and masterReady for fresh-start scenarios so the
/// new adopt-first flow falls through to the spawn path.
let preCheckMiss = SSHResult(exitCode: 1, stdout: "", stderr: "no master")
