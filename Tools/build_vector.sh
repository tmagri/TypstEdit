#!/bin/bash
# Rebuild the pinned SQLite vector extension for the app's deployment target.
# The upstream XCFramework advertises macOS 11 but its binary requires 15.
set -euo pipefail
if [[ $# -lt 4 ]]; then
    echo "Usage: $0 SOURCE_CHECKOUT FRAMEWORK_TEMPLATE OUTPUT_FRAMEWORK ARCH [ARCH...]" >&2
    exit 1
fi
SOURCE="$(cd "$1" && pwd)"
TEMPLATE="$(cd "$2" && pwd)"
OUTPUT="$3"
shift 3
TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
ARCH_FLAGS=()
for arch in "$@"; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
    ARCH_FLAGS+=("-arch" "$arch")
done
if [[ ! -f "$SOURCE/src/sqlite-vector.c" || ! -f "$TEMPLATE/Versions/A/vector" ]]; then
    echo "Missing pinned vector source or macOS framework template." >&2
    exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
ditto "$TEMPLATE" "$OUTPUT"
BINARY="$OUTPUT/Versions/A/vector"
# This is a new bundle copy; the old vendor signature no longer describes it.
rm -rf "$OUTPUT/Versions/A/_CodeSignature" "$OUTPUT/_CodeSignature"
xcrun --sdk macosx clang -std=c11 -O3 -fPIC \
    "${ARCH_FLAGS[@]}" -mmacosx-version-min="$TARGET" \
    -I"$SOURCE/src" -I"$SOURCE/libs" "$SOURCE"/src/*.c \
    -dynamiclib -undefined dynamic_lookup -Wl,-headerpad_max_install_names \
    -Wl,-install_name,@rpath/vector.framework/vector -o "$BINARY.new"
mv "$BINARY.new" "$BINARY"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion $TARGET" "$OUTPUT/Versions/A/Resources/Info.plist"
for arch in "$@"; do
    lipo -verify_arch "$arch" "$BINARY"
done
echo "Built vector.framework from the pinned source for macOS $TARGET ($*)."
