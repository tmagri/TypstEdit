import Foundation

// Standalone test for TypstCompiler.normalizeRawLanguages (Sources/Models/TypstCompiler.swift).
// Run:  swift NormalizeRawLanguagesTests.swift
// The implementation below MUST be kept in sync with the app; it is copied
// verbatim so the logic can be tested without building the full package.

enum CompilerRegex {
    static let rawFenceOpen = try! NSRegularExpression(pattern: #"^(\s*`{3,})(\s*)([A-Za-z0-9_#+.-]+)(.*)$"#)
}

let rawLanguageAliases: [String: String] = [
    "csharp": "cs", "c#": "cs", "c++": "cpp", "cxx": "cpp", "cc": "cpp",
    "shell": "bash", "zsh": "bash", "console": "bash", "terminal": "bash",
    "docker": "dockerfile", "objc": "objective-c", "obj-c": "objective-c",
    "fsharp": "fs", "json5": "json", "jsonl": "json", "node": "javascript",
    "nodejs": "javascript", "mjs": "javascript", "cjs": "javascript",
]

let knownRawLanguages: Set<String> = [
    "bash", "c", "cc", "console", "cpp", "csharp", "css", "cjs", "cs",
    "dart", "diff", "docker", "dockerfile", "fs", "fsharp", "go",
    "golang", "html", "javascript", "java", "json", "json5", "jsonc",
    "jsonl", "js", "kotlin", "lua", "makefile", "mjs", "node", "nodejs",
    "nix", "objc", "obj-c", "objective-c", "perl", "python", "ruby",
    "rust", "rb", "scala", "shell", "sh", "sql", "swift", "terminal",
    "toml", "typescript", "ts", "xml", "yaml", "yml", "zsh", "c#", "c++", "cxx",
]

func normalizeRawLanguages(_ source: String) -> String {
    guard source.contains("`") else { return source }
    var lines = source.components(separatedBy: "\n")
    var fenceRun = 0
    for i in lines.indices {
        let line = lines[i]
        if fenceRun > 0 {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "`" }), trimmed.count >= fenceRun {
                fenceRun = 0
            }
            continue
        }
        let nsLine = line as NSString
        guard let match = CompilerRegex.rawFenceOpen.firstMatch(
            in: line, range: NSRange(0..<nsLine.length)
        ) else { continue }
        let fence = nsLine.substring(with: match.range(at: 1))
        let gap = nsLine.substring(with: match.range(at: 2))
        let tag = nsLine.substring(with: match.range(at: 3))
        let rest = nsLine.substring(with: match.range(at: 4))
        let key = tag.lowercased()
        if let mapped = rawLanguageAliases[key] {
            lines[i] = fence + mapped + rest
        } else if !gap.isEmpty, knownRawLanguages.contains(key) {
            lines[i] = fence + tag + rest
        }
        if !rest.contains("`") {
            fenceRun = fence.filter { $0 == "`" }.count
        }
    }
    return lines.joined(separator: "\n")
}

// --- Tests ---
var failures = 0
func expect(_ input: String, _ expected: String, _ label: String) {
    let got = normalizeRawLanguages(input)
    if got != expected {
        failures += 1
        print("FAIL \(label)\n  in: \(input.split(separator: "\n").map{"\t"+$0}.joined(separator: "\n"))\n  want: \(expected.split(separator: "\n").map{"\t"+$0}.joined(separator: "\n"))\n  got:  \(got.split(separator: "\n").map{"\t"+$0}.joined(separator: "\n"))")
    } else {
        print("ok   \(label)")
    }
}

expect("```csharp\nint x;\n```", "```cs\nint x;\n```", "csharp -> cs")
expect("```c#\nint x;\n```", "```cs\nint x;\n```", "c# -> cs (no fence leak)")
expect("```c++\nint x;\n```", "```cpp\nint x;\n```", "c++ -> cpp (no fence leak)")
expect("```CSharp\nint x;\n```", "```cs\nint x;\n```", "case-insensitive alias")
expect("``` json\n{\"a\": 1}\n```", "```json\n{\"a\": 1}\n```", "gap closed for known lang")
expect("```json\n{\"a\": 1}\n```", "```json\n{\"a\": 1}\n```", "valid tag untouched")
expect("```json \n{\"a\": 1}\n```", "```json \n{\"a\": 1}\n```", "trailing space untouched (no gap)")
expect("```\nplain\n```", "```\nplain\n```", "untagged fence untouched")
expect("``` foobar\nx\n```", "``` foobar\nx\n```", "unknown token: gap kept (no content loss)")
expect("```json some caption\n{}\n```", "```json some caption\n{}\n```", "extra words preserved (content)")
expect("```shell\necho hi\n```", "```bash\necho hi\n```", "shell -> bash")
expect("```docker\nFROM x\n```", "```dockerfile\nFROM x\n```", "docker -> dockerfile")
expect("```objc\nx\n```", "```objective-c\nx\n```", "objc -> objective-c")
expect("```fsharp\nx\n```", "```fs\nx\n```", "fsharp -> fs")
expect("```json5\n{}\n```", "```json\n{}\n```", "json5 -> json")
expect("```csharp\nint x;\n```csharp\nint y;\n```", "```cs\nint x;\n```csharp\nint y;\n```", "inner fence-looking line untouched")
expect("````csharp\n```json\n{}\n```\n````", "````cs\n```json\n{}\n```\n````", "outer 4-fence: inner 3-fence is content")
expect("```rust let x = 1```\n```csharp\ny\n```", "```rust let x = 1```\n```cs\ny\n```", "single-line raw then block")
expect("```csharp\nx\n```\nmore text\n```csharp\ny\n```", "```cs\nx\n```\nmore text\n```cs\ny\n```", "two sequential blocks")
let multi = "a\n```csharp\nx\n```\nb"
if normalizeRawLanguages(multi).components(separatedBy: "\n").count != multi.components(separatedBy: "\n").count {
    failures += 1; print("FAIL line count changed")
} else { print("ok   line count preserved") }
expect("hello world", "hello world", "no backticks fast path")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
