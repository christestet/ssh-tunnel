---
title: Install
description: Download SSH Tunnel and open it on macOS 26 (Tahoe), including the one-time Gatekeeper override for un-notarized builds.
---

## Requirements

| Requirement | Version |
| --- | --- |
| macOS | 26.0 or newer, tested on macOS 26.5 Tahoe |
| SSH | A working host alias in `~/.ssh/config` |
| Build tools (only to build from source) | Xcode Command Line Tools, Swift 6.3 |

## Download

Download the latest DMG from
[GitHub Releases](https://github.com/christestet/ssh-tunnel/releases), mount it,
and drag `SSHTunnel.app` to **Applications**.

## Opening the GitHub DMG on macOS 26

:::caution[Un-notarized build]
Release DMGs are **ad-hoc signed, not notarized**. Notarization requires an
Apple Developer ID certificate and CI signing secrets the project does not have
yet, so macOS Gatekeeper quarantines the downloaded app. On macOS 26 (Tahoe)
the older right-click → **Open** workaround may no longer be enough for apps
downloaded from GitHub.
:::

To open the release build:

1. Download the DMG from
   [GitHub Releases](https://github.com/christestet/ssh-tunnel/releases).
2. Mount the DMG and drag `SSHTunnel.app` to `/Applications`.
3. Try to open `/Applications/SSHTunnel.app` once. macOS will block it.
4. Open **System Settings → Privacy & Security**.
5. In the **Security** section, click **Open Anyway** for `SSHTunnel.app`.
6. Confirm the warning and enter your password if macOS asks for it.

Apple documents this manual override in
[Open an app by overriding security settings](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).

If the **Open Anyway** button does not appear, remove the quarantine attribute
from Terminal after copying the app to `/Applications`:

```bash
xattr -dr com.apple.quarantine /Applications/SSHTunnel.app
open /Applications/SSHTunnel.app
```

Locally built apps (`make install`) are not quarantined and open normally.

## Build from source

Prefer building yourself? SSH Tunnel is a SwiftPM package with a Makefile:

```bash
git clone https://github.com/christestet/ssh-tunnel.git
cd ssh-tunnel
make install   # builds SSHTunnel.app and copies it to /Applications
```

Install the command line tools first if needed:

```bash
xcode-select --install
```

See [Build & Test](/ssh-tunnel/reference/build-and-test/) for all targets.

## Staying up to date

The app checks GitHub Releases for a newer version automatically, at most once
per 24 hours. When a newer release exists, an **Update available** banner
appears in the menu and a notification is posted; both open the release page so
you can download the new DMG and drag it to Applications. Because the app is
un-notarized, updates are always installed manually — there is no silent
self-update. See [Updates](/ssh-tunnel/guides/updates/) for details.
