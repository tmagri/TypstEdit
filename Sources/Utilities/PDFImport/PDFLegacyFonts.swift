import Foundation
import PDFKit
import CoreGraphics

/// Text set in legacy fonts (`Bwhebb`, `Bwgrkl`, …), which map
/// Hebrew and Greek letters onto ASCII codes and carry no Unicode mapping.
///
/// Such a PDF's text layer holds `tyrb[b` where the page shows בעברית, so
/// without this the import produces mojibake. The tables below are character
/// substitutions — the font itself is never used, embedded, or required.
///
/// The tables were checked against *The Hebrew and Aramaic Lexicon of the Old
/// Testament* (study edition), which sets Hebrew in `Bwhebb` and
/// transliteration in `BwLexa`; the decoded words in `PDFLegacyFontTests` are
/// that book's own text.
///
/// What is not decoded: `BwLexa` (transliteration marks over Latin letters,
/// e.g. `Ò` for a macron) and the symbol fonts. An import that meets one says
/// so once, instead of passing its codes off as text.
enum PDFLegacyFonts {

    /// One stretch of text drawn with one font, as the page draws it.
    struct Fragment: Equatable {
        var font: String
        /// Where the text starts, in display space (points, y up).
        var point: CGPoint
        /// Approximate advance width in points, used only for matching.
        var width: CGFloat
        var text: String
        /// The size `Tf` set for this fragment (0 when unknown).
        var fontSize: CGFloat = 0
        /// Marked-content role of the enclosing `BDC`/`BMC` sequence:
        /// "header", "footer", or nil for ordinary body text. Producers
        /// tag running heads/footers/pagination as layout artifacts
        /// (`/Artifact <</Attached [/Top]/Type/Pagination/Subtype/Footer>>
        /// BDC`), the authoritative furniture signal Acrobat's own DOCX
        /// export consumes (sop.pdf: 117 markers; its header1/footer1.xml
        /// carry exactly the marked rows).
        var artifact: String? = nil
    }

    /// Kinds of legacy text we can decode.
    enum Encoding: Equatable {
        /// Hebrew written with ASCII codes, laid out right to left.
        case hebrew
        /// Greek written with ASCII codes, left to right.
        case greek
    }

    /// The encoding for a font name, or `nil` for fonts we leave alone.
    static func encoding(forFont name: String) -> Encoding? {
        switch baseName(name) {
        case "bwhebb", "bwhebl", "bwheba":
            return .hebrew
        case "bwgrkl", "bwgrkn", "bwgrki", "bwgrkd":
            return .greek
        default:
            return nil
        }
    }

    /// A font name without its subset prefix: "YUTWIP+Bwhebb" → "bwhebb".
    static func baseName(_ name: String) -> String {
        (name.split(separator: "+").last.map(String.init) ?? name).lowercased()
    }

    /// A font we do not decode (transliteration and symbol fonts),
    /// so the import can warn instead of printing its codes.
    static func isUndecodedLegacyFont(_ name: String) -> Bool {
        ["bwlexa", "bwlexs", "bwtransh", "bweess", "bweeti", "bwviet", "bwcopm", "bwcyrl",
         "bwsymbs", "bwsymbol"].contains(baseName(name))
    }

    /// Decodes one stretch of legacy text into Unicode.
    ///
    /// Hebrew is drawn right to left, so its codes arrive in visual order:
    /// reversing the whole run restores the reading order of both the words
    /// and the letters. Codes not in the table pass through unchanged, so
    /// nothing disappears silently.
    static func decode(_ text: String, as encoding: Encoding) -> String {
        switch encoding {
        case .hebrew: return String(text.reversed().map { hebrew[$0] ?? $0 })
        case .greek: return String(text.map { greek[$0] ?? $0 })
        }
    }

