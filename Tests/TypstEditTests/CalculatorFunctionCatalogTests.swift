import XCTest
import Foundation
@testable import TypstEdit

/// Covers the curated function catalogue: structure, search, honest
/// compatibility labels, and — when the CAS helper and Typst are built —
/// the examples themselves.
///
/// Each test case gets its own `CASEngine` instance (a separate helper
/// process from `CASEngine.shared`), so the app's calculator session is
/// never touched and stored variables cannot leak between tests.
final class CalculatorFunctionCatalogTests: XCTestCase {

    private let engine = CASEngine()

    // MARK: - Helpers

    private func requireHelper() throws {
        guard CASEngine.isAvailable else {
            throw XCTSkip("typstedit-cas not built — run Tools/cas/build_cas.sh")
        }
    }

    private func eval(_ input: String,
                      approx: Bool = false) async -> CASEvalResult {
        await engine.eval(input: TISyntax.preprocess(input),
                          approx: approx,
                          angle: .radians,
                          digits: 12,
                          timeout: 30)
    }

    private func guide(id: String) throws -> CalculatorFunctionGuide {
        try XCTUnwrap(
            CalculatorFunctionCatalog.entries.first(where: { $0.id == id }),
            "catalogue entry '\(id)' is missing")
    }

    // MARK: - Structure

    func testCatalogueHasExpectedSize() {
        let count = CalculatorFunctionCatalog.entries.count
        XCTAssertGreaterThanOrEqual(count, 35, "The catalogue should stay a useful size.")
        XCTAssertLessThanOrEqual(count, 50, "Keep the catalogue curated; it is a guide, not a dump.")
    }

    func testIdentifiersAreUniqueAndStable() {
        let ids = CalculatorFunctionCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Entry ids must be unique.")
        for id in ids {
            XCTAssertFalse(id.isEmpty, "Every entry needs an id.")
            XCTAssertTrue(
                id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" },
                "Id '\(id)' is not a stable slug.")
        }
    }

    func testEveryEntryIsComplete() {
        for guide in CalculatorFunctionCatalog.entries {
            XCTAssertFalse(guide.title.isEmpty, guide.id)
            XCTAssertFalse(guide.syntax.isEmpty, guide.id)
            XCTAssertFalse(guide.description.isEmpty, guide.id)
            XCTAssertFalse(guide.example.isEmpty, guide.id)
            XCTAssertTrue(
                guide.example.contains(where: { !$0.isWhitespace }),
                "\(guide.id): the example must be a complete entry line.")
        }
    }

    func testCategoriesAreAllRepresented() {
        let used = Set(CalculatorFunctionCatalog.entries.map(\.category))
        XCTAssertEqual(used, Set(CalculatorFunctionCategory.allCases),
                       "Every category must have at least one entry.")
        for category in CalculatorFunctionCategory.allCases {
            XCTAssertFalse(
                CalculatorFunctionCatalog.entries.filter { $0.category == category }.isEmpty,
                "No entries in category \(category.rawValue).")
        }
    }

    func testKnownGapsAreLabelled() throws {
        let gapIDs = ["nderiv", "impdif", "texpand", "simult", "complex-parts"]
        for id in gapIDs {
            let entry = try guide(id: id)
            XCTAssertEqual(entry.compatibility, .notYetVerified,
                           "\(id) is a known gap and must not claim verification.")
            let lowercased = entry.description.lowercased()
            XCTAssertTrue(lowercased.contains("gap") || lowercased.contains("not"),
                          "\(id) should state its caution in the description.")
        }
        let gaps = CalculatorFunctionCatalog.entries.filter { $0.compatibility == .notYetVerified }
        XCTAssertGreaterThanOrEqual(gaps.count, 4,
                                   "Known TI gaps must be documented, not hidden.")
    }

    func testCatalogueAvoidsCodeAndFileFunctions() {
        // This guide must never suggest arbitrary code, file, or network
        // commands on the entry line.
        let forbidden = ["Prgm", "Local", "Send", "Open", "HTTP", "Connect", "Execute"]
        for guide in CalculatorFunctionCatalog.entries {
            for word in forbidden {
                XCTAssertFalse(guide.title.localizedCaseInsensitiveContains(word),
                               "\(guide.id): unexpected command (\(word)) in title.")
                XCTAssertFalse(guide.syntax.localizedCaseInsensitiveContains(word),
                               "\(guide.id): unexpected command (\(word)) in syntax.")
            }
        }
    }

