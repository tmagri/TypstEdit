#!/bin/bash
set -e

APP_NAME="TypstEdit"

CONFIG=${1:-release}
ARCH=${2:-arm64}

case "$ARCH" in
    arm64|x86_64) ;;
    *)
        echo "Usage: $0 [debug|release] [arm64|x86_64]"
        exit 1
        ;;
esac

SCRATCH_PATH=".build/arch-build/$ARCH"

if [ -f "VERSION" ]; then
    VERSION=$(cat VERSION)
else
    VERSION="1.0.0"
fi

echo "Building version $VERSION ($ARCH-only) with configuration: $CONFIG..."
# SwiftLint's build plugin loads sourcekitdInProc.framework from the local Xcode
# toolchain. That framework is not portable across machines and is not a Git
# dependency, so disable the plugin by default for project builds.
export DISABLE_SWIFTLINT=1

# Ensure DEVELOPER_DIR points to Xcode if available, avoiding missing SwiftUI macros
# (like SwiftUIMacros and PreviewsMacros) when xcode-select points to Command Line Tools.
if [ -z "$DEVELOPER_DIR" ]; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif XCODE_DEV_DIR=$(xcode-select -p 2>/dev/null); then
        if [[ "$XCODE_DEV_DIR" == *"CommandLineTools"* ]]; then
            CANDIDATE=$(mdfind 'kMDItemCFBundleIdentifier == "com.apple.dt.Xcode"' 2>/dev/null | head -n 1)
            if [ -n "$CANDIDATE" ] && [ -d "$CANDIDATE/Contents/Developer" ]; then
                export DEVELOPER_DIR="$CANDIDATE/Contents/Developer"
            fi
        fi
    fi
fi
swift build --scratch-path "$SCRATCH_PATH" -c "$CONFIG" --arch "$ARCH"

BIN_DIR=$(swift build --show-bin-path --scratch-path "$SCRATCH_PATH" -c "$CONFIG" --arch "$ARCH")
EXECUTABLE="$BIN_DIR/$APP_NAME"
if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable $APP_NAME not found at $EXECUTABLE"
    exit 1
fi

echo "Found executable: $EXECUTABLE"
APP_BUNDLE="$APP_NAME.app"

echo "Creating App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Strip debug symbols from the binary to reduce size
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy all SwiftPM resource bundles from this architecture's build.
echo "Copying resources bundle..."
find "$BIN_DIR" -maxdepth 1 -type d -name "*.bundle" -exec cp -R {} "$APP_BUNDLE/Contents/Resources/" \;

# Copy vector.framework into Contents/MacOS/ so @loader_path rpath finds it at launch
echo "Copying vector.framework..."
VECTOR_FRAMEWORK=""
for VECTOR_ROOT in "$SCRATCH_PATH/artifacts" ".build/artifacts"; do
    CANDIDATE="$VECTOR_ROOT/sqlite-vector/vectorBinary/vector.xcframework/macos-arm64_x86_64/vector.framework"
    if [ -d "$CANDIDATE" ]; then
        VECTOR_FRAMEWORK="$CANDIDATE"
        break
    fi
done

if [ -z "$VECTOR_FRAMEWORK" ]; then
    echo "Error: vector.framework not found in this architecture's SwiftPM artifacts."
    exit 1
fi

cp -R "$VECTOR_FRAMEWORK" "$APP_BUNDLE/Contents/MacOS/"
VECTOR_BINARY="$APP_BUNDLE/Contents/MacOS/vector.framework/Versions/A/vector"
if [ ! -f "$VECTOR_BINARY" ] || ! lipo -verify_arch "$ARCH" "$VECTOR_BINARY" >/dev/null 2>&1; then
    echo "Error: vector.framework does not contain the required $ARCH architecture."
    exit 1
fi