    /// Hebrew (`Bwhebb`): letters, final forms, and the maqaf.
    /// Codes not listed pass through unchanged.
    static let hebrew: [Character: Character] = [
        "a": "א", "b": "ב", "g": "ג", "d": "ד", "h": "ה", "w": "ו", "z": "ז",
        "x": "ח", "j": "ט", "y": "י", "k": "כ", "l": "ל", "m": "מ", "n": "נ",
        "s": "ס", "[": "ע", "p": "פ", "c": "צ", "q": "ק", "r": "ר", "X": "ש",
        "t": "ת",
        // Final forms.
        "K": "ך", "~": "ם", "!": "ן", "@": "ף", "C": "ץ",
        // Sin (draws it with the letter "v").
        "v": "שׂ",
        // The Hebrew hyphen.
        "-": "־",
    ]

    /// Greek (`Bwgrkl`, `Bwgrkn`): ASCII codes for Greek letters. A capital
    /// `V` is the final sigma, and a capital `S` the initial sigma.
    static let greek: [Character: Character] = [
        "a": "α", "b": "β", "g": "γ", "d": "δ", "e": "ε", "z": "ζ", "h": "η",
        "q": "θ", "i": "ι", "k": "κ", "l": "λ", "m": "μ", "n": "ν", "c": "ξ",
        "o": "ο", "p": "π", "r": "ρ", "s": "σ", "t": "τ", "u": "υ", "f": "φ",
        "x": "χ", "y": "ψ", "w": "ω",
        "S": "Σ", "V": "ς",
    ]

    // MARK: - Reading the page's text with its fonts

