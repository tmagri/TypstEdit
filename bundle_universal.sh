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

# Create Info.plist — kept in sync with bundle.sh (folder usage descriptions are
# REQUIRED for macOS TCC to grant folder-level access instead of per-file prompts).
cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.tmagri.$APP_NAME</string>
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
    <key>NSDesktopFolderUsageDescription</key>
    <string>TypstEdit needs access to your Desktop to open and save documents stored there.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>TypstEdit needs access to your Documents folder to open and save documents stored there.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>TypstEdit needs access to your Downloads folder to open documents stored there.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Typst Source</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>typ</string>
            </array>
            <key>CFBundleTypeIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.typst.typst-source</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Markdown Document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>net.daringfireball.markdown</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>md</string>
                <string>markdown</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>org.typst.typst-source</string>
            <key>UTTypeDescription</key>
            <string>Typst Source</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.source-code</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>typ</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>net.daringfireball.markdown</string>
            <key>UTTypeDescription</key>
            <string>Markdown Document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>md</string>
                    <string>markdown</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

# Code-sign the fully assembled bundle so macOS TCC binds the Info.plist
# (incl. folder usage descriptions) to a stable identity and seals resources.
# Without this, the linker-only signature leaves Info.plist unbound and TCC
# falls back to per-file prompts for every file the app — or its `typst`
# subprocess — touches.
#
# Sign inside-out (NOT --deep): vector.framework lives in MacOS/ which makes
# --deep emit "bundle format is ambiguous" and fail to bind Info.plist.
# Signing nested components first, then the outer bundle, binds the Info.plist
# and seals resources correctly. The nested typst binary shares the app's
# identity so its file reads are attributed to TypstEdit instead of re-prompting.
echo "Code-signing app bundle (ad-hoc, inside-out)..."
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/vector.framework" || true
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/bin/typst" || true
codesign --force --sign - "$APP_BUNDLE"

echo "Refreshing macOS Launch Services cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"

echo "Done! Universal binary app is located at $APP_BUNDLE"
