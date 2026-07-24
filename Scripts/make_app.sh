#!/bin/bash
# Build Shared Library.app — a proper LSUIElement menu bar bundle.
# Usage: Scripts/make_app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/Shared Library.app"
EXTRACTOR_SRC="$ROOT/Tools/extractor"
DESKTOP_PROJECT="$ROOT/Desktop/SharedLibraryDesktop.xcodeproj"
DERIVED_DATA="$ROOT/.build/SharedLibraryDesktopDerived"
GOOGLE_DESKTOP_CLIENT_ID="${SHARED_LIBRARY_GOOGLE_DESKTOP_CLIENT_ID:-}"
GOOGLE_DESKTOP_CLIENT_SECRET="${SHARED_LIBRARY_GOOGLE_DESKTOP_CLIENT_SECRET:-}"
if [ -z "$GOOGLE_DESKTOP_CLIENT_SECRET" ]; then
  GOOGLE_DESKTOP_CLIENT_SECRET="$(
    security find-generic-password \
      -s "com.sharedlibrary.build.google-oauth" \
      -a "desktop-client-secret" \
      -w 2>/dev/null || true
  )"
fi

if [ "$CONFIG" = "debug" ]; then
  XCODE_CONFIG="Debug"
else
  XCODE_CONFIG="Release"
fi

echo "Building the macOS bundle ($XCODE_CONFIG)…"
XCODE_SETTINGS_FILE="$(mktemp "${TMPDIR:-/tmp}/shared-library-xcode.XXXXXX")"
chmod 600 "$XCODE_SETTINGS_FILE"
{
  printf 'SHARED_LIBRARY_GOOGLE_DESKTOP_CLIENT_ID = %s\n' "$GOOGLE_DESKTOP_CLIENT_ID"
  printf 'SHARED_LIBRARY_GOOGLE_DESKTOP_CLIENT_SECRET = %s\n' "$GOOGLE_DESKTOP_CLIENT_SECRET"
} > "$XCODE_SETTINGS_FILE"
if xcodebuild \
  -project "$DESKTOP_PROJECT" \
  -scheme SharedLibraryDesktop \
  -configuration "$XCODE_CONFIG" \
  -derivedDataPath "$DERIVED_DATA" \
  -xcconfig "$XCODE_SETTINGS_FILE" \
  -allowProvisioningUpdates \
  build 2>&1 | sed '/SHARED_LIBRARY_GOOGLE_DESKTOP_CLIENT_SECRET/d'; then
  rm -f "$XCODE_SETTINGS_FILE"
  PROVISIONED_APP="$DERIVED_DATA/Build/Products/$XCODE_CONFIG/Shared Library.app"
  rm -rf "$APP"
  ditto "$PROVISIONED_APP" "$APP"
  echo "Done: $APP"
  echo "Launch with:  open \"$APP\""
  exit 0
fi

rm -f "$XCODE_SETTINGS_FILE"
echo "WARNING: Xcode bundle build failed; using the SwiftPM fallback."

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shared-library-app.XXXXXX")"
STAGING_APP="$STAGING_DIR/Shared Library.app"
EXTRACTOR_DEST="$STAGING_APP/Contents/Resources/Tools/extractor"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "Installing extractor dependencies..."
npm --prefix "$EXTRACTOR_SRC" ci --omit=dev

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/SharedLibrary"

echo "Assembling bundle at $STAGING_APP"
mkdir -p "$STAGING_APP/Contents/MacOS"
mkdir -p "$STAGING_APP/Contents/Resources"

cp "$BIN" "$STAGING_APP/Contents/MacOS/SharedLibrary"
cp "$ROOT/Resources/Info.plist" "$STAGING_APP/Contents/Info.plist"
if [ -n "$GOOGLE_DESKTOP_CLIENT_ID" ]; then
  /usr/libexec/PlistBuddy -c "Set :SharedLibraryGoogleDesktopClientID $GOOGLE_DESKTOP_CLIENT_ID" "$STAGING_APP/Contents/Info.plist"
fi
if [ -n "$GOOGLE_DESKTOP_CLIENT_SECRET" ]; then
  /usr/libexec/PlistBuddy -c "Set :SharedLibraryGoogleDesktopClientSecret $GOOGLE_DESKTOP_CLIENT_SECRET" "$STAGING_APP/Contents/Info.plist"
fi
rsync -a --delete --exclude='.env' "$EXTRACTOR_SRC/" "$EXTRACTOR_DEST/"

# npm packages can carry Finder/resource-fork metadata that codesign rejects.
xattr -cr "$STAGING_APP"

# Sign with a stable signing identity so the Keychain ACL survives rebuilds.
# Ad-hoc signing (--sign -) changes the code hash on every build, which
# invalidates the "Always Allow" Keychain grant and re-prompts every launch.
# A real cert has a stable designated requirement, so the grant sticks.
# Override with SIGN_IDENTITY=... if you have a different identity.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/[0-9]+\)/{print $2; exit}')}"

if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING_APP"
else
  echo "WARNING: no code-signing identity found; falling back to ad-hoc."
  echo "         The Keychain will re-prompt on every rebuild."
  codesign --force --deep --sign - "$STAGING_APP" 2>/dev/null || echo "(codesign skipped)"
fi

rm -rf "$APP"
ditto "$STAGING_APP" "$APP"

echo "Done: $APP"
echo "Launch with:  open \"$APP\""