    /// Every text fragment the page draws, in drawing order, with the font
    /// that drew it.
    ///
    /// PDFKit reports a substitute font instead of the one a PDF embeds, so
    /// the content stream is read directly. Only the operators that place
    /// text matter: `q`/`Q`/`cm` (graphics state), `BT`/`ET`, `Tf` (font),
    /// `Tm`/`Td`/`TD`/`T*` (position) and `Tj`/`TJ`/`'` (the text).
    static func fragments(of page: PDFPage, displaySize: CGSize) -> [Fragment] {
        guard let pageRef = page.pageRef else { return [] }
        let content = CGPDFContentStreamCreateWithPage(pageRef)
        defer { CGPDFContentStreamRelease(content) }

        let state = LegacyScanState()
        state.display = page.transform(for: .cropBox)
        // `Tf` names a font resource ("F6"); its dictionary names the
        // embedded font ("YUTWIP+Bwhebb"), which is what identifies the
        // encoding.
        state.fontNames = fontNames(of: pageRef)

        let table = CGPDFOperatorTableCreate()!
        defer { CGPDFOperatorTableRelease(table) }
        // The callbacks are file-scope functions: a C function pointer cannot
        // be formed from a method or from a closure that captures anything.
        CGPDFOperatorTableSetCallback(table, "q", legacyOpSave)
        CGPDFOperatorTableSetCallback(table, "Q", legacyOpRestore)
        CGPDFOperatorTableSetCallback(table, "cm", legacyOpConcat)
        CGPDFOperatorTableSetCallback(table, "BT", legacyOpBeginText)
        CGPDFOperatorTableSetCallback(table, "Tf", legacyOpFont)
        CGPDFOperatorTableSetCallback(table, "Tm", legacyOpTextMatrix)
        CGPDFOperatorTableSetCallback(table, "Td", legacyOpMoveLine)
        CGPDFOperatorTableSetCallback(table, "TD", legacyOpMoveLineAndLeading)
        CGPDFOperatorTableSetCallback(table, "TL", legacyOpLeading)
        CGPDFOperatorTableSetCallback(table, "T*", legacyOpNextLine)
        CGPDFOperatorTableSetCallback(table, "Tj", legacyOpShow)
        CGPDFOperatorTableSetCallback(table, "TJ", legacyOpShowArray)
        CGPDFOperatorTableSetCallback(table, "'", legacyOpQuoteShow)
        // Marked content: the /Artifact properties dict names the layout
        // role (Header/Footer/Pagination), which drives furniture
        // detection downstream.
        CGPDFOperatorTableSetCallback(table, "BDC", legacyOpBeginMarkedProperties)
        CGPDFOperatorTableSetCallback(table, "BMC", legacyOpBeginMarkedTag)
        CGPDFOperatorTableSetCallback(table, "EMC", legacyOpEndMarked)

        let scanner = CGPDFScannerCreate(content, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        return state.fragments
    }

    // MARK: - Reading the page's fonts

    /// Font resource name → embedded font name for a page ("F6" →
    /// "YUTWIP+Bwhebb"), from the page's `/Resources /Font` dictionary.
    static func fontNames(of pageRef: CGPDFPage) -> [String: String] {
        guard let dictionary = pageRef.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef?
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return [:] }

        final class Box { var names: [String: String] = [:] }
        let box = Box()
        CGPDFDictionaryApplyFunction(fonts, { key, object, info in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            var font: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &font), let font else { return }
            var base: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(font, "BaseFont", &base), let base else { return }
            box.names[String(cString: key)] = String(cString: base)
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.names
    }

    // MARK: - Matching words to fonts

    /// A fragment in `fragments` that covers the tail of the x-span
    /// `[x, x + width]` on `baseline` with a clearly smaller font — the
    /// signature of a superscript glued into the same word by PDFKit
    /// ("mc2", "footnote1": no space, so no separate word box). Returns the
    /// fragment and the x where its smaller text starts, for word splitting.
    static func scriptTail(overX x: CGFloat, width wordWidth: CGFloat, baseline: CGFloat,
                           tolerance: CGFloat, dominantSize: CGFloat,
                           in fragments: [Fragment]) -> (fragment: Fragment, splitX: CGFloat)? {
        guard wordWidth > 2 else { return nil }
        var best: (fragment: Fragment, splitX: CGFloat)?
        for fragment in fragments {
            // Clearly smaller type than the word's own size.
            guard fragment.fontSize > 0, fragment.fontSize <= dominantSize * 0.8 else { continue }
            guard abs(fragment.point.y - baseline) <= max(tolerance, dominantSize * 0.5) else { continue }
            let start = fragment.point.x
            let end = fragment.point.x + fragment.width
            // Must cover the tail: start inside the word's right half and
            // reach at least the word's end.
            let tailStart = x + wordWidth / 2
            guard start > tailStart, start < x + wordWidth, end >= x + wordWidth - 2 else { continue }
            if best == nil || start > best!.splitX { best = (fragment, start) }
        }
        return best
    }

    /// The embedded font name of the fragment that covers the x-span
    /// `[x, x + width]` on the baseline band `baseline ± tolerance`, or `nil`
    /// when no fragment matches.
    ///
    /// Matching is geometric, not textual: CID-keyed fonts (Identity-H) draw
    /// opaque two-byte codes, so a fragment's `text` is garbage for every
    /// non-legacy PDF and text containment can never match. The fragment's
    /// `point` is the Tm origin in display space and `width` approximates
    /// the run's extent, which is all the word-to-font join needs.
    static func fontName(overX x: CGFloat, width wordWidth: CGFloat, baseline: CGFloat,
                         tolerance: CGFloat, in fragments: [Fragment]) -> String? {
        // A word belongs to the fragment that covers its midpoint: widths
        // are estimates (glyph count × 0.5 em), so midpoint coverage is the
        // strongest cheap test, and edge-touching fragments cannot smear
        // their style onto the neighbouring words.
        let mid = x + wordWidth / 2
        var best: (name: String, overlap: CGFloat)?
        for fragment in fragments {
            guard abs(fragment.point.y - baseline) <= tolerance else { continue }
            let start = fragment.point.x
            let end = fragment.point.x + fragment.width
            guard mid >= start, mid <= end else { continue }
            let overlap = min(end, x + wordWidth) - max(start, x)
            let name = baseName(fragment.font)
            if let current = best {
                if overlap > current.overlap { best = (name, overlap) }
            } else {
                best = (name, overlap)
            }
        }
        return best?.name
    }

    /// The marked-content role ("header"/"footer") of the fragment that
    /// covers the x-span `[x, x + width]` on `baseline ± tolerance`, or nil
    /// for ordinary body text. Same geometric midpoint rule as `fontName`.
    static func artifactRole(overX x: CGFloat, width wordWidth: CGFloat, baseline: CGFloat,
                             tolerance: CGFloat, in fragments: [Fragment]) -> String? {
        // Any positive overlap qualifies: the role comes from a producer's
        // own mark, so an over-strict containment rule only loses words
        // (widths are estimates; the first SOP header pass dropped
        // "Procedure:" because its fragment midpoint fell into a gap).
        // Largest overlap wins so a neighbouring body mark cannot steal.
        var best: (role: String, overlap: CGFloat)?
        for fragment in fragments {
            guard let role = fragment.artifact else { continue }
            guard abs(fragment.point.y - baseline) <= tolerance else { continue }
            let start = fragment.point.x
            let end = fragment.point.x + fragment.width
            let overlap = min(end, x + wordWidth) - max(start, x)
            guard overlap > 0 else { continue }
            if let current = best {
                if overlap > current.overlap { best = (role, overlap) }
            } else {
                best = (role, overlap)
            }
        }
        return best?.role
    }

    /// The encoding of the legacy-font fragment that drew `text`, on the line
    /// whose baseline is `baseline` (display y), or `nil` when the text came
    /// from an ordinary font.
    ///
    /// PDFKit supplies the words and their geometry; the fragments supply the
    /// font. A word matches the fragment that contains it on the same line.
    static func encoding(of text: String, baseline: CGFloat, tolerance: CGFloat,
                         in fragments: [Fragment]) -> Encoding? {
        let needle = text.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        for fragment in fragments {
            guard abs(fragment.point.y - baseline) <= tolerance else { continue }
            let fragmentText = fragment.text.trimmingCharacters(in: .whitespaces)
            guard fragment.text.contains(needle) || needle.contains(fragmentText), !fragmentText.isEmpty
            else { continue }
            if let encoding = encoding(forFont: fragment.font) { return encoding }
        }
        return nil
    }
}

// MARK: - Content stream walking

/// State carried between operators while a page's content stream is read.
/// Passed to the callbacks through the scanner's `info` pointer, because a C
/// function pointer cannot capture Swift values.
final class LegacyScanState {
    var font = ""
    /// Font resource name → embedded font name ("F6" → "YUTWIP+Bwhebb"),
    /// read from the page's font dictionary.
    var fontNames: [String: String] = [:]
    var textMatrix = CGAffineTransform.identity
    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var leading: CGFloat = 0
    var display = CGAffineTransform.identity
    var fragments: [PDFLegacyFonts.Fragment] = []
    /// Width already drawn on the current text line, in text space. Many
    /// producers draw a whole line as one `BT` with several `TJ` strings —
    /// one per style segment — and position each with the line's `Tm`, so
    /// every fragment would otherwise start at the line's left edge and
    /// mid-line style boundaries would be invisible to the word join.
    var drawnWidth: CGFloat = 0
    /// The font size last set by `Tf`, for advance estimates.
    var fontSize: CGFloat = 11
    /// Role of the enclosing marked-content sequence (`BDC`/`BMC` … `EMC`),
    /// ISO 32000-2 §14.8.2. Nested sequences resolve to the outermost
    /// pagination role.
    var artifact: String? = nil
    /// Stack of enclosing roles, because artifacts nest (sop.pdf nests a
    /// plain `BDC … EMC` inside the Header sequence).
    var artifactStack: [String?] = []

