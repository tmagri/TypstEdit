#!/bin/bash
# verify_bundle.sh - fail-closed verifier for a packaged TypstEdit.app.
#
# Usage:
#   Tools/packaging/verify_bundle.sh APP_BUNDLE [ARCH...]
#
#   APP_BUNDLE  Path to the .app to check (before or after signing).
#   ARCH       Architectures the bundle must support, e.g. "arm64" or
#              "arm64 x86_64". Defaults to the architectures of the main
#              executable.
#
# Checks (any ERROR exits 1):
#   - Contents/Info.plist, CFBundleExecutable, LSMinimumSystemVersion.
#   - The main binary, Contents/Resources/bin/typst, the CAS helper
#     Contents/Resources/bin/typstedit-cas, vector.framework (preferred in
#     Contents/Frameworks), and at least one *.bundle resource bundle.
#   - Every Mach-O slice supports every requested architecture.
#   - Every Mach-O's macOS minimum OS version is recorded per slice and does
#     not exceed the LSMinimumSystemVersion the bundle advertises. The
#     verifier does not invent a floor: it compares the declaration with
#     reality.
#   - Non-weak Swift compatibility libraries (for example
#     @rpath/libswiftCompatibilitySpan.dylib) resolve to a real, non-symlink
#     Mach-O inside Contents/Frameworks with the requested slices - never to
#     the /usr/lib/swift shared-cache stub.
#   - Every non-system dependency resolves inside the bundle; weak links may
#     be absent but are reported.
#   - No LC_RPATH or LC_LOAD_DYLIB references build-machine locations
#     (/Users, /opt/homebrew, /usr/local, Xcode toolchains, .build, ...) and
#     no rpath escapes the bundle.
#   - No dangling or escaping symlinks inside the bundle.
#
# It never modifies the bundle and never claims notarization, quarantine or
# Gatekeeper status. Those are separate, explicit release steps.
#
# Requires: macOS and python3 (Xcode or Command Line Tools). Bash 3.2
# compatible.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
INSPECT="$SCRIPT_DIR/lib/macho_inspect.py"
PYTHON=${PYTHON:-python3}

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() {
    printf 'verify_bundle: ERROR: %s\n' "$*" >&2
    exit 1
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage 0
fi

if [ $# -lt 1 ]; then
    usage 2
fi

APP_BUNDLE=$1
shift

[ -d "$APP_BUNDLE" ] || die "app bundle not found: $APP_BUNDLE"
command -v "$PYTHON" >/dev/null 2>&1 || die "python3 is required (install Command Line Tools)"

exec "$PYTHON" "$INSPECT" verify "$APP_BUNDLE" "$@"
