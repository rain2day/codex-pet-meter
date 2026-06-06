# Codex Pet Meter

![Codex Pet Meter preview](assets/preview.png)

Codex Pet Meter is a small macOS menu bar app that places a live usage meter
around the Codex pet.

It shows Codex and Claude usage together, with separate session and weekly
indicators. The overlay follows the pet automatically from local Codex state and
does not modify `Codex.app`.

The project is intentionally local-first: it reads usage from the credentials
already stored by Codex and Claude Code on your Mac, stores only a small local
cache, and has no maintainer-operated server.

## Status

This is an early public open-source utility maintained by
[`rain2day`](https://github.com/rain2day). It is usable today, but the project is
still small: there are no public adoption claims, no package-manager
distribution yet, and the GitHub release process is still being hardened.

Good first contributions include install reliability, UI polish, provider
compatibility checks, privacy review, and release automation.

## Features

- Ring or pulse display modes
- Combined, Codex-only, or Claude-only usage
- Session and weekly percentages, with hover details
- 5-hour or 7-day reset indicator
- Custom colors for Codex, Claude, weekly, and reset lines
- Local-only usage reading; OpenUsage is not required
- No Accessibility permission and no calibration step

## Install

Requirements:

- macOS 13+
- Node.js 20+
- Xcode Command Line Tools
- Codex desktop app signed in
- Claude Code signed in, if you want Claude usage

```bash
git clone https://github.com/rain2day/codex-pet-meter.git
cd codex-pet-meter
./setup.sh
```

The app is installed to:

```text
~/Applications/Codex Pet Meter.app
```

`setup.sh` is re-runnable. It compiles the Swift app, signs it ad hoc, installs
it under `~/Applications`, and starts the app.

## Verify From Source

Run the same checks used by CI:

```bash
npm run check
```

The check script validates:

- `install.mjs` JavaScript syntax
- `setup.sh` shell syntax
- `app/CodexUsageHalo.swift` Swift typechecking against Cocoa

## Menu

Use the menu bar icon to change:

- Display Mode: `Pulse motion` or `Ring only`
- Data: `Combined`, `Codex`, `Claude`, used/left, and reset window
- Colors: provider session, weekly, and reset colors

Useful commands:

```bash
node install.mjs start
node install.mjs status
node install.mjs uninstall
```

## Data And Privacy

The app reads local Codex and Claude credentials already stored on your Mac,
then stores only a small local usage cache and your UI settings.

It does not patch Codex, install a background service, require OpenUsage, or send
usage data to a project-controlled backend.

It may call OpenAI and Anthropic usage endpoints using your existing local
tokens. See [docs/PRIVACY.md](docs/PRIVACY.md) for the full data flow.

## Project Layout

```text
app/CodexUsageHalo.swift      Swift menu bar app and overlay runtime
assets/                       Preview image and menu bar icon
install.mjs                   Build/install/start/status/uninstall helper
setup.sh                      One-shot installer
docs/ARCHITECTURE.md          Runtime and data-flow notes
docs/MAINTAINER_WORKFLOWS.md  Triage, release, and review workflows
docs/PRIVACY.md               Local data and network behavior
docs/ROADMAP.md               Near-term OSS roadmap
```

## Troubleshooting

If the meter does not appear, make sure the Codex pet is visible.

If usage is missing, sign in again to the relevant tool:

```bash
codex login
claude
```

Log:

```bash
tail -f /tmp/codex-usage-halo.log
```

If install fails, run:

```bash
npm run check
```

Then open an issue with your macOS version, Node version, the failing command,
and the relevant log excerpt.

## Contributing

Contributions are welcome. Please read
[CONTRIBUTING.md](CONTRIBUTING.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
and [docs/PRIVACY.md](docs/PRIVACY.md) before changing code that reads local
credentials or calls provider APIs.

Suggested GitHub topics for this repo:

```text
codex, macos, menu-bar, usage-meter, openai, claude, swift, appkit, local-first
```

## License

MIT. This project is not affiliated with OpenAI or Anthropic.
