import XCTest
@testable import TypstEdit

final class ExportPathTemplateTests: XCTestCase {
    func testPNGOutputPathUsesPageTemplate() {
        let requested = URL(fileURLWithPath: "/tmp/report.png")

        let result = TypstCompiler.exportDestinationURL(for: "png", requested: requested)

        XCTAssertEqual(result.lastPathComponent, "report-{0p}.png")
    }

    func testSVGOutputPathUsesPageTemplate() {
        let requested = URL(fileURLWithPath: "/tmp/report.svg")

        let result = TypstCompiler.exportDestinationURL(for: "svg", requested: requested)

        XCTAssertEqual(result.lastPathComponent, "report-{0p}.svg")
    }

    func testPDFOutputPathStaysUnchanged() {
        let requested = URL(fileURLWithPath: "/tmp/report.pdf")

        let result = TypstCompiler.exportDestinationURL(for: "pdf", requested: requested)

        XCTAssertEqual(result.lastPathComponent, "report.pdf")
    }

    func testTemplatePathIsNotDuplicated() {
        let requested = URL(fileURLWithPath: "/tmp/report-{0p}.png")

        let result = TypstCompiler.exportDestinationURL(for: "png", requested: requested)

        XCTAssertEqual(result.lastPathComponent, "report-{0p}.png")
    }
}
