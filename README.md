# SSH Tunnel

<img src="assets/icon.png" alt="SSH Tunnel menu bar app" width="200"/>

A tiny native macOS menu bar app that opens and closes SSH tunnels without
keeping terminal windows around. It wraps the same `ssh -M` master-socket
mechanism you'd use from the shell, and adds a state machine with health
checks, automatic reconnects, and lifecycle management that prevents orphan
SSH processes.

## Features

- Manage multiple tunnels from the menu bar and Settings sidebar
- Add, delete, and reorder tunnels in Settings; the menu follows the same order
- One-click start / stop per tunnel from the menu bar with an **Active** toggle
- Per-tunnel **Start at Login** toggle; the macOS login item is enabled while
  at least one tunnel has Start at Login enabled
- Single-instance app launch: opening a second copy activates the existing app
  and exits the new process
- Status indicated by icon color
  - **Idle (disconnected)** → icon in default menu-bar tint
  - **connecting / reconnecting** → yellow
  - **connected** → green
  - **failed** → red
- Health check every 15 seconds (`ssh -O check`) **plus** a TCP probe on every
  forwarded port — catches "master is alive but the forward is dead"
- Auto-reconnect with exponential backoff (5s → max-backoff) when the master
  drops or fails to come up, unless the user stopped it manually; reconnecting
  tunnels show a live retry countdown in the menu row
- **"Check Now"** in the menu runs an immediate health check and always
  delivers a macOS notification with the result — OK with the list of
  reachable forwarded ports, or failure with the reason
- **Quick Forward**: add remote ports on the SSH host to be forwarded on the fly via the menu
  bar or settings. The app automatically assigns and manages free local ports
  on `127.0.0.1`, establishes the forward immediately on the active tunnel,
  removes cancelled forwards with `ssh -O cancel`, and reapplies saved quick
  forwards after reconnects or app restarts
- Reads `~/.ssh/config` via `ssh -G` so all `LocalForward` entries are picked
  up automatically; Settings lets you add service labels for those discovered
  ports without editing ssh_config
- Clickable localhost port pills in each tunnel row open
  `http://localhost:<port>` in the default browser when the tunnel is connected
- Settings autosave tunnel edits, Quick Forward edits, labels, timing values,
  and the global logging level
- Hardened SSH options out of the box: `ServerAliveInterval=15`,
  `ServerAliveCountMax=3`, `ConnectTimeout=10`, `ExitOnForwardFailure=yes`
- Master `ssh` process is owned by the app: a normal quit stops masters the
  app started, and a relaunch adopts a live master at the app's control path
  instead of leaving the menu out of sync
- Stale control socket on disk is cleaned up automatically before each start
- **Preflight port-conflict detection**: before each start, the app probes
  every SSH Config Forward and Quick Forward port locally. If something else is already listening on
  it (Qdrant on 6333, a forgotten Docker container, an orphan ssh from a
  previous run, …), the tunnel refuses to start with a clear message naming
  the holder's PID + command — instead of `ssh` returning a cryptic
  `bind: Address already in use`
- **Reconnect cap**: after 10 consecutive failed attempts the app stops
  retrying and surfaces the last error. Toggle the tunnel off and on to
  retry — useful so a chronic issue (port collision, auth failure) doesn't
  silently churn forever
- **Coexists safely with terminal `ssh <host>` usage**: the default control
  path is namespaced (`~/.ssh/control-sshtunnelapp-%C`) so the app's master
  cannot collide with a master your own ssh_config creates; if a path
  collision is detected the app refuses to start instead of killing your
  interactive session
- **Network resilience**: automatic reconnection on network changes
  (WiFi switch, VPN connect/disconnect) via `NWPathMonitor` and on
  system wake via `NSWorkspace.didWakeNotification` — no waiting for
  the next scheduled health check
- **Login race protection**: Start at Login waits for a satisfied network path,
  applies a short startup settle delay, and can optionally wait until a
  configured Startup Check host:port accepts TCP connections before starting the
  tunnel
- **Run Diagnostics** in Settings: checks required fields, `ssh -G`, SSH config
  forwards, ControlPath safety, and local port availability before
  you start a tunnel
- Login item integration via `SMAppService`
- **Keyboard Shortcuts** while the menu is open: `⌘,` for Settings, `⌘?` for
  Help, and `⌘Q` to quit
