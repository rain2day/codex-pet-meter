# Codex Pet Meter

A floating halo overlay that wraps the OpenAI **Codex** desktop app's pet mascot with two animated rings showing your **5-hour session** and **weekly** usage as a live ECG-style heartbeat pulse.

- **Cyan ring** — current 5-hour session usage
- **Yellow ring** — weekly usage
- **Hover** the rings to see exact percentages and time-until-reset
- **Customizable colors** for each ring
- **Two layouts**: stacked (concentric) or split (left/right semicircles)
- **Pulse motion** scrolls a PQRST waveform along each filled arc, or switch to plain rings

> Status: works on macOS 13+. **Source install only — no prebuilt release yet.**
> Requires the OpenAI Codex desktop app, Node.js (for the build script), and Xcode Command Line Tools.

## How it works

A single Swift app reads two files Codex itself maintains:

1. **`~/.codex/.codex-global-state.json`** — Codex publishes the pet sprite's exact screen rect here (`electron-avatar-overlay-bounds.mascot`), updated whenever the pet moves or hides. The app polls this every 100 ms and centers the halo on whatever rect Codex reports. No Accessibility permission needed, no calibration, no edge-case workarounds.
2. **`~/.codex/auth.json`** — Codex stores its OAuth tokens here. The app reads the access token, fetches usage from `https://chatgpt.com/backend-api/wham/usage` once a minute, and refreshes the token via `https://auth.openai.com/oauth/token` when it expires.

No Codex.app modification, no helper server, no LaunchAgent, no asar patching. Just one app bundle in `~/Applications`.

## Install

### Prerequisites

- macOS 13+
- [OpenAI Codex desktop app](https://openai.com/) installed and signed in (`codex login`)
- Node.js 20+ (build script runs on Node)
- Xcode Command Line Tools (`xcode-select --install`)

### Setup

```bash
git clone https://github.com/rain2day/codex-pet-meter.git
cd codex-pet-meter
./setup.sh
```

The script builds and installs `~/Applications/Codex Pet Meter.app` and launches it. The halo immediately snaps to your Codex pet — no first-run dance, no permission prompts.

If the pet is hidden, the halo hides too. Show the pet again and the halo comes back.

## Usage

```bash
node install.mjs start              # restart the app
node install.mjs status             # is the app process running?
node install.mjs uninstall          # stop and remove
```

Menu bar icon (small ring glyph) provides:
- **Pulse motion** / **Ring only** — toggle the heartbeat wave on the rings
- **Stacked rings** / **Split rings (week ◐ session)** — concentric vs vertically bisected layout
- **Show used** / **Show left** — switch percent display
- **Session ring color…** / **Weekly ring color…** / **Reset colors** — pick any color via the system color picker
- **Show meter** — bring the halo back to front
- **Quit**

## Troubleshooting

### Halo shows 0% / no data

Check the auth file exists and the API is reachable:

```bash
cat ~/.codex/auth.json     # should show auth_mode + tokens
```

If `auth_mode` is `chatgpt`, the app uses the ChatGPT account token. If it's `api_key`, usage data isn't available (OpenAI doesn't expose usage for API-key auth).

Watch the app log:

```bash
tail -f /tmp/codex-usage-halo.log
```

### Halo doesn't appear

Make sure Codex's pet is visible (the avatar mascot, not the menu bar icon). Toggle it from inside Codex if needed. The state file should look like:

```bash
python3 -c 'import json; d=json.load(open("'"$HOME"'/.codex/.codex-global-state.json")); print(d.get("electron-avatar-overlay-open"), d.get("electron-avatar-overlay-bounds", {}).get("mascot"))'
```

`True` plus a `{left, top, width, height}` dict means the app should find the sprite.

## Architecture notes

See [docs/design.md](docs/design.md) for the diagnosis trail behind the original AX-based tracking implementation. The current file-based approach (since v0.3.0) sidesteps every issue documented there by reading the sprite rect from Codex's own state file.

## License

MIT — see [LICENSE](LICENSE). This project is not affiliated with OpenAI.
