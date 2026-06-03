---
title: Terminal Coexistence
description: How SSH Tunnel stays out of the way of your interactive Terminal SSH sessions.
---

SSH Tunnel and Terminal use **different control sockets by default**, so they do
not interfere with each other.

## Separate masters

The app's default **Control Path** is namespaced
(`~/.ssh/control-sshtunnelapp-%C`). Running `ssh my-proxy` in Terminal while the
app tunnel is up opens a separate connection — or multiplexes onto your own SSH
config master if you configured one. The app master stays separate. Starting the
app after a Terminal SSH session works the same way.

## Shared-socket protection

:::caution
If you deliberately point **Control Path** at the same file your SSH config
uses, the app **refuses to start** that tunnel with a clear error. It will not
run `ssh -O exit` against the shared socket, because that would terminate your
interactive session.
:::

## Migration of old defaults

Old installs that still used previous unsafe defaults —
`~/.ssh/control-%h` or `~/.ssh/control-sshtunnelapp-%h` — are migrated to the
hashed, namespaced default on first launch.

## Applying changed settings

If SSH settings change while a tunnel is running, **stop and start** the tunnel
so the active master connection is recreated with the new values.
