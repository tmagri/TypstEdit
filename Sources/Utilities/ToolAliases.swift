import Foundation

/// Redirects tool names models carry over from other harnesses onto the tool
/// that actually exists here.
///
/// A model that has been trained on `bash`, `str_replace_editor`, or
/// `todo_write` will sometimes call those names even when the request offered
/// a different set. Without a redirect the call fails, and the model usually
/// spends the next round discovering the real name — two requests to learn
/// something the harness already knows. The alias table is a small, explicit
/// list of the names that recur, not a fuzzy matcher: a wrong redirect would
/// be worse than an honest failure.
///
/// A redirect is reported back to the model as well as performed, so it calls
/// the right name itself next time instead of relying on the alias forever.
enum ToolAliases {

    /// Aliases keyed by the name a model may send, valued by the suffix of the
    /// tool that should run. Matching is on the tool *suffix*
    /// (`bash`, `run`), not the qualified `server__tool` name, because models
    /// invent the namespace as often as the name.
    ///
    /// Deliberately short. Each entry is a name seen in the wild whose
    /// meaning is unambiguous in this harness.
    static let byPlainName: [String: String] = [
        // Shell/execution tools from other harnesses. There is no shell tool
        // here, but `run` is the closest equivalent and its approval prompt
        // shows the exact code, so nothing runs unreviewed.
        "bash": "run",
        "shell": "run",
        "execute": "run",
        "execute_command": "run",
        "run_command": "run",
        "python": "run",
        "execute_code": "run",
        // Editing tools.
        "str_replace_editor": "edit_file",
        "str_replace": "edit_file",
        "search_replace": "edit_file",
        "replace_string_in_file": "edit_file",
        "apply_patch": "edit_file",
        "create_file": "write_file",
        "write": "write_file",
        // Reading and searching.
        "view": "read_file",
        "open_file": "read_file",
        "cat": "read_file",
        "read": "read_file",
        "grep": "grep_project",
        "search": "grep_project",
        "ripgrep": "grep_project",
        "glob": "list_files",
        "ls": "list_files",
        "list_directory": "list_files",
        "find": "list_files",
        // Task lists.
        "todo_write": "update_plan",
        "todowrite": "update_plan",
        "todo": "update_plan",
        "update_todos": "update_plan",
        // Web.
        "fetch": "web_fetch",
        "curl": "web_fetch",
        "browse": "web_fetch"
    ]

    /// The suffix of a qualified name (`project__read_file` → `read_file`),
    /// or the whole name when it has no namespace.
    static func plainName(_ qualifiedName: String) -> String {
        qualifiedName.range(of: "__").map { String(qualifiedName[$0.upperBound...]) } ?? qualifiedName
    }

    /// Resolves a model-sent name onto a tool that is actually offered.
    ///
    /// `candidates` are the qualified names the request offered. Returns the
    /// matching candidate, or `nil` when the name is already valid or nothing
    /// reasonable matches. An exact qualified match always wins, so this can
    /// never redirect a real tool call.
    static func resolve(_ name: String, against candidates: [String]) -> String? {
        if candidates.contains(name) { return nil }          // already valid
        if let exact = candidates.first(where: { plainName($0) == plainName(name) }) {
            // Same tool, wrong namespace — still worth correcting the name so
            // the transcript and the model's next call agree.
            return name == exact ? nil : exact
        }
        guard let target = byPlainName[plainName(name).lowercased()] else { return nil }
        // Prefer a tool in the same namespace the model used, so a redirected
        // `project2__bash` stays within project tools when possible.
        let namespace = name.range(of: "__").map { String(name[..<$0.lowerBound]) }
        if let namespace,
           let sameNamespace = candidates.first(where: { $0 == "\(namespace)__\(target)" }) {
            return sameNamespace
        }
        return candidates.first { plainName($0) == target }
    }

    /// The note handed back to the model alongside a redirected call's output.
    /// Naming the tool it actually ran is what stops the model repeating the
    /// wrong name.
    static func redirectNote(called: String, ran: String) -> String {
        "There is no \"\(called)\" tool here, so this ran as \"\(ran)\". Call \"\(ran)\" directly next time."
    }
}
