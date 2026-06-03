---
title: Features
description: Everything SSH Tunnel does, from multi-tunnel management to self-healing reconnects.
---

SSH Tunnel wraps the `ssh -M` master-socket workflow and layers management,
monitoring, and recovery on top. Each link below goes to the guide that covers
the feature in depth.

## Tunnel management

- Manage multiple tunnels from the menu bar and Settings sidebar.
- Add, delete, and reorder tunnels in Settings; the menu follows the same order.
- Start or stop each tunnel with an **Active** toggle.
- Autosave tunnel edits, quick forward edits, labels, timing values, and the
  global logging level.

See [Settings](/ssh-tunnel/guides/settings/) and
[Using the App](/ssh-tunnel/guides/using-the-app/).

## Status at a glance

- Show tunnel state through the menu bar icon color: **idle** (gray),
  **connecting / reconnecting** (yellow), **connected** (green), **failed**
  (red).
- Open connected localhost ports from clickable port pills.

See [Using the App](/ssh-tunnel/guides/using-the-app/).

## Self-healing connections

- Run scheduled health checks with `ssh -O check` plus TCP probes on every
  forwarded port.
- Run **Check Now** for an immediate health check and macOS notification.
- Reconnect automatically with exponential backoff when the master drops,
  unless the tunnel was stopped manually.
- Stop retrying after 10 consecutive failed attempts and surface the last error.
- Reconnect on network changes through `NWPathMonitor` and on system wake.
- Detect local port conflicts before starting and name the holder PID and
  command.

See [Health Checks & Reconnects](/ssh-tunnel/guides/health-checks/).

## Quick Forwards

- Add remote ports through **Quick Forward** from the menu bar or Settings.
- Remove quick forwards with `ssh -O cancel` and reapply saved quick forwards
  after reconnects or app restarts.

See [Quick Forwards](/ssh-tunnel/guides/quick-forwards/).

## Start at Login

- Enable **Start at Login** per tunnel; the macOS login item is enabled while at
  least one tunnel has it on (via `SMAppService`).
- Delay Start at Login until the network is ready, with an optional startup TCP
  check for VPN-only endpoints.

See [Health Checks & Reconnects](/ssh-tunnel/guides/health-checks/).

## Robust process lifecycle

- Launch as a single-instance app. Opening a second copy activates the existing
  app and exits the new process.
- Own the master `ssh` process and stop app-started masters on normal quit.
- Adopt a live master at the app control path after relaunch.
- Clean stale control sockets before each start.
- Use hardened SSH defaults: `ServerAliveInterval=15`, `ServerAliveCountMax=3`,
  `ConnectTimeout=10`, and `ExitOnForwardFailure=yes`.

See [SSH Command Mapping](/ssh-tunnel/reference/ssh-command-mapping/) and
[Terminal Coexistence](/ssh-tunnel/guides/terminal-coexistence/).

## Diagnostics & shortcuts

- Run diagnostics for required fields, `ssh -G`, SSH config forwards,
  ControlPath safety, and local port availability.
- Menu keyboard shortcuts: `⌘ + ,` for Settings, `⌘ + ?` for Help, and
  `⌘ + Q` to quit.

See [Settings](/ssh-tunnel/guides/settings/) and
[Debugging & Logs](/ssh-tunnel/reference/debugging/).