- No Dock icon (`LSUIElement = YES`)

## Requirements

- macOS 26.0 or newer (tested on macOS 26.5 / Tahoe)
- Xcode Command Line Tools (`xcode-select --install`)
- An SSH host alias defined in `~/.ssh/config` that the app can call

No full Xcode install is required — the app builds straight from the Swift
sources with `swiftc`.

## Configure your SSH host

The app reads everything it needs from `~/.ssh/config`. You can use any
number of `LocalForward` entries; the app discovers all of them via
`ssh -G <hostAlias>` and probes each one in its health checks.

```sshconfig
Host my-proxy
    HostName proxy.example.com
    User sshproxy
    IdentityFile ~/.ssh/id_ed25519
    ExitOnForwardFailure yes
    LocalForward 1443 internal-api.example.com:443
    LocalForward 8080 internal-db.example.com:5432
```

In **Settings...** from the menu bar app, add a tunnel and set the
**Host Alias** to `my-proxy`. The **Control Path** defaults to
`~/.ssh/control-sshtunnelapp-%C` — a namespaced location that also separates
same-host tunnels by user and port, and won't collide with whatever your own
`~/.ssh/config` uses for `ControlPath`.

The **SSH Config Forwards** section shows ports discovered from ssh_config.
Add optional service labels there so the menu shows names like `API 1443`
instead of only port numbers. To change the underlying forwards, edit
`~/.ssh/config` and hit **Refresh Forwards** in the settings pane.

Use **Quick Forwards** for temporary or app-managed forwards. Enter a remote
port and optional label; the app assigns a free local port, saves it, and
applies it immediately when the tunnel is connected.

## Using the menu

Each configured tunnel appears as a row with:

- a colored state dot and state label
- localhost port pills for SSH Config Forwards and saved Quick Forwards
- an **Active** switch to start or stop the tunnel
- a **Start at Login** switch for per-tunnel autostart
- an **Add Quick Forward** button for adding a remote port immediately
- a **Check Now** button for an explicit health check and notification

Port pills are clickable while connected and open `http://localhost:<port>` in
your default browser. Their context menu opens the tunnel in Settings; Quick
Forward pills can also be removed directly from the row.

The bottom action bar adds a new tunnel, copies the debug log, opens Settings,
opens Help, or quits the app. **Copy Debug Log** copies the in-memory log buffer
to the clipboard and reveals the persistent log file in Finder.

## Settings

Settings uses a sidebar/detail layout. The sidebar lets you add, delete, and
reorder tunnels. The detail pane is autosaved after edits and contains:

- **Logging / Log Level** — global minimum log level for unified logging, the
  persistent file log, and the in-memory debug-log export. The default is
  **Warnings**; switch to **Debug** before reproducing a subtle issue.
- **Tunnel Configuration** — name, Host Alias, control path, health-check
  interval, max reconnect backoff, and Start at Login settings.
- **Startup Check** — shown when Start at Login is enabled. If a host is set, the
  app waits until that TCP host:port is reachable before starting the tunnel.
- **SSH Config Forwards** — read from `ssh -G <alias>`. You can label these
  ports, but the actual forward definitions still live in `~/.ssh/config`.
- **Quick Forwards** — app-managed remote ports. Local ports are assigned
  automatically and saved once available.
- **Run Diagnostics** — validates required fields, SSH config resolution,
  discovered forwards, ControlPath collision safety, and local port
  availability.

### Coexistence with terminal `ssh <host>`

The app and your terminal use **different** control sockets by default, so:

- Running `ssh my-proxy` in Terminal while the app's tunnel is up opens a
  fresh second connection (or multiplexes onto your own ssh_config master if
  you have one). The app's master stays separate.
- Running `ssh my-proxy` first and then starting the app's tunnel works too —
  again, separate masters.

If you deliberately point the **Control Path** at the same file your
ssh_config uses, the app **refuses to start** that tunnel with a clear error.
It will not `-O exit` the existing socket; that would kill your interactive
terminal session.

Old installs that still had the previous unsafe defaults
(`~/.ssh/control-%h` or `~/.ssh/control-sshtunnelapp-%h`) are auto-migrated to
the hashed namespaced default on first launch.

If you change SSH settings while a tunnel is running, stop and start the
tunnel manually so the active master connection is recreated with the new
values.

