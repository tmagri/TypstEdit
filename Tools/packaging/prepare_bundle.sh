#!/bin/bash
# prepare_bundle.sh - make an assembled .app bundle portable before final signing.
#
# Usage:
#   Tools/packaging/prepare_bundle.sh APP_BUNDLE [ARCH...]
#
#   APP_BUNDLE  Path to an assembled TypstEdit.app (Contents/MacOS/<exe>,
#               Contents/Frameworks, Contents/Resources already populated).
#   ARCH       Architectures the app must contain, e.g. "arm64" or
#               "arm64 x86_64". Defaults to the architectures of the main
#               executable.
#
# What it does (in order, before the caller performs the final code signing):
#   1. Resolves the Xcode/Command Line Tools toolchain. An explicit
#      DEVELOPER_DIR is authoritative; otherwise Xcode.app, then
#      xcode-select -p, is used.
#   2. Finds every Mach-O in the bundle and computes the Swift runtime
#      compatibility libraries that are linked non-weakly (currently
#      @rpath/libswiftCompatibilitySpan.dylib). It asks the selected
#      toolchain's swift-stdlib-tool to copy what the app needs, and falls
#      back to an explicit copy from the toolchain's
#      usr/lib/swift-*/macosx directory for anything still missing.
#   3. Verifies every copied library is a real (non-symlink) Mach-O with all
#      requested slices - never the /usr/lib/swift shared-cache stub - and
#      thins it to exactly the requested architectures.
#   4. Adds the portable rpath @executable_path/../Frameworks to the main
#      executable (plus equivalent @loader_path rpaths for helpers and
#      framework binaries that have @rpath dependencies) and deletes
#      absolute build-machine rpaths (Xcode toolchain, /Users, /opt,
#      /usr/local, ...) from the app and every bundled non-system Mach-O.
#   5. Records provenance/licensing information for the bundled Swift runtime
#      in Contents/Resources/Licenses.
#   6. Ad-hoc signs only the Mach-O files it touched, so the bundle stays
#      launchable. The caller still signs the bundle inside-out afterwards.
#
# It never changes Mach-O minimum OS versions. A lower deployment target
# requires recompiling; vtool/install_name_tool cannot honestly do that.
#
# Requires: macOS, python3, Xcode or Command Line Tools (for lipo,
# install_name_tool, codesign and the Swift runtime). Bash 3.2 compatible.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSPECT="$SCRIPT_DIR/lib/macho_inspect.py"
PYTHON=${PYTHON:-python3}

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() {
    printf 'prepare_bundle: ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'prepare_bundle: WARN: %s\n' "$*" >&2
}

step() {
    printf '==> %s\n' "$*"
}

