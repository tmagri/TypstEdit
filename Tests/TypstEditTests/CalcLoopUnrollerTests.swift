import XCTest
@testable import TypstEdit

/// Static specialisation of `#calc` calls inside statically bounded loops.
final class CalcLoopUnrollerTests: XCTestCase {

    // MARK: - Substitution

    func testSubstitutesInsideCalculatorCallsOnly() {
        let body = "[Order #n : #calc(\"BesselJ(n, 6)\") and #n]"
        XCTAssertEqual(
            CalcLoopUnroller.specialise(body, variable: "n", value: "3"),
            "[Order #n : #calc(\"BesselJ(3, 6)\") and #n]")
    }

    func testSubstitutionIsWordBounded() {
        XCTAssertEqual(
            CalcLoopUnroller.specialise("#calc(\"nn + n + x_n + n2 + a.n\")", variable: "n", value: "7"),
            "#calc(\"nn + 7 + x_n + n2 + a.n\")")
    }

    func testNegativeValuesAreParenthesised() {
        XCTAssertEqual(
            CalcLoopUnroller.specialise("#calc(\"n^2\")", variable: "n", value: "-1"),
            "#calc(\"(-1)^2\")")
    }

    func testSubstitutesTableBounds() {
        XCTAssertEqual(
            CalcLoopUnroller.specialise("#calc-table(\"n*x\", x, 0, n, 4)", variable: "n", value: "2"),
            "#calc-table(\"2*x\", x, 0, 2, 4)")
    }

    func testSubstitutesNestedRangeHeads() {
        XCTAssertEqual(
            CalcLoopUnroller.specialise("[#for j in range(i) [#calc(\"j\")]]", variable: "i", value: "2"),
            "[#for j in range(2) [#calc(\"j\")]]")
    }

    // MARK: - Iterables

    func testIterationValues() {
        XCTAssertEqual(CalcLoopUnroller.iterationValues("range(3)"), ["0", "1", "2"])
        XCTAssertEqual(CalcLoopUnroller.iterationValues("range(2, 5)"), ["2", "3", "4"])
        XCTAssertEqual(CalcLoopUnroller.iterationValues("range(6, 0, -3)"), ["6", "3"])
        XCTAssertEqual(CalcLoopUnroller.iterationValues("(0.1, -2, 3)"), ["0.1", "-2", "3"])
        XCTAssertNil(CalcLoopUnroller.iterationValues("range(count)"))
        XCTAssertNil(CalcLoopUnroller.iterationValues("range(1, 2, 0)"))
        XCTAssertNil(CalcLoopUnroller.iterationValues("(a, b)"))
        XCTAssertNil(CalcLoopUnroller.iterationValues("values"))
    }

    // MARK: - unroll

    func testUnrollRebindsTheLoopVariable() {
        let result = CalcLoopUnroller.unroll("#for n in range(2) [Order #n: #calc(\"n^2\")]")
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(
            result.output,
            "#{ let n = 0; [Order #n: #calc(\"0^2\")] }#{ let n = 1; [Order #n: #calc(\"1^2\")] }")
    }

    func testUnrollCodeBody() {
        let result = CalcLoopUnroller.unroll("#for k in (1, 2) { [#calc(\"k\")] }")
        XCTAssertEqual(
            result.output,
            "#{ let k = 1;  [#calc(\"1\")]  }#{ let k = 2;  [#calc(\"2\")]  }")
    }

    func testUnrollNestedLoopsIncludingDependentBounds() {
        let result = CalcLoopUnroller.unroll("#for i in range(1, 3) [#for j in range(i) [#calc(\"i*j\")]]")
        XCTAssertTrue(result.warnings.isEmpty, "a bound that depends on the outer variable is resolvable")
        XCTAssertFalse(result.output.contains("#for"))
        // i = 1: j ∈ {0}; i = 2: j ∈ {0, 1}
        XCTAssertTrue(result.output.contains("#calc(\"1*0\")"))
        XCTAssertTrue(result.output.contains("#calc(\"2*0\")"))
        XCTAssertTrue(result.output.contains("#calc(\"2*1\")"))
        XCTAssertFalse(result.output.contains("#calc(\"1*1\")"))
    }

