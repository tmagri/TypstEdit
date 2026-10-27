import Foundation

/// Installs the two files that make calculator functions available to the
/// Typst compiler:
///
/// - `TypstEditCalc.wasm`  — the compiled numeric core (built from
///   `Tools/calc-plugin/`), loaded by Typst's plugin API.
/// - `TypstEditCalcBridge.typ` — the bridge module (`Sources/Resources/Calc/
///   bridge.typ`): typed wrappers, generic `calc-call`, `calc-param`, `plot`.
///
/// Typst resolves both by path relative to the document, so the compiler needs
/// them next to the shadow file. The bridge is imported into the shadow with a
/// single `#import` line; nothing is injected as a string literal.
nonisolated enum CalcPlugin {

    /// The compiled numeric core.
    static let wasmFileName = "TypstEditCalc.wasm"
    /// The Typst bridge module, as installed next to the document.
    static let bridgeFileName = "TypstEditCalcBridge.typ"
    /// The bridge's file name in the source tree / app bundle.
    static let bridgeSourceName = "bridge.typ"
    /// Minimum `abi_version` the app accepts from the wasm module.
    static let requiredABIVersion = 2

    /// The import line prepended to the shadow document. Only the bridge's
    /// public names are imported, so private helpers (`_calc`, `_calc-in`, …)
    /// never shadow or collide with the document's own definitions.
    static var importStatement: String {
        let names = definedNames().subtracting(["calc", "calc-table"]).sorted()
        guard !names.isEmpty else { return "#import \"\(bridgeFileName)\": *\n" }
        return "#import \"\(bridgeFileName)\": " + names.joined(separator: ", ") + "\n"
    }

    // MARK: - Lookup

    private struct Candidate {
        let path: String
    }

    /// Search order mirrors the other helper binaries: app bundle resources,
    /// then developer builds, then system installs.
    private static func candidates(for fileName: String) -> [String] {
        var paths: [String] = []
        // SwiftPM resources (Sources/Resources/Calc) live in the module bundle,
        // not in Bundle.main; `ModuleResources.main` finds it in both the
        // packaged app and command-line builds.
        if let moduleResources = ModuleResources.main.resourcePath {
            paths.append("\(moduleResources)/Calc/\(fileName)")
            paths.append("\(moduleResources)/\(fileName)")
        }
        if let resources = Bundle.main.resourcePath {
            paths.append("\(resources)/bin/\(fileName)")
            paths.append("\(resources)/Calc/\(fileName)")
            paths.append("\(resources)/\(fileName)")
        }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            paths.append(executable.appendingPathComponent("build/calc/\(fileName)").path)
            paths.append(executable.appendingPathComponent(fileName).path)
        }
        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        paths.append(sourceRoot.appendingPathComponent("build/calc/\(fileName)").path)
        paths.append(sourceRoot.appendingPathComponent("Sources/Resources/Calc/\(fileName)").path)
        paths.append(
            NSString(string: "~/Desktop/TypstEdit/build/calc/\(fileName)").expandingTildeInPath)
        paths.append("/usr/local/bin/\(fileName)")
        paths.append("/opt/homebrew/bin/\(fileName)")
        return paths
    }

    /// Debug aid: prints the search paths once (used by tests when discovery fails).
    static func debugSearchPaths() -> String {
        let wasm = candidates(for: wasmFileName)
        let bridge = candidates(for: bridgeFileName)
        return "cwd=\(FileManager.default.currentDirectoryPath)\n" +
            "wasm:\n" + wasm.joined(separator: "\n") +
            "\nbridge:\n" + bridge.joined(separator: "\n")
    }

    static func locateWasm() -> String? {
        candidates(for: wasmFileName).first { FileManager.default.isReadableFile(atPath: $0) }
    }

    static func locateBridge() -> String? {
        // The bridge keeps its source name (`bridge.typ`) in the repo and the
        // app bundle; only the copy installed next to a document is renamed.
        var paths = candidates(for: bridgeFileName)
        paths.append(contentsOf: candidates(for: bridgeSourceName))
        return paths.first { FileManager.default.isReadableFile(atPath: $0) }
    }

    static var isAvailable: Bool { locateWasm() != nil && locateBridge() != nil }

    // MARK: - Install

    private static func copyIfNeeded(from source: String, into directory: URL, name: String) -> Bool {
        let destination = directory.appendingPathComponent(name)
        let manager = FileManager.default
        // Compare contents, not sizes: an edited bridge of the same length
        // (or an updated wasm) must replace a stale copy. Both are small.
        if let existing = manager.contents(atPath: destination.path),
           let fresh = manager.contents(atPath: source),
           existing == fresh {
            return true
        }
        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.copyItem(atPath: source, toPath: destination.path)
            return true
        } catch {
            print("[CalcPlugin] could not install \(name) into \(directory.path): \(error)")
            return manager.isReadableFile(atPath: destination.path)
        }
    }

    /// Copies the wasm core and the bridge next to the document the compiler is
    /// about to build. Returns false when the core has not been built, so the
    /// caller can warn instead of injecting an import that cannot resolve.
    @discardableResult
    nonisolated static func install(into directory: URL) -> Bool {
        guard let wasm = locateWasm() else { return false }
        guard copyIfNeeded(from: wasm, into: directory, name: wasmFileName) else { return false }
        if let bridge = locateBridge() {
            guard copyIfNeeded(from: bridge, into: directory, name: bridgeFileName) else { return false }
        } else {
            // A missing bridge is fatal for the import; treat as unbuilt.
            return false
        }
        return true
    }

    /// Removes installed copies (housekeeping for temp folders).
    nonisolated static func uninstall(from directory: URL) {
        let manager = FileManager.default
        try? manager.removeItem(at: directory.appendingPathComponent(wasmFileName))
        try? manager.removeItem(at: directory.appendingPathComponent(bridgeFileName))
    }

    // MARK: - Bridge introspection

    /// Names the bridge defines with `#let name(…)`, parsed from the bridge
    /// source. Used by the feature scanner and the portability warning, so
    /// adding a wrapper to `bridge.typ` needs no Swift change.
    ///
    /// Falls back to the well-known set when the resource is unavailable
    /// (for example in a headless build that only ships the wasm).
    static func definedNames() -> Set<String> {
        guard let path = locateBridge(),
              let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return fallbackDefinedNames
        }
        return parseDefinedNames(source)
    }

    /// Parses `#let <name>(` declarations, ignoring private `_`-prefixed names.
    static func parseDefinedNames(_ source: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: #"(?m)^\s*#let\s+([A-Za-z][A-Za-z0-9_-]*)\s*\("#)
        let ns = source as NSString
        var names = Set<String>()
        for match in pattern.matches(in: source, options: [], range: NSRange(location: 0, length: ns.length)) {
            names.insert(ns.substring(with: match.range(at: 1)))
        }
        // Names provided by the app rather than the bridge file: `#calc` and
        // `#calc-table` are resolved during compilation, not defined in Typst.
        names.insert("calc")
        names.insert("calc-table")
        return names
    }

    // MARK: - Completion data

    /// Registry functions callable through `calc-call("name", …)`, from the
    /// `functions.txt` resource the plugin build script generates from
    /// `calc_dispatch.c` (kept in sync by a test).
    static let registryFunctions: [(name: String, arity: Int)] = {
        guard let path = candidates(for: "functions.txt").first(where: { FileManager.default.isReadableFile(atPath: $0) }),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "/")
            guard parts.count == 2, let arity = Int(parts[1]) else { return nil }
            return (String(parts[0]), arity)
        }
    }()

    /// Public bridge functions with their parameter names, parsed from
    /// `bridge.typ`: named parameters in the signature plus names read through
    /// `args.at("…")` (how `plot` accepts `x-min:` and friends).
    static let bridgeSignatures: [String: [String]] = {
        guard let path = locateBridge(),
              let source = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        return parseSignatures(source)
    }()

    static func parseSignatures(_ source: String) -> [String: [String]] {
        let head = try! NSRegularExpression(pattern: #"(?m)^#let\s+([A-Za-z][A-Za-z0-9_-]*)\s*\("#)
        let named = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9-]*)\s*:"#)
        let atKey = try! NSRegularExpression(pattern: #"args\.at\("([A-Za-z][A-Za-z0-9-]*)""#)
        let ns = source as NSString
        let heads = head.matches(in: source, range: NSRange(location: 0, length: ns.length))
        var result: [String: [String]] = [:]
        for (index, match) in heads.enumerated() {
            let name = ns.substring(with: match.range(at: 1))
            // The signature runs to the matching ')'.
            var depth = 0, cursor = match.range.upperBound - 1, end = cursor
            while cursor < ns.length {
                let c = ns.character(at: cursor)
                if c == 0x28 { depth += 1 }
                if c == 0x29 { depth -= 1; if depth == 0 { end = cursor; break } }
                cursor += 1
            }
            let signature = ns.substring(with: NSRange(location: match.range.upperBound, length: max(0, end - match.range.upperBound)))
            let bodyEnd = index + 1 < heads.count ? heads[index + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: end, length: max(0, bodyEnd - end)))
            var parameters: [String] = []
            for m in named.matches(in: signature, range: NSRange(location: 0, length: (signature as NSString).length)) {
                parameters.append((signature as NSString).substring(with: m.range(at: 1)))
            }
            for m in atKey.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                let key = (body as NSString).substring(with: m.range(at: 1))
                if !parameters.contains(key) { parameters.append(key) }
            }
            result[name] = parameters
        }
        return result
    }

    private static let fallbackDefinedNames: Set<String> = [
        "BesselJ", "BesselY", "BesselI", "BesselK", "calc-gamma", "calc-lgamma",
        "calc-param", "plot", "calc-call", "calc-fn", "calc-functions",
        "calc", "calc-table",
    ]
}
