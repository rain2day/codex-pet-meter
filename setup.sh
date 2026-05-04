#!/usr/bin/env bash
# One-shot installer for Codex Pet Meter.
# Builds the macOS app, installs a server LaunchAgent (auto-starts the usage
# server at login), and starts both. Re-runnable.

set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking prerequisites"

if ! command -v node >/dev/null 2>&1; then
    echo "Error: Node.js is required. Install from https://nodejs.org/" >&2
    exit 1
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "Error: Xcode Command Line Tools are required. Run: xcode-select --install" >&2
    exit 1
fi

if [ ! -d "/Applications/Codex.app" ]; then
    echo "Warning: /Applications/Codex.app not found." >&2
    echo "         The Pet Meter will install but won't show data until you install OpenAI Codex." >&2
fi

CODEX_AUTH="${CODEX_HOME:-$HOME/.codex}/auth.json"
if [ ! -f "$CODEX_AUTH" ]; then
    echo "Warning: $CODEX_AUTH not found." >&2
    echo "         Run 'codex login' first, or the usage server will return errors." >&2
fi

echo "==> Building app, installing server LaunchAgent, starting both"
node install.mjs install

echo
echo "==> Verifying server is reachable"
sleep 2
if curl -sS -m 3 http://127.0.0.1:43741/api/usage >/dev/null 2>&1; then
    echo "Server is reachable on http://127.0.0.1:43741"
else
    echo "Warning: server is not yet reachable. Check ${TMPDIR:-/tmp}/codex-pet-meter-server.log" >&2
    echo "         Or run: node install.mjs status-server" >&2
fi

cat <<'EOF'

==> Setup complete!

The server is running under launchd and will auto-start every login.
The Pet Meter app is in ~/Applications and was just launched.

Next steps (manual, only on first run):

  1. Grant Accessibility permission so the halo can track the Codex pet:
       System Settings -> Privacy & Security -> Accessibility
       Click +, add ~/Applications/Codex Pet Meter.app, toggle ON.

  2. Drag the halo (the two rings) onto the Codex pet sprite.
     When you release, the halo auto-saves the relative position.

Useful commands:
  node install.mjs status            # is the app running?
  node install.mjs status-server     # is the server loaded?
  node install.mjs uninstall         # remove everything

Diagnostic logs:
  tail -f /tmp/codex-usage-halo.log         # app
  tail -f /tmp/codex-pet-meter-server.log   # server (managed by launchd)

EOF
