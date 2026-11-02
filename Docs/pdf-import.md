# PDF import

**File → Import → PDF…** converts a PDF to a Typst file. Figures are saved as PNG files in a folder next to the new file. You can also save the result as Markdown and JSON.

The import runs on your Mac. It uses only Apple frameworks (PDFKit and Vision). It does not download models. The PDF leaves your Mac only if you turn on the AI option, and then only as cropped images of formulas and tables.

## Import a PDF

1. Select **File → Import → PDF…** (⇧⌥⌘I).
2. Select the PDF.
3. Optional: in **Pages**, enter a page or a range, for example `201-260`. Leave it empty to import all pages.
4. Optional: select **Use AI for formulas and complex tables**. This option is available only when AI Chat is on.
5. Optional: select **Also save Markdown and JSON**.
6. Click **Import**.

If the PDF is outside the open project, select **Add to Project** or **Open PDF Folder**. If a Typst file with the same name exists, select **Replace** or **Keep Both**.

For more than 150 pages with no range, the app asks you to confirm and shows an estimated time. The import takes approximately 0.3 to 1 second for each page.

Search the new file for `TODO(import)`. This marker shows each formula and table that you must examine.

## Import with OCR only

Use **File → Import → PDF (Force OCR)…** when the imported text is incorrect. This can occur when a PDF has an incorrect text encoding or an old, poor OCR layer. This command ignores the text in the PDF. It reads each page from its image with on-device OCR.

## What the import finds

| Content | How it is found |
|---|---|
| Text | From the text layer of the PDF. On scanned pages that have no text layer, from Vision OCR. |
| Reading order | Columns are separated with a recursive XY-cut. A centred line that crosses the column gap, for example an author line, stays one line. |
| Paragraphs | From line spacing and indents. Words hyphenated at line ends are joined. A paragraph broken by a column or page is joined again. |
| Headings | From the PDF bookmarks, if there are bookmarks. If not, from font size, weight, capitals, numbering ("2.1 Results") and the space around the line. |
| Lists | Bullets and numbers. Labels such as "(IV)" and "(a)" are kept as written. |
| Ruled tables | From the lines that draw the cells. Merged cells become `rowspan` and `colspan`. Column widths are kept. A table that continues on the next page becomes one table. |
| Other tables | From text alignment, and from terms with descriptions (a glossary or a site chart). |
| Code samples | A box of code lines becomes a raw block. Line breaks and indents are kept. |
| Figures | Ink on the page that is not text, cropped to PNG with its caption. |
| Formulas | Display formulas become images. With AI, they become Typst math. |
| Page furniture | Running headers, footers and page numbers are removed. A printed table of contents becomes `#outline()`. |

## Scanned PDFs

A page is scanned if it shows one large image of the page.

- **A scan with an OCR text layer** (from most scanners and archives): the import uses the text layer. Font sizes in such layers are not correct, so the import does not use size to find headings. It uses weight, capitals, numbering and space.
- **A scan without a text layer**: Vision document recognition (macOS 26 or later) finds paragraphs, titles, lists and tables. On earlier macOS versions, the import reads lines with OCR and then does the layout itself.

## Use AI for formulas and complex tables

The import uses the **Chat & Actions** model. The model must accept images.

- **Formulas**: the import sends each formula image. The model returns LaTeX. The bundled `tex2typst` converts it to Typst math.
- **Complex tables**: these are tables that the import cannot read clearly, for example tables without lines that have spans. The import sends each table image. The model returns the cells.

If the model cannot read an item, the item stays an image. A `TODO(import)` comment holds the text that the import found. Results from AI also get a `TODO(import)` comment so that you can examine them.

### Local models

Many local servers (LM Studio, Ollama, llama.cpp) do one request at a time and put other requests in a queue. With a local model, the import:

- Sends one request at a time.
- Before each request, waits up to 30 seconds while the server is busy. TypstEdit counts the requests that it sends to the server: chat, completions, embeddings and imports.
- Waits 5 seconds and tries again, two times at most, if the server sends "busy" (HTTP 503 or 429).
- Stops using AI for the rest of the import if the server stays busy or does not answer in time. The remaining items stay images. A note gives the server name.

Requests from other apps to the same server are not counted.

## Use PDFs in AI Chat

AI Chat has two tools for PDFs in the project:

- **`read_pdf`** gives the PDF text to the model as Markdown, with tables, headings and code. It writes no files. It reads 40 pages at most in each call. If you give no page range, it reads the first 20 pages.
- **`import_pdf`** makes a Typst file, the same as the menu command. You must approve the import first. The approval shows the destination, the pages and the AI model, if the import uses AI. It imports 150 pages at most in each call. Plan mode does not offer this tool.

For example, "Summarise chapter 2 of manual.pdf" uses `read_pdf`. "Import pages 12–30 of manual.pdf as Typst" uses `import_pdf`.

## Known limits

- A chart with two columns of related rows and no lines, for example "Letters | Acts", is read one column at a time.
- Formulas without AI stay images.
- On very old scans, OCR errors from the scanner or from Vision stay in the text.
