---
title: FAQ & Troubleshooting
description: Keyboard shortcuts and fixes for common SSH Tunnel connection issues.
---

## Troubleshooting checklist

- Verify the alias works in Terminal: `ssh <alias>`.
- Make sure your SSH key is loaded: `ssh-add -l`.
- Confirm the control path directory exists.
- Set **Log Level** to **Debug** before reproducing timing or reconnect
  problems.
- Use **Copy Debug Log** to copy recent entries and reveal the persistent log
  file.
- Use **Check Now** for an immediate notification with the current failure
  reason.
- If a forwarded port is unreachable, try `nc -vz 127.0.0.1 <port>`.
- If notifications are missing, allow alerts in **System Settings →
  Notifications → SSH Tunnel**.

## Common questions

### Why does macOS block the app on first launch?

Release builds are ad-hoc signed and not notarized, so Gatekeeper quarantines
them. Follow the one-time override in
[Install](/ssh-tunnel/getting-started/install/).

### Does the app interfere with my Terminal SSH sessions?

No. It uses a separate, namespaced control socket by default, and it refuses to
start if you point it at a socket your SSH config already uses. See
[Terminal Coexistence](/ssh-tunnel/guides/terminal-coexistence/).

### A tunnel is stuck as "failed" — how do I recover it?

After 10 consecutive failed reconnect attempts the app stops retrying. Toggle
the tunnel **Active** switch off and on to start fresh. See
[Health Checks & Reconnects](/ssh-tunnel/guides/health-checks/).

### How do I forward a port that isn't in my SSH config?

Use [Quick Forwards](/ssh-tunnel/guides/quick-forwards/). The app assigns a free
local port and reapplies the forward after reconnects and restarts.

### Where are the logs?

`~/Library/Logs/SSHTunnel/tunnel.log`, plus unified logging under the subsystem
`com.sshtunnel.app`. See [Debugging & Logs](/ssh-tunnel/reference/debugging/).

## Keyboard shortcuts

While the menu is open:

| Shortcut | Action |
| --- | --- |
| `⌘ + ,` | Open Settings |
| `⌘ + ?` | Open Help |
| `⌘ + Q` | Quit |
