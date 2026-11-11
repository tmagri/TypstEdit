; HEADINGS (Blue Bold)
(heading) @type


; MARKUP (Purple + Bold/Italic)
(strong) @text.strong
(emph) @type_alternate

; HASHTAG COMMANDS (Purple)
"#" @function
(call item: (ident) @function)
; Method calls: `counter(page).get()`, `datetime.today().display(…)`,
; `calc.max(…)`, `outline.entry.where(…)` — only the called name, not the
; object it is called on.
(call item: (field field: (ident) @function))
(set (ident) @function)
(show (ident) @function)

; KEYWORDS (Purple)
(let "let" @keyword)
(set "set" @keyword)
(show "show" @keyword)
(import "import" @keyword)
(include "include" @keyword)
(branch ["if" "else"] @keyword)
(while "while" @keyword)
(for ["for" "in"] @keyword)
(return "return" @keyword)
(flow ["break" "continue"] @keyword)
(context "context" @keyword)

; VALUES
(number) @number
(string) @string
(bool) @boolean

; BRACKETS & PUNCTUATION
; Code-mode bracket pairs: `{ … }` code blocks, `[ … ]` content blocks and
; `( … )` groups. Without these the braces carry no capture at all and render
; as plain text, which reads as if a block never closes. Declared before the
; math section so a code group never falls through to the math @number rules
; (same anonymous tokens, earlier pattern wins).
(block ["{" "}"] @punctuation.bracket)
(content ["[" "]"] @punctuation.bracket)
(group ["(" ")"] @punctuation.bracket)
["," ";"] @punctuation.delimiter
":" @punctuation.delimiter
(field "." @punctuation.delimiter)

; OPERATORS
; Assignment, the lambda arrow, arithmetic and logic. `=` is the bare
; let-binding token (`#let x = 1`); named assignment nodes are aliased
; "assign" and matched separately.
"=" @operator
(lambda "=>" @operator)
(add "+" @operator)
(sub "-" @operator)
(mul "*" @operator)
(div "/" @operator)
(sign ["+" "-"] @operator)
(cmp ["==" "<=" ">=" "!=" "<" ">"] @operator)
(fraction "/" @operator)
(and "and" @operator)
(or "or" @operator)
(not "not" @operator)
(in ["in" "not"] @operator)
(as "as" @operator)

; COMMENTS
(comment) @comment

; CODE BLOCKS
[
  (raw_blck)
  (raw_span)
] @text.literal

; ESCAPES & LINE BREAKS
; An escaped backslash (\\) is a literal backslash character -> plain text.
; Declared BEFORE the general operator rule so its (lower) capture index wins
; precedence for the same node range.
(escape) @punctuation.delimiter
(#match? @punctuation.delimiter "^\\\\\\\\$")
; Every other escape sequence (\n, \t, \u{1F600}, ...) and a bare line-break
; backslash are operators -> styled distinctly, never confused with plain text.
(escape) @operator
(linebreak) @operator



; MATH (Yellow)
; Placed at the very bottom so it overrides any prior general matches (like call idents).
(math) @number
"$" @number
(formula) @number
(letter) @number
(symbol) @number
(fraction) @number
(attach) @number
(fac) @number
(align) @number
(formula (ident) @number)
(formula (call item: (ident) @number))
(group ["(" ")" "[" "]" "{" "}"] @number)
(apply ["(" ")" "[" "]" "{" "}"] @number)
"/" @number
"^" @number
