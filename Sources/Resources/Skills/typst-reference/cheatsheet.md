# Typst Cheat Sheet for AI Assistants

A compact, accurate reference for generating Typst 0.13–0.15 documents.
Ships as the `typst-reference` skill's full attachment (`cheatsheet.md`);
pair with `function-catalog.md` (same folder) for the complete function
catalog.

## 1. Modes

Typst source mixes three modes. Which mode you are in decides what syntax
means — most generated-document errors are mode errors.

| Mode | Entered by | `#` means | Bare words mean |
|---|---|---|---|
| Markup (default) | start of file, content blocks `[...]` | start of code expression | literal text |
| Code | after `#`, inside `{...}`, `(...)` | — (a literal `#` is an error) | identifiers/expressions |
| Math | `$...$` | starts a code expression | variables/math symbols |

```typst
Text mode: plain words, *strong*, _emph_.
#set text(size: 11pt)              // one code expression in markup
#{ let x = 2; x + 1 }              // code block, last expression is the value
$ x^2 + y_1 $                      // inline math
$ sum_(i=1)^n i = (n(n+1))/2 $     // block math (spaces around $)
```

- To write a literal `#`, `$`, `@`, `\`, `_`, `*`, `[`, `]` in markup, escape it: `\#`, `\$`, `\_`, `\\`, …
- In math mode, escape `$` as `\$`; text within math goes in quotes: `$ "if" x > 0 $`.

## 2. Markup essentials

````typst
= Heading 1                        // = .. ====== for levels 1–5
== Heading 2

*strong text*                      // bold
_emphasized text_                  // italic
`inline code`                      // raw (no parsing inside)
```rust                            // fenced code block with highlighting
fn main() {}
```
````

- Bullet list: lines starting `- ` (or `+ ` for numbered)
- Nested lists: indent by 2 spaces (or consistent indent)
- Term list: `/ Term: description`

Link: `https://typst.app` auto-links; `#link("https://example.com")[text]`;
internal `#link(@intro)[Jump]`.

Label anything with `<intro>` after it; reference with `@intro` or
`#ref(@intro, form: "page")`.

Line break in a paragraph: `\` (backslash + newline or space).
Non-breaking space: `~`. Unicode escape: `\u{2003}`.

Comments: `// line`  and  `/* block */`  (not inside raw/math).

Raw-block fences may carry 3 or more backticks — use a longer run to nest
raw blocks inside documentation.

## 3. Code mode

```typst
#let x = 3                         // binding
#let f(a, b: 2) = a + b            // function, named arg with default
#let g(..rest) = rest              // argument sink (arguments value)
#let double = x => x * 2           // closure (single expr)
#let multi(a) = {                  // closure with body block
  let t = a * 2
  t + 1
}

#if x > 0 [ positive ] else [ non-positive ]      // conditional (markup branches)
#for v in (1, 2, 3) [#v ]                          // loop, markup body
#for v in (1, 2) {                                 // loop, code body
  [#v]
}

#(1 + 2)                           // parenthesized expression prints its value
#x                                 // prints x if it is content/string/number
```

- Blocks: `{..}` code blocks return their last expression; `[..]` content
  blocks produce content.
- Values: `int`, `float`, `str`, `bytes`, `length` (`12pt`, `1em`, `50%`),
  `angle` (`90deg`), `ratio` (`50%`), `relative length` (`10pt + 50%`),
  `fraction` (`1fr`), `color` (`rgb("#1a1a1a")`, `luma(30)`), content `[...]`,
  arrays `(1, 2, 3)`, dictionaries `(a: 1, b: 2)`, functions.
- Array literal: `(1, 2, 3)`; single-element needs comma: `(1,)`.
- Dict access: `dict.a` or `dict.at("a")`; arrays: `arr.at(0)`, negative
  indices from the end.
- Methods: `arr.len()`, `str.upper()`, `n.str()`, `str.int()`, `str.float()`.
- Spread: `#let a = (2, 3); #calc.max(..a)`; dict spread into named args.
- Destructuring: `#let (a, b) = arr; #let (x, y: dflt) = dict`.
- Comparisons: `== != < <= > >=`; logic: `and not or`; membership: `in`.
- Ternary: `#if c { a } else { b }` (no `?:` operator).
- Joining content: `[a] + [b]`; repetition: `[ab] * 3`.

Modules:

```typst
#import "utils.typ": helper, *        // named imports; * = all
#import "@preview/tablex:0.0.8": tablex   // packages
#include "chapter1.typ"               // inline content
```

## 4. Set and show rules

