; HEADINGS (Blue Bold)
(heading) @type

; MATH (Yellow)
(math) @number
"$" @number

; MARKUP (Purple + Bold/Italic)
(strong) @text.strong
(emph) @type_alternate

; HASHTAG COMMANDS (Purple)
"#" @function
(call item: (ident) @function)
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
