import Foundation
import NaturalLanguage
import Accelerate
import CSQLite
import vector

// MARK: - Core Data Models
struct DocumentChunk: Codable {
    let fileURL: URL
    let text: String
    let embedding: [Float]
}

enum EmbeddingError: Error {
    case modelUnavailable
    case generationFailed
    case apiError(String)
}

// MARK: - Embedding Interface
protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    func getEmbedding(for text: String) async throws -> [Float]
}

// MARK: - Local Provider (Apple Native)
struct LocalEmbeddingProvider: EmbeddingProvider {
    var dimensions: Int { return 512 }
    
    func getEmbedding(for text: String) async throws -> [Float] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            throw EmbeddingError.modelUnavailable
        }
        guard let vector = embedding.vector(for: text) else {
            throw EmbeddingError.generationFailed
        }
        return vector.map { Float($0) }
    }
}

// MARK: - Generic API Provider (Handles OpenAI & Ollama via /v1/embeddings)
struct GenericAPIEmbeddingProvider: EmbeddingProvider {
    var dimensions: Int
    let endpointURL: URL
    let apiKey: String
    let modelName: String
    
    func getEmbedding(for text: String) async throws -> [Float] {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        
        if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let cleanText = text.replacingOccurrences(of: "\n", with: " ")
        let body: [String: Any] = [
            "input": cleanText,
            "model": modelName
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw EmbeddingError.apiError("API failed. Make sure the endpoint is correct and running.")
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]],
              let firstResult = dataArray.first,
              let embedding = firstResult["embedding"] as? [Double] else {
            throw EmbeddingError.generationFailed
        }
        
        return embedding.map { Float($0) }
    }
}

@MainActor
class RAGManager: ObservableObject {
    static let shared = RAGManager()
    
    @Published var isIndexing: Bool = false
    @Published var indexProgress: Double = 0.0     
    @Published var indexStatus: String = ""      
    
    private var currentProjectDir: URL?
    private var db: OpaquePointer?
    
    private init() {}
    
    // MARK: - Path Configuration
    
    private var cacheFolderURL: URL? {
        currentProjectDir?.appendingPathComponent("vectorcaches", isDirectory: true)
    }
    
    private var dbFileURL: URL? {
        if AISettingsManager.shared.cacheEmbeddingsToDisk {
            return cacheFolderURL?.appendingPathComponent("project_index.sqlite")
        }
        return nil
    }
    
    private var activeProvider: EmbeddingProvider {
        let settings = AISettingsManager.shared
        
        switch settings.provider {
        case .openAI:
            return GenericAPIEmbeddingProvider(
                dimensions: settings.openAIEmbeddingModel.contains("large") ? 3072 : 1536,
                endpointURL: URL(string: "https://api.openai.com/v1/embeddings")!,
                apiKey: settings.openAIApiKey,
                modelName: settings.openAIEmbeddingModel
            )
            
        case .custom:
            return GenericAPIEmbeddingProvider(
                dimensions: settings.customEmbeddingModel.contains("mxbai") ? 1024 : 768, 
                endpointURL: URL(string: settings.customEmbeddingEndpoint)!,
                apiKey: settings.customApiKey,
                modelName: settings.customEmbeddingModel
            )
            
        default:
            return LocalEmbeddingProvider()
        }
    }
    
    // MARK: - Database Management
    
