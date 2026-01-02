import SwiftUI

struct TableEditorView: View {
    @ObservedObject var controller: EditorController
    var onInsert: (Int, Int) -> Void
    var onCancel: () -> Void
    
    @State private var hoveredRows: Int = 0
    @State private var hoveredCols: Int = 0
    @State private var selectedRows: Int = 0
    @State private var selectedCols: Int = 0
    @State private var isPicking: Bool = false
    @State private var hasInitialized = false
    
    private let maxRows = 10
    private let maxCols = 10
    
    private let alignOptions = [
        "", "left", "center", "right",
        "top", "horizon", "bottom",
        "center + horizon", "left + horizon", "right + horizon",
        "center + top", "center + bottom"
    ]
    
    private var effectiveCols: Int {
        // First check the explicit columns string
        let colsString = controller.tableColumnsString.trimmingCharacters(in: .whitespaces)
        if !colsString.isEmpty {
            if let count = Int(colsString) {
                return count
            }
            // It might be a list like (1fr, auto)
            if colsString.hasPrefix("(") && colsString.hasSuffix(")") {
                let inner = colsString.dropFirst().dropLast()
                // Simple comma split
                return inner.split(separator: ",").count
            }
        }
        
        // Fallback to grid selection
        let displayCols = isPicking ? (hoveredCols > 0 ? hoveredCols : selectedCols) : selectedCols
        return max(1, displayCols)
    }
    
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
                    let rows = selectedRows > 0 ? selectedRows : 2
                    let cols = selectedCols > 0 ? selectedCols : 2
                    onInsert(rows, cols)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedRows == 0 && !hasInitialized)
            }
            .padding(.bottom, 10)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    // Size Selection
                    VStack(alignment: .center, spacing: 4) {
                        let displayRows = isPicking ? (hoveredRows > 0 ? hoveredRows : selectedRows) : selectedRows
                        let displayCols = isPicking ? (hoveredCols > 0 ? hoveredCols : selectedCols) : selectedCols
                        
                        HStack(spacing: 8) {
                            Text("\(max(1, displayRows)) x \(max(1, displayCols)) Table")
                                .font(.system(.title3, design: .monospaced))
                                .foregroundColor(.accentColor)
                            
                            if isPicking {
                                Text("(Picking...)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .transition(.opacity)
                            } else {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.bottom, 5)
                        
                        if controller.tableEditInitialRows > 0 && controller.tableEditInitialCols > 0 {
                            let displayRows = isPicking ? (hoveredRows > 0 ? hoveredRows : selectedRows) : selectedRows
                            let displayCols = isPicking ? (hoveredCols > 0 ? hoveredCols : selectedCols) : selectedCols
                            
                            if displayRows < controller.tableEditInitialRows || displayCols < controller.tableEditInitialCols {
                                HStack(spacing: 4) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                    Text("Warning: Data will be trimmed")
                                }
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.bottom, 5)
                            }
                        }
                        
                        // Grid
                        VStack(spacing: 4) {
                            ForEach(1...maxRows, id: \.self) { row in
                                HStack(spacing: 4) {
                                    ForEach(1...maxCols, id: \.self) { col in
                                        TableGridSquare(
                                            isHighlighted: {
                                                let displayRows = isPicking ? (hoveredRows > 0 ? hoveredRows : selectedRows) : selectedRows
                                                let displayCols = isPicking ? (hoveredCols > 0 ? hoveredCols : selectedCols) : selectedCols
                                                return row <= displayRows && col <= displayCols
                                            }(),
                                            onHover: { isHovering in
                                                if isPicking && isHovering {
                                                    hoveredRows = row
                                                    hoveredCols = col
                                                }
                                            },
                                            onClick: {
                                                if isPicking {
                                                    selectedRows = row
                                                    selectedCols = col
                                                    isPicking = false
                                                } else {
                                                    isPicking = true
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.2))
                        .cornerRadius(12)
                        .onHover { hovering in
                            if !hovering {
                                hoveredRows = 0
                                hoveredCols = 0
                            }
                        }
                        .onTapGesture {
                            // If user clicks outside a specific square but inside the grid box
                            isPicking.toggle()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    
                    Divider()
                    
                    // Advanced Settings
                    Group {
                        Text("Properties")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 5)
                        
                        VStack(spacing: 12) {
                            HStack {
                                Text("Columns:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. (1fr, auto) or 3", text: $controller.tableColumnsString)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Inset:")
                                    .frame(width: 80, alignment: .leading)
                                TextField("e.g. 10pt", text: $controller.tableInset)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            HStack {
                                Text("Align:")
                                    .frame(width: 80, alignment: .leading)
                                Picker("", selection: $controller.tableAlign) {
                                    ForEach(alignOptions, id: \.self) { option in
                                        Text(option.isEmpty ? "Default (None)" : option).tag(option)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                            }
                        }
                        
                        Divider()
                        
                        // Header Settings
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Include Header", isOn: $controller.useTableHeader)
                                .toggleStyle(.checkbox)
                            
                            if controller.useTableHeader {
                                let count = effectiveCols
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(0..<count, id: \.self) { index in
                                        HStack {
                                            Text("Cell \(index + 1):")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .frame(width: 50, alignment: .leading)
                                            
                                            TextField("Header content...", text: Binding(
                                                get: {
                                                    if index < controller.tableHeaderCells.count {
                                                        return controller.tableHeaderCells[index]
                                                    }
                                                    return ""
                                                },
                                                set: { newValue in
                                                    // Ensure array is large enough
                                                    while controller.tableHeaderCells.count <= index {
                                                        controller.tableHeaderCells.append("")
                                                    }
                                                    controller.tableHeaderCells[index] = newValue
                                                }
                                            ))
                                            .textFieldStyle(.roundedBorder)
                                        }
                                    }
                                }
                                .padding(.leading, 20)
                                .onAppear {
                                    // Pre-populate if empty
                                    if controller.tableHeaderCells.isEmpty {
                                        controller.tableHeaderCells = Array(repeating: "", count: count)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 400)
            
            Text("Left-click grid to Pick, Left-click again to Keep")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(25)
        .frame(width: 450)
        .background(VisualEffectView(material: .hudWindow, blendingMode: .withinWindow).ignoresSafeArea())
        .onAppear {
            if !hasInitialized {
                if controller.tableEditInitialRows > 0 && controller.tableEditInitialCols > 0 {
                    selectedRows = controller.tableEditInitialRows
                    selectedCols = controller.tableEditInitialCols
                } else {
                    selectedRows = 2
                    selectedCols = 2
                }
                hasInitialized = true
            }
        }
        .onDisappear {
            // Let state be managed by parent/controller
        }
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
