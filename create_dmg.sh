#!/bin/bash
set -e

APP_NAME="TypstEdit"
APP_BUNDLE="TypstEdit.app"
# arm64 = default. Pass "universal" for the Intel+ARM fat build.
ARCH=${1:-arm64}

case "$ARCH" in
    arm64)
        BUNDLE_SCRIPT="./bundle.sh"
        DMG_NAME="TypstEdit_Installer.dmg"
        ;;
    universal)
        BUNDLE_SCRIPT="./bundle_universal.sh"
        DMG_NAME="TypstEdit_Installer_universal.dmg"
        ;;
    *)
        echo "Usage: $0 [arm64|universal]  (default: arm64)"
        exit 1
        ;;
esac

echo "📦 Preparing to package $APP_NAME ($ARCH)..."

# Ensure bundle exists and is fresh
"$BUNDLE_SCRIPT"

# Create temporary folder for DMG content
echo "📂 Setting up DMG structure..."
rm -rf dist
mkdir -p dist
cp -r "$APP_BUNDLE" dist/
ln -s /Applications dist/Applications

# Create DMG
echo "💿 Creating DMG ($DMG_NAME)..."
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder dist -ov -format UDZO "$DMG_NAME"

# Clean up
rm -rf dist

echo "✅ DMG created successfully: $DMG_NAME"
