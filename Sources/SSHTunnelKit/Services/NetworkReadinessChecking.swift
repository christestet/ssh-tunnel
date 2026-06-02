import Foundation
import Network
import Synchronization

protocol NetworkReadinessChecking: Sendable {
    func canReach(host: String, port: Int, timeout: TimeInterval) async -> Bool
}

struct TCPNetworkReadinessChecker: NetworkReadinessChecking {
    func canReach(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty,
              (1...65535).contains(port),
              let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(trimmedHost),
            port: nwPort,
            using: .tcp
        )
        let connectionBox = ReadinessConnectionBox(connection: connection)
        defer { connectionBox.connection.cancel() }

        return await withTimeout(seconds: timeout, default: false) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let gate = ReadinessOneShotBool { continuation.resume(returning: $0) }
                connectionBox.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        gate.fire(true)
                    case .failed, .cancelled:
                        gate.fire(false)
                    default:
                        break
                    }
                }
                connectionBox.connection.start(queue: .global())
            }
        }
    }
}

private final class ReadinessConnectionBox: @unchecked Sendable {
    let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }
}

private final class ReadinessOneShotBool: Sendable {
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