```typst
#set page(paper: "a4", margin: 2cm, numbering: "1")
#set text(font: "New Computer Modern", size: 11pt, lang: "en")
#set par(justify: true, leading: 0.65em)
#set heading(numbering: "1.1.")
#set enum(numbering: "a)")
#set list(indent: 1em, tight: true)

#show link: set text(fill: blue)              // show-set rule
#show heading.where(level: 1): it => block[   // transformational rule
  #upper(it.body)
]
#show "TODO": strong                          // string selector
#show raw.where(block: true): set block(fill: luma(240))
```

- `set` applies from that point to the end of the enclosing block/file.
- `show` selectors: functions, `f.where(..)`, strings, regexes, `f.and/or(..)`.
- Rule target receives `it` (the element); use `it.body`, plus custom fields.

## 5. Page and layout

```typst
#set page(
  paper: "a4",              // or width:/height:
  margin: (top: 2cm, x: 2.5cm, bottom: 2cm),
  numbering: "1 / 1",       // page numbers, "I", "i", "a" …
  header: context {
    if counter(page).get().first() > 1 [running header]
  },
  footer: align(center)[#context counter(page).display()],
)

#pagebreak()
#colbreak()
#v(1em)  #h(2pt)  #v(1fr)

#align(center)[centered]
#align(right, [right])

#block(fill: luma(240), inset: 8pt, radius: 4pt, width: 100%)[
  boxed paragraph — breakable across pages
]
#box(width: 2cm, stroke: 0.5pt)[inline box]

#grid(                      // fixed-track layout
  columns: (2fr, 1fr),
  rows: (auto, auto),
  gutter: 8pt,
  align: (left, center),
  [left cell], [right cell],
  [A2], [B2],
)

#stack(dir: ltr, spacing: 1em, [a], [b])

#place(center + horizon)[watermark]        // out of flow, absolutely placed
#layout(bounds => [container width: #bounds.width])  // measure region (0.12+)
```

Page constants in headers/footers: `#context counter(page).display("I")`,
`#context page.height`.

## 6. Text styling

```typst
#text(font: ("Helvetica", "Arial"), size: 10pt, fill: navy,
      weight: "bold", style: "italic", tracking: 0.5pt)[styled]
#underline[underline] #overline[…] #strike[…] #highlight[…] #sub[x] #super[2]
#smallcaps[SmallCaps] #lower[ABC] #upper[abc] #smallcaps
#raw("code", lang: "py", block: false)
#lorem(20)
```

Fonts are matched in order of the list; `font: "*"` wildcards OK. Use
`#set text(font: (name: "...", covers: "latin-in-cjk"))` for CJK mixes.

## 7. Tables, figures, lists

```typst
#table(
  columns: (auto, 1fr),
  rows: auto,
  inset: 6pt,
  stroke: 0.5pt,
  table.header([Name], [Amount]),          // repeats on page breaks
  table.hline(),
  [Flour], [100g],
  table.cell([Note], colspan: 2),
)

#figure(
  table(columns: 2, [a], [b]),
  caption: [A caption],
) <tab:ex>

As @tab:ex shows …  → "Table 1"
#figure.caption(position: top)[…]      // caption above

#figure(image("chart.png", width: 80%), caption: [Chart]) <fig:chart>
#image("logo.svg", height: 2cm)          // png/jpg/gif/svg supported
```

Figures get a `kind` (`image`, `table`, `raw`, or custom via `kind:`); show
rules and outline targets can filter with `figure.where(kind: table)`.

```typst
#outline(title: [Contents], depth: 2)      // table of contents
#outline(target: figure.where(kind: table))
```

Bibliography: `#bibliography("refs.yml", style: "ieee")`; cite with `@key`
and style with `#set bibliography(...)`; add glossary-like customizations via
show rules on `ref`.

## 8. Math

```typst
$ x^2 + y_1 $                                  // inline
$ sum_(i=0)^n i = (n(n+1))/2 $                 // display (blank lines around)
$ frac(a, b) a/b binom(n, k) $                 // fractions
$ vec(1, 2, 3) mat(1, 2; 3, 4) $               // vectors and matrices (; = row)
$ cases(1 "if" x > 0, 0 "otherwise") $
$ lim_(x -> oo) integral_0^1 dif x $           // limits and integrals
$ hat(x) tilde(z) dot(x) bar(v) $              // accents
$ -> <=> ==> $                                 // symbol shorthands
$ alpha beta Gamma pi tau $                    // greek names
$ "text in math" upright text $                // quoted or upright()
$ 5 != 4 equiv 3 $                             // relations
```

- Multi-letter identifiers in math are italic variables; use `"text"` or
  `upright(...)` for words.
- `dif x` for differentials; `dots.c/dots.v` for ellipses; `star`, `dagger`,
  `plus.circle` etc.
