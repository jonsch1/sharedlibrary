#!/bin/bash
# Build Shared Library.app — a proper LSUIElement menu bar bundle.
# Usage: Scripts/make_app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Shared Library.app"
EXTRACTOR_SRC="$ROOT/Tools/extractor"
EXTRACTOR_DEST="$APP/Contents/Resources/Tools/extractor"

echo "Installing extractor dependencies..."
npm --prefix "$EXTRACTOR_SRC" ci --omit=dev

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/SharedLibrary"

echo "Assembling bundle at $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/SharedLibrary"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
rsync -a --delete --exclude='.env' "$EXTRACTOR_SRC/" "$EXTRACTOR_DEST/"

# npm packages can carry Finder/resource-fork metadata that codesign rejects.
xattr -cr "$APP"

# Sign with a stable signing identity so the Keychain ACL survives rebuilds.
# Ad-hoc signing (--sign -) changes the code hash on every build, which
# invalidates the "Always Allow" Keychain grant and re-prompts every launch.
# A real cert has a stable designated requirement, so the grant sticks.
# Override with SIGN_IDENTITY=... if you have a different identity.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/[0-9]+\)/{print $2; exit}')}"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  echo "WARNING: no code-signing identity found; falling back to ad-hoc."
  echo "         The Keychain will re-prompt on every rebuild."
  codesign --force --deep --sign - "$APP" 2>/dev/null || echo "(codesign skipped)"
fi

echo "Done: $APP"
echo "Launch with:  open \"$APP\""
