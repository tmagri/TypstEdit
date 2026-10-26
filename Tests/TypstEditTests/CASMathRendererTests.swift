import XCTest
@testable import TypstEdit

final class CASMathRendererTests: XCTestCase {
    func testDarkSourceUsesTransparentPageAndWhiteText() {
        let source = CASMathRenderer.documentSource(math: "x = -2", dark: true)
        XCTAssertTrue(source.contains("fill: none"))
        XCTAssertTrue(source.contains("rgb(\"ffffff\")"))
    }

    func testLightSourceUsesTransparentPageAndBlackText() {
        let source = CASMathRenderer.documentSource(math: "x = -2", dark: false)
        XCTAssertTrue(source.contains("fill: none"))
        XCTAssertTrue(source.contains("rgb(\"000000\")"))
    }

    func testDarkSVGHasWhiteGlyphsAndNoPageBackground() throws {
        try verifySVG(dark: true, foreground: "#ffffff")
    }

    func testLightSVGHasBlackGlyphsAndNoPageBackground() throws {
        try verifySVG(dark: false, foreground: "#000000")
    }

    func testMatrixResultsCompileInBothAppearances() throws {
        let matrices: [CASExpression] = [
            .vector([.vector([.symbol("a"), .symbol("b")])]),
            .vector([.vector([.symbol("a")]), .vector([.symbol("b")])]),
            .vector([.vector([.symbol("a")])]),
            .vector([
                .vector([.number(value: "-2", approx: nil), .number(value: "1", approx: nil)]),
                .vector([.number(value: "3/2", approx: nil), .number(value: "-1/2", approx: nil)])
            ])
        ]
        for matrix in matrices {
            let math = CASTypstRenderer.typst(matrix)
            try verifySVG(dark: true, foreground: "#ffffff", math: math)
            try verifySVG(dark: false, foreground: "#000000", math: math)
        }
    }

    /// Compile the same source the history renderer uses. A white page
    /// rectangle previously covered dark-mode glyphs, making answers blank.
    private func verifySVG(dark: Bool, foreground: String, math: String = "x = -2") throws {
        guard let typstPath = CASMathRenderer.resolveTypstPath() else {
            throw XCTSkip("Typst is not installed")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CASMathRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("equation.typ")
        let output = directory.appendingPathComponent("equation.svg")
        try CASMathRenderer.documentSource(math: math, dark: dark)
            .write(to: input, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", input.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        guard process.terminationStatus == 0 else { return }

        let svg = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(svg.contains("fill=\"\(foreground)\""), "Equation glyphs must match the appearance")
        XCTAssertFalse(svg.contains("<rect"), "The equation SVG must not contain a page background")
    }
}
