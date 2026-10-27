#!/bin/bash
set -eo pipefail

APP_NAME="TypstEdit"
APP_BUNDLE="TypstEdit.app"
# universal = one app that runs on Apple Silicon and Intel (recommended).
ARCH=${1:-universal}

case "$ARCH" in
    universal)
        DMG_NAME="TypstEdit_Universal.dmg"
        ;;
    arm64)
        DMG_NAME="TypstEdit_AppleSilicon.dmg"
        ;;
    x86_64)
        DMG_NAME="TypstEdit_Intel.dmg"
        ;;
    *)
        echo "Usage: $0 [universal|arm64|x86_64]  (default: universal)"
        exit 1
        ;;
esac

echo "📦 Preparing to package $APP_NAME ($ARCH)..."

# Both bundle scripts verify the result and fail if it can't launch on
# another Mac (missing Swift runtime, wrong architecture, macOS floor).
if [ "$ARCH" = "universal" ]; then
    ./bundle_universal.sh
else
    ./bundle.sh release "$ARCH"
fi

echo "📂 Setting up DMG structure..."
rm -rf dist
mkdir -p dist
ditto "$APP_BUNDLE" "dist/$APP_BUNDLE"
ln -s /Applications dist/Applications
cp THIRD_PARTY_NOTICES.md dist/

echo "💿 Creating DMG ($DMG_NAME)..."
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder dist -ov -format UDZO "$DMG_NAME"

rm -rf dist

echo "✅ DMG created successfully: $DMG_NAME"
echo "   Ad-hoc signed (not notarized): on another Mac, open it with"
echo "   right-click → Open, or run: xattr -dr com.apple.quarantine /Applications/$APP_BUNDLE"
