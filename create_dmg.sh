#!/bin/bash
set -e

APP_NAME="TypstEdit"
DMG_NAME="TypstEdit_Installer.dmg"
APP_BUNDLE="TypstEdit.app"

echo "📦 Preparing to package $APP_NAME..."

# Ensure bundle exists and is fresh
./bundle.sh

# Create temporary folder for DMG content
echo "📂 Setting up DMG structure..."
rm -rf dist
mkdir -p dist
cp -r "$APP_BUNDLE" dist/
ln -s /Applications dist/Applications

# Create DMG
echo "💿 Creating DMG..."
rm -f "$DMG_NAME"
hdiutil create -volname "$APP_NAME" -srcfolder dist -ov -format UDZO "$DMG_NAME"

# Clean up
rm -rf dist

echo "✅ DMG created successfully: $DMG_NAME"
