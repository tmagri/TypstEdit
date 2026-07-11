;; From nvim-treesitter/nvim-treesitter
;; Code spans
[
  (code_span)
  (link_title)
] @text.literal

(code_span_delimiter) @punctuation.special

;; Emphasis (italic)
(emphasis) @text.emphasis
(emphasis_delimiter) @punctuation.special

;; Strong emphasis (bold)
(strong_emphasis) @text.strong

;; Strikethrough
(strikethrough) @text.strike

;; Links
[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @text.uri

[
  (link_label)
  (link_text)
  (image_description)
] @text.reference

(inline_link ["[" "]" "(" ")"] @punctuation.delimiter)
(shortcut_link ["[" "]"] @punctuation.delimiter)
(image ["!" "[" "]" "(" ")"] @punctuation.delimiter)

;; Inline HTML
(html_tag) @text.literal

;; Escapes & line breaks
[
  (backslash_escape)
  (hard_line_break)
] @punctuation.special

; NOTE: extension not enabled by default
; (wiki_link ["[" "|" "]"] @punctuation.delimiter)
