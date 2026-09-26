import XCTest
@testable import TypstEdit

/// Coverage for the Typst→Markdown interpreter subset: loops, flow control,
/// user-defined functions, destructuring, the method battery, display/repr rules,
/// and the per-snippet leak policy. Each test mirrors a behavior verified against
/// the reference compiler (Downloads/typst-main).
final class TypstInterpreterTests: XCTestCase {

    private func convert(_ source: String) -> String {
        TypstToMarkdownConverter.convert(source, isAlreadyMarkdown: false)
    }

    // MARK: - Loops & iteration

    func testForOverArray() {
        XCTAssertEqual(convert("#for item in (\"Alpha\", \"Beta\") [- #item]"), "- Alpha- Beta\n")
    }

    func testForOverRange() {
        XCTAssertEqual(convert("#for i in range(3) [Item #i]"), "Item 0Item 1Item 2\n")
    }

    func testForOverStringIteratesGraphemes() {
        XCTAssertEqual(convert("#for ch in \"ab\" [#ch.]"), "a.b.\n")
    }

    func testForOverDictYieldsPairs() {
        XCTAssertEqual(convert("#let d = (a: 1, b: 2)\n#for (k, v) in d [#k = #v ]"), "a = 1 b = 2\n")
    }

    func testForDestructuringArrayPattern() {
        XCTAssertEqual(convert("#for (a, b) in ((1, 2), (3, 4)) [#a#b ]"), "12 34\n")
    }

    func testWhileTerminates() {
        XCTAssertEqual(convert("#let n = 2 #while n > 0 [#n#{ n = n - 1 }]"), "21\n")
    }

    func testWhileCapLeaksSnippet() {
        // A non-terminating loop hits the 10,000-iteration reference cap; the
        // snippet's raw source leaks and the document survives.
        let output = convert("#let n = 0 #while true [x]\nafter")
        XCTAssertTrue(output.contains("#while true [x]"), "infinite loop should leak raw: \(output)")
        XCTAssertTrue(output.contains("after"), "document should survive: \(output)")
    }

    func testBreakInsideFor() {
        XCTAssertEqual(convert("#for i in range(5) [#i #if i == 2 [#break]]"), "0 1 2\n")
    }

    func testContinueSkipsRemainderOfIteration() {
        XCTAssertEqual(convert("#for i in range(4) [#if i == 1 [#continue]:#i]"), ":0:2:3\n")
    }

    func testBreakInsideWhile() {
        XCTAssertEqual(convert("#let n = 0 #while true [#if n == 3 [#break]-#n#{ n = n + 1 }]done"), "-0-1-2done\n")
    }

    // MARK: - Conditionals

    func testIfTakesTrueBranch() {
        XCTAssertEqual(convert("#if 3 > 2 [bigger] [smaller]"), "bigger\n")
    }

    func testIfElseIfChain() {
        let source = "#let x = 5\n#if x < 3 [small] else if x < 10 [medium] else [large]"
        XCTAssertEqual(convert(source), "medium\n")
    }

    func testStringConditionLeniency() {
        // App dialect: hybrid .note documents rely on "true"/"false" strings.
        XCTAssertEqual(convert("#if \"true\" [yes] [no]"), "yes\n")
    }

    func testBracedMarkupBodyAppDialect() {
        XCTAssertEqual(convert("#let big = true\n#if big { Big }"), "Big\n")
    }

    func testBracketElseWithoutElseKeyword() {
        // App dialect: `#if cond [a] [b]` — second bracket stands in for else.
        XCTAssertEqual(convert("#if 1 > 2 [yes] [no]"), "no\n")
    }

    // MARK: - Bindings & destructuring

    func testLetVariableEvaluation() {
        XCTAssertEqual(convert("#let name = \"Typst\"\n#name"), "Typst\n")
    }

    func testLetDestructuring() {
        XCTAssertEqual(convert("#let (a, b) = (1, 2)\n#a #b"), "1 2\n")
    }

    func testLetDictDestructuringWithSink() {
        XCTAssertEqual(convert("#let (a: x, ..rest) = (a: 1, b: 2, c: 3)\n#x #rest.b #rest.c"), "1 2 3\n")
    }

