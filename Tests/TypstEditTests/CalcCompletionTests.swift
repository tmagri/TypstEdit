import XCTest
@testable import TypstEdit

/// Offline completion for the calculator features. All names come from the
/// bridge (bridge.typ), the registry list (functions.txt, generated from
/// calc_dispatch.c) and the calculator catalogue — none are hardcoded.
@MainActor
final class CalcCompletionTests: XCTestCase {
    private let service = OfflineCompletionService.shared

    private func complete(_ text: String) -> [String] {
        service.provideCompletion(text: text, cursorIndex: text.count)
    }

    func testRegistryListMatchesTheCRegistry() throws {
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tools/calc-plugin/calc_dispatch.c")
        guard let c = try? String(contentsOf: source, encoding: .utf8) else { throw XCTSkip("calc_dispatch.c not found") }
        let regex = try NSRegularExpression(pattern: #"(?m)^\s*\{"([a-z0-9]+)", (\d)"#)
        let ns = c as NSString
        let expected = regex.matches(in: c, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)) + "/" + ns.substring(with: $0.range(at: 2))
        }
        let actual = CalcPlugin.registryFunctions.map { "\($0.name)/\($0.arity)" }
        XCTAssertEqual(actual, expected, "functions.txt is stale: run Tools/calc-plugin/build_calc_plugin.sh")
        XCTAssertGreaterThan(actual.count, 80)
    }

    func testBridgeFunctionsAfterHash() {
        XCTAssertTrue(complete("#Bes").contains("#BesselJ("))
        XCTAssertTrue(complete("#calc-c").contains("#calc-call("))
        XCTAssertTrue(complete("#calc-t").contains("#calc-table("))
        XCTAssertTrue(complete("#plo").contains("#plot("))
        XCTAssertTrue(complete("#calc-par").contains("#calc-param("))
        // Ordinary Typst completion keeps working alongside.
        XCTAssertTrue(complete("#calc").contains("#calc("))
        XCTAssertTrue(complete("#pageb").contains("#pagebreak()"))
    }

    func testRegistryNamesInsideCalcCall() {
        let suggestions = complete(#"#calc-call("bess"#)
        XCTAssertTrue(suggestions.contains(#""besselj", "#), "\(suggestions)")
        XCTAssertTrue(suggestions.contains(#""besselk", "#))
        XCTAssertTrue(suggestions.allSatisfy { $0.hasPrefix(#""bess"#) })
        XCTAssertFalse(suggestions.contains { $0.contains("erf") })
    }

    func testCalcFnClosesSingleArgumentFunctions() {
        let suggestions = complete(#"#plot(calc-fn("er"#)
        XCTAssertTrue(suggestions.contains(#""erf")"#), "\(suggestions)")
        XCTAssertTrue(suggestions.contains(#""erfinv")"#))
        XCTAssertTrue(complete(#"#plot(calc-fn("bessel"#).contains(#""besselj", "#), "two-argument functions still take a fixed argument")
    }

    func testCASNamesInsideCalcString() {
        let suggestions = complete(#"Value #calc("sol"#)
        XCTAssertTrue(suggestions.contains(#""solve("#), "\(suggestions)")
        let mid = complete(#"#calc("2*fac"#)
        XCTAssertFalse(mid.isEmpty)
        XCTAssertTrue(mid.allSatisfy { $0.hasPrefix(#""2*fac"#) && $0.hasSuffix("(") }, "\(mid)")
        XCTAssertEqual(complete(#"#calc("2+"#), [], "nothing to complete after an operator")
    }

    func testPlotParametersComeFromTheBridgeSignature() {
        let suggestions = complete("#plot(x => x, 0, 1, sam")
        XCTAssertTrue(suggestions.contains("samples: "), "\(suggestions)")
        XCTAssertTrue(complete("#plot(fn: f, x-").contains("x-min: "), "names read via args.at(…) are included")
        XCTAssertTrue(complete("#plot(f, 0, 1, leg").contains("legend: "))
    }

    func testSignatureParser() {
        let parsed = CalcPlugin.parseSignatures("""
        #let foo(a, b: 1, long-name: auto) = { args.at("hidden") }
        #let _private(x) = x
        #let bar(..args) = { let v = args.at("x-min", default: 0); v }
        """)
        XCTAssertEqual(parsed["foo"], ["b", "long-name", "hidden"], "keys read via args.at(…) count as parameters")
        XCTAssertEqual(parsed["bar"], ["x-min"])
        XCTAssertNil(parsed["_private"])
    }
}
