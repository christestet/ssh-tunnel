---
title: Using the App
description: Menu rows, clickable port pills, and the bottom action bar explained.
---

Each configured tunnel appears as a menu row with a state indicator, forwarded
port pills, an **Active** switch, a **Start at Login** switch, **Add Quick
Forward**, and **Check Now**. The row also surfaces the latest error when a
start, check, or reconnect fails.

## Menu bar icon state

The menu bar icon color reflects the combined tunnel state at a glance:

| Color | State |
| --- | --- |
| Gray | Idle / disconnected |
| Yellow | Connecting or reconnecting |
| Green | Connected |
| Red | Failed |

The image is template-rendered when disconnected and color-tinted for the
connecting, connected, and failed states.

## Port pills

SSH Config Forwards and Quick Forward ports appear as localhost port pills in
each tunnel row.

- While the tunnel is **connected**, click a pill to open
  `http://localhost:<port>` in your default browser.
- A pill's context menu jumps to that tunnel in Settings.
- Quick Forward pills also have a remove button.

## The action bar

The bottom action bar keeps two single-tap actions — **Add Tunnel** and
**Settings** — plus a **More (…)** menu containing:

- **Copy Debug Log** — copies the in-memory log buffer to the clipboard and
  reveals the persistent log file in Finder.
- **How to Use** — opens the in-app help.
- **Quit**.

## Keyboard shortcuts

While the menu is open:

| Shortcut | Action |
| --- | --- |
| `⌘ + ,` | Open Settings |
| `⌘ + ?` | Open Help |
| `⌘ + Q` | Quit |

## Single instance

SSH Tunnel runs as a single-instance app. Opening a second copy activates the
existing app and exits the new process.