    func testCodeBlockMutationRebinds() {
        XCTAssertEqual(convert("#{ let n = 1 n = n + 1 n }"), "2\n")
    }

    func testAugmentedAssignment() {
        XCTAssertEqual(convert("#{ let total = 3 total += 4 total }"), "7\n")
    }

    // MARK: - Functions & closures

    func testFunctionCall() {
        XCTAssertEqual(convert("#let double(x) = x * 2\n#double(4)"), "8\n")
    }

    func testFunctionWithParenthesizedIfBody() {
        XCTAssertEqual(convert("#let fact(n) = if n <= 1 (1) else (n * fact(n - 1))\n#fact(5)"), "120\n")
    }

    func testParenthesizedClosure() {
        XCTAssertEqual(convert("#let add = (a, b) => a + b\n#add(2, 3)"), "5\n")
    }

    func testSingleArgArrowClosure() {
        XCTAssertEqual(convert("#repr(range(3).map(x => x + 1))"), "(1, 2, 3)\n")
    }

    func testClosureDefaultAndNamedArguments() {
        XCTAssertEqual(convert("#let greet(name, punct: \"!\") = [hi #name#punct]\n#greet(\"Ann\")"), "hi Ann!\n")
    }

    func testReturnExitsFunctionEarly() {
        XCTAssertEqual(convert("#let f(x) = { if x > 0 { return \"pos\" } \"neg\" }\n#f(1) #f(-1)"), "pos neg\n")
    }

    func testSpreadInCallAndArray() {
        XCTAssertEqual(convert("#let xs = (2, 3)\n#repr((1, ..xs, 4))"), "(1, 2, 3, 4)\n")
    }

    // MARK: - Methods & builtins

    func testMethodLenDesugarsToTypeFunction() {
        XCTAssertEqual(convert("#let items = (\"a\", \"b\")\n#items.len()"), "2\n")
    }

    func testArrayPushMutatesBinding() {
        XCTAssertEqual(convert("#let items = (\"a\", \"b\")\n#items.push(\"c\")\n#items.len()"), "3\n")
    }

    func testStringUpperAndLen() {
        XCTAssertEqual(convert("#let s = \"Hello\"\n#s.upper() #s.len()"), "HELLO 5\n")
    }

    func testStringSplit() {
        XCTAssertEqual(convert("#let parts = \"a,b,c\".split(\",\")\n#parts.len()"), "3\n")
    }

    func testArrayMapFoldFilterEnumerate() {
        XCTAssertEqual(convert("#repr(range(4).map(x => x * 2))"), "(0, 2, 4, 6)\n")
        XCTAssertEqual(convert("#range(1, 5).fold(0, (acc, x) => acc + x)"), "10\n")
        XCTAssertEqual(convert("#repr(range(6).filter(x => calc.rem(x, 2) == 0))"), "(0, 2, 4)\n")
        XCTAssertEqual(convert("#repr((\"a\", \"b\").enumerate())"), "((0, \"a\"), (1, \"b\"))\n")
    }

    func testDictInsertAndRepr() {
        XCTAssertEqual(convert("#let d = (a: 1)\n#d.insert(\"b\", 2)\n#repr(d)"), "(a: 1, b: 2)\n")
    }

    func testJoinStrings() {
        XCTAssertEqual(convert("#(\"a\", \"b\", \"c\").join(\", \")"), "a, b, c\n")
    }

    func testJoinNumbersThrowsLikeReference() {
        // Reference ops::join has no int+str arm — the snippet leaks raw.
        let output = convert("before #(1, 2).join(\", \") after")
        XCTAssertTrue(output.contains("#(1, 2).join("), "int join should leak raw: \(output)")
        XCTAssertTrue(output.contains("before") && output.contains("after"), "document survives: \(output)")
    }

    func testCalcBattery() {
        XCTAssertEqual(convert("#calc.max(2, 7) #calc.floor(3.7) #calc.abs(-4)"), "7 3 4\n")
    }

    func testNumbering() {
        XCTAssertEqual(convert("#numbering(\"I. 1)\", 2, 3)"), "II. 3)\n")
    }

    // MARK: - Display & repr rules

