#!/bin/bash
set -e

APP_NAME="TypstEdit"
APP_BUNDLE="$APP_NAME.app"
DMG_NAME="$APP_NAME-Installer.dmg"
VOLUME_NAME="$APP_NAME Installer"
TEMP_DMG="temp.dmg"

# Check if app bundle exists
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Error: $APP_BUNDLE not found. Run ./bundle.sh first."
    exit 1
fi

echo "Creating DMG installer for $APP_NAME..."

# Clean up any existing DMG
rm -f "$DMG_NAME" "$TEMP_DMG"

# Create a temporary directory for DMG contents
DMG_DIR="dmg_contents"
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"

# Copy the app bundle
echo "Copying $APP_BUNDLE to DMG staging area..."
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create a symbolic link to /Applications
echo "Creating Applications symlink..."
ln -s /Applications "$DMG_DIR/Applications"

# Calculate size needed (in MB, with some padding)
SIZE=$(du -sm "$DMG_DIR" | awk '{print $1}')
SIZE=$((SIZE + 50))

echo "Creating temporary DMG (${SIZE}MB)..."
hdiutil create -srcfolder "$DMG_DIR" -volname "$VOLUME_NAME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size ${SIZE}m "$TEMP_DMG"

# Mount the temporary DMG
echo "Mounting temporary DMG..."
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | \
    egrep '^/dev/' | sed 1q | awk '{print $3}')

echo "Mounted at: $MOUNT_DIR"

# Set custom icon position and view options (optional)
echo "Configuring DMG appearance..."
echo '
   tell application "Finder"
     tell disk "'$VOLUME_NAME'"
           open
           set current view of container window to icon view
           set toolbar visible of container window to false
           set statusbar visible of container window to false
           set the bounds of container window to {400, 100, 900, 450}
           set viewOptions to the icon view options of container window
           set arrangement of viewOptions to not arranged
           set icon size of viewOptions to 72
           set position of item "'$APP_NAME'.app" of container window to {125, 175}
           set position of item "Applications" of container window to {375, 175}
           close
           open
           update without registering applications
           delay 2
     end tell
   end tell
' | osascript || echo "Warning: Could not set DMG appearance"

# Unmount the temporary DMG
echo "Unmounting temporary DMG..."
hdiutil detach "$MOUNT_DIR"

# Convert to compressed, read-only DMG
echo "Compressing final DMG..."
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_NAME"

# Clean up
rm -f "$TEMP_DMG"
rm -rf "$DMG_DIR"

echo "✓ Installer created: $DMG_NAME"
echo "You can now distribute this DMG file to users."
