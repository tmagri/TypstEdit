#!/bin/bash
# run_tests.sh - self-contained tests for Tools/packaging helpers.
#
# Builds tiny Mach-O fixtures with clang, then checks that:
#   - a correct bundle passes verification;
#   - the verifier rejects a missing Swift compatibility library, a wrong
#     architecture, a minimum-OS mismatch, non-portable rpaths and
#     dependencies, symlinked OS stubs and missing layout files;
#   - prepare_bundle.sh copies a real (non-symlink) universal Swift library,
#     installs the portable rpath, removes build-machine rpaths, leaves
#     minimum OS versions untouched and is idempotent;
#   - the built TypstEdit.app in the repository root, when present, PASSES
#     verification, and a copy prepared with this helper only still fails on
#     the truthful minimum-OS mismatch.
#
# Requires: macOS with Xcode or Command Line Tools (clang, lipo,
# install_name_tool, codesign) and python3. The universal-Swift-library test
# needs full Xcode; it is skipped when only Command Line Tools are available.
#
# Bash 3.2 compatible. Exits non-zero when any test fails.

set -u

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=$(cd "$TESTS_DIR/.." && pwd)
REPO_DIR=$(cd "$PKG_DIR/../.." && pwd)
PREPARE="$PKG_DIR/prepare_bundle.sh"
VERIFY="$PKG_DIR/verify_bundle.sh"
INSPECT="$PKG_DIR/lib/macho_inspect.py"
PYTHON=${PYTHON:-python3}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/typstedit-packaging-tests.XXXXXX") || exit 1
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

ok() {
    PASS=$((PASS + 1))
    printf 'PASS  %s\n' "$1"
}

skip() {
    SKIP=$((SKIP + 1))
    printf 'SKIP  %s (%s)\n' "$1" "$2"
}

fail() {
    FAIL=$((FAIL + 1))
    name=$1
    shift
    FAILED_NAMES="$FAILED_NAMES
  - $name"
    printf 'FAIL  %s\n' "$name"
    for line in "$@"; do
        printf '%s\n' "$line" | sed 's/^/      /'
    done
}

invoke() {
    LAST_OUT="$WORK/last-output.txt"
    "$@" > "$LAST_OUT" 2>&1
    LAST_STATUS=$?
}

assert_status() {
    name=$1
    expected=$2
    if [ "$LAST_STATUS" -eq "$expected" ]; then
        ok "$name"
    else
        fail "$name" "expected exit $expected, got $LAST_STATUS" "output:" "$(tail -n 30 "$LAST_OUT")"
    fi
}

assert_contains() {
    name=$1
    pattern=$2
    if grep -F -- "$pattern" "$LAST_OUT" >/dev/null 2>&1; then
        ok "$name"
    else
        fail "$name" "expected output to contain: $pattern" "output:" "$(tail -n 30 "$LAST_OUT")"
    fi
}

assert_not_contains() {
    name=$1
    pattern=$2
    if grep -F -- "$pattern" "$LAST_OUT" >/dev/null 2>&1; then
        fail "$name" "expected output NOT to contain: $pattern" "output:" "$(tail -n 30 "$LAST_OUT")"
    else
        ok "$name"
    fi
}

assert_file() {
    name=$1
    path=$2
    if [ -f "$path" ] && [ ! -L "$path" ]; then
        ok "$name"
    else
        fail "$name" "expected real regular file: $path"
    fi
}

assert_archs() {
    name=$1
    path=$2
    expected=$3
    actual=$("$PYTHON" "$INSPECT" archs "$path" 2>/dev/null | tr '\n' ' ')
    actual_sorted=$(printf '%s\n' $actual | sort | tr '\n' ' ')
    expected_sorted=$(printf '%s\n' $expected | sort | tr '\n' ' ')
    if [ "$actual_sorted" = "$expected_sorted" ]; then
        ok "$name"
    else
        fail "$name" "expected archs '$expected', got '$actual'"
    fi
}

# --- environment -----------------------------------------------------------

