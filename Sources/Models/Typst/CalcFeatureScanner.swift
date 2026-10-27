import Foundation

/// What TypstEdit calculator features a document uses. `TypstCompiler` runs
/// this on every update: the result decides whether the calc bridge is
/// imported into the shadow file, whether `#calc` calls need resolving, and
/// whether the document is flagged as non-portable.
///
/// The *names* are not hardcoded here: they are parsed from the bridge module
/// (`Sources/Resources/Calc/bridge.typ`), so adding a wrapper there is enough
/// for detection to keep up.
struct CalcFeatureSummary: Equatable, Sendable {
    /// `#calc("…")` — one-shot CAS evaluations resolved at compile time.
    var usesCalcCall = false
    /// `#calc-table(expr, x, a, b, n)` — tabulated CAS evaluations.
    var usesCalcTable = false
    /// `#let a = calc-param(…)` — document parameters shared with the CAS.
    var usesCalcParam = false
    /// Names the document calls that only exist in the bridge, e.g. `plot`,
    /// `BesselJ`, `calc-call`. Sorted for stable output.
    var bridgeNames: [String] = []
    /// 1-based source lines where any feature appears.
    var lines: [Int] = []

    var usesBridge: Bool { !bridgeNames.isEmpty }

    /// True when the shadow must import the bridge. `#calc`/`#calc-table`
    /// calls are replaced by literals before compiling, so a document that
    /// uses only those needs neither the bridge nor the WASM core;
    /// `calc-param` is an identity function the bridge defines.
    var needsBridge: Bool { usesBridge || usesCalcParam }

    var usesAny: Bool { usesCalcCall || usesCalcTable || usesCalcParam || usesBridge }

    /// True when the compile pipeline needs a CAS round-trip (parameters
    /// and/or call resolution), as opposed to only importing the bridge.
    var needsResolution: Bool { usesCalcCall || usesCalcTable || usesCalcParam }

    /// Human-readable feature list for warnings and the status bar.
    var featureNames: [String] {
        var names: [String] = []
        if usesCalcCall { names.append("#calc") }
        if usesCalcTable { names.append("#calc-table") }
        if usesCalcParam { names.append("calc-param") }
        names.append(contentsOf: bridgeNames)
        return names
    }

    var firstLine: Int? { lines.min() }
}

/// Text scanner for TypstEdit calculator feature usage. Line-oriented by
/// design: a false positive costs only an import plus a portability warning,
/// never a wrong output.
enum CalcFeatureScanner {

    /// Bridge-defined names, parsed once from the bridge resource.
    nonisolated(unsafe) static let knownNames: [String] = CalcPlugin.definedNames().sorted()

    /// One regex alternation for every name the bridge provides, longest
    /// first so `#calc-table` wins over `calc`. `#calc`/`#calc-table` are
    /// matched with their hash because that is how documents call them.
    private static let featureRegex: NSRegularExpression = {
        let alternation = knownNames
            .sorted { $0.count > $1.count }
            .map { name -> String in
                let escaped = NSRegularExpression.escapedPattern(for: name)
                // compile-time calls: optional '#', string first argument
                return (name == "calc" || name == "calc-table") ? "#?" + escaped + #"(?=\s*\(\s*")"# : escaped
            }
            .joined(separator: "|")
        // Word-bounded and followed by an opening bracket: a declaration or a
        // call. Preceding `-`/`.`/`#` are excluded so `my-plot(` and
        // `#plot(`-style prefixes do not double-count, and `#calc(`'s own `#`
        // is matched explicitly above.
        return try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.-])(?:\(alternation))\\s*\\(")
    }()

    /// Blanks the contents of `"…"` string literals (keeping the quotes and
    /// the length, so offsets and line numbers are unchanged). Text inside a
    /// `#calc("BesselJ(n, 6)")` string is CAS input, not a Typst call, and must
    /// not count as bridge usage.
    static func maskingStringContents(_ source: String) -> String {
        var units = Array(source.utf16)
        var index = 0
        var inString = false
        while index < units.count {
            let unit = units[index]
            if inString {
                if unit == 0x5C, index + 1 < units.count { // backslash escape
                    units[index] = 0x20
                    if units[index + 1] != 0x0A { units[index + 1] = 0x20 }
                    index += 2
                    continue
                }
                if unit == 0x22 { inString = false }
                else if unit != 0x0A { units[index] = 0x20 }
            } else if unit == 0x22 {
                inString = true
            }
            index += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Scans raw document text (before any injection).
    static func scan(_ rawSource: String) -> CalcFeatureSummary {
        var summary = CalcFeatureSummary()
        guard !rawSource.isEmpty else { return summary }

        let source = maskingStringContents(rawSource)
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        var detected = Set<String>()
        var locations: [Int] = []

        for match in featureRegex.matches(in: source, options: [], range: full) {
            let token = ns.substring(with: match.range)
            let name = token
                .replacingOccurrences(of: "(", with: "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "#", with: "")
            switch name {
            case "calc": summary.usesCalcCall = true
            case "calc-table": summary.usesCalcTable = true
            case "calc-param": summary.usesCalcParam = true
            default: detected.insert(name)
            }
            locations.append(match.range.location)
        }

        summary.bridgeNames = detected.sorted()
        guard summary.usesAny else { return summary }

        // Line numbers for the warning, in one pass over the source.
        locations.sort()
        var line = 1
        var index = 0
        var lastRecorded = 0
        for location in locations {
            while index < min(location, ns.length) {
                if ns.character(at: index) == 0x0A { line += 1 }
                index += 1
            }
            if lastRecorded != line {
                summary.lines.append(line)
                lastRecorded = line
            }
        }
        return summary
    }
}

/// Decides whether the open document should be flagged as non-portable.
/// `.typ` files are flagged: they must compile in a stock Typst toolchain, and
/// the calculator bridge breaks that. `.note` files are exempt — notes are a
/// TypstEdit-native hybrid format whose helpers are always available.
enum CalcPortabilityPolicy {
    static func shouldWarn(fileExtension: String) -> Bool {
        fileExtension.lowercased() != "note"
    }

    /// The advisory warning shown in the diagnostics panel for `.typ` files.
    static func warning(summary: CalcFeatureSummary, fileExtension: String) -> TypstError? {
        guard shouldWarn(fileExtension: fileExtension), summary.usesAny else { return nil }
        let features = summary.featureNames.joined(separator: ", ")
        var issue = TypstError(
            line: summary.firstLine,
            message: "TypstEdit calculator features in use — this document is not portable Typst.",
            severity: .warning)
        issue.hints = [
            "Uses: \(features). These names come from the TypstEdit calculator bridge and its WebAssembly core; standard Typst has neither.",
            "The saved file will not compile in a stock Typst toolchain (typst CLI, typst.app, other editors).",
            "File ▸ Export As ▸ Standard Typst writes a version that does: #calc values are inlined and the calculator core is bundled next to it.",
            ".note files are exempt from this warning: notes are a TypstEdit-native format.",
        ]
        return issue
    }
}