    func testPreservesSurroundingText() {
        let source = "Before\n#for n in range(1) [#calc(\"n\")]\nAfter"
        XCTAssertEqual(CalcLoopUnroller.unroll(source).output,
                       "Before\n#{ let n = 0; [#calc(\"0\")] }\nAfter")
    }

    func testLeavesNonCalculatorLoopsAlone() {
        let source = "#for n in range(3) [item #n]"
        XCTAssertEqual(CalcLoopUnroller.unroll(source).output, source)
    }

    func testLeavesNonLiteralBoundsAloneAndWarns() {
        let source = "line one\n#for n in range(count) [#calc(\"n\")]"
        let result = CalcLoopUnroller.unroll(source)
        XCTAssertEqual(result.output, source)
        XCTAssertEqual(result.warnings.map(\.line), [2])
    }

    func testRefusesHugeLoops() {
        let source = "#for n in range(1000) [#calc(\"n\")]"
        let result = CalcLoopUnroller.unroll(source, maxIterations: 100)
        XCTAssertEqual(result.output, source)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testIgnoresMalformedAndDestructuringLoops() {
        for source in [
            "#for n in range(3 [#calc(\"n\")]",
            "#for (k, v) in pairs [#calc(\"k\")]",
            "#for n in range(3)\n[#calc(\"n\")]",
        ] {
            XCTAssertEqual(CalcLoopUnroller.unroll(source).output, source, source)
        }
    }

    // MARK: - Semantics: the unrolled text must be valid, equivalent Typst

    /// Runs `typst query <selector> --field <field>` on `source`.
    private func query(_ source: String, selector: String, field: String) throws -> String {
        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("typst-aarch64-apple-darwin/typst").path,
            "/opt/homebrew/bin/typst", "/usr/local/bin/typst",
        ]
        guard let typst = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("typst binary not found")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unroll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.typ")
        try source.write(to: file, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: typst)
        process.arguments = ["query", file.path, selector, "--field", field]
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors // deprecation notices go here, not into the result
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0,
                       "typst query failed:\n\(source)\n\(String(data: errorData, encoding: .utf8) ?? "")")
        return output.filter { !$0.isWhitespace }
    }

    /// The unrolled form must evaluate exactly like the loop: same per-
    /// iteration values (the loop variable is still bound) and no literal
    /// `[`/`]` leaking into the text. The `#calc` call only triggers the
    /// rewrite; it is stripped before compiling, since this test checks the
    /// Typst side alone.
    func testUnrolledFormIsEquivalentTypst() throws {
        let loop = "#for n in range(3) [n#n #metadata(n * 2) <probe> #calc(\"n\")]"
        let unrolled = CalcLoopUnroller.unroll(loop).output
        XCTAssertNotEqual(unrolled, loop)
        let strip = { (text: String) in
            text.replacingOccurrences(of: #"#calc\("[^"]*"\)"#, with: "", options: .regularExpression)
        }

        let original = try query(strip(loop), selector: "<probe>", field: "value")
        let specialised = try query(strip(unrolled), selector: "<probe>", field: "value")
        XCTAssertEqual(original, "[0,2,4]")
        XCTAssertEqual(specialised, original)

        // The content tree of a labelled block holding the loop must contain
        // the same text and no literal bracket text nodes.
        let wrap = { (text: String) in "#block[\(strip(text))] <body>" }
        let specialisedTree = try query(wrap(unrolled), selector: "<body>", field: "body")
        let originalTree = try query(wrap(loop), selector: "<body>", field: "body")
        for expected in ["\"text\":\"n\"", "\"text\":\"0\"", "\"text\":\"2\""] {
            XCTAssertTrue(originalTree.contains(expected), originalTree)
            XCTAssertTrue(specialisedTree.contains(expected), specialisedTree)
        }
        XCTAssertFalse(specialisedTree.contains("\"text\":\"[\""), "literal brackets leaked: \(specialisedTree)")
        XCTAssertFalse(specialisedTree.contains("\"text\":\"]\""), "literal brackets leaked: \(specialisedTree)")
    }

    // MARK: - Through the resolution pass (live CAS)

    func testResolveSpecialisesLoopCalls() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let settings = CalcResolutionSettings(angle: .radians, exactMode: .auto, digits: 12, timeout: 30)
        let result = await CalcResolutionPass.resolve(
            "#for n in (-1, 2, 3) [#calc(\"n^2\") ]\n",
            fileExtension: "typ", settings: settings, cache: [:], storedParameters: [])
        let output = result.outcome.output
        XCTAssertTrue(result.outcome.diagnostics.isEmpty, "\(result.outcome.diagnostics)")
        XCTAssertFalse(output.contains("#calc("), output)
        XCTAssertEqual(
            output,
            "#{ let n = -1; [1 ] }#{ let n = 2; [4 ] }#{ let n = 3; [9 ] }\n")
    }

    func testResolveKeepsUnsupportedLoopAndWarns() async throws {
        let settings = CalcResolutionSettings(angle: .radians, exactMode: .auto, digits: 12, timeout: 30)
        let source = "#for n in range(count) [#calc(\"n\")]\n"
        let result = await CalcResolutionPass.resolve(
            source, fileExtension: "typ", settings: settings, cache: [:], storedParameters: [])
        XCTAssertTrue(result.outcome.output.hasPrefix("#for n in range(count)"))
        XCTAssertTrue(result.outcome.diagnostics.contains { $0.message.contains("cannot be specialised") })
    }

    // MARK: - Code-mode loops and hash-less calls

    func testUnrollsCodeModeLoopsAsJoiningBlock() {
        let result = CalcLoopUnroller.unroll(#"#table(..for n in (1, 2) { ([#calc("n^2")],) })"#)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(
            result.output,
            #"#table(..{ { let n = 1;  ([#calc("1^2")],)  }; { let n = 2;  ([#calc("2^2")],)  }; })"#)
    }

    func testCodeModeUnrollIsEquivalentTypst() throws {
        // A code block joins its values like `for` does: same array, same order.
        let loop = #"#metadata(for n in (1, 2, 3) { (n * 10, calc("n")) }) <probe>"#
        let unrolled = CalcLoopUnroller.unroll(loop).output
        XCTAssertNotEqual(unrolled, loop)
        let strip = { (text: String) in
            text.replacingOccurrences(of: #"calc\("[^"]*"\)"#, with: "0", options: .regularExpression)
        }
        XCTAssertEqual(try query(strip(loop), selector: "<probe>", field: "value"), "[[10,0,20,0,30,0]]")
        XCTAssertEqual(try query(strip(unrolled), selector: "<probe>", field: "value"), "[[10,0,20,0,30,0]]")
    }

    func testProseContainingForIsUntouched() {
        let source = "We use this for n in (1, 2) [cases] without any calculator."
        XCTAssertEqual(CalcLoopUnroller.unroll(source).output, source)
    }

    func testResolveSpecialisesCodeModeLoopsAndHashlessCalls() async throws {
        guard CASEngine.isAvailable else { throw XCTSkip("typstedit-cas not built") }
        let settings = CalcResolutionSettings(angle: .radians, exactMode: .auto, digits: 12, timeout: 30)
        let result = await CalcResolutionPass.resolve(
            #"#table(..for n in (1, 2) { ([#calc("n^2")],) }) #grid(calc("3*4"), calc-table("x", x, 0, 1, 1))"#,
            fileExtension: "typ", settings: settings, cache: [:], storedParameters: [])
        let output = result.outcome.output
        XCTAssertTrue(result.outcome.diagnostics.isEmpty, "\(result.outcome.diagnostics.map(\.message))")
        XCTAssertFalse(output.contains("calc("), output)
        XCTAssertTrue(output.contains("[1]") && output.contains("[4]"), output)
        XCTAssertTrue(output.contains("#grid(12, ((0, 0), (1, 1)))"), output)
    }

    func testTypstCalcModuleIsNotMistakenForACall() async throws {
        let settings = CalcResolutionSettings(angle: .radians, exactMode: .auto, digits: 12, timeout: 30)
        let source = "#calc.pow(2, 3) #calc.abs(-1) #my-calc(\"x\")"
        let result = await CalcResolutionPass.resolve(
            source, fileExtension: "typ", settings: settings, cache: [:], storedParameters: [])
        XCTAssertEqual(result.outcome.output, source)
        XCTAssertFalse(CalcFeatureScanner.scan(source).usesAny)
    }
}
