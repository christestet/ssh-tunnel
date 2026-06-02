import Foundation
import Synchronization
import os

/// Subsystem used for every `os.Logger` this app emits. Filter for it in
/// Console.app (`subsystem:com.sshtunnel.app`) or `log stream --predicate
/// 'subsystem == "com.sshtunnel.app"'` to watch the tunnel lifecycle live.
public let tunnelLogSubsystem = "com.sshtunnel.app"

/// Functional area a log entry belongs to. Maps 1:1 onto an `os.Logger`
/// category so you can narrow Console.app to e.g. only the `ssh` invocations
/// while chasing a connection bug.
public enum LogCategory: String, Sendable, CaseIterable {
    /// App/manager lifecycle: launch, autostart, shutdown.
    case lifecycle
    /// Raw `ssh` process invocations (arguments, exit code, stderr).
    case ssh
    /// Control-master lifecycle: spawn, ready-wait, adoption, exit.
    case master
    /// Quick forwards and ssh_config LocalForward add/remove/apply.
    case forward
    /// Network path changes and wake-driven recovery.
    case network
    /// Local port availability and conflict resolution.
    case ports
    /// Reconnect/backoff scheduling.
    case reconnect
    /// Periodic health checks and forward reachability probes.
    case health
}

/// Severity of a log entry. Ordered so callers can threshold (e.g. only keep
/// `>= .warning`). Maps onto `OSLogType`.
public enum LogLevel: Int, Sendable, Comparable, CustomStringConvertible, Codable, CaseIterable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4
    case off = 5

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .off: return "OFF"
        }
    }

    public var label: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .warning: return "Warnings"
        case .error: return "Errors"
        case .off: return "Off"
        }
    }

    public func allows(_ level: LogLevel) -> Bool {
        guard self != .off, level != .off else { return false }
        return level >= self
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .error
        case .error: return .fault
        case .off: return .debug
        }
    }
}

/// A single structured log record. Immutable and `Sendable` so it can be
/// shipped between actors and stored in the in-memory recorder for in-app
/// inspection/export.
public struct LogEntry: Sendable, Equatable {
    public let date: Date
    public let category: LogCategory
    public let level: LogLevel
    /// Optional tunnel identity (name or host alias) the entry relates to, so
    /// the in-app log can be filtered per tunnel.
    public let tunnel: String?
    public let message: String

    public init(
        date: Date = Date(),
        category: LogCategory,
        level: LogLevel,
        tunnel: String? = nil,
        message: String
    ) {
        self.date = date
        self.category = category
        self.level = level
        self.tunnel = tunnel
        self.message = message
    }

    /// One-line, human-readable rendering used by the in-app log export.
    public func formatted() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: date)
        let scope = tunnel.map { " [\($0)]" } ?? ""
        return "\(stamp) \(level) \(category.rawValue)\(scope): \(message)"
    }
}

/// Sink for structured log entries. Implementations fan out to the unified
/// logging system, an in-memory ring buffer, tests, etc. `Sendable` so it can
/// be injected into the `Sendable` ssh runners and `@MainActor` controllers
/// alike.
public protocol TunnelLogging: Sendable {
    func shouldLog(_ level: LogLevel) -> Bool
    func log(_ entry: LogEntry)
}

public extension TunnelLogging {
    func shouldLog(_ level: LogLevel) -> Bool {
        level != .off
    }

    /// Ergonomic entry point: builds the message lazily so `.debug` logs cost
    /// nothing when filtered out by the backing logger.
    func log(
        _ level: LogLevel,
        _ category: LogCategory,
        tunnel: String? = nil,
        _ message: @autoclosure () -> String
    ) {
        guard shouldLog(level) else { return }
        log(LogEntry(category: category, level: level, tunnel: tunnel, message: message()))
    }
}

/// Thread-safe mutable threshold used by settings-driven log filters. The gate
/// lets a running tunnel pick up changes from the settings view immediately.
public final class LogLevelGate: Sendable {
    private let storage: Mutex<LogLevel>

    public init(minimumLevel: LogLevel = .warning) {
        storage = Mutex(minimumLevel)
    }

    public var minimumLevel: LogLevel {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    public func allows(_ level: LogLevel) -> Bool {
        minimumLevel.allows(level)
    }
}

/// Filters a backing logger by a mutable minimum level.
public struct LevelFilteredTunnelLogger: TunnelLogging {
    private let base: any TunnelLogging
    private let gate: LogLevelGate

    public init(base: any TunnelLogging, gate: LogLevelGate) {
        self.base = base
        self.gate = gate
    }

    public func shouldLog(_ level: LogLevel) -> Bool {
        gate.allows(level) && base.shouldLog(level)
    }

    public func log(_ entry: LogEntry) {
        guard shouldLog(entry.level) else { return }
        base.log(entry)
    }
}

/// Production sink: forwards to `os.Logger`, one logger per category. Messages
/// are logged `.public` on purpose — this is a developer-facing debugging tool
/// and the payloads (host aliases, ports, control paths, ssh stderr) are not
/// secrets.
public struct OSLogTunnelLogger: TunnelLogging {
    private let subsystem: String

    public init(subsystem: String = tunnelLogSubsystem) {
        self.subsystem = subsystem
    }

