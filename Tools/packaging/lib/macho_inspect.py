#!/usr/bin/env python3
"""macho_inspect.py - standard-library-only Mach-O inspection for TypstEdit packaging.

This tool is part of the *development* packaging pipeline. It parses Mach-O
headers and load commands directly (fat/thin, 32/64-bit, either endianness)
so it does not depend on otool-classic, which is known to be quirky around
the dyld shared cache and toolchain libraries.

It requires only python3 from the host (Xcode or Command Line Tools provide
python3 on modern macOS; `xcode-select --install` is enough).

Subcommands (all output is plain line-oriented text for Bash 3.2):
  info FILE [--json]      full machine-readable report for one Mach-O
  archs FILE              one architecture name per line
  rpaths FILE             deduplicated LC_RPATH values
  dylibs FILE             "<weak|strong>\t<install name>" for every dependency
  minos FILE              "<arch>\t<macOS minimum OS version>" per slice
  required-swift-libs F   basenames of Swift runtime dylibs that must be
                          bundled inside the app (non-weak compatibility libs)
  find-machos ROOT        every regular Mach-O file under ROOT, one per line
  rel-up FROM TO          print "@loader_path/<relative path FROM -> TO>"
  verify APP [ARCH...]    full bundle verification; exit 1 on any ERROR

The verifier never modifies a bundle. prepare_bundle.sh is the only helper
that mutates Mach-O load commands (rpaths), and it never touches minOS.
"""

import json
import os
import plistlib
import re
import struct
import sys

LC_REQ_DYLD = 0x80000000
LC_LOAD_DYLIB = 0x0C
LC_ID_DYLIB = 0x0D
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24

# kind -> weak?
DYLIB_COMMANDS = {
    LC_LOAD_DYLIB: False,
    LC_LOAD_WEAK_DYLIB: True,
    LC_REEXPORT_DYLIB: False,
    LC_LAZY_LOAD_DYLIB: False,
    LC_LOAD_UPWARD_DYLIB: False,
}

PLATFORM_NAMES = {
    1: "MACOS",
    2: "IOS",
    3: "TVOS",
    4: "WATCHOS",
    5: "BRIDGEOS",
    6: "MACCATALYST",
    7: "IOSSIMULATOR",
    8: "TVOSSIMULATOR",
    9: "WATCHOSSIMULATOR",
    10: "DRIVERKIT",
    11: "VISIONOS",
    12: "VISIONOS_SIMULATOR",
}

FAT_MAGICS = {
    b"\xca\xfe\xba\xbe": (">", False),  # FAT_MAGIC
    b"\xca\xfe\xba\xbf": (">", True),   # FAT_MAGIC_64
}
THIN_MAGICS = {
    b"\xcf\xfa\xed\xfe": ("<", True),   # MH_MAGIC_64
    b"\xfe\xed\xfa\xcf": (">", True),   # MH_CIGAM_64
    b"\xce\xfa\xed\xfe": ("<", False),  # MH_MAGIC
    b"\xfe\xed\xfa\xce": (">", False),  # MH_CIGAM
}
MACHO_MAGICS = tuple(FAT_MAGICS) + tuple(THIN_MAGICS)

CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_X86 = 7
CPU_TYPE_ARM = 12
CPU_TYPE_X86_64 = CPU_TYPE_X86 | CPU_ARCH_ABI64
CPU_TYPE_ARM64 = CPU_TYPE_ARM | CPU_ARCH_ABI64
CPU_SUBTYPE_MASK = 0x00FFFFFF
CPU_SUBTYPE_ARM64E = 2

#: Anything that absolute-path-wise is NOT covered by these prefixes is
#: considered non-portable to ship inside an app bundle.
SYSTEM_PREFIXES = (
    "/usr/lib/",
    "/usr/libexec/",
    "/usr/share/",
    "/System/",
    "/Library/Apple/",
    "/bin/",
    "/sbin/",
)

#: Explicit fingerprints of build-machine leakage; these are always errors.
BAD_ABSOLUTE_RE = re.compile(
    r"^(/Users/|/Volumes/|/private/|/opt/|/usr/local/|/Applications/[^/]*Xcode|"
    r"/Library/Developer/|/var/folders/)"
)
BAD_FRAGMENT_RE = re.compile(r"(/\.build/|/DerivedData/|/SourcePackages/|/checkouts/)")


