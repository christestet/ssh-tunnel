---
title: SSH Command Mapping
description: Exactly which ssh commands SSH Tunnel runs for each action.
---

SSH Tunnel shells out to `/usr/bin/ssh`. One-shot commands use built-in
timeouts so a stuck SSH process cannot freeze the UI.

| Action | Command |
| --- | --- |
| Master | `ssh -N -M -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -S <controlPath> <hostAlias>` |
| Resolve ports | `ssh -G <hostAlias>` |
| Quick Forward | `ssh -S <controlPath> -O forward -L <localPort>:localhost:<remotePort> <hostAlias>` |
| Remove Quick Forward | `ssh -S <controlPath> -O cancel -L <localPort>:localhost:<remotePort> <hostAlias>` |
| Check | `ssh -S <controlPath> -O check <hostAlias>` |
| Stop | `ssh -S <controlPath> -O exit <hostAlias>` |
| Forward probe | TCP `connect()` to `127.0.0.1:<port>` for each forwarded port |

## Process lifecycle

The master runs as a regular child process, so the app process is its parent.

- During a **normal quit**, SSH Tunnel sends `ssh -O exit` to stop masters it
  owns and removes its control socket.
- On **relaunch**, if a live master still exists at the app control path, the
  app **adopts** it before showing the tunnel as connected.
- If no master is alive, **stale control sockets** are cleaned before a new
  master starts.