    func place(_ text: String) {
        guard !text.isEmpty, !font.isEmpty else { return }
        // Text is drawn at Tm's origin, rotated and scaled by Tm's linear
        // part, then mapped by the graphics state and display transforms.
        var linear = textMatrix
        linear.tx = 0
        linear.ty = 0
        let origin = CGPoint(x: textMatrix.tx, y: textMatrix.ty)
            .applying(linear)
            .applying(ctm)
            .applying(display)
        let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
        // Identity-H and other two-byte encodings deliver two latin-1 chars
        // per glyph; halve the count so the width estimates glyphs.
        let glyphCount = max(1, text.count / 2)
        let width = CGFloat(glyphCount) * fontSize * 0.5 * scale
        var start = origin
        if drawnWidth > 0 {
            // Advance the segment start along the line's direction. Lines
            // are horizontal in every layout we join words against, so the
            // x component alone is enough.
            let unit = CGPoint(x: linear.a, y: linear.b)
                .applying(ctm).applying(display)
            let length = max(0.001, sqrt(unit.x * unit.x + unit.y * unit.y))
            start.x += unit.x / length * drawnWidth
            start.y += unit.y / length * drawnWidth
        }
        fragments.append(.init(font: font, point: start, width: width, text: text,
                               fontSize: fontSize, artifact: artifact))
        drawnWidth += width
    }
}

private func legacyState(_ info: UnsafeMutableRawPointer?) -> LegacyScanState? {
    guard let info else { return nil }
    return Unmanaged<LegacyScanState>.fromOpaque(info).takeUnretainedValue()
}

private func legacyPopNumber(_ scanner: CGPDFScannerRef) -> CGFloat? {
    var real: CGPDFReal = 0
    if CGPDFScannerPopNumber(scanner, &real) { return CGFloat(real) }
    return nil
}

/// Six numbers popped in reverse order: CGPDFScanner yields operands last
/// first.
private func legacyPopNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat] {
    var values = [CGFloat](repeating: 0, count: count)
    for index in (0..<count).reversed() { values[index] = legacyPopNumber(scanner) ?? 0 }
    return values
}

