import Foundation

extension Bundle {
    /// The enclosing `.app` bundle, even when running as a helper tool in
    /// `Contents/Helpers/` (where `Bundle.main` is just that folder).
    ///
    /// LaunchServices only treats a process as the GUI application when it is
    /// started from `<app>.app/Contents/MacOS/<CFBundleExecutable>`, so the CLI
    /// and MCP server run from `Contents/Helpers/typstedit` and must look up
    /// resources through the enclosing bundle instead of `Bundle.main`.
    static var enclosingAppBundle: Bundle {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return .main
        }
        var url = Bundle.main.bundleURL
        while url.path != "/" {
            if url.pathExtension == "app", let bundle = Bundle(url: url) {
                return bundle
            }
            url = url.deletingLastPathComponent()
        }
        if !CommandLine.arguments.isEmpty {
            var argURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            while argURL.path != "/" {
                if argURL.pathExtension == "app", let bundle = Bundle(url: argURL) {
                    return bundle
                }
                argURL = argURL.deletingLastPathComponent()
            }
        }
        return .main
    }
}

enum ModuleResources {
    static let main: Bundle = {
        let name = "TypstEdit_TypstEdit.bundle"
        let candidates = [
            Bundle.enclosingAppBundle.resourceURL,
            Bundle.enclosingAppBundle.bundleURL,
            Bundle.main.resourceURL,
            Bundle.main.bundleURL
        ]
        for candidate in candidates {
            if let path = candidate?.appendingPathComponent(name).path,
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return .main
    }()
}