## Build & run

```bash
make            # build the .app bundle into ./SSHTunnel.app
make run        # stop any running instance, build, then relaunch
make test       # run unit tests through the Makefile
make install    # copy to /Applications/SSHTunnel.app
make stop       # kill the running app
make clean      # remove .build/ and SSHTunnel.app
swift build     # SwiftPM build (debug)
swift test      # run unit tests
```

### Editors

VS Code works from the SwiftPM package directly. The workspace includes a
default `swift: Test` task, so **Terminal → Run Test Task** runs `swift test`.

Xcode does not need a checked-in `.xcodeproj`: open `Package.swift` directly.
Generated Xcode project/workspace files are intentionally ignored so the repo
keeps SwiftPM as the single source of truth.

`make install` puts the app in `/Applications`. After that you can launch it
from Spotlight, Launchpad, or set tunnels to start from the menu's or
Settings' **Start at Login** switch. In Settings, set the **Startup Check** host and port when startup must wait for
a VPN-only endpoint such as `vpn-gateway.internal:443`; leave the host empty
to use only the satisfied network-path gate and short settle delay. If the
Startup Check is not reachable yet, the app retries it periodically until
the tunnel can start.

## How the SSH calls map

The app shells out to `/usr/bin/ssh`. Each one-shot command has a built-in
timeout so a wedged ssh cannot freeze the UI.

| Action | Command |
|---|---|
| **Master** | `ssh -N -M -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ConnectTimeout=10 -S <controlPath> <hostAlias>` |
| **Resolve ports** | `ssh -G <hostAlias>` (parsed for `LocalForward` lines) |
| **Quick Forward** | `ssh -S <controlPath> -O forward -L <localPort>:localhost:<remotePort> <hostAlias>` |
| **Remove Quick Forward** | `ssh -S <controlPath> -O cancel -L <localPort>:localhost:<remotePort> <hostAlias>` |
| **Check** | `ssh -S <controlPath> -O check <hostAlias>` |
| **Stop** | `ssh -S <controlPath> -O exit <hostAlias>` |
| **Forward probe** | TCP `connect()` to `127.0.0.1:<port>` for each forwarded port |

The master runs as a regular child process (no `-f`), so the app process is
its parent. During a normal quit, the app sends `ssh -O exit` to stop masters
it owns and removes its control socket. On relaunch, if a live master still
exists at the app's control path, the app adopts it before showing the tunnel
as connected.

## How to debug and monitor a tunnel

Connection problems are usually timing-sensitive — they show up at login,
right after a network change, or while a Quick Forward is added mid-connect.
The app emits structured logs for every step of the connection lifecycle so
you can reconstruct exactly what happened, even after a restart.

### Quick start: copy the debug log

Open the menu bar and click **Copy Debug Log**. This puts the recent log on
your clipboard (paste it into a bug report) **and** reveals the persistent log
file in Finder.

### Where the logs live

| Sink | Location | Survives relaunch? | Best for |
|---|---|---|---|
| Unified logging | Console.app / `log` CLI | ✅ (system-managed) | live streaming, filtering by category |
| Persistent file | `~/Library/Logs/SSHTunnel/tunnel.log` (+ rotated `tunnel.log.1`) | ✅ | login / restart bugs, full history |
| In-memory buffer | **Copy Debug Log** menu action | ❌ (cleared on quit) | quick copy-paste of recent events |

All three sinks receive the same entries after the current **Log Level** filter
is applied. Everything is logged under the subsystem `com.sshtunnel.app`,
split into categories you can filter on:
`lifecycle`, `ssh`, `master`, `forward`, `network`, `ports`, `reconnect`,
`health`.

### Watch the tunnel live

Stream everything the app logs while you reproduce the problem:

```bash
log stream --predicate 'subsystem == "com.sshtunnel.app"' --level debug
```

Narrow it to a single area — for example only the raw `ssh` invocations, or
only the master lifecycle:

```bash
# every ssh command, its exit code and stderr
log stream --predicate 'subsystem == "com.sshtunnel.app" && category == "ssh"'

# control-master spawn / ready / adopt / exit
log stream --predicate 'subsystem == "com.sshtunnel.app" && category == "master"'
```

Pull the last hour out of the system log after the fact (great for the
"it failed at login this morning" case):