class MachOError(Exception):
    pass


def arch_name(cputype, cpusubtype):
    subtype = cpusubtype & CPU_SUBTYPE_MASK
    if cputype == CPU_TYPE_ARM64:
        return "arm64e" if subtype == CPU_SUBTYPE_ARM64E else "arm64"
    if cputype == CPU_TYPE_X86_64:
        return "x86_64"
    if cputype == CPU_TYPE_ARM:
        return "arm"
    if cputype == CPU_TYPE_X86:
        return "i386"
    return "cpu%d_%d" % (cputype, subtype)


def decode_version(value):
    return "%d.%d.%d" % (value >> 16, (value >> 8) & 0xFF, value & 0xFF)


def short_version(text):
    """'13.0.0' -> '13.0' (keep three components only when needed)."""
    parts = [int(p) for p in text.split(".")] + [0, 0]
    if parts[2]:
        return "%d.%d.%d" % (parts[0], parts[1], parts[2])
    return "%d.%d" % (parts[0], parts[1])


def version_tuple(text):
    out = []
    for piece in text.split("."):
        piece = piece.strip()
        out.append(int(piece) if piece.isdigit() else 0)
    while len(out) < 3:
        out.append(0)
    return tuple(out[:3])


def _read_cstr(blob, offset):
    if offset < 0 or offset >= len(blob):
        return ""
    end = blob.find(b"\x00", offset)
    if end < 0:
        end = len(blob)
    return blob[offset:end].decode("utf-8", "replace")


def _parse_load_commands(cmds, endian):
    dylibs = []
    rpaths = []
    build_versions = []
    version_min = []
    offset = 0
    total = len(cmds)
    while offset + 8 <= total:
        cmd, cmdsize = struct.unpack_from(endian + "II", cmds, offset)
        if cmdsize < 8 or offset + cmdsize > total:
            raise MachOError("corrupt load command (cmd=0x%x size=%d)" % (cmd, cmdsize))
        blob = cmds[offset:offset + cmdsize]
        if cmd in DYLIB_COMMANDS:
            name_off = struct.unpack_from(endian + "I", blob, 8)[0]
            if cmd != LC_ID_DYLIB:
                dylibs.append({
                    "name": _read_cstr(blob, name_off),
                    "weak": DYLIB_COMMANDS[cmd],
                })
        elif cmd == LC_RPATH:
            path_off = struct.unpack_from(endian + "I", blob, 8)[0]
            rpaths.append(_read_cstr(blob, path_off))
        elif cmd == LC_BUILD_VERSION and cmdsize >= 24:
            platform, minos, sdk, ntools = struct.unpack_from(endian + "IIII", blob, 8)
            build_versions.append({
                "platform": PLATFORM_NAMES.get(platform, "PLATFORM_%d" % platform),
                "minos": decode_version(minos),
                "sdk": decode_version(sdk),
            })
        elif cmd == LC_VERSION_MIN_MACOSX and cmdsize >= 16:
            minos, sdk = struct.unpack_from(endian + "II", blob, 8)
            version_min.append({
                "platform": "MACOS",
                "minos": decode_version(minos),
                "sdk": decode_version(sdk),
            })
        offset += cmdsize
    return dylibs, rpaths, build_versions, version_min


def _parse_slice(f, base, size):
    f.seek(base)
    magic_bytes = f.read(4)
    if magic_bytes not in THIN_MAGICS:
        raise MachOError("not a thin Mach-O slice")
    endian, is64 = THIN_MAGICS[magic_bytes]
    head_rest = 28 if is64 else 24
    rest = f.read(head_rest)
    if len(rest) < head_rest:
        raise MachOError("truncated Mach-O header")
    cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack(
        endian + "iiIIII", rest[:24]
    )
    # header is 32 bytes for 64-bit (incl. reserved) and 28 for 32-bit
    cmd_bytes = f.read(sizeofcmds)
    if len(cmd_bytes) < sizeofcmds:
        raise MachOError("truncated load commands")
    dylibs, rpaths, build_versions, version_min = _parse_load_commands(cmd_bytes, endian)
    macos_versions = []
    for entry in build_versions + version_min:
        if entry["platform"] == "MACOS":
            macos_versions.append(entry["minos"])
    slice_info = {
        "arch": arch_name(cputype, cpusubtype),
        "cputype": cputype,
        "cpusubtype": cpusubtype,
        "filetype": filetype,
        "platforms": build_versions + version_min,
        "minos": short_version(max(macos_versions, key=version_tuple)) if macos_versions else None,
        "dylibs": dylibs,
        "rpaths": rpaths,
    }
    return slice_info


