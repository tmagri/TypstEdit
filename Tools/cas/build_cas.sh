#!/bin/bash
# build_cas.sh — build the `typstedit-cas` helper used by TypstEdit's
# Calculator mode.
#
# The helper embeds Giac (the CAS engine behind Xcas / the HP Prime), which
# needs GMP and MPFR. This script fetches pinned sources, builds static
# libraries for one or both macOS architectures, then compiles and links the
# helper. Everything lands under <repo>/build/cas; `bundle.sh` copies the
# finished binary into the app bundle.
#
# Usage:
#   Tools/cas/build_cas.sh                 # build for this machine's arch
#   Tools/cas/build_cas.sh --arch universal # arm64 + x86_64, merged with lipo
#   Tools/cas/build_cas.sh --arch arm64 --clean
#   Tools/cas/build_cas.sh fetch           # only download/verify sources
#
# Requirements: clang (Xcode CLT), curl, tar, make, (lipo for universal).
set -euo pipefail

# Homebrew uses different prefixes on Apple Silicon and Intel. Include its
# build tools without requiring a custom interactive shell configuration.
for tools_dir in /opt/homebrew/bin /usr/local/bin; do
    if [[ -d "$tools_dir" ]]; then export PATH="$tools_dir:$PATH"; fi
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAS_ROOT="$REPO_ROOT/build/cas"
DEPS="$CAS_ROOT/deps"
SRC="$CAS_ROOT/src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
# Apply the same target to every C/C++ object, not just the final executable.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

GMP_VERSION=6.3.0
GMP_URL="https://gmplib.org/download/gmp/gmp-${GMP_VERSION}.tar.xz"
MPFR_VERSION=4.2.2
MPFR_URL="https://www.mpfr.org/mpfr-${MPFR_VERSION}/mpfr-${MPFR_VERSION}.tar.xz"
GIAC_REPO="https://salsa.debian.org/science-team/giac.git"
GIAC_COMMIT="5295d5d9144e3b9837cd257ec36a83c07a0ddbbe"

ARCH="$(uname -m)"
WANTED_ARCH=""
CLEAN=0
FETCH_ONLY=0
# autoconf 2.72+ generates configure scripts that macOS's /bin/sh (bash 3.2)
# cannot run; use Homebrew bash when it exists.
BREW_BASH="/bin/bash"
for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$candidate" ]]; then BREW_BASH="$candidate"; break; fi
done
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch) WANTED_ARCH="$2"; shift 2 ;;
        --clean) CLEAN=1; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        fetch) FETCH_ONLY=1; shift ;;
        *) echo "unknown option: $1"; exit 1 ;;
    esac
done

case "$WANTED_ARCH" in
    "") ARCHS=("$ARCH") ;;
    universal) ARCHS=(arm64 x86_64) ;;
    arm64|x86_64) ARCHS=("$WANTED_ARCH") ;;
    *) echo "bad --arch '$WANTED_ARCH' (arm64|x86_64|universal)"; exit 1 ;;
esac

# Fail with installation instructions, rather than failing deep inside a
# configure/make step with the unhelpful status 127.
missing=()
for tool in clang clang++ curl git make patch tar autoreconf autoconf automake aclocal; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ! command -v glibtoolize >/dev/null 2>&1 && ! command -v libtoolize >/dev/null 2>&1; then
    missing+=("GNU libtool (glibtoolize/libtoolize)")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Missing CAS build tools:\n'
    printf '  %s\n' "${missing[@]}"
    printf 'Install Xcode Command Line Tools and run: brew install autoconf automake libtool bash\n'
    exit 1
fi
if command -v glibtoolize >/dev/null 2>&1; then
    export LIBTOOLIZE="$(command -v glibtoolize)"
fi

mkdir -p "$DEPS" "$SRC" "$CAS_ROOT"

log() { printf '\n=== %s ===\n' "$*"; }

# ----------------------------------------------------------------- helpers
# Downloads `$2` to `$1`, retrying transient failures.
#
# `curl --retry` alone does not cover HTTP/2 framing errors (curl exit 16),
# which are common on flaky networks and previously aborted the CAS build with
# no retry at all. `--retry-all-errors` plus a partial-file cleanup keeps the
# build resumable instead of failing the whole DMG step.
download() {
    local dest="$1" url="$2"
    local attempt
    for attempt in 1 2 3 4 5; do
        if curl -fL --retry 3 --retry-all-errors --retry-delay 2 \
                --connect-timeout 20 --max-time 600 \
                -o "$dest.part" "$url"; then
            mv "$dest.part" "$dest"
            return 0
        fi
        rm -f "$dest.part"
        printf 'retrying %s (attempt %d/5)\n' "$url" "$attempt"
        sleep $((attempt * 2))
    done
    printf 'error: could not download %s\n' "$url" >&2
    return 1
}