private func legacyPopText(_ scanner: CGPDFScannerRef) -> String? {
    var string: CGPDFStringRef?
    guard CGPDFScannerPopString(scanner, &string), let string,
          let bytes = CGPDFStringGetBytePtr(string) else { return nil }
    let data = Data(bytes: bytes, count: CGPDFStringGetLength(string))
    return String(data: data, encoding: .isoLatin1)
}

/// A number operand, whether stored as an integer or a real.
private func legacyNumberValue(_ object: CGPDFObjectRef) -> CGFloat? {
    var real: CGPDFReal = 0
    if CGPDFObjectGetValue(object, .real, &real) { return CGFloat(real) }
    var integer: CGPDFInteger = 0
    if CGPDFObjectGetValue(object, .integer, &integer) { return CGFloat(integer) }
    return nil
}

private func legacyOpSave(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.stack.append(state.ctm)
}

private func legacyOpRestore(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info), let previous = state.stack.popLast() else { return }
    state.ctm = previous
}

private func legacyOpConcat(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    let v = legacyPopNumbers(scanner, 6)
    let matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    state.ctm = matrix.concatenating(state.ctm)
}

private func legacyOpBeginText(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.textMatrix = .identity
    state.drawnWidth = 0
    // `BT` resets the text matrix and text line parameters only. The CTM is
    // graphics state: it survives until `Q`, and many producers place every
    // text block with `q … cm … BT … ET Q`, so resetting it here put every
    // fragment at (0, 0) and broke the word-to-font join (testdoc.pdf).
}

private func legacyOpFont(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    var size: CGPDFReal = 0
    if CGPDFScannerPopNumber(scanner, &size) { state.fontSize = CGFloat(size) }
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return }
    let resource = String(cString: name)
    // The resource name identifies the font within the page; the dictionary
    // maps it to the embedded font, which is what names the encoding.
    state.font = state.fontNames[resource] ?? resource
}

