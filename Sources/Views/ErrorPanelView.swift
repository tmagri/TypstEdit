import SwiftUI
import AppKit

struct ErrorPanelView: View {
    @ObservedObject var compiler: TypstCompiler
    @ObservedObject var editorController: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isExpanded: Bool = true
    @State private var showAllErrors: Bool = false

    /// Problems that stop the compiler itself (typst missing, watch crashed…).
    /// These never arrive as diagnostics, so without this row the panel would
    /// read "No issues" while nothing compiles.
    private var compilerProblem: String? {
        let status = compiler.compilationStatus
        guard compiler.errors.isEmpty,
              status.hasPrefix("Error") || status.hasPrefix("Failed") else { return nil }
        return status
    }

    private var documentName: String? { editorController.currentFileURL?.lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(themeManager.secondaryTextColor)
                    .onTapGesture {
                        withAnimation {
                            isExpanded.toggle()
                        }
                    }
                
                Text(compiler.errors.contains(where: { $0.severity == .error }) ? "Errors" : "Issues")
                    .font(.headline)
                    .foregroundColor(themeManager.textColor)
                    .onTapGesture {
                        withAnimation {
                            isExpanded.toggle()
                        }
                    }
                
                Spacer()
                
                if !compiler.errors.isEmpty {
                    // Separate badges for errors (red) and advisory warnings (yellow).
                    let errorCount = compiler.errors.filter { $0.severity == .error }.count
                    let warningCount = compiler.errors.filter { $0.severity == .warning }.count
                    if errorCount > 0 {
                        Text("\(errorCount)")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.red)
                            .cornerRadius(10)
                    }
                    if warningCount > 0 {
                        Text("\(warningCount)")
                            .font(.caption)
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.yellow)
                            .cornerRadius(10)
                    }

