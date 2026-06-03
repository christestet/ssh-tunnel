---
title: Release Process
description: How SSH Tunnel versions and ships releases with Release Please and Conventional Commits.
---

Releases are managed by [Release Please](https://github.com/googleapis/release-please)
driven by Conventional Commit history.

## Version bumps

| Commit type | Effect |
| --- | --- |
| `fix:` | bumps the **patch** version |
| `feat:` | bumps the **minor** version |
| `BREAKING CHANGE:` or `!` | bumps the **major** version |

## Versioning rules

- `Resources/Info.plist` stores the user-visible semantic version in
  `CFBundleShortVersionString` as `MAJOR.MINOR.PATCH` without a leading `v`.
  UI labels and Git tags may add the `v` prefix.
- `CFBundleVersion` stays numeric and monotonically incremented for distributed
  builds.
- Do not bump versions manually unless the change is explicitly a
  release/version maintenance change — Release Please derives the next version.

## Build & upload

Release Please opens a release PR; merging it creates a GitHub Release. The
release workflow (`.github/workflows/release.yml`) then builds and uploads the
unsigned/ad-hoc-signed DMG:

```
SSHTunnel-v<version>-macos26-arm64.dmg
```

The [Changelog](/ssh-tunnel/changelog/) is generated from the same commit
history. See [Updates](/ssh-tunnel/guides/updates/) for how users are notified
about new releases.

## Project layout

```text
.
├── Makefile
├── Package.swift
├── assets/ssh-tunnel.png
├── Resources/Info.plist
├── Sources/SSHTunnel/
│   └── SSHTunnelApp.swift
├── Sources/SSHTunnelKit/
│   ├── Logging/
│   ├── Model/
│   ├── Services/
│   └── Views/
├── Tests/SSHTunnelTests/
└── docs/                     # this documentation site
```

## App icon assets

The app bundles checked-in icon assets from `assets/`: `AppIcon.icns`,
`MenuBarIcon.png`, and `MenuBarIcon@2x.png`. Keeping these generated assets in
the repository makes local and GitHub Actions release builds deterministic. The
menu bar image is template-rendered when disconnected and color-tinted for the
connecting, connected, and failed states.
