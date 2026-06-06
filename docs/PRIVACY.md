# Privacy

Codex Pet Meter is designed as a local-first utility. It does not run a backend
service controlled by the maintainer and does not send usage data to this
project.

## Data Read Locally

The app may read:

```text
~/.codex/.codex-global-state.json
~/.codex/auth.json
~/.claude/.credentials.json
CLAUDE_CODE_OAUTH_TOKEN
macOS Keychain item: Claude Code-credentials
```

The Codex state file is used only to place the overlay around the pet.

The credential files and Keychain item are used to ask OpenAI and Anthropic for
usage information that those tools already expose to the signed-in user.

## Network Requests

The app may call:

- OpenAI or ChatGPT usage and OAuth refresh endpoints for Codex usage.
- Anthropic OAuth usage and refresh endpoints for Claude usage.
- Anthropic promo clock status endpoint for peak/off-peak display.

The project does not proxy those requests through a maintainer server.

## Data Written Locally

The app writes:

```text
~/Library/Application Support/com.rainsday.codex-pet-meter/usage-cache.json
/tmp/codex-usage-halo.log
UserDefaults for display settings, selected provider, colors, and backoff state
```

The usage cache stores normalized usage percentages, reset dates, provider
labels, plan text when available, and cache timestamps. It should not store raw
access tokens.

When provider token refresh succeeds, the app may write refreshed credentials
back to the same local source used by the provider tool:

- `~/.codex/auth.json` for Codex
- `~/.claude/.credentials.json` for Claude file credentials
- the Claude Code Keychain item for Claude Keychain credentials

## Data Not Collected By This Project

The project does not collect:

- personal identity
- prompts or code
- source files
- full account records
- raw token logs
- analytics events
- crash reports

## Contributor Rules

Changes that touch credential handling must:

- avoid logging raw tokens or full credential payloads
- keep local cache contents minimal
- document any new file, Keychain, environment, or network access
- avoid adding telemetry without a public design issue and maintainer approval

## Uninstall

Run:

```bash
node install.mjs uninstall
```

This removes the installed app bundle. It does not delete provider credentials.
You can remove the app cache manually if desired:

```bash
rm -rf "$HOME/Library/Application Support/com.rainsday.codex-pet-meter"
rm -f /tmp/codex-usage-halo.log
```
