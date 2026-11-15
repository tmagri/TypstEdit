import SwiftUI
import AppKit

/// "Find in Project": full-project search and replace, in the Files panel
/// of the sidebar.
///
/// Sits under the project header: a search field, a collapsible replace
/// field, and results grouped by file. Clicking a match opens the file at
/// the match's line; the checkboxes choose which matches a Replace All
/// touches. Files with unsaved editor edits are never searched or rewritten
/// (the model skips them and the header says so) — replacing under an
/// editor would be silently undone by its next save.
struct ProjectFindReplaceView: View {
    @ObservedObject var model: ProjectFindReplaceModel
    let projectRoot: URL?
    /// Opens the file and reveals the line, in the window this sidebar
    /// belongs to.
    let openFile: (URL, Int) -> Void
    /// Re-scan the project after a replace. Passed in so the parent owns
    /// the model's lifecycle details.
    let onReplaced: () -> Void

    @EnvironmentObject var themeManager: ThemeManager
    @State private var query: String = ""
    @State private var replacement: String = ""
    @State private var showReplace = false
    @State private var caseSensitive = false
    @State private var wholeWord = false
    @State private var useRegex = false
    @State private var ignoreDiacritics = true
    @State private var includeGlob: String = ""
    @State private var showOptions = false
    @State private var expandedFiles: Set<Int> = []
    @State private var confirmReplace = false
    @State private var replaceResult: String?
    @FocusState private var queryFocused: Bool

    private var options: ProjectFindReplaceModel.Options {
        ProjectFindReplaceModel.Options(
            caseSensitive: caseSensitive,
            wholeWord: wholeWord,
            regex: useRegex,
            ignoreDiacritics: ignoreDiacritics,
            includeGlob: includeGlob.isEmpty ? nil : includeGlob
        )
    }

