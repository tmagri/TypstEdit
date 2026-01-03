import SwiftUI

struct SymbolPickerView: View {
    @ObservedObject var controller: EditorController
    @Environment(\.presentationMode) var presentationMode
    
    @State private var searchText = ""
    @State private var selectedCategory: String = "Greek"
    
    // Data Structure for Symbols
    struct SymbolCategory: Identifiable {
        let id = UUID()
        let name: String
        let symbols: [(display: String, code: String, name: String)]
    }
    
    let categories: [SymbolCategory] = [
        SymbolCategory(name: "Greek", symbols: [
            ("α", "alpha", "alpha"), ("β", "beta", "beta"), ("γ", "gamma", "gamma"), ("δ", "delta", "delta"),
            ("ε", "epsilon", "epsilon"), ("ζ", "zeta", "zeta"), ("η", "eta", "eta"), ("θ", "theta", "theta"),
            ("ι", "iota", "iota"), ("κ", "kappa", "kappa"), ("λ", "lambda", "lambda"), ("μ", "mu", "mu"),
            ("ν", "nu", "nu"), ("ξ", "xi", "xi"), ("ο", "omicron", "omicron"), ("π", "pi", "pi"),
            ("ρ", "rho", "rho"), ("σ", "sigma", "sigma"), ("τ", "tau", "tau"), ("υ", "upsilon", "upsilon"),
            ("φ", "phi", "phi"), ("χ", "chi", "chi"), ("ψ", "psi", "psi"), ("ω", "omega", "omega"),
            ("Α", "Alpha", "Alpha"), ("Β", "Beta", "Beta"), ("Γ", "Gamma", "Gamma"), ("Δ", "Delta", "Delta"),
            ("Ε", "Epsilon", "Epsilon"), ("Ζ", "Zeta", "Zeta"), ("Η", "Eta", "Eta"), ("Θ", "Theta", "Theta"),
            ("Ι", "Iota", "Iota"), ("Κ", "Kappa", "Kappa"), ("Λ", "Lambda", "Lambda"), ("Μ", "Mu", "Mu"),
            ("Ν", "Nu", "Nu"), ("Ξ", "Xi", "Xi"), ("Ο", "Omicron", "Omicron"), ("Π", "Pi", "Pi"),
            ("Ρ", "Rho", "Rho"), ("Σ", "Sigma", "Sigma"), ("Τ", "Tau", "Tau"), ("Υ", "Upsilon", "Upsilon"),
            ("Φ", "Phi", "Phi"), ("Χ", "Chi", "Chi"), ("Ψ", "Psi", "Psi"), ("Ω", "Omega", "Omega")
        ]),
        SymbolCategory(name: "Operators", symbols: [
            ("+", "+", "plus"), ("−", "-", "minus"), ("×", "times", "times"), ("⋅", "dot", "dot"),
            ("÷", "div", "div"), ("±", "plus.minus", "plus minus"), ("∓", "minus.plus", "minus plus"),
            ("∗", "ast", "asterisk"), ("⋆", "star", "star"), ("○", "circ", "circle"), ("∙", "bullet", "bullet"),
            ("∑", "sum", "sum"), ("∏", "product", "product"), ("∫", "integral", "integral")
        ]),
        SymbolCategory(name: "Relations", symbols: [
            ("=", "=", "equals"), ("≠", "!=", "not equal"), ("<", "<", "less"), (">", ">", "greater"),
            ("≤", "<=", "less equal"), ("≥", ">=", "greater equal"), ("≈", "approx", "approx"), ("≡", "equiv", "equivalent"),
            ("∝", "prop", "proportional"), ("∈", "in", "in"), ("∉", "in.not", "not in"),
            ("⊂", "subset", "subset"), ("⊃", "supset", "supset"), ("⊆", "subset.eq", "subset equal"), ("⊇", "supset.eq", "supset equal")
        ]),
        SymbolCategory(name: "Arrows", symbols: [
            ("→", "arrow.r", "right arrow"), ("←", "arrow.l", "left arrow"), ("↔", "arrow.l.r", "left right arrow"),
            ("⇒", "arrow.r.double", "double right arrow"), ("⇐", "arrow.l.double", "double left arrow"), ("⇔", "arrow.l.r.double", "double left right arrow"),
            ("↑", "arrow.t", "up arrow"), ("↓", "arrow.b", "down arrow")
        ]),
        SymbolCategory(name: "Sets", symbols: [
            ("∅", "emptyset", "empty set"), ("∞", "infinity", "infinity"), ("∀", "forall", "for all"), ("∃", "exists", "exists"),
            ("∄", "exists.not", "not exists"), ("∪", "union", "union"), ("∩", "sect", "intersection"),
            ("ℕ", "NN", "naturals"), ("ℤ", "ZZ", "integers"), ("ℚ", "QQ", "rationals"), ("ℝ", "RR", "reals"), ("ℂ", "CC", "complex")
        ]),
        SymbolCategory(name: "Gaps", symbols: [
           ("...", "dots.h", "horizontal dots"), ("⋮", "dots.v", "vertical dots"),
           ("⋱", "dots.down", "diagonal dots down"), ("⋰", "dots.up", "diagonal dots up")
        ])
    ]
    
    private var filteredSymbols: [(display: String, code: String, name: String)] {
        let allSymbols = categories.flatMap { $0.symbols }
        if searchText.isEmpty {
            if let category = categories.first(where: { $0.name == selectedCategory }) {
                return category.symbols
            }
            return []
        } else {
            return allSymbols.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.code.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    let columns = [
        GridItem(.adaptive(minimum: 50, maximum: 60))
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Insert Symbol")
                    .font(.headline)
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
                TextField("Search symbol...", text: $searchText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
            
            HStack(alignment: .top, spacing: 0) {
                // Sidebar Categories
                if searchText.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(categories) { category in
                                Button(action: { selectedCategory = category.name }) {
                                    Text(category.name)
                                        .font(.system(size: 13))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(selectedCategory == category.name ? Color.accentColor : Color.clear)
                                        .foregroundColor(selectedCategory == category.name ? .white : .primary)
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                    .frame(width: 100)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    
                    Divider()
                }
                
                // Symbol Grid
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(filteredSymbols, id: \.code) { symbol in
                            Button(action: {
                                controller.insertSymbol(code: symbol.code, unicode: symbol.display)
                                // Optional: Keep open or close? Usually keep open for multiple insertions.
                                // If needed to close: presentationMode.wrappedValue.dismiss()
                            }) {
                                VStack(spacing: 4) {
                                    Text(symbol.display)
                                        .font(.system(size: 24))
                                    Text(symbol.code)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .frame(width: 50, height: 50)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help(symbol.name)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 600, height: 400)
    }
}