command -v "$PYTHON" >/dev/null 2>&1 || {
    printf 'python3 is required\n' >&2
    exit 1
}
command -v xcrun >/dev/null 2>&1 || {
    printf 'xcrun is required (install Command Line Tools)\n' >&2
    exit 1
}
CLANG=$(xcrun --find clang 2>/dev/null) || {
    printf 'clang not found via xcrun\n' >&2
    exit 1
}
LIPO=$(xcrun --find lipo 2>/dev/null)
INSTALL_NAME_TOOL=$(xcrun --find install_name_tool 2>/dev/null)
# clang 21 omits -syslibroot when both -arch and -mmacosx-version-min are
# given unless the SDK is passed explicitly; fixture builds set it always.
SDKROOT=$(xcrun --show-sdk-path 2>/dev/null)
if [ -z "$SDKROOT" ]; then
    printf 'could not resolve the macOS SDK path\n' >&2
    exit 1
fi

COMPAT_LIB=""
for candidate in \
    ${DEVELOPER_DIR:+$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-*/macosx/libswiftCompatibilitySpan.dylib} \
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-*/macosx/libswiftCompatibilitySpan.dylib \
    /Library/Developer/CommandLineTools/usr/lib/swift-*/macosx/libswiftCompatibilitySpan.dylib; do
    if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
        COMPAT_LIB=$candidate
        break
    fi
done
[ -n "$COMPAT_LIB" ] || {
    printf 'could not find libswiftCompatibilitySpan.dylib in a toolchain; run with full Xcode installed\n' >&2
    exit 1
}

UNIVERSAL_COMPAT_LIB=""
for candidate in \
    ${DEVELOPER_DIR:+$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-*/macosx/libswiftCompatibilitySpan.dylib} \
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-*/macosx/libswiftCompatibilitySpan.dylib; do
    if [ -f "$candidate" ] && [ ! -L "$candidate" ] \
        && "$PYTHON" "$INSPECT" archs "$candidate" 2>/dev/null | grep -Fx arm64 >/dev/null \
        && "$PYTHON" "$INSPECT" archs "$candidate" 2>/dev/null | grep -Fx x86_64 >/dev/null; then
        UNIVERSAL_COMPAT_LIB=$candidate
        break
    fi
done

printf 'fixtures: %s\n' "$WORK"
printf 'toolchain compatibility library: %s\n' "$COMPAT_LIB"
if [ -n "$UNIVERSAL_COMPAT_LIB" ]; then
    printf 'universal compatibility library: %s\n' "$UNIVERSAL_COMPAT_LIB"
fi

# --- fixture builders ------------------------------------------------------

printf 'int main(void) { return 0; }\n' > "$WORK/main.c"
printf 'int vec_symbol(void) { return 0; }\n' > "$WORK/vec.c"

write_plist() {
    plist=$1
    minos=$2
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Fixture</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.fixture</string>
    <key>CFBundleName</key>
    <string>Fixture</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.0.1</string>
    <key>CFBundleVersion</key>
    <string>0.0.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>$minos</string>
</dict>
</plist>
EOF
}

# make_app APP MAIN_MINOS VECTOR_MINOS WITH_COMPAT [MAIN_ARCHS] [TYPST_ARCHS]
make_app() {
    app=$1
    main_minos=$2
    vector_minos=$3
    with_compat=$4
    main_archs=${5:-arm64}
    typst_archs=${6:-arm64}

    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" \
             "$app/Contents/Frameworks" \
             "$app/Contents/Resources/bin" \
             "$app/Contents/Resources/FixtureResources.bundle"

    arch_flags=""
    for arch in $main_archs; do
        arch_flags="$arch_flags -arch $arch"
    done

    # shellcheck disable=SC2086
    if [ "$with_compat" -eq 1 ]; then
        "$CLANG" $arch_flags -isysroot "$SDKROOT" -Wl,-headerpad_max_install_names -mmacosx-version-min="$main_minos" \
            -Wl,-rpath,@executable_path/../Frameworks \
            "$WORK/main.c" "$COMPAT_LIB" -o "$app/Contents/MacOS/Fixture"
        "$INSTALL_NAME_TOOL" -change /usr/lib/swift/libswiftCompatibilitySpan.dylib \
            @rpath/libswiftCompatibilitySpan.dylib "$app/Contents/MacOS/Fixture"
    else
        "$CLANG" $arch_flags -isysroot "$SDKROOT" -Wl,-headerpad_max_install_names -mmacosx-version-min="$main_minos" \
            -Wl,-rpath,@executable_path/../Frameworks \
            "$WORK/main.c" -o "$app/Contents/MacOS/Fixture"
    fi

    vector_dir="$app/Contents/Frameworks/vector.framework"
    mkdir -p "$vector_dir/Resources"
    # shellcheck disable=SC2086
    "$CLANG" $arch_flags -dynamiclib -isysroot "$SDKROOT" -Wl,-headerpad_max_install_names -mmacosx-version-min="$vector_minos" \
        -install_name @rpath/vector.framework/vector \
        "$WORK/vec.c" -o "$vector_dir/vector"
    cat > "$vector_dir/Resources/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>vector</string>
    <key>CFBundleIdentifier</key>
    <string>com.example.vector</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
</dict>
</plist>
EOF

    # shellcheck disable=SC2086
    "$CLANG" -arch arm64 -isysroot "$SDKROOT" -Wl,-headerpad_max_install_names -mmacosx-version-min=11.0 "$WORK/main.c" \
        -o "$app/Contents/Resources/bin/typst"
    [ "$typst_archs" = arm64 ] || {
        # shellcheck disable=SC2086
        "$CLANG" -arch x86_64 -isysroot "$SDKROOT" -Wl,-headerpad_max_install_names -mmacosx-version-min=11.0 "$WORK/main.c" \
            -o "$WORK/typst-x86_64"
        "$LIPO" -create "$app/Contents/Resources/bin/typst" \
            "$WORK/typst-x86_64" -output "$app/Contents/Resources/bin/typst"
    }

    # shellcheck disable=SC2086
    "$CLANG" -arch arm64 -arch x86_64 -isysroot "$SDKROOT" -Wl,-headerpad_max_install_names -mmacosx-version-min=13.0 \
        "$WORK/main.c" -o "$app/Contents/Resources/bin/typstedit-cas"

    printf 'fixture resource\n' > "$app/Contents/Resources/FixtureResources.bundle/data.txt"
    write_plist "$app/Contents/Info.plist" "$main_minos"
}


