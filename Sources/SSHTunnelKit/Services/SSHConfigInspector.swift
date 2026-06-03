import CryptoKit
import Foundation

/// Effective options for a host alias, as resolved by `ssh -G`.
/// Used both to discover `LocalForward` ports and to expand `%`-tokens in the
/// control path (so our `FileManager` operations look at the same file `ssh`
/// itself uses).
struct SSHHostOptions: Equatable {
    var hostname: String      // %h — resolved remote hostname
    var user: String          // %r — remote user
    var port: String          // %p — remote port (string to keep the original token form)
    var forwardInfos: [ForwardInfo]
    /// Whatever `ControlPath` the user has set in ~/.ssh/config for this host.
    /// Empty if they haven't set one. Important for collision detection — if
    /// it points at the same file we're about to use, we must NOT touch the
    /// existing socket because it belongs to an interactive ssh session.
    var userControlPath: String

    init(
        hostname: String,
        user: String,
        port: String,
        forwardInfos: [ForwardInfo],
        userControlPath: String
    ) {
        self.hostname = hostname
        self.user = user
        self.port = port
        self.forwardInfos = forwardInfos
        self.userControlPath = userControlPath
    }

    // Compatibility for old code
    var forwardedPorts: [Int] {
        forwardInfos.map { $0.localPort }
    }
}

struct SSHConfigInspector {
    let runner: SSHRunning

    init(runner: SSHRunning = ProcessSSHRunner()) {
        self.runner = runner
    }

    func resolveOptions(forHost host: String) async -> SSHHostOptions? {
        let result = await runner.run(arguments: ["-G", host], timeout: 5)
        guard result.exitCode == 0 else { return nil }
        return Self.parseOptions(from: result.stdout)
    }

    static func parseLocalForwardPorts(from output: String) -> [ForwardInfo] {
        var infos: [ForwardInfo] = []
        var seenPorts = Set<Int>()
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  parts[0].lowercased() == "localforward" else { continue }
            
            let localBindSpec = String(parts[1])
            let remoteSpec = String(parts[2])
            
            guard let localPort = parseTCPPort(localBindSpec) else { continue }
            let remotePort = parseTCPPort(remoteSpec)
            let remoteHost = parseRemoteHost(remoteSpec)

            if seenPorts.insert(localPort).inserted {
                infos.append(ForwardInfo(localPort: localPort, remotePort: remotePort, remoteHost: remoteHost))
            }
        }
        return infos
    }

    static func parseOptions(from output: String) -> SSHHostOptions {
        var hostname = ""
        var user = ""
        var port = "22"
        var userControlPath = ""
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = String(parts[1])
            switch key {
            case "hostname": hostname = value
            case "user": user = value
            case "port": port = value
            case "controlpath":
                // OpenSSH emits `none` when no ControlPath is set.
                if value.lowercased() != "none" {
                    userControlPath = value
                }
            default: break
            }
        }
        return SSHHostOptions(
            hostname: hostname,
            user: user,
            port: port,
            forwardInfos: parseLocalForwardPorts(from: output),
            userControlPath: userControlPath
        )
    }

    /// Extracts the remote host from a `LocalForward` remote spec
    /// (`host:hostport`). Handles bracketed IPv6 (`[::1]:80` → `::1`) and bare
    /// `host:port` (everything before the last colon). Falls back to
    /// `localhost` when no host part is present.
    private static func parseRemoteHost(_ rawSpec: String) -> String {
        // `maxSplits` parsing can leave leading whitespace on the remote spec.
        let remoteSpec = rawSpec.trimmingCharacters(in: .whitespaces)
        if remoteSpec.hasPrefix("["),
           let close = remoteSpec.firstIndex(of: "]") {
            let host = remoteSpec[remoteSpec.index(after: remoteSpec.startIndex)..<close]
            return host.isEmpty ? "localhost" : String(host)
        }
        if let lastColon = remoteSpec.lastIndex(of: ":") {
            let host = remoteSpec[remoteSpec.startIndex..<lastColon]
            return host.isEmpty ? "localhost" : String(host)
        }
        return "localhost"
    }

    private static func parseTCPPort(_ bindSpec: String) -> Int? {
        if bindSpec.hasPrefix("/") {
            return nil
        }

        if bindSpec.hasPrefix("["),
           let close = bindSpec.firstIndex(of: "]") {
            let afterClose = bindSpec.index(after: close)
            guard afterClose < bindSpec.endIndex, bindSpec[afterClose] == ":" else { return nil }
            let portStart = bindSpec.index(after: afterClose)
            return Int(bindSpec[portStart...])
        }

        if let lastColon = bindSpec.lastIndex(of: ":") {
            let portPart = bindSpec[bindSpec.index(after: lastColon)...]
            return Int(portPart)
        }

        return Int(bindSpec)
    }
}

/// Expands the `%`-tokens that OpenSSH supports inside a `ControlPath` template
/// (see `ssh_config(5)`, "TOKENS"). Only the tokens that actually depend on
/// host-specific resolution (%h, %r, %p, %C) need values from `ssh -G`; the
/// local ones (%L, %l, %u, %d) come from the process environment.
///
/// We pass the *unexpanded* template to ssh itself (-S), so ssh's own logic
/// places the socket file. This helper exists only so our `FileManager`
/// operations agree on the path with ssh.
enum ControlPathExpander {
    static func expand(template: String, options: SSHHostOptions) -> String {
        var result = ""
        result.reserveCapacity(template.count)

        var iterator = template.makeIterator()
        while let ch = iterator.next() {
            guard ch == "%" else {
                result.append(ch)
                continue
            }
            guard let next = iterator.next() else {
                result.append("%") // trailing lone %, keep literal
                break
            }
            switch next {
            case "%":
                result.append("%")
            case "h":
                result.append(options.hostname)
            case "r":
                result.append(options.user)
            case "p":
                result.append(options.port)
            case "C":
                result.append(hashedConnectionToken(options: options))
            case "L":
                result.append(localHostShort())
            case "l":
                result.append(localHostFQDN())
            case "u":
                result.append(localUser())
            case "d":
                result.append(localHome())
            default:
                // Unknown token — leave it as-is so the path stays diagnosable
                result.append("%")
                result.append(next)
            }
        }

        return NSString(string: result).expandingTildeInPath
    }

    private static func localHostShort() -> String {
        let full = localHostFQDN()
        return full.split(separator: ".").first.map(String.init) ?? full
    }

    private static func localHostFQDN() -> String {
        ProcessInfo.processInfo.hostName
    }

    private static func localUser() -> String {
        NSUserName()
    }

    private static func localHome() -> String {
        NSHomeDirectory()
    }

    private static func hashedConnectionToken(options: SSHHostOptions) -> String {
        let input = localHostFQDN() + options.hostname + options.port + options.user
        return Insecure.SHA1
            .hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
