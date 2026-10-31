---
name: Typst Reference
description: "Accurate Typst 0.13–0.15 syntax reference. Use when writing or fixing Typst markup, math, set/show rules, tables, or code-mode scripting — consult before guessing syntax, and read cheatsheet.md/function-catalog.md via read_skill_file for details."
---

# Typst Reference

Built into TypstEdit (bundled skill, read-only — it updates with the app).
You have three attached reference files, readable on demand with
`read_skill_file` (skill: "typst-reference"):

- **`cheatsheet.md`** — full syntax cheat sheet: layout, tables, figures,
  math, scripting, a document skeleton, and the common-mistakes list. Read it
  when you need anything beyond the core below.
- **`function-catalog.md`** — ~580 functions with signatures, examples and
  parameters, extracted from the official manual. Search it for exact
  parameter names and call syntax (e.g. before using an uncommon function).
- **`styling-recipes.md`** — custom-formatting cookbook: breakable tables,
  restyling raw blocks without losing syntax highlighting, ToC/outline entry
  styling, page-break-per-heading guards, title pages, custom lists of
  figures, custom `ref` formatting (`Gen 1:1`-style cross-references), and
  context/counter patterns. Read it before writing any transformational
  `#show` rule or custom layout.
- **`dates-and-times.md`** — date printing patterns and traps: the display
  grammar (component + modifiers), why `datetime.now()` and `strftime` don't
  exist, why `datetime.today()` is date-only, and date math/comparison
  recipes. Read it before printing, parsing or comparing dates.

## Core syntax (what most documents need)

Typst mixes three modes. Which mode you are in decides what syntax means —
most generated-document errors are mode errors.

| Mode | Entered by | `#` means | Bare words mean |
|---|---|---|---|
| Markup (default) | start of file, content blocks `[...]` | starts a code expression | literal text |
| Code | after `#`, inside `{...}`, `(...)` | — (a literal `#` is an error) | identifiers/expressions |
| Math | `$...$` | starts a code expression | variables/math symbols |

```typst
= Heading        == Heading 2        // levels 1–5
*strong*         _emph_              `inline code`
- bullet list    + numbered list     / Term: definition
#set text(font: "New Computer Modern", size: 11pt)
#set par(justify: true)
#set heading(numbering: "1.1.")
#show link: set text(fill: blue)          // show-set rule
#show heading.where(level: 1): it => upper(it.body)

#let x = 3                          // binding
#let f(a, b: 2) = a + b             // function with named default
#let double = x => x * 2            // closure
#if x > 0 [ positive ] else [ non-positive ]
#for v in (1, 2, 3) [#v ]
#(1 + 2)                            // parenthesized expression prints
```

