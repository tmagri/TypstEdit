import SwiftUI
import AppKit

struct LayoutEditorView: View {
    @ObservedObject var controller: EditorController
    @Binding var isPresented: Bool
    
    // Tab State
    @State private var selectedTab: String = "text" // text, par, align, page
    
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
    @State private var pageNumberAlign: String = "center" // New
    @State private var pageFill: String = ""
    @State private var pageHeader: String = "" // New
    @State private var pageFooter: String = "" // New
    @State private var applyTo: String = "document" // document, next_page
    @State private var pageValidationError: String? = nil
    
    // --- Text Settings State ---
    @State private var textFont: String = "Default"
    @State private var textSize: String = "11pt"
    @State private var textWeight: String = "regular"
    @State private var textStyle: String = "normal"
    @State private var textColor: String = ""
    @State private var textStrokeColor: String = "" // New
    @State private var textStrokeThickness: String = "" // New
    @State private var textStretch: Double = 100 // New (percentage)
    @State private var textDirection: String = "ltr" // New
    @State private var textScript: String = "" // New
    @State private var textLang: String = "en"
    @State private var textRegion: String = ""
    
    // --- Paragraph Settings State (New) ---
    @State private var parJustify: Bool = false
    @State private var parHyphenate: Bool = false
    @State private var parLeading: String = "" // e.g. 1.5em
    @State private var parSpacing: String = "" // e.g. 1.2em
    @State private var parIndent: String = "" // First line indent
    @State private var parHangingIndent: String = ""
    
    // --- Alignment Settings State (New) ---
    @State private var alignHorizontal: String = "start" // left, center, right, start, end
    @State private var alignVertical: String = "top" // top, horizon, bottom
    
