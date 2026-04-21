#!/bin/bash
#
# Builds Sato in Release mode, packages it as a signed .dmg installer,
# and prints the Sparkle EdDSA signature for appcast.xml.
#
# Usage:
#   ./scripts/build-release.sh 1.0.0
#
# Prerequisites:
#   brew install create-dmg
#
# Output:
#   build/Sato-<version>.dmg
#
set -e

# Ensure Homebrew tools are on PATH (common on Apple Silicon Macs)
if [ -d "/opt/homebrew/bin" ]; then
    export PATH="/opt/homebrew/bin:$PATH"
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "  Example: $0 1.0.0"
    exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Version must be in semver format (e.g. 1.0.0)"
    exit 1
fi

# Resolve project root relative to this script's location
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
EXPORT_DIR="$BUILD_DIR/export"
DMG_OUTPUT="$BUILD_DIR/Sato-$VERSION.dmg"
BACKGROUND_1X="$PROJECT_DIR/assets/dmg/background.png"
BACKGROUND_2X="$PROJECT_DIR/assets/dmg/background@2x.png"
INFO_PLIST="$PROJECT_DIR/leanring-buddy/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/leanring-buddy/leanring-buddy.entitlements"

# Preflight checks
if ! command -v create-dmg &>/dev/null; then
    echo "create-dmg not found. Install it with: brew install create-dmg"
    exit 1
fi

if [ ! -f "$BACKGROUND_1X" ]; then
    echo "DMG background not found at $BACKGROUND_1X"
    exit 1
fi

echo "Building Sato v$VERSION..."
echo ""

# Clean previous build artifacts
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR"

# Stamp the version into Info.plist so the built app reports it correctly
echo "Updating Info.plist to version $VERSION..."
plutil -replace CFBundleShortVersionString -string "$VERSION" "$INFO_PLIST"

# Derive a monotonic build number from the version (1.0.0 -> 100, 1.2.3 -> 123)
# so Sparkle's sparkle:version comparisons always increase.
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }')
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$INFO_PLIST"

# Build in Release configuration.
# The scheme is "leanring-buddy" (legacy name) but PRODUCT_NAME is "Sato",
# so the output is Sato.app.
echo "Compiling Sato in Release mode..."
xcodebuild \
    -project "$PROJECT_DIR/leanring-buddy.xcodeproj" \
    -scheme "leanring-buddy" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    -destination "generic/platform=macOS" \
    clean build \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    2>&1 | tail -5

# Locate the built app
BUILT_APP="$BUILD_DIR/DerivedData/Build/Products/Release/Sato.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "Build failed — Sato.app not found at $BUILT_APP"
    exit 1
fi

cp -R "$BUILT_APP" "$EXPORT_DIR/Sato.app"

# Ad-hoc sign with hardened runtime so Gatekeeper is less hostile
echo "Ad-hoc signing Sato.app..."
codesign --force --deep --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$EXPORT_DIR/Sato.app"

codesign --verify --verbose "$EXPORT_DIR/Sato.app" 2>&1 || true

# Build the DMG.
# Window size matches the 1x background (540x378). Icon positions place
# Sato.app to the left of the terracotta arrow and Applications to the right.
echo "Creating DMG..."

# create-dmg returns exit code 2 when it can't set the custom icon on the DMG
# volume itself (common on CI and without Finder), but the DMG is still valid.
# Treat exit code 2 as success.
set +e
create-dmg \
    --volname "Sato $VERSION" \
    --background "$BACKGROUND_1X" \
    --window-pos 200 120 \
    --window-size 540 378 \
    --icon-size 100 \
    --icon "Sato.app" 135 189 \
    --hide-extension "Sato.app" \
    --app-drop-link 405 189 \
    --no-internet-enable \
    "$DMG_OUTPUT" \
    "$EXPORT_DIR"
DMG_EXIT=$?
set -e

if [ $DMG_EXIT -ne 0 ] && [ $DMG_EXIT -ne 2 ]; then
    echo "create-dmg failed with exit code $DMG_EXIT"
    exit 1
fi

if [ ! -f "$DMG_OUTPUT" ]; then
    echo "DMG creation failed — file not found"
    exit 1
fi

DMG_SIZE=$(stat -f%z "$DMG_OUTPUT")
echo ""
echo "DMG created: $DMG_OUTPUT ($DMG_SIZE bytes)"

# Sign the DMG with Sparkle's EdDSA key so auto-update signature
# verification works. The private key must be in the macOS Keychain
# (put there by Sparkle's generate_keys tool).
echo ""
echo "Signing DMG with Sparkle EdDSA key..."
SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -name "sign_update" -path "*/artifacts/*" 2>/dev/null | head -1)
if [ -z "$SIGN_UPDATE" ]; then
    echo "sign_update not found in DerivedData. Build the project in Xcode first"
    echo "so Sparkle's SPM artifacts are available, or install Sparkle via Homebrew:"
    echo "  brew install --cask sparkle"
    exit 1
fi

SIGNATURE=$("$SIGN_UPDATE" "$DMG_OUTPUT")

echo ""
echo "Build complete!"
echo ""
echo "  File:    $DMG_OUTPUT"
echo "  Size:    $DMG_SIZE bytes"
echo "  Version: $VERSION (build $BUILD_NUMBER)"
echo ""
echo "Sparkle signature (add to appcast.xml <enclosure> tag):"
echo "$SIGNATURE"
echo ""