```bash
log show --last 1h --predicate 'subsystem == "com.sshtunnel.app"' --info --debug
```

### Reading the logs

- **State transitions** are logged for every tunnel, e.g.
  `state Connecting -> Connected`.
- Each connection attempt is tagged with a short **correlation id** like
  `(#a1b2c3d4)`. When the app is in a reconnect loop, filter on that id to
  follow one attempt end-to-end without interleaving from other attempts.
- **Silent decisions are logged too** — the cases that used to be invisible:
  ssh config not resolvable yet at login, a Quick Forward deferred because the
  tunnel isn't connected, a reconnect being scheduled with its backoff delay,
  and which tunnels network-recovery starts or defers.

### Timing analysis in Instruments

The connection path emits **os_signpost** intervals (subsystem
`com.sshtunnel.app`, category `connection`) around `startTunnel`,
`resolveOptions`, and `waitForMasterReady`. Record a trace with the
**os_signpost** instrument to see how long each step takes and how overlapping
work (e.g. Quick Forwards racing the master becoming ready) lines up on the
timeline.

### Run Diagnostics

For configuration problems rather than runtime races, use **Run Diagnostics**
in Settings. It validates required fields, runs `ssh -G`, lists SSH config
forwards, checks ControlPath safety, and verifies local port
availability. If the tunnel is already connected, the diagnostic treats ports
held by that tunnel's own SSH process as expected instead of reporting them as
conflicts.

## Custom icon

Drop a PNG into `assets/icon.png` and run `make`. The Makefile uses
`sips` and `iconutil` to generate:

- `MenuBarIcon.png` (18×18) and `MenuBarIcon@2x.png` (36×36) — menu bar
- `AppIcon.icns` — used in Login Items, System Settings, Finder Get Info

The menu-bar variant is template-rendered when the tunnel is disconnected
and color-tinted (green/yellow/red) for the other states.

## Project layout

```
.
├── Makefile
├── Package.swift                # SwiftPM build + test config
├── assets/icon.png              # source for the menu-bar / app icon
├── Resources/Info.plist         # LSUIElement, bundle id, icon ref
├── Sources/SSHTunnel/
│   └── SSHTunnelApp.swift       # @main, MenuBarExtra, Settings, Help window, app lifecycle
├── Sources/SSHTunnelKit/
│   ├── Logging/
│   │   ├── LogSettingsStore.swift # persisted global log threshold
│   │   └── TunnelLog.swift        # OSLog + in-memory + rotating file log sinks
│   ├── Model/
│   │   ├── Constants.swift
│   │   ├── TunnelSettings.swift   # persisted tunnel settings + validation
│   │   └── TunnelState.swift      # shared state labels and colors
│   ├── Services/
│   │   ├── ForwardHealthChecking.swift
│   │   ├── LoginItemManager.swift
│   │   ├── NetworkMonitor.swift
│   │   ├── NetworkReadinessChecking.swift
│   │   ├── PortAvailability.swift
│   │   ├── PortConflictResolver.swift
│   │   ├── ProcessRunner.swift
│   │   ├── SSHConfigInspector.swift
│   │   ├── SSHRunner.swift
│   │   ├── TunnelController.swift
│   │   ├── TunnelDiagnosticRunner.swift
│   │   ├── TunnelManager.swift
│   │   └── TunnelNotifier.swift
│   └── Views/
│       ├── AppVersionDisplay.swift
│       ├── HelpView.swift
│       ├── MenuBarView.swift
│       └── TunnelSettingsView.swift
└── Tests/SSHTunnelTests/
    └── unit tests for controllers, settings, diagnostics, logging, SSH parsing,
        network recovery, port conflicts, version metadata, and install/build helpers
```

## Notes

- The app launches `ssh` as a regular subprocess; it inherits your user
  environment including `SSH_AUTH_SOCK`. Keys with passphrases work as long
  as your `ssh-agent` has them loaded (e.g. via Keychain).
- `make install` ad-hoc signs the bundle (`codesign --sign -`). That is
  enough for local use — no Apple Developer ID required. Gatekeeper will
  let it run because it was built and signed on the same machine.
- Bundle identifier defaults to `de.connacher.SSHTunnel`. Change it in
  `Resources/Info.plist` if you intend to share the build.