VECTOR_ARCHS=$(lipo -archs "$VECTOR_BINARY")
if [ "$VECTOR_ARCHS" != "$ARCH" ]; then
    lipo "$VECTOR_BINARY" -thin "$ARCH" -output "$VECTOR_BINARY.thin"
    mv "$VECTOR_BINARY.thin" "$VECTOR_BINARY"
fi
echo "  Copied and thinned vector.framework to $ARCH."

# Copy Typst executable into the bundle
echo "Bundling Typst executable..."
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
case "$ARCH" in
    arm64) TYPST_BINARY="typst-aarch64-apple-darwin/typst" ;;
    x86_64) TYPST_BINARY="typst-x86_64-apple-darwin/typst" ;;
esac
if [ -f "$TYPST_BINARY" ]; then
    cp "$TYPST_BINARY" "$APP_BUNDLE/Contents/Resources/bin/typst"
    chmod +x "$APP_BUNDLE/Contents/Resources/bin/typst"
    echo "✓ Typst executable bundled"
else
    echo "⚠️  Warning: Typst executable not found. App will require system Typst installation."
fi

# Copy the CAS helper (Calculator mode) into the bundle. Built by
# Tools/cas/build_cas.sh into build/cas/typstedit-cas.
echo "Bundling CAS helper..."
if [ -f "build/cas/typstedit-cas" ]; then
    cp "build/cas/typstedit-cas" "$APP_BUNDLE/Contents/Resources/bin/typstedit-cas"
    chmod +x "$APP_BUNDLE/Contents/Resources/bin/typstedit-cas"
    codesign --force --sign - "$APP_BUNDLE/Contents/Resources/bin/typstedit-cas" 2>/dev/null || true
    echo "✓ CAS helper bundled"
else
    echo "⚠️  Warning: build/cas/typstedit-cas not found — Calculator mode will be unavailable. Run Tools/cas/build_cas.sh."
fi


# Icon Handling
# Priority: compile the Icon Composer asset (AppIcon.icon) with actool, which
# produces an adaptive Assets.car (black Dock icon in Dark mode, like
# FaceTime/Phone/Reminders, blue in Light mode) plus a legacy AppIcon.icns
# fallback for older macOS. Falls back to a static AppIcon.icns, then
# icon.png, if actool/Xcode isn't available (e.g. Command Line Tools only).
ACTOOL_PARTIAL_PLIST="$APP_BUNDLE/Contents/Resources/.actool-partial.plist"
if [ -d "AppIcon.icon" ] && xcrun --find actool >/dev/null 2>&1; then
    echo "Compiling AppIcon.icon (Icon Composer) with actool..."
    if xcrun actool \
        --compile "$APP_BUNDLE/Contents/Resources" \
        --platform macosx \
        --minimum-deployment-target 13.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ACTOOL_PARTIAL_PLIST" \
        --enable-icon-stack-fallback-generation=disabled \
        "AppIcon.icon" > /tmp/typstedit-actool.log 2>&1; then
        echo "✓ Compiled Assets.car + AppIcon.icns from AppIcon.icon"
    else
        echo "⚠️  actool failed to compile AppIcon.icon (see /tmp/typstedit-actool.log); falling back to static icon."
        cat /tmp/typstedit-actool.log
        if [ -f "AppIcon.icns" ]; then
            cp "AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        fi
    fi
    rm -f "$ACTOOL_PARTIAL_PLIST"
elif [ -f "AppIcon.icns" ]; then
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
    <string>com.tmagri.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
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

echo "Done! App is located at $APP_BUNDLE"

# Code-sign the fully assembled bundle so macOS TCC binds the Info.plist
# (incl. folder usage descriptions) to a stable identity and seals resources.
# See bundle_universal.sh for the full rationale. Sign inside-out (NOT --deep):
# vector.framework in MacOS/ makes --deep fail to bind Info.plist.
echo "Code-signing app bundle (ad-hoc, inside-out)..."
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/vector.framework" || true
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/bin/typst" || true
codesign --force --sign - "$APP_BUNDLE"

echo "Refreshing macOS Launch Services cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"