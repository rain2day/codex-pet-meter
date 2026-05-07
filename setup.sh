#!/usr/bin/env bash
# One-shot installer for Codex Pet Meter.
# Builds the macOS app, installs it to ~/Applications, and launches it.
# Re-runnable.

set -euo pipefail

cd "$(dirname "$0")"

echo "==> Checking prerequisites"

if ! command -v node >/dev/null 2>&1; then
    echo "Error: Node.js is required (used by the build script). Install from https://nodejs.org/" >&2
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
    echo "         Run 'codex login' first, or the halo will show 0% usage." >&2
fi

echo "==> Building app and installing it to ~/Applications"
node install.mjs install

cat <<'EOF'

==> Setup complete!

The Pet Meter app is in ~/Applications and was just launched. The halo
will follow whichever Codex pet you have set, no calibration step needed.

The app follows Codex's pet from the local Codex state file and reads usage
from local Codex / Claude credentials. OpenUsage is not required.

Useful commands:
  node install.mjs status      # is the app running?
  node install.mjs start       # restart it
  node install.mjs uninstall   # remove it

Diagnostic log:
  tail -f /tmp/codex-usage-halo.log

EOF
