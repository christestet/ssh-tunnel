---
title: Configure SSH
description: Define a host with LocalForward entries in your SSH config and add it as a tunnel in SSH Tunnel.
---

SSH Tunnel reads tunnel definitions from `~/.ssh/config`. Use any number of
`LocalForward` entries; the app discovers them with `ssh -G <hostAlias>` and
probes each forwarded port during health checks.

## Define a host

```ssh-config
Host my-proxy
    HostName proxy.example.com
    User sshproxy
    IdentityFile ~/.ssh/id_ed25519
    ExitOnForwardFailure yes
    LocalForward 1443 internal-api.example.com:443
    LocalForward 8080 internal-db.example.com:5432
```

## Add the tunnel

1. Open **Settings…** (`⌘ + ,` while the menu is open).
2. Add a tunnel and set **Host Alias** to `my-proxy`.
3. Toggle **Active** in the menu bar to connect.

The default **Control Path** is `~/.ssh/control-sshtunnelapp-%C`, which keeps
app-managed masters separate from Terminal sessions and same-host tunnels. See
[Terminal Coexistence](/ssh-tunnel/guides/terminal-coexistence/) for why this
matters.

## Forwards and labels

The **SSH Config Forwards** section shows ports discovered from your SSH config.
Add optional service labels there so the menu can show names like `API 1443`
instead of bare port numbers.

To change the actual forwards, edit `~/.ssh/config` and choose **Refresh
Forwards** in Settings.

For temporary or app-managed forwards, use
[Quick Forwards](/ssh-tunnel/guides/quick-forwards/): enter a remote port and
optional label, and the app assigns a free local port, saves it, and applies it
immediately while the tunnel is connected.

## Hardened SSH defaults

The app starts masters with hardened options so dropped tunnels are detected
quickly:

- `ServerAliveInterval=15`
- `ServerAliveCountMax=3`
- `ConnectTimeout=10`
- `ExitOnForwardFailure=yes`

See the full [SSH Command Mapping](/ssh-tunnel/reference/ssh-command-mapping/)
for every command the app runs.
