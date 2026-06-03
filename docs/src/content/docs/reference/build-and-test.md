---
title: Build & Test
description: Build SSH Tunnel from source with the Makefile or SwiftPM.
---

SSH Tunnel is a SwiftPM package — there is no checked-in Xcode project. Open
`Package.swift` directly in Xcode, or use the Makefile.

## Makefile targets

```bash
make            # build SSHTunnel.app
make run        # stop any running instance, build, then relaunch
make test       # run unit tests through the Makefile
make install    # copy SSHTunnel.app to /Applications
make stop       # stop the running app
make clean      # remove .build/ and SSHTunnel.app
```

## SwiftPM

```bash
swift build     # debug build
swift test      # run tests
```

## Editors

- **VS Code** works from the SwiftPM package directly. The workspace includes a
  default `swift: Test` task, so **Terminal → Run Test Task** runs `swift test`.
- **Xcode** does not need a checked-in `.xcodeproj`; open `Package.swift`
  directly. Generated Xcode project and workspace files are intentionally
  ignored so SwiftPM remains the source of truth.

## Contributing

Contributions are welcome. Use Conventional Commit style for PR titles and
commits, add tests before Swift implementation changes (TDD), run `swift test`
or `make test`, and do not bump versions manually unless the change is
explicitly a release/version maintenance change. See
[CONTRIBUTING.md](https://github.com/christestet/ssh-tunnel/blob/main/CONTRIBUTING.md).
