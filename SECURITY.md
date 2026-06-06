# Security Policy

Codex Pet Meter is local-first, but it reads local authentication material from
developer tools. Please report security issues carefully.

## Supported Versions

The project currently supports the latest source on `main` and the latest
GitHub release once releases are published.

## Reporting A Vulnerability

Please do not open a public issue for vulnerabilities involving credentials,
token refresh, local cache contents, or provider API misuse.

Preferred reporting path:

1. Use GitHub private vulnerability reporting if it is available for this repo.
2. If private reporting is not available, contact the maintainer through the
   GitHub profile and include only a high-level summary until a private channel
   is established.

Please include:

- affected commit or release
- macOS version
- whether Codex, Claude, or combined mode is involved
- minimal reproduction steps
- what data may be exposed or modified

## Scope

Security-relevant areas include:

- reading `~/.codex/auth.json`
- refreshing OpenAI tokens and writing them back
- reading Claude credentials from file, environment, or Keychain
- writing Claude refreshed credentials back to file or Keychain
- local cache files and diagnostic logs
- provider usage API requests

## Non-Goals

This project is not intended to bypass provider limits, modify Codex or Claude
apps, or expose raw usage data to third-party services.