# ===========================================================================
# Tests
# ===========================================================================

test_valid_bundle_passes() {
    app="$WORK/valid.app"
    make_app "$app" 13.0 13.0 1
    mkdir -p "$app/Contents/Frameworks"
    cp "$COMPAT_LIB" "$app/Contents/Frameworks/"
    "$LIPO" -extract arm64 "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib" \
        -output "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib.thin"
    mv "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib.thin" \
        "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    invoke "$VERIFY" "$app" arm64
    assert_status "valid fixture bundle passes verification" 0
}

test_missing_compat_library_fails() {
    app="$WORK/missing-compat.app"
    make_app "$app" 13.0 13.0 1
    invoke "$VERIFY" "$app" arm64
    assert_status "missing Swift compatibility library is rejected" 1
    assert_contains "missing compatibility library names the dylib" "libswiftCompatibilitySpan.dylib"
    assert_contains "missing compatibility library is reported as unbundled" "not bundled in Contents/Frameworks"
}

test_wrong_architecture_fails() {
    app="$WORK/wrong-arch.app"
    make_app "$app" 13.0 13.0 0 "arm64 x86_64" "arm64"
    invoke "$VERIFY" "$app" "arm64 x86_64"
    assert_status "wrong architecture is rejected" 1
    assert_contains "wrong architecture names the missing slice" "missing x86_64"
    assert_contains "wrong architecture names the typst helper" "Contents/Resources/bin/typst"
}

test_minos_mismatch_fails() {
    app="$WORK/bad-minos.app"
    make_app "$app" 13.0 15.0 0
    invoke "$VERIFY" "$app" arm64
    assert_status "LSMinimumSystemVersion mismatch is rejected" 1
    assert_contains "minOS mismatch quotes the declaration" "LSMinimumSystemVersion is 13.0"
    assert_contains "minOS mismatch quotes the real requirement" "requires macOS 15.0"
    assert_contains "minOS mismatch names the vector binary" "vector.framework/vector"
}

test_nonportable_rpath_fails() {
    app="$WORK/bad-rpath.app"
    make_app "$app" 13.0 13.0 0
    "$INSTALL_NAME_TOOL" -add_rpath /opt/homebrew/lib "$app/Contents/MacOS/Fixture"
    invoke "$VERIFY" "$app" arm64
    assert_status "absolute Homebrew rpath is rejected" 1
    assert_contains "Homebrew rpath is quoted" "/opt/homebrew/lib"
    assert_contains "Homebrew rpath is called non-portable" "non-portable rpath"
}

