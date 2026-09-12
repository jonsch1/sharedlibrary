#!/bin/bash

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apple_directory="$(cd "${script_directory}/.." && pwd)"
action="${1:-archive}"
build_number="${BUILD_NUMBER:-}"
release_directory="${BRIEFLY_RELEASE_DIRECTORY:-${apple_directory}/.build/testflight}"
archive_path="${release_directory}/Briefly-${build_number:-unset}.xcarchive"
export_path="${release_directory}/export-${build_number:-unset}-$(date -u +%Y%m%d%H%M%S)"
export_options="${apple_directory}/AppStore/ExportOptions.plist"

usage() {
    cat <<'EOF'
Usage:
  BUILD_NUMBER=<number> ./scripts/testflight.sh archive
  BUILD_NUMBER=<number> ./scripts/testflight.sh export
  BUILD_NUMBER=<number> ./scripts/testflight.sh upload

Actions:
  archive  Create and verify a signed iOS archive without sending it to Apple.
  export   Re-sign an existing archive for the App Store and export an IPA.
  upload   Upload an existing, verified archive to App Store Connect.

Optional App Store Connect API-key authentication:
  ASC_KEY_PATH=/absolute/path/to/AuthKey_<id>.p8
  ASC_KEY_ID=<key-id>
  ASC_ISSUER_ID=<issuer-id>

The project supplies the marketing version. BUILD_NUMBER overrides
CURRENT_PROJECT_VERSION for the app and its share extension without editing the
Xcode project. Every successful App Store Connect upload needs a unique build
number for that marketing version.
EOF
}

if [[ "${action}" != "archive" && "${action}" != "export" && "${action}" != "upload" ]]; then
    usage >&2
    exit 2
fi

if [[ -z "${build_number}" ]]; then
    echo 'BUILD_NUMBER is required.' >&2
    usage >&2
    exit 2
fi

if [[ ! "${build_number}" =~ ^[0-9]+([.][0-9]+){0,2}$ ]]; then
    echo 'BUILD_NUMBER must contain one to three period-separated integers.' >&2
    exit 2
fi

authentication_arguments=(-allowProvisioningUpdates)
authentication_values=("${ASC_KEY_PATH:-}" "${ASC_KEY_ID:-}" "${ASC_ISSUER_ID:-}")
authentication_value_count=0
for value in "${authentication_values[@]}"; do
    if [[ -n "${value}" ]]; then
        authentication_value_count=$((authentication_value_count + 1))
    fi
done

if [[ "${authentication_value_count}" -ne 0 && "${authentication_value_count}" -ne 3 ]]; then
    echo 'Set ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID together, or omit all three.' >&2
    exit 2
fi

if [[ "${authentication_value_count}" -eq 3 ]]; then
    if [[ ! -f "${ASC_KEY_PATH}" ]]; then
        echo "App Store Connect API key not found: ${ASC_KEY_PATH}" >&2
        exit 2
    fi
    authentication_arguments+=(
        -authenticationKeyPath "${ASC_KEY_PATH}"
        -authenticationKeyID "${ASC_KEY_ID}"
        -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
    )
fi

mkdir -p "${release_directory}"

if [[ "${action}" == "archive" ]]; then
    if [[ -e "${archive_path}" ]]; then
        echo "Archive already exists: ${archive_path}" >&2
        echo 'Choose a new BUILD_NUMBER or move the existing archive intentionally.' >&2
        exit 1
    fi

    echo "Archiving Briefly build ${build_number} for iOS and iPadOS..."
    xcodebuild \
        -project "${apple_directory}/Briefly.xcodeproj" \
        -scheme Briefly \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "${archive_path}" \
        -derivedDataPath "${release_directory}/DerivedData" \
        "${authentication_arguments[@]}" \
        CURRENT_PROJECT_VERSION="${build_number}" \
        archive
elif [[ ! -d "${archive_path}" ]]; then
    echo "Archive not found: ${archive_path}" >&2
    echo "Create it first with BUILD_NUMBER=${build_number} ./scripts/testflight.sh archive" >&2
    exit 1
fi

