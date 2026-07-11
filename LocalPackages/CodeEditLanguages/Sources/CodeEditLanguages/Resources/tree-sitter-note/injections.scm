; Note (.note) injections.
;
; The primary grammar is Markdown, so we begin with the standard Markdown
; injections (fenced code blocks, HTML blocks, frontmatter, and the markdown-inline
; parser for inline content).
;
; The final rule overlays Typst across each (paragraph) node. Because injected
; layers take precedence over the primary layer in the highlight pipeline, Typst
; constructs inside paragraph text (#functions, $math$, =headings, *bold*,
; _italic_, // comments) are highlighted as Typst and win wherever they overlap
; with Markdown. Injecting per-paragraph (rather than over the whole document)
; is important: it leaves block-level Markdown structure (ATX headings, lists,
; tables, fenced code blocks, blockquotes) to the Markdown primary layer, and
; keeps each Typst parse small and fast. It also means "# ATX Heading" (a
; heading, not a paragraph) stays a Markdown heading, while "#func()" (a
; paragraph) is highlighted as Typst.

; --- Standard Markdown injections ---

(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

((html_block) @injection.content (#set! injection.language "html"))

(document . (section . (thematic_break) (_) @injection.content (thematic_break)) (#set! injection.language "yaml"))

([(minus_metadata) (plus_metadata)] @injection.content (#set! injection.language "yml"))

((inline) @injection.content (#set! injection.language "markdown_inline"))

; --- Typst overlay (the heart of the .note hybrid) ---

((paragraph) @injection.content (#set! injection.language "typst"))
