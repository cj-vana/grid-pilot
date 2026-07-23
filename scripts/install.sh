#!/bin/zsh
# Build, install to /Applications, link the CLI, and launch.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/make-app.sh

if pgrep -xq gridpilot; then
    echo "stopping running GridPilot…"
    pkill -x gridpilot || true
    sleep 1
fi

rm -rf /Applications/GridPilot.app
cp -R dist/GridPilot.app /Applications/

mkdir -p /usr/local/bin 2>/dev/null || true
if [ -w /usr/local/bin ]; then
    ln -sf /Applications/GridPilot.app/Contents/MacOS/gridpilot /usr/local/bin/gridpilot
    echo "linked /usr/local/bin/gridpilot"
else
    echo "note: /usr/local/bin not writable — add an alias:"
    echo "  alias gridpilot=/Applications/GridPilot.app/Contents/MacOS/gridpilot"
fi

open /Applications/GridPilot.app
echo "GridPilot is running — look for the fader icon in your menu bar."