    public func log(_ entry: LogEntry) {
        guard shouldLog(entry.level) else { return }
        let logger = Logger(subsystem: subsystem, category: entry.category.rawValue)
        let scope = entry.tunnel.map { "[\($0)] " } ?? ""
        let line = scope + entry.message
        logger.log(level: entry.level.osLogType, "\(line, privacy: .public)")
    }
}

/// In-memory ring buffer of the most recent entries, for in-app inspection and
/// "Copy Debug Log" export. Thread-safe via `Mutex`; `Sendable`.
public final class InMemoryLogRecorder: TunnelLogging, Sendable {
    private let capacity: Int
    private let storage = Mutex<[LogEntry]>([])

    public init(capacity: Int = 2_000) {
        self.capacity = max(1, capacity)
    }

    public func log(_ entry: LogEntry) {
        guard shouldLog(entry.level) else { return }
        storage.withLock { entries in
            entries.append(entry)
            if entries.count > capacity {
                entries.removeFirst(entries.count - capacity)
            }
        }
    }

    /// Snapshot of buffered entries, oldest first.
    public func entries() -> [LogEntry] {
        storage.withLock { $0 }
    }

    /// Multi-line rendering of the buffer, optionally filtered by minimum level
    /// and/or tunnel identity. Suitable for clipboard or file export.
    public func formatted(minimumLevel: LogLevel = .debug, tunnel: String? = nil) -> String {
        entries()
            .filter { $0.level >= minimumLevel }
            .filter { tunnel == nil || $0.tunnel == tunnel }
            .map { $0.formatted() }
            .joined(separator: "\n")
    }

    public func clear() {
        storage.withLock { $0.removeAll() }
    }
}

/// Fans a single entry out to several sinks (e.g. `os.Logger` + in-memory
/// recorder). Empty composite is a valid no-op sink.
public struct CompositeTunnelLogger: TunnelLogging {
    private let sinks: [any TunnelLogging]

    public init(_ sinks: [any TunnelLogging]) {
        self.sinks = sinks
    }

    public func shouldLog(_ level: LogLevel) -> Bool {
        sinks.contains { $0.shouldLog(level) }
    }

    public func log(_ entry: LogEntry) {
        for sink in sinks {
            if sink.shouldLog(entry.level) {
                sink.log(entry)
            }
        }
    }
}

/// Persists log entries to a rotating file on disk. Unlike the in-memory
/// recorder, this survives app relaunches — essential for diagnosing the
/// login-time / restart bugs where the interesting events happen *before* a
/// human can open the app. Thread-safe via `Mutex`; `Sendable`.
///
/// When the primary file grows past `maxBytes` it is renamed to `<name>.1`
/// (replacing any previous backup) and a fresh primary file is started, so the
/// on-disk footprint stays bounded at roughly `2 * maxBytes`.
public final class FileLogRecorder: TunnelLogging, Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let state = Mutex<FileHandle?>(nil)

    public init(fileURL: URL, maxBytes: Int = 1_048_576) throws {
        self.fileURL = fileURL
        self.maxBytes = max(1_024, maxBytes)

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        state.withLock { $0 = handle }
    }

    deinit {
        state.withLock { try? $0?.close() }
    }

    public func log(_ entry: LogEntry) {
        guard shouldLog(entry.level) else { return }
        guard let data = (entry.formatted() + "\n").data(using: .utf8) else { return }
        state.withLock { handle in
            guard let current = handle else { return }
            current.write(data)
            if (try? current.offset()).map({ $0 > UInt64(maxBytes) }) == true {
                handle = rotate(currentHandle: current)
            }
        }
    }

    /// Caller already holds the lock. Closes the current handle, rotates the
    /// file to `<name>.1`, and returns a fresh primary handle (or `nil` if it
    /// could not be reopened).
    private func rotate(currentHandle: FileHandle) -> FileHandle? {
        try? currentHandle.close()
        let backupURL = fileURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        return try? FileHandle(forWritingTo: fileURL)
    }
}


/// Process-wide default logger, used wherever explicit dependency injection is
/// awkward (e.g. the `@main` app, free functions). Tests and call sites that
/// need isolation can inject their own `TunnelLogging` instead.
///
/// The shared sink writes both to the unified logging system *and* to a shared
/// in-memory recorder (`TunnelLog.recorder`) so the app can offer an instant
/// "Copy Debug Log" without round-tripping through `OSLogStore`.
public enum TunnelLog {
    /// Process-wide threshold used by the shared production logger.
    public static let levelGate = LogLevelGate(minimumLevel: .warning)

    /// In-memory buffer backing the in-app log export.
    public static let recorder = InMemoryLogRecorder()

    /// Standard on-disk log location: `~/Library/Logs/SSHTunnel/tunnel.log`.
    /// This is the conventional place for user-visible app logs on macOS and is
    /// readable in Console.app under "Log Reports".
    public static let fileURL: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("SSHTunnel", isDirectory: true)
            .appendingPathComponent("tunnel.log")
    }()

    /// Best-effort persistent file sink. `nil` if the file could not be opened
    /// (e.g. sandbox denial) — logging then degrades to OSLog + in-memory only.
    public static let fileRecorder: FileLogRecorder? = try? FileLogRecorder(fileURL: fileURL)

    /// Default fan-out sink: unified logging + in-memory recorder + (if
    /// available) a rotating on-disk file that survives app relaunches.
    public static let shared: any TunnelLogging = LevelFilteredTunnelLogger(
        base: CompositeTunnelLogger(
            [OSLogTunnelLogger(), recorder] + (fileRecorder.map { [$0] } ?? [])
        ),
        gate: levelGate
    )
}

