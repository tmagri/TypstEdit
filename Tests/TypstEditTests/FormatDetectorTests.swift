import XCTest
@testable import TypstEdit

final class FormatDetectorTests: XCTestCase {
    
    func testTitleDetection() {
        let text = "#title[My Amazing Title]"
        // Index at 'M'
        XCTAssertTrue(FormatDetector.detectIsTitle(in: text, at: 8))
        
        let range = FormatDetector.findTitleRange(in: text, at: 8)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.location, 0)
        XCTAssertEqual(range?.length, 24)
    }
    
    func testTitleDetectionWithParams() {
        let text = "#title(author: \"Me\")[My Title]"
        XCTAssertTrue(FormatDetector.detectIsTitle(in: text, at: 22))
        
        let range = FormatDetector.findTitleRange(in: text, at: 22)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.location, 0)
    }
    
    func testNoTitle() {
        let text = "= Heading"
        XCTAssertFalse(FormatDetector.detectIsTitle(in: text, at: 2))
    }
    
    func testHeadingDetection() {
        let text = "== Heading 2"
        XCTAssertEqual(FormatDetector.detectHeadingLevel(in: text, at: 4), 2)
    }
}
