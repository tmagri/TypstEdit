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

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAS_ROOT="$REPO_ROOT/build/cas"
DEPS="$CAS_ROOT/deps"
SRC="$CAS_ROOT/src"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

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
BREW_BASH="/opt/homebrew/bin/bash"
[[ -x "$BREW_BASH" ]] || BREW_BASH="/bin/bash"
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
    if [[ ! -d "$SRC/giac" ]]; then
        git clone --depth 50 "$GIAC_REPO" "$SRC/giac"
    fi
    ( cd "$SRC/giac" && git fetch --depth 50 origin master 2>/dev/null || true
      git checkout -q "$GIAC_COMMIT" )
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

    log "Building for $arch"
    mkdir -p "$prefix" "$buildroot"

    local CC_BIN="clang -arch $arch"
    local CXX_BIN="clang++ -arch $arch"

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
        cp -R "$SRC/giac" "$buildroot/giac"
        ( cd "$buildroot/giac" \
          && for patch in "$SRC"/giac/debian/patches/*.patch; do \
                patch -p1 --forward --silent < "$patch" 2>/dev/null || true; \
            done \
          && sed -i.bak -e 's/^   AM_GNU_GETTEXT$/   dnl AM_GNU_GETTEXT (not needed for the helper build)/' \
                        -e 's/^   AM_GNU_GETTEXT_VERSION/   dnl AM_GNU_GETTEXT_VERSION/' \
                        -e 's/^SUBDIRS =.*/SUBDIRS = src/' \
                        -e 's/^DIST_SUBDIRS =.*/DIST_SUBDIRS = src/' \
                        configure.ac Makefile.am \
          && sed -i.bak2 '/^AC_OUTPUT(\[/,$ { /^doc\//d; /^intl\//d; /^po\//d; /^examples\//d; /^debian/d; /^micropython/d; /^check\//d; }' configure.ac \
          && rm -rf doc check intl po debianold debian examples \
          && touch src/js.h src/js.c \
          && ( ./autogen.sh 2>/dev/null || autoreconf -fi ) \
          && CONFIG_SHELL="$BREW_BASH" "$BREW_BASH" ./configure --prefix="$prefix" \
                --disable-fltk --disable-cocoa --disable-ao --disable-gsl \
                --disable-lapack --disable-pari --disable-ntl --disable-glpk \
                --disable-samplerate --disable-curl --disable-gettext \
                --disable-micropy --disable-quickjs --disable-png \
                --disable-ecm --disable-bernmm --disable-sscl --disable-dl \
                --disable-shared --enable-static \
                CC="$CC_BIN" CXX="$CXX_BIN" \
                CXXFLAGS="-O2 -std=gnu++17 -mmacosx-version-min=13.0" \
                CPPFLAGS="-I$prefix/include" \
                LDFLAGS="-L$prefix/lib" \
          && make -C src libgiac.la -j"$JOBS" \
          && make -C src install-libLTLIBRARIES install-data \
                 install-giacincludeHEADERS DESTDIR= )
        # autotools may name it .a directly in .libs; normalize.
        if [[ ! -f "$prefix/lib/libgiac.a" ]]; then
            found="$(find "$buildroot/giac/src/.libs" -name 'libgiac*.a' | head -1 || true)"
            [[ -n "$found" ]] && mkdir -p "$prefix/lib" && cp "$found" "$prefix/lib/libgiac.a"
        fi
        [[ -f "$prefix/lib/libgiac.a" ]] || { echo "giac build failed"; exit 1; }
    fi

    # --- helper
    log "typstedit-cas ($arch)"
    clang++ -std=gnu++17 -O2 -arch "$arch" -mmacosx-version-min=13.0 \
        "$REPO_ROOT/Tools/cas/typstedit-cas.cpp" \
        -I"$prefix/include" \
        -o "$CAS_ROOT/typstedit-cas-$arch" \
        "$prefix/lib/libgiac.a" "$prefix/lib/libmpfr.a" "$prefix/lib/libgmp.a" \
        -lz -lm -lpthread \
        -framework CoreFoundation -framework Accelerate
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
        -output "$CAS_ROOT/typstedit-cas"
else
    cp "$CAS_ROOT/typstedit-cas-${ARCHS[0]}" "$CAS_ROOT/typstedit-cas"
fi

chmod +x "$CAS_ROOT/typstedit-cas"
log "Done: $CAS_ROOT/typstedit-cas"
"$CAS_ROOT/typstedit-cas" <<'EOF'
{"v":1,"id":1,"op":"eval","input":"solve(x^2-4=0,x)","angle":"rad","digits":12}
{"v":1,"id":2,"op":"shutdown"}
EOF
