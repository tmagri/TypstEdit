# Packaging helpers

Reusable, independent helpers for packaging the TypstEdit `.app` bundle. They
are intentionally not wired into `bundle.sh` / `bundle_universal.sh`: call
them from the release pipeline at the point described below.

Both helpers operate on an already assembled bundle. They do **not** build
the app, copy resources, change deployment targets, sign for distribution,
create a DMG or make notarization/Gatekeeper claims.

## Host requirements

- macOS with Xcode or Command Line Tools (provides `python3`, `lipo`,
  `install_name_tool`, `codesign`, `plutil`).
- Universal (`arm64 x86_64`) output needs the full Xcode toolchain: the
  Command Line Tools runtime copy of `libswiftCompatibilitySpan.dylib`
  contains only `arm64`/`arm64e`. Set `DEVELOPER_DIR` to Xcode (for example
  `/Applications/Xcode.app/Contents/Developer`) or make Xcode the default
  with `xcode-select`.
- Bash 3.2 compatible (macOS `/bin/bash`).

## Order of operations

```
build products
  -> assemble TypstEdit.app (Contents/MacOS, Contents/Frameworks, Contents/Resources)
  -> Tools/packaging/prepare_bundle.sh TypstEdit.app arm64 x86_64
  -> sign inside-out (helpers, frameworks, dylibs, then the app)
  -> Tools/packaging/verify_bundle.sh TypstEdit.app arm64 x86_64
  -> optional: verify again on the signed artifact, build the DMG
```

`prepare_bundle.sh` must run **before** final signing. It re-signs ad-hoc only
the Mach-O files whose load commands it changed, so an unsigned intermediate
bundle is still launchable. The caller remains responsible for signing
inside-out (`Contents/Resources/bin/*`, every `Contents/Frameworks` binary,
`vector.framework`, then the app) and for notarization.

## prepare_bundle.sh

```
Tools/packaging/prepare_bundle.sh APP_BUNDLE [ARCH...]
```

- `APP_BUNDLE`: assembled `.app` (must contain `Contents/Info.plist` and
  `Contents/MacOS/<CFBundleExecutable>`).
- `ARCH`: `arm64`, `x86_64`, `arm64e`; comma or space separated. Defaults to
  the architectures of the main executable.

Exit status: `0` on success, `1` on any failure, `2` for usage errors.

What it does:

1. **Toolchain lookup.** Uses `DEVELOPER_DIR` when set (and fails if it is
   invalid). Otherwise prefers `/Applications/Xcode.app/Contents/Developer`,
   then `xcode-select -p`.
2. **Swift runtime closure.** Scans every Mach-O in the bundle and finds
   non-weak references to Swift runtime compatibility libraries (today
   `@rpath/libswiftCompatibilitySpan.dylib`). It asks the selected
   toolchain's `swift-stdlib-tool --copy --scan-executable ...` to place the
   required libraries in `Contents/Frameworks`, then fills any gap with an
   explicit copy from the toolchain's `usr/lib/swift-*/macosx`.
3. **Real files, right slices.** Rejects symlinks (the `/usr/lib/swift`
   shared-cache stubs cannot be shipped), verifies every requested slice is
   present, and thins each library to exactly the requested architectures.
   A toolchain that cannot provide a slice aborts with an actionable error
   instead of producing a bundle that crashes on the other Mac.
4. **Portable rpaths.** Adds `@executable_path/../Frameworks` to the main
   executable (required), and best-effort `@loader_path`-relative rpaths to
   helpers, framework binaries and dylibs that have `@rpath` dependencies.
   Deletes absolute rpaths that do not point into the OS
   (`/usr/lib`, `/System`, `/Library/Apple`), which removes Xcode toolchain
   and build-directory rpaths from the app and from every bundled
   non-system Mach-O. If a helper cannot grow its load commands (missing
   `-headerpad_max_install_names`), the rpath is optional: dyld falls back to
   the main executable's rpaths, so this is a warning, not a failure.
5. **Provenance/licensing.** Writes
   `Contents/Resources/Licenses/SwiftRuntime-NOTICE.txt` with the toolchain
   path, Swift version, each bundled library's architecture slices, minimum
   OS version, SHA-256 and path. Copies `LICENSE`/`NOTICE`/`COPYING` files
   verbatim when the selected toolchain ships them next to the runtime;
   otherwise it records provenance and the upstream Apache-2.0 reference
   only. It never invents license text and never claims Apple approval.
6. **Deployment target is untouched.** It does not run `vtool` or any
   `-set-version-min` command. A Mach-O minimum OS version can only be
   changed honestly by recompiling; lowering it here would be a lie that
   crashes on launch.

