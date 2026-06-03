import Foundation
import Darwin

struct PortConflict: Equatable, Sendable {
    let port: Int
    let pid: Int?
    let command: String?
    let commandArgs: [String]?
    let openFiles: [String]?

    init(
        port: Int,
        pid: Int? = nil,
        command: String? = nil,
        commandArgs: [String]? = nil,
        openFiles: [String]? = nil
    ) {
        self.port = port
        self.pid = pid
        self.command = command
        self.commandArgs = commandArgs
        self.openFiles = openFiles
    }

    var userMessage: String {
        let holder: String
        switch (pid, command) {
        case let (p?, c?): holder = "PID \(p) — \(c)"
        case let (p?, nil): holder = "PID \(p)"
        case let (nil, c?): holder = c
        case (nil, nil):   holder = "another process"
        }
        return """
        Local port \(port) is already bound by \(holder). \
        Free it (e.g. `kill \(pid.map(String.init) ?? "<pid>")`) and try again.
        """
    }
}

protocol PortAvailabilityChecking: Sendable {
    /// Returns every port among `ports` that is already bound on 127.0.0.1,
    /// sorted by port number. Empty if all listed ports are free.
    func conflicts(among ports: [Int]) async -> [PortConflict]
    /// Returns the lowest-numbered port that's already bound on 127.0.0.1, or
    /// nil if all listed ports are free.
    func firstConflict(among ports: [Int]) async -> PortConflict?
    /// Finds a free port on 127.0.0.1 within the given range.
    func findFreePort(in range: ClosedRange<Int>) async -> Int?
}

extension PortAvailabilityChecking {
    func firstConflict(among ports: [Int]) async -> PortConflict? {
        await conflicts(among: ports).min(by: { $0.port < $1.port })
    }
}

struct LocalPortAvailabilityChecker: PortAvailabilityChecking {
    func conflicts(among ports: [Int]) async -> [PortConflict] {
        // Probe ports in parallel — bindProbe is a syscall, identifyHolder
        // shells out. Sequential is wasteful for multi-LocalForward tunnels.
        let results: [PortConflict] = await withTaskGroup(
            of: PortConflict?.self
        ) { group in
            for port in ports {
                group.addTask {
                    let busy = await Task.detached(priority: .userInitiated) {
                        Self.bindProbe(port: port)
                    }.value
                    guard busy else { return nil }
                    let holder = await Self.identifyHolder(port: port)
                    return PortConflict(
                        port: port,
                        pid: holder.pid,
                        command: holder.command,
                        commandArgs: holder.args,
                        openFiles: holder.openFiles
                    )
                }
            }
            var out: [PortConflict] = []
            for await conflict in group {
                if let conflict { out.append(conflict) }
            }
            return out
        }
        return results.sorted { $0.port < $1.port }
    }

    func findFreePort(in range: ClosedRange<Int>) async -> Int? {
        // Probe a bounded number of *random* candidates rather than allocating
        // and shuffling the whole 1024–65535 range on every call. Random samples
        // also avoid predictable collisions if multiple apps use the same logic.
        // A free port is overwhelmingly likely within a few hundred attempts;
        // fall back to a full scan only if the range is nearly exhausted.
        let maxRandomAttempts = 256
        var tried = Set<Int>()
        for _ in 0..<maxRandomAttempts {
            let port = Int.random(in: range)
            guard tried.insert(port).inserted else { continue }
            if await isFree(port) { return port }
        }
        for port in range where !tried.contains(port) {
            if await isFree(port) { return port }
        }
        return nil
    }

    private func isFree(_ port: Int) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            !Self.bindProbe(port: port)
        }.value
    }

    /// POSIX bind probe on 127.0.0.1. Mirrors exactly what `ssh -L` will do:
    /// open a stream socket, bind to (127.0.0.1, port) without SO_REUSEADDR.
    /// If the bind returns EADDRINUSE, ssh will also fail; if it succeeds, the
    /// port is genuinely free at this instant. The socket is closed
    /// immediately so ssh can take the port over.
    private static func bindProbe(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return false } // bind ok → port free
        return errno == EADDRINUSE
    }

    /// Best-effort identification of the process holding `port`. We first use
    /// `lsof -F pc` for pid+command, then ask `ps` for argv and `lsof -p` for
    /// open file names. Either can silently degrade — callers always get a
    /// usable PortConflict.
    static func identifyHolder(port: Int) async -> (pid: Int?, command: String?, args: [String]?, openFiles: [String]?) {
        let lsof = await runCapturing(
            "/usr/sbin/lsof",
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-F", "pc"]
        )
        let (pid, command) = parseLsofOutput(lsof)
        guard let pid else { return (nil, command, nil, nil) }

        let ps = await runCapturing("/bin/ps", ["-o", "command=", "-p", String(pid)])
        let args = parsePsCommandLine(ps)
        let openFileOutput = await runCapturing("/usr/sbin/lsof", ["-nP", "-p", String(pid), "-F", "n"])
        let openFiles = parseOpenFileNames(openFileOutput)
        return (pid, command, args.isEmpty ? nil : args, openFiles.isEmpty ? nil : openFiles)
    }

    /// Parses `lsof -F pc` output. Each record starts with a `p<pid>` line and
    /// is followed by attribute lines (e.g. `c<command>`). We take the first
    /// pid/command pair we see.
    static func parseLsofOutput(_ output: String) -> (Int?, String?) {
        var pid: Int?
        var command: String?
        for line in output.split(separator: "\n") {
            guard let first = line.first else { continue }
            let value = String(line.dropFirst())
            switch first {
            case "p":
                if pid == nil { pid = Int(value) }
            case "c":
                if command == nil { command = value }
            default:
                break
            }
            if pid != nil, command != nil { break }
        }
        return (pid, command)
    }

    /// Splits `ps -o command=` output on whitespace. Sane control paths and
    /// host aliases don't contain spaces, so this is enough for ssh-argv match.
    static func parsePsCommandLine(_ output: String) -> [String] {
        output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
    }

    static func parseOpenFileNames(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            guard line.first == "n" else { return nil }
            return String(line.dropFirst())
        }
    }

    /// Runs `path` with `args`, captures stdout, gives up after 2 seconds.
    private static func runCapturing(_ path: String, _ args: [String]) async -> String {
        let result = await runProcess(
            executable: URL(fileURLWithPath: path),
            arguments: args,
            timeout: 2
        )
        return result.stdout
    }
}
