---
title: Health Checks & Reconnects
description: How SSH Tunnel verifies connectivity, recovers from drops, and detects port conflicts.
---

## Health checks

**Check Now** runs `ssh -O check` and probes each forwarded TCP port on
`127.0.0.1`. Automatic health checks do the same on the configured interval, and
network or wake events trigger recovery work immediately instead of waiting for
the timer.

If a live master has a dead forward, the app tries to re-establish that forward
before reconnecting the whole tunnel.

## Reconnects

Reconnect backoff starts at **5 seconds** and doubles up to your configured
**Max Backoff**. While waiting, the menu row shows the retry countdown.

- A previously connected tunnel posts an interruption notification before
  reconnecting.
- After **10 consecutive failed** reconnect attempts, the app stops and leaves
  the tunnel **failed** until you toggle it off and on.
- Reconnects do not happen for tunnels that were stopped manually.

The app reconnects on network changes through `NWPathMonitor` and on system
wake.

## Port conflicts

Before starting, the app checks whether any forwarded port is already bound. For
foreign processes it reports the holder's **PID and command**. It may clean up
an obvious orphan SSH process only when its arguments match this tunnel's host
alias or control path — never an unrelated process.

## Start at Login readiness

When a tunnel has **Start at Login** enabled, the app waits until macOS reports
a satisfied network path, applies a short settle delay, and then connects. If a
**Startup Check** host is configured, the app retries until a TCP connection to
that host and port succeeds — handy for VPN-only endpoints.

The macOS login item (via `SMAppService`) is enabled while at least one tunnel
has Start at Login enabled.
