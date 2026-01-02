import XCTest
@testable import TypstEdit

final class EquationDetectorTests: XCTestCase {
    
    func testSimpleInlineEquation() {
        let text = "Text $x^2$ more text"
        // Index at 'x' (offset 6)
        // $ is at 5, second $ is at 9. 
        // Range should be [5, length 5] -> "5, 6, 7, 8, 9"
        
        // Test cursor inside
        let range = EquationDetector.findEquationRange(in: text, at: 6)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.location, 5)
        XCTAssertEqual(range?.length, 5)
    }
    
    func testBlockEquation() {
        let text = "Prev\n$ x + y $\nNext"
        // $ at 5, second $ at 13.
        // Cursor at 8 (space after x)
        
        let range = EquationDetector.findEquationRange(in: text, at: 8)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.location, 5)
        XCTAssertEqual(range?.length, 9) // 13 - 5 + 1
    }
    
    func testEscapedDollar() {
        let text = "Cost is \\$5.00 but $x=5$"
        // Cursor at 19 (x)
        // First $ is escaped at 8. Real start $ is at 18.
        
        let range = EquationDetector.findEquationRange(in: text, at: 19)
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.location, 18)
    }
    
    func testNoEquation() {
        let text = "Just plain text"
        let range = EquationDetector.findEquationRange(in: text, at: 5)
        XCTAssertNil(range)
    }
    
    func testUnbalanced() {
        let text = "Start $ broken"
        let range = EquationDetector.findEquationRange(in: text, at: 8)
        XCTAssertNil(range)
    }
}