    func testDisplayFloatIntegralHasNoDecimal() {
        XCTAssertEqual(convert("#3.0 #1.5 #true"), "3 1.5 true\n")
    }

    func testConversions() {
        XCTAssertEqual(convert("#int(3.7) #float(2) #str(42)"), "3 2 42\n")
    }

    func testNoneDisplaysEmpty() {
        XCTAssertEqual(convert("x#none y"), "x y\n")
    }

    func testReprOfNonContentValuesIsCode() {
        XCTAssertEqual(convert("#repr((1, 2))"), "(1, 2)\n")
        XCTAssertEqual(convert("#repr(\"hi\")"), "\"hi\"\n")
    }

    func testUnknownIdentifierRendersAsItsName() {
        XCTAssertEqual(convert("#nope stays"), "nope stays\n")
    }

    func testUnknownFunctionCallLeaksAsContent() {
        XCTAssertEqual(convert("#frobnicate(1)"), "#frobnicate(1)\n")
    }

    // MARK: - Markup integration

    func testHeadingWithInlineSnippet() {
        XCTAssertEqual(convert("#let who = \"me\"\n= Title\n== Sub #who"), "# Title\n## Sub me\n")
    }

    func testMidLineEqualsIsText() {
        XCTAssertEqual(convert("#let k = \"a\"\n#let v = 1\n#k = #v list"), "a = 1 list\n")
    }

    func testBoldContainsSnippet() {
        XCTAssertEqual(convert("*bold #if true [yes]* text"), "**bold yes** text\n")
    }

    func testCodeSpanHashIsVerbatim() {
        XCTAssertEqual(convert("Use `#let x = 1` literally"), "Use `#let x = 1` literally\n")
    }

    func testMathPassesThrough() {
        XCTAssertEqual(convert("$x^2$ stays"), "$x^2$ stays\n")
    }

    func testEscapedHashIsText() {
        XCTAssertEqual(convert("\\#not-code"), "#not-code\n")
    }

    func testAdjacentSnippetsKeepSpace() {
        // `#expr` is atomic: `#3 #x` renders both values with the markup space kept.
        XCTAssertEqual(convert("#3 #x"), "3 x\n")
    }

    // MARK: - Content functions (renderer dispatch)

    func testLinkRenders() {
        XCTAssertEqual(convert("#link(\"https://example.com\")[Example]"), "[Example](https://example.com)\n")
    }

    func testTableWithHeader() {
        XCTAssertEqual(
            convert("#table(columns: 2, table.header[*A*][*B*], [1], [2])"),
            "| **A** | **B** |\n| --- | --- |\n| 1 | 2 |\n"
        )
    }

    func testStrikeRenders() {
        XCTAssertEqual(convert("#strike[old]"), "~~old~~\n")
    }

    // MARK: - Table round-trip (AICompletionService.visitTable emission)

    func testTableRoundTripsSanitizerEmission() {
        // Exact shape the sanitizer emits for a markdown table: multi-line,
        // align tuple, multi-line table.header call.
        let source = """
        #table(
          columns: 2,
          align: (left, right),
          table.header(
            [*Header 1*],
            [*Header 2*],
          ),
          [Cell 1],
          [Cell 2],
        )
        """
        XCTAssertEqual(convert(source), "| **Header 1** | **Header 2** |\n| --- | --- |\n| Cell 1 | Cell 2 |\n")
    }

    func testTableWithoutAlign() {
        let source = """
        #table(
          columns: 2,
          table.header(
            [*H1*],
            [*H2*],
          ),
          [a],
          [b],
        )
        """
        XCTAssertEqual(convert(source), "| **H1** | **H2** |\n| --- | --- |\n| a | b |\n")
    }

    func testTableColumnsAsArray() {
        XCTAssertEqual(convert("#table(columns: (auto, auto), [a], [b])"), "| a | b |\n| --- | --- |\n")
    }

    func testTableCellPositionalPayload() {
        XCTAssertEqual(
            convert("#table(columns: 2, table.cell(0, 0, [A]), table.cell(0, 1, [B]))"),
            "| A | B |\n| --- | --- |\n"
        )
    }