    private var headerSummary: String {
        if model.isSearching { return "Searching…" }
        if let error = model.patternError { return error }
        return model.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.results.isEmpty {
                resultList
            }
        }
        .background(themeManager.sidebarBackground)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.secondaryTextColor)

                TextField("Find in project", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($queryFocused)
                    .onSubmit { runSearch() }
                    .onChange(of: query) { _ in runSearch() }

                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }

                toggleButton("Aa", active: caseSensitive) {
                    caseSensitive.toggle()
                    runSearch()
                }
                .help("Match case")

                toggleButton("ab", active: wholeWord) {
                    wholeWord.toggle()
                    runSearch()
                }
                .help("Whole word")
                .font(.system(size: 10, design: .rounded))

                toggleButton(".*", active: useRegex) {
                    useRegex.toggle()
                    runSearch()
                }
                .help("Regular expression")
                .font(.system(size: 10, design: .monospaced))

                Button(action: { showOptions.toggle() }) {
                    Image(systemName: showOptions ? "slider.horizontal.3" : "line.3.horizontal")
                        .font(.system(size: 11))
                        .foregroundColor(showOptions ? themeManager.accentColor : themeManager.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help("More options")
            }

            if showOptions {
                HStack(spacing: 4) {
                    toggleButton("á", active: ignoreDiacritics) {
                        ignoreDiacritics.toggle()
                        runSearch()
                    }
                    .help("Ignore diacritics (é == e)")
                    .font(.system(size: 11))

                    TextField("Filter, e.g. *.typ", text: $includeGlob)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .onSubmit { runSearch() }
                        .onChange(of: includeGlob) { _ in runSearch() }
                }
                .padding(.leading, 16)
            }

            // Replace row
            HStack(spacing: 4) {
                Image(systemName: showReplace ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(themeManager.secondaryTextColor)
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { showReplace.toggle() }

                if showReplace {
                    TextField("Replace with", text: $replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { confirmReplace = true }

                    Button("Replace") {
                        confirmReplace = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.accentColor)
                    .disabled(model.selectedMatchCount == 0 || model.isReplacing)

                    Button("All") {
                        model.selectAll(true)
                        confirmReplace = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(themeManager.secondaryTextColor)
                    .disabled(model.results.isEmpty || model.isReplacing)
                    .help("Select every match, then replace")

                    if model.isReplacing {
                        ProgressView()
                            .controlSize(.mini)
                    }
                } else {
                    Button("Replace") { showReplace = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.secondaryTextColor)
                }
            }

            if !model.results.isEmpty || model.isSearching {
                Text(headerSummary)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.secondaryTextColor)
                    .lineLimit(1)
            }
            if let replaceResult {
                Text(replaceResult)
                    .font(.system(size: 10))
                    .foregroundColor(themeManager.secondaryTextColor)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            if let first = model.results.first {
                expandedFiles.insert(first.id)
            }
        }
        .confirmationDialog(
            "Replace \(model.selectedMatchCount) match\(model.selectedMatchCount == 1 ? "" : "es")?",
            isPresented: $confirmReplace,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { Task { await performReplace() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files are rewritten on disk. Files with unsaved editor changes are skipped.")
        }
    }

    private func toggleButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .frame(minWidth: 18)
                .padding(.horizontal, 2)
                .background(active ? themeManager.accentColor.opacity(0.25) : Color.clear)
                .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .foregroundColor(active ? themeManager.accentColor : themeManager.secondaryTextColor)
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.results) { file in
                    fileRow(file)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .id(model.searchGeneration)
    }

    private func fileRow(_ file: ProjectFindReplaceModel.FileResult) -> some View {
        let isExpanded = expandedFiles.contains(file.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: { toggleExpand(file.id) }) {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(themeManager.secondaryTextColor)
                        Image(systemName: "doc.text")
                            .font(.system(size: 11))
                            .foregroundColor(themeManager.accentColor)
                        Text(file.relativePath)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(themeManager.textColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(file.matches.count)")
                            .font(.system(size: 10))
                            .foregroundColor(themeManager.secondaryTextColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if showReplace {
                    // Per-file select/deselect, a tri-state checkbox.
                    Button(action: {
                        model.setSelectedForFile(!file.allSelected, fileID: file.id)
                    }) {
                        Image(systemName: file.allSelected ? "checkmark.square.fill"
                              : (file.noneSelected ? "square" : "minus.square"))
                            .font(.system(size: 11))
                            .foregroundColor(file.allSelected ? themeManager.accentColor : themeManager.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .help(file.allSelected ? "Exclude this file's matches from replace"
                          : "Include this file's matches in replace")
                }
            }
            .padding(.vertical, 3)

            if isExpanded {
                ForEach(file.matches) { match in
                    matchRow(match, in: file)
                }
            }
        }
    }

    private func matchRow(_ match: ProjectFindReplaceModel.Match, in file: ProjectFindReplaceModel.FileResult) -> some View {
        HStack(alignment: .top, spacing: 4) {
            if showReplace {
                Button(action: {
                    model.setSelected(!match.selectedForReplace, matchID: match.id)
                }) {
                    Image(systemName: match.selectedForReplace ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11))
                        .foregroundColor(match.selectedForReplace ? themeManager.accentColor : themeManager.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }

            Button(action: {
                openFile(match.url, match.line)
            }) {
                HStack(alignment: .top, spacing: 6) {
                    Text("\(match.line)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(themeManager.secondaryTextColor)
                        .frame(minWidth: 28, alignment: .trailing)
                        .padding(.top, 1)

                    matchText(match)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(themeManager.textColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 1)

                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .help("Open \(file.relativePath):\(match.line)")
        }
        .padding(.leading, 18)
        .padding(.vertical, 1)
    }

    /// The match's line with the matched range highlighted.
    @ViewBuilder
    private func matchText(_ match: ProjectFindReplaceModel.Match) -> some View {
        // Text(left) + highlighted + Text(right), preserving the matched
        // range even when the ends of the line are long.
        if let swiftRange = Range(match.rangeInLine, in: match.lineText) {
            (Text(String(match.lineText[match.lineText.startIndex..<swiftRange.lowerBound]))
             + Text(match.matchedText)
                .foregroundColor(themeManager.accentColor)
                .underline()
             + Text(String(match.lineText[swiftRange.upperBound...])))
        } else {
            Text(match.lineText)
        }
    }

    // MARK: - Actions

    private func toggleExpand(_ id: Int) {
        if expandedFiles.contains(id) {
            expandedFiles.remove(id)
        } else {
            expandedFiles.insert(id)
        }
    }

    private func runSearch() {
        model.search(query: query, options: options, root: projectRoot)
    }

    private func performReplace() async {
        let outcome = await model.replace(with: replacement, root: projectRoot)
        replaceResult = outcome.message
        model.refresh(root: projectRoot)
        onReplaced()
    }
}
