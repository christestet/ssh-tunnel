---
title: Quick Forwards
description: Forward remote ports on the fly without editing your SSH config.
---

Quick Forwards let you forward a remote port on the SSH host without touching
`~/.ssh/config`. They are ideal for temporary or app-managed forwards.

## Add a Quick Forward

1. In a tunnel row, click **Add Quick Forward** (`+`) — also available in
   Settings.
2. Enter the **remote port** and an optional **service label**.
3. The app finds a free local port on `127.0.0.1` and establishes the forward
   on the active tunnel using `ssh -O forward`.

The forward is saved in Settings and shown as a clickable localhost port pill.

## Lifecycle

- **Saved**: Quick forwards persist in Settings.
- **Removed**: Use the remove button on the pill or in Settings; the app runs
  `ssh -O cancel` to tear down the forward.
- **Reapplied**: Saved quick forwards are reapplied automatically on reconnect
  or after an app restart, so you do not have to recreate them.

## Under the hood

| Action | Command |
| --- | --- |
| Add | `ssh -S <controlPath> -O forward -L <localPort>:localhost:<remotePort> <hostAlias>` |
| Remove | `ssh -S <controlPath> -O cancel -L <localPort>:localhost:<remotePort> <hostAlias>` |

See the full [SSH Command Mapping](/ssh-tunnel/reference/ssh-command-mapping/).