- Attachments: `x^(2n)`, `y_i^j`; big operators take limits via `_` below.
- Spacing: `,` thin, `;` thick, `!` quad (e.g. `$ a, b $`).
- Escape `$` inside math as `\$`; literal `#` must be escaped `\$#`? — use
  `math.escape("#")`? Actually `#` in math starts code: write `#set math(...)`
  outside, or escape in markup only. Prefer keeping math pure.

## 9. Scripting utilities

```typst
#calc.abs(-3) #calc.min(1, 2) #calc.max(..(1, 5, 3)) #calc.floor(2.7)
#calc.round(2.4, digits: 1) #calc.pow(2, 10) #calc.sqrt(2)
#calc.sin(90deg) #calc.log(100, base: 10) #calc.even(4)

#range(5)               // (0,1,2,3,4); range(1, 10, step: 2)
#luma(200) #rgb("#4a7dbd") #rgb(20%, 30%, 50%) #cmyk(0%, 20%, 30%, 0%)
#gradient.linear(..rgb, angle: 45deg)  #tiling

#str("abc").len() #upper("x") #repr(x) #json("f.json") #read("data.csv")
#csv("f.csv") #yaml("f.yml") #toml("f.toml")

#counter(page).update(1)                // counters/state (need context to read)
#context counter(heading).display()
#state("k", 0).update(v => v + 1)
#context here().position()              // current location on the page
#context measure([wide text])           // → (width: …, height: …)
#metadata(42) <meta> #query(<meta>)
#eval("1 + 1")
#numbering("I", 3)                      // "III"; also "1.1", "a", "い" …
#datetime.today().display("[month repr:long] [day], [year]")
```

`context` expressions re-run when layout state is available; anything reading
`counter`/`state`/`page`/`here` needs `context` (Typst 0.11+).
`datetime.today()` is NOT context state — it works anywhere, but is
**date-only**: Typst has no wall-clock time (no `datetime.now()`).

## 10. Common mistakes (guard against these)

1. Unbalanced `[]`/`{}`/`()` — the top parser error; check nesting first.
2. Mode confusion: `#` starts code in markup and math; a literal `#` in
   markup is `\#`. Keep math free of markup tricks.
3. Content vs string: `"abc"` is a string, `[abc]` is content. Functions
   like `emph` take content; `upper` takes str or content.
4. Missing comma between function args, or missing `:` for named args.
5. `set`/`show` must be at top level of markup or in code blocks — `#set ...`
   with a semicolon-free single expression.
6. Spaces matter in math: `$f(x)$` renders italic letters f(x); write
   `$ f(x) $` and use `f` as `op("f", limits: true)` for operators.
7. `1fr` only inside auto-sized containers (grid columns, stack spacing).
8. Labels `<x>` attach to the PREVIOUS element; place them on the same line
   or directly after it.
9. Nested lists need consistent indentation; tight vs spaced lists differ.
10. `–`/`—`/curly quotes are fine in text, but a raw `_` in URLs needs
    escaping (`\_`) or `#link("...")[...]`.
11. `let` requires `#let` in markup; inside code blocks plain `let`.
12. `table.cell(colspan: 2)` counts COLUMNS; rowspans need `table.cell(rowspan:)`
    and matching empty cells.

## 11. Common AI failure modes (validated against the compiler)

Every row below was executed against the real `typst` binary — the "Compiler
says" column is the literal error text (see
`Docs/tools/validate_reference_corpus.py` to re-run the corpus).

### 11.1 Delimiter errors — the cascade rule

All of these produce exactly `error: unclosed delimiter`, and everything
after the unclosed opener is misparsed:

| Broken | Compiler says |
|---|---|
| `#let x = [para one` (no closing `]`) | `unclosed delimiter` |
| `#let f(a) = {` (no closing `}`) | `unclosed delimiter` |
| `#table(columns: 2, [a], [b],` (no `)`) | `unclosed delimiter` |
| `#text(font: "Helvetica)[hi]` (string swallowed the `]`) | `unclosed delimiter` |
| `$ e = sum_(n=0)^oo 1/n!` (no closing `$`) | `unclosed delimiter` |
| `#let x = (1, 2]` (wrong closer) | `unclosed delimiter` |
| `Hello ]` (stray closer) | `unexpected closing bracket` |

**Cascade rule:** one unclosed delimiter near the top of a document floods
the panel with "expected expression"/"unclosed delimiter" errors for every
following line. Diagnose at the FIRST error: check its delimiter balance,
fix that opener, ignore all later errors until the next compile. Never try
to fix errors line-by-line down the cascade — they are echoes, not causes.

### 11.2 Language cross-contamination

