import Foundation
import Network
import Synchronization

protocol ForwardHealthChecking: Sendable {
    func firstUnreachablePort(among ports: [Int], timeout: TimeInterval) async -> Int?
}

struct TCPForwardHealthChecker: ForwardHealthChecking {
    func firstUnreachablePort(among ports: [Int], timeout: TimeInterval) async -> Int? {
        for port in ports {
            if await tcpProbe(port: port, timeout: timeout) { continue }
            return port
        }
        return nil
    }

    /// Returns `true` if a TCP connection to `127.0.0.1:port` reaches `.ready`
    /// within `timeout`.
    private func tcpProbe(port: Int, timeout: TimeInterval) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let connBox = NWConnectionBox(conn: NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp))
        defer { connBox.conn.cancel() }

        return await withTimeout(seconds: timeout, default: false) {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // `stateUpdateHandler` may fire multiple times; the
                // continuation must resume exactly once.
                let gate = OneShotBool { cont.resume(returning: $0) }
                connBox.conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.fire(true)
                    case .failed, .cancelled: gate.fire(false)
                    default: break
                    }
                }
                connBox.conn.start(queue: .global())
            }
        }
    }
}

/// Holds the `NWConnection` so race branches can share it without
/// `nonisolated(unsafe)` captures. `NWConnection` is a reference type
/// without Sendable conformance.
private final class NWConnectionBox: @unchecked Sendable {
    let conn: NWConnection
    init(conn: NWConnection) { self.conn = conn }
}

/// Ensures a continuation is resumed at most once even though
/// `NWConnection.stateUpdateHandler` can fire repeatedly.
private final class OneShotBool: Sendable {
    private let slot: Mutex<(@Sendable (Bool) -> Void)?>

    init(_ block: @escaping @Sendable (Bool) -> Void) {
        self.slot = Mutex(block)
    }

    func fire(_ value: Bool) {
        let block = slot.withLock { current -> (@Sendable (Bool) -> Void)? in
            let captured = current
            current = nil
            return captured
        }
        block?(value)
    }
}
