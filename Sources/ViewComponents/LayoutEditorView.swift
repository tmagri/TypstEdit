import SwiftUI
import AppKit

struct LayoutEditorView: View {
    @ObservedObject var controller: EditorController
    @Binding var isPresented: Bool
    
    // Tab State
    @State private var selectedTab: String = "page" // page, text
    
    // --- Page Settings State ---
    @State private var paperSize: String = "a4"
    @State private var customWidth: String = "21cm"
    @State private var customHeight: String = "29.7cm"
    @State private var orientation: String = "portrait"
    @State private var marginType: String = "auto"
    @State private var marginTop: String = "2.5cm"
    @State private var marginBottom: String = "2.5cm"
    @State private var marginLeft: String = "2.5cm"
    @State private var marginRight: String = "2.5cm"
    @State private var columns: Int = 1
    @State private var pageNumbering: String = ""
    @State private var pageFill: String = ""
    @State private var applyTo: String = "document" // document, next_page
    @State private var pageValidationError: String? = nil
    
    // --- Text Settings State ---
    @State private var textFont: String = "Default"
    @State private var textSize: String = "11pt"
    @State private var textWeight: String = "regular"
    @State private var textStyle: String = "normal"
    @State private var textColor: String = ""
    @State private var textLang: String = "en"
    @State private var textRegion: String = ""
    
