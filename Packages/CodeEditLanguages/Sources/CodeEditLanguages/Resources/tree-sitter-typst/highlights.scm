(call
  item: (ident) @function)
(call
  item: (field field: (ident) @function.method))
(tagged field: (ident) @attribute)
(field field: (ident) @attribute)
(comment) @comment

; CONTROL
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

; OPERATOR
(in ["in" "not"] @keyword.operator)
(context "context" @keyword.control)
(and "and" @keyword.operator)
(or "or" @keyword.operator)
(not "not" @keyword.operator)
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

; VALUE
(raw_blck "```" @operator) @markup.raw.block
(raw_span "`" @operator) @markup.raw.block
(raw_blck lang: (ident) @attribute)
(label) @attribute
(ref) @attribute
(number) @constant.numeric
(string) @string
(content ["[" "]"] @operator)
(bool) @constant.builtin.boolean
(none) @constant.builtin
(auto) @constant.builtin
(ident) @variable

; MARKUP
(item "-" @markup.list)
(term ["/" ":"] @markup.list)
(heading "=" @type) @type
(heading "==" @type) @type
(heading "===" @type) @type
(heading "====" @type) @type
(heading "=====" @type) @type
(heading "======" @type) @type
(url) @tag
(emph) @comment
(strong) @keyword
(symbol) @constant.character
(shorthand) @constant.builtin
(quote) @markup.quote
(align) @operator
(letter) @constant.character
(linebreak) @constant.builtin

(math "$" @operator)
"#" @keyword
"end" @operator

(escape) @constant.character.escape
["(" ")" "{" "}"] @punctuation.bracket
["," ";" ".." ":" "sep"] @punctuation.delimiter
"assign" @punctuation
(field "." @punctuation)
