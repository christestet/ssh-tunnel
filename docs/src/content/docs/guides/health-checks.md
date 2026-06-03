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

Before starting, the app checks whether every forwarded local port is free and
handles a busy port differently depending on what holds it:

- **Orphan app masters** — an obvious leftover `ssh` master from a previous run
  of this app (matched by host alias or control path) is cleaned up so the port
  can be reused. Unrelated processes are never touched.
- **Config `LocalForward` ports in use** — when a port declared by
  `LocalForward` in `~/.ssh/config` is held by a foreign process, the app shows
  the holder's **PID and command** and offers a free local port to use instead.
  Accept the suggestion (or type your own) to start the tunnel with that forward
  remapped, or cancel to leave the tunnel stopped.
- **Quick Forward ports** — a quick forward simply picks another free local port
  automatically, with no prompt.

### Session-only remap

A remap applies **only to the current session** — your `~/.ssh/config` is never
modified, and the original port is re-checked the next time you start the
tunnel. When any config forward is remapped, the master is started with
`ClearAllForwardings=yes` and **every** config forward is then applied
explicitly (`ssh -O forward`), so the remapped one lands on the new port while
the rest keep their configured ports. The chosen local port is shown in the
tunnel's port pills, so you always click through to the right
`http://localhost:<port>`.

## Start at Login readiness

When a tunnel has **Start at Login** enabled, the app waits until macOS reports
a satisfied network path, applies a short settle delay, and then connects. If a
**Startup Check** host is configured, the app retries until a TCP connection to
that host and port succeeds — handy for VPN-only endpoints.

The macOS login item (via `SMAppService`) is enabled while at least one tunnel
has Start at Login enabled.