test_nonportable_dependency_fails() {
    app="$WORK/bad-dep.app"
    make_app "$app" 13.0 13.0 0
    "$INSTALL_NAME_TOOL" -change /usr/lib/libSystem.B.dylib \
        /Users/tester/build/libSystem.B.dylib "$app/Contents/MacOS/Fixture"
    invoke "$VERIFY" "$app" arm64
    assert_status "absolute /Users dependency is rejected" 1
    assert_contains "/Users dependency is quoted" "/Users/tester/build/libSystem.B.dylib"
    assert_contains "/Users dependency is called non-portable" "non-portable dependency"
}

test_missing_layout_files_fail() {
    app="$WORK/missing-layout.app"
    make_app "$app" 13.0 13.0 0

    rm -f "$app/Contents/Resources/bin/typst"
    invoke "$VERIFY" "$app" arm64
    assert_status "missing Typst helper is rejected" 1
    assert_contains "missing Typst helper is named" "missing Typst helper"

    make_app "$app" 13.0 13.0 0
    rm -rf "$app/Contents/Frameworks/vector.framework"
    invoke "$VERIFY" "$app" arm64
    assert_status "missing vector.framework is rejected" 1
    assert_contains "missing vector.framework is named" "missing vector.framework"

    make_app "$app" 13.0 13.0 0
    rm -rf "$app/Contents/Resources/FixtureResources.bundle"
    invoke "$VERIFY" "$app" arm64
    assert_status "missing resource bundles are rejected" 1
    assert_contains "missing resource bundles are named" "no *.bundle resource bundles"

    make_app "$app" 13.0 13.0 0
    rm -f "$app/Contents/MacOS/Fixture"
    invoke "$VERIFY" "$app" arm64
    assert_status "missing main binary is rejected" 1
    assert_contains "missing main binary is named" "missing main binary"
}

test_symlinked_stub_is_rejected() {
    app="$WORK/stub-symlink.app"
    make_app "$app" 13.0 13.0 1
    ln -s /usr/lib/swift/libswiftCore.dylib \
        "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    invoke "$VERIFY" "$app" arm64
    assert_status "symlinked OS stub as compatibility library is rejected" 1
    assert_contains "stub symlink is reported" "symlink"
}

test_prepare_fixes_compat_and_rpaths() {
    app="$WORK/prepare.app"
    make_app "$app" 13.0 13.0 1
    "$INSTALL_NAME_TOOL" -add_rpath \
        /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx \
        "$app/Contents/MacOS/Fixture"
    "$INSTALL_NAME_TOOL" -add_rpath /Users/tester/build/DerivedData "$app/Contents/MacOS/Fixture"

    minos_before=$("$PYTHON" "$INSPECT" minos "$app/Contents/MacOS/Fixture")
    invoke "$PREPARE" "$app" arm64
    if [ "$LAST_STATUS" -eq 0 ]; then
        ok "prepare_bundle.sh succeeds on a fixture bundle"
    else
        fail "prepare_bundle.sh succeeds on a fixture bundle" "output:" "$(tail -n 30 "$LAST_OUT")"
    fi

    lib="$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    assert_file "prepare copies a real Swift compatibility library" "$lib"
    assert_archs "prepared Swift library is thinned to the requested arch" "$lib" "arm64 "
    minos_after=$("$PYTHON" "$INSPECT" minos "$app/Contents/MacOS/Fixture")
    if [ "$minos_before" = "$minos_after" ]; then
        ok "prepare does not change the main binary minimum OS version"
    else
        fail "prepare does not change the main binary minimum OS version" \
            "before: $minos_before" "after: $minos_after"
    fi

    rpaths=$("$PYTHON" "$INSPECT" rpaths "$app/Contents/MacOS/Fixture")
    case "$rpaths" in
        *"@executable_path/../Frameworks"*) ok "prepare adds the portable Frameworks rpath" ;;
        *) fail "prepare adds the portable Frameworks rpath" "rpaths: $rpaths" ;;
    esac
    case "$rpaths" in
        *"/Applications/Xcode.app"*) fail "prepare removes the Xcode toolchain rpath" "rpaths: $rpaths" ;;
        *) ok "prepare removes the Xcode toolchain rpath" ;;
    esac
    case "$rpaths" in
        *"/Users/tester"*) fail "prepare removes the /Users build rpath" "rpaths: $rpaths" ;;
        *) ok "prepare removes the /Users build rpath" ;;
    esac

    invoke "$VERIFY" "$app" arm64
    assert_status "prepared fixture bundle passes verification" 0

    # Idempotency: a second run must not duplicate the portable rpath.
    invoke "$PREPARE" "$app" arm64
    assert_status "prepare_bundle.sh is idempotent" 0
    count=$("$PYTHON" "$INSPECT" rpaths "$app/Contents/MacOS/Fixture" 2>/dev/null | grep -Fxc "@executable_path/../Frameworks" || true)
    if [ "$count" -eq 1 ]; then
        ok "portable rpath is not duplicated on re-run"
    else
        fail "portable rpath is not duplicated on re-run" "count: $count"
    fi
}

