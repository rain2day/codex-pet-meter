# Contributing

Thanks for helping improve Codex Pet Meter. The project is small, local-first,
and security-sensitive because it reads credentials that already exist on a
developer's Mac.

## Good First Contributions

- Improve install and uninstall reliability across macOS versions.
- Add clearer troubleshooting for missing Codex or Claude credentials.
- Improve the menu bar and overlay UI without adding setup friction.
- Add tests or static checks around installer behavior.
- Review the privacy and credential-handling documentation.

## Local Setup

Requirements:

- macOS 13 or newer
- Node.js 20 or newer
- Xcode Command Line Tools

```bash
git clone https://github.com/rain2day/codex-pet-meter.git
cd codex-pet-meter
npm run check
./setup.sh
```

## Pull Request Guidelines

- Keep changes focused and explain the user-facing reason.
- Do not add analytics, telemetry, remote logging, or a maintainer-operated
  backend without opening an issue first.
- Do not print access tokens, refresh tokens, account IDs, or raw credential
  payloads in logs.
- Update `README.md` or `docs/` when user-facing behavior changes.
- Run `npm run check` before opening a PR.

## Privacy-Sensitive Changes

Any change that touches these areas needs extra care:

- `~/.codex/auth.json`
- `~/.codex/.codex-global-state.json`
- `~/.claude/.credentials.json`
- macOS Keychain access through `/usr/bin/security`
- OpenAI or Anthropic usage and refresh endpoints
- local caches under `~/Library/Application Support/com.rainsday.codex-pet-meter`

Please describe the data flow in the PR and link to the relevant privacy doc
section.

## Maintainer Review

The maintainer prioritizes changes that make the app easier to install, safer to
inspect, and simpler to debug. Large rewrites are welcome only after an issue
has agreed on scope.
