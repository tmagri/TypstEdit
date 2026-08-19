import SwiftUI
import WebKit

class EditorBridge: ObservableObject {
    var saveAction: (() -> Void)?
    
    func save() {
        print("[DEBUG] EditorBridge.save() called, action exists: \(saveAction != nil)")
        saveAction?()
    }
}

struct VisualEquationEditor: View {
    @Binding var initialEquation: String
    var onSave: (String) -> Void
    var onCancel: () -> Void
    
    @StateObject private var bridge = EditorBridge()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sum")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("Equation Editor")
                    .font(.headline)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // WebView
            WebViewWrapper(initialEquation: $initialEquation, bridge: bridge, onSaveTransport: { code in
                onSave(code)
            })
            
            Divider()
            
            // Footer
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button("Insert Equation") {
                    print("[DEBUG] Insert button clicked")
                    bridge.save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
    }
}

struct WebViewWrapper: NSViewRepresentable {
    @Binding var initialEquation: String
    @ObservedObject var bridge: EditorBridge
    var onSaveTransport: (String) -> Void
    
    func makeNSView(context: Context) -> WKWebView {
        let webConfiguration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        
        // Add message handler
        userContentController.add(context.coordinator, name: "equationEditor")
        webConfiguration.userContentController = userContentController
        
        let webView = WKWebView(frame: .zero, configuration: webConfiguration)
        
        // Safely enable the Web Inspector for debugging (macOS 13.3+)
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        
        context.coordinator.webView = webView // Set early
        webView.navigationDelegate = context.coordinator
        
        // Helper to find resources whether SPM flattened them or kept the folder
        func getResourceURL(name: String, ext: String) -> URL? {
            return ModuleResources.main.url(forResource: name, withExtension: ext) ??
                   ModuleResources.main.url(forResource: name, withExtension: ext, subdirectory: "Vendor") ??
                   Bundle.main.url(forResource: name, withExtension: ext) ??
                   Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Vendor")
        }
        
        // Robust HTML loading & JS Injection
        if let htmlURL = getResourceURL(name: "EquationEditor", ext: "html") {
            let baseURL = htmlURL.deletingLastPathComponent()
            
            do {
                var html = try String(contentsOf: htmlURL, encoding: .utf8)
                
                // Inject JS directly to bypass WKWebView local file restrictions and SPM path flattening
                if let mURL = getResourceURL(name: "mathlive.min", ext: "js"),
                   let tURL = getResourceURL(name: "tex2typst.min", ext: "js") {
                    
                    let mathliveJS = try String(contentsOf: mURL, encoding: .utf8)
                    let tex2typstJS = try String(contentsOf: tURL, encoding: .utf8)
                    
                    html = html.replacingOccurrences(of: "<script defer src=\"./Vendor/mathlive.min.js\"></script>", with: "<script>\n\(mathliveJS)\n</script>")
                    html = html.replacingOccurrences(of: "<script src=\"./Vendor/tex2typst.min.js\"></script>", with: "<script>\n\(tex2typstJS)\n</script>")
                }
                
                webView.loadHTMLString(html, baseURL: baseURL)
            } catch {
                print("[ERROR] Fallback to loadFileURL: \(error)")
                webView.loadFileURL(htmlURL, allowingReadAccessTo: baseURL)
            }
        } else {
            print("[ERROR] Could not find EquationEditor.html in bundle.")
        }
        
        // Transparent background
        webView.setValue(false, forKey: "drawsBackground")
        
        return webView
    }
    
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Update parent to ensure closure captures (like onSave) are fresh
        context.coordinator.parent = self
    }
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: WebViewWrapper
        var webView: WKWebView?
        
        init(_ parent: WebViewWrapper) {
            self.parent = parent
            super.init()
            // weak reference to avoid cycles if closure captures coordinator? 
            // Coordinator lives on View? No, Representable creates it.
            // We need to set the action on the bridge.
            parent.bridge.saveAction = { [weak self] in
                self?.save()
            }
        }
        
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "equationEditor", let body = message.body as? [String: Any], let type = body["type"] as? String {
                print("[DEBUG] Received message from JS: \(type)")
                
                if type == "ready" {
                    // Inject initial equation
                    print("[DEBUG] JS Ready, injecting: \(parent.initialEquation)")
                    injectEquation(parent.initialEquation, in: message.webView)
                } else if type == "save" {
                    // Handle save message
                    if let content = body["content"] as? String {
                        print("[DEBUG] Received equation from JS via message: \(content)")
                        DispatchQueue.main.async {
                            self.parent.onSaveTransport(content)
                        }
                    }
                } else if type == "error" {
                    let message = body["message"] as? String ?? "Unknown JS error"
                    let source = body["source"] as? String ?? "unknown"
                    let line = body["lineno"] as? Int ?? 0
                    print("[ERROR] JS Error in Equation Editor: \(message) at \(source):\(line)")
                } else if type == "log" {
                    let level = body["level"] as? String ?? "debug"
                    let message = body["message"] as? String ?? ""
                    print("[JS-\(level.uppercased())] \(message)")
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
        }
        
        func injectEquation(_ equation: String, in targetWebView: WKWebView? = nil) {
            let activeWebView = targetWebView ?? self.webView
            
            guard let webView = activeWebView else {
                print("[ERROR] Cannot inject equation: webView is nil")
                return
            }
            
            // Escape: backslash, single quote, newline
             let escaped = equation.replacingOccurrences(of: "\\", with: "\\\\")
                                   .replacingOccurrences(of: "'", with: "\\'")
                                   .replacingOccurrences(of: "\n", with: "\\n")
            
            print("[DEBUG] Injecting equation into JS: \(escaped)")
            let script = "window.setEquation('\(escaped)')"
            webView.evaluateJavaScript(script) { (result, error) in
                if let error = error {
                    print("[ERROR] JS injection failed: \(error)")
                }
            }
        }
        
        func save() {
            print("[DEBUG] JS triggerSave called")
            // Call the void function that triggers the message response
            webView?.evaluateJavaScript("window.triggerSave()") { (result, error) in
                if let error = error {
                    print("[ERROR] Error calling triggerSave: \(error)")
                }
            }
        }
    }
}