## verify_bundle.sh

```
Tools/packaging/verify_bundle.sh APP_BUNDLE [ARCH...]
```

Exit status: `0` when every check passes, `1` when any ERROR is found, `2`
for usage/tooling errors. It never modifies the bundle.

Checks:

| Area | Failure condition |
| --- | --- |
| Layout | `Contents/Info.plist`, `CFBundleExecutable` or `LSMinimumSystemVersion` missing; main binary missing; `Contents/Resources/bin/typst` missing; `Contents/Resources/bin/typstedit-cas` missing; `Contents/Frameworks/vector.framework` missing (a legacy copy in `Contents/MacOS` is accepted with a warning); no `*.bundle` resource bundles in `Contents/Resources`. |
| Architectures | Any Mach-O in the bundle lacks one of the requested slices (default: the main binary's slices). |
| Minimum OS | Any Mach-O slice requires a macOS version greater than `LSMinimumSystemVersion`. The per-slice values are printed, so the declaration can be compared with reality. The verifier imposes no floor of its own: a helper built for macOS 11/13 passes at 13 as long as the bundle declares at least that. |
| Swift compatibility runtime | A non-weak `libswiftCompatibility*.dylib` reference does not resolve to a real, non-symlink Mach-O inside the bundle with the requested slices. OS shared-cache stubs and symlinks are rejected. |
| Dependencies | A non-weak non-system dependency does not resolve inside the bundle. Weak links may be absent and are reported as warnings. |
| Portability | Any `LC_RPATH` or `LC_LOAD_DYLIB` pointing at `/Users`, `/Volumes`, `/opt`, `/usr/local`, `/Applications/*Xcode`, `/Library/Developer`, `.build`, `DerivedData`, `SourcePackages` or `checkouts`; any absolute dependency outside the OS (`/usr/lib`, `/System`, `/Library/Apple`); any `@loader_path`/`@executable_path` rpath escaping the bundle; dangling or escaping symlinks. |

The output lists every Mach-O with its per-slice minimum OS version, then
`NOTE:`, `WARN:` and `ERROR:` lines and a `Verification PASSED/FAILED`
summary. No claims are made about code signing, notarization, quarantine or
Gatekeeper: those are separate release steps.

## lib/macho_inspect.py

Python 3 standard library only; parses Mach-O/fat headers and load commands
directly (no `otool`), so it is stable around the dyld shared cache. Used by
both helpers; also useful on its own:

```
python3 lib/macho_inspect.py info FILE [--json]     # slices, dylibs, rpaths, minOS
python3 lib/macho_inspect.py archs FILE             # one arch per line
python3 lib/macho_inspect.py rpaths FILE
python3 lib/macho_inspect.py dylibs FILE            # "strong|weak<TAB>install name"
python3 lib/macho_inspect.py minos FILE             # "arch<TAB>macOS minOS"
python3 lib/macho_inspect.py required-swift-libs FILE
python3 lib/macho_inspect.py find-machos ROOT
python3 lib/macho_inspect.py rel-up FROM_DIR TO_DIR # @loader_path form
python3 lib/macho_inspect.py verify APP [ARCH...]
```

`rel-up`, `archs`, `minos` and friends are line-oriented on purpose so the
Bash 3.2 wrappers can consume them without JSON parsing.

## Tests

```
Tools/packaging/tests/run_tests.sh
```

The suite builds tiny real Mach-O fixtures with `clang` (universal and thin,
dylib-based `vector.framework`, a compatibility-library dependency rewritten
to `@rpath`) and asserts behaviour; it exits non-zero if any assertion fails.
It requires full Xcode for the universal-Swift-library case (skipped
automatically when only Command Line Tools are available).

Covered failures: missing Swift compatibility dependency, wrong architecture,
minimum-OS mismatch, non-portable rpath, non-portable dependency path,
symlinked OS stub, missing main/Typst/CAS/vector/resource bundles; plus
prepare's copy, thinning, rpath cleanup, minOS preservation, idempotency and
a toolchain that lacks a requested slice.

Two regression tests use the repository's current `TypstEdit.app`: it must
fail verification, and a copy prepared by `prepare_bundle.sh` (with
`vector.framework` moved to `Contents/Frameworks`) must fail only on the
truthful minimum-OS mismatch caused by the current `vector` binary.

## Out of scope (parent pipeline responsibilities)

- Rebuilding `vector.framework` with a macOS 13 deployment target.
- Deciding the final `LSMinimumSystemVersion` policy (needs a product
  decision) and the matching `-mmacosx-version-deployment` flags.
- Resource paths, CAS deployment, universal DMG creation, signing identity,
  notarization and Gatekeeper validation.