archive_info="${archive_path}/Info.plist"
app_path="${archive_path}/Products/Applications/Briefly.app"
app_info="${app_path}/Info.plist"

if [[ ! -f "${archive_info}" || ! -f "${app_info}" ]]; then
    echo "Archive is missing its expected Briefly app: ${archive_path}" >&2
    exit 1
fi

bundle_identifier="$(plutil -extract CFBundleIdentifier raw "${app_info}")"
marketing_version="$(plutil -extract CFBundleShortVersionString raw "${app_info}")"
archived_build_number="$(plutil -extract CFBundleVersion raw "${app_info}")"

if [[ "${bundle_identifier}" != 'fyi.readbriefly.BrieflyNative' ]]; then
    echo "Unexpected bundle identifier in archive: ${bundle_identifier}" >&2
    exit 1
fi

if [[ "${archived_build_number}" != "${build_number}" ]]; then
    echo "Unexpected build number in archive: ${archived_build_number}" >&2
    exit 1
fi

codesign --verify --deep --strict "${app_path}"

echo "Verified Briefly ${marketing_version} (${archived_build_number})."
echo "Archive: ${archive_path}"

if [[ "${action}" == "archive" ]]; then
    echo 'Archive only: nothing was uploaded.'
    exit 0
fi

if [[ "${action}" == "export" ]]; then
    local_export_options="${export_path}-ExportOptions.plist"
    cp "${export_options}" "${local_export_options}"
    /usr/libexec/PlistBuddy -c 'Set :destination export' "${local_export_options}"

    echo 'Re-signing the verified archive for App Store distribution...'
    xcodebuild \
        -exportArchive \
        -archivePath "${archive_path}" \
        -exportPath "${export_path}" \
        -exportOptionsPlist "${local_export_options}" \
        "${authentication_arguments[@]}"

    distribution_summary="${export_path}/DistributionSummary.plist"
    if [[ ! -f "${distribution_summary}" ]]; then
        echo 'Export is missing its distribution summary.' >&2
        exit 1
    fi

    certificate_type="$(/usr/libexec/PlistBuddy -c 'Print :Briefly.ipa:0:certificate:type' "${distribution_summary}")"
    app_debuggable="$(/usr/libexec/PlistBuddy -c 'Print :Briefly.ipa:0:entitlements:get-task-allow' "${distribution_summary}")"
    extension_debuggable="$(/usr/libexec/PlistBuddy -c 'Print :Briefly.ipa:0:embeddedBinaries:0:entitlements:get-task-allow' "${distribution_summary}")"
    push_environment="$(/usr/libexec/PlistBuddy -c 'Print :Briefly.ipa:0:entitlements:aps-environment' "${distribution_summary}")"
    cloudkit_environment="$(/usr/libexec/PlistBuddy -c 'Print :Briefly.ipa:0:entitlements:com.apple.developer.icloud-container-environment' "${distribution_summary}")"

    if [[ "${certificate_type}" != *'Apple Distribution'* ]]; then
        echo "Unexpected export certificate: ${certificate_type}" >&2
        exit 1
    fi
    if [[ "${app_debuggable}" != 'false' || "${extension_debuggable}" != 'false' ]]; then
        echo 'The exported app or share extension is still debuggable.' >&2
        exit 1
    fi
    if [[ "${push_environment}" != 'production' || "${cloudkit_environment}" != 'Production' ]]; then
        echo 'The exported app is missing its production push or CloudKit environment.' >&2
        exit 1
    fi

    echo "Exported Briefly ${marketing_version} (${archived_build_number}) without uploading it."
    echo "Signing: ${certificate_type}; production push and CloudKit verified."
    echo "Export: ${export_path}"
    exit 0
fi

echo 'Uploading the verified archive to App Store Connect...'
xcodebuild \
    -exportArchive \
    -archivePath "${archive_path}" \
    -exportPath "${export_path}" \
    -exportOptionsPlist "${export_options}" \
    "${authentication_arguments[@]}"

echo "Upload accepted for processing: Briefly ${marketing_version} (${archived_build_number})."
echo 'Open App Store Connect > ReadBriefly > TestFlight to follow processing and assign testers.'
