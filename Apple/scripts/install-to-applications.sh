#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apple_directory="$(cd "${script_directory}/.." && pwd)"
target_dir="${1:-/Applications}"
destination_app="${target_dir}/Briefly.app"
destination_executable="${destination_app}/Contents/MacOS/Briefly"

macos_app="${apple_directory}/.build/xcode/macos/Build/Products/Debug/Briefly.app"
macos_executable="${macos_app}/Contents/MacOS/Briefly"
bundle_identifier="fyi.readbriefly.BrieflyNative"

echo "==> Building Briefly for macOS..."
xcodebuild \
    -project "${apple_directory}/Briefly.xcodeproj" \
    -scheme Briefly \
    -destination 'platform=macOS' \
    -derivedDataPath "${apple_directory}/.build/xcode/macos" \
    build

if ! codesign -d --entitlements - "${macos_app}" 2>&1 \
    | grep -q 'com.apple.developer.applesignin'; then
    echo 'The macOS app is missing the Sign in with Apple entitlement.' >&2
    echo 'Open Xcode and refresh the Briefly development signing profile.' >&2
    exit 1
fi

echo "==> Stopping running Briefly instances..."
# Terminate running Briefly instances so the binary/bundle is not locked
while read -r pid command; do
    if [[ "${command}" == "${destination_executable}"* || "${command}" == "${macos_executable}"* ]]; then
        kill "${pid}" 2>/dev/null || true
    fi
done < <(ps -axo pid=,command=)

pkill -x Briefly 2>/dev/null || true

echo "==> Installing Briefly to ${destination_app}..."
mkdir -p "${target_dir}"
rm -rf "${destination_app}"
ditto "${macos_app}" "${destination_app}"

echo "==> Launching ${destination_app}..."
open -n "${destination_app}"

echo "==> Briefly installed and launched successfully from ${destination_app}."