test_prepare_replaces_stub_symlink() {
    app="$WORK/prepare-stub.app"
    make_app "$app" 13.0 13.0 1
    ln -s /usr/lib/swift/libswiftCore.dylib \
        "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    invoke "$PREPARE" "$app" arm64
    assert_status "prepare replaces a pre-existing OS stub symlink" 0
    assert_file "prepare leaves a real library, not a symlink" \
        "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    invoke "$VERIFY" "$app" arm64
    assert_status "bundle with replaced stub passes verification" 0
}

test_prepare_universal_compat() {
    if [ -z "$UNIVERSAL_COMPAT_LIB" ]; then
        skip "prepare packages universal Swift compatibility library" "no universal toolchain library (full Xcode required)"
        return
    fi
    app="$WORK/prepare-universal.app"
    make_app "$app" 13.0 13.0 1 "arm64 x86_64" "arm64 x86_64"
    invoke "$PREPARE" "$app" arm64 x86_64
    assert_status "prepare_bundle.sh packages a universal bundle" 0
    lib="$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
    assert_file "universal Swift library is a real file" "$lib"
    assert_archs "universal Swift library keeps both requested slices" "$lib" "arm64 x86_64 "
    invoke "$VERIFY" "$app" arm64 x86_64
    assert_status "universal fixture bundle passes verification" 0
}

test_clt_only_toolchain_is_rejected() {
    clt=/Library/Developer/CommandLineTools
    if [ ! -d "$clt" ]; then
        skip "prepare rejects a toolchain without the requested slice" "Command Line Tools not installed"
        return
    fi
    clt_lib=$(ls "$clt"/usr/lib/swift-*/macosx/libswiftCompatibilitySpan.dylib 2>/dev/null | head -n 1)
    if [ -z "$clt_lib" ] || "$PYTHON" "$INSPECT" archs "$clt_lib" 2>/dev/null | grep -Fx x86_64 >/dev/null; then
        skip "prepare rejects a toolchain without the requested slice" "CLT ships a universal library here"
        return
    fi
    app="$WORK/prepare-clt.app"
    make_app "$app" 13.0 13.0 1 "arm64 x86_64" "arm64 x86_64"
    invoke env DEVELOPER_DIR="$clt" "$PREPARE" "$app" x86_64
    assert_status "prepare rejects a toolchain lacking the requested slice" 1
    assert_contains "prepare explains the missing toolchain slice" "with slices [x86_64]"
}

test_built_app_passes() {
    # The repository's TypstEdit.app is a build artifact. When present, it
    # must be the verified, portable output of bundle.sh/bundle_universal.sh.
    # (The failure classes it once had are covered by the fixture tests.)
    built_app="$REPO_DIR/TypstEdit.app"
    if [ ! -d "$built_app" ]; then
        skip "built TypstEdit.app passes verification" "TypstEdit.app not present"
        return
    fi
    archs="$(lipo -archs "$built_app/Contents/MacOS/TypstEdit" 2>/dev/null || true)"
    invoke "$VERIFY" "$built_app" $archs
    assert_status "built TypstEdit.app passes verification" 0
    assert_not_contains "built app bundles the Swift compatibility library" "not bundled in Contents/Frameworks"
    assert_not_contains "built app has no non-portable rpath" "non-portable rpath"
}

# --- run -------------------------------------------------------------------

test_valid_bundle_passes
test_missing_compat_library_fails
test_wrong_architecture_fails
test_minos_mismatch_fails
test_nonportable_rpath_fails
test_nonportable_dependency_fails
test_missing_layout_files_fail
test_symlinked_stub_is_rejected
test_prepare_fixes_compat_and_rpaths
test_prepare_replaces_stub_symlink
test_prepare_universal_compat
test_clt_only_toolchain_is_rejected
test_built_app_passes

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -ne 0 ]; then
    printf 'failed tests:%s\n' "$FAILED_NAMES"
    exit 1
fi
exit 0
