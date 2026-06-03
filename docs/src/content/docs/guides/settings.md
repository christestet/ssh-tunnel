---
title: Settings
description: The sidebar/detail Settings layout and every field it exposes.
---

Settings uses a sidebar/detail layout. The sidebar lets you add, delete, and
reorder tunnels; the menu uses the same order. The detail pane is **autosaved**
after edits.

## Tunnel configuration

| Field | What it does |
| --- | --- |
| **Name** | Label shown in the menu and settings list. |
| **Host Alias** | The SSH config host entry to connect to. |
| **Control Path** | Socket path for the app's SSH master connection. |
| **Health Check** | Seconds between automatic connectivity checks. |
| **Max Backoff** | Maximum delay between reconnect attempts. |
| **Start at Login** | Connect this tunnel when the app launches. |

## Startup Check

An optional TCP host and port gate for **Start at Login**. The app retries until
a TCP connection to that host and port succeeds — useful for VPN-only
endpoints. See [Health Checks & Reconnects](/ssh-tunnel/guides/health-checks/).

## SSH Config Forwards

TCP ports derived from `ssh -G <alias>`. Add optional service labels here for
clearer localhost port pills (for example `API 1443`). To change the actual
forwards, edit `~/.ssh/config` and choose **Refresh Forwards**.

## Quick Forwards

App-managed remote ports with automatically assigned local ports. See the
dedicated [Quick Forwards](/ssh-tunnel/guides/quick-forwards/) guide.

## Logging

**Log Level** sets the global minimum level for unified logging, the persistent
file log, and the in-memory debug-log export. Use **Debug** before reproducing
subtle timing or reconnect issues. See
[Debugging & Logs](/ssh-tunnel/reference/debugging/).

## Run Diagnostics

Validates the saved or drafted tunnel configuration before you start it. It
checks:

- Required fields
- `ssh -G` resolution
- SSH config forwards
- Quick Forwards with assigned local ports
- ControlPath collision safety
- Local port availability

When the tunnel is already connected, ports held by that tunnel's own `ssh`
process are treated as expected rather than as conflicts.
