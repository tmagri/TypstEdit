import XCTest
@testable import TypstEdit

final class NoteSyntaxAutoFixTests: XCTestCase {

    func testAutoFixUnclosedMathWithTrailingCaret() {
        let input = "$B=p(1+i)^{t}+∑_{k=1}^"
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertTrue(output.hasSuffix("$"), "Should have closed the math block with $: \(output)")
        XCTAssertTrue(output.contains("^{}"), "Should complete trailing caret with ^{}: \(output)")
        XCTAssertEqual(output, "$B=p(1+i)^{t}+∑_{k=1}^{}$")
    }

    func testAutoFixTrailingSubscriptInMath() {
        let input = "Formula is $x_$"
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, "Formula is $x_{}$")
    }

    func testAutoFixTrailingBinaryOperatorInMath() {
        let input = "Calculation: $1 + 2 + $"
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, "Calculation: $1 + 2 + \"\"$")
    }

    func testAutoFixUnclosedParenthesesInsideMath() {
        let input = "$f(x) = (a + b$"
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, "$f(x) = (a + b)$")
    }

    func testAutoFixUnclosedCodeFence() {
        let input = """
        # Title
        ```typst
        #let x = 1
        """
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertTrue(output.hasSuffix("```"), "Should close unclosed code fence at EOF")
    }

    func testAutoFixDanglingCaretInContent() {
        let input = "Interest rate is high ^"
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, "Interest rate is high \\^")
    }

    func testPreservesValidNoteSyntax() {
        let input = """
        = Note Title
        This is a normal paragraph with $E = mc^2$ math.
        - Item 1
        - Item 2
        """
        let output = TypstCompiler.autoFixBrokenNoteSyntax(input)
        XCTAssertEqual(output, input)
    }

    @MainActor
    func testCompileCleanSucceedsWithBrokenNoteSyntax() async {
        let compiler = TypstCompiler()
        let brokenNote = """
        = Interest Note
        
        Variables:
        B is Balance
        p is Principle
        $B=p(1+i)^{t}+∑_{k=1}^
        
        More text here.
        """
        
        let result = await compiler.compileClean(
            content: brokenNote,
            fileExtension: "note",
            originalFileURL: nil,
            projectRoot: nil
        )
        
        XCTAssertTrue(result.success, "compileClean should succeed on broken note syntax: \(result.error ?? "")")
        XCTAssertNotNil(result.pdfURL, "compileClean should produce a PDF URL")
    }
}
