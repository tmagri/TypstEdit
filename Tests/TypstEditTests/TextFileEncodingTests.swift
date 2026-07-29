import XCTest
@testable import TypstEdit

final class TextFileEncodingTests: XCTestCase {

    func testPlainUTF8WithoutBOM() {
        let source = "= Heading\nHello wörld — typst ✓"
        let data = source.data(using: .utf8)!
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, source)
        XCTAssertEqual(decoded.encoding, .utf8)
        XCTAssertEqual(decoded.encodingName, "UTF-8")
    }

    func testUTF8WithBOMIsStripped() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append("content".data(using: .utf8)!)
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "content")
        XCTAssertEqual(decoded.encodingName, "UTF-8 (BOM)")
        XCTAssertFalse(decoded.text.hasPrefix("\u{FEFF}"))
    }

    func testUTF16LittleEndianWithBOM() {
        var data = Data([0xFF, 0xFE])
        data.append("line one\nline two".data(using: .utf16LittleEndian)!)
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "line one\nline two")
        XCTAssertEqual(decoded.encoding, .utf16LittleEndian)
        XCTAssertEqual(decoded.encodingName, "UTF-16 (LE)")
    }

    func testUTF16BigEndianWithBOM() {
        var data = Data([0xFE, 0xFF])
        data.append("big endian text".data(using: .utf16BigEndian)!)
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "big endian text")
        XCTAssertEqual(decoded.encoding, .utf16BigEndian)
        XCTAssertEqual(decoded.encodingName, "UTF-16 (BE)")
    }

    func testUTF16LittleEndianWithoutBOMUsesHeuristic() {
        // ASCII text encoded as UTF-16LE has a NUL on every odd byte and none on
        // even bytes — the classic BOM-less signature.
        let data = "A four line text\nsecond line\nthird line\nfourth line"
            .data(using: .utf16LittleEndian)!
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "A four line text\nsecond line\nthird line\nfourth line")
        XCTAssertEqual(decoded.encodingName, "UTF-16 (LE)")
    }

    func testUTF16BigEndianWithoutBOMUsesHeuristic() {
        let data = "Some reasonably long english text for detection"
            .data(using: .utf16BigEndian)!
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "Some reasonably long english text for detection")
        XCTAssertEqual(decoded.encodingName, "UTF-16 (BE)")
    }

    func testWindows1252DecodesEuroAndCurlyQuotes() {
        // 0x80 = €, 0x93/0x94 = curly quotes — invalid UTF-8, defined only in CP1252.
        let data = Data([0x50, 0x72, 0x69, 0x63, 0x65, 0x3A, 0x20, 0x80, 0x31, 0x30]) // "Price: €10"
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "Price: €10")
        XCTAssertEqual(decoded.encoding, .windowsCP1252)
    }

    func testLatin1StyleFileStillDecodes() {
        // "café" in Latin-1/CP1252 — 0xE9 is an invalid UTF-8 lead byte, no NUL
        // parity bias, so it lands in the single-byte branch.
        let data = Data([0x63, 0x61, 0x66, 0xE9])
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "café")
    }

    func testEmptyData() {
        let decoded = TextFileEncoding.decode(Data())
        XCTAssertEqual(decoded.text, "")
    }

    func testUTF32WithBOM() {
        var data = Data([0xFF, 0xFE, 0x00, 0x00])
        data.append("32 bit".data(using: .utf32LittleEndian)!)
        let decoded = TextFileEncoding.decode(data)
        XCTAssertEqual(decoded.text, "32 bit")
        XCTAssertEqual(decoded.encodingName, "UTF-32 (LE)")
    }
}
