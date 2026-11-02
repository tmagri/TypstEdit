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
        let width = CGFloat(text.count) * scale * 0.5
        fragments.append(.init(font: font, point: origin, width: width, text: text))
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
    state.stack = []
    state.ctm = .identity
}

private func legacyOpFont(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    var ignored: CGPDFObjectRef?
    CGPDFScannerPopObject(scanner, &ignored)   // the size
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
}

private func legacyOpMoveLineAndLeading(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    let ty = legacyPopNumber(scanner) ?? 0, tx = legacyPopNumber(scanner) ?? 0
    state.leading = -ty
    state.textMatrix = state.textMatrix.translatedBy(x: tx, y: ty)
}

private func legacyOpLeading(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.leading = legacyPopNumber(scanner) ?? state.leading
}

private func legacyOpNextLine(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    state.textMatrix = state.textMatrix.translatedBy(x: 0, y: -state.leading)
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

/// `TJ`: an array of strings and kerning adjustments. A large negative
/// adjustment is a word gap.
private func legacyOpShowArray(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) {
    guard let state = legacyState(info) else { return }
    var array: CGPDFArrayRef?
    guard CGPDFScannerPopArray(scanner, &array), let array else { return }
    var text = ""
    for index in 0..<CGPDFArrayGetCount(array) {
        var element: CGPDFObjectRef?
        guard CGPDFArrayGetObject(array, index, &element), let element else { continue }
        var string: CGPDFStringRef?
        if CGPDFObjectGetValue(element, .string, &string), let string,
           let bytes = CGPDFStringGetBytePtr(string) {
            let data = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            text += String(data: data, encoding: .isoLatin1) ?? ""
            continue
        }
        if let adjustment = legacyNumberValue(element), adjustment < -200 { text += " " }
    }
    state.place(text)
}