def inspect(path):
    """Return a report dict for a Mach-O file (or raise MachOError)."""
    report = {
        "path": path,
        "is_symlink": os.path.islink(path),
        "slices": [],
        "archs": [],
    }
    if report["is_symlink"]:
        raise MachOError("refusing to parse symlink: %s" % path)
    with open(path, "rb") as f:
        head = f.read(8)
        if len(head) < 8:
            raise MachOError("file too small")
        magic_bytes, fat_endian, fat64 = None, None, False
        for magic, (endian, is64) in FAT_MAGICS.items():
            if head[:4] == magic:
                magic_bytes, fat_endian, fat64 = magic, endian, is64
                break
        if magic_bytes:
            nfat = struct.unpack_from(fat_endian + "I", head, 4)[0]
            if nfat == 0 or nfat > 64:
                raise MachOError("implausible fat slice count %d" % nfat)
            f.seek(8)
            entries = []
            for _ in range(nfat):
                if fat64:
                    raw = f.read(32)
                    if len(raw) < 32:
                        raise MachOError("truncated fat header")
                    cputype, cpusubtype, offset, size, _align, _res = struct.unpack(
                        fat_endian + "iiQQII", raw
                    )
                else:
                    raw = f.read(20)
                    if len(raw) < 20:
                        raise MachOError("truncated fat header")
                    cputype, cpusubtype, offset, size, _align = struct.unpack(
                        fat_endian + "iiIII", raw
                    )
                entries.append((cputype, cpusubtype, offset, size))
            for cputype, cpusubtype, offset, size in entries:
                try:
                    slice_info = _parse_slice(f, offset, size)
                except MachOError:
                    continue
                report["slices"].append(slice_info)
        else:
            report["slices"].append(_parse_slice(f, 0, None))
    if not report["slices"]:
        raise MachOError("no readable Mach-O slices")
    seen = []
    for entry in report["slices"]:
        if entry["arch"] not in seen:
            seen.append(entry["arch"])
    report["archs"] = seen
    return report


def is_macho_file(path):
    try:
        with open(path, "rb") as f:
            return f.read(4) in MACHO_MAGICS
    except OSError:
        return False


def walk_machos(root):
    """Yield regular (non-symlink) Mach-O files under root in stable order."""
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not os.path.islink(os.path.join(dirpath, d)))
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            if is_macho_file(path):
                found.append(path)
    return found


def merged_dylibs(report):
    """Union dylib dependencies across slices; weak only if weak everywhere."""
    merged = {}
    order = []
    for slice_info in report["slices"]:
        for dep in slice_info["dylibs"]:
            key = dep["name"]
            if key not in merged:
                merged[key] = dep["weak"]
                order.append(key)
            else:
                merged[key] = merged[key] and dep["weak"]
    return [(name, merged[name]) for name in order]


def merged_rpaths(report):
    seen = []
    for slice_info in report["slices"]:
        for rp in slice_info["rpaths"]:
            if rp not in seen:
                seen.append(rp)
    return seen


def macos_minos_map(report):
    out = {}
    for slice_info in report["slices"]:
        arch = slice_info["arch"]
        version = slice_info["minos"]
        if version is None:
            continue
        if arch not in out or version_tuple(version) > version_tuple(out[arch]):
            out[arch] = version
    return out


# ---------------------------------------------------------------------------
# Path classification
# ---------------------------------------------------------------------------

def normalize_arch_list(values):
    archs = []
    for value in values:
        for piece in value.replace(",", " ").split():
            if piece and piece not in archs:
                archs.append(piece)
    return archs


def is_system_path(path):
    if path.startswith("/"):
        return path.startswith(SYSTEM_PREFIXES) or path == "/usr/lib"
    return False


def path_portability_problem(path):
    """Return a human readable reason if an absolute path is not portable."""
    if not path.startswith("/"):
        return None
    if is_system_path(path):
        return None
    if BAD_ABSOLUTE_RE.match(path):
        return "build-machine absolute path"
    if BAD_FRAGMENT_RE.search(path):
        return "absolute build directory path"
    return "absolute path outside the OS"