    func testTableCellsWithInlineEmph() {
        XCTAssertEqual(
            convert("#table(columns: 2, [Alice #emph[Smith]], [30])"),
            "| Alice *Smith* | 30 |\n| --- | --- |\n"
        )
    }

    func testMarkdownStrongInCell() {
        // Sanitizer-emitted cells can carry markdown-pasted `**strong**`.
        XCTAssertEqual(convert("#table(columns: 1, [**md bold**])"), "| **md bold** |\n| --- |\n")
    }

    func testTableCellWithBacktickSpanContainingBracket() {
        // Regression: bracket counting during content capture must ignore
        // backtick raw spans — `` `[0, 360)` `` has an unbalanced `[`, which
        // used to swallow the cell's own `]`, run the argument list to EOF
        // ("unterminated argument list"), and leak the whole table raw
        // (interval notation in table cells).
        XCTAssertEqual(
            convert("#table(columns: 1, [Orientation angle `[0, 360)`.])"),
            "| Orientation angle `[0, 360)`. |\n| --- |\n"
        )
    }

    func testTextCallDropsSizeArgument() {
        // Regression: `#text(26pt, weight: "bold")[X]` leaked its size into
        // the bold payload ("**26pt X**"). Only the content block is text;
        // sizes/fonts/fills cannot survive Markdown.
        XCTAssertEqual(convert("#text(26pt, weight: \"bold\")[Hello]"), "**Hello**\n")
        XCTAssertEqual(convert("#text(16pt, weight: \"medium\")[Lorem Ipsum]"), "Lorem Ipsum\n")
    }

    func testInlineMarkdownStrong() {
        XCTAssertEqual(convert("a **b** c"), "a **b** c\n")
    }

    func testSingleStarStillBold() {
        XCTAssertEqual(convert("a *b* c"), "a **b** c\n")
    }

    func testBacktickInsideBoldDoesNotHang() {
        // Regression: the bold loop's text run stops at a backtick without
        // consuming it, and nothing dispatched code spans — `*…(`dolor`)…*`
        // spun forever, freezing the Markdown export.
        XCTAssertEqual(
            convert("*Lorem ipsum (`dolor` sit `amet`):* consectetur"),
            "**Lorem ipsum (`dolor` sit `amet`):** consectetur\n"
        )
    }

    func testBacktickInsideHeadingDoesNotHang() {
        XCTAssertEqual(convert("= Title `code` more"), "# Title `code` more\n")
    }

    func testTableHlineSkipped() {
        // Rule lines carry no cells — skipping keeps the columns aligned.
        XCTAssertEqual(convert("#grid(columns: 2, grid.hline(), [a], [b])"), "| a | b |\n| --- | --- |\n")
    }

    func testTableRowFlattensCells() {
        XCTAssertEqual(
            convert("#table(columns: 2, table.row([a], [b]), [c], [d])"),
            "| a | b |\n| --- | --- |\n| c | d |\n"
        )
    }

    func testTableFooterFlattensCells() {
        XCTAssertEqual(convert("#table(columns: 1, [x], table.footer([f]))"), "| x |\n| --- |\n| f |\n")
    }

    func testHandwrittenTableWithUnitsAndStroke() {
        // Hand-written styling: fraction-unit columns and `0.5pt + black` stroke.
        // These sums have no Markdown meaning and must not leak the call.
        let source = """
        #table(
          columns: (auto, 1fr, 1fr, 1fr, 1.2fr, 1.2fr, 1fr, 1fr),
          align: center + horizon,
          stroke: 0.5pt + black,
          [], [*SPH*], [*CYL*], [*Axis*], [*Near-ADD*], [*Inter-ADD*], [*PD*], [*BVD*],
          [*R*], [0.00], [-0.50], [160], [1.00], [], [], [],
          [*L*], [0.00], [-1.75], [163], [1.00], [], [], []
        )
        """
        XCTAssertEqual(
            convert(source),
            "|  | **SPH** | **CYL** | **Axis** | **Near-ADD** | **Inter-ADD** | **PD** | **BVD** |\n" +
            "| --- | --- | --- | --- | --- | --- | --- | --- |\n" +
            "| **R** | 0.00 | -0.50 | 160 | 1.00 |  |  |  |\n" +
            "| **L** | 0.00 | -1.75 | 163 | 1.00 |  |  |  |\n"
        )
    }

