import XCTest
@testable import TypstEdit

/// Regression coverage for compiling with "Store Temp Files Inside Project"
/// turned off. The shadow source then lives under the OS temp directory, which
/// Typst rejects with "source file must be contained in project root" unless
/// `--root` is widened to a directory that contains both the project and the
/// shadow file.
final class CompileRootTests: XCTestCase {

    // MARK: - Root resolution

    func testProjectRootIsKeptWhenShadowLivesInsideIt() {
        let project = URL(fileURLWithPath: "/Users/example/project")
        let shadow = URL(fileURLWithPath: "/Users/example/project/temp")

        let root = TypstCompiler.compileRoot(projectRoot: project, shadowDirectory: shadow)

        XCTAssertEqual(root.url.standardizedFileURL.path, project.standardizedFileURL.path)
        XCTAssertFalse(root.isWidened)
    }

    func testRootIsWidenedForOSStorage() {
        let project = URL(fileURLWithPath: "/Users/example/project")
        let shadow = URL(fileURLWithPath: "/private/var/folders/ab/T/TypstEdit/0123456789abcdef/build")

        let root = TypstCompiler.compileRoot(projectRoot: project, shadowDirectory: shadow)

        XCTAssertEqual(root.url.path, "/", "the only directory containing both is the filesystem root")
        XCTAssertTrue(root.isWidened)
    }

    func testRootIsWidenedToTheDeepestCommonDirectory() {
        let project = URL(fileURLWithPath: "/Users/example/project")
        let shadow = URL(fileURLWithPath: "/Users/example/.typstedit-cache/build")

        let root = TypstCompiler.compileRoot(projectRoot: project, shadowDirectory: shadow)

        XCTAssertEqual(root.url.standardizedFileURL.path, "/Users/example")
        XCTAssertTrue(root.isWidened)
    }

    // MARK: - Root-absolute references

    func testRootAbsoluteReferencesAreMadeRelativeToTheShadow() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("CompileRootTests-\(UUID().uuidString)")
        let project = base.appendingPathComponent("project")
        let shadowDir = base.appendingPathComponent("TypstEdit/hash/build")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        try "#let greeting = [hi]".write(
            to: project.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: project.appendingPathComponent("logo.png"))

        let content = """
        #import "/lib.typ": greeting
        #image("/logo.png")
        Text that mentions "/not-a-real-file"
        """
        let rewritten = TypstCompiler.rewriteRootAbsolutePaths(
            in: content, projectRoot: project, shadowDirectory: shadowDir)

        XCTAssertFalse(rewritten.contains("\"/lib.typ\""), rewritten)
        XCTAssertFalse(rewritten.contains("\"/logo.png\""), rewritten)
        XCTAssertTrue(rewritten.contains("\"/not-a-real-file\""), "plain text must not be rewritten")

        // The rewritten references resolve to the project files from the shadow.
        for (reference, file) in [
            (firstQuotedPath(after: "#import ", in: rewritten), "lib.typ"),
            (firstQuotedPath(after: "#image(", in: rewritten), "logo.png"),
        ] {
            let resolved = URL(fileURLWithPath:
                (shadowDir.path as NSString).appendingPathComponent(reference)).standardizedFileURL
            XCTAssertEqual(resolved.path, project.appendingPathComponent(file).standardizedFileURL.path,
                           "reference \(reference) in:\n\(rewritten)")
        }
    }

    func testMissingRootAbsoluteReferencesAreUntouched() throws {
        let project = URL(fileURLWithPath: "/Users/example/project")
        let content = "#import \"/lib.typ\": *"
        let rewritten = TypstCompiler.rewriteRootAbsolutePaths(
            in: content, projectRoot: project, shadowDirectory: project.appendingPathComponent("temp"))
        XCTAssertEqual(rewritten, content)
    }

    // MARK: - End-to-end

    /// Compiles a document whose imports and images are root-absolute while the
    /// project keeps its scratch files in the OS temp directory. Before the
    /// root-widening fix this failed with "source file must be contained in
    /// project root".
    @MainActor
    func testCompileWithOSStorageSucceeds() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("CompileRootE2E-\(UUID().uuidString)")
        let project = base.appendingPathComponent("project")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        defer {
            AppTempDirectoryManager.clear(for: project)
            try? fm.removeItem(at: base)
        }

        let configDir = project.appendingPathComponent(ProjectSettingsManager.dotFolderName)
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try #"{"storeTempInProject": false}"#.write(
            to: configDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(
            ProjectSettingsManager.effectiveStoreTempInProject(for: project),
            "the fixture must exercise out-of-project storage")

        try "#let greeting = [Hello from lib]".write(
            to: project.appendingPathComponent("lib.typ"), atomically: true, encoding: .utf8)
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: project.appendingPathComponent("logo.png"))

        let source = """
        #import "/lib.typ": greeting
        = Document
        #greeting
        #image("/logo.png")
        """
        let original = project.appendingPathComponent("doc.typ")
        try source.write(to: original, atomically: true, encoding: .utf8)

        let result = await TypstCompiler().compileClean(
            content: source, fileExtension: "typ", originalFileURL: original, projectRoot: project)

        XCTAssertTrue(result.success, result.error ?? "")
        XCTAssertFalse(
            (result.error ?? "").contains("must be contained in project root"),
            "the compiler root must contain the shadow file")
        let pdf = try XCTUnwrap(result.pdfURL)
        XCTAssertGreaterThan((try? Data(contentsOf: pdf))?.count ?? 0, 100)
    }

    // MARK: - Helpers

    /// The first `"…"` string after `marker`, e.g. the path in `#image("…")`.
    private func firstQuotedPath(after marker: String, in text: String) -> String {
        guard let start = text.range(of: marker)?.upperBound,
              let open = text[start...].firstIndex(of: "\""),
              let close = text[text.index(after: open)...].firstIndex(of: "\"") else {
            return ""
        }
        return String(text[text.index(after: open)..<close])
    }
}
