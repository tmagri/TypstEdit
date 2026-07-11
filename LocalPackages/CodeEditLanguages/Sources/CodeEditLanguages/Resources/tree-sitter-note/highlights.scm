; Note (.note) block-level highlighting.
; Mirrors tree-sitter-markdown/highlights.scm — the primary grammar for note
; files is Markdown. Typst constructs are overlaid separately via the note
; injections layer (see injections.scm), and take precedence wherever they apply.

;; Headings
(atx_heading (inline) @text.title)
(setext_heading (paragraph) @text.title)

;; Heading markers (dim the leading ### / underlines)
[
  (atx_h1_marker)
  (atx_h2_marker)
  (atx_h3_marker)
  (atx_h4_marker)
  (atx_h5_marker)
  (atx_h6_marker)
  (setext_h1_underline)
  (setext_h2_underline)
] @punctuation.special

;; Code blocks
[
  (indented_code_block)
  (fenced_code_block)
  (link_title)
] @text.literal

(fenced_code_block_delimiter) @punctuation.delimiter

(info_string (language) @keyword)

(code_fence_content) @none

;; Links & reference definitions
(link_destination) @text.uri

[
  (link_label)
] @text.reference

(link_reference_definition
  ":" @punctuation.delimiter)

;; Lists
[
  (list_marker_plus)
  (list_marker_minus)
  (list_marker_star)
  (list_marker_dot)
  (list_marker_parenthesis)
] @text.list

;; Task lists ([x] done vs [ ] open)
(task_list_marker_checked) @boolean
(task_list_marker_unchecked) @text.list

;; Tables
(pipe_table_header "|" @punctuation.special)
(pipe_table_row "|" @punctuation.special)
(pipe_table_delimiter_row "|" @punctuation.special)
(pipe_table_delimiter_cell) @punctuation.delimiter

;; Blockquotes
[
  (block_continuation)
  (block_quote_marker)
] @text.quote

;; Thematic break (---)
(thematic_break) @text.strike

;; Frontmatter (YAML/TOML). The injections.scm normally parses these,
;; the capture is a fallback when injection is unavailable.
[
  (minus_metadata)
  (plus_metadata)
] @text.literal

;; Escapes
[
  (backslash_escape)
] @punctuation.special
