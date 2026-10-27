import SwiftUI

/// Sheet listing the calculator's TI-89 style function catalogue: search
/// over title/syntax/description, a category picker, a list with
/// compatibility labels, and a detail pane with an "Insert Example" button
/// that hands the example to the entry line and closes the sheet.
///
/// Presented from the Calculator panel (see `CalculatorView`); the theme
/// comes from the surrounding environment, like the rest of the panel.
struct CalculatorFunctionCatalogView: View {
    /// Called with the selected entry. The Calculator panel decides what to do
    /// with it: entry-line examples load into the home screen; "In documents"
    /// entries insert into the open Typst file instead (they are Typst code,
    /// not calculator input).
    let onInsert: (CalculatorFunctionGuide) -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var category: CalculatorFunctionCategory?
    @State private var selectedID: String?

    private var results: [CalculatorFunctionGuide] {
        CalculatorFunctionCatalog.search(query: query, category: category)
    }

    private var selected: CalculatorFunctionGuide? {
        results.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            HStack(spacing: 0) {
                resultList
                Divider()
                detailPane
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(themeManager.mainBackground)
    }

    // MARK: - Header / controls

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "book")
                .foregroundColor(.accentColor)
            Text("FUNCTION CATALOGUE")
                .font(.system(size: 11, weight: .bold))
                .tracking(1)
                .foregroundColor(themeManager.textColor.opacity(0.6))
            Spacer()
            Button("Done") {
                dismiss()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(themeManager.textColor.opacity(0.5))
                TextField("Search title, syntax, or description", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(themeManager.textColor.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Clear the search")
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .cornerRadius(6)

            Picker("Category", selection: $category) {
                Text("All").tag(CalculatorFunctionCategory?.none)
                ForEach(CalculatorFunctionCategory.allCases) { item in
                    Text(item.displayName).tag(CalculatorFunctionCategory?.some(item))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            Text("\(results.count) of \(CalculatorFunctionCatalog.entries.count)")
                .font(.caption)
                .foregroundColor(themeManager.textColor.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - List

    private var resultList: some View {
        List(selection: $selectedID) {
            ForEach(results) { guide in
                row(for: guide)
                    .tag(guide.id)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 290)
        .overlay {
            if results.isEmpty {
                Text("No function matches “\(query)”.")
                    .font(.callout)
                    .foregroundColor(themeManager.textColor.opacity(0.5))
            }
        }
    }

    private func row(for guide: CalculatorFunctionGuide) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(guide.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(themeManager.textColor)
            Text(guide.syntax)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(themeManager.textColor.opacity(0.6))
                .lineLimit(1)
            CalculatorCompatibilityBadge(compatibility: guide.compatibility)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = guide.id }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let guide = selected {
            detail(for: guide)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "curlybraces.square")
                    .font(.system(size: 26))
                    .foregroundColor(themeManager.textColor.opacity(0.3))
                Text("Select a function to see its syntax and example.")
                    .font(.callout)
                    .foregroundColor(themeManager.textColor.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detail(for guide: CalculatorFunctionGuide) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(guide.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(themeManager.textColor)
                    HStack(spacing: 8) {
                        Text(guide.category.displayName)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .cornerRadius(5)
                        CalculatorCompatibilityBadge(compatibility: guide.compatibility)
                        Spacer()
                    }

                    sectionLabel("Syntax")
                    Text(guide.syntax)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(themeManager.textColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    sectionLabel("Description")
                    Text(guide.description)
                        .font(.callout)
                        .foregroundColor(themeManager.textColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)

                    if guide.compatibility == .notYetVerified {
                        Label(guide.compatibility.detail, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    sectionLabel("Example")
                    Text(guide.example)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(themeManager.textColor)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.1))
                        )

                    Text(guide.compatibility.detail)
                        .font(.caption)
                        .foregroundColor(themeManager.textColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Text(guide.category == .documents
                     ? "Insert Example places this Typst code at the cursor in the open document."
                     : "Insert Example closes this sheet and passes the example to the calculator.")
                    .font(.caption2)
                    .foregroundColor(themeManager.textColor.opacity(0.5))
                Spacer()
                Button(guide.category == .documents ? "Insert into Document" : "Insert Example") {
                    onInsert(guide)
                    dismiss()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundColor(themeManager.textColor.opacity(0.45))
    }

    // MARK: - Footer

    private var footer: some View {
        Text("The calculator runs a CAS with TI-89 style input — it is not a complete TI-89. Entries marked “Not yet verified” are known gaps; their examples error or come back unevaluated.")
            .font(.caption2)
            .foregroundColor(themeManager.textColor.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }
}

// MARK: - Compatibility badge

/// Small colored capsule showing one entry's compatibility label.
struct CalculatorCompatibilityBadge: View {
    let compatibility: CalculatorFunctionCompatibility

    private var color: Color {
        switch compatibility {
        case .verified: return .green
        case .alias: return .blue
        case .notYetVerified: return .orange
        }
    }

    var body: some View {
        Label(compatibility.label,
              systemImage: compatibility == .notYetVerified ? "exclamationmark.triangle" : "checkmark")
            .font(.system(size: 9, weight: .semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .cornerRadius(5)
    }
}
