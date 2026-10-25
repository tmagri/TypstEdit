# Styling Recipes — custom formatting cookbook

Show-rule and layout idioms that local models typically get wrong. Every
snippet below is self-contained and was compiled with the vendored Typst
(0.15.x). Read this before writing custom formatting; look up exact parameter
names in `function-catalog.md`.

## 1. Tables: breakable or not

`breakable` lives on `block`, **not** on `table` — `#set table(breakable: …)`
errors with "unexpected argument: breakable". Route the set rule through the
table element with a *show-set* rule:

```typst
// Convention for the whole document: tables never split across a page break;
// Typst pushes a whole table to the next page instead of tearing it apart.
#show table: set block(breakable: false)

= Spec
#table(columns: 2, [Parameter], [Value], [Voltage], [5 V])
```

Long tables should stay breakable — pair with a repeating header:

```typst
#table(
  columns: 2,
  table.header([Item], [Qty]), // re-renders on every page the table spans
  ..range(20).map(i => ([Item #i], [#i])).flatten()
)
```

One-off unbreakable tables: wrap in `#block(breakable: false)[ … ]`.

## 2. Raw blocks: restyle without losing syntax highlighting

Keep the raw ELEMENT (`it`) intact. Re-emitting `it.text` (or `it.body`)
line-by-line renders plain text and silently discards Typst's token colors:

```typst
#show raw.where(block: true): it => {
  set text(font: ("Menlo", "Courier New", "DejaVu Sans Mono"), size: 8pt)
  set par(justify: false, leading: 0.5em)
  block(width: 100%, breakable: true, fill: luma(245), inset: 8pt)[#it]
}

#raw(block: true, "fn main() { println!(\"hi\"); }")
```

The `set` rules inside a transformational show rule scope to that rule's
output — no global restyle. `breakable: true` lets long listings split
across pages.

## 3. Table of contents: per-level entry styling

Rules chain: the `where(level:)` rules run first, the general `outline.entry`
rule wraps their output. Depth scaling uses `calc.pow` on `1em`.

```typst
#show outline.entry.where(level: 1): it => {
  set text(weight: "bold")
  it
}
#show outline.entry.where(level: 2): it => {
  set text(weight: "medium", style: "italic")
  it
}
#show outline.entry: it => {
  let exponent = calc.max(0, it.level - 2)
  let scale-factor = calc.pow(0.9, exponent)
  text(size: scale-factor * 1em, it)
}

= Architecture
== Overview
= Details
#outline(depth: 2)
```

## 4. Every level-1 heading starts a new page — with guards

A *weak* column break is skipped when the heading is already at the top of
its page, so a heading that opens the document creates no blank page. The
counter guard skips the first N level-1 headings (front matter):

```typst
#show heading.where(level: 1): it => {
  context {
    if counter(heading).get().first() >= 4 {
      colbreak(weak: true)
    }
  }
  it
}

= Document Control
Front matter.
= Introduction
Body starts here.
= Design
More body.
```

Reading `counter(heading)` requires the `context` wrapper — without it:
"can only be used when context is known". Use `pagebreak(weak: true)` in
single-column documents that don't use columns.

## 5. Title page block

`\` breaks lines inside markup; `#v(…)` adds spacing; dashed identifiers are
valid bindings (`#let doc-title = …`):

```typst
#let doc-title = "Product Specification"
#let doc-subtitle = "Widget Family"
#let doc-reference = "SPEC-001"
#let doc-version = "2.1"
#let doc-date = "October 2026"
#let doc-owner = "Engineering"
#let doc-recipient = "Manufacturing"

#align(center)[
  #text(18pt, weight: "bold")[#doc-title] \
  #v(0.5em)
  #text(14pt)[#doc-subtitle] \
  #v(0.5em)
  #text(11pt)[*Document reference:* #doc-reference] \
  #text(11pt)[*Version:* #doc-version | *Date:* #doc-date] \
  #text(11pt)[*Owner:* #doc-owner | *Recipient:* #doc-recipient]
]
```

Trap: `#doc-title = "X"` in markup is a variable *read* followed by literal
text — assignments need `#let` (or a code block).

## 6. Custom List of Figures with short titles

`figure.where(kind: image)` selects figure elements; the counter looked up
`.at(it.element.location())` gives the figure's number; `it.indented(…)`,
`it.prefix()`, `it.fill`, `it.page()` reassemble the entry line. Real image
files can be replaced by placeholder boxes — the `kind` is what matters:

```typst
#let figure-list-titles = ("The first chart", "The second chart")

#figure(
  box(width: 100%, height: 40pt, fill: luma(230)),
  kind: image, caption: [Full descriptive caption one]
)
#figure(
  box(width: 100%, height: 40pt, fill: luma(230)),
  kind: image, caption: [Full descriptive caption two]
)

#block[
  #show outline.entry: it => {
    set text(weight: "regular", style: "normal")
    let figure-number = counter(figure.where(kind: image)).at(it.element.location()).first()
    let short-name = figure-list-titles.at(figure-number - 1)
    link(
      it.element.location(),
      it.indented(it.prefix(), [
        #short-name #box(width: 1fr, it.fill) #it.page()
      ]),
    )
  }
  #outline(title: [List of Figures], target: figure.where(kind: image))
]
```

The wrapping `#block[ … ]` scopes the show rule so the main table of contents
keeps its own styling.

## 7. Context, counters, locations

```typst
#set page(
  numbering: "1 / 1",
  header: context {
    if counter(page).get().first() > 1 [running header]
  },
  footer: align(center)[#context counter(page).display("1 / 1")],
)

= Section <intro>
#context [Page #counter(page).display(), heading #counter(heading).display()]
#context counter(heading).update(2) // renumber from 2 if needed
```

Rules of thumb:

- Anything reading `counter`, `state`, `page`, `here`, `today`, `query`
  results needs `context`.
- `counter(x).get()` = value at the current position; `counter(x).at(loc)` =
  value at a location (e.g. `it.element.location()`).
- `counter(page).display("1 / 1")` renders formatted; `.update(n)` mutates.
- Counters can be scoped by selector: `counter(figure.where(kind: image))`.

## 8. Show-rule gotchas

- **Always return `it`.** A transformational rule that forgets `it` makes the
  element vanish (`#show heading: it => { … }` with no `it` erases headings).
- **Keep elements intact.** Emit `it` (e.g. `[#it]`) rather than rebuilding
  content from `it.body`/`it.text` — rebuilding drops syntax highlighting,
  links, labels and counter wiring.
- **Rule order matters.** Later `show` rules apply to the output of earlier
  ones; `show: template` (the "root" rule) runs innermost-last and wraps the
  whole document.
- **Show-set pattern.** Element params you want to change often live on the
  wrapping block (`breakable`, `fill`, `inset`), not on the element: route
  with `#show table: set block(breakable: false)`.
- **Weak vs strong breaks.** `pagebreak(weak: true)` / `colbreak(weak: true)`
  are skipped at the top of a page/column — never create blank pages. Strong
  breaks always break; use them only for deliberate empty space.
- **Scope rules** with `block[ … ]` or `#[ … ]` when one region needs
  different styling (e.g. a List of Figures that differs from the ToC).
