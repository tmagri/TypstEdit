import SwiftUI

struct FoundationEditorView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.presentationMode) var presentationMode
    
    @State private var searchText = ""
    @State private var navigationPath: [FoundationItem] = []
    
    struct FoundationItem: Identifiable {
        let id = UUID()
        let name: String
        let description: String
        let snippet: String
        var children: [FoundationItem]? = nil
    }
    
    let items: [FoundationItem] = [
        FoundationItem(name: "arguments", description: "Captured arguments to a function.", snippet: "arguments"),
        FoundationItem(name: "array", description: "A sequence of values.", snippet: "()", children: [
            FoundationItem(name: "len", description: "The number of values in the array.", snippet: ".len()"),
            FoundationItem(name: "first", description: "The first value in the array.", snippet: ".first()"),
            FoundationItem(name: "last", description: "The last value in the array.", snippet: ".last()"),
            FoundationItem(name: "at", description: "The value at the specified index.", snippet: ".at(0)"),
            FoundationItem(name: "push", description: "Adds a value to the end of the array.", snippet: ".push(value)"),
            FoundationItem(name: "pop", description: "Removes and returns the last value.", snippet: ".pop()"),
            FoundationItem(name: "insert", description: "Inserts a value at the specified index.", snippet: ".insert(0, value)"),
            FoundationItem(name: "remove", description: "Removes the value at the specified index.", snippet: ".remove(0)"),
            FoundationItem(name: "contains", description: "Checks if the array contains a value.", snippet: ".contains(value)"),
            FoundationItem(name: "find", description: "Finds the first value satisfying a predicate.", snippet: ".find(v => v == target)"),
            FoundationItem(name: "filter", description: "Returns a new array with values satisfying a predicate.", snippet: ".filter(v => v != none)"),
            FoundationItem(name: "map", description: "Applies a function to each value.", snippet: ".map(v => v * 2)"),
            FoundationItem(name: "rev", description: "Reverses the array.", snippet: ".rev()"),
            FoundationItem(name: "flatten", description: "Flattens nested arrays.", snippet: ".flatten()"),
            FoundationItem(name: "join", description: "Joins array values into a string or content.", snippet: ".join(\", \")"),
            FoundationItem(name: "slice", description: "Returns a sub-array.", snippet: ".slice(0, 5)"),
            FoundationItem(name: "sorted", description: "Returns a sorted version of the array.", snippet: ".sorted()"),
            FoundationItem(name: "dedup", description: "Removes duplicate values.", snippet: ".dedup()")
        ]),
        FoundationItem(name: "assert", description: "Ensures that a condition is fulfilled.", snippet: "#assert(condition, message: \"Error message\")"),
        FoundationItem(name: "auto", description: "A value that indicates a smart default.", snippet: "#auto"),
        FoundationItem(name: "bool", description: "A type with two states.", snippet: "#true"),
        FoundationItem(name: "bytes", description: "A sequence of bytes.", snippet: "#bytes(())"),
        FoundationItem(name: "calc", description: "Module for calculations and processing of numeric values.", snippet: "calc.", children: [
            FoundationItem(name: "abs", description: "The absolute value.", snippet: "#calc.abs(x)"),
            FoundationItem(name: "min", description: "The minimum value.", snippet: "#calc.min(a, b)"),
            FoundationItem(name: "max", description: "The maximum value.", snippet: "#calc.max(a, b)"),
            FoundationItem(name: "even", description: "Checks if an integer is even.", snippet: "#calc.even(x)"),
            FoundationItem(name: "odd", description: "Checks if an integer is odd.", snippet: "#calc.odd(x)"),
            FoundationItem(name: "mod", description: "The modulo.", snippet: "#calc.mod(a, b)"),
            FoundationItem(name: "pow", description: "The power.", snippet: "#calc.pow(base, exponent)"),
            FoundationItem(name: "sqrt", description: "The square root.", snippet: "#calc.sqrt(x)"),
            FoundationItem(name: "sin", description: "The sine.", snippet: "#calc.sin(angle)"),
            FoundationItem(name: "cos", description: "The cosine.", snippet: "#calc.cos(angle)"),
            FoundationItem(name: "tan", description: "The tangent.", snippet: "#calc.tan(angle)"),
            FoundationItem(name: "log", description: "The logarithm.", snippet: "#calc.log(x)"),
            FoundationItem(name: "ln", description: "The natural logarithm.", snippet: "#calc.ln(x)"),
            FoundationItem(name: "exp", description: "The exponential function.", snippet: "#calc.exp(x)"),
            FoundationItem(name: "floor", description: "Rounds down.", snippet: "#calc.floor(x)"),
            FoundationItem(name: "ceil", description: "Rounds up.", snippet: "#calc.ceil(x)"),
            FoundationItem(name: "round", description: "Rounds to the nearest integer.", snippet: "#calc.round(x)")
        ]),
        FoundationItem(name: "content", description: "A piece of document content.", snippet: "content"),
        FoundationItem(name: "datetime", description: "Represents a date, time, or both.", snippet: "#datetime(year: 2024, month: 1, day: 1)", children: [
            FoundationItem(name: "today", description: "The current date.", snippet: "#datetime.today()"),
            FoundationItem(name: "display", description: "Formats the date using a pattern.", snippet: ".display(\"[year]-[month]-[day]\")"),
            FoundationItem(name: "year", description: "The year component.", snippet: ".year()"),
            FoundationItem(name: "month", description: "The month component.", snippet: ".month()"),
            FoundationItem(name: "day", description: "The day component.", snippet: ".day()"),
            FoundationItem(name: "weekday", description: "The weekday component.", snippet: ".weekday()"),
            FoundationItem(name: "ordinal", description: "The ordinal day of the year.", snippet: ".ordinal()")
        ]),
        FoundationItem(name: "decimal", description: "A fixed-point decimal number type.", snippet: "#decimal(\"1.0\")"),
        FoundationItem(name: "dictionary", description: "A map from string keys to values.", snippet: "(:)", children: [
            FoundationItem(name: "len", description: "The number of pairs.", snippet: ".len()"),
            FoundationItem(name: "at", description: "The value at a key.", snippet: ".at(\"key\")"),
            FoundationItem(name: "keys", description: "Returns the keys as an array.", snippet: ".keys()"),
            FoundationItem(name: "values", description: "Returns the values as an array.", snippet: ".values()"),
            FoundationItem(name: "pairs", description: "Returns the pairs as an array.", snippet: ".pairs()"),
            FoundationItem(name: "insert", description: "Inserts or updates a value.", snippet: ".insert(\"key\", value)"),
            FoundationItem(name: "remove", description: "Removes a pair by key.", snippet: ".remove(\"key\")")
        ]),
        FoundationItem(name: "duration", description: "Represents a positive or negative span of time.", snippet: "1s"),
        FoundationItem(name: "eval", description: "Evaluates a string as Typst code.", snippet: "#eval(\"1 + 1\")"),
        FoundationItem(name: "float", description: "A floating-point number.", snippet: "1.0"),
        FoundationItem(name: "function", description: "A mapping from argument values to a return value.", snippet: "() => {}"),
        FoundationItem(name: "int", description: "A whole number.", snippet: "1"),
        FoundationItem(name: "label", description: "A label for an element.", snippet: "<label>"),
        FoundationItem(name: "module", description: "A collection of variables and functions that are commonly related to a single theme.", snippet: "module"),
        FoundationItem(name: "none", description: "A value that indicates the absence of any other value.", snippet: "#none"),
        FoundationItem(name: "panic", description: "Fails with an error.", snippet: "#panic(\"Error\")"),
        FoundationItem(name: "plugin", description: "Loads a WebAssembly module.", snippet: "#plugin(\"path/to/module.wasm\")"),
        FoundationItem(name: "regex", description: "A regular expression.", snippet: "#regex(\".*\")"),
        FoundationItem(name: "repr", description: "Returns the string representation of a value.", snippet: "#repr(value)"),
        FoundationItem(name: "selector", description: "A filter for selecting elements within the document.", snippet: "#selector(heading)"),
        FoundationItem(name: "std", description: "A module that contains all globally accessible items.", snippet: "std."),
        FoundationItem(name: "str", description: "A sequence of Unicode codepoints.", snippet: "\"string\"", children: [
             FoundationItem(name: "len", description: "The length of the string in codepoints.", snippet: ".len()"),
             FoundationItem(name: "first", description: "The first codepoint.", snippet: ".first()"),
             FoundationItem(name: "last", description: "The last codepoint.", snippet: ".last()"),
             FoundationItem(name: "at", description: "The codepoint at the specified index.", snippet: ".at(0)"),
             FoundationItem(name: "slice", description: "Returns a substring.", snippet: ".slice(0, 5)"),
             FoundationItem(name: "contains", description: "Checks if the string contains a substring.", snippet: ".contains(\"sub\")"),
             FoundationItem(name: "find", description: "Finds the first occurrence of a pattern.", snippet: ".find(regex(\"pattern\"))"),
             FoundationItem(name: "match", description: "Finds the first match of a regex.", snippet: ".match(regex(\"pattern\"))"),
             FoundationItem(name: "matches", description: "Finds all matches of a regex.", snippet: ".matches(regex(\"pattern\"))"),
             FoundationItem(name: "replace", description: "Replaces matches of a pattern.", snippet: ".replace(regex(\"old\"), \"new\")"),
             FoundationItem(name: "trim", description: "Removes surrounding whitespace.", snippet: ".trim()"),
             FoundationItem(name: "split", description: "Splits the string at a pattern.", snippet: ".split(\" \")"),
             FoundationItem(name: "rev", description: "Reverses the string.", snippet: ".rev()"),
             FoundationItem(name: "lower", description: "Converts to lowercase.", snippet: ".lower()"),
             FoundationItem(name: "upper", description: "Converts to uppercase.", snippet: ".upper()")
        ]),
        FoundationItem(name: "symbol", description: "A Unicode symbol.", snippet: "#symbol(\"a\")"),
        FoundationItem(name: "sys", description: "Module for system interactions.", snippet: "sys."),
        FoundationItem(name: "target", description: "Returns the current export target.", snippet: "target"),
        FoundationItem(name: "type", description: "Describes a kind of value.", snippet: "#type(value)"),
        FoundationItem(name: "version", description: "A version with an arbitrary number of components.", snippet: "#version(1, 0, 0)")
    ]
    
    // --- Data Access ---
    
    private var currentItems: [FoundationItem] {
        if !searchText.isEmpty {
             return getAllItems(from: items).filter {
                 $0.name.localizedCaseInsensitiveContains(searchText) ||
                 $0.description.localizedCaseInsensitiveContains(searchText)
             }
        }
        
        if let parent = navigationPath.last {
            return parent.children ?? []
        }
        return items
    }
    
    private func getAllItems(from items: [FoundationItem]) -> [FoundationItem] {
        var result = [FoundationItem]()
        for item in items {
            result.append(item)
            if let children = item.children {
                result.append(contentsOf: getAllItems(from: children))
            }
        }
        return result
    }
    
    // --- View ---
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if !navigationPath.isEmpty && searchText.isEmpty {
                    Button(action: {
                        navigationPath.removeLast()
                    }) {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    
                    Text(navigationPath.last?.name ?? "Foundation")
                        .font(.headline)
                } else {
                    Text("Insert Foundation Item")
                        .font(.headline)
                }
                
                Spacer()
                Button("Close") {
                    presentationMode.wrappedValue.dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search item...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            
            // Item List
            List(currentItems) { item in
                Button(action: {
                    if let children = item.children, searchText.isEmpty {
                        // Navigate down if has children and not searching
                        navigationPath.append(item)
                    } else {
                        // Insert snippet
                        controller.insertText(item.snippet, replacementRange: controller.selectedRange)
                        presentationMode.wrappedValue.dismiss()
                    }
                }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name)
                                .font(.headline)
                                .foregroundColor(.accentColor)
                            Text(item.description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        
                        // Show chevron if has children and not searching, else show snippet
                        if item.children != nil && searchText.isEmpty {
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        } else {
                            Text(item.snippet)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(4)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle()) // Make full row clickable
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 500, height: 600)
    }
}