Escapes in markup: `\#  \$  \_  \*  \[  \]  \\  ~` (non-breaking space is `~`).
Line break: `\`. Labels: `… <intro>` then reference with `@intro`.

## The mistakes that cause most compile errors

All facts below are validated against the `typst` compiler (see
`Docs/tools/validate_reference_corpus.py` for the executable corpus).

### Delimiter emergencies — read the FIRST error

Every unclosed `[`, `{`, `(`, string, or `$` math reports exactly
`error: unclosed delimiter`, and **everything after it is misparsed**, so one
broken line can flood the panel with hundreds of follow-on "expected
expression" errors. The fix lives at the TOP of the cascade, not the bottom:
read the first error, balance that opening delimiter, and ignore the rest
until the next compile.

| Compiler says | Usual cause | Fix |
|---|---|---|
| `unclosed delimiter` | an unclosed `[`/`{`/`(`, string, or `$…$` (often multi-line content the model left open) | close the opener at/near the reported line |
| `unexpected closing bracket` | a stray `]` with no opener | delete it or open a block |
| `the character '#' is not valid in code` | Markdown headings (`###### x`) or `##set` | headings are `=`, `==`, … |
| `the character '|' is not valid in code` | Rust closure `\|x\| …` | closures are `x => …` |
| `the character '?' is not valid in code` | C/JS ternary `c ? a : b` | `#if c { a } else { b }` |
| `expected expression` | `# let` (space after `#`) or a Python-style `# comment` line | `#let`; comments are `// …` |
| `expected comma` | named arg missing its colon (`#text(size 20pt)`) | `size: 20pt` |
| `unexpected colon` | Python dict braces `{"a": 1}` | Typst dicts: `(a: 1)` |
| `unknown variable: True/None/len/print` | Python/Rust habits | `true`, `none`, `arr.len()` (no global `len`/`print`) |
| `expected semicolon or line break` | type annotations (`let x: int = 3`) | Typst has none — drop them |
| `unknown variable: rac` / `lpha` | LaTeX in math (`\frac`, `\alpha` — the `\` eats one char) | `frac(a, b)`, `alpha` |
| `label '<x>' does not exist in the document` | `@ref` with no matching `<x>`, or `@` in an email (`user@example.com`) | add the label or escape: `user\@example.com` |
| `expected block` (points at an operand) | a type test `x is figure` — Typst has **no `is` operator** | compare instead: `el.func() == figure`, `el.kind == "verse"`, or `type(x)` |
| `type location has no method 'field'` | `loc.field("chapter")` — hallucinated API | read the *element*: `el.fields().at("chapter", default: …)`; `location` is only a position |
| `unexpected argument: chapter` (on `figure`) | `#figure(…, chapter: "1")` — `figure` rejects unknown named args | keep per-item data in a dict keyed by `str(el.label)` or in `metadata`; match it in the show rule |
| `please specify the figure's supplement` | custom-`kind` figure without `supplement:` | pass `supplement: [Gen]` (or show-set it for that kind) |

### Silent failures — compiles, renders wrong

These produce **no error**, so check for them by eye:

- Missing `#` — `let x = 3`, `set text(…)`, `table(…)` render as literal text.
- `**bold**` renders literally — Typst emphasis is `*bold*` / `_emph_`.
- `elif` renders as literal text — chains are `#if … [..] else if … [..] else [..]`.
- `[text](url)` renders literally — links are `#link("url")[text]`.
- `<div>` silently becomes a label named `div`.
- `snake_case_words` in prose — `_` toggles emphasis; escape as `snake\_case`.
- A stray `;` after `#let x = 3;` renders as text.

### Type rules worth knowing

- Strings auto-convert to content: `#emph("text")` and `#([a] + "b")` work.
- Named params are typed: `font:` wants a string (`"Arial"`), `stroke:` wants
  a stroke/length/color — `stroke: 3` fails.
- A single-element array needs a trailing comma: `#(1,)` — `#(1)` is an int.
- Dashed identifiers are legal, so `dict.a-b` works; quoted keys need
  `dict.at("a-b")`.
- Duplicate labels compile; a *reference* to a missing label does not.
- Typst has **no `is` operator**: `if x is figure` fails with `expected
  block`. Test types with `el.func() == figure` and kinds with
  `el.kind == "verse"`.
- Inside a code block `{ ... }`, code-mode keywords are **bare**: `if … { }
  else { }`, `link(it.target)[…]` — never `#if`, `#else`, `#link` (the `#`
  is only for markup/math mode).
- `location` values (from `el.location()`, `here()`) carry no payload:
  there is no `loc.field("x")`. Read element data with
  `el.fields().at("x", default: …)` instead.
- `#figure()` rejects unknown named arguments (`unexpected argument:
  chapter`). Attach per-item data via a dict keyed by `str(el.label)` or
  `metadata`, then match it inside the show rule (see
  `styling-recipes.md` §9).
- In `#show ref:` rules, `it.element` can be `none` while resolving —
  guard with `if it.element != none` before calling `.func()`; `it.target`
  is the label being referenced.
- `7 / 2` is `3.5`; integer division is `calc.quot(7, 2)`.
- Labels `<x>` attach to the *previous* element; put them right after it.
- Reading `counter`/`state`/`page` requires `context`:
  `#context counter(page).display()`. Dates are different:
  `datetime.today()` needs no context and is **date-only** (no wall-clock
  `now()`); see `dates-and-times.md`.
- `table.header(...)` repeats across page breaks; `table.cell(colspan: 2)`
  counts columns.
