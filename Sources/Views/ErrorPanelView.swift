import SwiftUI

struct ErrorPanelView: View {
    @ObservedObject var compiler: TypstCompiler
    @ObservedObject var editorController: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isExpanded: Bool = true
    @State private var showAllErrors: Bool = false
    
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
                
                Text("Errors")
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
                    .help("Show all errors in a separate window")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(themeManager.sidebarOverlay.opacity(0.5))
            
            // Error List (Inline - limit to first few)
            if isExpanded {
                if compiler.errors.isEmpty {
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
                                ErrorRowView(error: error, onClick: {
                                    editorController.goToLine(error.line)
                                })
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
                    .frame(maxHeight: 200)
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
                    Button("Close") {
                        showAllErrors = false
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                }
                .padding()
                .background(themeManager.sidebarBackground)
                
                List {
                    ForEach(compiler.errors) { error in
                        ErrorRowView(error: error, onClick: {
                            editorController.goToLine(error.line)
                            showAllErrors = false // Auto-close on selection? Optional.
                        })
                        .environmentObject(themeManager)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
            .frame(width: 500, height: 400)
            .background(themeManager.sidebarBackground)
        }
    }
}

struct ErrorRowView: View {
    let error: TypstError
    let onClick: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isHovered: Bool = false
    
    private var isWarning: Bool { error.severity == .warning }

    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isWarning ? "exclamationmark.bubble.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(isWarning ? .yellow : .red)
                    .font(.caption)
                    .padding(.top, 2)
                
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isWarning ? "Warning" : "Line \(error.line)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(isWarning ? .yellow : themeManager.accentColor)
                        if isWarning {
                            Text("Line \(error.line)")
                                .font(.caption2)
                                .foregroundColor(themeManager.secondaryTextColor)
                        }
                    }
                    
                    Text(error.message)
                        .font(.caption)
                        .foregroundColor(themeManager.textColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
            }
            .padding(8)
            .background(isHovered ? themeManager.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .buttonStyle(.plain)
    }
}
