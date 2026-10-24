import Foundation
import CoreML
import CryptoKit

/// Optional-download lifecycle for the Core ML build of Microsoft's
/// LLMLingua-2 token classifier
/// (`bert-base-multilingual-cased-meetingbank` variant) that powers the
/// "LLMLingua-2" chat compression method.
///
/// Nothing ships inside the app bundle — the editor stays lean, exactly like
/// the Typst engine: the model (roughly 90 MB quantized) is downloaded once
/// from the project's model releases, compiled to a `.mlmodelc` on first
/// install, and stored under Application Support. Until it's installed — or
/// if it fails to load — the compression method silently falls back to the
/// built-in `HeuristicTokenFilter`, so the feature degrades, never breaks.
///
/// The archive itself is produced by `Tools/convert_llmlingua2_coreml.py`
/// in this repository and contains `LLMLingua2.mlpackage/` + `vocab.txt`.
@MainActor
final class LLMLingua2Manager: ObservableObject {
    static let shared = LLMLingua2Manager()

    // MARK: Published state (mirrors TypstUpdater's shape)

    @Published private(set) var isWorking = false
    @Published private(set) var status = "Ready"
    @Published private(set) var progress: Double = 0
    @Published private(set) var lastError: String?
    @Published private(set) var isInstalled = false
    /// Loaded lazily on first compression; also refreshed for the UI.
    @Published private(set) var engineReady = false

    // MARK: Distribution constants
    //
    // The archive is published once via the conversion script; bump the tag
    // (and `expectedArchiveSHA256`) whenever the model is re-converted.

    /// Where the optional Core ML compression model is published: a release
    /// asset on this repository, under a dedicated tag so it stays decoupled
    /// from the app release tags. To publish:
    ///   gh release create llmlingua2-coreml-v1 \
    ///       build/llmlingua2-coreml/LLMLingua2-CoreML.zip \
    ///       --title "LLMLingua-2 Core ML model" --notes "..."
    /// Re-convert and publish a new tag (llmlingua2-coreml-v2, …) when the
    /// model changes, and update the SHA-256 below to match.
    static let modelArchiveURL = URL(
        string: "https://github.com/tmagri/TypstEdit/releases/download/llmlingua2-coreml-v1/LLMLingua2-CoreML.zip"
    )!

    /// Optional integrity check. Empty string = skip verification (HTTPS
    /// transport only). Must match `shasum -a 256` of the published archive.
    static let expectedArchiveSHA256 = "650a02291203745e97f4c207f899f4719e88d1a53b7a2d8c1c1fa6b8e642837a"

    /// Approximate advertised size, shown in the UI before download.
    static let advertisedSize = "~310 MB"

    private var cachedEngine: LLMLingua2Engine?
    private let loadQueue = DispatchQueue(label: "com.typstedit.llmlingua2.load")

    private init() {
        isInstalled = Self.installedModelURL != nil && Self.installedVocabURL != nil
    }

    // MARK: Storage layout