# Extracts an already-downloaded tarball, reusing it when it is still valid.
# Returns non-zero when the cached archive is missing or corrupt so the caller
# can re-download.
extract_cached() {
    local archive="$1" target="$2" dir="$3"
    [[ -f "$archive" ]] || return 1
    rm -rf "$dir"
    if tar -xJf "$archive" -C "$target" 2>/dev/null && [[ -f "$dir/configure" ]]; then
        return 0
    fi
    rm -rf "$dir"
    return 1
}

# ---------------------------------------------------------------- fetching
fetch_sources() {
    log "Fetching GMP $GMP_VERSION"
    # Check for a file inside the tree, not just the directory: an interrupted
    # `tar` can leave the directory behind with its contents missing or partial,
    # and a bare `-d` test would then skip the re-extract forever.
    if [[ ! -f "$SRC/gmp-${GMP_VERSION}/configure" ]]; then
        if ! extract_cached "$DEPS/gmp.tar.xz" "$SRC" "$SRC/gmp-${GMP_VERSION}"; then
            download "$DEPS/gmp.tar.xz" "$GMP_URL"
            tar -xJf "$DEPS/gmp.tar.xz" -C "$SRC"
        fi
    fi
    log "Fetching MPFR $MPFR_VERSION"
    if [[ ! -f "$SRC/mpfr-${MPFR_VERSION}/configure" ]]; then
        if ! extract_cached "$DEPS/mpfr.tar.xz" "$SRC" "$SRC/mpfr-${MPFR_VERSION}"; then
            download "$DEPS/mpfr.tar.xz" "$MPFR_URL"
            tar -xJf "$DEPS/mpfr.tar.xz" -C "$SRC"
        fi
    fi
    log "Fetching giac at $GIAC_COMMIT"
    if [[ ! -d "$SRC/giac/.git" ]]; then
        rm -rf "$SRC/giac"
        git clone --no-checkout --depth 1 "$GIAC_REPO" "$SRC/giac"
    fi
    # Fetch the pinned revision itself: the latest 50 commits may no longer
    # contain it after upstream advances.
    if ! git -C "$SRC/giac" cat-file -e "$GIAC_COMMIT^{commit}" 2>/dev/null; then
        git -C "$SRC/giac" fetch --depth 1 origin "$GIAC_COMMIT"
    fi
    git -C "$SRC/giac" checkout --detach "$GIAC_COMMIT"
    log "Sources ready"
}

# Returns 0 when every pinned source tree is present on disk.
#
# GMP and MPFR are only used to build per-arch static libraries, while the giac
# checkout is also the marker attached to `build/cas/src`. Checking only for the
# giac directory meant a tree missing gmp/mpfr (eg after a partial clean, or when
# `build/cas/src` was preserved but its tarball contents were not) skipped the
# fetch and failed later with a bare `cp: ... No such file or directory`.
have_all_sources() {
    [[ -f "$SRC/gmp-${GMP_VERSION}/configure" ]] \
        && [[ -f "$SRC/mpfr-${MPFR_VERSION}/configure" ]] \
        && [[ -d "$SRC/giac/.git" ]]
}

if [[ $FETCH_ONLY -eq 1 ]]; then
    fetch_sources
    exit 0
fi

have_all_sources || fetch_sources

