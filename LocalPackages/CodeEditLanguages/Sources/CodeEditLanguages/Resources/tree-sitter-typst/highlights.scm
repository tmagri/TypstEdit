; HEADINGS (Blue Bold)
(heading) @type

; MATH (Yellow)
(math) @number
"$" @number

; MARKUP (Purple + Bold/Italic)
(strong) @keyword
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
