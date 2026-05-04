# Codex Pet Meter

A floating halo overlay that wraps the OpenAI **Codex** desktop app's pet mascot with two animated rings showing your **5-hour session** and **weekly** usage in real time.

- **Cyan ring** — current 5-hour session usage
- **Yellow ring** — weekly usage
- **Hover** the rings to see exact percentages and time-until-reset
- **Drag** the halo to reposition it relative to your pet sprite (auto-calibrates)
- Follows the pet 1:1 in real time using the macOS Accessibility API

> Status: works on macOS 13+. **Source install only — no prebuilt release yet.**
> Requires the OpenAI Codex desktop app, Node.js 20+, and Xcode Command Line Tools.
> A signed `.dmg` release is on the roadmap; for now you build it locally.

## How it works

Three pieces:

1. **`server.mjs`** — tiny local HTTP server that reads your Codex auth token from `~/.codex/auth.json` and proxies the OpenAI usage endpoint at `http://127.0.0.1:43741/api/usage`.
2. **`Codex Pet Meter.app`** — a borderless `LSUIElement` Swift app that draws the halo, follows the Codex pet via the Accessibility API, and polls the server every 60 seconds for usage data.
3. **LaunchAgent** at `~/Library/LaunchAgents/com.rainsday.codex-pet-meter.server.plist` — keeps `server.mjs` running across reboots, restarts it if it crashes (`KeepAlive`).

No Codex.app modification, no asar patching, no integrity hash drama. Just a floating overlay that tracks the pet's window position natively.

## Install

### Prerequisites

- macOS 13+
- [OpenAI Codex desktop app](https://openai.com/) installed and signed in (`codex login`)
- Node.js 20+
- Xcode Command Line Tools (`xcode-select --install`)

### Setup

```bash
git clone https://github.com/rain2day/codex-pet-meter.git
cd codex-pet-meter
./setup.sh
```

The script will:
1. Build and install `~/Applications/Codex Pet Meter.app`
2. Start the usage server on `127.0.0.1:43741`
3. Print the next manual steps

After install, you must:

1. **Grant Accessibility permission** so the halo can track the Codex pet window.
   System Settings → Privacy & Security → Accessibility → click **+** → add `~/Applications/Codex Pet Meter.app` → toggle **ON**.
2. **Calibrate halo position** — drag the halo onto the pet sprite once. The release auto-saves the relative position; from then on the halo follows the pet at that offset.

## Usage

```bash
# App
node install.mjs start              # restart app (also ensures server is running)
node install.mjs reset              # restart app at default screen position
node install.mjs status             # is the app process running?

# Server (managed by launchd, survives reboots)
node install.mjs status-server      # is the server loaded? show pid + log path
node install.mjs start-server       # (re)start via launchd
node install.mjs stop-server        # stop via launchd

# Cleanup
node install.mjs uninstall          # stop + remove app AND server LaunchAgent
```

Menu bar icon (small ring glyph) provides:
- **Orb motion** / **Ring only** — toggle animated orb on the rings
- **Show used** / **Show left** — switch percent display
- **Show meter** — bring halo back to front
- **Reset position** — reset to default offset
- **Reset calibration** — discard saved mascot percentages, fall back to default formula
- **Quit**

## Troubleshooting

### Halo doesn't follow the pet

Check `/tmp/codex-usage-halo.log`:

```bash
tail -f /tmp/codex-usage-halo.log
```

Look for:
- `AX permission at launch: false` → grant Accessibility permission and toggle the entry off/on
- `attach skipped: Codex not running` → Codex isn't running yet
- `AX attached pid=...` → all good, tracking is active

If the line says permission is false but you've granted it: macOS TCC sometimes caches stale entries. Remove the Pet Meter entry from the Accessibility list entirely (`-` button) then add it back via the `+` button.

### Halo "bounces away" near a screen edge

That's Codex's pet self-teleporting when its window hits a screen edge. The halo uses cursor-tracking during drag to absorb this — make sure you've granted Accessibility permission so the global mouse monitor works.

### Diagnostic trace mode

For debugging, run with `--trace` to write detailed per-frame logs:

```bash
node install.mjs trace
# reproduce the issue
node install.mjs trace-stop
# snapshot saved to /tmp/halo-trace-<timestamp>.txt
```

### Server not reachable

```bash
curl http://127.0.0.1:43741/api/usage
```

Should return JSON. If it errors with `Codex auth not found`, run `codex login` in the terminal first.

Server lifecycle is managed by launchd:

```bash
node install.mjs status-server      # show state + log path
node install.mjs start-server       # kickstart it
tail -f /tmp/codex-pet-meter-server.log
```

If the LaunchAgent itself is missing (e.g. you cloned but didn't run `setup.sh`):

```bash
node install.mjs install-server
```

## How rebuilds + permissions interact

The app is **ad-hoc signed** (no Apple Developer cert). Every rebuild changes the binary's CDHash, which causes macOS TCC to drop the Accessibility grant. After every `node install.mjs install`, you'll need to remove and re-add the Pet Meter entry in Accessibility settings.

If this becomes annoying and you have an Apple Developer membership, you can swap the codesign call in `install.mjs` to use your Developer ID — TCC tracks Developer-ID-signed apps by team identifier, so the grant survives rebuilds.

## Architecture notes

See [docs/design.md](docs/design.md) for the diagnosis trail behind the current tracking implementation, including the cursor-tracking workaround for Codex's edge teleport behavior.

## License

MIT — see [LICENSE](LICENSE).

This project is not affiliated with OpenAI.
