import SwiftUI

struct TableEditorView: View {
    var onInsert: (Int, Int) -> Void
    var onCancel: () -> Void
    
    var initialRows: Int = 0
    var initialCols: Int = 0
    
    @State private var hoveredRows: Int = 0
    @State private var hoveredCols: Int = 0
    @State private var hasInitialized = false
    
    private let maxRows = 10
    private let maxCols = 10
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Insert Table")
                    .font(.headline)
                
                Spacer()
                
                Button("Insert") {
                    if hoveredRows > 0 && hoveredCols > 0 {
                        onInsert(hoveredRows, hoveredCols)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(hoveredRows == 0 || hoveredCols == 0)
            }
            .padding(.bottom, 10)
            
            VStack(alignment: .center, spacing: 4) {
                Text("\(max(1, hoveredRows)) x \(max(1, hoveredCols)) Table")
                    .font(.system(.title3, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .padding(.bottom, 5)
                
                if initialRows > 0 && initialCols > 0 {
                    if hoveredRows < initialRows || hoveredCols < initialCols {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Warning: Data will be trimmed")
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.bottom, 5)
                    } else {
                        Text("Modifying existing table")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.bottom, 5)
                    }
                }
                
                // Grid
                VStack(spacing: 4) {
                    ForEach(1...maxRows, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(1...maxCols, id: \.self) { col in
                                TableGridSquare(
                                    isHighlighted: row <= hoveredRows && col <= hoveredCols,
                                    onHover: { isHovering in
                                        if isHovering {
                                            hoveredRows = row
                                            hoveredCols = col
                                        }
                                    },
                                    onClick: {
                                        onInsert(row, col)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.2))
                .cornerRadius(12)
            }
            .onAppear {
                if !hasInitialized {
                    if initialRows > 0 && initialCols > 0 {
                        hoveredRows = initialRows
                        hoveredCols = initialCols
                    }
                    hasInitialized = true
                }
            }
            
            Text("Select table size by hovering over the grid")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(30)
        .frame(width: 400)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).ignoresSafeArea())
    }
}

struct TableGridSquare: View {
    var isHighlighted: Bool
    var onHover: (Bool) -> Void
    var onClick: () -> Void
    
    var body: some View {
        Rectangle()
            .fill(isHighlighted ? Color.accentColor : Color.gray.opacity(0.3))
            .frame(width: 24, height: 24)
            .cornerRadius(4)
            .onHover { hovering in
                onHover(hovering)
            }
            .onTapGesture {
                onClick()
            }
            .animation(.easeInOut(duration: 0.1), value: isHighlighted)
    }
}
