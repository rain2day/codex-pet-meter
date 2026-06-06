# Maintainer Workflows

This document describes how the maintainer should run the project day to day.

## Triage

Classify new issues as:

- `install`: setup, signing, Node, Swift, or macOS version issues
- `provider-codex`: Codex state, auth, usage, or refresh behavior
- `provider-claude`: Claude credentials, rate limits, or peak/off-peak behavior
- `ui`: menu bar, overlay drawing, colors, layout, or display modes
- `privacy`: credential access, cache contents, logging, or network behavior
- `docs`: README, troubleshooting, roadmap, or release notes

Ask for:

- macOS version
- Node version
- Xcode Command Line Tools status
- `npm run check` output
- whether Codex, Claude, or combined mode is selected
- sanitized log excerpt from `/tmp/codex-usage-halo.log`

Never ask users to paste raw token files.

## Pull Request Review

For each PR:

1. Confirm the change is scoped.
2. Check whether the privacy model changes.
3. Run `npm run check`.
4. Read any installer or credential-handling changes carefully.
5. Update docs and changelog when behavior changes.

## Release Checklist

1. Confirm `npm run check` passes on a clean checkout.
2. Run `./setup.sh` on a local Mac.
3. Confirm `node install.mjs status` finds the app.
4. Confirm Codex-only mode still works.
5. Confirm Claude-only mode still handles missing credentials gracefully.
6. Update `CHANGELOG.md`.
7. Tag the release.
8. Upload a signed or clearly documented release artifact.
9. Open a follow-up issue for anything deferred.

## Suggested GitHub Labels

- `bug`
- `documentation`
- `good first issue`
- `help wanted`
- `install`
- `privacy`
- `provider-codex`
- `provider-claude`
- `release`
- `ui`

## OpenAI Codex Usage

If the project receives API credits, use them only for core open-source work:

- PR review and patch risk summaries
- fixture-based parser and credential-flow tests
- documentation consistency checks
- release checklist automation
- security review of local token handling

Do not use credits to generate fake engagement, synthetic stars, or misleading
adoption claims.