# ------------------------------------------------------------ per-arch build
build_arch() {
    local arch="$1"
    local prefix="$CAS_ROOT/prefix-$arch"
    local buildroot="$CAS_ROOT/build-$arch"

    log "Building for $arch (macOS $MACOSX_DEPLOYMENT_TARGET)"
    local cache_key="target-v3:$MACOSX_DEPLOYMENT_TARGET:gmp-$GMP_VERSION:mpfr-$MPFR_VERSION:giac-$GIAC_COMMIT"
    # Earlier builds cached host-target objects (macOS 26), despite linking
    # the final helper with a macOS 13 load command. Rebuild those caches.
    if [[ ! -f "$prefix/.build-key" ]] || [[ "$(cat "$prefix/.build-key")" != "$cache_key" ]]; then
        rm -rf "$prefix" "$buildroot"
    fi
    mkdir -p "$prefix" "$buildroot"

    local CC_BIN="clang -arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
    local CXX_BIN="clang++ -arch $arch -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

    # --- GMP
    if [[ ! -f "$prefix/lib/libgmp.a" ]]; then
        log "GMP ($arch)"
        rm -rf "$buildroot/gmp"
        cp -R "$SRC/gmp-${GMP_VERSION}" "$buildroot/gmp"
        ( cd "$buildroot/gmp" \
          && ./configure --prefix="$prefix" \
                --enable-static --disable-shared --with-pic \
                --disable-cxx \
                CC="$CC_BIN" \
                $([[ "$arch" == "x86_64" ]] && echo "--host=x86_64-apple-darwin") \
          && make -j"$JOBS" \
          && make install )
    fi

    # --- MPFR
    if [[ ! -f "$prefix/lib/libmpfr.a" ]]; then
        log "MPFR ($arch)"
        rm -rf "$buildroot/mpfr"
        cp -R "$SRC/mpfr-${MPFR_VERSION}" "$buildroot/mpfr"
        ( cd "$buildroot/mpfr" \
          && ./configure --prefix="$prefix" \
                --with-gmp="$prefix" \
                --enable-static --disable-shared \
                CC="$CC_BIN" \
          && make -j"$JOBS" \
          && make install )
    fi

    # --- giac (library only; no GUI, no optional math libraries)
    if [[ ! -f "$prefix/lib/libgiac.a" ]]; then
        log "giac ($arch) — this is the long step"
        rm -rf "$buildroot/giac"
        bash "$REPO_ROOT/Tools/cas/prepare_giac.sh" "$SRC/giac" "$GIAC_COMMIT" "$buildroot/giac"
        ( cd "$buildroot/giac" \
          && CONFIG_SHELL="$BREW_BASH" "$BREW_BASH" ./configure --prefix="$prefix" \
                --disable-fltk --disable-cocoa --disable-ao --disable-gsl \
                --disable-lapack --disable-pari --disable-ntl --disable-glpk \
                --disable-samplerate --disable-curl --disable-gettext \
                --disable-micropy --disable-quickjs --disable-png \
                --disable-ecm --disable-bernmm --disable-dl \
                --disable-shared --enable-static \
                CC="$CC_BIN" CXX="$CXX_BIN" \
                CFLAGS="-O2 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
                CXXFLAGS="-O2 -std=gnu++17 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
                CPPFLAGS="-I$prefix/include" \
                LDFLAGS="-L$prefix/lib -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" \
          && make -C src libgiac.la -j"$JOBS" \
          && make -C src install-giacincludeHEADERS DESTDIR= )
        # Install only the library the helper needs. `install-libLTLIBRARIES`
        # would also build libxcas (the GUI), whose gl2ps.c Debian removes.
        # Upstream installs these generated headers from an exec hook.
        mkdir -p "$prefix/lib" "$prefix/include/giac"
        cp "$buildroot/giac/src/.libs/libgiac.a" "$prefix/lib/libgiac.a"
        for header in config.h input_lexer.h input_parser.h; do
            cp "$buildroot/giac/src/$header" "$prefix/include/giac/$header"
        done
        [[ -f "$prefix/lib/libgiac.a" ]] || { echo "giac build failed"; exit 1; }
    fi

    # --- helper
    log "typstedit-cas ($arch)"
    clang++ -std=gnu++17 -O2 -arch "$arch" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
        "$REPO_ROOT/Tools/cas/typstedit-cas.cpp" \
        -I"$prefix/include" \
        -o "$CAS_ROOT/typstedit-cas-$arch.new" \
        "$prefix/lib/libgiac.a" "$prefix/lib/libmpfr.a" "$prefix/lib/libgmp.a" \
        -lz -lm -lpthread \
        -framework CoreFoundation -framework Accelerate
    mv "$CAS_ROOT/typstedit-cas-$arch.new" "$CAS_ROOT/typstedit-cas-$arch"
    printf '%s\n' "$cache_key" > "$prefix/.build-key"
    log "Built $CAS_ROOT/typstedit-cas-$arch"
}

for a in "${ARCHS[@]}"; do
    if [[ $CLEAN -eq 1 ]]; then
        rm -rf "$CAS_ROOT/prefix-$a" "$CAS_ROOT/build-$a" "$CAS_ROOT/typstedit-cas-$a"
    fi
    build_arch "$a"
done

# ------------------------------------------------------------- final binary
if [[ "${#ARCHS[@]}" -eq 2 ]]; then
    lipo -create "$CAS_ROOT/typstedit-cas-arm64" "$CAS_ROOT/typstedit-cas-x86_64" \
        -output "$CAS_ROOT/typstedit-cas.new"
else
    cp "$CAS_ROOT/typstedit-cas-${ARCHS[0]}" "$CAS_ROOT/typstedit-cas.new"
fi

chmod +x "$CAS_ROOT/typstedit-cas.new"
codesign --force --sign - "$CAS_ROOT/typstedit-cas.new"
mv "$CAS_ROOT/typstedit-cas.new" "$CAS_ROOT/typstedit-cas"
log "Done: $CAS_ROOT/typstedit-cas"
# Do not fail a cross-build by executing a foreign architecture on the host.
if lipo -verify_arch "$ARCH" "$CAS_ROOT/typstedit-cas" >/dev/null 2>&1; then
    "$CAS_ROOT/typstedit-cas" <<'EOF'
{"v":1,"id":1,"op":"eval","input":"solve(x^2-4=0,x)","angle":"rad","digits":12}
{"v":1,"id":2,"op":"shutdown"}
EOF
else
    log "Cross-built helper; execution test requires a $WANTED_ARCH Mac"
fi
