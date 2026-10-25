# Dates and Times

Validated against the vendored Typst (0.15.x). The #1 trap: **Typst has no
wall-clock time** — builds must be reproducible, so there is a *today* but no
*now*. Everything below was executed against the real compiler.

## The right way to print today's date

```typst
#let display-date = datetime.today().display("[month repr:long] [day], [year]")

Version *#display-date*
```

`datetime.today()` needs **no** `context` — it is not layout state. In
markup the line needs its `#`: `#let display-date = …` (a bare
`let display-date = …` renders as literal text).

## Pattern grammar (component + modifiers)

Components in `[brackets]`; modifiers are `key: value` pairs separated by
spaces, and they are **component-specific**:

| Component | Renders | Valid modifiers | Invalid (verified errors) |
|---|---|---|---|
| `[year]` | 2026 | `padding:zero` | `repr:pad` |
| `[month]` | 10 (numeric default) | `repr:long`, `repr:short` | `repr:number` |
| `[day]` | 25 | `padding:zero` | `repr:pad` |
| `[weekday repr:long]` | Saturday | `repr:short` | `padding:…` |
| `[hour repr:24 padding:zero]` | 09 | `repr:12`, `padding` | — |
| `[minute padding:zero]` / `[second padding:zero]` | 07 / 03 | `padding` | `repr:pad` |

An unknown component errors with
`invalid component name 'birthday' at index 1`; an unknown modifier with
`invalid modifier 'repr' at index N` (N = position inside the pattern).

## The traps (all verified)

| Broken | Compiler says | Right |
|---|---|---|
| `datetime.now()` | `type datetime does not contain field 'now'` | `datetime.today()` — there is no wall-clock time |
| `today` (bare, in code) | `unknown variable: today` | `datetime.today()` — the old global was removed |
| `d.year` (no parens) | `cannot access fields on type datetime` | `d.year()` — components are *methods* |
| `d.display` (no parens) | `cannot access fields on type datetime` | `d.display("[year]")` — must call it |
| `d.strftime("%B %d, %Y")` | `type datetime has no method 'strftime'` | `d.display("[month repr:long] [day repr:pad]…")` — Typst patterns, not C `strftime` |
| `.display(pattern: "[year]")` | `unexpected argument: pattern` | `.display("[year]")` — positional only |
| `today().display("[hour]")` | `failed to format datetime (insufficient information)` | `today()` is **date-only** — time components need an explicit `datetime(…, hour:, minute:, second:)` |

Also silent: `datetime.today()` in markup *without* `#` renders as the
literal text "datetime.today()".

## Recipes

Construct a fixed date, compare deadlines, do date math:

```typst
#let deadline = datetime(year: 2026, month: 12, day: 31)
#let today = datetime.today()

#if today > deadline [ Overdue ] else [ Due #deadline.display("[month repr:short] [day], [year]") ]

#(deadline - today).days() days remaining
#(today + duration(days: 30)).display("[month repr:long] [day], [year]")
```

Weekday (1 = Monday … 7 = Sunday) and debugging:

```typst
#datetime.today().weekday()
#repr(datetime.today()) // datetime(year: …, month: …, …) — handy in the error panel
```

A date in a running page header (context only needed for the *counter*, not
the date):

```typst
#set page(header: [
  #datetime.today().display("[month repr:long] [day], [year]")
  #h(1fr)
  #context counter(page).display("1 / 1")
])
```
