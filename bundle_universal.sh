#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
export MACOSX_DEPLOYMENT_TARGET=13.0
APP_NAME="TypstEdit"
BUILD_DIR=".build"
FINAL_APP_BUNDLE="$APP_NAME.app"
# Assemble and verify separately. A failed build must not destroy the
# currently working app.
APP_BUNDLE="build/bundles/$APP_NAME-universal.app"

if [ -f "VERSION" ]; then
    VERSION=$(cat VERSION)
else
    VERSION="1.0.0"
fi

echo "Building Universal Binary (ARM64 + x86_64)..."
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

# Build each architecture into its OWN scratch directory — a shared scratch
# makes both builds write the same Products/Release/TypstEdit, so the second
# overwrites the first and lipo would see one file twice.
# Build for ARM64 (Apple Silicon)
echo "Building for ARM64..."
swift build -c release --arch arm64 --scratch-path "$BUILD_DIR/arch-build/arm64"
ARM_BIN_DIR="$(swift build -c release --arch arm64 --scratch-path "$BUILD_DIR/arch-build/arm64" --show-bin-path)"
ARM_BIN="$ARM_BIN_DIR/$APP_NAME"

# --show-bin-path only reports a path; it does not perform a build.
echo "Building for x86_64..."
swift build -c release --arch x86_64 --scratch-path "$BUILD_DIR/arch-build/x86_64"
X86_BIN_DIR="$(swift build -c release --arch x86_64 --scratch-path "$BUILD_DIR/arch-build/x86_64" --show-bin-path)"
X86_BIN="$X86_BIN_DIR/$APP_NAME"

echo "Creating universal binary..."
for BIN in "$ARM_BIN" "$X86_BIN"; do
    if [ ! -f "$BIN" ]; then
        echo "Error: built executable not found at $BIN"
        exit 1
    fi
done
lipo -create "$ARM_BIN" "$X86_BIN" -output "$BUILD_DIR/$APP_NAME-universal"

echo "Creating App Bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp "$BUILD_DIR/$APP_NAME-universal" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Strip debug symbols from the release binary to reduce size
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Use this build's actual output, never stale global .build/out bundles.
echo "Copying SPM resource bundles..."
for NAME in TypstEdit_TypstEdit.bundle CodeEditLanguages_CodeEditLanguages.bundle; do
    if [ ! -d "$ARM_BIN_DIR/$NAME" ] || [ ! -d "$X86_BIN_DIR/$NAME" ]; then
        echo "Error: missing resource bundle $NAME in an architecture build."
        exit 1
    fi
done
while IFS= read -r BUNDLE; do
    ditto "$BUNDLE" "$APP_BUNDLE/Contents/Resources/$(basename "$BUNDLE")"
done < <(find "$ARM_BIN_DIR" -maxdepth 1 -type d -name '*.bundle')

# Recompile the pinned vector source at macOS 13. The vendor binary's load
# command requires macOS 15, despite its package advertising an older floor.
VECTOR_SOURCE="$BUILD_DIR/arch-build/arm64/checkouts/sqlite-vector"
VECTOR_TEMPLATE="$BUILD_DIR/arch-build/arm64/artifacts/sqlite-vector/vectorBinary/vector.xcframework/macos-arm64_x86_64/vector.framework"
bash "$SCRIPT_DIR/Tools/build_vector.sh" "$VECTOR_SOURCE" "$VECTOR_TEMPLATE" \
    "$APP_BUNDLE/Contents/Frameworks/vector.framework" arm64 x86_64

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

# The CAS builder validates its deployment-target cache and only rebuilds
# libraries when necessary. An architecture-only check misses host-target
# static objects hidden inside the helper.
echo "Building/bundling Universal CAS helper..."
CAS_HELPER="build/cas/typstedit-cas"
bash "$SCRIPT_DIR/Tools/cas/build_cas.sh" --arch universal
if [ ! -x "$CAS_HELPER" ] \
    || ! lipo -verify_arch arm64 "$CAS_HELPER" >/dev/null 2>&1 \
    || ! lipo -verify_arch x86_64 "$CAS_HELPER" >/dev/null 2>&1; then
    echo "Error: CAS helper was not built for both arm64 and x86_64."
    exit 1
fi
cp "$CAS_HELPER" "$APP_BUNDLE/Contents/Resources/bin/typstedit-cas"
chmod +x "$APP_BUNDLE/Contents/Resources/bin/typstedit-cas"

# Calculator WASM core: the numeric library Typst documents call (BesselJ,
# calc-call, plot…). Architecture-independent; one build serves both slices.
CALC_WASM="build/calc/TypstEditCalc.wasm"
bash "$SCRIPT_DIR/Tools/calc-plugin/build_calc_plugin.sh"
if [ ! -f "$CALC_WASM" ]; then
    echo "Error: $CALC_WASM was not built (needs: brew install lld)." >&2
    exit 1
fi
cp "$CALC_WASM" "$APP_BUNDLE/Contents/Resources/bin/TypstEditCalc.wasm"
echo "✓ Universal CAS helper bundled"

# Icon Handling
# Priority: compile the Icon Composer asset (AppIcon.icon) with actool, which
# produces an adaptive Assets.car (black Dock icon in Dark mode, like
# FaceTime/Phone/Reminders, blue in Light mode) plus a legacy AppIcon.icns
# fallback for older macOS. Falls back to a static AppIcon.icns if
# actool/Xcode isn't available (e.g. Command Line Tools only).
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

# Licences for redistributed components.
mkdir -p "$APP_BUNDLE/Contents/Resources/Licenses"
cp THIRD_PARTY_NOTICES.md "$APP_BUNDLE/Contents/Resources/Licenses/"
for f in typst-aarch64-apple-darwin/LICENSE typst-aarch64-apple-darwin/NOTICE; do
    [ -f "$f" ] && cp "$f" "$APP_BUNDLE/Contents/Resources/Licenses/typst-$(basename "$f")"
done

# Bundle the Swift compatibility runtime (libswiftCompatibilitySpan.dylib).
# The app links it with an rpath into this Mac's Xcode, so on any other Mac
# it fails to launch with "Library not loaded". This copies it into
# Contents/Frameworks, adds @executable_path/../Frameworks, and removes the
# absolute Xcode rpath.
bash "$SCRIPT_DIR/Tools/packaging/prepare_bundle.sh" "$APP_BUNDLE" arm64 x86_64

# Sign inside-out (NOT --deep), so the Info.plist (incl. folder usage
# descriptions) is bound and TCC grants folder access instead of prompting
# per file. Nested code first, then the outer bundle.
echo "Code-signing app bundle (ad-hoc, inside-out)..."
for dylib in "$APP_BUNDLE"/Contents/Frameworks/*.dylib; do
    [ -f "$dylib" ] && codesign --force --sign - "$dylib"
done
codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/vector.framework"
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/bin/typst"
codesign --force --sign - "$APP_BUNDLE/Contents/Resources/bin/typstedit-cas"
codesign --force --sign - "$APP_BUNDLE"
codesign --verify --strict "$APP_BUNDLE"

# Fail the build rather than ship a bundle that can't launch elsewhere.
bash "$SCRIPT_DIR/Tools/packaging/verify_bundle.sh" "$APP_BUNDLE" arm64 x86_64

# Only now replace the working app.
rm -rf "$FINAL_APP_BUNDLE"
ditto "$APP_BUNDLE" "$FINAL_APP_BUNDLE"

echo "Refreshing macOS Launch Services cache..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$FINAL_APP_BUNDLE"

echo "Done! Universal app is located at $FINAL_APP_BUNDLE"
