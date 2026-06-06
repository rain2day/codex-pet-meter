# Roadmap

This roadmap keeps the project honest about what exists now and what needs work
before broader release.

## Now

- Swift menu bar app with overlay drawing.
- Codex pet tracking from local Codex state.
- Codex and Claude usage display.
- Local cache fallback.
- One-shot installer.
- MIT license.

## Next

- Publish a signed GitHub release with a zip artifact.
- Add install verification for fresh macOS machines.
- Add screenshots or a short demo video for the README.
- Add issue triage labels and a release checklist.
- Improve errors when provider credentials are missing or expired.

## Later

- Add optional launch-at-login support.
- Add settings export/import for colors and display mode.
- Add provider compatibility tests around fixture JSON.
- Explore a Homebrew cask only after releases are stable.
- Add a lightweight UI test strategy for menu state and overlay rendering.

## Non-Goals

- Bypassing provider usage limits.
- Modifying Codex or Claude applications.
- Sending usage data to a project backend.
- Adding analytics or tracking without explicit user opt-in and a public design
  review.
