; HEADINGS
(heading "=" @type) @markup.heading.1
(heading "==" @type) @markup.heading.2
(heading "===" @type) @markup.heading.3
(heading "====" @type) @markup.heading.4
(heading "=====" @type) @markup.heading.5
(heading "======" @type) @markup.heading.6

; FUNCTIONS & COMMANDS
(call item: (ident) @function)
(call item: (field field: (ident) @function.method))
(tagged field: (ident) @attribute)
(field field: (ident) @attribute)
"#" @keyword.operator

; KEYWORDS
(let "let" @keyword.storage.type)
(branch ["if" "else"] @keyword.control.conditional)
(while "while" @keyword.control.repeat)
(for ["for" "in"] @keyword.control.repeat)
(import "import" @keyword.control.import)
(as "as" @keyword.operator)
(include "include" @keyword.control.import)
(show "show" @keyword.control)
(show (ident) @function) 
(set "set" @keyword.control)
(set (ident) @function)
(return "return" @keyword.control)
(flow ["break" "continue"] @keyword.control)
(in ["in" "not"] @keyword.operator)
(context "context" @keyword.control)
(and "and" @keyword.operator)
(or "or" @keyword.operator)
(not "not" @keyword.operator)

; OPERATORS
(sign ["+" "-"] @operator)
(add "+" @operator)
(sub "-" @operator)
(mul "*" @operator)
(div "/" @operator)
(cmp ["==" "<=" ">=" "!=" "<" ">"] @operator)
(fraction "/" @operator)
(fac "!" @operator)
(attach ["^" "_"] @operator)
(wildcard) @operator
(align) @operator

; VALUES & CONSTANTS
(number) @constant.numeric
(string) @string
(bool) @constant.builtin.boolean
(none) @constant.builtin
(auto) @constant.builtin
(ident) @variable
(label) @attribute
(ref) @attribute

; MARKUP
(comment) @comment
(emph) @comment ; Italic
(strong) @keyword ; Bold
(symbol) @constant.character
(shorthand) @constant.builtin
(quote) @markup.quote
(letter) @constant.character
(linebreak) @constant.builtin
(url) @tag
(raw_blck "```" @operator) @markup.raw.block
(raw_span "`" @operator) @markup.raw.block
(raw_blck lang: (ident) @attribute)
(content ["[" "]"] @operator)

; MATH
(math "$" @operator) @keyword.operator
"end" @operator

; MISC
(escape) @constant.character.escape
["(" ")" "{" "}"] @punctuation.bracket
["," ";" ".." ":" "sep"] @punctuation.delimiter
"assign" @punctuation
(field "." @punctuation)
