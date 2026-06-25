# Contributing to macDros

Welcome, and thanks for taking the time to look around. macDros is a small,
focused Mac client for mirroring and controlling Android devices, and we are
happy to take patches, bug reports, device-compatibility notes, and ideas from
anyone who finds the project useful. This document captures the conventions
that keep the codebase consistent.

## Quick start

1. Read [docs/BUILDING.md](docs/BUILDING.md) for the full toolchain setup.
2. Run `./scripts/bootstrap.sh` once to fetch vendored binaries and generate
   the Xcode project.
3. Open `DroidMirroring.xcodeproj`, pick the `macDros` scheme, and build.

## Repo layout

| Path           | What lives there                                              |
| -------------- | ------------------------------------------------------------- |
| `App/`         | SwiftUI macOS app target, windows, scenes, app-level glue     |
| `Helpers/`     | Helper tools (privileged helper, FileProvider bridge, etc.)   |
| `Extensions/`  | App extensions (FileProvider, Quick Look thumbnails)          |
| `Packages/`    | Swift packages — `ADBKit`, `MirrorKit`, `WirelessKit`, etc.   |
| `scripts/`     | Build, bootstrap, release, signing scripts                    |
| `docs/`        | Architecture notes, building, credits, roadmap                |

## Sending a pull request

1. Fork the repo and create a topic branch off `main`
   (`feat/<short-name>` or `fix/<short-name>`).
2. Make focused commits — one logical change per commit when possible.
3. Run package tests for anything you touched:
   ```
   cd Packages/<PackageName> && swift test
   ```
4. Build the app to make sure nothing broke at the Xcode layer:
   ```
   xcodebuild -scheme macDros -destination 'platform=macOS' build
   ```
5. Open a PR against `main`. Fill out the PR template, include before/after
   screenshots or a short screen recording for UI changes, and list the
   device(s) you verified on.
6. Be patient with review — this is a small project and reviewers may take a
   few days. We will give concrete, actionable feedback rather than rubber
   stamps.

## Coding conventions

- **Indent**: 2 spaces, no tabs.
- **Naming**: `camelCase` for variables and functions, `PascalCase` for
  types, `SCREAMING_SNAKE_CASE` only for shell environment variables.
- **Concurrency**: Swift 6 strict-concurrency mode. Mark actors, `Sendable`,
  and isolation boundaries explicitly — do not silence warnings with
  `@unchecked` unless there is a comment explaining why.
- **Comments**: explain *why*, not *what*. The code already says what it does.
- **No emojis in source files** (commit messages, docs, and the Contributor
  Covenant are fine).
- **Logs**: use the established prefixes — `[mirror]`, `[coordinator]`,
  `[adb]`, `[wireless]`, `[click]`. They make grepping bug reports much
  easier.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Please
include the device model, Android version, connection type, and the log
snippet captured with the command shown in the template. Bugs without logs
take much longer to diagnose.

## Suggesting features

Use the [feature request template](.github/ISSUE_TEMPLATE/feature_request.md).
Describe the problem first, then the proposed solution — it is much easier
to design well when we agree on what is broken.

## Areas where help is wanted

- A real Fusion mode (proper per-app windowing instead of the current single
  mirror surface).
- Image thumbnails in the file browser via the QuickLook extension.
- A Mac App Store-compatible USB transport layer (the current one relies on
  entitlements MAS does not allow).
- Testing on Pixel, Xiaomi, and MIUI-based devices — wireless pairing
  behaviour varies a lot across OEMs and we need more data points.

## License

By contributing you agree that your contribution will be released under the
[Apache License 2.0](LICENSE), the same license the project uses.
