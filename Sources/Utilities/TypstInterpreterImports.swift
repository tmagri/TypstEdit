import Foundation

// MARK: - TypstInterpreterImports.swift
// #import / #include execution. Imports load the file via fileLoader, interpret it in
// a fresh child environment (with a cycle guard), and bind exports:
//   - `import "x.typ" as m`  → the export set binds as one dict under `m`
//   - `import "x.typ": a, b` → only those names
//   - `import "x.typ": *`    → all exports
//   - no alias/items         → app-lenient: all exports bind unqualified (matches the
//     previous evaluator and hybrid .note documents that `#import "Troy.note"` then
//     read dict fields directly)
// Load failures stay silent, matching the old behavior.

extension TypstInterpreter {
    func evalImport(path: TypstExpr, alias: String?, items: TypstImportItems) throws -> TypstValue {
        guard let loader = fileLoader else { return .none }
        let pathValue = try eval(expr: path)
        guard case .str(let filename) = pathValue else { return .none }
        if importStack.contains(filename) { return .none }  // cycle guard
        guard let content = loader(filename) else { return .none }

        let childEnvironment = TypstEnvironment()
        let child = TypstInterpreter(
            environment: childEnvironment,
            fileLoader: loader,
            importStack: importStack + [filename]
        )

        let parser = TypstParser(input: content)
        guard let ast = try? parser.parse(), case .document(let nodes) = ast else { return .none }
        _ = child.evalRoot(nodes)

        var exports = childEnvironment.exportVariables()
        if let alias {
            let moduleDict = TypstDict(exports.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
            environment.define(identifier: alias, value: .dict(moduleDict))
            return .none
        }

        if case .names(let names) = items {
            exports = exports.filter { names.contains($0.key) }
        }
        for (key, value) in exports {
            environment.define(identifier: key, value: value)
        }
        return .none
    }

    /// `#include "file.typ"` splices the file's rendered markup at the include site.
    func evalInclude(path: TypstExpr) throws -> TypstValue {
        guard let loader = fileLoader else { return .none }
        let pathValue = try eval(expr: path)
        guard case .str(let filename) = pathValue else { return .none }
        if importStack.contains(filename) { return .none }
        guard let content = loader(filename) else { return .none }

        let parser = TypstParser(input: content)
        guard let ast = try? parser.parse(), case .document(let nodes) = ast else { return .none }
        let child = TypstInterpreter(
            environment: TypstEnvironment(),
            fileLoader: fileLoader,
            importStack: importStack + [filename]
        )
        return .content(child.evalRoot(nodes))
    }
}
