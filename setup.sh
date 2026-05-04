#!/usr/bin/env bash
# One-shot installer for Codex Pet Meter.
# Builds the macOS app, installs it to ~/Applications, and starts the usage server.
# Re-runnable.

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

echo "==> Building and installing Codex Pet Meter.app"
node install.mjs install

echo
echo "==> Starting usage server (background)"
nohup node server.mjs >/tmp/codex-pet-meter-server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID (logs at /tmp/codex-pet-meter-server.log)"

sleep 1
if curl -sS -m 2 http://127.0.0.1:43741/api/usage >/dev/null 2>&1; then
    echo "Server is reachable on http://127.0.0.1:43741"
else
    echo "Warning: server is not yet reachable. Check /tmp/codex-pet-meter-server.log" >&2
fi

cat <<'EOF'

==> Setup complete!

Next steps (manual, only on first run):

  1. Grant Accessibility permission so the halo can track the Codex pet:
       System Settings -> Privacy & Security -> Accessibility
       Click +, add ~/Applications/Codex Pet Meter.app, toggle ON.

  2. Drag the halo (the two rings) onto the Codex pet sprite.
     When you release, the halo auto-saves the relative position.

To stop everything:
  pkill -f CodexPetMeter
  pkill -f "node.*server.mjs"

To uninstall:
  node install.mjs uninstall

Diagnostic logs:
  tail -f /tmp/codex-usage-halo.log

EOF
