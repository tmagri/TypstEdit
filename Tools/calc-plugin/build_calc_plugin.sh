#!/bin/sh
# Builds the TypstEdit calculator WASM plugin.
#
#   Tools/calc-plugin/build_calc_plugin.sh
#
# Output: build/calc/TypstEditCalc.wasm
#
# Requirements:
#   - clang with the WebAssembly backend (macOS system clang has it)
#   - wasm-ld (install with: brew install lld)
#
# The plugin is freestanding: no libc, no WASI imports, only the two
# `typst_env` host functions Typst provides. `wasm-ld --allow-undefined` turns
# those two into imports.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
out_dir="${root}/build/calc"
mkdir -p "$out_dir"

cc=${CC:-clang}
if ! command -v "$cc" >/dev/null 2>&1; then
  echo "error: clang not found (set CC)" >&2
  exit 1
fi

find_wasm_ld() {
  if [ -n "${WASM_LD:-}" ] && [ -x "${WASM_LD}" ]; then
    echo "${WASM_LD}"
    return 0
  fi
  for candidate in \
      "$(command -v wasm-ld 2>/dev/null || true)" \
      /opt/homebrew/opt/lld/bin/wasm-ld \
      /usr/local/opt/lld/bin/wasm-ld \
      /usr/local/bin/wasm-ld; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

wasm_ld=$(find_wasm_ld || true)
if [ -z "${wasm_ld:-}" ]; then
  cat >&2 <<'MSG'
error: wasm-ld not found.

Install the LLVM linker (it ships wasm-ld):
    brew install lld

Then re-run this script.
MSG
  exit 1
fi

obj_dir="${root}/build/calc/obj"
mkdir -p "$obj_dir"

echo "==> compiling calc_math.c"
"$cc" --target=wasm32 -O2 -std=c99 -ffreestanding -fno-builtin -nostdlib \
  -Wall -Wextra -Wno-unused-parameter \
  -c "$here/calc_math.c" -o "$obj_dir/calc_math.o"

echo "==> compiling calc_dispatch.c"
"$cc" --target=wasm32 -O2 -std=c99 -ffreestanding -fno-builtin -nostdlib \
  -Wall -Wextra -Wno-unused-parameter \
  -c "$here/calc_dispatch.c" -o "$obj_dir/calc_dispatch.o"

echo "==> compiling plugin.c"
"$cc" --target=wasm32 -O2 -std=c99 -ffreestanding -fno-builtin -nostdlib \
  -Wall -Wextra -Wno-unused-parameter \
  -c "$here/plugin.c" -o "$obj_dir/plugin.o"

echo "==> linking TypstEditCalc.wasm"
"$wasm_ld" \
  --no-entry \
  --allow-undefined \
  --export-memory \
  --initial-memory=262144 \
  --max-memory=262144 \
  --strip-all \
  -o "$out_dir/TypstEditCalc.wasm" \
  "$obj_dir/calc_math.o" "$obj_dir/calc_dispatch.o" "$obj_dir/plugin.o"

size=$(wc -c < "$out_dir/TypstEditCalc.wasm" | tr -d ' ')
echo "==> built ${out_dir}/TypstEditCalc.wasm (${size} bytes)"

# Optional: verify the module's imports look right (only typst_env functions).
if command -v strings >/dev/null 2>&1; then
  if strings "$out_dir/TypstEditCalc.wasm" | grep -qi "wasi_snapshot"; then
    echo "warning: module appears to import WASI; Typst will refuse to load it" >&2
  fi
fi

# The editor's offline completion reads the registry from this list
# ("name/arity" per line), so it never needs a hardcoded copy.
list="${root}/Sources/Resources/Calc/functions.txt"
grep -E '^[[:space:]]*\{"[a-z0-9]+", [0-9]' "$here/calc_dispatch.c" \
  | sed -E 's/^[[:space:]]*\{"([a-z0-9]+)", ([0-9]).*/\1\/\2/' > "$list"
echo "==> wrote $(wc -l < "$list" | tr -d ' ') names to Sources/Resources/Calc/functions.txt"

echo "==> done"