    private func setupDatabase() {
         guard currentProjectDir != nil else {
            print("Standalone mode active: Aborting vector database setup.")
            return
        }
        
        if let folderURL = cacheFolderURL, AISettingsManager.shared.cacheEmbeddingsToDisk {
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
            }
        }
        
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        
        // Use :memory: if dbFileURL is nil (though our guard above makes this safer)
        let dbPath = dbFileURL?.path ?? ":memory:"
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open vector DB.")
            return
        }
        
        sqlite3_enable_load_extension(db, 1)
        var errMsg: UnsafeMutablePointer<Int8>?
        // Compute path relative to the executable directory (Contents/MacOS/) where
        // the bundle scripts copy vector.framework. This matches the @loader_path rpath
        // that dyld already uses, so no install_name_tool rpath manipulation is needed.
        let execDir = Bundle.main.executableURL?.deletingLastPathComponent().path ?? ""
        let vectorExtPath = "\(execDir)/vector.framework/vector"
        if sqlite3_load_extension(db, vectorExtPath, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg != nil ? String(cString: errMsg!) : "Unknown error"
            print("Failed to load sqlite-vector: \(msg)")
            sqlite3_free(errMsg)
        }
        
        let createSQL = """
        CREATE TABLE IF NOT EXISTS files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE,
            last_modified REAL
        );
        CREATE TABLE IF NOT EXISTS chunks (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id INTEGER,
            text TEXT,
            embedding BLOB,
            FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
        );
        """
        
        if sqlite3_exec(db, createSQL, nil, nil, &errMsg) != SQLITE_OK {
            print("Failed to create tables: \(String(cString: errMsg!))")
            sqlite3_free(errMsg)
        }
        
        let provider = activeProvider
        let initVectorSQL = "SELECT vector_init('chunks', 'embedding', 'type=FLOAT32,dimension=\(provider.dimensions),distance=COSINE');"
        sqlite3_exec(db, initVectorSQL, nil, nil, nil)
        
        sqlite3_exec(db, "SELECT vector_quantize_preload('chunks', 'embedding');", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
    }
    // MARK: - Standalone Mode Management
    
    /// Completely disables the RAG Manager and closes any active DB connections for standalone editing.
    public func disableForStandaloneMode() {
        self.currentProjectDir = nil
        
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        
        // Reset any indexing state just in case it was interrupted
        isIndexing = false
        indexProgress = 0.0
        indexStatus = ""
        
        print("RAGManager: Vector DB locked out and closed for standalone mode.")
    }
    
    public func clearIndexCache() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
        
        if let fileURL = dbFileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
            print("Project vector db cleared successfully.")
        } else {
            print("In-memory vector db cleared successfully.")
        }
    }
    
    // MARK: - Indexing
    
    func indexProject(at projectDir: URL, forceReindex: Bool = false) async {
        let isDirectory = (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else {
            print("RAGManager: Aborting index. Provided URL is a standalone file, not a directory.")
            return
        }

        guard !isIndexing else { return }
        isIndexing = true
        indexProgress = 0.0
        indexStatus = "Gathering files..."
        
        defer { 
            isIndexing = false 
            indexStatus = ""
            indexProgress = 0.0
        }
        
        self.currentProjectDir = projectDir
        
        if forceReindex {
            clearIndexCache()
        }
        
        setupDatabase()
        guard let db = db else { return }
        
        let cleanupSQL = "SELECT id, path FROM files;"
        var cleanupStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, cleanupSQL, -1, &cleanupStmt, nil) == SQLITE_OK {
            var idsToDelete: [Int64] = []
            while sqlite3_step(cleanupStmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(cleanupStmt, 0)
                let path = String(cString: sqlite3_column_text(cleanupStmt, 1))
                let fullURL = projectDir.appendingPathComponent(path)
                
                if !FileManager.default.fileExists(atPath: fullURL.path) {
                    idsToDelete.append(id)
                }
            }
            sqlite3_finalize(cleanupStmt)
            
            if !idsToDelete.isEmpty {
                sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
                for id in idsToDelete {
                    let delSQL = "DELETE FROM files WHERE id = \(id);"
                    sqlite3_exec(db, delSQL, nil, nil, nil)
                }
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                print("Cleaned up \(idsToDelete.count) deleted files from vector DB.")
            }
        }
        
        let provider = activeProvider
        let filesToProcess = gatherFiles(in: projectDir)
        var cacheUpdated = false
        
        let totalFiles = filesToProcess.count
        guard totalFiles > 0 else { return }
        
        for (index, fileURL) in filesToProcess.enumerated() {
            guard isIndexing else { break }
            
            self.indexProgress = Double(index) / Double(totalFiles)
            self.indexStatus = "Indexing \(fileURL.lastPathComponent)..."
            
            let ext = fileURL.pathExtension.lowercased()
            let attributes = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let lastModifiedDate = attributes?.contentModificationDate else { continue }
            let lastModified = lastModifiedDate.timeIntervalSince1970
            
            let fileKey = fileURL.path.replacingOccurrences(of: projectDir.path + "/", with: "")
            
            var needsIndexing = true
            var fileId: Int64 = -1
            
            let checkSQL = "SELECT id, last_modified FROM files WHERE path = ?;"
            var checkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, checkSQL, -1, &checkStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(checkStmt, 1, (fileKey as NSString).utf8String, -1, nil)
                if sqlite3_step(checkStmt) == SQLITE_ROW {
                    fileId = sqlite3_column_int64(checkStmt, 0)
                    let storedModified = sqlite3_column_double(checkStmt, 1)
                    if storedModified >= lastModified {
                        needsIndexing = false
                    }
                }
            }
            sqlite3_finalize(checkStmt)
            
            if !needsIndexing { continue }
            
            var extractedTextChunks: [String] = []
            
            let plaintextExtensions = ["typ", "md", "bib", "txt", "csv", "yaml", "yml"]
            if plaintextExtensions.contains(ext) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    extractedTextChunks = content.components(separatedBy: "\n\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.count > 50 }
                }
            } else if ext == "json" {
               if let data = try? Data(contentsOf: fileURL),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    extractedTextChunks = extractSemanticChunks(
                        from: json, 
                        fileName: fileURL.lastPathComponent
                    )
                }
            }
            
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            
            if fileId != -1 {
                let delSQL = "DELETE FROM files WHERE id = \(fileId);"
                sqlite3_exec(db, delSQL, nil, nil, nil)
            }
            
            let insertFileSQL = "INSERT INTO files (path, last_modified) VALUES (?, ?);"
            var insertFileStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, insertFileSQL, -1, &insertFileStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(insertFileStmt, 1, (fileKey as NSString).utf8String, -1, nil)
                sqlite3_bind_double(insertFileStmt, 2, lastModified)
                if sqlite3_step(insertFileStmt) == SQLITE_DONE {
                    fileId = sqlite3_last_insert_rowid(db)
                }
            }
            sqlite3_finalize(insertFileStmt)
            
            let insertChunkSQL = "INSERT INTO chunks (file_id, text, embedding) VALUES (?, ?, ?);"
            var insertChunkStmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertChunkSQL, -1, &insertChunkStmt, nil)
            
            for textChunk in extractedTextChunks {
                do {
                    let vector = try await provider.getEmbedding(for: textChunk)
                    sqlite3_bind_int64(insertChunkStmt, 1, fileId)
                    sqlite3_bind_text(insertChunkStmt, 2, (textChunk as NSString).utf8String, -1, nil)
                    
                    let vectorData = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    _ = vectorData.withUnsafeBytes { rawBuffer in
                        sqlite3_bind_blob(insertChunkStmt, 3, rawBuffer.baseAddress, Int32(rawBuffer.count), nil)
                    }
                    
                    sqlite3_step(insertChunkStmt)
                    sqlite3_reset(insertChunkStmt)
                } catch {
                    print("[RAG Error] Failed to embed chunk in \(fileURL.lastPathComponent): \(error)")
                }
            }
            sqlite3_finalize(insertChunkStmt)
            
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            cacheUpdated = true
        }
        
        if isIndexing {
            self.indexProgress = 1.0
            self.indexStatus = "Finishing up..."
            
            if cacheUpdated {
                print("Local project vector db updated successfully.")
                // Build a TurboQuant index to significantly speed up searches
                sqlite3_exec(db, "SELECT vector_quantize('chunks', 'embedding', 'qtype=TURBO');", nil, nil, nil)
            } else {
                print("Using cached embeddings from local vectorcaches folder.")
            }
        }
    }

    private func gatherFiles(in projectDir: URL) -> [URL] {
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        
        var validFiles: [URL] = []
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            
            if isDirectory && filename == "vectorcaches" {
                enumerator.skipDescendants()
                continue
            }
            
            if isDirectory { continue }
            
            if let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, fileSize > 2 * 1024 * 1024 {
                continue
            }
            
            let ext = fileURL.pathExtension.lowercased()
            let allowedExtensions = ["typ", "md", "json", "bib", "txt", "csv", "yaml", "yml"]
            if allowedExtensions.contains(ext) {
                validFiles.append(fileURL)
            }
        }
        
        return validFiles
    }
    
    // MARK: - Searching
    
    func search(query: String, topK: Int = 3) async -> [DocumentChunk] {
        guard let db = db, let currentProjectDir = currentProjectDir else { return [] }
        
        do {
            let queryVector = try await activeProvider.getEmbedding(for: query)
            let vectorData = queryVector.withUnsafeBufferPointer { Data(buffer: $0) }
            
             // Use vector_quantize_scan for SIMD-accelerated approximate nearest neighbor search
            var searchSQL = """
            SELECT c.text, f.path, c.embedding, v.distance 
            FROM chunks AS c 
            JOIN files AS f ON c.file_id = f.id
            JOIN vector_quantize_scan('chunks', 'embedding', ?, ?) AS v 
            ON c.id = v.rowid
            ORDER BY v.distance ASC;
            """
            
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, searchSQL, -1, &stmt, nil) != SQLITE_OK {
                // Fallback to brute-force full scan if quantization index isn't built yet
                searchSQL = """
                SELECT c.text, f.path, c.embedding, v.distance 
                FROM chunks AS c 
                JOIN files AS f ON c.file_id = f.id
                JOIN vector_full_scan('chunks', 'embedding', ?, ?) AS v 
                ON c.id = v.rowid
                ORDER BY v.distance ASC;
                """
                if sqlite3_prepare_v2(db, searchSQL, -1, &stmt, nil) != SQLITE_OK {
                    let err = String(cString: sqlite3_errmsg(db))
                    print("Search query prepare failed: \(err)")
                    return []
                }
            }
            
            _ = vectorData.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 1, rawBuffer.baseAddress, Int32(rawBuffer.count), nil)
            }
            sqlite3_bind_int64(stmt, 2, Int64(topK))
            
            var results: [DocumentChunk] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let text = String(cString: sqlite3_column_text(stmt, 0))
                let path = String(cString: sqlite3_column_text(stmt, 1))
                let embeddingBytes = sqlite3_column_blob(stmt, 2)
                let embeddingLen = sqlite3_column_bytes(stmt, 2)
                
                var embedding: [Float] = []
                if let embeddingBytes = embeddingBytes, embeddingLen > 0 {
                    let floatCount = Int(embeddingLen) / MemoryLayout<Float>.size
                    let pointer = embeddingBytes.bindMemory(to: Float.self, capacity: floatCount)
                    embedding = Array(UnsafeBufferPointer(start: pointer, count: floatCount))
                }
                
                let fileURL = currentProjectDir.appendingPathComponent(path)
                results.append(DocumentChunk(fileURL: fileURL, text: text, embedding: embedding))
            }
            
            sqlite3_finalize(stmt)
            return results
        } catch {
            print("Search failed: \(error)")
            return []
        }
    }
    
    // MARK: - Helpers
    
    private func flattenJSON(_ json: Any, prefix: String = "") -> [String] {
        var result: [String] = []
        
        if let dict = json as? [String: Any] {
            for (key, value) in dict {
                let newPrefix = prefix.isEmpty ? key : "\(prefix) > \(key)"
                result.append(contentsOf: flattenJSON(value, prefix: newPrefix))
            }
        } else if let array = json as? [Any] {
            for (index, value) in array.enumerated() {
                let newPrefix = "\(prefix) [\(index)]"
                result.append(contentsOf: flattenJSON(value, prefix: newPrefix))
            }
        } else if let str = json as? String {
            if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append("\(prefix): \(str)")
            }
        } else {
            result.append("\(prefix): \(json)")
        }
        
        return result
    }

    private func extractSemanticChunks(from json: Any, path: String = "", parentMetadata: String = "", fileName: String) -> [String] {
        var chunks: [String] = []
        
        if let dict = json as? [String: Any] {
            var localMetadata = parentMetadata
            
            for (key, value) in dict {
                if let str = value as? String, str.count < 50 {
                    localMetadata += "\(key.capitalized): \(str), "
                } else if let num = value as? NSNumber {
                    localMetadata += "\(key.capitalized): \(num), "
                } else if let bool = value as? Bool {
                    localMetadata += "\(key.capitalized): \(bool), "
                }
            }
            
            for (key, value) in dict {
                let currentPath = path.isEmpty ? key : "\(path) > \(key)"
                
                if let str = value as? String, str.count >= 50 {
                    let cleanText = str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    let chunk = "Source: \(fileName) | Path: \(currentPath)\nContext: \(localMetadata)\nContent: \(cleanText)"
                    chunks.append(chunk)
                } else if let nestedDict = value as? [String: Any] {
                    chunks.append(contentsOf: extractSemanticChunks(from: nestedDict, path: currentPath, parentMetadata: localMetadata, fileName: fileName))
                } else if let nestedArray = value as? [Any] {
                    chunks.append(contentsOf: extractSemanticChunks(from: nestedArray, path: currentPath, parentMetadata: localMetadata, fileName: fileName))
                }
            }
        } else if let array = json as? [Any] {
            for (index, value) in array.enumerated() {
                let currentPath = "\(path)[\(index)]"
                chunks.append(contentsOf: extractSemanticChunks(from: value, path: currentPath, parentMetadata: parentMetadata, fileName: fileName))
            }
        } else if let str = json as? String, str.count >= 50 {
            let cleanText = str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let chunk = "Source: \(fileName) | Path: \(path)\nContext: \(parentMetadata)\nContent: \(cleanText)"
            chunks.append(chunk)
        }
        
        return chunks
    }

    private func chunkStrings(_ strings: [String], maxChunkSize: Int) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""
        
        for string in strings {
            if currentChunk.count + string.count > maxChunkSize {
                chunks.append(currentChunk)
                currentChunk = ""
            }
            currentChunk += string + "\n"
        }
        if !currentChunk.isEmpty { chunks.append(currentChunk) }
        return chunks
    }
}