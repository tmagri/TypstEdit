# Calculator mode

The left panel's Calculator tab is a CAS home screen in the style of a
TI-89: you type a line, it evaluates, and the history keeps input on the
left and a typeset result on the right. The engine is Giac (the CAS inside
Xcas / the HP Prime) running as a bundled helper program — no Python, no
network.

## Opening it

- The `function` icon in the status bar, or
- Editor → Open Calculator (⌘⇧U), or
- open a saved `.tcalc` file from the Files tab.

## Entry line

| Key | Behaviour |
|---|---|
| ↩ | Evaluate |
| ⇧↩ | Start a new line (for a longer multi-line question) |
| ⌥↩ | Evaluate as a decimal (TI's ◆ENTER) |
| ↑ / ↓ | On single-line input, highlight a history line; the text shows in the entry line. On a multi-line question, move the caret |
| Esc | Clear the entry line, or stop a running calculation |

The `F2/F3/F4` menus insert templates (Algebra, Calc, Other) with the caret
inside. The MODE menu switches RAD/DEG, Auto/Exact/Approx and displayed
digits — mirroring the TI-89's MODE screen.

## Syntax (TI-89 style)

```
solve(x^2-4=0,x)        → (x=-2) or (x=2)
cZeros(x^2+1,x)         → [-i,i]
d(x^3,x)                → 3x²
∫(x^2,x,0,1)            → 1/3
limit(sin(x)/x,x,0)     → 1
Σ(k,k,1,5)              → 15
factor(x^2-4)           → (x-2)*(x+2)
propFrac(x^2/(x+1),x)   → x - 1 + 1/(x+1)
5→a                     store (also 5->a)
a*2                     → 10
f1(x)=x^2               Define f1(x)=x^2
nSolve(cos(x)=x,x)      numeric root
[[1,2];[3,4]]*2         matrices with ; rows
ans, ans(n), entry(n)   recall previous results/inputs
expr | x=3              evaluate with x=3
```

`approx(...)` / `exact(...)` force one-off precision like the TI's MATH menu.

## Inserting into the document

Right-click any input or result in the history:

- **Inline equation** `$…$` at the cursor
- **Block equation** `$ … $` on its own line
- **Input = Result** as one display equation
- **Copy as Typst / plain text**
- **Reuse in entry line** (or just click the line, then ↩)

Insertion is available for `.typ` and `.note` documents.

## Saving sessions

- **Save** (⌘S while the panel is focused) writes a `.tcalc` file: history,
  cached results, stored variables and modes. Results are cached in the
  file, so reopening never re-evaluates; stored variables are replayed
  quietly so later entries keep working.
- **Export as .typ** writes the history as display equations.

## Finding functions

The `book` button next to MODE opens the **function catalogue** (or use
F4 Other → Browse all functions). It lists every curated function with its
syntax, an example, and an honest compatibility label:

- **Verified**: the example was run against the bundled engine.
- **Alias**: TI spelling converted to the engine's name.
- **Not yet verified**: a known gap, with a caution.

Select an entry and click **Insert Example** to put it on the entry line.
The catalogue is a guide to what works, not a complete TI-89.

## Using it from AI Chat

The chat has an `evaluate_math` tool for exact or approximate math. It uses a
fresh, sandboxed CAS process:

- No project, file, Python, or network access.
- No shared variables with the Calculator panel.
- Only math functions are permitted. Assignments, strings, and programs are
  refused.
- Each call returns the plain result and Typst math.

Example asks:

```
Solve 3x^2 - 5x + 2 = 0 and insert the roots as an equation.
Compute ∫ x^2 sin(x) dx from 0 to pi, then check it numerically.
```

## AI fallback for questions

When the CAS cannot evaluate an entry — or returns something unusable for it,
like a string echo of the input or `undef` (Giac's answer for text it cannot
make sense of) — the calculator can ask the AI chat model to interpret it,
Wolfram|Alpha style:

- Opt in twice: enable AI Chat in Settings, then turn on *AI Fallback* in
  Settings → General → Calculator. Both default to off.
- Only entries that read like a question are routed ("How many r's in
  strawberry", "Area of a circle, if diameter is 1 cm?", or a word problem
  that embeds units — "…velocity of 6 m/s, using g = 9.8 m/s^2, how many
  seconds…?"). Formula-shaped input — a bare function call or operator-heavy
  text — still shows the CAS error, so a typo in a formula is never sent to
  the AI.
- The model only *interprets*: computable questions become a TI-syntax
  expression that the CAS evaluates locally, so the number is exact even
  from a small local model. The result shows as math with the model's prose
  underneath. Knowledge and counting questions get a prose answer.
- The model the fallback uses is its own choice: pick it under *Model* in the
  AI Fallback card, in Settings → AI → Model per Feature, or from the model
  chip in the calculator's status strip — which also shows what is in use.
  With nothing chosen, it uses the default Chat & Actions model.
- The answer appears in the history with an AI badge, copies via the
  context menu, is saved in the `.tcalc` file, and is exported as text (plus
  the exact result) by *Export as .typ*.
- If the AI request fails, the normal CAS error entry appears and the status
  line says why the fallback failed.

## The engine

`build/cas/typstedit-cas` is built by `Tools/cas/build_cas.sh` (Giac + GMP +
MPFR, static, universal). The panel shows a warning in its status strip if
the helper is missing. See `Tools/cas/README.md` for build details and the
protocol.

## Using the calculator from a document

Typst documents can call the calculator while they compile. This is
**TypstEdit-only Typst**: standard Typst has none of it, so a `.typ` file that
uses these features gets a warning in the Issues panel and a *Non-portable
Typst* badge in the status bar. `.note` files are exempt: notes are a
TypstEdit-native format, and their preview always comes from this app.

### Send an equation to the calculator

Put the cursor inside an equation (`$ … $`), then use the toolbar's
**Send Equation to Calculator** button or the editor's right-click menu →
**Send to Calculator**. The Typst math is translated to TI/Giac syntax
(fractions, powers, `sqrt`, trig, integrals, sums, limits, derivatives,
matrices) and loaded into the calculator's entry line. Constructs the
translator cannot express (for example `cases(...)` or `&` alignment) are
refused with a message instead of loading something wrong.

### Use calculator functions in a document

| Call | What it does |
|---|---|
| `calc-call("name", …)` | **Any** function in the numeric core, by name |
| `calc-fn("name", …)` | The same, curried to `x => …` for `plot`/loops |
| `calc-functions()` | Lists every available function name |
| `BesselJ(order, x)`, `BesselY`, `BesselI`, `BesselK` | Bessel functions |
| `calc-gamma(z)`, `calc-lgamma(z)`, `calc-erf(x)`, … | Common special functions |
| `plot(fn, x-min, x-max)` | Draws a labelled chart |
| `#calc("expression")` | Evaluates once at compile time, inserts the value |
| `#calc-table("expression", x, a, b, n)` | Samples an expression into points |
| `#let a = calc-param(2.5)` | Declares a document parameter |

```typ
#let a = calc-param(2)

#plot(x => BesselJ(a, x), 0, 20, title: [Bessel J with a = #a])

The value of a·3 is #calc("a*3").

#plot(
  curves: (
    (fn: x => BesselJ(0, x), label: [J0]),
    (fn: x => BesselJ(1, x), label: [J1]),
  ),
  x-min: 0, x-max: 20,
)
```

The dispatcher is generic: **anything in the numeric core is callable by name**
without a dedicated wrapper. `calc-functions()` prints the current list.

```typ
#calc-call("erf", 0.5)                 // 0.5204998778…
#calc-call("zeta", 2)                  // 1.6449340668…
#calc-call("ellipk", 0.5)              // 1.8540746773…
#calc-call("jacobisn", 1, 0.5)         // 0.8030018249…
#calc-call("legendre", 4, 0.3)         // 0.0729375
#plot(calc-fn("airyai"), -2, 2)
```

Available today: elementary functions (`exp`, `ln`, `pow`, trig and inverse
trig, hyperbolic, `sinc`, `cbrt`, `hypot`, …), combinatorics and gamma
(`gamma`, `lgamma`, `digamma`, `beta`, `factorial`, `binom`, `npr`, `gcd`,
`lcm`), error and incomplete functions (`erf`, `erfc`, `erfinv`, `gammainc`,
`gammaincc`, `betainc`), integrals (`ei`, `e1`, `li`, `si`, `ci`), special
(`zeta`, `lambertw`, `lambertwm1`, `airyai`, `airybi`), Bessel (`besselj`,
`bessely`, `besseli`, `besselk`, `sphbesselj`, `sphbessely`), orthogonal
polynomials (`legendre`, `chebyt`, `chebyu`, `hermite`, `laguerre`), and
elliptic (`ellipk`, `ellipe`, `jacobisn`, `jacobicn`, `jacobidn`).

`BesselJ` and the other wrappers work **inside Typst's own control flow**, so a
loop can compute and draw per-iteration values:

```typ
#for n in range(3) [
  Order #n: #BesselJ(n, 6)
  #plot(x => BesselJ(n, x), 0, 12)
]
```

`#calc` and `#calc-table` are evaluated by the real CAS *before* Typst runs.
Inside a loop with literal bounds they are **specialised**: TypstEdit expands
the loop into one copy per iteration, re-binds the loop variable in each copy
(so `#n` and other Typst code still work), and substitutes the value into the
calculator string only. Any Giac function then works per iteration, with exact
CAS values:

```typ
#for n in range(3) [
  Order #n: #calc("BesselJ(n, 6)")    // Giac's own BesselJ, exact
]
#for i in range(1, 4) [#for j in range(i) [#calc("binomial(i, j)") ]]
```

Code-mode loops are specialised too, and in code mode the calls are written
without `#`:

```typ
#table(columns: 2, ..for n in (1, 2, 3) { ([#n], [#calc("Zeta(2*n)")]) })
#grid(calc("6*7"), plot(points: calc-table("x^2", x, 0, 2, 20), x-min: 0, x-max: 2))
```

Specialisation needs bounds TypstEdit can read without running Typst:
`range(…)` with integer literals (or a bound from an enclosing specialised
loop), or a tuple of numbers like `(0.1, 0.5, 0.9)`. Loops over data computed
at run time (`range(count)`, arrays from `json(…)`) are left unchanged with a
warning; use the compiled functions (`calc-call`, `BesselJ`, …) there. Loops are
capped at 200 iterations. Error lines still point at the source you wrote.

For curves of arbitrary CAS expressions, `#calc-table` samples the expression
once and `plot(points: …)` draws it:

```typ
#plot(points: #calc-table("sin(x)/x", x, 0.01, 20, 120), x-min: 0, x-max: 20)
```

### How it is wired

Two files ship with the app and are copied next to the preview document:

- `TypstEditCalc.wasm` — the numeric core.
- `TypstEditCalcBridge.typ` — the bridge module (source:
  `Sources/Resources/Calc/bridge.typ`), imported by the shadow document with a
  single `#import "TypstEditCalcBridge.typ": *`.

Nothing is injected as a Swift string: the bridge is ordinary Typst source, and
the function list lives in the C registry
(`Tools/calc-plugin/calc_dispatch.c`), so adding a function is one table row.

The math functions run in a compiled WebAssembly module,
`build/calc/TypstEditCalc.wasm`, loaded by Typst's plugin API. It is
freestanding wasm32 (no libc, no WASI) and implements its own elementary
functions. Accuracy, checked against scipy over ~26,000 points plus 156
special-function references:

- `calc-gamma` / `calc-lgamma`: ~1e-15
- Bessel J, I: ~1e-11 below the series crossover, ~1e-7 to 1e-9 above it
- Bessel Y, K: ~1e-9 below the crossover, ~1e-6 worst case above it (the
  exponentially decaying K is the hardest case)

That is chart-grade accuracy, not arbitrary precision. When a document needs
exact values, use `#calc("…")` (the real CAS) or the Calculator panel.

Three ways a document reaches calculator functions, by when they run:

| Path | Runs | Coverage | Values |
|---|---|---|---|
| `#calc`, `#calc-table` | before Typst (CAS) | any Giac expression | exact |
| …inside literal-bound loops | before Typst, specialised per iteration | any Giac expression | exact |
| `calc-call`, `BesselJ`, … | inside Typst (WASM) | the compiled library | chart-grade |

The WASM path is only needed when a value depends on something TypstEdit
cannot know before Typst runs: a loop over computed data, `plot()` sampling of
a callback, or a conditional on a computed value. A document that uses only
`#calc` needs neither the bridge nor the WASM core.

### Build the plugin

```sh
brew install lld                  # provides wasm-ld
Tools/calc-plugin/build_calc_plugin.sh
```

The script writes `build/calc/TypstEditCalc.wasm`. If it is missing, the app
warns "the calculator's WebAssembly core is not built" instead of injecting a
bridge that cannot load. Packaging must copy the module next to `typst` and
`typstedit-cas` in `Contents/Resources/bin/`.

`Tools/calc-plugin/tests/test_numerics.c` compares the numeric core against
the platform libm/scipy: build it with `clang -O2 -o /tmp/t
Tools/calc-plugin/calc_math.c Tools/calc-plugin/tests/test_numerics.c -lm`
and run `/tmp/t`.



### Export as Standard Typst

**File ▸ Export As ▸ Standard Typst (.typ)…** writes a file that compiles with
stock Typst (the `typst` CLI, typst.app, other editors):

- Markdown and Notes are converted to Typst first (a note's helpers are inlined).
- Every `#calc` / `#calc-table`, including those in specialised loops, is
  replaced by its value.
- If runtime functions remain (`plot`, `BesselJ`, `calc-call`…),
  `TypstEditCalcBridge.typ` and `TypstEditCalc.wasm` are written next to the
  file and imported. Keep the three files together. If only `calc-param`
  remains, it is inlined and no extra files are written.
- The result is verified by compiling it with the plain `typst` binary before
  the export reports success. A `#calc` that cannot be evaluated stops the
  export with the reason instead of writing a broken file.

Every other export (PDF, PNG, SVG — from `.typ`, `.note` or `.md`) and the
command line run the same calculator step as the live preview.

### Autocomplete

Offline autocomplete covers the calculator: `#Bes…` → `BesselJ(`, names inside
`calc-call("…` / `calc-fn("…` (from the function registry), `plot(` parameters
(from the bridge's signature) and CAS function names inside `#calc("…")`.

### Soundness contract

Every function either returns a value within its documented accuracy or
returns NaN ("declines"); it never returns a plausible but wrong number. Inside
each function's supported domain it must not decline either. Both halves are
enforced by `Tools/calc-plugin/tests/test_registry.c` (16,765 cases against
mpmath, run by `swift test`). Misuse (strings, lengths, named arguments, wrong
arity, unknown names) fails the compile with a clear message.
