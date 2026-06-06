# Architecture

Codex Pet Meter is a small macOS menu bar app built from one Swift source file
and a Node.js installer.

## Runtime Components

### Installer

`install.mjs` builds `app/CodexUsageHalo.swift` with `/usr/bin/swiftc`, creates a
minimal `.app` bundle under `~/Applications/Codex Pet Meter.app`, copies the
menu icon, ad-hoc signs the bundle when possible, and starts it with
`/usr/bin/open`.

`setup.sh` wraps the installer with prerequisite checks and user-facing setup
messages.

### Codex State Reader

`CodexStateReader` polls:

```text
~/.codex/.codex-global-state.json
```

It reads the Codex pet open state and sprite bounds so the halo can follow the
pet without Accessibility permissions or manual calibration.

### Usage Reader

`CodexUsageReader` fetches provider usage and emits normalized snapshots to the
overlay.

Codex flow:

1. Read `~/.codex/auth.json`.
2. Call the ChatGPT usage endpoint with the local access token.
3. Refresh the access token on `401` or `403`.
4. Write refreshed token data back to `~/.codex/auth.json`.
5. Cache normalized usage locally.

Claude flow:

1. Read credentials from `CLAUDE_CODE_OAUTH_TOKEN`, `~/.claude/.credentials.json`,
   or the Claude Code macOS Keychain item.
2. Call Anthropic's OAuth usage endpoint.
3. Respect provider throttling and backoff.
4. Refresh Claude credentials when possible and persist them back to their
   original source.
5. Cache normalized usage locally.

### Halo View

`HaloView` draws the overlay using AppKit and Core Graphics. It supports ring
and pulse modes, single-provider and combined views, session and weekly values,
reset indicators, and custom colors saved in `UserDefaults`.

### App Delegate

`AppDelegate` owns the borderless overlay panel, menu bar status item, provider
menu, display settings, color picker routing, and quit behavior.

## Local Storage

The app writes:

```text
~/Library/Application Support/com.rainsday.codex-pet-meter/usage-cache.json
/tmp/codex-usage-halo.log
UserDefaults for display settings and backoff state
```

It may also update provider-owned credential files or Keychain items when a
refresh succeeds. See [PRIVACY.md](PRIVACY.md).

## Design Constraints

- Do not modify `Codex.app`.
- Avoid Accessibility permissions unless a future feature clearly requires
  them.
- Do not add project-operated servers or remote telemetry.
- Keep the installer transparent and inspectable.
- Prefer small AppKit changes over framework migrations until the project has a
  broader contributor base.

## Known Technical Risks

- Provider usage endpoints are not stable public APIs and may change.
- Token refresh behavior must avoid corrupting provider credential files.
- Menu bar apps can behave differently across macOS versions and displays.
- The app currently has static checks but no automated UI test harness.
