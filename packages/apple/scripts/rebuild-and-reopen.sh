#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apple_directory="$(cd "${script_directory}/.." && pwd)"
platform="${1:-all}"

macos_app="${apple_directory}/.build/xcode/macos/Build/Products/Debug/Briefly.app"
macos_executable="${macos_app}/Contents/MacOS/Briefly"
ios_app="${apple_directory}/.build/xcode/ios-simulator/Build/Products/Debug-iphonesimulator/Briefly.app"
bundle_identifier="fyi.readbriefly.BrieflyNative"

build_and_open_macos() {
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

    # Stop only prior instances launched from this repo-local derived-data path.
    # Other Briefly installations with the same bundle identifier are untouched.
    while read -r pid command; do
        if [[ "${command}" == "${macos_executable}" ]]; then
            kill "${pid}" 2>/dev/null || true
        fi
    done < <(ps -axo pid=,command=)

    # Launch this exact repo-local build even if another installation is open.
    open -n "${macos_app}"
}

build_and_open_ios() {
    if ! xcrun simctl list devices | grep -q '(Booted)'; then
        echo 'No iOS Simulator is booted. Boot one in Xcode and try again.' >&2
        exit 1
    fi

    xcodebuild \
        -project "${apple_directory}/Briefly.xcodeproj" \
        -scheme Briefly \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "${apple_directory}/.build/xcode/ios-simulator" \
        build

    xcrun simctl terminate booted "${bundle_identifier}" 2>/dev/null || true
    xcrun simctl install booted "${ios_app}"
    xcrun simctl launch booted "${bundle_identifier}"
}

case "${platform}" in
    macos)
        build_and_open_macos
        ;;
    ios)
        build_and_open_ios
        ;;
    all)
        build_and_open_macos
        build_and_open_ios
        ;;
    *)
        echo "Usage: $0 [macos|ios|all]" >&2
        exit 2
        ;;
esac
