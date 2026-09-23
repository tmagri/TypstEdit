import Foundation

enum ImageCleanupRegex {
    static let typst = try! NSRegularExpression(pattern: #"\bimage\s*\(\s*"([^"]+)""#)
    static let markdown = try! NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*<?([^)>]+?)>?\s*\)"#)
}

/// An image file on disk that no scanned document references.
struct UnusedImage: Identifiable, Hashable {
    let url: URL
    let fileSize: Int

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Result of scanning a folder for images that are never referenced.
struct ImageCleanupReport {
    let unusedImages: [UnusedImage]
    let documentCount: Int
    let imageCount: Int

    var totalUnusedBytes: Int { unusedImages.reduce(0) { $0 + $1.fileSize } }
}

/// Finds image files that no document (.typ, .note, .md) in a project or
/// notebook folder references. Matching is deliberately conservative — a
/// reference that could plausibly resolve to an existing image (root-relative,
/// document-relative, absolute, or by bare filename) marks it as used, so an
/// image is only reported when nothing can possibly point at it. False
/// "unused" reports would lose data; false "used" ones merely skip a file.
enum ImageCleanupScanner {
    static let documentExtensions: Set<String> = ["typ", "note", "md", "markdown"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tif", "tiff", "heic", "heif"]

    /// Folders never scanned. "backups"/"temp"/"vectorcaches" are app-managed
    /// output (same set the sidebar hides); "archive" is skipped so images a
    /// previous cleanup moved there don't resurface as unused.
    static let skippedFolderNames: Set<String> = ["backups", "temp", "vectorcaches", "archive"]

    /// Destination for "Archive": an `Archive/` folder at the scan root.
    static func archiveDirectory(for root: URL) -> URL {
        root.appendingPathComponent("Archive", isDirectory: true)
    }

    // MARK: - Scanning

    static func scan(root: URL) -> ImageCleanupReport {
        let fileManager = FileManager.default

        var documents: [URL] = []
        var imageSizes: [URL: Int] = [:]

        // Breadth-first walk, pruning skipped folders as they are reached.
        var queue: [URL] = [root]
        while !queue.isEmpty {
            let folder = queue.removeFirst()
            let contents = (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skippedFolderNames.contains(item.lastPathComponent.lowercased()) { continue }
                    queue.append(item)
                    continue
                }
                let ext = item.pathExtension.lowercased()
                if documentExtensions.contains(ext) {
                    documents.append(item)
                } else if imageExtensions.contains(ext) {
                    imageSizes[item] = values?.fileSize ?? 0
                }
            }
        }

        // Collect every path a document could plausibly be pointing at.
        var usedPaths: Set<String> = []
        var usedFileNames: Set<String> = []

        for document in documents {
            guard let decoded = try? TextFileEncoding.string(from: document) else { continue }
            let documentDirectory = document.deletingLastPathComponent()
            for rawReference in imageReferencePaths(in: decoded.text) {
                let reference = rawReference.removingPercentEncoding ?? rawReference
                let lowered = reference.lowercased()
                if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("data:") {
                    continue
                }
                if lowered.hasPrefix("~") {
                    usedPaths.insert(URL(fileURLWithPath: (reference as NSString).expandingTildeInPath).standardizedFileURL.path)
                } else if reference.hasPrefix("/") {
                    usedPaths.insert(URL(fileURLWithPath: reference).standardizedFileURL.path)
                } else {
                    // Typst compiles with `--root <project>`, so references may be
                    // root-relative, while the compiler's temp-file rewriting
                    // produces document-relative ones. Accept both.
                    usedPaths.insert(root.appendingPathComponent(reference).standardizedFileURL.path)
                    usedPaths.insert(documentDirectory.appendingPathComponent(reference).standardizedFileURL.path)
                }
                // Bare-name match keeps an image safe even when a document
                // resolves its path in a way this scan doesn't model.
                usedFileNames.insert((reference as NSString).lastPathComponent.lowercased())
            }
        }

        let unused = imageSizes
            .filter { url, _ in
                !usedPaths.contains(url.standardizedFileURL.path)
                    && !usedFileNames.contains(url.lastPathComponent.lowercased())
            }
            .map { UnusedImage(url: $0.key, fileSize: $0.value) }
            .sorted { $0.url.path < $1.url.path }

        return ImageCleanupReport(
            unusedImages: unused,
            documentCount: documents.count,
            imageCount: imageSizes.count
        )
    }

    // MARK: - Reference extraction

    /// Image paths referenced by a document. Understands Typst `#image("…")`
    /// (the `#` is optional, so code-mode `image(…)` calls match too) and
    /// Markdown `![alt](…)` — which together cover `.typ`, `.md`, and the
    /// hybrid `.note` format. Web and data URLs are returned as-is; callers
    /// skip them.
    static func imageReferencePaths(in text: String) -> Set<String> {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var references: Set<String> = []

        // \b stops `image(` from matching inside identifiers like `myimage(`
        // while still matching both `#image(` and bare `image(`.
        for match in ImageCleanupRegex.typst.matches(in: text, options: [], range: fullRange) {
            references.insert(nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces))
        }

        // Markdown, including the angle-bracket form used for paths with spaces.
        for match in ImageCleanupRegex.markdown.matches(in: text, options: [], range: fullRange) {
            references.insert(nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces))
        }

        return references
    }

    // MARK: - Actions

    /// Moves images to the Trash. Returns the number successfully trashed.
    @discardableResult
    static func trash(_ images: [UnusedImage]) -> Int {
        var trashed = 0
        for image in images {
            do {
                try FileManager.default.trashItem(at: image.url, resultingItemURL: nil)
                trashed += 1
            } catch {
                print("ImageCleanup: failed to trash \(image.url.path): \(error)")
            }
        }
        return trashed
    }

    /// Moves images into `Archive/` under `root`, preserving each image's
    /// folder structure relative to the root so names cannot collide.
    /// Returns the number successfully moved.
    @discardableResult
    static func archive(_ images: [UnusedImage], into root: URL) -> Int {
        let fileManager = FileManager.default
        let archiveRoot = archiveDirectory(for: root).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        var archived = 0

        for image in images {
            let sourcePath = image.url.standardizedFileURL.path
            let relative = sourcePath.hasPrefix(rootPath + "/") ? String(sourcePath.dropFirst(rootPath.count + 1)) : image.name
            var destination = archiveRoot.appendingPathComponent(relative)

            var uniqueSuffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = destination.deletingLastPathComponent()
                    .appendingPathComponent("\(image.url.deletingPathExtension().lastPathComponent) \(uniqueSuffix).\(image.url.pathExtension)")
                uniqueSuffix += 1
            }

            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: image.url, to: destination)
                archived += 1
            } catch {
                print("ImageCleanup: failed to archive \(sourcePath): \(error)")
            }
        }
        return archived
    }
}