def expand_path_template(template, loader_dir, exec_dir):
    return template.replace("@loader_path", loader_dir).replace(
        "@executable_path", exec_dir
    )


def inside(path, root):
    path = os.path.realpath(path)
    root = os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


# ---------------------------------------------------------------------------
# Verifier
# ---------------------------------------------------------------------------

class Findings(object):
    def __init__(self):
        self.errors = []
        self.warnings = []
        self.notes = []

    def error(self, message):
        self.errors.append(message)

    def warn(self, message):
        self.warnings.append(message)

    def note(self, message):
        self.notes.append(message)


def load_plist(path):
    with open(path, "rb") as handle:
        return plistlib.load(handle)


def find_framework_binary(framework_dir):
    """Locate the Mach-O executable of a .framework directory."""
    candidates = []
    plist_paths = [
        os.path.join(framework_dir, "Resources", "Info.plist"),
        os.path.join(framework_dir, "Versions", "Current", "Resources", "Info.plist"),
    ]
    versions_dir = os.path.join(framework_dir, "Versions")
    if os.path.isdir(versions_dir):
        for name in sorted(os.listdir(versions_dir)):
            plist_paths.append(
                os.path.join(versions_dir, name, "Resources", "Info.plist")
            )
    bundle_name = os.path.basename(framework_dir)
    if bundle_name.endswith(".framework"):
        bundle_name = bundle_name[: -len(".framework")]
    for plist_path in plist_paths:
        if os.path.isfile(plist_path):
            try:
                info = load_plist(plist_path)
                executable = info.get("CFBundleExecutable")
            except Exception:
                executable = None
            if executable:
                for base in (
                    framework_dir,
                    os.path.join(framework_dir, "Versions", "Current"),
                ):
                    candidate = os.path.join(base, executable)
                    if os.path.isfile(candidate) and not os.path.islink(candidate):
                        candidates.append(candidate)
                if os.path.isdir(versions_dir):
                    for name in sorted(os.listdir(versions_dir)):
                        candidate = os.path.join(versions_dir, name, executable)
                        if os.path.isfile(candidate) and not os.path.islink(candidate):
                            candidates.append(candidate)
    if not candidates:
        # Fallback: any Mach-O directly inside the framework whose name matches.
        for dirpath, _dirnames, filenames in os.walk(framework_dir):
            if os.path.islink(dirpath):
                continue
            for name in filenames:
                path = os.path.join(dirpath, name)
                if os.path.islink(path):
                    continue
                if name == bundle_name and is_macho_file(path):
                    candidates.append(path)
    return candidates[0] if candidates else None