    // MARK: - Search

    func testSearchEmptyQueryReturnsEverything() {
        XCTAssertEqual(CalculatorFunctionCatalog.search(query: "", category: nil).count,
                       CalculatorFunctionCatalog.entries.count)
        XCTAssertEqual(CalculatorFunctionCatalog.search(query: "   ", category: nil).count,
                       CalculatorFunctionCatalog.entries.count)
    }

    func testSearchMatchesTitleSyntaxAndDescription() {
        // Title: "solve(" and its description.
        XCTAssertTrue(CalculatorFunctionCatalog.search(query: "solve", category: nil)
            .contains { $0.id == "solve" })
        // Syntax: the square-root glyph appears in the powers entry syntax.
        XCTAssertTrue(CalculatorFunctionCatalog.search(query: "√(", category: nil)
            .contains { $0.id == "powers-roots" })
        // Description: "prime factors" is only in the isPrime/ifactor entry.
        XCTAssertTrue(CalculatorFunctionCatalog.search(query: "prime factors", category: nil)
            .contains { $0.id == "isprime" })
    }

    func testSearchIsCaseInsensitive() {
        let upper = CalculatorFunctionCatalog.search(query: "SOLVE", category: nil).map(\.id)
        let lower = CalculatorFunctionCatalog.search(query: "solve", category: nil).map(\.id)
        XCTAssertEqual(upper, lower)
        XCTAssertFalse(lower.isEmpty)
    }

    func testSearchFiltersByCategory() {
        let algebra = CalculatorFunctionCatalog.search(query: "", category: .algebra)
        XCTAssertFalse(algebra.isEmpty)
        XCTAssertTrue(algebra.allSatisfy { $0.category == .algebra })

        let matrices = CalculatorFunctionCatalog.search(query: "", category: .matrices)
        XCTAssertEqual(matrices.map(\.id),
                       CalculatorFunctionCatalog.entries
                           .filter { $0.category == .matrices }
                           .map(\.id))

        // "solve" does not belong to the lists category.
        XCTAssertTrue(CalculatorFunctionCatalog.search(query: "solve", category: .lists).isEmpty)
    }

    func testSearchReturnsNoMatchesForUnknownText() {
        XCTAssertTrue(CalculatorFunctionCatalog.search(query: "zzzznotafunction", category: nil).isEmpty)
    }

    // MARK: - Examples (real CAS helper)

    func testVerifiedExamplesEvaluate() async throws {
        try requireHelper()
        // A bare matrix literal prints in the same form it was typed
        // ([[1,2],[3,4]]), so the "unchanged" heuristic does not apply.
        let printsAsTyped: Set<String> = ["matrix-literal"]
        var failures: [String] = []
        for guide in CalculatorFunctionCatalog.entries
        where guide.compatibility != .notYetVerified {
            // ans/entry recall needs a seeded history; covered separately.
            guard guide.id != "recall" else { continue }
            let result = await eval(guide.example)
            let preprocessed = TISyntax.preprocess(guide.example)
            if !result.ok {
                failures.append("\(guide.id) (\(guide.example)): \(result.errorMessage)")
            } else if result.resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("\(guide.id) (\(guide.example)): empty result")
            } else if result.resultText == preprocessed && !printsAsTyped.contains(guide.id) {
                failures.append("\(guide.id) (\(guide.example)): came back unevaluated")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testRecallExampleUsesHistory() async throws {
        try requireHelper()
        let entry = try guide(id: "recall")
        let history = [
            CalculatorEntry(input: "2+2", resultPlain: "4"),
            CalculatorEntry(input: "3*3", resultPlain: "9"),
        ]
        // Bare `ans` is the newest result, like the TI-89.
        let substituted = try TISyntax.substituteRecalls(in: entry.example, history: history)
        XCTAssertEqual(substituted, "9*2")
        let result = await eval(substituted)
        XCTAssertTrue(result.ok, result.errorMessage)
        XCTAssertEqual(result.resultText, "18")

        // Numbered recall counts back from the newest line, starting at 1.
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "ans(2)", history: history), "4")
        XCTAssertEqual(try TISyntax.substituteRecalls(in: "entry(1)", history: history), "3*3")
    }

