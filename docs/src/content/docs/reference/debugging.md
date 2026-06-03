---
title: Debugging & Logs
description: Where SSH Tunnel writes logs and how to stream them while reproducing an issue.
---

Connection issues are often timing-sensitive: login startup, network changes,
VPN readiness, or quick forwards added while a master is still connecting. SSH
Tunnel logs each connection step so failures can be reconstructed after the
fact.

Use **Copy Debug Log** from the menu bar to copy recent logs to the clipboard
and reveal the persistent log file in Finder.

## Log sinks

| Sink | Location | Survives relaunch? | Best for |
| --- | --- | --- | --- |
| Unified logging | Console.app or `log` CLI | Yes | Live filtering |
| Persistent file | `~/Library/Logs/SSHTunnel/tunnel.log` | Yes | Login and restart issues |
| In-memory buffer | **Copy Debug Log** | No | Quick bug reports |

All sinks use the subsystem `com.sshtunnel.app`, with categories such as
`lifecycle`, `ssh`, `master`, `forward`, `network`, `ports`, `reconnect`, and
`health`.

## Stream logs live

```bash
log stream --predicate 'subsystem == "com.sshtunnel.app"' --level debug
```

## Pull the last hour after the fact

```bash
log show --last 1h --predicate 'subsystem == "com.sshtunnel.app"' --info --debug
```

## Diagnostics

For configuration problems, use **Run Diagnostics** in Settings. It validates
required fields, runs `ssh -G`, lists SSH config forwards, checks ControlPath
safety, and verifies local port availability. See
[Settings](/ssh-tunnel/guides/settings/).

:::tip
Set **Log Level** to **Debug** before reproducing timing or reconnect problems
so the relevant steps are captured.
:::