| From | Broken | Compiler says | Typst way |
|---|---|---|---|
| Python | `# let x = 3` | `expected expression` | `#let x = 3` — no space |
| Python | `# comment` line | `expected expression` | `// comment` |
| Python | `True`, `None` | `unknown variable: True` | `true`, `none` |
| Python | `elif` | *(none — renders as literal text!)* | `else if` |
| Python | `#let d = {"a": 1}` | `unexpected colon` | `#let d = (a: 1)` |
| Python | `#len(arr)` | `unknown variable: len` | `arr.len()` — methods only |
| Python | `#let x: int = 3` | `expected semicolon or line break` | `#let x = 3` |
| JS/C | `c ? a : b` | `the character '?' is not valid in code` | `#if c { a } else { b }` |
| Rust | `\|x\| x * 2` | `the character '\|' is not valid in code` | `x => x * 2` |
| Rust | `#fn f(x) -> int` | `unclosed delimiter` | `#let f(x) = x` |
| Markdown | `###### Deep heading` | `the character '#' is not valid in code` | `======`-style: `=`, `==`, `===` … |
| Markdown | `**bold**` | *(none — renders literally)* | `*bold*` |
| Markdown | `[text](url)` | *(none — renders literally)* | `#link("url")[text]` |
| HTML | `Hello <div> world` | *(none — becomes a label `div`)* | escape or remove |
| LaTeX | `$ \frac{a}{b} $` | `unknown variable: rac` (the `\` eats one char) | `$ frac(a, b) $` |
| LaTeX | `$ \alpha $` | `unknown variable: lpha` | `$ alpha $` |
| LaTeX | `\textbf{bold}` in markup | *(none — renders literally)* | `*bold*` |

### 11.3 Missing-`#` silent failures

In markup, forgetting `#` never errors — it renders as literal text:

```typst
let x = 3            // renders as the words "let x = 3"
set text(size: 20pt) // ditto
table(columns: 2)    // ditto
```

The trap: `let x = 3` on one line then `#x` later errors with
`unknown variable: x` — pointing at the WRONG line. The bug is the missing
`#` on the earlier line. Related silent traps:

```typst-broken
user@example.com // @ starts a reference → "label <example.com> does not exist"
snake_case_name  // _ toggles emphasis → escape: snake\_case\_name
#let x = 3;      // the stray ; renders as text
###### x         // markdown heading → the character '#' is not valid in code
```

Right:

```typst
user\@example.com // escape the @
snake\_case\_name // escape the underscores
```

### 11.4 Function-call confusion

| Broken | Compiler says | Right |
|---|---|---|
| `#text(size 20pt)[hi]` | `expected comma` | `#text(size: 20pt)[hi]` |
| `#text(font: [Arial])` | `expected string, dictionary, or array, found content` | `font: "Arial"` |
| `#text(colour: red)` | `unexpected argument: colour` | check the param name (`fill`, not `colour`) |
| `#rect(stroke: 3)` | `expected length, color, … found integer` | `stroke: 3pt` |
| `#(1).len()` | `type integer has no method 'len'` | `#(1,).len()` — trailing comma makes the array |
| `#([a] + 1)` | `cannot add content and integer` | `#([a] + [b])` |
| `#("a" + 1)` | `cannot add string and integer` | `"a" + str(1)` |

Coercions that DO work (no error): `#emph("text")`, `#([a] + "b")`,
`#upper("abc")`. Dashed identifiers are legal: `#dict.a-b` works; for
quoted keys use `dict.at("a-b")`. Duplicate labels compile; references to
missing labels error with `label '<x>' does not exist in the document`.
`7 / 2` is `3.5` — integer division is `calc.quot(7, 2)`.

### 11.5 Context rules

```typst-broken
#counter(page).display() // ERROR: can only be used when context is known
```

```typst
#context counter(page).display() // right — counter/state/page/today need context
```

## 12. Document skeleton


```typst
// main.typ
#set document(title: "Report", author: "A. Author")
#set page(paper: "a4", margin: 2.5cm, numbering: "1")
#set text(font: "New Computer Modern", size: 11pt)
#set par(justify: true)
#set heading(numbering: "1.")

#align(center)[
  = Report Title
  #v(0.5em)
  A. Author #h(1em) October 2026
]

#outline(depth: 2)
#pagebreak()

= Introduction
#lorem(40)

== Background
#lorem(20)

#bibliography("refs.yml")
```

Templates: wrap everything in a function and apply with `#show: project`:

```typst
// template.typ
#let project(body) = {
  set page(paper: "a4", margin: 2cm, numbering: "1")
  set text(size: 11pt)
  set heading(numbering: "1.")
  show heading.where(level: 1): it => block(sticky: true)[#it]
  body
}

// main.typ
#import "template.typ": project
#show: project
= Document
…
```