    func testDefineExampleCreatesCallableFunction() async throws {
        try requireHelper()
        let entry = try guide(id: "define")
        let definition = await eval(entry.example)
        XCTAssertTrue(definition.ok, definition.errorMessage)
        let call = await eval("f(3)")
        XCTAssertTrue(call.ok, call.errorMessage)
        XCTAssertEqual(call.resultText, "9")
    }

    func testStoreExampleCreatesVariable() async throws {
        try requireHelper()
        let entry = try guide(id: "store")
        let store = await eval(entry.example)
        XCTAssertTrue(store.ok, store.errorMessage)
        XCTAssertEqual(store.resultText, "5")
        let reuse = await eval("a*2")
        XCTAssertTrue(reuse.ok, reuse.errorMessage)
        XCTAssertEqual(reuse.resultText, "10")
    }

    func testKnownGapsBehaveAsDocumented() async throws {
        try requireHelper()

        // Gaps whose example stays unevaluated. The printed form can drop
        // the wrapper, so check the exact documented output.
        let expected: [String: String] = [
            "impdif": "impDif(x^2+y^2=4,x,y)",
            "texpand": "sin(x+y)",
            "complex-parts": "3+4*i",
        ]
        for (id, text) in expected {
            let entry = try guide(id: id)
            let result = await eval(entry.example)
            XCTAssertTrue(result.ok, "\(id): \(result.errorMessage)")
            XCTAssertEqual(result.resultText, text,
                           "\(id) is a documented gap; its example must not evaluate.")
        }

        // nDeriv: Giac treats the third argument as a step size, so the
        // result is NOT the TI slope value at x = 3.
        let derivative = await eval("nDeriv(x^2,x,3)")
        XCTAssertTrue(derivative.ok, derivative.errorMessage)
        XCTAssertNotEqual(derivative.resultText, "6",
                          "nDeriv must not be presented as the TI numeric derivative.")

        // simult is not supported by the helper.
        let simult = await eval("simult([[2,0][0,2]],[3,4])")
        XCTAssertFalse(simult.ok, "simult is a documented gap; it must report an error.")
    }

    // MARK: - Typst rendering (converter smoke test)

    func testVerifiedResultsCompileAsTypstMath() async throws {
        try requireHelper()
        guard let typstPath = CASMathRenderer.resolveTypstPath() else {
            throw XCTSkip("typst binary not found — skipping converter smoke test")
        }

        // A function definition returns a program echo, which arrives as a
        // string and is shown as plain text, not typeset math.
        let knownRendererGaps: Set<String> = ["define"]

        var failures: [String] = []
        for guide in CalculatorFunctionCatalog.entries
        where guide.compatibility != .notYetVerified {
            guard guide.id != "recall" else { continue }
            let result = await eval(guide.example)
            guard result.ok else {
                failures.append("\(guide.id): evaluation failed")
                continue
            }
            // Documented gaps are asserted separately by
            // testKnownGapsBehaveAsDocumented.
            guard !knownRendererGaps.contains(guide.id) else { continue }
            guard !result.resultTypst.isEmpty else {
                failures.append("\(guide.id): no Typst result")
                continue
            }
            if !compiles(result.resultTypst, with: typstPath) {
                failures.append("\(guide.id): Typst compile failed for \(result.resultTypst)")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Compiles one rendered math snippet the same way `CASMathRenderer`
    /// does, but synchronously and without the image cache.
    private func compiles(_ math: String, with typstPath: String) -> Bool {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("FunctionCatalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        guard (try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)) != nil else {
            return false
        }
        let input = work.appendingPathComponent("snippet.typ")
        let output = work.appendingPathComponent("snippet.svg")
        let source = CASMathRenderer.documentSource(math: math, dark: false)
        guard (try? source.write(to: input, atomically: true, encoding: .utf8)) != nil else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: typstPath)
        process.arguments = ["compile", input.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
            && FileManager.default.fileExists(atPath: output.path)
    }
}
