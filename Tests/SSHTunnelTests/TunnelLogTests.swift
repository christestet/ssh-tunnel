import XCTest
@testable import SSHTunnelKit

final class TunnelLogTests: XCTestCase {

    // MARK: LogLevel

    func testLogLevelIsOrdered() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.notice)
        XCTAssertLessThan(LogLevel.notice, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
        XCTAssertLessThan(LogLevel.error, LogLevel.off)
    }

    func testLogLevelAllowsEntriesAtOrAboveMinimum() {
        XCTAssertTrue(LogLevel.info.allows(.info))
        XCTAssertTrue(LogLevel.info.allows(.warning))
        XCTAssertFalse(LogLevel.info.allows(.debug))
    }

    func testLogLevelOffDisablesAllEntries() {
        for level in LogLevel.allCases {
            XCTAssertFalse(LogLevel.off.allows(level))
        }
    }

    // MARK: LogEntry formatting

    func testFormattedIncludesLevelCategoryAndMessage() {
        let entry = LogEntry(
            date: Date(timeIntervalSince1970: 0),
            category: .ssh,
            level: .warning,
            tunnel: nil,
            message: "ssh exited 255"
        )
        let line = entry.formatted()
        XCTAssertTrue(line.contains("WARN"))
        XCTAssertTrue(line.contains("ssh"))
        XCTAssertTrue(line.contains("ssh exited 255"))
    }

    func testFormattedIncludesTunnelScopeWhenPresent() {
        let entry = LogEntry(category: .master, level: .info, tunnel: "prod-db", message: "connected")
        XCTAssertTrue(entry.formatted().contains("[prod-db]"))
    }

    func testFormattedOmitsScopeWhenTunnelNil() {
        let entry = LogEntry(category: .lifecycle, level: .info, tunnel: nil, message: "launch")
        XCTAssertFalse(entry.formatted().contains("[]"))
    }

    // MARK: InMemoryLogRecorder

    func testRecorderStoresEntriesInOrder() {
        let recorder = InMemoryLogRecorder()
        recorder.log(.info, .ssh, "first")
        recorder.log(.info, .ssh, "second")
        let messages = recorder.entries().map(\.message)
        XCTAssertEqual(messages, ["first", "second"])
    }

    func testRecorderHonorsCapacityAsRingBuffer() {
        let recorder = InMemoryLogRecorder(capacity: 3)
        for i in 1...5 {
            recorder.log(.info, .ssh, "msg\(i)")
        }
        let messages = recorder.entries().map(\.message)
        XCTAssertEqual(messages, ["msg3", "msg4", "msg5"])
    }

    func testRecorderFormattedFiltersByMinimumLevel() {
        let recorder = InMemoryLogRecorder()
        recorder.log(.debug, .ssh, "noisy")
        recorder.log(.error, .ssh, "boom")
        let output = recorder.formatted(minimumLevel: .warning)
        XCTAssertFalse(output.contains("noisy"))
        XCTAssertTrue(output.contains("boom"))
    }

    func testRecorderFormattedFiltersByTunnel() {
        let recorder = InMemoryLogRecorder()
        recorder.log(.info, .master, tunnel: "a", "alpha")
        recorder.log(.info, .master, tunnel: "b", "beta")
        let output = recorder.formatted(tunnel: "a")
        XCTAssertTrue(output.contains("alpha"))
        XCTAssertFalse(output.contains("beta"))
    }

    func testRecorderClearEmptiesBuffer() {
        let recorder = InMemoryLogRecorder()
        recorder.log(.info, .ssh, "x")
        recorder.clear()
        XCTAssertTrue(recorder.entries().isEmpty)
    }

    // MARK: CompositeTunnelLogger

    func testCompositeFansOutToAllSinks() {
        let a = InMemoryLogRecorder()
        let b = InMemoryLogRecorder()
        let composite = CompositeTunnelLogger([a, b])
        composite.log(.notice, .reconnect, "scheduled")
        XCTAssertEqual(a.entries().count, 1)
        XCTAssertEqual(b.entries().count, 1)
    }

    func testEmptyCompositeIsNoOp() {
        let composite = CompositeTunnelLogger([])
        composite.log(.error, .ssh, "ignored")
        // No crash, nothing to assert beyond reaching here.
    }

    func testLevelFilteredLoggerDropsEntriesBelowMinimum() {
        let recorder = InMemoryLogRecorder()
        let gate = LogLevelGate(minimumLevel: .warning)
        let logger = LevelFilteredTunnelLogger(base: recorder, gate: gate)

        logger.log(.info, .ssh, "ignored")
        logger.log(.warning, .ssh, "kept")

        XCTAssertEqual(recorder.entries().map(\.message), ["kept"])
    }

    func testLevelFilteredLoggerCanBeUpdated() {
        let recorder = InMemoryLogRecorder()
        let gate = LogLevelGate(minimumLevel: .error)
        let logger = LevelFilteredTunnelLogger(base: recorder, gate: gate)

        logger.log(.warning, .ssh, "ignored")
        gate.minimumLevel = .warning
        logger.log(.warning, .ssh, "kept")

        XCTAssertEqual(recorder.entries().map(\.message), ["kept"])
    }

    func testLevelFilteredLoggerSkipsMessageEvaluationBelowMinimum() {
        let recorder = InMemoryLogRecorder()
        let gate = LogLevelGate(minimumLevel: .error)
        let logger = LevelFilteredTunnelLogger(base: recorder, gate: gate)
        var didEvaluate = false

        func expensiveMessage() -> String {
            didEvaluate = true
            return "debug details"
        }

        logger.log(.debug, .ssh, expensiveMessage())

        XCTAssertFalse(didEvaluate)
        XCTAssertTrue(recorder.entries().isEmpty)
    }

    @MainActor
    func testLogSettingsDefaultToWarnings() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            TunnelLog.levelGate.minimumLevel = .warning
        }

        let store = LogSettingsStore(defaults: defaults)

        XCTAssertEqual(store.minimumLevel, .warning)
        XCTAssertEqual(TunnelLog.levelGate.minimumLevel, .warning)
    }

    @MainActor
    func testLogSettingsPersistAndUpdateGlobalGate() {
        let (defaults, suite) = makeIsolatedDefaults()
        defer {
            defaults.removePersistentDomain(forName: suite)
            TunnelLog.levelGate.minimumLevel = .warning
        }

        let store = LogSettingsStore(defaults: defaults)
        store.minimumLevel = .error

        XCTAssertEqual(TunnelLog.levelGate.minimumLevel, .error)
        XCTAssertEqual(LogSettingsStore(defaults: defaults).minimumLevel, .error)
    }

    @MainActor
    func testTunnelControllerUsesGlobalLogLevelForTunnelLogs() {
        let previousLevel = TunnelLog.levelGate.minimumLevel
        TunnelLog.recorder.clear()
        TunnelLog.levelGate.minimumLevel = .warning
        defer {
            TunnelLog.levelGate.minimumLevel = previousLevel
            TunnelLog.recorder.clear()
        }

        let controller = TunnelController(
            settings: makeTestSettings(),
            sshRunner: StubSSHRunner(results: []),
            notifier: SpyTunnelNotifier(),
            startsMonitoring: false
        )

        controller.state = .connected
        XCTAssertFalse(TunnelLog.recorder.entries().contains { $0.message.contains("state") })

        TunnelLog.levelGate.minimumLevel = .debug
        controller.state = .disconnected

        XCTAssertTrue(TunnelLog.recorder.entries().contains { $0.level == .info && $0.message.contains("state") })
    }

    @MainActor
    private func makeIsolatedDefaults() -> (UserDefaults, String) {
        let suite = "log-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return (UserDefaults.standard, suite)
        }
        return (defaults, suite)
    }
}