    func testHandwrittenPrismTable() {
        let source = """
        #table(
          columns: (1.5fr, 1.5fr, 1.5fr, 1.5fr, 1.5fr),
          align: center + horizon,
          stroke: 0.5pt + black,
          [], [*H-DIST*], [*V-DIST*], [*H-NEAR*], [*V-NEAR*],
          [*R PRISM*], [], [], [], [],
          [*L PRISM*], [], [], [], []
        )
        """
        XCTAssertEqual(
            convert(source),
            "|  | **H-DIST** | **V-DIST** | **H-NEAR** | **V-NEAR** |\n" +
            "| --- | --- | --- | --- | --- |\n" +
            "| **R PRISM** |  |  |  |  |\n" +
            "| **L PRISM** |  |  |  |  |\n"
        )
    }

    func testQuantityAdditionIsLenient() {
        // Styling sums degrade to strings instead of throwing — the renderer
        // drops the named arguments, so nothing user-visible changes.
        XCTAssertEqual(convert("#table(columns: 1, stroke: 0.5pt + black, [a])"), "| a |\n| --- |\n")
        XCTAssertEqual(convert("#table(columns: 1, stroke: 0.5pt + rgb(0, 0, 0), [a])"), "| a |\n| --- |\n")
        // Plain arithmetic is untouched.
        XCTAssertEqual(convert("#{ 2 + 3 }"), "5\n")
        XCTAssertEqual(convert("#repr(2cm + 3cm)"), "5cm\n")
    }

    // MARK: - Remaining renderer dispatch cases

    func testVerticalSpaceBreaks() {
        // Call form dispatches; a bare `#v` stays an unknown identifier rendered
        // as its name (same lenient policy as the old converter).
        XCTAssertEqual(convert("above#v()below"), "above\n\nbelow\n")
        XCTAssertEqual(convert("above#vbelow"), "abovevbelow\n")
    }

    func testOutlineRendersTOC() {
        XCTAssertEqual(convert("#outline()"), "[TOC]\n")
    }

    func testImageRenders() {
        XCTAssertEqual(convert("#image(\"pic.png\")"), "![image](pic.png)\n")
    }

    func testFootnoteRenders() {
        XCTAssertEqual(convert("#footnote[see notes]"), "^[see notes]\n")
    }

    func testQuoteBlockRenders() {
        XCTAssertEqual(convert("#quote[To be]"), "> To be\n")
        XCTAssertEqual(convert("#quote[a\nb]"), "> a\n> b\n")
    }

    func testHighlightSuperSubUnderline() {
        XCTAssertEqual(convert("#highlight[hot]"), "==hot==\n")
        XCTAssertEqual(convert("#super[2]"), "<sup>2</sup>\n")
        XCTAssertEqual(convert("#sub[1]"), "<sub>1</sub>\n")
        XCTAssertEqual(convert("#underline[u]"), "<u>u</u>\n")
    }

    func testPagebreakAndLineRenderRule() {
        XCTAssertEqual(convert("a#pagebreak()b"), "a\n---\n\nb\n")
        XCTAssertEqual(convert("a#line()b"), "a\n---\n\nb\n")
    }

    // MARK: - Recovery policy

    func testBadSnippetLeaksItsLineAndDocumentSurvives() {
        XCTAssertEqual(convert("before #let = broken after\nmore"), "before #let = broken after\nmore\n")
    }

    // MARK: - Layout templates (#show: template.with(...))

    func testNamedDefaultParamsDontConsumePositionals() {
        // Reference call.rs: positional arguments bind to default-less
        // parameters only — `#let f(date: none, body)` called `#f(x)` fills body.
        XCTAssertEqual(convert("#let f(date: none, body) = { body }\n#f(x)"), "x\n")
    }