    // Data Sources
    let paperSizes = ["a4", "us-letter", "us-legal", "a3", "a5", "iso-b5"]
    @State private var availableFonts: [String] = []
    let weights = ["thin", "extralight", "light", "regular", "medium", "semibold", "bold", "extrabold", "black"]
    let styles = ["normal", "italic", "oblique"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Layout & Style")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            // Tab Picker
            Picker("", selection: $selectedTab) {
                Text("Page Layout").tag("page")
                Text("Text Style").tag("text")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 10)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedTab == "page" {
                        pageSettingsView
                    } else {
                        textSettingsView
                    }
                }
                .padding()
            }
            
            if let error = pageValidationError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            
            // Footer
            HStack {
                Spacer()
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Insert Code") {
                    if selectedTab == "page" {
                        insertPageLayout()
                    } else {
                        insertTextLayout()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
        }
        .frame(width: 400, height: 500)
        .onAppear {
            loadFonts()
        }
    }
    
    // MARK: - Subviews
    
    var pageSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Paper Size & Orientation
            VStack(alignment: .leading, spacing: 8) {
                Text("Paper").font(.subheadline).bold()
                HStack {
                    Picker("Size", selection: $paperSize) {
                        ForEach(paperSizes, id: \.self) { size in
                            Text(size.capitalized).tag(size)
                        }
                        Divider()
                        Text("Custom").tag("custom")
                    }
                    .frame(maxWidth: .infinity)
                    
                    if paperSize != "custom" {
                        Picker("Orientation", selection: $orientation) {
                            Text("Portrait").tag("portrait")
                            Text("Landscape").tag("landscape")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                
                if paperSize == "custom" {
                    HStack(spacing: 12) {
                        Text("Width:")
                        TextField("21cm", text: $customWidth)
                            .textFieldStyle(.roundedBorder)
                        Text("Height:")
                        TextField("29.7cm", text: $customHeight)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.top, 4)
                }
            }
            
            Divider()
            
            // Margins
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Margins").font(.subheadline).bold()
                    Spacer()
                    Picker("", selection: $marginType) {
                        Text("Auto").tag("auto")
                        Text("Custom").tag("custom")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                
                if marginType == "custom" {
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Text("Top:")
                            TextField("2.5cm", text: $marginTop)
                            Text("Bottom:")
                            TextField("2.5cm", text: $marginBottom)
                        }
                        HStack(spacing: 12) {
                            Text("Left:")
                            TextField("2.5cm", text: $marginLeft)
                            Text("Right:")
                            TextField("2.5cm", text: $marginRight)
                        }
                    }
                }
            }
            
            Divider()
            
            // Columns & Numbering
            VStack(alignment: .leading, spacing: 8) {
                Text("Content").font(.subheadline).bold()
                
                HStack {
                    Text("Columns:")
                    Spacer()
                    Stepper("\(columns)", value: $columns, in: 1...4)
                }
                
                HStack {
                    Text("Page Numbers:")
                    TextField("e.g. \"1 / 1\"", text: $pageNumbering)
                }
                
                HStack {
                    Text("Background Fill:")
                    TextField("e.g. #f0f0f0", text: $pageFill)
                }
            }
            
            Divider()
            
            // Apply To
            VStack(alignment: .leading, spacing: 8) {
                Text("Apply To").font(.subheadline).bold()
                Picker("", selection: $applyTo) {
                    Text("Document (#set)").tag("document")
                    Text("New Page (#page)").tag("next_page")
                }
                .pickerStyle(.radioGroup)
            }
        }
    }
    
    var textSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Font Settings").font(.subheadline).bold()
            
            // Font Family
            HStack {
                Text("Font Family:")
                Picker("", selection: $textFont) {
                    Text("Default").tag("Default")
                    Divider()
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
            }
            
            // Size, Weight, Style
            HStack {
                Text("Size:")
                TextField("11pt", text: $textSize)
                    .frame(width: 60)
                Spacer()
                Text("Weight:")
                Picker("", selection: $textWeight) {
                    ForEach(weights, id: \.self) { w in
                        Text(w.capitalized).tag(w)
                    }
                }
                .frame(width: 100)
            }
            
            HStack {
                Text("Style:")
                Picker("", selection: $textStyle) {
                    ForEach(styles, id: \.self) { s in
                        Text(s.capitalized).tag(s)
                    }
                }
                Spacer()
                Text("Color:")
                TextField("#000000", text: $textColor)
                    .frame(width: 80)
            }
            
            Divider()
            
            Text("Localization").font(.subheadline).bold()
            
            // Lang & Region
            HStack {
                Text("Language:")
                TextField("en", text: $textLang)
                    .frame(width: 50)
                Spacer()
                Text("Region:")
                TextField("US", text: $textRegion)
                    .frame(width: 50)
            }
        }
    }
    
    // MARK: - Logic
    
    func loadFonts() {
        // Fetch system fonts
        let manager = NSFontManager.shared
        availableFonts = manager.availableFontFamilies
    }
    
    func insertPageLayout() {
        pageValidationError = nil
        var params: [String] = []
        
        // Paper / Size
        if paperSize == "custom" {
            if !validateTypstLength(customWidth) || !validateTypstLength(customHeight) {
                pageValidationError = "Invalid custom size. Use units like cm, mm, pt, or in."
                return
            }
            params.append("width: \(customWidth)")
            params.append("height: \(customHeight)")
        } else {
            params.append("paper: \"\(paperSize)\"")
            if orientation == "landscape" { params.append("flipped: true") }
        }
        
        // Margins
        if marginType == "custom" {
            let m = [marginTop, marginBottom, marginLeft, marginRight]
            for unit in m {
                if !validateTypstLength(unit) {
                    pageValidationError = "Invalid margin unit: '\(unit)'. Use cm, mm, pt, or in."
                    return
                }
            }
            
            if marginTop == marginBottom && marginBottom == marginLeft && marginLeft == marginRight {
                params.append("margin: \(marginTop)")
            } else {
                params.append("margin: (top: \(marginTop), bottom: \(marginBottom), left: \(marginLeft), right: \(marginRight))")
            }
        } // "auto" is default, no code needed
        
        // Columns
        if columns > 1 { params.append("columns: \(columns)") }
        
        // Numbering
        if !pageNumbering.isEmpty { params.append("numbering: \"\(pageNumbering)\"") }
        
        // Fill
        if !pageFill.isEmpty { params.append("fill: \(pageFill)") }
        
        let paramString = params.joined(separator: ", ")
        let snippet: String
        
        if applyTo == "document" {
            snippet = "#set page(\(paramString))\n"
        } else {
            snippet = "#page(\(paramString))[]\n"
        }
        
        controller.insertText(snippet)
        isPresented = false
    }
    
    private func validateTypstLength(_ length: String) -> Bool {
        let trimmed = length.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        if ["auto", "none"].contains(trimmed) { return true }
        
        // Pattern: number followed by unit (pt, mm, cm, in, %, em, fr)
        let pattern = #"^-?\d+(\.\d+)?(pt|mm|cm|in|%|em|fr)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        return regex.firstMatch(in: trimmed, range: range) != nil
    }
    
    func insertTextLayout() {
        pageValidationError = nil
        var params: [String] = []
        
        // Font
        if textFont != "Default" {
            params.append("font: \"\(textFont)\"")
        }
        
        // Size
        if !textSize.isEmpty { 
            if !validateTypstLength(textSize) {
                pageValidationError = "Invalid text size: '\(textSize)'. Use pt, mm, cm, in, em."
                return
            }
            params.append("size: \(textSize)") 
        }
        
        // Weight
        if textWeight != "regular" { params.append("weight: \"\(textWeight)\"") }
        
        // Style
        if textStyle != "normal" { params.append("style: \"\(textStyle)\"") }
        
        // Color
        if !textColor.isEmpty { params.append("fill: \(textColor)") }
        
        // Lang
        if !textLang.isEmpty { params.append("lang: \"\(textLang)\"") }
        
        // Region
        if !textRegion.isEmpty { params.append("region: \"\(textRegion)\"") }
        
        let paramString = params.joined(separator: ", ")
        let snippet = "#set text(\(paramString))\n"
        
        controller.insertText(snippet)
        isPresented = false
    }
}
