# SSH Tunnel

[![Swift](https://img.shields.io/badge/Swift-6.3-orange.svg?logo=swift)](https://www.swift.org/)
[![macOS](https://img.shields.io/badge/macOS-26.0%2B-111111.svg?logo=apple)](https://developer.apple.com/macos/)
[![Swift](https://github.com/christestet/ssh-tunnel/actions/workflows/swift.yml/badge.svg)](https://github.com/christestet/ssh-tunnel/actions/workflows/swift.yml)
[![Release](https://github.com/christestet/ssh-tunnel/actions/workflows/release.yml/badge.svg)](https://github.com/christestet/ssh-tunnel/actions/workflows/release.yml)
[![Latest release](https://img.shields.io/github/v/release/christestet/ssh-tunnel?display_name=tag&sort=semver)](https://github.com/christestet/ssh-tunnel/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Docs](https://img.shields.io/badge/docs-GitHub%20Pages-2563eb.svg?logo=readthedocs&logoColor=white)](https://christestet.github.io/ssh-tunnel/)

<p align="center">
  <img src="assets/ssh-tunnel.png" alt="SSH Tunnel menu bar app icon" width="180">
</p>

**SSH Tunnel** is a native macOS menu bar app for opening, monitoring, and
closing SSH tunnels from the SSH config you already use. It wraps the same
`ssh -M` master-socket workflow you would run in Terminal, then adds health
checks, reconnects, quick forwards, diagnostics, and process lifecycle handling
so tunnels do not drift out of sync.

## Documentation

The full documentation is the **single source of truth** and lives at
**<https://christestet.github.io/ssh-tunnel/>**. This README is a short overview;
each topic below links to the page that covers it in depth.

| Topic | Page |
| --- | --- |
| Install & Gatekeeper override | [Install](https://christestet.github.io/ssh-tunnel/getting-started/install/) |
| Define hosts & forwards | [Configure SSH](https://christestet.github.io/ssh-tunnel/getting-started/configure-ssh/) |
| Full feature list | [Features](https://christestet.github.io/ssh-tunnel/features/) |
| Menu, port pills, action bar | [Using the App](https://christestet.github.io/ssh-tunnel/guides/using-the-app/) |
| Every Settings field | [Settings](https://christestet.github.io/ssh-tunnel/guides/settings/) |
| On-the-fly forwards | [Quick Forwards](https://christestet.github.io/ssh-tunnel/guides/quick-forwards/) |
| Health checks, reconnects, port conflicts | [Health Checks & Reconnects](https://christestet.github.io/ssh-tunnel/guides/health-checks/) |
| Staying out of Terminal's way | [Terminal Coexistence](https://christestet.github.io/ssh-tunnel/guides/terminal-coexistence/) |
| Update notifications | [Updates](https://christestet.github.io/ssh-tunnel/guides/updates/) |
| Exact `ssh` commands | [SSH Command Mapping](https://christestet.github.io/ssh-tunnel/reference/ssh-command-mapping/) |
| Logs & diagnostics | [Debugging & Logs](https://christestet.github.io/ssh-tunnel/reference/debugging/) |
| Build from source | [Build & Test](https://christestet.github.io/ssh-tunnel/reference/build-and-test/) |
| Versioning & releases | [Release Process](https://christestet.github.io/ssh-tunnel/reference/release-process/) |
| Troubleshooting | [FAQ & Troubleshooting](https://christestet.github.io/ssh-tunnel/faq/) |

The site is built from the `docs/` folder with
[Astro Starlight](https://starlight.astro.build/) and deployed to GitHub Pages on
every push to `main`. See [docs/README.md](docs/README.md) to run it locally.

## Highlights

- Native SwiftUI menu bar app with no Dock icon.
- Reads tunnel hosts and `LocalForward` entries from `~/.ssh/config` through
  `ssh -G`.
- Starts, stops, checks, and reconnects tunnels without keeping Terminal
  windows open.
- Supports multiple tunnels, per-tunnel Start at Login, quick forwards, labels,
  and clickable localhost port pills.
- Self-healing: scheduled health checks, TCP port probes, and automatic
  reconnects with exponential backoff.
- Detects local port conflicts before starting, reports the blocking process,
  and offers a session-only remap of a busy config `LocalForward` port onto a
  free local port.
- Uses a namespaced default control path, `~/.ssh/control-sshtunnelapp-%C`, to
  avoid colliding with interactive SSH sessions.
- Builds from SwiftPM or the included Makefile. No checked-in Xcode project is
  required.

See the full [Features](https://christestet.github.io/ssh-tunnel/features/) page
for the complete list.

## Requirements

| Requirement | Version |
| --- | --- |
| macOS | 26.0 or newer, tested on macOS 26.5 Tahoe |
| Swift tools | Swift 6.3 (only to build from source) |
| Build tools | Xcode Command Line Tools (only to build from source) |
| SSH | A working host alias in `~/.ssh/config` |

## Install

Download the latest DMG from
[GitHub Releases](https://github.com/christestet/ssh-tunnel/releases), mount it,
and drag `SSHTunnel.app` to Applications.

> Release DMGs are **ad-hoc signed, not notarized**, so macOS Gatekeeper
> quarantines the download. The
> [Install guide](https://christestet.github.io/ssh-tunnel/getting-started/install/)
> walks through the one-time **Open Anyway** override (and the `xattr` fallback)
> for opening the build on macOS 26 (Tahoe).

To build and install locally instead:

```bash
xcode-select --install   # once, if the command line tools are missing
make install             # build and copy SSHTunnel.app to /Applications
```

Locally built apps are not quarantined and open normally. For all build targets
see [Build & Test](https://christestet.github.io/ssh-tunnel/reference/build-and-test/).

## Quick start

1. Define a host with one or more `LocalForward` entries in `~/.ssh/config`:

   ```sshconfig
   Host my-proxy
       HostName proxy.example.com
       User sshproxy
       IdentityFile ~/.ssh/id_ed25519
       ExitOnForwardFailure yes
       LocalForward 1443 internal-api.example.com:443
       LocalForward 8080 internal-db.example.com:5432
   ```

2. Open **Settings…**, add a tunnel, and set **Host Alias** to `my-proxy`.
3. Toggle **Active** in the menu bar to connect. Forwarded ports appear as
   clickable localhost port pills.

The full walkthrough, including labels, quick forwards, and port-conflict
remapping, is in
[Configure SSH](https://christestet.github.io/ssh-tunnel/getting-started/configure-ssh/).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before
opening a pull request.

In short: use Conventional Commit style for PR titles and commits, add tests
before Swift implementation changes (TDD), run `swift test` or `make test`, and
do not bump versions manually unless the change is explicitly a release/version
maintenance change. Releases are handled automatically — see
[Release Process](https://christestet.github.io/ssh-tunnel/reference/release-process/).

## License

SSH Tunnel is released under the [MIT License](LICENSE).
