#!/bin/bash
# Build, sign, and install Shared Library into /Applications.
# Run this again any time to UPDATE — it's idempotent (quits the running
# copy, replaces the bundle, relaunches).
# Usage: Scripts/install.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Shared Library.app"
DEST="/Applications/Shared Library.app"

# 1. Build + sign the bundle in the repo.
"$ROOT/Scripts/make_app.sh" "$CONFIG"

# 2. Quit any running instance so the bundle isn't busy.
if pgrep -x SharedLibrary >/dev/null; then
  echo "Quitting running Shared Library…"
  osascript -e 'quit app "Shared Library"' 2>/dev/null || pkill -x SharedLibrary || true
  # Wait for it to actually exit.
  for _ in $(seq 1 20); do pgrep -x SharedLibrary >/dev/null || break; sleep 0.2; done
fi

# 3. Replace the installed copy.
echo "Installing to $DEST"
rm -rf "$DEST"
cp -R "$APP" "$DEST"

# 4. Relaunch the installed copy.
echo "Launching…"
open "$DEST"

echo "Done. Shared Library is installed in /Applications and running."