    // Data Sources
    let paperSizes = ["a4", "us-letter", "us-legal", "a3", "a5", "iso-b5"]
    @State private var availableFonts: [String] = []
    let weights = ["thin", "extralight", "light", "regular", "medium", "semibold", "bold", "extrabold", "black"]
    let styles = ["normal", "italic", "oblique"]
    let directions = ["ltr", "rtl"]
    let alignHorizons = ["start", "left", "center", "right", "end"]
    let alignVerticals = ["top", "horizon", "bottom"]
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "doc.plaintext")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Document Styles")
                    .font(.headline)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Tab Picker
            Picker("", selection: $selectedTab) {
                Text("Text").tag("text")
                Text("Paragraph").tag("par")
                Text("Align").tag("align")
                Text("Page").tag("page")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if selectedTab == "text" {
                        textSettingsView
                    } else if selectedTab == "par" {
                        paragraphSettingsView
                    } else if selectedTab == "align" {
                        alignmentSettingsView
                    } else if selectedTab == "page" {
                        pageSettingsView
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
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Insert Code") {
                    switch selectedTab {
                    case "text": insertTextLayout()
                    case "par": insertParagraphLayout()
                    case "align": insertAlignmentLayout()
                    case "page": insertPageLayout()
                    default: break
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 550)
        .onAppear {
            loadFonts()
        }
    }
    
    // MARK: - Subviews
    
    var pageSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Paper Size & Orientation
            VStack(alignment: .leading, spacing: 8) {
                Label("Paper", systemImage: "doc.text")
                    .font(.subheadline.bold())
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
                    Label("Margins", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.subheadline.bold())
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
                                .textFieldStyle(.roundedBorder)
                            Text("Bottom:")
                            TextField("2.5cm", text: $marginBottom)
                                .textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 12) {
                            Text("Left:")
                            TextField("2.5cm", text: $marginLeft)
                                .textFieldStyle(.roundedBorder)
                            Text("Right:")
                            TextField("2.5cm", text: $marginRight)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            
            Divider()
            
            // Columns & Numbering
            VStack(alignment: .leading, spacing: 12) {
                Label("Content", systemImage: "list.dash")
                    .font(.subheadline.bold())
                
                HStack {
                    Text("Columns:")
                    Spacer()
                    Stepper("\(columns)", value: $columns, in: 1...4)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page Numbers:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack {
                        TextField("e.g. \"1 / 1\"", text: $pageNumbering)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $pageNumberAlign) {
                            ForEach(alignHorizons, id: \.self) { align in
                                Text(align.capitalized).tag(align)
                            }
                        }
                        .frame(width: 100)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Background Fill:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g. #f0f0f0", text: $pageFill)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            Divider()
            
            // Header & Footer
            VStack(alignment: .leading, spacing: 12) {
                Label("Header & Footer", systemImage: "macwindow.on.rectangle")
                    .font(.subheadline.bold())
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Header:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Content", text: $pageHeader)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Footer:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Content", text: $pageFooter)
                        .textFieldStyle(.roundedBorder)
                }
            }
            
            Divider()
            
            // Apply To
            VStack(alignment: .leading, spacing: 8) {
                Label("Apply To", systemImage: "arrow.turn.down.right")
                    .font(.subheadline.bold())
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
            Label("Font Settings", systemImage: "textformat")
                .font(.subheadline.bold())
            
            // Font Family
            VStack(alignment: .leading, spacing: 4) {
                Text("Font Family:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $textFont) {
                    Text("Default").tag("Default")
                    Divider()
                    ForEach(availableFonts, id: \.self) { font in
                        Text(font).tag(font)
                    }
                }
            }
            
            // Size, Weight, Style
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Size:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("11pt", text: $textSize)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weight:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $textWeight) {
                        ForEach(weights, id: \.self) { w in
                            Text(w.capitalized).tag(w)
                        }
                    }
                    .frame(width: 120)
                }
            }
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Style:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $textStyle) {
                        ForEach(styles, id: \.self) { s in
                            Text(s.capitalized).tag(s)
                        }
                    }
                    .frame(width: 120)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Color:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("#000000", text: $textColor)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
            
            Divider()
            
            // Stroke & Stretch
            Label("Advanced Typography", systemImage: "sparkles")
                .font(.subheadline.bold())
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stroke Color:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("e.g. black", text: $textStrokeColor)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thickness:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("0.5pt", text: $textStrokeThickness)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
            }
            
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stretch (\(Int(textStretch))%):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Slider(value: $textStretch, in: 50...200, step: 5)
                }
                
                Spacer()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Direction:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("", selection: $textDirection) {
                        ForEach(directions, id: \.self) { d in
                            Text(d.uppercased()).tag(d)
                        }
                    }
                    .frame(width: 100)
                }
            }
            
            Divider()
            
            Label("Localization", systemImage: "globe")
                .font(.subheadline.bold())
            
            // Lang & Region
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Language:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("en", text: $textLang)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Region:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("US", text: $textRegion)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Script:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("latn", text: $textScript)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                
                Spacer()
            }
        }
    }
    
    // MARK: - New Views
    
    var paragraphSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Paragraph Layout", systemImage: "paragraphsign")
                .font(.subheadline.bold())
            
            HStack(spacing: 20) {
                Toggle("Justify Text", isOn: $parJustify)
                Toggle("Hyphenate", isOn: $parHyphenate)
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Leading (Line Spacing):")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. 1.5em", text: $parLeading)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paragraph Spacing:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. 1.2em", text: $parSpacing)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("First Line Indent:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. 2em", text: $parIndent)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hanging Indent:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g. 0pt", text: $parHangingIndent)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }
    
    var alignmentSettingsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Content Alignment", systemImage: "align.horizontal.center")
                .font(.subheadline.bold())
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Horizontal Alignment:")
                Picker("", selection: $alignHorizontal) {
                    ForEach(alignHorizons, id: \.self) { a in
                        Text(a.capitalized).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Vertical Alignment:")
                Picker("", selection: $alignVertical) {
                    ForEach(alignVerticals, id: \.self) { a in
                        Text(a.capitalized).tag(a)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Spacer()
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
        if !pageNumbering.isEmpty { 
            params.append("numbering: \"\(pageNumbering)\"") 
            if pageNumberAlign != "center" {
                 params.append("number-align: \(pageNumberAlign)")
            }
        }
        
        // Fill
        if !pageFill.isEmpty { params.append("fill: \(pageFill)") }
        
        // Header
        if !pageHeader.isEmpty { params.append("header: [\(pageHeader)]") }
        
        // Footer
        if !pageFooter.isEmpty { params.append("footer: [\(pageFooter)]") }
        
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
    
    // ... validateTypstLength ... (unchanged)
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
        
        // Stroke
        if !textStrokeColor.isEmpty {
            if !textStrokeThickness.isEmpty {
                params.append("stroke: (paint: \(textStrokeColor), thickness: \(textStrokeThickness))")
            } else {
                params.append("stroke: \(textStrokeColor)")
            }
        }
        
        // Stretch
        if textStretch != 100 { params.append("stretch: \(Int(textStretch))%") }
        
        // Direction
        if textDirection != "ltr" { params.append("dir: \(textDirection)") }
        
        // Script
        if !textScript.isEmpty { params.append("script: \"\(textScript)\"") }
        
        // Lang
        if !textLang.isEmpty { params.append("lang: \"\(textLang)\"") }
        
        // Region
        if !textRegion.isEmpty { params.append("region: \"\(textRegion)\"") }
        
        let paramString = params.joined(separator: ", ")
        let snippet = "#set text(\(paramString))\n"
        
        controller.insertText(snippet)
        isPresented = false
    }
    
    func insertParagraphLayout() {
        pageValidationError = nil
        var params: [String] = []
        
        if parJustify { params.append("justify: true") }
        if parHyphenate { params.append("hyphenate: true") }
        
        if !parLeading.isEmpty {
           if !validateTypstLength(parLeading) {
               pageValidationError = "Invalid leading unit: '\(parLeading)'"
               return
           }
           params.append("leading: \(parLeading)")
        }
        
        if !parSpacing.isEmpty {
           if !validateTypstLength(parSpacing) {
               pageValidationError = "Invalid spacing unit: '\(parSpacing)'"
               return
           }
           params.append("spacing: \(parSpacing)")
        }
        
        if !parIndent.isEmpty { params.append("first-line-indent: \(parIndent)") }
        if !parHangingIndent.isEmpty { params.append("hanging-indent: \(parHangingIndent)") }
        
        let paramString = params.joined(separator: ", ")
        let snippet = "#set par(\(paramString))\n"
        controller.insertText(snippet)
        isPresented = false
    }
    
    func insertAlignmentLayout() {
        var alignParts: [String] = []
        
        if alignHorizontal != "start" { alignParts.append(alignHorizontal) }
        if alignVertical != "top" { alignParts.append(alignVertical) }
        
        let alignContent = alignParts.joined(separator: " + ")
        if !alignContent.isEmpty {
            let snippet = "#set align(\(alignContent))\n"
            controller.insertText(snippet)
            isPresented = false
        } else {
            // Default/Empty
            isPresented = false
        }
    }
}
