import XCTest
@testable import TypstEdit

final class EquationDetectorTests: XCTestCase {

    private func range(_ text: String, at index: Int) -> String? {
        guard let range = EquationDetector.findEquationRange(in: text, at: index) else { return nil }
        return (text as NSString).substring(with: range)
    }

    func testSimpleInlineEquation() {
        let text = "Text $x^2$ more text"
        // `$` at 5, closing `$` at 9 — the range includes both.
        XCTAssertEqual(range(text, at: 6), "$x^2$")
    }

    func testBlockEquation() {
        let text = "Prev\n$ x + y $\nNext"
        XCTAssertEqual(range(text, at: 8), "$ x + y $")
    }

    /// Display equations use `$$`, which one `$`-to-`$` regex read as an
    /// empty inline pair — so a click inside `$$ … $$` found nothing.
    func testDisplayEquation() {
        let text = "$$ x + y $$"
        XCTAssertEqual(range(text, at: 4), "$$ x + y $$")
        XCTAssertEqual(range(text, at: 0), "$$ x + y $$")
        // The closing delimiter counts as inside, like the opening one.
        XCTAssertEqual(range(text, at: 12), "$$ x + y $$")
        XCTAssertEqual(range("$$x$$", at: 1), "$$x$$")
    }

    func testEscapedDollar() {
        // Swift literal "Cost is \\$5.00 but $x=5$" decodes to the 24-char string:
        //   C(0) o(1) s(2) t(3) ' '(4) i(5) s(6) ' '(7) \(8) $(9) 5(10) .(11) 0(12) 0(13)
        //   ' '(14) b(15) u(16) t(17) ' '(18) $(19) x(20) =(21) 5(22) $(23)
        // The escaped pair \$ occupies indices 8–9; the real opening $ is at 19.
        let text = "Cost is \\$5.00 but $x=5$"
        XCTAssertEqual(range(text, at: 20), "$x=5$")
    }

    func testNoEquation() {
        XCTAssertNil(range("Just plain text", at: 5))
    }

    func testUnbalanced() {
        XCTAssertNil(range("Start $ broken", at: 8))
        XCTAssertNil(range("Start $$ broken", at: 9))
    }

    /// Adjacent equations must not be merged into one range.
    func testAdjacentEquationsStaySeparate() {
        let text = "a $x$ b $y$ c"
        XCTAssertEqual(range(text, at: 4), "$x$")
        XCTAssertEqual(range(text, at: 10), "$y$")
    }

    func testCaretOutsideBothEdgesFindsNothing() {
        let text = "text $x$ more"
        XCTAssertNil(range(text, at: 15))
    }
}
