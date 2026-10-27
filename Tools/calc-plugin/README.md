# TypstEditCalc — the calculator's WebAssembly core

`TypstEditCalc.wasm` is the numeric core behind the calculator functions a
Typst document can call (`BesselJ`, `calc-gamma`, …). It is a freestanding
wasm32 module loaded with Typst's plugin API, so the functions execute inside
the Typst compiler — which is what makes them usable inside `#for` loops and
`plot()` sampling.

There is no math in the injected Typst bridge beyond thin wrappers; all of it
lives here, compiled.

## Layout

| Path | Purpose |
|---|---|
| `calc_math.h` / `calc_math.c` | The numeric core: fdlibm-derived `exp`/`log`/`sin`/`cos`/`pow`, Lanczos/Stirling gamma, digamma, erf family, incomplete gamma/beta, zeta, Lambert W, Ei/E1/Si/Ci, Airy, Bessel J/Y/I/K and spherical, orthogonal polynomials, elliptic integrals and Jacobi functions |
| `calc_dispatch.c` | **The function registry**: name → implementation + arity. Adding a function is one row here |
| `plugin.c` | Typst wasm-minimal-protocol glue: `call1`/`call2`/`call3` (generic dispatch), `functions` (name list), plus the fixed-arity Bessel/gamma exports |
| `tests/test_numerics.c` | Accuracy suite for the elementary functions, Bessel and gamma (~26k checks) |
| `tests/test_special.c` | 156 reference checks for the special functions (values generated with scipy) |
| `tests/gen_registry_reference.py` | Generates `tests/registry_reference.h`: mpmath references and per-case tolerances for **every** registry function, plus each function's supported domain |
| `tests/test_registry.c` | Registry conformance (16,765 cases): accurate-or-NaN everywhere, no declines in the supported domain, no slow calls. Run by `swift test` |
| `build_calc_plugin.sh` | Builds `build/calc/TypstEditCalc.wasm` |

The Typst side lives outside this directory:
`Sources/Resources/Calc/bridge.typ` is the bridge module the app copies next to
the document (typed wrappers, `calc-call`, `calc-param`, `plot`). It ships as a
SwiftPM resource; nothing is generated.

## Build

```sh
brew install lld                    # provides wasm-ld
Tools/calc-plugin/build_calc_plugin.sh
```

Requirements: `clang` with the WebAssembly backend (the macOS system clang has
it) and `wasm-ld` from LLVM/lld. Override the tools with `CC=…` and
`WASM_LD=…` if needed.

The output is ~16 KB. The app installs it next to each document's shadow file
because Typst resolves `plugin("TypstEditCalc.wasm")` relative to the
document.

## Soundness contract

Every function returns either a value within its documented error model or NaN
("declined"); never a finite wrong value. In its documented supported domain it
must not decline. Iterative algorithms return NaN when they do not converge,
casts from double to integer are never used unguarded (they are undefined for
NaN/huge values and saturate silently in wasm — `llvm-objdump` confirms the
module contains no trapping conversions), and every argument buffer is
bounds-checked.

After changing a function, regenerate and run the conformance suite:

```sh
python3 tests/gen_registry_reference.py     # needs mpmath
clang -O2 -std=c99 -o /tmp/registry calc_math.c calc_dispatch.c tests/test_registry.c
/tmp/registry -v
```

## Adding a function

1. Implement it in `calc_math.c` and declare it in `calc_math.h` (or reuse an
   existing implementation).
2. Add one row to `te_functions[]` in `calc_dispatch.c`:
   `{"myfn", 2, 0, te_my_binary_fn, 0},`
3. Add its mpmath reference to `REF` in `tests/gen_registry_reference.py`
   (the generator refuses to run for a registry entry without one).
4. Rebuild: `Tools/calc-plugin/build_calc_plugin.sh` (also regenerates
   `Sources/Resources/Calc/functions.txt` for autocomplete).

That is the whole change. Documents call it as `#calc-call("myfn", a, b)`;
`calc-functions()` lists it; the feature scanner and portability warning pick
it up because they read names from the bridge and the registry rather than a
hardcoded list. A friendlier wrapper is optional — add `#let my-fn(a, b) =
calc-call("myfn", a, b)` to `bridge.typ` if the name should read naturally.

## Protocol

Typst plugins import two host functions from the `typst_env` module:

```wat
(import "typst_env" "wasm_minimal_protocol_write_args_to_buffer" (func (param i32)))
(import "typst_env" "wasm_minimal_protocol_send_result_to_host" (func (param i32 i32)))
```

An exported function takes the *lengths* of its byte arguments, returns `0` on
success (or `1` with a UTF-8 error message), and sends its result buffer to the
host. Every function here takes little-endian `f64` bytes and returns one
`f64`, so the Typst side is a single `float.from-bytes(…)`.

`call1`/`call2`/`call3` take the UTF-8 function name as the first buffer and
the arguments after it, which is what makes the API generic. Status codes: `0`
ok, `1` unknown function, `2` wrong arity — both surfaced as compile errors.

The module must export its memory (`wasm-ld --export-memory`) and must not
import WASI: Typst refuses modules that do.

## Accuracy

`tests/test_numerics.c` runs ~26,000 comparisons:

```sh
clang -O2 -std=c99 -D_DARWIN_C_SOURCE \
  -o /tmp/calc_numerics calc_math.c tests/test_numerics.c -lm
/tmp/calc_numerics
```

Measured worst case:

| Function | Regime | Relative error |
|---|---|---|
| `exp`, `log`, `pow` | all | ~2e-15 |
| `gamma`, `lgamma` | all | ~1e-15 |
| `bessel_j`, `bessel_i` | series (x ≤ 18) | ≤ 2e-11 |
| `bessel_j` | asymptotic (x > 18) | ≤ 2e-7 near the crossover, ~1e-9 far out |
| `bessel_y` | series / asymptotic | ~1e-9 / ≤ 3e-7 |
| `bessel_k` | integer-order series / asymptotic | ≤ 1e-6 worst case near the crossover (orders 0–3: ≤ 7e-7) |

That is chart-grade accuracy. Exact values come from the CAS (`#calc("…")` or
the Calculator panel), not from this module.

## Implementation notes

- **No libc.** WebAssembly has no `sin`/`cos`/`exp`/`log`/`pow` instructions,
  so the module carries fdlibm's algorithms and its own bit-level helpers. It
  never links WASI, which keeps the import list to the two protocol functions.
- **Series vs asymptotic.** Power series lose all significance as `|x|` grows
  (the terms grow, then cancel). J, Y, I use the series up to `x = 18` and
  Hankel expansions beyond; K decays like `e^-x`, so it switches at `x = 11`,
  before cancellation eats the result.
- **Integer orders** of Y and K use the exact A&S 9.1.11 / 9.6.11 forms
  (harmonic numbers and `psi`), because the reflection formula is `0/0` at
  integer order and an epsilon shift loses too much to cancellation.
- **`pow` for integer exponents** uses repeated squaring. It rounds the
  exponent rather than truncating it — a value like `6.9999999999999867` is an
  integer here, and a plain cast would silently use 6.
- **Plugin purity.** Typst requires plugin functions to be pure; these are
  stateless math with a bump allocator for the argument/result buffers.
