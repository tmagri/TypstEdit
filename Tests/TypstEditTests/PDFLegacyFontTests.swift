import XCTest
import PDFKit
@testable import TypstEdit

/// Legacy fonts: the character tables, the code decoding, and one page built
/// by hand that uses a font actually named `Bwhebb` (and `BwLexa`), so the
/// whole pipeline — content-stream font scanning, decoding, and the text
/// layer — is exercised without needing a real BibleWorks PDF on this Mac.
///
/// The decoding tests need no files at all: the tables and the substitution
/// are pure functions, so they run on any machine.
final class PDFLegacyFontTests: XCTestCase {

    // MARK: - Tables

    func testHebrewLettersAndFinalForms() {
        XCTAssertEqual(PDFLegacyFonts.decode("tyrb[b", as: .hebrew), "בעברית")
        XCTAssertEqual(PDFLegacyFonts.decode("!y[", as: .hebrew), "עין")
        XCTAssertEqual(PDFLegacyFonts.decode("Klm", as: .hebrew), "מלך")
        XCTAssertEqual(PDFLegacyFonts.decode("~wy", as: .hebrew), "יום")
        XCTAssertEqual(PDFLegacyFonts.decode("@sa", as: .hebrew), "אסף")
        // Each final form maps to its letter, not to the ordinary form.
        XCTAssertEqual(PDFLegacyFonts.hebrew["K"], "ך")
        XCTAssertEqual(PDFLegacyFonts.hebrew["~"], "ם")
        XCTAssertEqual(PDFLegacyFonts.hebrew["!"], "ן")
        XCTAssertEqual(PDFLegacyFonts.hebrew["@"], "ף")
        XCTAssertEqual(PDFLegacyFonts.hebrew["C"], "ץ")
        // Sin is drawn with "v" and carries its own dot; the maqaf with "-".
        XCTAssertEqual(PDFLegacyFonts.decode("vdq-ynba", as: .hebrew), "אבני־קדשׂ")
    }

    func testHebrewWordsFromTheBook() {
        // Words as they appear in the lexicon this table was checked against.
        // Verified against a rendering of the page: "~[ bkX" shows שכב עם,
        // and "la @san" shows נאסף אל.
        XCTAssertEqual(PDFLegacyFonts.decode(" wytwba", as: .hebrew), "אבותיו ")
        XCTAssertEqual(PDFLegacyFonts.decode("~[ bkX", as: .hebrew), "שכב עם")
        XCTAssertEqual(PDFLegacyFonts.decode("la @san", as: .hebrew), "נאסף אל")
        XCTAssertEqual(PDFLegacyFonts.decode("tw[mXm", as: .hebrew), "משמעות")
    }

    func testGreekLetters() {
        XCTAssertEqual(PDFLegacyFonts.decode("logoV", as: .greek), "λογος")
        XCTAssertEqual(PDFLegacyFonts.decode("kardia", as: .greek), "καρδια")
    }

    func testUnmappedCodesPassThrough() {
        // Nothing disappears silently: codes without a letter are kept, in
        // the order Hebrew is read (the codes reverse).
        XCTAssertEqual(PDFLegacyFonts.decode("a9b", as: .hebrew), "ב9א")
        XCTAssertEqual(PDFLegacyFonts.decode("a9b", as: .greek), "α9β")
    }

    // MARK: - Font names

    func testSubsetPrefixIsStripped() {
        XCTAssertEqual(PDFLegacyFonts.baseName("YUTWIP+Bwhebb"), "bwhebb")
        XCTAssertEqual(PDFLegacyFonts.baseName("Bwhebb"), "bwhebb")
        XCTAssertEqual(PDFLegacyFonts.encoding(forFont: "YUTWIP+Bwhebb"), .hebrew)
        XCTAssertEqual(PDFLegacyFonts.encoding(forFont: "BWGRKL"), .greek)
        XCTAssertNil(PDFLegacyFonts.encoding(forFont: "TimesNewRoman"))
    }

    func testUndecodedLegacyFontsAreRecognised() {
        XCTAssertTrue(PDFLegacyFonts.isUndecodedLegacyFont("YURGAP+BwLexa"))
        XCTAssertFalse(PDFLegacyFonts.isUndecodedLegacyFont("YUTWIP+Bwhebb"))
        XCTAssertFalse(PDFLegacyFonts.isUndecodedLegacyFont("Helvetica"))
    }

    // MARK: - Replacing codes inside a run

    /// PDFKit splits words where it likes, so a Hebrew fragment can start in
    /// the middle of a "word" ("ytwylkw(Lesëonenu"). The codes are found as a
    /// run of characters, ignoring whitespace.
    func testCodesAreReplacedInsideAMixedRun() {
        let fragment = PDFLegacyFonts.Fragment(font: "YUTWIP+Bwhebb", point: CGPoint(x: 36, y: 71),
                                               width: 120, text: "tyrb[b")
        XCTAssertEqual(PDFPageExtractor.replacingLegacy(in: "The word tyrb[b appears here.", fragments: [fragment]),
                       "The word בעברית appears here.")
        XCTAssertEqual(PDFPageExtractor.replacingLegacy(in: "45 ytwylkw tyrb[b— 1981", fragments: [fragment]),
                       "45 ytwylkw בעברית— 1981")
    }

    func testWhitespaceInsensitiveRange() {
        let text = "a tyrb[b b"
        let range = PDFPageExtractor.whitespaceInsensitiveRange(of: "tyrb[b", in: text)
        XCTAssertNotNil(range)
        XCTAssertEqual(text[range!], "tyrb[b")
        XCTAssertNil(PDFPageExtractor.whitespaceInsensitiveRange(of: "zzz", in: text))
    }