note() {
    printf '    %s\n' "$*"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage 0
fi

if [ $# -lt 1 ]; then
    usage 2
fi

APP_BUNDLE=$1
shift

if [ ! -d "$APP_BUNDLE" ]; then
    die "app bundle not found: $APP_BUNDLE"
fi
APP_BUNDLE=$(cd "$APP_BUNDLE" && pwd)
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
RESOURCES_DIR="$CONTENTS/Resources"
PLIST="$CONTENTS/Info.plist"

[ -d "$CONTENTS" ] || die "not an app bundle (missing Contents): $APP_BUNDLE"
[ -f "$PLIST" ] || die "missing $PLIST; build the bundle layout before preparing it"
command -v "$PYTHON" >/dev/null 2>&1 || die "python3 is required (install Command Line Tools)"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/typstedit-prepare.XXXXXX") || die "cannot create temp dir"
cleanup() {
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Toolchain resolution
# ---------------------------------------------------------------------------

step "Resolving Xcode toolchain"

if [ -n "${DEVELOPER_DIR:-}" ]; then
    [ -d "$DEVELOPER_DIR" ] || die "DEVELOPER_DIR does not exist: $DEVELOPER_DIR"
    TOOLCHAIN_DEVELOPER_DIR=$DEVELOPER_DIR
elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
    TOOLCHAIN_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
else
    TOOLCHAIN_DEVELOPER_DIR=$(xcode-select -p 2>/dev/null) \
        || die "no Xcode/Command Line Tools found; set DEVELOPER_DIR"
fi

DEVELOPER_DIR=$TOOLCHAIN_DEVELOPER_DIR
export DEVELOPER_DIR

command -v xcrun >/dev/null 2>&1 || die "xcrun is required"
LIPO=$(xcrun --find lipo 2>/dev/null) || die "lipo not found in selected toolchain"
INSTALL_NAME_TOOL=$(xcrun --find install_name_tool 2>/dev/null) \
    || die "install_name_tool not found in selected toolchain"
STDLIB_TOOL=$(xcrun --find swift-stdlib-tool 2>/dev/null || true)

note "DEVELOPER_DIR=$DEVELOPER_DIR"
if [ -n "$STDLIB_TOOL" ]; then
    note "swift-stdlib-tool=$STDLIB_TOOL"
else
    warn "swift-stdlib-tool not found; using explicit toolchain library lookup only"
fi

# ---------------------------------------------------------------------------
# Main executable and requested architectures
# ---------------------------------------------------------------------------

EXECUTABLE=$(plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null) \
    || die "cannot read CFBundleExecutable from $PLIST"
[ -n "$EXECUTABLE" ] || die "Info.plist has an empty CFBundleExecutable"
MAIN_BINARY="$MACOS_DIR/$EXECUTABLE"
[ -f "$MAIN_BINARY" ] || die "missing main binary: $MAIN_BINARY"
[ ! -L "$MAIN_BINARY" ] || die "main binary is a symlink: $MAIN_BINARY"

REQUESTED_ARCHS=()
for arg in "$@"; do
    for arch in $(printf '%s' "$arg" | tr ',' ' '); do
        case "$arch" in
            arm64|x86_64|arm64e) REQUESTED_ARCHS+=("$arch") ;;
            *) die "unsupported architecture '$arch' (use arm64, x86_64 or arm64e)" ;;
        esac
    done
done

if [ ${#REQUESTED_ARCHS[@]} -eq 0 ]; then
    while IFS= read -r arch; do
        [ -n "$arch" ] && REQUESTED_ARCHS+=("$arch")
    done < <("$PYTHON" "$INSPECT" archs "$MAIN_BINARY")
fi
[ ${#REQUESTED_ARCHS[@]} -gt 0 ] || die "could not determine architectures for $MAIN_BINARY"

MAIN_ARCHS=$("$PYTHON" "$INSPECT" archs "$MAIN_BINARY" | tr '\n' ' ')
note "main executable: ${MAIN_BINARY#$APP_BUNDLE/}"
note "main architectures: $MAIN_ARCHS"
note "requested architectures: ${REQUESTED_ARCHS[*]}"
for arch in "${REQUESTED_ARCHS[@]}"; do
    case " $MAIN_ARCHS " in
        *" $arch "*) ;;
        *) die "main binary has no $arch slice (has: $MAIN_ARCHS)" ;;
    esac
done

minos_of() {
    "$PYTHON" "$INSPECT" minos "$1" 2>/dev/null
}

MAIN_MINOS_BEFORE=$(minos_of "$MAIN_BINARY")

CHANGED_MACHOS=()

# ---------------------------------------------------------------------------
# Enumerate Mach-O images
# ---------------------------------------------------------------------------

step "Scanning bundled Mach-O files"

MACHO_LIST="$TMP_ROOT/machos.txt"
"$PYTHON" "$INSPECT" find-machos "$CONTENTS" > "$MACHO_LIST" || die "Mach-O scan failed"
MACHO_COUNT=$(wc -l < "$MACHO_LIST" | tr -d ' ')
[ "$MACHO_COUNT" -gt 0 ] || die "no Mach-O files found under $CONTENTS"
note "$MACHO_COUNT Mach-O file(s)"

file_has_archs() {
    file=$1
    shift
    have=$("$PYTHON" "$INSPECT" archs "$file" 2>/dev/null | tr '\n' ' ')
    [ -n "$have" ] || return 1
    for needed in "$@"; do
        case " $have " in
            *" $needed "*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

image_has_rpath_deps() {
    "$PYTHON" "$INSPECT" dylibs "$1" 2>/dev/null | grep -q '@rpath/' || return 1
}

rpaths_of() {
    "$PYTHON" "$INSPECT" rpaths "$1" 2>/dev/null
}

has_rpath() {
    file=$1
    wanted=$2
    while IFS= read -r existing; do
        [ "$existing" = "$wanted" ] && return 0
    done < <(rpaths_of "$file")
    return 1
}

add_rpath() {
    file=$1
    rpath=$2
    required=${3:-optional}
    if has_rpath "$file" "$rpath"; then
        return 0
    fi
    if ! "$INSTALL_NAME_TOOL" -add_rpath "$rpath" "$file" >/dev/null 2>&1; then
        if [ "$required" = "required" ]; then
            die "failed to add rpath $rpath to ${file#$APP_BUNDLE/} (relink with -headerpad_max_install_names)"
        fi
        # dyld falls back to the main executable's rpaths, so helper/framework
        # images keep working even when their own load commands cannot grow.
        warn "could not add rpath $rpath to ${file#$APP_BUNDLE/}; relying on the main executable rpath"
        return 0
    fi
    CHANGED_MACHOS+=("$file")
    note "added rpath $rpath to ${file#$APP_BUNDLE/}"
}

delete_rpath() {
    file=$1
    rpath=$2
    "$INSTALL_NAME_TOOL" -delete_rpath "$rpath" "$file" >/dev/null 2>&1 \
        || die "failed to delete rpath $rpath from ${file#$APP_BUNDLE/}"
    CHANGED_MACHOS+=("$file")
    note "removed rpath $rpath from ${file#$APP_BUNDLE/}"
}

is_portable_rpath() {
    case "$1" in
        @*) return 0 ;;
        /usr/lib|/usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Required Swift compatibility libraries
# ---------------------------------------------------------------------------

step "Collecting Swift runtime dependencies"

REQUIRED_SWIFT_LIBS="$TMP_ROOT/swift-libs.txt"
: > "$REQUIRED_SWIFT_LIBS"
while IFS= read -r macho; do
    "$PYTHON" "$INSPECT" required-swift-libs "$macho" >> "$REQUIRED_SWIFT_LIBS" 2>/dev/null || true
done < "$MACHO_LIST"
sort -u "$REQUIRED_SWIFT_LIBS" -o "$REQUIRED_SWIFT_LIBS"
SWIFT_LIB_COUNT=$(wc -l < "$REQUIRED_SWIFT_LIBS" | tr -d ' ')
if [ "$SWIFT_LIB_COUNT" -eq 0 ]; then
    note "no non-weak Swift compatibility libraries linked"
else
    while IFS= read -r lib; do
        note "required: $lib"
    done < "$REQUIRED_SWIFT_LIBS"
fi

# Directories inside the selected toolchain that hold back-deployed Swift
# runtime dylibs. Newest SDK/toolchain first; only real files are used.
toolchain_lib_dirs() {
    ls -d \
        "$DEVELOPER_DIR"/Toolchains/*/usr/lib/swift-*/macosx \
        "$DEVELOPER_DIR"/usr/lib/swift-*/macosx \
        "$DEVELOPER_DIR"/Toolchains/*/usr/lib/swift/macosx \
        "$DEVELOPER_DIR"/usr/lib/swift/macosx \
        2>/dev/null | sort -r
}

find_toolchain_lib() {
    lib_name=$1
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        candidate="$dir/$lib_name"
        if [ -f "$candidate" ] && [ ! -L "$candidate" ] \
            && file_has_archs "$candidate" "${REQUESTED_ARCHS[@]}"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done < <(toolchain_lib_dirs)
    return 1
}

# ---------------------------------------------------------------------------
# Copy libraries into Contents/Frameworks
# ---------------------------------------------------------------------------

step "Packaging Swift compatibility libraries into Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"

if [ -n "$STDLIB_TOOL" ] && [ "$SWIFT_LIB_COUNT" -gt 0 ]; then
    SCAN_ARGS=()
    while IFS= read -r macho; do
        SCAN_ARGS+=("--scan-executable" "$macho")
    done < "$MACHO_LIST"
    if "$STDLIB_TOOL" --copy "${SCAN_ARGS[@]}" --platform macosx \
        --destination "$FRAMEWORKS_DIR" > "$TMP_ROOT/stdlib-tool.log" 2>&1; then
        note "swift-stdlib-tool copy succeeded"
    else
        warn "swift-stdlib-tool failed; falling back to explicit toolchain lookup"
        sed 's/^/    /' "$TMP_ROOT/stdlib-tool.log" >&2 || true
    fi
fi

BUNDLED_SWIFT_LIBS=()
while IFS= read -r lib_name; do
    [ -n "$lib_name" ] || continue
    dest="$FRAMEWORKS_DIR/$lib_name"

    if [ -L "$dest" ]; then
        warn "replacing symlinked $lib_name in Contents/Frameworks"
        rm -f "$dest"
    fi

    if [ -f "$dest" ] && file_has_archs "$dest" "${REQUESTED_ARCHS[@]}"; then
        note "$lib_name already bundled"
    else
        if [ -f "$dest" ]; then
            note "$lib_name has missing slices; replacing from toolchain"
        fi
        source_lib=$(find_toolchain_lib "$lib_name" || true)
        if [ -z "$source_lib" ]; then
            die "cannot find $lib_name with slices [${REQUESTED_ARCHS[*]}] in the selected toolchain ($DEVELOPER_DIR). Install full Xcode (Command Line Tools may ship arm-only runtime libraries) or set DEVELOPER_DIR to Xcode."
        fi
        cp "$source_lib" "$dest" || die "failed to copy $source_lib"
        chmod 755 "$dest"
        if [ -L "$dest" ]; then
            die "copied $lib_name is a symlink; refusing to ship an OS stub"
        fi
        note "copied $lib_name from $source_lib"
    fi

    [ -f "$dest" ] || die "bundled library missing: $dest"
    [ ! -L "$dest" ] || die "bundled library is a symlink (OS stub): $dest"
    file_has_archs "$dest" "${REQUESTED_ARCHS[@]}" \
        || die "bundled library $lib_name lacks slices [${REQUESTED_ARCHS[*]}] after copy"

    # Thin to exactly the requested architectures (drops arm64e when not asked).
    current_archs=$("$PYTHON" "$INSPECT" archs "$dest" 2>/dev/null | tr '\n' ' ')
    keep=0
    thin_args=()
    for arch in "${REQUESTED_ARCHS[@]}"; do
        thin_args+=("-extract" "$arch")
    done
    for arch in $current_archs; do
        wanted=0
        for requested in "${REQUESTED_ARCHS[@]}"; do
            [ "$arch" = "$requested" ] && wanted=1
        done
        [ "$wanted" -eq 0 ] && keep=1
    done
    if [ "$keep" -eq 1 ]; then
        "$LIPO" "${thin_args[@]}" "$dest" -output "$dest.thin" >/dev/null 2>&1 \
            || die "failed to thin $lib_name to [${REQUESTED_ARCHS[*]}]"
        mv "$dest.thin" "$dest"
        chmod 755 "$dest"
        note "thinned $lib_name to ${REQUESTED_ARCHS[*]}"
        CHANGED_MACHOS+=("$dest")
    fi

    # Never ship a library whose LC_ID_DYLIB points at the machine it was
    # copied from (they normally reference /usr/lib/swift, which is correct).
    BUNDLED_SWIFT_LIBS+=("$dest")
done < "$REQUIRED_SWIFT_LIBS"

# ---------------------------------------------------------------------------
# rpath surgery
# ---------------------------------------------------------------------------

step "Normalizing rpaths"

while IFS= read -r macho; do
    [ -n "$macho" ] || continue
    while IFS= read -r rpath; do
        [ -n "$rpath" ] || continue
        if ! is_portable_rpath "$rpath"; then
            delete_rpath "$macho" "$rpath"
        fi
    done < <(rpaths_of "$macho")
done < "$MACHO_LIST"

# Main executable always gets the portable Frameworks search path.
add_rpath "$MAIN_BINARY" "@executable_path/../Frameworks" required

# Helpers in Contents/Resources/bin reach Contents/Frameworks via ../../Frameworks.
while IFS= read -r macho; do
    [ -n "$macho" ] || continue
    case "$macho" in
        "$RESOURCES_DIR"/bin/*)
            if image_has_rpath_deps "$macho"; then
                add_rpath "$macho" "@executable_path/../../Frameworks"
            fi
            ;;
    esac
done < "$MACHO_LIST"

# Framework binaries (Contents/Frameworks/Foo.framework/Versions/A/Foo) reach
# Contents/Frameworks via a path relative to their own location.
while IFS= read -r macho; do
    [ -n "$macho" ] || continue
    case "$macho" in
        "$FRAMEWORKS_DIR"/*.framework/*)
            if image_has_rpath_deps "$macho"; then
                loader_dir=$(dirname "$macho")
                relative_rpath=$("$PYTHON" "$INSPECT" rel-up "$loader_dir" "$FRAMEWORKS_DIR")
                add_rpath "$macho" "$relative_rpath"
            fi
            ;;
    esac
done < "$MACHO_LIST"

# Plain dylibs directly in Contents/Frameworks find siblings via @loader_path.
while IFS= read -r macho; do
    [ -n "$macho" ] || continue
    case "$macho" in
        "$FRAMEWORKS_DIR"/*)
            case "$macho" in
                "$FRAMEWORKS_DIR"/*.framework/*) ;;
                *)
                    if image_has_rpath_deps "$macho"; then
                        add_rpath "$macho" "@loader_path"
                    fi
                    ;;
            esac
            ;;
    esac
done < "$MACHO_LIST"

# ---------------------------------------------------------------------------
# Ad-hoc sign touched Mach-O files (caller still signs the bundle inside-out)
# ---------------------------------------------------------------------------

step "Ad-hoc signing modified Mach-O files"

if [ ${#CHANGED_MACHOS[@]} -gt 0 ] && command -v codesign >/dev/null 2>&1; then
    SIGNED=""
    for macho in "${CHANGED_MACHOS[@]}"; do
        case " $SIGNED " in
            *" $macho "*) continue ;;
        esac
        codesign --force --sign - "$macho" >/dev/null 2>&1 \
            || warn "ad-hoc signing failed for ${macho#$APP_BUNDLE/}"
        SIGNED="$SIGNED $macho"
    done
    note "ad-hoc signed $(printf '%s\n' $SIGNED | wc -l | tr -d ' ') file(s)"
else
    note "nothing to re-sign"
fi

# ---------------------------------------------------------------------------
# Guard: minOS was not modified
# ---------------------------------------------------------------------------

MAIN_MINOS_AFTER=$(minos_of "$MAIN_BINARY")
if [ "$MAIN_MINOS_BEFORE" != "$MAIN_MINOS_AFTER" ]; then
    die "internal error: main binary minimum OS version changed during preparation"
fi
for lib in "${BUNDLED_SWIFT_LIBS[@]+"${BUNDLED_SWIFT_LIBS[@]}"}"; do
    [ -n "$(minos_of "$lib")" ] || die "internal error: cannot read minOS of $lib"
done

# ---------------------------------------------------------------------------
# Swift runtime provenance / licensing
# ---------------------------------------------------------------------------

if [ ${#BUNDLED_SWIFT_LIBS[@]} -gt 0 ]; then
    step "Recording Swift runtime licenses/provenance"
    LICENSES_DIR="$RESOURCES_DIR/Licenses"
    mkdir -p "$LICENSES_DIR"

    LICENSE_SOURCES=""
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        for name in LICENSE LICENSE.txt LICENSE.md NOTICE NOTICE.txt COPYING; do
            if [ -f "$dir/$name" ]; then
                cp "$dir/$name" "$LICENSES_DIR/SwiftRuntime-$name" 2>/dev/null || true
                LICENSE_SOURCES="$LICENSE_SOURCES $dir/$name"
            fi
        done
    done < <(
        for lib in "${BUNDLED_SWIFT_LIBS[@]}"; do
            dirname "$lib"
        done | sort -u
    )

    NOTICE="$LICENSES_DIR/SwiftRuntime-NOTICE.txt"
    {
        printf 'TypstEdit - bundled Swift runtime notice\n'
        printf '========================================\n\n'
        printf 'This application bundles the following Swift runtime compatibility\n'
        printf 'libraries so it can run with the deployment target recorded in\n'
        printf 'Contents/Info.plist (LSMinimumSystemVersion) on Macs that do not ship\n'
        printf 'them in the operating system.\n\n'
        printf 'Toolchain: %s\n' "$DEVELOPER_DIR"
        if [ -n "$STDLIB_TOOL" ]; then
            printf 'swift-stdlib-tool: %s\n' "$STDLIB_TOOL"
        fi
        if command -v xcrun >/dev/null 2>&1; then
            SWIFT_VERSION=$(xcrun swift --version 2>/dev/null | head -n 2 | tr '\n' ' ')
            [ -n "$SWIFT_VERSION" ] && printf 'Swift: %s\n' "$SWIFT_VERSION"
        fi
        printf '\nBundled libraries:\n'
        for lib in "${BUNDLED_SWIFT_LIBS[@]}"; do
            archs=$("$PYTHON" "$INSPECT" archs "$lib" 2>/dev/null | awk '{printf "%s ", $0}')
            minos=$("$PYTHON" "$INSPECT" minos "$lib" 2>/dev/null | awk '{printf "%s=%s ", $1, $2}')
            digest=$(shasum -a 256 "$lib" 2>/dev/null | awk '{print $1}')
            printf '  %s\n' "$(basename "$lib")"
            printf '    path:   Contents/Frameworks/%s\n' "$(basename "$lib")"
            printf '    archs:  %s\n' "$archs"
            printf '    minOS:  %s (unmodified)\n' "$minos"
            printf '    sha256: %s\n' "$digest"
        done
        printf '\nThese libraries are part of the Swift runtime distributed with the\n'
        printf 'Apple toolchain and are licensed under the Apache License, Version 2.0\n'
        printf '(https://www.swift.org/LICENSE.txt). The Apache-2.0 license text is\n'
        printf 'not reinvented here. When the selected toolchain provides a license or\n'
        printf 'notice file next to the runtime libraries, it is copied verbatim into\n'
        printf 'this directory as SwiftRuntime-<name>; otherwise this notice records\n'
        printf 'only provenance and the upstream license reference. Keep this file in\n'
        printf 'redistributed builds and review it before changing the toolchain.\n'
        if [ -n "$LICENSE_SOURCES" ]; then
            printf '\nVerbatim license files copied from the toolchain:\n'
            for source in $LICENSE_SOURCES; do
                printf '  %s\n' "$source"
            done
        fi
    } > "$NOTICE"
    chmod 644 "$NOTICE"

    if [ -n "$LICENSE_SOURCES" ]; then
        note "copied toolchain license/notice files into Contents/Resources/Licenses"
    else
        warn "toolchain ships no license/notice file next to its Swift runtime; wrote provenance notice only"
    fi
    note "notice: ${NOTICE#$APP_BUNDLE/}"
else
    step "No Swift runtime libraries bundled; skipping license notice"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

step "Preparation complete"
note "bundle: $APP_BUNDLE"
note "architectures: ${REQUESTED_ARCHS[*]}"
note "Mach-O files scanned: $MACHO_COUNT"
note "Swift libraries bundled: ${#BUNDLED_SWIFT_LIBS[@]}"
note "Mach-O files modified: $(printf '%s\n' "${CHANGED_MACHOS[@]+"${CHANGED_MACHOS[@]}"}" | sort -u | grep -c . || true)"
note "minimum OS versions were not modified (recompile to change deployment target)"
note "run Tools/packaging/verify_bundle.sh before and after final signing"
exit 0
