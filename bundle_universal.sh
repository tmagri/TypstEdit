#!/bin/bash
set -e

APP_NAME="TypstEdit"
BUILD_DIR=".build"
APP_BUNDLE="$APP_NAME.app"

if [ -f "VERSION" ]; then
    VERSION=$(cat VERSION)
else
    VERSION="1.0.0"
fi

echo "Building Universal Binary (ARM64 + x86_64)..."

# Build for ARM64 (Apple Silicon)
echo "Building for ARM64..."
swift build -c release --arch arm64

# Build for x86_64 (Intel)
echo "Building for x86_64..."
swift build -c release --arch x86_64

# Create universal binary
echo "Creating universal binary..."
lipo -create \
    "$BUILD_DIR/arm64-apple-macosx/release/$APP_NAME" \
    "$BUILD_DIR/x86_64-apple-macosx/release/$APP_NAME" \
    -output "$BUILD_DIR/$APP_NAME-universal"

echo "Creating App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME-universal" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Strip debug symbols from the release binary to reduce size
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy all SPM resource bundles — use maxdepth 1 to avoid duplicates from nested build dirs
echo "Copying SPM resource bundles..."
find "$BUILD_DIR/arm64-apple-macosx/release" -maxdepth 1 -type d -name "*.bundle" | while read bundle; do
    echo "  Copying: $(basename "$bundle")"
    cp -r "$bundle" "$APP_BUNDLE/Contents/Resources/"
done

# Copy vector.framework into Contents/MacOS/ so @loader_path rpath finds it at launch
# Use the pre-built universal macOS slice from the XCFramework artifact
echo "Copying vector.framework..."
VECTOR_XCFW_MACOS="$BUILD_DIR/artifacts/sqlite-vector/vectorBinary/vector.xcframework/macos-arm64_x86_64"
if [ -d "$VECTOR_XCFW_MACOS/vector.framework" ]; then
    cp -r "$VECTOR_XCFW_MACOS/vector.framework" "$APP_BUNDLE/Contents/MacOS/"
    echo "  Copied: vector.framework (universal)"
fi

# Copy Typst executable into the bundle
echo "Bundling Universal Typst executable..."
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
if [ -f "typst-universal" ]; then
    cp "typst-universal" "$APP_BUNDLE/Contents/Resources/bin/typst"
    chmod +x "$APP_BUNDLE/Contents/Resources/bin/typst"
    echo "✓ Universal Typst executable bundled"
else
    echo "⚠️  Error: 'typst-universal' not found. Run lipo creation first."
    exit 1
fi

# Icon Handling
if [ -f "AppIcon.icns" ]; then
    echo "Using custom AppIcon.icns..."
    cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
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
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

echo "Done! Universal binary app is located at $APP_BUNDLE"
