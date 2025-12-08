import SwiftUI

struct ErrorPanelView: View {
    @ObservedObject var compiler: TypstCompiler
    @ObservedObject var editorController: EditorController
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isExpanded: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundColor(themeManager.secondaryTextColor)
                
                Text("Errors")
                    .font(.headline)
                    .foregroundColor(themeManager.textColor)
                
                Spacer()
                
                if !compiler.errors.isEmpty {
                    Text("\(compiler.errors.count)")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red)
                        .cornerRadius(10)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(themeManager.sidebarOverlay.opacity(0.5))
            .onTapGesture {
                withAnimation {
                    isExpanded.toggle()
                }
            }
            
            // Error List
            if isExpanded {
                if compiler.errors.isEmpty {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No errors")
                            .foregroundColor(themeManager.secondaryTextColor)
                            .font(.caption)
                    }
                    .padding()
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(compiler.errors) { error in
                                ErrorRowView(error: error, onClick: {
                                    editorController.goToLine(error.line)
                                })
                                .environmentObject(themeManager)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }
}

struct ErrorRowView: View {
    let error: TypstError
    let onClick: () -> Void
    @EnvironmentObject var themeManager: ThemeManager
    @State private var isHovered: Bool = false
    
    var body: some View {
        Button(action: onClick) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Line \(error.line)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(themeManager.accentColor)
                    
                    Text(error.message)
                        .font(.caption)
                        .foregroundColor(themeManager.textColor)
                        .lineLimit(3)
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