def verify_bundle(app, arch_args):
    app = os.path.abspath(app)
    findings = Findings()
    contents = os.path.join(app, "Contents")
    macos_dir = os.path.join(contents, "MacOS")
    frameworks_dir = os.path.join(contents, "Frameworks")
    resources_dir = os.path.join(contents, "Resources")
    plist_path = os.path.join(contents, "Info.plist")

    if not os.path.isdir(app):
        findings.error("bundle does not exist: %s" % app)
        return findings, None

    # --- Info.plist -------------------------------------------------------
    info = None
    if not os.path.isfile(plist_path):
        findings.error("missing Contents/Info.plist")
    else:
        try:
            info = load_plist(plist_path)
        except Exception as exc:
            findings.error("Contents/Info.plist is unreadable: %s" % exc)
    executable_name = None
    declared_minos = None
    if info is not None:
        executable_name = info.get("CFBundleExecutable")
        if not executable_name:
            findings.error("Info.plist has no CFBundleExecutable")
        declared_minos = info.get("LSMinimumSystemVersion")
        if not declared_minos:
            findings.error("Info.plist has no LSMinimumSystemVersion")
        elif not re.match(r"^\d+(\.\d+){0,2}$", str(declared_minos)):
            findings.error(
                "Info.plist LSMinimumSystemVersion is not a version: %r"
                % (declared_minos,)
            )
            declared_minos = None
    else:
        findings.error("cannot resolve the main executable without Info.plist")

    # --- main executable --------------------------------------------------
    main_binary = None
    if executable_name:
        main_binary = os.path.join(macos_dir, executable_name)
        if not os.path.isfile(main_binary):
            findings.error("missing main binary Contents/MacOS/%s" % executable_name)
            main_binary = None
        elif not is_macho_file(main_binary):
            findings.error("Contents/MacOS/%s is not a Mach-O binary" % executable_name)
            main_binary = None
        elif os.path.islink(main_binary):
            findings.error("Contents/MacOS/%s is a symlink, not a real binary" % executable_name)
            main_binary = None

    # --- expected architectures ------------------------------------------
    expected_archs = normalize_arch_list(arch_args)
    if not expected_archs and main_binary:
        try:
            expected_archs = inspect(main_binary)["archs"]
        except MachOError as exc:
            findings.error("cannot read architectures of main binary: %s" % exc)
    if not expected_archs:
        findings.error("no architectures supplied and none could be derived")
        return findings, None
    for arch in expected_archs:
        if arch not in ("arm64", "x86_64", "arm64e"):
            findings.error("unsupported requested architecture: %s" % arch)

    # --- required layout --------------------------------------------------
    required_files = [
        ("Typst helper", os.path.join(resources_dir, "bin", "typst")),
        ("CAS helper", os.path.join(resources_dir, "bin", "typstedit-cas")),
    ]
    for label, path in required_files:
        rel = os.path.relpath(path, app)
        if not os.path.isfile(path):
            findings.error("missing %s (%s)" % (label, rel))
        elif not is_macho_file(path):
            findings.error("%s (%s) is not a Mach-O binary" % (label, rel))
        elif not os.access(path, os.X_OK):
            findings.warn("%s (%s) is not executable" % (label, rel))

    vector_dir = os.path.join(frameworks_dir, "vector.framework")
    legacy_vector_dir = os.path.join(macos_dir, "vector.framework")
    vector_binary = None
    if os.path.isdir(vector_dir):
        vector_binary = find_framework_binary(vector_dir)
        if not vector_binary:
            findings.error(
                "Contents/Frameworks/vector.framework has no Mach-O executable"
            )
        else:
            findings.note("vector.framework found in Contents/Frameworks")
    elif os.path.isdir(legacy_vector_dir):
        vector_binary = find_framework_binary(legacy_vector_dir)
        findings.warn(
            "vector.framework is in the legacy Contents/MacOS location; "
            "Contents/Frameworks/vector.framework is the supported layout"
        )
        if not vector_binary:
            findings.error("Contents/MacOS/vector.framework has no Mach-O executable")
    else:
        findings.error(
            "missing vector.framework (expected Contents/Frameworks/vector.framework)"
        )

    resource_bundles = []
    if os.path.isdir(resources_dir):
        for name in sorted(os.listdir(resources_dir)):
            path = os.path.join(resources_dir, name)
            if name.endswith(".bundle") and os.path.isdir(path):
                resource_bundles.append(path)
    if not resource_bundles:
        findings.error(
            "no *.bundle resource bundles found in Contents/Resources"
        )
    else:
        findings.note(
            "resource bundles: %s" % ", ".join(os.path.basename(p) for p in resource_bundles)
        )

    # --- symlinks inside the bundle --------------------------------------
    for dirpath, dirnames, filenames in os.walk(contents):
        for name in list(dirnames) + list(filenames):
            path = os.path.join(dirpath, name)
            if not os.path.islink(path):
                continue
            rel = os.path.relpath(path, app)
            if not os.path.exists(path):
                findings.error("dangling symlink in bundle: %s" % rel)
            elif not inside(path, app):
                findings.error(
                    "symlink escapes the bundle: %s -> %s"
                    % (rel, os.readlink(path))
                )
            elif os.path.basename(path).startswith("libswift"):
                findings.error(
                    "Swift runtime symlink %s points outside the bundle (%s); "
                    "it would be an OS stub after packaging"
                    % (rel, os.readlink(path))
                )

    # --- collect every Mach-O image --------------------------------------
    image_paths = []
    if main_binary:
        image_paths.append(main_binary)
    for _label, path in required_files:
        if os.path.isfile(path) and is_macho_file(path) and not os.path.islink(path):
            image_paths.append(path)
    for path in walk_machos(contents):
        real = os.path.realpath(path)
        if real not in [os.path.realpath(p) for p in image_paths]:
            image_paths.append(path)

    images = []
    for path in image_paths:
        try:
            images.append(inspect(path))
        except MachOError as exc:
            findings.error(
                "cannot parse Mach-O %s: %s" % (os.path.relpath(path, app), exc)
            )

    if main_binary:
        try:
            main_report = inspect(main_binary)
        except MachOError:
            main_report = None
    else:
        main_report = None
    main_rpaths = merged_rpaths(main_report) if main_report else []
    exec_dir = macos_dir

    # --- per-image checks -------------------------------------------------
    def rel(path):
        return os.path.relpath(path, app)

    compat_requirements = []  # (image_rel, install name, weak, image)

    for report in images:
        path = report["path"]
        image_rel = rel(path)
        loader_dir = os.path.dirname(path)

        for arch in expected_archs:
            if arch not in report["archs"]:
                findings.error(
                    "wrong architecture: %s is missing %s (has: %s)"
                    % (image_rel, arch, ", ".join(report["archs"]) or "none")
                )

        for arch, minos in sorted(macos_minos_map(report).items()):
            if declared_minos and version_tuple(minos) > version_tuple(str(declared_minos)):
                findings.error(
                    "LSMinimumSystemVersion is %s but %s (%s slice) requires macOS %s"
                    % (declared_minos, image_rel, arch, minos)
                )

        image_rpaths = merged_rpaths(report)
        for rpath in image_rpaths:
            problem = path_portability_problem(rpath)
            if problem:
                findings.error(
                    "non-portable rpath in %s: %s (%s)" % (image_rel, rpath, problem)
                )
                continue
            if not rpath.startswith("@"):
                continue
            resolved = expand_path_template(rpath, loader_dir, exec_dir)
            if not inside(resolved, app):
                findings.error(
                    "rpath escapes the bundle in %s: %s -> %s"
                    % (image_rel, rpath, os.path.normpath(resolved))
                )

        for name, weak in merged_dylibs(report):
            basename = os.path.basename(name)
            is_compat = basename.startswith("libswiftCompatibility")

            problem = path_portability_problem(name)
            if problem:
                findings.error(
                    "non-portable dependency in %s: %s (%s)"
                    % (image_rel, name, problem)
                )
                continue

            resolved = None
            if name.startswith("@rpath/"):
                suffix = name[len("@rpath/"):]
                candidates = image_rpaths + [
                    rp for rp in main_rpaths if rp not in image_rpaths
                ]
                for rpath in candidates:
                    expanded = expand_path_template(rpath, loader_dir, exec_dir)
                    candidate = os.path.join(expanded, suffix)
                    if os.path.isfile(candidate):
                        resolved = candidate
                        break
            elif name.startswith("@executable_path/") or name.startswith("@loader_path/"):
                candidate = expand_path_template(name, loader_dir, exec_dir)
                if os.path.isfile(candidate):
                    resolved = candidate
            elif name.startswith("/"):
                if is_system_path(name):
                    resolved = name  # dyld shared cache
                elif os.path.isfile(name):
                    resolved = name

            if resolved is None:
                if weak:
                    findings.warn(
                        "weak dependency does not resolve in %s: %s"
                        % (image_rel, name)
                    )
                else:
                    findings.error(
                        "unresolved non-system dependency in %s: %s"
                        % (image_rel, name)
                    )
            elif not is_system_path(resolved):
                if not inside(resolved, app):
                    findings.error(
                        "dependency of %s resolves outside the bundle: %s -> %s"
                        % (image_rel, name, rel(resolved)
                           if inside(resolved, app) else resolved)
                    )
                elif is_compat and os.path.islink(resolved):
                    findings.error(
                        "Swift compatibility library %s is a symlink inside the bundle"
                        % rel(resolved)
                    )

            if is_compat:
                compat_requirements.append((image_rel, name, weak, report))
                bundled = os.path.join(frameworks_dir, basename)
                target = None
                if os.path.isfile(bundled) and not os.path.islink(bundled):
                    target = bundled
                elif resolved and not is_system_path(resolved) and inside(resolved, app):
                    target = resolved
                if target is None:
                    level = findings.warn if weak else findings.error
                    level(
                        "Swift compatibility library %s is required by %s but is "
                        "not bundled in Contents/Frameworks" % (basename, image_rel)
                    )
                else:
                    if os.path.islink(target):
                        findings.error(
                            "bundled Swift library %s is a symlink (not a real file)"
                            % rel(target)
                        )
                    try:
                        lib_report = inspect(target)
                    except MachOError as exc:
                        findings.error(
                            "bundled Swift library %s is not readable: %s"
                            % (rel(target), exc)
                        )
                        lib_report = None
                    if lib_report is not None:
                        for arch in expected_archs:
                            if arch not in lib_report["archs"]:
                                findings.error(
                                    "bundled Swift library %s is missing the %s slice "
                                    "(has: %s)"
                                    % (rel(target), arch, ", ".join(lib_report["archs"]))
                                )
                        if not inside(target, app):
                            findings.error(
                                "bundled Swift library resolves outside bundle: %s"
                                % target
                            )

    # --- summary ----------------------------------------------------------
    minos_rows = []
    for report in images:
        rows = sorted(macos_minos_map(report).items())
        if rows:
            compact = ", ".join("%s=%s" % (arch, ver) for arch, ver in rows)
            minos_rows.append((rel(report["path"]), compact))

    return findings, {
        "expected_archs": expected_archs,
        "declared_minos": declared_minos,
        "minos_rows": minos_rows,
        "images": [rel(report["path"]) for report in images],
        "main_rpaths": main_rpaths,
    }


