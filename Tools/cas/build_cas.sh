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

# ---------------------------------------------------------------- fetching
fetch_sources() {
    log "Fetching GMP $GMP_VERSION"
    if [[ ! -d "$SRC/gmp-${GMP_VERSION}" ]]; then
        curl -fL --retry 3 -o "$DEPS/gmp.tar.xz" "$GMP_URL"
        tar -xJf "$DEPS/gmp.tar.xz" -C "$SRC"
    fi
    log "Fetching MPFR $MPFR_VERSION"
    if [[ ! -d "$SRC/mpfr-${MPFR_VERSION}" ]]; then
        curl -fL --retry 3 -o "$DEPS/mpfr.tar.xz" "$MPFR_URL"
        tar -xJf "$DEPS/mpfr.tar.xz" -C "$SRC"
    fi
    log "Fetching giac at $GIAC_COMMIT"
    if [[ ! -d "$SRC/giac/.git" ]]; then
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

if [[ $FETCH_ONLY -eq 1 ]]; then
    fetch_sources
    exit 0
fi

[[ -d "$SRC/giac" ]] || fetch_sources

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
