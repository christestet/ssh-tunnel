# ths is a mac os 26 tahoe menu bar app for connecting to remote servres via ssh, using ssh config.

- Also use your context7 mcp server with the swiftui docs if needded
- Always develop new features using test driven development (TDD) and write tests before writing the implementation code, when touching swift code.
- Please use latest swift 6 apis not deprecated ones - refer to the docs for mac os 26 tahoe: https://developer.apple.com/documentation/swiftui
- Version releases follow Conventional Commits and semantic-release semantics: `fix` bumps patch, `feat` bumps minor, and `BREAKING CHANGE` / `!` bumps major.
- Keep `CFBundleShortVersionString` in Resources/Info.plist as the user-visible semantic version in `MAJOR.MINOR.PATCH` format without a leading `v`; UI labels and Git tags may add the `v` prefix.
- Keep `CFBundleVersion` as the macOS build version: numeric, machine-readable, and monotonically incremented for distributed builds.
- Any release/version bump must update Info.plist, version-related tests/docs, and use Conventional Commit messages so semantic-release can derive the correct next version.
- Releases are coordinated by Release Please using `release-please-config.json` and `.release-please-manifest.json`; GitHub Actions builds and uploads the unsigned/ad-hoc-signed DMG from `.github/workflows/release.yml` after a release is created.