def print_verify_result(app, findings, summary):
    print("verify_bundle: %s" % app)
    if summary:
        print("  architectures: %s" % ", ".join(summary["expected_archs"]))
        print("  LSMinimumSystemVersion: %s" % summary["declared_minos"])
        print("  Mach-O images checked: %d" % len(summary["images"]))
        for image, rows in summary["minos_rows"]:
            print("    %-60s %s" % (image, rows))
    if findings.notes:
        for message in findings.notes:
            print("NOTE: %s" % message)
    for message in findings.warnings:
        print("WARN: %s" % message)
    for message in findings.errors:
        print("ERROR: %s" % message)
    if findings.errors:
        print(
            "Verification FAILED: %d error(s), %d warning(s)"
            % (len(findings.errors), len(findings.warnings))
        )
        return 1
    print("Verification PASSED: 0 errors, %d warning(s)" % len(findings.warnings))
    return 0


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def cmd_info(path, as_json):
    report = inspect(path)
    if as_json:
        print(json.dumps(report, indent=2))
        return 0
    for slice_info in report["slices"]:
        print("slice=%s minos=%s" % (slice_info["arch"], slice_info["minos"]))
        for dep in slice_info["dylibs"]:
            print("  dylib%s %s" % (" (weak)" if dep["weak"] else "", dep["name"]))
        for rpath in slice_info["rpaths"]:
            print("  rpath %s" % rpath)
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    command = argv[1]
    args = argv[2:]

    try:
        if command == "info":
            as_json = "--json" in args
            paths = [a for a in args if a != "--json"]
            return cmd_info(paths[0], as_json)
        if command == "archs":
            print("\n".join(inspect(args[0])["archs"]))
            return 0
        if command == "rpaths":
            for rpath in merged_rpaths(inspect(args[0])):
                print(rpath)
            return 0
        if command == "dylibs":
            for name, weak in merged_dylibs(inspect(args[0])):
                print("%s\t%s" % ("weak" if weak else "strong", name))
            return 0
        if command == "minos":
            rows = sorted(macos_minos_map(inspect(args[0])).items())
            for arch, version in rows:
                print("%s\t%s" % (arch, version))
            return 0
        if command == "required-swift-libs":
            names = []
            for name, weak in merged_dylibs(inspect(args[0])):
                basename = os.path.basename(name)
                if weak:
                    continue
                if not basename.startswith("libswiftCompatibility"):
                    continue
                if basename not in names:
                    names.append(basename)
            for name in names:
                print(name)
            return 0
        if command == "find-machos":
            for path in walk_machos(args[0]):
                print(path)
            return 0
        if command == "rel-up":
            relative = os.path.relpath(args[1], args[0])
            print("@loader_path/" + relative)
            return 0
        if command == "verify":
            if not args:
                sys.stderr.write("usage: macho_inspect.py verify APP_BUNDLE [ARCH...]\n")
                return 2
            app = args[0]
            findings, summary = verify_bundle(app, args[1:])
            return print_verify_result(os.path.abspath(app), findings, summary)
    except MachOError as exc:
        sys.stderr.write("macho_inspect: %s\n" % exc)
        return 2
    except OSError as exc:
        sys.stderr.write("macho_inspect: %s\n" % exc)
        return 2

    sys.stderr.write("unknown command: %s\n" % command)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
