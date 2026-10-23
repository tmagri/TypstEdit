# Syntax-Highlighting Validation Tests

Generic (non-confidential) tests for TypstEdit's raw code-block syntax
highlighting. No company content — sample code uses placeholder text.

## What these cover

Typst resolves a raw block's language tag against its bundled syntax set.
Several very common tags do **not** resolve (verified on both the bundled
Typst 0.12 binary and Homebrew 0.15.1), so the compiler normalizes them in
the shadow source before compiling (see
`Sources/Models/TypstCompiler.swift` → `normalizeRawLanguages`).

Two separate defect patterns were found in real documents:

1. **Unresolved / corrupting language tags** — `csharp`, `shell`, `docker`,
   `objc`, `fsharp`, `json5`, `node` never highlight; `c#` and `c++` even
   leak the `#` / `++` into the rendered output.
   → Fixed by `normalizeRawLanguages` (`csharp → cs`, `shell → bash`, …).
2. **A custom raw show rule that flattens highlighting** — a rule that
   re-emits `it.text` line-by-line discards the highlighted token spans, so
   *no* language highlights. The raw ELEMENT (`it`) must be kept so Typst's
   built-in highlighting survives the restyle.
   → Fix the document/generator: use `[#it]` inside the styled block.

## Files

| File | Purpose | Expected result |
|---|---|---|
| `NormalizeRawLanguagesTests.swift` | 21 unit tests for the shadow-source fence normalizer | `swift NormalizeRawLanguagesTests.swift` → `ALL PASS` |
| `generic-raw-rule-broken.typ` | Defect pattern 2: `it.text.split` show rule | Compiles, but **no** highlighting (documents the defect) |
| `generic-raw-rule-fixed.typ` | Corrected pattern: same styling with `[#it]` | Compiles, **with** highlighting |

## Running the visual checks

```sh
TYPST=<typst binary>            # e.g. bundled or /opt/homebrew/bin/typst
swift Tests/TypstHighlight/NormalizeRawLanguagesTests.swift
"$TYPST" compile Tests/TypstHighlight/generic-raw-rule-broken.typ out-{n}.png
"$TYPST" compile Tests/TypstHighlight/generic-raw-rule-fixed.typ out-{n}.png
```

`fixed` must show colored tokens (keywords/types/strings in the C#-style
block; keys/values in the JSON block); `broken` renders the same layout in
a single color. Rendering with the app's dark-mode preamble also keeps
colors: inner token styles win over the preamble's blanket text fill.

## Known limits

- `vb` and `powershell` have no resolvable target in Typst's bundled syntax
  set on any tested version — they stay unhighlighted.
- Typst 0.13+ emits a deprecation warning for `c#` / `c++` fences; the
  normalizer removes the problem by rewriting the tag.
