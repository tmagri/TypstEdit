#!/bin/bash
set -e

APP_NAME="TypstEdit"
BUILD_DIR=".build/debug"
EXECUTABLE="$BUILD_DIR/$APP_NAME"
APP_BUNDLE="$APP_NAME.app"

echo "Building..."
swift build

echo "Creating App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Typst executable into the bundle
echo "Bundling Typst executable..."
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
if [ -f "typst-aarch64-apple-darwin/typst" ]; then
    cp "typst-aarch64-apple-darwin/typst" "$APP_BUNDLE/Contents/Resources/bin/typst"
    chmod +x "$APP_BUNDLE/Contents/Resources/bin/typst"
    echo "✓ Typst executable bundled"
else
    echo "⚠️  Warning: Typst executable not found. App will require system Typst installation."
fi


# Icon Handling
# Priority: Use existing AppIcon.icns if available, otherwise generate from icon.png
if [ -f "AppIcon.icns" ]; then
    echo "Using custom AppIcon.icns..."
    cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
elif [ -f "icon.png" ]; then
    echo "Generating App Icon from icon.png..."
    ICONSET="AppIcon.iconset"
    mkdir -p "$ICONSET"
    
    # Ensure source is PNG
    sips -s format png "icon.png" --out "icon_source.png" > /dev/null
    
    # Generate sizes
    sips -z 16 16     "icon_source.png" --out "$ICONSET/icon_16x16.png" > /dev/null
    sips -z 32 32     "icon_source.png" --out "$ICONSET/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     "icon_source.png" --out "$ICONSET/icon_32x32.png" > /dev/null
    sips -z 64 64     "icon_source.png" --out "$ICONSET/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   "icon_source.png" --out "$ICONSET/icon_128x128.png" > /dev/null
    sips -z 256 256   "icon_source.png" --out "$ICONSET/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "icon_source.png" --out "$ICONSET/icon_256x256.png" > /dev/null
    sips -z 512 512   "icon_source.png" --out "$ICONSET/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "icon_source.png" --out "$ICONSET/icon_512x512.png" > /dev/null
    sips -z 1024 1024 "icon_source.png" --out "$ICONSET/icon_512x512@2x.png" > /dev/null
    
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
    rm -f "icon_source.png"
fi

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! App is located at $APP_BUNDLE"

