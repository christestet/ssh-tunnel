---
title: Updates
description: How SSH Tunnel notifies you about new releases and how updates are installed.
---

SSH Tunnel checks GitHub Releases for a newer version automatically — at most
once every 24 hours.

## Update notifications

When a newer release is available:

- An **Update available** banner appears at the top of the menu.
- A macOS notification is posted.

Both open the release page so you can download the new DMG and drag it to
Applications.

:::note[Manual updates only]
Because the app is **not notarized**, updates are installed manually — there is
no silent self-update. See [Install](/ssh-tunnel/getting-started/install/) for
the Gatekeeper steps when opening a downloaded DMG.
:::

## Manual checks and the toggle

Manual update checks and the automatic-check toggle live in the **About &
Updates** popover, opened from the info (ⓘ) button in the Settings sidebar
footer.

## How releases are versioned

Releases are managed by **Release Please** from Conventional Commit history:

- `fix:` bumps the patch version.
- `feat:` bumps the minor version.
- `BREAKING CHANGE:` or `!` bumps the major version.

The [Changelog](/ssh-tunnel/changelog/) is generated from that history.
