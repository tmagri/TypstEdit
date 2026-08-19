import Foundation

enum ModuleResources {
    static let main: Bundle = {
        let name = "TypstEdit_TypstEdit.bundle"
        let candidates = [
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
