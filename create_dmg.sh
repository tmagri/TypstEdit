#!/bin/bash
set -e

APP_NAME="TypstEdit"
APP_BUNDLE="TypstEdit.app"
# arm64 = default. Each installer contains only its target architecture.
ARCH=${1:-arm64}

case "$ARCH" in
    arm64)
        DMG_NAME="TypstEdit_AppleSilicon.dmg"
        ;;
    x86_64)
        DMG_NAME="TypstEdit_Intel.dmg"
        ;;
    *)
        echo "Usage: $0 [arm64|x86_64]  (default: arm64)"
        exit 1
        ;;
esac

echo "📦 Preparing to package $APP_NAME ($ARCH)..."

# Ensure bundle exists and is fresh
./bundle.sh release "$ARCH"

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
