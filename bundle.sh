#!/bin/bash
set -e

APP_NAME="TypstEdit"

CONFIG=${1:-release}
ARCH="arm64"

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
swift build -c "$CONFIG" --arch "$ARCH"

# Find the executable specifically in the requested configuration folder.
# SwiftPM's output location depends on the build system in use: the classic
# llbuild layout is .build/$ARCH-apple-macosx/$CONFIG/, while the newer
# swift-build layout writes .build/out/Products/{Debug,Release}/. Prefer the
# NEWEST candidate so a stale binary left behind by the other layout can
# never get packaged (this once shipped an old app that was missing freshly
# added features even though `swift build` had compiled them).
case "$CONFIG" in
    release) EXEC_CONFIG="Release" ;;
    debug)   EXEC_CONFIG="Debug" ;;
    *)       EXEC_CONFIG="$CONFIG" ;;
esac

CANDIDATES=(
    ".build/out/Products/$EXEC_CONFIG/$APP_NAME"
    ".build/out/$ARCH-apple-macosx/$CONFIG/$APP_NAME"
    ".build/$ARCH-apple-macosx/$CONFIG/$APP_NAME"
)

EXECUTABLE=""
EXEC_TIME=0
for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ]; then
        mtime=$(stat -f "%m" "$candidate")
        if [ "$mtime" -gt "$EXEC_TIME" ]; then
            EXEC_TIME="$mtime"
            EXECUTABLE="$candidate"
        fi
    fi
done

if [ -z "$EXECUTABLE" ]; then
    echo "Error: Executable $APP_NAME not found for configuration $CONFIG (searched: ${CANDIDATES[*]})"
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

# Copy all SPM resource bundles — check both layout locations (new swift-build out dir and classic llbuild dir)
echo "Copying resources bundle..."
BUNDLE_FOUND=0
for BUNDLE_DIR in ".build/out/Products/$EXEC_CONFIG" ".build/out/$ARCH-apple-macosx/$CONFIG" ".build/$ARCH-apple-macosx/$CONFIG"; do
    if [ -d "$BUNDLE_DIR" ]; then
        find "$BUNDLE_DIR" -maxdepth 1 -type d -name "*.bundle" | while read bundle; do
            echo "  Copying: $(basename "$bundle")"
            cp -r "$bundle" "$APP_BUNDLE/Contents/Resources/"
            BUNDLE_FOUND=1
        done
        # If we found bundles in this location, don't keep searching to avoid duplicates
        if [ "$BUNDLE_FOUND" -eq 1 ] || [ -n "$(find "$BUNDLE_DIR" -maxdepth 1 -type d -name "*.bundle" 2>/dev/null)" ]; then
            break
        fi
    fi
done

# Copy vector.framework into Contents/MacOS/ so @loader_path rpath finds it at launch
echo "Copying vector.framework..."
VECTOR_XCFW=".build/artifacts/sqlite-vector/vectorBinary/vector.xcframework/macos-arm64_x86_64"
if [ -d "$VECTOR_XCFW/vector.framework" ]; then
    cp -r "$VECTOR_XCFW/vector.framework" "$APP_BUNDLE/Contents/MacOS/"
    echo "  Copied: vector.framework"
elif [ -d ".build/arm64-apple-macosx/$CONFIG/vector.framework" ]; then
    cp -r ".build/arm64-apple-macosx/$CONFIG/vector.framework" "$APP_BUNDLE/Contents/MacOS/"
    echo "  Copied: vector.framework (from build)"
fi

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