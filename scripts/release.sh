#!/bin/bash
set -euo pipefail

# Prepares a signed, notarized Sparkle release candidate from an app exported
# through Xcode Organizer. This script deliberately never builds with xcodebuild
# and never creates tags, GitHub releases, or appcast commits.

if [ -d "/opt/homebrew/bin" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
EXPORTED_APP_PATH="${2:-}"
NOTARY_PROFILE="${SATO_NOTARY_PROFILE:-sato-notarization}"
DEVELOPER_IDENTITY="${SATO_DEVELOPER_IDENTITY:-Developer ID Application: Amir Valizadeh (UP52GQK38V)}"
DEVELOPER_IDENTITY_HASH="${SATO_DEVELOPER_IDENTITY_HASH:-}"
GITHUB_REPOSITORY="vitalune/sato"
DMG_BACKGROUND="${PROJECT_DIR}/assets/dmg/background.png"

if [ -z "$VERSION" ] || [ -z "$EXPORTED_APP_PATH" ]; then
    echo "Usage: $0 <version> <path-to-Xcode-exported-Sato.app>"
    echo "Example: $0 1.2.0 ~/Desktop/Sato.app"
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use semantic versioning, for example 1.2.0"
    exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
    echo "Release candidates must be prepared on macOS with Xcode and Keychain access."
    exit 1
fi

if [ ! -d "$EXPORTED_APP_PATH" ]; then
    echo "Exported app not found: $EXPORTED_APP_PATH"
    exit 1
fi

if [ "$(basename "$EXPORTED_APP_PATH")" != "Sato.app" ]; then
    echo "Expected an exported app named Sato.app"
    exit 1
fi

for requiredCommand in create-dmg codesign ditto security spctl stat xcrun; do
    if ! command -v "$requiredCommand" >/dev/null 2>&1; then
        echo "Missing required command: $requiredCommand"
        exit 1
    fi
done

availableSigningIdentities="$(security find-identity -v -p codesigning)"
if [ -n "$DEVELOPER_IDENTITY_HASH" ]; then
    if [[ "$availableSigningIdentities" != *"$DEVELOPER_IDENTITY_HASH"* ]]; then
        echo "Developer ID signing identity hash not found: $DEVELOPER_IDENTITY_HASH"
        exit 1
    fi
else
    matchingIdentityHashes=()
    while IFS= read -r signingIdentityLine; do
        if [[ "$signingIdentityLine" == *"\"${DEVELOPER_IDENTITY}\""* ]]; then
            signingIdentityRemainder="${signingIdentityLine#*) }"
            matchingIdentityHashes+=("${signingIdentityRemainder%% *}")
        fi
    done <<< "$availableSigningIdentities"

    if [ "${#matchingIdentityHashes[@]}" -eq 0 ]; then
        echo "Developer ID signing identity not found: $DEVELOPER_IDENTITY"
        echo "Set SATO_DEVELOPER_IDENTITY if the certificate name differs."
        exit 1
    fi

    DEVELOPER_IDENTITY_HASH="${matchingIdentityHashes[0]}"
    if [ "${#matchingIdentityHashes[@]}" -gt 1 ]; then
        echo "Multiple certificates share the Developer ID name."
        echo "Using certificate hash: $DEVELOPER_IDENTITY_HASH"
    fi
fi

if [ ! -f "$DMG_BACKGROUND" ]; then
    echo "DMG background not found: $DMG_BACKGROUND"
    exit 1
fi

SPARKLE_BIN="${SPARKLE_BIN:-}"
if [ -z "$SPARKLE_BIN" ]; then
    shopt -s nullglob
    sparkleCandidateDirectories=(
        "$HOME"/Library/Developer/Xcode/DerivedData/*/SourcePackages/artifacts/sparkle/Sparkle/bin
        "/Applications/Sparkle.app/Contents/MacOS"
    )
    shopt -u nullglob

    for sparkleCandidateDirectory in "${sparkleCandidateDirectories[@]}"; do
        if [ -x "${sparkleCandidateDirectory}/sign_update" ] \
            && [ -x "${sparkleCandidateDirectory}/generate_appcast" ]; then
            SPARKLE_BIN="$sparkleCandidateDirectory"
            break
        fi
    done
fi

if [ -z "$SPARKLE_BIN" ] \
    || [ ! -x "${SPARKLE_BIN}/sign_update" ] \
    || [ ! -x "${SPARKLE_BIN}/generate_appcast" ]; then
    echo "Sparkle tools were not found."
    echo "Build once in Xcode so Swift Package Manager downloads Sparkle,"
    echo "or set SPARKLE_BIN to the directory containing sign_update and generate_appcast."
    exit 1
fi

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Apple notarization credentials are unavailable for profile: $NOTARY_PROFILE"
    echo "Set SATO_NOTARY_PROFILE or store credentials with xcrun notarytool."
    exit 1
fi

IFS='.' read -r versionMajor versionMinor versionPatch <<< "$VERSION"
EXPECTED_BUILD_NUMBER=$(printf "%d%02d%02d" \
    "$versionMajor" \
    "$versionMinor" \
    "$versionPatch")
EXPORTED_INFO_PLIST="${EXPORTED_APP_PATH}/Contents/Info.plist"
EXPORTED_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" \
    "$EXPORTED_INFO_PLIST")
EXPORTED_BUILD_NUMBER=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" \
    "$EXPORTED_INFO_PLIST")

if [ "$EXPORTED_VERSION" != "$VERSION" ] \
    || [ "$EXPORTED_BUILD_NUMBER" != "$EXPECTED_BUILD_NUMBER" ]; then
    echo "The exported app version does not match the requested release."
    echo "Expected: ${VERSION} (${EXPECTED_BUILD_NUMBER})"
    echo "Exported: ${EXPORTED_VERSION} (${EXPORTED_BUILD_NUMBER})"
    echo "Update Info.plist, then archive and export again through Xcode Organizer."
    exit 1
fi

CANDIDATE_DIRECTORY="${PROJECT_DIR}/build/release-candidate-v${VERSION}"
STAGING_DIRECTORY="${CANDIDATE_DIRECTORY}/staging"
ARCHIVES_DIRECTORY="${CANDIDATE_DIRECTORY}/archives"
STAGED_APP_PATH="${STAGING_DIRECTORY}/Sato.app"
APP_NOTARIZATION_ZIP="${CANDIDATE_DIRECTORY}/Sato-${VERSION}.zip"
DMG_PATH="${ARCHIVES_DIRECTORY}/Sato-${VERSION}.dmg"
STAGED_APPCAST_PATH="${CANDIDATE_DIRECTORY}/appcast.xml"
SPARKLE_SIGNATURE_PATH="${CANDIDATE_DIRECTORY}/sparkle-signature.txt"
RELEASE_NOTES_PATH="${CANDIDATE_DIRECTORY}/release-notes.md"

rm -rf "$CANDIDATE_DIRECTORY"
mkdir -p "$STAGING_DIRECTORY" "$ARCHIVES_DIRECTORY"
ditto "$EXPORTED_APP_PATH" "$STAGED_APP_PATH"

echo "Verifying the Developer ID signature..."
codesign --verify --deep --strict --verbose=2 "$STAGED_APP_PATH"

echo "Submitting the app for notarization..."
ditto -c -k --keepParent "$STAGED_APP_PATH" "$APP_NOTARIZATION_ZIP"
xcrun notarytool submit "$APP_NOTARIZATION_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$STAGED_APP_PATH"
xcrun stapler validate "$STAGED_APP_PATH"
spctl --assess --type execute --verbose "$STAGED_APP_PATH"

echo "Creating the release DMG..."
set +e
create-dmg \
    --volname "Sato ${VERSION}" \
    --background "$DMG_BACKGROUND" \
    --window-pos 200 120 \
    --window-size 540 378 \
    --icon-size 100 \
    --icon "Sato.app" 135 189 \
    --hide-extension "Sato.app" \
    --app-drop-link 405 189 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGING_DIRECTORY"
createDmgExitCode=$?
set -e

# create-dmg returns 2 when Finder cannot set the volume icon even though the
# resulting DMG is valid.
if [ "$createDmgExitCode" -ne 0 ] && [ "$createDmgExitCode" -ne 2 ]; then
    echo "create-dmg failed with exit code ${createDmgExitCode}"
    exit "$createDmgExitCode"
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "DMG creation failed: ${DMG_PATH} was not produced"
    exit 1
fi

echo "Signing the DMG with Developer ID..."
codesign --force \
    --sign "$DEVELOPER_IDENTITY_HASH" \
    --timestamp \
    "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

echo "Submitting the DMG for notarization..."
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "Signing the final DMG for Sparkle..."
"${SPARKLE_BIN}/sign_update" "$DMG_PATH" > "$SPARKLE_SIGNATURE_PATH"

if [ -f "${PROJECT_DIR}/appcast.xml" ]; then
    cp "${PROJECT_DIR}/appcast.xml" "$STAGED_APPCAST_PATH"
fi

echo "Generating the staged Sparkle appcast..."
"${SPARKLE_BIN}/generate_appcast" \
    --download-url-prefix "https://github.com/${GITHUB_REPOSITORY}/releases/download/v${VERSION}/" \
    -o "$STAGED_APPCAST_PATH" \
    "$ARCHIVES_DIRECTORY"
/usr/bin/xmllint --noout "$STAGED_APPCAST_PATH"

stagedAppcastContents="$(<"$STAGED_APPCAST_PATH")"
if [[ "$stagedAppcastContents" != *"<sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>"* ]]; then
    echo "The staged appcast does not contain version ${VERSION}"
    exit 1
fi

cat > "$RELEASE_NOTES_PATH" <<EOF
# Sato ${VERSION}

## What's new

- Detach chat into a movable, resizable floating window.
- Dock chat to either side of any connected display.
- Resize docked chat with responsive message and Markdown wrapping.
- Reopen the five most recent conversations from the menu bar.
- Pin important conversations so they persist beyond the recent-history limit.
EOF

DMG_SIZE=$(stat -f%z "$DMG_PATH")

echo ""
echo "Release candidate v${VERSION} (${EXPECTED_BUILD_NUMBER}) is ready."
echo "DMG: ${DMG_PATH}"
echo "Size: ${DMG_SIZE} bytes"
echo "Sparkle signature: ${SPARKLE_SIGNATURE_PATH}"
echo "Staged appcast: ${STAGED_APPCAST_PATH}"
echo "Release notes: ${RELEASE_NOTES_PATH}"
echo ""
echo "Nothing was tagged, uploaded, published, or pushed."