    func testShowApplyTemplateRendersHeaderThenBody() {
        let source = """
        #let doc-layout(title: none, body) = {
          align(center)[
            #block(width: 100%)[
              #if title != none { text(weight: "bold", size: 28pt)[#title] }
            ]
          ]
          body
        }
        #show: doc-layout.with(title: "Quarterly Report")
        = Section
        Body text.
        """
        let output = convert(source)
        XCTAssertTrue(output.contains("**Quarterly Report**"), "title should render bold: \(output)")
        XCTAssertTrue(output.contains("# Section"), "show body should render: \(output)")
        XCTAssertTrue(output.contains("Body text."), "trailing body should render: \(output)")
    }

    func testBracedIfBodyRendersTypstCalls() {
        XCTAssertEqual(convert("#if true { text(weight: \"bold\")[T] }"), "**T**\n")
    }

    func testBracedProseBodyStaysMarkup() {
        // The app dialect keeps prose bodies (`{ Big }`) as markup so spacing
        // survives; only code-punctuation bodies switch to code parse.
        XCTAssertEqual(convert("#let big = true\n#if big { Big }"), "Big\n")
    }

    func testAlignDropsAlignmentWords() {
        XCTAssertEqual(convert("#align(center)[X]"), "X\n")
        XCTAssertEqual(convert("#align(center + horizon)[X]"), "X\n")
        XCTAssertEqual(convert("#align(top, right)[X]"), "X\n")
    }

    func testTextWeightBoldRendersBold() {
        XCTAssertEqual(convert("#text(weight: \"bold\")[T]"), "**T**\n")
        XCTAssertEqual(convert("#text(weight: \"medium\")[T]"), "T\n")
    }

    func testCounterChainStaysSilent() {
        // counter machinery is dropped: every member access/call yields none,
        // which displays empty (the "Page #current of #total" cosmetic case).
        // The markup spaces around the snippets are preserved.
        XCTAssertEqual(convert("Page #counter(page).get().first() of #counter(page).final().first() end"), "Page  of  end\n")
    }

    func testDatetimeTodayDisplaysRealDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        XCTAssertEqual(
            convert("#datetime.today().display(\"[month repr:long] [day], [year]\")"),
            formatter.string(from: Date()) + "\n"
        )
    }

    func testDatetimeDisplayWithoutPatternUsesTypstDefault() {
        // Regression: display() with no pattern rendered empty (typst's
        // documented default is [year]-[month repr:short]-[day]).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MMM-d"
        XCTAssertEqual(
            convert("#datetime.today().display()"),
            formatter.string(from: Date()) + "\n"
        )
    }

    func testFunctionWithPartialApplication() {
        XCTAssertEqual(convert("#let f(a, b) = [#a#b]\n#f.with(\"x\")(\"y\")"), "xy\n")
    }

    // MARK: - Imports

    func testImportAllThenConditional() {
        let input = """
        #import "lib.typ"
        #let enabled = true
        #if enabled {
          Hello
        } else {
          No
        }
        """
        let output = convert(input)
        XCTAssertTrue(output.contains("Hello"))
        XCTAssertFalse(output.contains("No"))
    }

    func testImportSelectedNamesViaFileLoader() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let lib = tempDir.appendingPathComponent("lib.typ")
        try? "#let wanted = \"yes\"\n#let unwanted = \"no\"".write(to: lib, atomically: true, encoding: .utf8)

        let output = TypstToMarkdownConverter.convert(
            "#import \"lib.typ\": wanted\n#wanted",
            isAlreadyMarkdown: false,
            fileLoader: { name in
                try? String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
            }
        )
        XCTAssertTrue(output.contains("yes"), "selected import should bind: \(output)")
        XCTAssertFalse(output.contains("no\n"), "unselected name should not bind: \(output)")
    }

    func testImportNoteVariablesViaFileLoader() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let note = tempDir.appendingPathComponent("glossary.note")
        let noteContent = """
        #let terms = (
          mainTerm: "Lorem"
        )
        """
        try? noteContent.write(to: note, atomically: true, encoding: .utf8)

        let output = TypstToMarkdownConverter.convert(
            "#import \"glossary.note\"\n#terms.mainTerm",
            isAlreadyMarkdown: false,
            fileLoader: { name in
                try? String(contentsOf: tempDir.appendingPathComponent(name), encoding: .utf8)
            }
        )
        XCTAssertTrue(output.contains("Lorem"), "imported note variables should resolve: \(output)")
    }
}
