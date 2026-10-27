#!/bin/bash
# Prepare a fresh pinned source tree. No failed patch is silently ignored.
set -euo pipefail
if [[ $# -ne 3 ]]; then
    echo "Usage: $0 SOURCE_REPOSITORY COMMIT OUTPUT_DIRECTORY" >&2
    exit 1
fi
SOURCE="$1"
COMMIT="$2"
OUTPUT="$3"
mkdir -p "$OUTPUT"
git -C "$SOURCE" archive "$COMMIT" | tar -xf - -C "$OUTPUT"
(
    cd "$OUTPUT"
    # Only the library build fixes are relevant on macOS: a declaration fix,
    # the rules that generate input_parser.h from the Bison grammar, and the
    # configure.ac closing-statement order. The other Debian patches modify
    # Linux system libraries, GUI packaging, or documentation.
    # Follow their series order, rather than applying all patches alphabetically.
    while read -r name remainder; do
        case "$name" in
            fix_implicit_declaration.patch|missing-build-rules.patch|build_fix_to_order_closing_statements_correctly.patch)
                echo "Applying Giac library fix: $name"
                patch --batch --forward -p1 < "debian/patches/$name"
                ;;
        esac
    done < debian/patches/series
    sed -i.bak \
        -e 's/^   AM_GNU_GETTEXT$/   dnl AM_GNU_GETTEXT (disabled for the helper)/' \
        -e 's/^   AM_GNU_GETTEXT_VERSION/   dnl AM_GNU_GETTEXT_VERSION/' \
        configure.ac
    sed -i.bak -e 's/^SUBDIRS =.*/SUBDIRS = src/' \
        -e 's/^DIST_SUBDIRS =.*/DIST_SUBDIRS = src/' Makefile.am
    sed -i.bak2 '/^AC_OUTPUT(\[/,$ { /^doc\//d; /^intl\//d; /^po\//d; /^examples\//d; /^debian/d; /^micropython/d; /^check\//d; }' configure.ac
    # The pinned repository ships these generated files. Its mkjs binary is
    # Linux-only, so prevent timestamp races from triggering regeneration.
    touch src/js.h src/js.c
    autoreconf -fi
)