private func legacyOpTextMatrix(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    let v = legacyPopNumbers(scanner, 6)
    state.textMatrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
}

private func legacyOpMoveLine(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    let ty = legacyPopNumber(scanner) ?? 0, tx = legacyPopNumber(scanner) ?? 0
    state.textMatrix = state.textMatrix.translatedBy(x: tx, y: ty)
    state.drawnWidth = 0
}

private func legacyOpMoveLineAndLeading(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    let ty = legacyPopNumber(scanner) ?? 0, tx = legacyPopNumber(scanner) ?? 0
    state.leading = -ty
    state.textMatrix = state.textMatrix.translatedBy(x: tx, y: ty)
    state.drawnWidth = 0
}

private func legacyOpLeading(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.leading = legacyPopNumber(scanner) ?? state.leading
}

private func legacyOpNextLine(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.textMatrix = state.textMatrix.translatedBy(x: 0, y: -state.leading)
    state.drawnWidth = 0
}

private func legacyOpShow(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info), let text = legacyPopText(scanner) else { return }
    state.place(text)
}

private func legacyOpQuoteShow(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.textMatrix = state.textMatrix.translatedBy(x: 0, y: -state.leading)
    if let text = legacyPopText(scanner) { state.place(text) }
}

/// `TJ`: an array of strings and kerning adjustments. Each string is placed
/// as its own fragment at its own x so mid-line font switches become visible
/// to the word join (styled segments are separate TJ strings). A large
/// negative adjustment is a word gap.
private func legacyOpShowArray(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    var array: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &array), let array else { return }
    for index in 0..<CGPDFArrayGetCount(array) {
        var element: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, index, &element), let element else { continue }
        var string: CGPDFStringRef?
        if CGPDFObjectGetValue(element, .string, &string), let string,
           let bytes = CGPDFStringGetBytePtr(string) {
            let data = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            state.place(String(data: data, encoding: .isoLatin1) ?? "")
            continue
        }
        // Kerning adjustments shift the pen in thousandths of text space.
        if let adjustment = legacyNumberValue(element) {
            state.drawnWidth += adjustment < -200 ? -adjustment / 1000 + state.fontSize * 0.3
                                                  : -adjustment / 1000
        }
    }
}

// MARK: - Marked content (ISO 32000-2 §14.8.2)

private func legacyOpBeginMarkedProperties(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    // `tag properties` — pop the properties dict, then the tag name.
    var object: CGPDFObjectRef?
    guard CGPDFScannerPopObject(scanner, &object), let object else { return }
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return }
    let tag = String(cString: name)
    state.artifactStack.append(state.artifact)
    guard tag == "Artifact" else { state.artifact = nil; return }
    // The properties dictionary may be inline or a resource reference;
    // only the inline `/Artifact <</Type/Pagination/Subtype/Header>>`
    // form names the role. An unreadable dict is an untyped artifact:
    // no role, so body-text handling applies.
    var dict: CGPDFDictionaryRef?
    guard CGPDFObjectGetValue(object, .dictionary, &dict), let dict else { state.artifact = nil; return }
    var typeName: UnsafePointer<CChar>?
    var subtypeName: UnsafePointer<CChar>?
    CGPDFDictionaryGetName(dict, "Type", &typeName)
    CGPDFDictionaryGetName(dict, "Subtype", &subtypeName)
    guard let t = typeName.map(String.init), t == "Pagination" else { state.artifact = nil; return }
    switch subtypeName.map(String.init) {
    case "Header": state.artifact = "header"
    case "Footer": state.artifact = "footer"
    default: break
    }
}

private func legacyOpBeginMarkedTag(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name) else { return }
    state.artifactStack.append(state.artifact)
    // A bare tag adds no role: keep the enclosing one (real files nest
    // `BMC … EMC` inside an Artifact sequence).
}

private func legacyOpEndMarked(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info), let restored = state.artifactStack.popLast() else { return }
    state.artifact = restored
}