                    Button(action: copyAll) {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(themeManager.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .help("Copy all issues as text")
                    
                    // Pop-out button
                    Button(action: {
                        showAllErrors = true
                    }) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                            .foregroundColor(themeManager.secondaryTextColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                    .help("Show all issues with full details in a separate window")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(themeManager.sidebarOverlay.opacity(0.5))
            
            // Error List (Inline - limit to first few)
            if isExpanded {
                if let problem = compilerProblem {
                    CompilerProblemRow(message: problem)
                        .environmentObject(themeManager)
                        .padding(8)
                } else if compiler.errors.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No issues")
                            .foregroundColor(themeManager.secondaryTextColor)
                            .font(.caption)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(compiler.errors.prefix(5))) { error in
                                ErrorRowView(
                                    error: error,
                                    editorController: editorController,
                                    documentName: documentName
                                )
                                .environmentObject(themeManager)
                            }
                            
                            if compiler.errors.count > 5 {
                                Button(action: { showAllErrors = true }) {
                                    Text("Show \(compiler.errors.count - 5) more...")
                                        .font(.caption)
                                        .foregroundColor(themeManager.accentColor)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 280)
                }
            }
        }
        .sheet(isPresented: $showAllErrors) {
            VStack(spacing: 0) {
                HStack {
                    Text("Compilation Issues (\(compiler.errors.count))")
                        .font(.headline)
                        .foregroundColor(themeManager.textColor)
                    Spacer()
                    Button("Copy All", action: copyAll)
                        .disabled(compiler.errors.isEmpty)
                    Button("Close") {
                        showAllErrors = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding()
                .background(themeManager.sidebarBackground)
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(compiler.errors) { error in
                            ErrorRowView(
                                error: error,
                                editorController: editorController,
                                documentName: documentName,
                                startExpanded: true,
                                onNavigate: { showAllErrors = false }
                            )
                            .environmentObject(themeManager)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .frame(minWidth: 520, idealWidth: 680, minHeight: 360, idealHeight: 540)
            .background(themeManager.sidebarBackground)
        }
    }

    private func copyAll() {
        let text = compiler.errors
            .map { $0.reportText(documentName: documentName) }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A compiler-level failure that is not tied to the document (no diagnostics).
private struct CompilerProblemRow: View {
    let message: String
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.red)
                .font(.caption)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Compiler")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(themeManager.accentColor)
                Text(message)
                    .font(.caption)
                    .foregroundColor(themeManager.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(8)
    }
}

struct ErrorRowView: View {
    let error: TypstError
    @ObservedObject var editorController: EditorController
    var documentName: String? = nil
    var startExpanded: Bool = false
    /// Called after the row moved the editor (e.g. to close a sheet).
    var onNavigate: (() -> Void)? = nil

    @EnvironmentObject var themeManager: ThemeManager
    @State private var isHovered: Bool = false
    @State private var showDetails: Bool = false
    @State private var copied: Bool = false

    private var isWarning: Bool { error.severity == .warning }
    private var explanation: String? { TypstErrorExplainer.explanation(for: error) }
    private var fixes: [TypstFix] { editorController.quickFixes(for: error) }
    private var canNavigate: Bool { error.line != nil }
    private var aiEnabled: Bool { AISettingsManager.shared.assistantEnabled }

    private var hasDetails: Bool {
        error.snippet != nil || !error.hints.isEmpty || !error.trace.isEmpty
            || explanation != nil || !fixes.isEmpty || aiEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summary
            if showDetails {
                details
                    .padding(.leading, 20)
            }
        }
        .padding(8)
        .background(isHovered ? themeManager.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
        .onAppear { showDetails = startExpanded }
    }

    // MARK: - Summary (icon, location, message)

    private var summary: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isWarning ? "exclamationmark.bubble.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(isWarning ? .yellow : .red)
                .font(.caption)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(isWarning ? "Warning" : "Error")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(isWarning ? .yellow : .red)
                    Text(error.locationLabel)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(canNavigate ? themeManager.accentColor : themeManager.secondaryTextColor)
                }

                Text(error.message)
                    .font(.caption)
                    .foregroundColor(themeManager.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: navigate)
            .help(canNavigate ? "Go to this location" : "This issue has no location in the open document")

            Spacer(minLength: 4)

            Button(action: copy) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
                    .foregroundColor(themeManager.secondaryTextColor)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0)
            .help("Copy this issue as text")

            if hasDetails {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() } }) {
                    Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(themeManager.secondaryTextColor)
                }
                .buttonStyle(.plain)
                .help(showDetails ? "Hide details" : "Show code, hints and fixes")
            }
        }
    }

    // MARK: - Details

    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snippet = error.snippet {
                SnippetView(code: snippet, column: error.column, length: error.length, isWarning: isWarning)
                    .environmentObject(themeManager)
            }

            ForEach(Array(error.hints.enumerated()), id: \.offset) { _, hint in
                labeled("Hint", systemImage: "lightbulb", text: hint)
            }

            if let explanation {
                labeled("How to fix", systemImage: "wrench.and.screwdriver", text: explanation)
            }

            ForEach(Array(error.trace.enumerated()), id: \.offset) { _, frame in
                traceRow(frame)
            }

            if !fixes.isEmpty || aiEnabled {
                actions
            }
        }
    }

    private func labeled(_ title: String, systemImage: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundColor(themeManager.secondaryTextColor)
                .frame(width: 12)
                .padding(.top, 1)
            (Text("\(title): ").fontWeight(.semibold) + Text(markdown(text)))
                .font(.caption)
                .foregroundColor(themeManager.textColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    /// Renders backtick code spans in hints/explanations; falls back to plain text.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    @ViewBuilder
    private func traceRow(_ frame: TypstError.TraceEntry) -> some View {
        let location: String = {
            if let file = frame.file { return frame.fileLine.map { "\(file):\($0)" } ?? file }
            if let line = frame.line { return "line \(line)" }
            return ""
        }()
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundColor(themeManager.secondaryTextColor)
                .frame(width: 12)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(markdown(frame.message.prefix(1).uppercased() + frame.message.dropFirst()))
                    .font(.caption)
                    .foregroundColor(themeManager.textColor)
                    .fixedSize(horizontal: false, vertical: true)
                if !location.isEmpty {
                    if let line = frame.line {
                        Button("Go to \(location)") {
                            editorController.goToLine(line)
                            onNavigate?()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    } else {
                        Text(location)
                            .font(.caption)
                            .foregroundColor(themeManager.secondaryTextColor)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            ForEach(fixes) { fix in
                Button(fix.title) {
                    editorController.applyQuickFix(fix)
                }
                .controlSize(.small)
                .help("Apply this change to line \(error.line ?? 0)")
            }
            if aiEnabled {
                Button("✨ Fix with AI") {
                    editorController.requestAIFix(for: error)
                    onNavigate?()
                }
                .controlSize(.small)
                .help("Open the AI prompt with this error and its code")
            }
        }
    }

    // MARK: - Actions

    private func navigate() {
        guard canNavigate else { return }
        editorController.goToError(error)
        onNavigate?()
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(error.reportText(documentName: documentName), forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// The source line the compiler reported, with a caret under the exact span.
/// Long lines are trimmed around the caret so it stays visible in the sidebar.
private struct SnippetView: View {
    let code: String
    let column: Int?
    let length: Int?
    let isWarning: Bool
    @EnvironmentObject var themeManager: ThemeManager

    private static let contextBefore = 32
    private static let maxWidth = 96

    private var display: (code: String, caret: String?) {
        let chars = Array(code.replacingOccurrences(of: "\t", with: " "))
        guard let column else {
            let text = chars.count > Self.maxWidth ? String(chars.prefix(Self.maxWidth)) + "…" : String(chars)
            return (text, nil)
        }
        var start = 0
        var prefix = ""
        if column > Self.contextBefore {
            start = column - Self.contextBefore
            prefix = "…"
        }
        let end = min(chars.count, start + Self.maxWidth)
        let suffix = end < chars.count ? "…" : ""
        let visible = start < end ? String(chars[start..<end]) : ""
        let caretOffset = prefix.count + (column - start)
        let caret = String(repeating: " ", count: max(0, caretOffset))
            + String(repeating: "^", count: max(1, length ?? 1))
        return (prefix + visible + suffix, caret)
    }

    var body: some View {
        let d = display
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text(d.code)
                    .foregroundColor(themeManager.textColor)
                if let caret = d.caret {
                    Text(caret)
                        .foregroundColor(isWarning ? .yellow : .red)
                        .fontWeight(.bold)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(6)
        }
        .background(Color.primary.opacity(0.06))
        .cornerRadius(4)
    }
}
