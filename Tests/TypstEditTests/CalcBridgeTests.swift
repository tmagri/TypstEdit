import XCTest
@testable import TypstEdit

/// The calculator bridge module (`Sources/Resources/Calc/bridge.typ`) and its
/// WebAssembly numeric core. Structure checks run anywhere; compile/value
/// checks need the bundled `typst` binary plus a built plugin
/// (`Tools/calc-plugin/build_calc_plugin.sh`) and skip when either is missing.
final class CalcBridgeTests: XCTestCase {

    // MARK: - Resource discovery

    func testBridgeResourceIsFound() throws {
        guard CalcPlugin.locateBridge() != nil else {
            XCTFail("bridge.typ not found. Search paths:\n" + CalcPlugin.debugSearchPaths())
            return
        }
    }

    func testDefinedNamesComeFromTheBridgeFile() throws {
        guard let path = CalcPlugin.locateBridge(),
              let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("bridge.typ not found")
        }
        let names = CalcPlugin.parseDefinedNames(source)
        // The generic entry points and the friendly wrappers must all be found.
        for expected in ["calc-call", "calc-fn", "calc-param", "plot", "BesselJ", "calc-gamma"] {
            XCTAssertTrue(names.contains(expected), "bridge should define \(expected)")
        }
        // Private helpers must not be reported as features.
        XCTAssertFalse(names.contains("_calc-in"))
        XCTAssertFalse(names.contains("_plot-finite"))
    }

    func testBridgeHasNoNumericImplementations() throws {
        guard let path = CalcPlugin.locateBridge(),
              let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw XCTSkip("bridge.typ not found")
        }
        // The numeric core lives in wasm. A hit here means math crept back into
        // Typst source.
        for forbidden in ["Lanczos", "_lanczos", "asymptotic", "calc.fact", "calc.gamma("] {
            XCTAssertFalse(source.contains(forbidden), "bridge should not implement \(forbidden)")
        }
        XCTAssertTrue(source.contains("plugin(\"TypstEditCalc.wasm\")"))
    }

    func testImportStatementListsOnlyPublicNames() throws {
        guard CalcPlugin.locateBridge() != nil else { throw XCTSkip("bridge.typ not found") }
        let line = CalcPlugin.importStatement
        XCTAssertTrue(line.hasPrefix("#import \"TypstEditCalcBridge.typ\": "), line)
        XCTAssertTrue(line.contains("calc-call") && line.contains("plot") && line.contains("BesselJ"), line)
        XCTAssertFalse(line.contains("_calc"), "private helpers must not be imported: \(line)")
        XCTAssertFalse(line.contains(": *"), line)
        XCTAssertTrue(line.hasSuffix("\n"))
    }

    // MARK: - Compile harness

    private static func locateTypst() -> String? {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-aarch64-apple-darwin/typst").path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-x86_64-apple-darwin/typst").path,
            NSString(string: "~/Desktop/TypstEdit/typst-aarch64-apple-darwin/typst").expandingTildeInPath,
            "/opt/homebrew/bin/typst",
            "/usr/local/bin/typst",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Installs the bridge + plugin in a scratch directory and compiles
    /// `import CalcPlugin.importStatement + body`.
    @discardableResult
    private func compileWithBridge(_ body: String, expectingSuccess: Bool = true) throws -> String {
        guard let typst = Self.locateTypst() else {
            throw XCTSkip("typst binary not found — skipping compile test")
        }
        guard CalcPlugin.isAvailable else {
            throw XCTSkip("TypstEditCalc.wasm not built — run Tools/calc-plugin/build_calc_plugin.sh")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalcBridgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(CalcPlugin.install(into: directory))

        let sourceURL = directory.appendingPathComponent("test.typ")
        let pdfURL = directory.appendingPathComponent("test.pdf")
        try (CalcPlugin.importStatement + body).write(to: sourceURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typst)
        process.arguments = ["compile", sourceURL.path, pdfURL.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if expectingSuccess {
            XCTAssertEqual(process.terminationStatus, 0, "typst failed:\n\(output)")
        } else {
            XCTAssertNotEqual(process.terminationStatus, 0, "compilation should have failed")
        }
        return output
    }

    // MARK: - Values through the bridge

    func testNamedWrappersMatchReference() throws {
        try compileWithBridge("""
        #let near(a, want, tol: 1e-6) = assert(calc.abs(a - want) <= calc.abs(want) * tol, message: str(a) + " != " + str(want))
        #near(calc-gamma(5), 24.0, tol: 1e-12)
        #near(calc-gamma(0.5), 1.7724538509055159, tol: 1e-12)
        #near(calc-lgamma(5), 3.1780538303479458, tol: 1e-12)
        #near(BesselJ(0, 1), 0.7651976865579666, tol: 1e-9)
        #near(BesselJ(2.5, 5), 0.24037720111131827, tol: 1e-9)
        #near(BesselY(0, 1), 0.08825696421567697, tol: 1e-5)
        #near(BesselI(0, 5), 27.239871823604453, tol: 1e-9)
        #near(BesselK(0, 1), 0.42102443824070834, tol: 1e-5)
        """)
    }

    func testGenericCallReachesManyFunctions() throws {
        // The point of the dispatcher: these need no wrapper in bridge.typ.
        try compileWithBridge("""
        #let near(a, want, tol: 1e-6) = assert(calc.abs(a - want) <= calc.abs(want) * tol, message: str(a) + " != " + str(want))
        #near(calc-call("erf", 0.5), 0.5204998778130465, tol: 1e-12)
        #near(calc-call("digamma", 3.0), 0.9227843350984671, tol: 1e-11)
        #near(calc-call("zeta", 2.0), 1.6449340668482264, tol: 1e-11)
        #near(calc-call("lambertw", 1.0), 0.5671432904097838, tol: 1e-11)
        #near(calc-call("airyai", 1.0), 0.13529241631288147, tol: 1e-5)
        #near(calc-call("ei", 1.0), 1.8951178163559368, tol: 1e-11)
        #near(calc-call("si", 1.0), 0.9460830703671831, tol: 1e-11)
        #near(calc-call("ellipk", 0.5), 1.8540746773013719, tol: 1e-11)
        #near(calc-call("jacobisn", 1.0, 0.5), 0.8030018248956439, tol: 1e-9)
        #near(calc-call("legendre", 4.0, 0.3), 0.0729375, tol: 1e-12)
        #near(calc-call("gammainc", 2.0, 3.0), 0.8008517265285442, tol: 1e-11)
        #near(calc-call("betainc", 2.0, 3.0, 0.5), 0.6875, tol: 1e-11)
        """)
    }

    func testFunctionListIsAvailable() throws {
        try compileWithBridge("""
        #let names = calc-functions()
        #assert(names.contains("besselj"))
        #assert(names.contains("zeta"))
        #assert(names.contains("ellipk"))
        """)
    }

    func testUnknownFunctionFailsLoudly() throws {
        // An unknown name must be an error, not a silent NaN.
        let output = try compileWithBridge(
            "#calc-call(\"definitely-not-a-function\", 1.0)",
            expectingSuccess: false)
        XCTAssertTrue(output.contains("unknown function"), output)
    }

    func testWrongArityFailsLoudly() throws {
        let output = try compileWithBridge(
            "#calc-call(\"erf\", 1.0, 2.0)",
            expectingSuccess: false)
        XCTAssertTrue(output.contains("wrong number of arguments"), output)
    }

    func testIntegerArgumentsAreCoerced() throws {
        try compileWithBridge("""
        #assert(calc.abs(BesselJ(0, 1) - 0.7651976865579666) < 1e-9)
        #assert(calc.abs(calc-gamma(5) - 24.0) < 1e-9)
        #assert(calc.abs(calc-call("zeta", 2) - 1.6449340668482264) < 1e-11)
        """)
    }

    func testCalcFnCurriesForPlotAndLoops() throws {
        try compileWithBridge("""
        #plot(calc-fn("besselj", 0), 0, 20)
        #plot(calc-fn("erf"), -2, 2)
        #for m in (0.1, 0.5, 0.9) [
          k(#m) = #calc-call("ellipk", m)
        ]
        """)
    }

    func testPlotCallStyles() throws {
        try compileWithBridge("""
        #plot(x => BesselJ(0, x), 0, 20)
        #plot(x => BesselJ(0, x), x-min: 0, x-max: 10, grid: false, border: false)
        #plot(points: ((0, 1), (1, 1.5), (2, 0.7)), x-min: 0, x-max: 2)
        #plot(curves: ((fn: x => BesselJ(0, x), label: [J0]), (fn: calc-fn("besselj", 1), label: [J1])), 0, 20, title: [Bessel])
        """)
    }

    func testCalcParamIsIdentity() throws {
        try compileWithBridge("""
        #let a = calc-param(2.5)
        a = #a
        """)
    }

    // MARK: - Soundness of every registry function inside real Typst

    /// Every registry function (enumerated from the plugin itself), called with
    /// edge values through the real wasm runtime: each call must return a
    /// float. A trap, plugin error or non-float would fail the compile.
    func testEveryRegistryFunctionWithEdgeInputsInTypst() throws {
        try compileWithBridge(#"""
        #let edges = (0.0, -0.0, 1.0, -1.0, 0.5, 2.5, -2.5, 100.0, 1e-300, -1e-300, 1e300, -1e300,
                      float.inf, -float.inf, float.nan, 1, -7)
        #let few = (0.0, 1.0, -1.0, 0.5, 1e300, -1e300, float.inf, float.nan, 3)
        #let calls = 0
        #for line in calc-functions().split("\n") {
          if line == "" { continue }
          let parts = line.split("/")
          let name = parts.at(0)
          let arity = int(parts.at(1))
          if arity == 1 {
            for a in edges {
              let v = calc-call(name, a)
              assert(type(v) == float, message: name + " returned " + str(type(v)))
            }
          } else if arity == 2 {
            for a in few { for b in edges {
              let v = calc-call(name, a, b)
              assert(type(v) == float, message: name + " returned " + str(type(v)))
            } }
          } else {
            for a in few { for b in few { for c in few {
              let v = calc-call(name, a, b, c)
              assert(type(v) == float, message: name + " returned " + str(type(v)))
            } } }
          }
        }
        #assert(calc-functions().split("\n").filter(l => l != "").len() >= 80)
        """#)
    }

    func testFunctionListCarriesArity() throws {
        try compileWithBridge("""
        #let names = calc-functions()
        #assert(names.contains("besselj/2"))
        #assert(names.contains("erf/1"))
        #assert(names.contains("betainc/3"))
        """)
    }

    func testPreviouslyWrongValuesAreNowCorrect() throws {
        // Each of these returned a silently wrong value before the soundness pass.
        try compileWithBridge("""
        #assert(calc-call("floor", 1e300) == 1e300)
        #assert(calc-call("trunc", -2.5) == -2.0)
        #assert(calc-call("round", float.inf) == float.inf)
        #let s = calc-call("sin", 1e300)
        #assert(s != s, message: "sin beyond the reduction limit must decline (NaN)")
        #assert(calc-call("binom", 1e9, 5e8) == float.inf or calc-call("binom", 1e9, 5e8) != calc-call("binom", 1e9, 5e8))
        #assert(calc.abs(calc-call("binom", 0.5, 2) + 0.125) < 1e-15)
        #assert(calc.abs(calc-call("besseli", 1, -1) + 0.5651591039924851) < 1e-12)
        #assert(calc-call("li", 1) == -float.inf)
        #assert(calc.abs(calc-call("zeta", 0) + 0.5) < 1e-15)
        #assert(calc.abs(calc-call("lambertwm1", -1e-300) + 697.3227762954601) < 1e-9)
        #assert(calc.abs(calc-call("sinh", 1e-10) - 1e-10) < 1e-25)
        #assert(calc.abs(calc-call("asinh", -1e10) + 23.7189981105004) < 1e-13)
        #assert(calc.abs(calc-call("jacobisn", 2, 1) - 0.9640275800758169) < 1e-14)
        #assert(calc-call("mod", 1e300, 3) == 0.0) // fmod is exact (1e300 as a double is divisible by 3)
        """)
    }

    // MARK: - Misuse fails loudly, never silently

    private func assertFails(_ body: String, with message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let output = try compileWithBridge(body, expectingSuccess: false)
        XCTAssertTrue(output.contains(message), "expected “\(message)” in:\n\(output)", file: file, line: line)
    }

    func testMisuseIsReportedClearly() throws {
        try assertFails("#calc-call(\"erf\", x: 1)", with: "named arguments are not supported")
        try assertFails("#calc-call(\"erf\", \"1.5\")", with: "take numbers")
        try assertFails("#calc-call(\"erf\", 50%)", with: "take numbers")
        try assertFails("#calc-call(\"erf\", 1pt)", with: "take numbers")
        try assertFails("#calc-call(\"erf\", none)", with: "take numbers")
        try assertFails("#calc-call(\"erf\", true)", with: "take numbers")
        try assertFails("#calc-call(5, 1.0)", with: "must be a string")
        try assertFails("#calc-call(\"erf\")", with: "1 to 3 arguments")
        try assertFails("#calc-call(\"erf\", 1, 2, 3, 4)", with: "1 to 3 arguments")
        try assertFails("#calc-call(\"no-such-fn\", 1.0)", with: "unknown function")
        try assertFails("#calc-call(\"" + String(repeating: "x", count: 5000) + "\", 1.0)", with: "unknown function")
        try assertFails("#calc-call(\"erf\", 1.0, 2.0)", with: "wrong number of arguments")
        try assertFails("#calc-fn(\"erf\", y: 2)", with: "named arguments are not supported")
        try assertFails("#plot(calc-fn(\"erf\"), 1, 1)", with: "must be less than x-max")
        try assertFails("#plot(calc-fn(\"erf\"), 0, 1, samples: 0)", with: "samples must be")
        try assertFails("#plot(5, 0, 1)", with: "must be a function")
        try assertFails("#plot(calc-fn(\"erf\"), 0, 1, colour: red)", with: "unknown argument")
        try assertFails("#plot()", with: "give a function")
    }

    func testDecimalArgumentsAreAccepted() throws {
        try compileWithBridge("#assert(calc.abs(calc-call(\"erf\", decimal(\"0.5\")) - 0.5204998778130465) < 1e-15)")
    }

    func testCurvesAcceptBareFunctionsAndPointsSkipNonFinite() throws {
        try compileWithBridge("""
        #plot(curves: (calc-fn("erf"), calc-fn("besselj", 0)), 0, 3)
        #plot(points: ((0, 1), (1, float.nan), (2, float.inf), (3, 2)), x-min: 0, x-max: 3)
        """)
    }

    func testPurityRepeatedCallsAreBitIdentical() throws {
        try compileWithBridge("""
        #let a = range(200).map(i => calc-call("besselj", 2.5, i * 0.37))
        #let b = range(200).map(i => calc-call("besselj", 2.5, i * 0.37))
        #assert(a == b)
        """)
    }

    // MARK: - Native conformance suites (run when clang is available)

    /// Builds and runs the C registry-conformance harness: every registry
    /// function against mpmath references, with the decline/coverage contract.
    func testNativeRegistryConformanceSuite() throws {
        let clang = "/usr/bin/clang"
        guard FileManager.default.isExecutableFile(atPath: clang) else { throw XCTSkip("clang not available") }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tools/calc-plugin")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("tests/registry_reference.h").path) else {
            throw XCTSkip("registry_reference.h not found")
        }
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent("calc-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: binary) }
        func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }
        let build = try run(clang, ["-O2", "-std=c99", "-o", binary.path,
                                     "calc_math.c", "calc_dispatch.c", "tests/test_registry.c"])
        XCTAssertEqual(build.0, 0, build.1)
        let result = try run(binary.path, [])
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertTrue(result.1.contains(" 0 failures, 0 slow calls"), result.1)
    }
}
