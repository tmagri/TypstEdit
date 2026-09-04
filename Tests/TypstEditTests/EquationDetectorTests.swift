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
        // Swift literal "Cost is \\$5.00 but $x=5$" decodes to the 24-char string:
        //   C(0) o(1) s(2) t(3) ' '(4) i(5) s(6) ' '(7) \(8) $(9) 5(10) .(11) 0(12) 0(13)
        //   ' '(14) b(15) u(16) t(17) ' '(18) $(19) x(20) =(21) 5(22) $(23)
        // The escaped pair \$ occupies indices 8–9; the real opening $ is at index 19.
        let text = "Cost is \\$5.00 but $x=5$"

        // Cursor at 20 (inside 'x'), which is inside the equation $x=5$.
        let range = EquationDetector.findEquationRange(in: text, at: 20)
        XCTAssertNotNil(range)
        // Real opening $ is at 19, closing $ at 23 → length 5.
        XCTAssertEqual(range?.location, 19)
        XCTAssertEqual(range?.length, 5)
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
