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

Full documentation lives at **<https://christestet.github.io/ssh-tunnel/>** —
install guide, SSH configuration, usage, health checks, command mapping,
debugging, and FAQ. The site is built from the `docs/` folder with
[Astro Starlight](https://starlight.astro.build/) and deployed to GitHub Pages
on every push to `main`. See [docs/README.md](docs/README.md) to run it locally.

## Highlights

- Native SwiftUI menu bar app with no Dock icon.
- Reads tunnel hosts and `LocalForward` entries from `~/.ssh/config` through
  `ssh -G`.
- Starts, stops, checks, and reconnects tunnels without keeping Terminal
  windows open.
- Supports multiple tunnels, per-tunnel Start at Login, quick forwards, labels,
  and clickable localhost port pills.
- Detects local port conflicts before starting and reports the blocking
  process.
- Uses a namespaced default control path,
  `~/.ssh/control-sshtunnelapp-%C`, to avoid colliding with interactive SSH
  sessions.
- Builds from SwiftPM or the included Makefile. No checked-in Xcode project is
  required.

## Requirements

| Requirement | Version |
| --- | --- |
| macOS | 26.0 or newer, tested on macOS 26.5 Tahoe |
| Swift tools | Swift 6.3 |
| Build tools | Xcode Command Line Tools |
| SSH | A working host alias in `~/.ssh/config` |

Install the command line tools if needed:

```bash
xcode-select --install
```

## Install

Download the latest DMG from
[GitHub Releases](https://github.com/christestet/ssh-tunnel/releases), mount it,
and drag `SSHTunnel.app` to Applications.

### Opening the GitHub DMG on macOS 26

Release DMGs are **ad-hoc signed, not notarized**. Notarization requires an
Apple Developer ID certificate and CI signing secrets that the project does not
yet have, so macOS Gatekeeper quarantines the downloaded app. On macOS 26
(Tahoe), the older right-click → **Open** workaround may no longer be enough for
apps downloaded from GitHub.

To open the release build:

1. Download the DMG from
   [GitHub Releases](https://github.com/christestet/ssh-tunnel/releases).
2. Mount the DMG and drag `SSHTunnel.app` to `/Applications`.
3. Try to open `/Applications/SSHTunnel.app` once. macOS will block it.
4. Open **System Settings → Privacy & Security**.
5. In the **Security** section, click **Open Anyway** for `SSHTunnel.app`.
6. Confirm the warning and enter your password if macOS asks for it.

Apple documents this manual override here:
[Open an app by overriding security settings](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).

If the **Open Anyway** button does not appear, remove the quarantine attribute
from Terminal after copying the app to `/Applications`:

  ```bash
  xattr -dr com.apple.quarantine /Applications/SSHTunnel.app
  open /Applications/SSHTunnel.app
  ```

Locally built apps (`make install`) are not quarantined and open normally.

### Staying up to date

The app checks GitHub Releases for a newer version automatically (at most once
per 24 hours). When a newer release exists, an **Update available** banner
appears in the menu and a notification is posted; both open the release page so
you can download the new DMG and drag it to Applications. Manual checks and the
automatic-check toggle live in the **About & Updates** popover in Settings (the
ⓘ button in the tunnel list footer). Because the app is un-notarized, updates
are always installed manually — there is no silent self-update.

You can also build and install locally:

```bash
make install
```

## Configure SSH

The app reads tunnel definitions from `~/.ssh/config`. Use any number of
`LocalForward` entries; SSH Tunnel discovers them with `ssh -G <hostAlias>` and
uses each forwarded port in health checks.

```sshconfig
Host my-proxy
    HostName proxy.example.com
    User sshproxy
    IdentityFile ~/.ssh/id_ed25519
    ExitOnForwardFailure yes
    LocalForward 1443 internal-api.example.com:443
    LocalForward 8080 internal-db.example.com:5432
```

Open **Settings...**, add a tunnel, and set **Host Alias** to `my-proxy`.
The default **Control Path** is `~/.ssh/control-sshtunnelapp-%C`, which keeps
app-managed masters separate from terminal sessions and same-host tunnels.

The **SSH Config Forwards** section shows ports discovered from SSH config. Add
optional service labels there so the menu can show names like `API 1443`
instead of only port numbers. To change the actual forwards, edit
`~/.ssh/config` and choose **Refresh Forwards** in Settings.

Use **Quick Forwards** for temporary or app-managed forwards. Enter a remote
port and optional label; the app assigns a free local port, saves it, and
applies it immediately when the tunnel is connected.

## Features

- Manage multiple tunnels from the menu bar and Settings sidebar.
- Add, delete, and reorder tunnels in Settings; the menu follows the same
  order.
- Start or stop each tunnel with an **Active** toggle.
- Enable **Start at Login** per tunnel. The macOS login item is enabled while
  at least one tunnel has Start at Login enabled.
- Launch as a single-instance app. Opening a second copy activates the existing
  app and exits the new process.
- Show tunnel state through menu bar icon color:
  - **Idle**: gray.
  - **Connecting / reconnecting**: yellow.
  - **Connected**: green.
  - **Failed**: red.
- Run scheduled health checks with `ssh -O check` plus TCP probes on every
  forwarded port.
- Reconnect automatically with exponential backoff when the master drops,
  unless the tunnel was stopped manually.
- Stop retrying after 10 consecutive failed attempts and surface the last
  error.
- Run **Check Now** for an immediate health check and macOS notification.
- Add remote ports through **Quick Forward** from the menu bar or Settings.
- Remove quick forwards with `ssh -O cancel` and reapply saved quick forwards
  after reconnects or app restarts.
- Open connected localhost ports from clickable port pills.
- Autosave tunnel edits, quick forward edits, labels, timing values, and global
  logging level.
- Use hardened SSH defaults: `ServerAliveInterval=15`,
  `ServerAliveCountMax=3`, `ConnectTimeout=10`, and
  `ExitOnForwardFailure=yes`.
- Own the master `ssh` process and stop app-started masters on normal quit.
- Adopt a live master at the app control path after relaunch.
- Clean stale control sockets before each start.
- Detect local port conflicts before starting and name the holder PID and
  command.
- Reconnect on network changes through `NWPathMonitor` and on system wake.
- Delay Start at Login until the network is ready, with an optional startup
  TCP check for VPN-only endpoints.
- Run diagnostics for required fields, `ssh -G`, SSH config forwards,
  ControlPath safety, and local port availability.
- Integrate with macOS login items through `SMAppService`.
- Support menu keyboard shortcuts: `⌘ + ,` for Settings, `⌘ + ?` for
  Help, and `⌘ + Q` to quit.

## Using The App

Each configured tunnel appears as a menu row with a state indicator, forwarded
port pills, an **Active** switch, a **Start at Login** switch, **Add Quick
Forward**, and **Check Now**.

Port pills are clickable while connected and open `http://localhost:<port>` in
the default browser. Their context menu opens the tunnel in Settings; quick
forward pills can also be removed directly from the row.

The bottom action bar adds a new tunnel, copies the debug log, opens Settings,
opens Help, or quits the app. **Copy Debug Log** copies the in-memory log buffer
to the clipboard and reveals the persistent log file in Finder.

## Settings

Settings uses a sidebar/detail layout. The sidebar lets you add, delete, and
reorder tunnels. The detail pane is autosaved after edits and includes:

- **Logging / Log Level**: global minimum log level for unified logging, the
  persistent file log, and the in-memory debug-log export.
- **Tunnel Configuration**: name, host alias, control path, health-check
  interval, max reconnect backoff, and Start at Login settings.
- **Startup Check**: optional TCP host and port gate for Start at Login.
- **SSH Config Forwards**: discovered from `ssh -G <alias>`, with optional
  labels.
- **Quick Forwards**: app-managed remote ports with automatically assigned
  local ports.
- **Run Diagnostics**: validates fields, SSH config resolution, discovered
  forwards, ControlPath collision safety, and local port availability.

## Coexistence With Terminal SSH

SSH Tunnel and Terminal use different control sockets by default.

Running `ssh my-proxy` in Terminal while the app tunnel is up opens a separate
connection, or multiplexes onto your own SSH config master if you configured
one. The app master stays separate. Starting the app after a terminal SSH
session works the same way.

If you deliberately point **Control Path** at the same file your SSH config
uses, the app refuses to start that tunnel with a clear error. It will not run
`ssh -O exit` against the shared socket because that would terminate the
interactive session.

Old installs that still used previous unsafe defaults,
`~/.ssh/control-%h` or `~/.ssh/control-sshtunnelapp-%h`, are migrated to the
hashed namespaced default on first launch.

If SSH settings change while a tunnel is running, stop and start the tunnel so
the active master connection is recreated with the new values.

## Build And Test

```bash
make            # build SSHTunnel.app
make run        # stop any running instance, build, then relaunch
make test       # run unit tests through the Makefile
make install    # copy SSHTunnel.app to /Applications
make stop       # stop the running app
make clean      # remove .build/ and SSHTunnel.app
swift build     # SwiftPM debug build
swift test      # SwiftPM tests
```

VS Code works from the SwiftPM package directly. The workspace includes a
default `swift: Test` task, so **Terminal -> Run Test Task** runs `swift test`.

Xcode does not need a checked-in `.xcodeproj`; open `Package.swift` directly.
Generated Xcode project and workspace files are intentionally ignored so
SwiftPM remains the source of truth.

## SSH Command Mapping

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

The master runs as a regular child process, so the app process is its parent.
During a normal quit, SSH Tunnel sends `ssh -O exit` to stop masters it owns and
removes its control socket. On relaunch, if a live master still exists at the
app control path, the app adopts it before showing the tunnel as connected.

## Debugging

Connection issues are often timing-sensitive: login startup, network changes,
VPN readiness, or quick forwards added while a master is still connecting. SSH
Tunnel logs each connection step so failures can be reconstructed after the
fact.

Use **Copy Debug Log** from the menu bar to copy recent logs to the clipboard
and reveal the persistent log file in Finder.

| Sink | Location | Survives relaunch? | Best for |
| --- | --- | --- | --- |
| Unified logging | Console.app or `log` CLI | Yes | Live filtering |
| Persistent file | `~/Library/Logs/SSHTunnel/tunnel.log` | Yes | Login and restart issues |
| In-memory buffer | **Copy Debug Log** | No | Quick bug reports |

All sinks use the subsystem `com.sshtunnel.app`, with categories such as
`lifecycle`, `ssh`, `master`, `forward`, `network`, `ports`, `reconnect`, and
`health`.

Stream logs while reproducing an issue:

```bash
log stream --predicate 'subsystem == "com.sshtunnel.app"' --level debug
```

Pull the last hour after the fact:

```bash
log show --last 1h --predicate 'subsystem == "com.sshtunnel.app"' --info --debug
```

For configuration problems, use **Run Diagnostics** in Settings. It validates
required fields, runs `ssh -G`, lists SSH config forwards, checks ControlPath
safety, and verifies local port availability.

## Project Layout

```text
.
|-- Makefile
|-- Package.swift
|-- assets/icon.png
|-- Resources/Info.plist
|-- Sources/SSHTunnel/
|   `-- SSHTunnelApp.swift
|-- Sources/SSHTunnelKit/
|   |-- Logging/
|   |-- Model/
|   |-- Services/
|   `-- Views/
`-- Tests/SSHTunnelTests/
```

## Icon

The app bundles checked-in icon assets from `assets/`: `AppIcon.icns`,
`MenuBarIcon.png`, and `MenuBarIcon@2x.png`. Keeping these generated assets in
the repository makes local and GitHub Actions release builds deterministic.

The menu bar image is template-rendered when disconnected and color-tinted for
connecting, connected, and failed states.

## Release Process

Releases are managed by Release Please and Conventional Commits.

- `fix:` bumps the patch version.
- `feat:` bumps the minor version.
- `BREAKING CHANGE:` or `!` bumps the major version.
- `Resources/Info.plist` stores the user-visible semantic version in
  `CFBundleShortVersionString`.
- `CFBundleVersion` stays numeric and monotonically incremented for distributed
  builds.
- The release workflow builds and uploads
  `SSHTunnel-v<version>-macos26-arm64.dmg`.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md)
before opening a pull request.

In short: use Conventional Commit style for PR titles and commits, add tests
before Swift implementation changes, run `swift test` or `make test`, and do
not bump versions manually unless the change is explicitly a release/version
maintenance change.

## License

SSH Tunnel is released under the [MIT License](LICENSE).