    /// Application Support/TypstEdit/CompressionModel/ — the same pattern
    /// TypstUpdater uses for the downloaded engine.
    static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("TypstEdit/CompressionModel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The compiled Core ML model, once install finished.
    static var installedModelURL: URL? {
        let url = storageDirectory.appendingPathComponent("LLMLingua2.mlmodelc", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static var installedVocabURL: URL? {
        let url = storageDirectory.appendingPathComponent("vocab.txt")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Install / Remove

    /// Downloads, verifies, extracts, and compiles the model archive.
    /// Progress and status update the same observed properties the Typst
    /// engine cards bind to, so the UI patterns stay identical.
    func installModel() {
        guard !isWorking else { return }
        isWorking = true
        progress = 0
        lastError = nil
        status = "Downloading…"
        Task { await performInstall() }
    }

    private func performInstall() async {
        defer {
            isWorking = false
            refreshInstalledState()
        }
        do {
            // 1. Download (streamed, with progress).
            let archiveURL = Self.storageDirectory.appendingPathComponent("LLMLingua2-CoreML.zip")
            try await Self.downloadArchive(to: archiveURL) { [weak self] fraction in
                self?.progress = fraction
            }

            // 2. Verify checksum when one is configured.
            status = "Verifying…"
            if !Self.expectedArchiveSHA256.isEmpty {
                let digest = try await Self.sha256(of: archiveURL)
                guard digest.lowercased() == Self.expectedArchiveSHA256.lowercased() else {
                    try? FileManager.default.removeItem(at: archiveURL)
                    throw LLMLingua2Error.checksumMismatch
                }
            }

            // 3. Extract (ditto handles zip archives natively on macOS).
            status = "Extracting…"
            let extractDir = Self.storageDirectory.appendingPathComponent("extract", isDirectory: true)
            try? FileManager.default.removeItem(at: extractDir)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try await Self.runProcess("/usr/bin/ditto", ["-x", "-k", archiveURL.path, extractDir.path])

            // 4. Validate contents.
            guard let packageURL = Self.findPackage(in: extractDir) else {
                throw LLMLingua2Error.archiveMissingModel
            }
            guard let vocabURL = Self.findVocab(in: extractDir) else {
                throw LLMLingua2Error.archiveMissingVocab
            }
            let vocabText = try String(contentsOf: vocabURL, encoding: .utf8)
            guard vocabText.split(separator: "\n").count > 1_000 else {
                throw LLMLingua2Error.archiveMissingVocab
            }

            // 5. Compile the .mlpackage once; the compiled bundle is what
            //    ships forward. MLModel.compileModel lands in a temp
            //    directory, so it is moved into place afterwards.
            status = "Preparing model…"
            let compiledTemp = try await Self.runDetached {
                try MLModel.compileModel(at: packageURL)
            }
            let finalModelURL = Self.storageDirectory.appendingPathComponent("LLMLingua2.mlmodelc", isDirectory: true)
            try? FileManager.default.removeItem(at: finalModelURL)
            try FileManager.default.moveItem(at: compiledTemp, to: finalModelURL)
            let finalVocabURL = Self.storageDirectory.appendingPathComponent("vocab.txt")
            try? FileManager.default.removeItem(at: finalVocabURL)
            try FileManager.default.copyItem(at: vocabURL, to: finalVocabURL)

            // 6. Clean scratch files.
            try? FileManager.default.removeItem(at: extractDir)
            try? FileManager.default.removeItem(at: archiveURL)

            status = "Compression model installed"
            progress = 1
            cachedEngine = nil // force a fresh load with the new files
        } catch {
            lastError = Self.describe(error)
            status = "Failed"
        }
    }

    /// Deletes the installed model and any scratch state. The UI falls back
    /// to the heuristic filter immediately (settings method stays selected;
    /// `ChatCompressor.resolve` handles the degradation).
    func removeModel() {
        guard !isWorking else { return }
        cachedEngine = nil
        engineReady = false
        try? FileManager.default.removeItem(at: Self.storageDirectory)
        _ = Self.storageDirectory // recreate the (now empty) folder
        refreshInstalledState()
        status = "Removed"
    }

    func refreshInstalledState() {
        let installed = Self.installedModelURL != nil && Self.installedVocabURL != nil
        isInstalled = installed
        if !installed {
            engineReady = false
            cachedEngine = nil
        }
    }

    // MARK: Engine loading

    /// Loads (once) and returns the inference engine, or nil when the model
    /// isn't installed or fails to load. Callers never need to distinguish
    /// those cases — the compression pipeline falls back to the heuristic
    /// filter on nil.
    func loadEngineIfNeeded() async -> LLMLingua2Engine? {
        if let cachedEngine { return cachedEngine }
        guard let modelURL = Self.installedModelURL,
              let vocabURL = Self.installedVocabURL else {
            engineReady = false
            return nil
        }
        do {
            let engine = try await Self.runDetached { [vocabURL] in
                try LLMLingua2Engine(modelAt: modelURL, vocabText: String(contentsOf: vocabURL, encoding: .utf8))
            }
            cachedEngine = engine
            engineReady = true
            return engine
        } catch {
            lastError = "Couldn't load the compression model: \(Self.describe(error))"
            engineReady = false
            return nil
        }
    }

    // MARK: - Steps (all off the main actor)

    private static func downloadArchive(to destination: URL, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        let delegate = ProgressDownloadDelegate { fraction, finished, tempURL, error in
            Task { @MainActor in
                if let fraction { onProgress(min(fraction * 0.9, 0.9)) }
            }
        }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await session.download(from: modelArchiveURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LLMLingua2Error.downloadFailed
        }
        _ = delegate // keeps the delegate alive until the session is invalidated
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private static func sha256(of url: URL) async throws -> String {
        try await runDetached {
            try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Finds `LLMLingua2.mlpackage` (or any `.mlpackage`) in the extracted tree.
    private static func findPackage(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("LLMLingua2.mlpackage", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.pathExtension == "mlpackage" {
            return url
        }
        return nil
    }

    private static func findVocab(in directory: URL) -> URL? {
        let direct = directory.appendingPathComponent("vocab.txt")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "vocab.txt" {
            return url
        }
        return nil
    }

    private static func runProcess(_ path: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LLMLingua2Error.processFailed(path))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Hops a throwing, non-actor closure onto a background executor.
    private static func runDetached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }
}

// MARK: - Errors

enum LLMLingua2Error: LocalizedError {
    case downloadFailed
    case checksumMismatch
    case archiveMissingModel
    case archiveMissingVocab
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed:
            return "The model archive couldn't be downloaded. Check your connection and try again."
        case .checksumMismatch:
            return "The downloaded archive failed its integrity check and was discarded."
        case .archiveMissingModel:
            return "The archive didn't contain a Core ML model package."
        case .archiveMissingVocab:
            return "The archive didn't contain the tokenizer vocabulary (vocab.txt)."
        case .processFailed(let tool):
            return "A helper step (\(tool)) failed during installation."
        }
    }
}

// MARK: - Download Progress Delegate

/// Bridges URLSession's download-progress callbacks into a simple fraction
/// reporter. The completion signal isn't used — the async `download(from:)`
/// call above returns the temp file — this exists purely so the settings UI
/// can show a real progress bar for the (larger) model archive.
private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    typealias Reporter = @Sendable (Double?, Bool, URL?, Error?) -> Void
    private let report: Reporter

    init(report: @escaping Reporter) {
        self.report = report
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), false, nil, nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        report(1.0, true, location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { report(nil, true, nil, error) }
    }
}

// MARK: - Inference Engine

/// Owns the loaded `MLModel` plus its tokenizer and turns a text into a
/// compressed text: every word gets a keep/drop score from the model (the
/// logit of its first subtoken — LLMLingua-2's word-level scoring), then the
/// shared `TokenSelection` picks the survivors.
///
/// Prediction runs serialized on a private queue; the class is marked
/// `@unchecked Sendable` because the queue *is* the synchronization.
final class LLMLingua2Engine: @unchecked Sendable {

    private let model: MLModel
    private let tokenizer: WordPieceTokenizer
    private let queue = DispatchQueue(label: "com.typstedit.llmlingua2.predict")

    /// The model was exported with a fixed sequence length (see
    /// Tools/convert_llmlingua2_coreml.py), matching BERT's training window.
    private let maxSequenceLength = 512

    init(modelAt url: URL, vocabText: String) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: config)
        self.tokenizer = WordPieceTokenizer(vocabText: vocabText)
    }

    init(model: MLModel, vocabText: String) {
        self.model = model
        self.tokenizer = WordPieceTokenizer(vocabText: vocabText)
    }

    /// Synchronous compression — call through `LLMLingua2Compressor` (async)
    /// off the main actor.
    func compress(_ text: String, keepRate: Double, forceTokens: [String], isCode: Bool) -> String {
        queue.sync {
            let segmentation = PromptCompression.segment(text)
            let segments = segmentation.segments
            guard segments.count > 3 else { return text }

            // One representative id per word: the word's first subtoken.
            // Word-level filtering means a word is kept or dropped whole —
            // the compressed text stays word-aligned and readable.
            let representativeIDs: [Int] = segments.map { tokenizer.encodeWord($0.text).first ?? tokenizer.unkID }

            // Score every word (chunked to the model's fixed window).
            var scores = [Double](repeating: 0, count: segments.count)
            let window = maxSequenceLength - 2 // CLS + content + SEP
            var chunkStart = 0
            while chunkStart < representativeIDs.count {
                let chunkEnd = min(chunkStart + window, representativeIDs.count)
                let chunk = Array(representativeIDs[chunkStart..<chunkEnd])
                let chunkScores = (try? runScores(for: chunk)) ?? []
                for (offset, score) in chunkScores.enumerated() {
                    scores[chunkStart + offset] = score
                }
                chunkStart = chunkEnd
            }

            // Code safety: rate floor + forced structural words, exactly
            // like the heuristic path, so neither compressor can mangle a
            // Typst file's syntax.
            let effectiveRate = isCode ? max(keepRate, 0.8) : keepRate
            var forced = Set<Int>()
            let forcedWords = Set(forceTokens.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                .union(isCode ? HeuristicTokenFilter.structuralTokens : [])
            for (index, segment) in segments.enumerated() {
                let raw = segment.text.lowercased()
                // Same rule as the heuristic filter: word-level force
                // matching ignores attached punctuation, braces match raw.
                let bare = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;:!?()[]{}"))
                if forcedWords.contains(bare) || forcedWords.contains(raw)
                    || (isCode && HeuristicTokenFilter.structuralTokens.contains(raw)) {
                    forced.insert(index)
                }
                if isCode && segment.text.contains(where: { "{}()[]#$=;<>\\".contains($0) }) {
                    scores[index] += 2.0
                }
            }

            let keeping = TokenSelection.keepIndices(scores: scores, keepRate: effectiveRate, forced: forced)
            return segmentation.assemble(keeping: keeping)
        }
    }

    /// One forward pass over `[CLS] ids [SEP]`; returns keep-logit minus
    /// drop-logit per content position (first `count` entries).
    private func runScores(for ids: [Int]) throws -> [Double] {
        let length = ids.count + 2
        let inputIDs = Self.array(from: [tokenizer.clsID] + ids + [tokenizer.sepID], length: length)
        let attentionMask = Self.array(from: Array(repeating: 1, count: length), length: length)
        let typeIDs = Self.array(from: Array(repeating: 0, count: length), length: length)

        let inputNames = model.modelDescription.inputDescriptionsByName.keys.sorted()
        guard inputNames.count >= 3 else { return [] }
        // The conversion script names them input_ids / attention_mask /
        // token_type_ids; sorted() restores exactly that order. Anything
        // else is still handled positionally.
        let input = try MLDictionaryFeatureProvider(dictionary: [
            inputNames[0]: MLFeatureValue(multiArray: inputIDs),
            inputNames[1]: MLFeatureValue(multiArray: attentionMask),
            inputNames[2]: MLFeatureValue(multiArray: typeIDs),
        ])
        let output = try model.prediction(from: input)

        let outputNames = model.modelDescription.outputDescriptionsByName.keys.sorted()
        guard let logits = output.featureValue(for: outputNames[0])?.multiArrayValue,
              logits.count >= length * 2 else { return [] }

        var result = [Double](repeating: 0, count: ids.count)
        for position in 0..<ids.count {
            let drop = logits[position * 2]
            let keep = logits[position * 2 + 1]
            result[position] = keep.doubleValue - drop.doubleValue
        }
        return result
    }

    private static func array(from values: [Int], length: Int) -> MLMultiArray {
        let array = try! MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: value)
        }
        return array
    }
}

// MARK: - Compressor Adapter

/// `LLMLingua2Engine` behind the `PromptCompressor` protocol: hops the
/// (blocking) Core ML prediction off the calling actor.
struct LLMLingua2Compressor: PromptCompressor {
    let engine: LLMLingua2Engine

    func compress(
        _ text: String,
        keepRate: Double,
        forceTokens: [String],
        isCode: Bool
    ) async -> String {
        let engine = self.engine
        return await Task.detached(priority: .userInitiated) {
            engine.compress(text, keepRate: keepRate, forceTokens: forceTokens, isCode: isCode)
        }.value
    }
}