    // MARK: - A synthetic page using real `Bwhebb` / `BwLexa` font resources

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-font-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// Builds a one-page PDF, by hand, whose `Resources /Font` dictionary
    /// names fonts `Bwhebb` and `YURGAP+BwLexa` — exactly how a real
    /// BibleWorks PDF names them. The content stream draws a standalone
    /// Hebrew word, a line that mixes English and Hebrew, a `BwLexa` mark,
    /// and plain English, so the test runs identically on any machine.
    ///
    /// PDFKit only extracts a font's text into `attributedString` when the
    /// font has *some* embedded program (a `FontDescriptor` with a
    /// `FontFile`); it does not check that the program is valid. So `F1` and
    /// `F2` get a `FontDescriptor` pointing at a `FontFile3` stream full of
    /// zeros — enough to make PDFKit trust the `Encoding`-derived text,
    /// without needing a real font file from disk.
    private func writeLegacyFontFixture() throws -> PDFPage {
        let content = """
        BT /F1 18 Tf 36 190 Td (!y[) Tj ET
        BT /F3 12 Tf 36 160 Td (The word ) Tj ET
        BT /F1 12 Tf 108 160 Td (tyrb[b) Tj ET
        BT /F3 12 Tf 160 160 Td ( appears here.) Tj ET
        BT /F2 10 Tf 36 130 Td (-) Tj ET
        BT /F3 12 Tf 36 100 Td (A reference to Ugarit follows.) Tj ET
        """
        let contentData = Array(content.utf8)
        let widths = (32...126).map { _ in "556" }.joined(separator: " ")

        func fontObject(name: String, descriptor: Int?) -> String {
            var body = "<< /Type /Font /Subtype /Type1 /BaseFont /\(name) /Encoding /WinAnsiEncoding " +
                "/FirstChar 32 /LastChar 126 /Widths [\(widths)]"
            if let descriptor { body += " /FontDescriptor \(descriptor) 0 R" }
            return body + " >>"
        }
        func descriptorObject(name: String, fontFile: Int) -> String {
            """
            << /Type /FontDescriptor /FontName /\(name) /Flags 4 /FontBBox [0 0 1000 1000] \
            /ItalicAngle 0 /Ascent 750 /Descent -250 /CapHeight 700 /StemV 80 /MissingWidth 556 \
            /FontFile3 \(fontFile) 0 R >>
            """
        }

        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = [0]   // object 0 is the free-list head

        func addObject(_ number: Int, _ body: String) {
            offsets.append(pdf.count)
            pdf.append(Data("\(number) 0 obj\n\(body)\nendobj\n".utf8))
        }

        addObject(1, "<< /Type /Catalog /Pages 2 0 R >>")
        addObject(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
        addObject(3, """
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 400 220] \
        /Resources << /Font << /F1 5 0 R /F2 6 0 R /F3 7 0 R >> >> /Contents 4 0 R >>
        """)
        offsets.append(pdf.count)
        pdf.append(Data("4 0 obj\n<< /Length \(contentData.count) >>\nstream\n".utf8))
        pdf.append(Data(contentData))
        pdf.append(Data("\nendstream\nendobj\n".utf8))
        // F1: Hebrew we decode. F2: BwLexa, which we do not decode (kept as
        // a warning). F3: an ordinary standard font, which needs no
        // descriptor, for the surrounding English.
        addObject(5, fontObject(name: "Bwhebb", descriptor: 8))
        addObject(6, fontObject(name: "YURGAP+BwLexa", descriptor: 9))
        addObject(7, fontObject(name: "Helvetica", descriptor: nil))
        addObject(8, descriptorObject(name: "Bwhebb", fontFile: 10))
        addObject(9, descriptorObject(name: "BwLexa", fontFile: 10))
        let placeholderFont = Data(repeating: 0, count: 32)
        offsets.append(pdf.count)
        pdf.append(Data("10 0 obj\n<< /Length \(placeholderFont.count) /Subtype /Type1C >>\nstream\n".utf8))
        pdf.append(placeholderFont)
        pdf.append(Data("\nendstream\nendobj\n".utf8))

        let xrefOffset = pdf.count
        var xref = "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() {
            xref += String(format: "%010d 00000 n \n", offset)
        }
        pdf.append(Data(xref.utf8))
        pdf.append(Data("trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF".utf8))

        let url = root.appendingPathComponent("legacy.pdf")
        try pdf.write(to: url)
        guard let page = PDFDocument(url: url)?.page(at: 0) else {
            throw XCTSkip("PDFKit could not open the hand-built fixture")
        }
        return page
    }

    func testSyntheticPageDecodesLegacyHebrew() throws {
        let page = try writeLegacyFontFixture()
        let runs = PDFPageExtractor.textLayerRuns(for: page) ?? []
        let text = runs.map(\.text).joined(separator: "\n")
        // The standalone word and the one inside a mixed English/Hebrew line
        // both decode to real Hebrew.
        XCTAssertTrue(text.contains("עין"), text)
        XCTAssertTrue(text.contains("בעברית"), text)
        // Nothing of the source codes should survive.
        XCTAssertFalse(text.contains("tyrb[b"), text)
        XCTAssertFalse(text.contains("!y["), text)
        // The page's own English is untouched.
        XCTAssertTrue(text.contains("Ugarit"), text)
    }

    func testSyntheticPageReportsUndecodedLegacyFont() throws {
        let page = try writeLegacyFontFixture()
        // The page uses BwLexa, which is a font we do not decode, so the
        // import must say so rather than pass its codes as text.
        let undecoded = PDFPageExtractor.undecodedLegacyFonts(of: page)
        XCTAssertTrue(undecoded.contains { PDFLegacyFonts.baseName($0) == "bwlexa" }, "\(undecoded)")
    }
}
