import Foundation
import NaturalLanguage
import Accelerate

// MARK: - Core Data Models
// MARK: - Core Data Models
struct DocumentChunk: Codable {
    let fileURL: URL
    let text: String
    let embedding: [Float]
    
    enum CodingKeys: String, CodingKey {
        case fileURL
        case text
        case embedding
    }
    
    // Normal initializer used during indexing
    init(fileURL: URL, text: String, embedding: [Float]) {
        self.fileURL = fileURL
        self.text = text
        self.embedding = embedding
    }
    
    // Custom Decoder: Base64 String -> Raw Bytes -> [Float]
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fileURL = try container.decode(URL.self, forKey: .fileURL)
        self.text = try container.decode(String.self, forKey: .text)
        
        // Decode the Base64 string back into binary data
        let data = try container.decode(Data.self, forKey: .embedding)
        
        // Safely bind the raw memory bytes back into an array of Floats
        self.embedding = data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
    
    // Custom Encoder: [Float] -> Raw Bytes -> Base64 String
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(text, forKey: .text)
        
        // Convert the Float array directly into binary Data
        let data = embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
        
        // JSONEncoder automatically converts Data into a Base64 string
        try container.encode(data, forKey: .embedding)
    }
}
struct FileIndex: Codable {
    let lastModified: Date
    let chunks: [DocumentChunk]
}

struct ProjectIndex: Codable {
    // Key is the relative file path or file URL string
    var files: [String: FileIndex] = [:]
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
        
        // Ollama ignores the Bearer token, but OpenAI requires it. 
        // Sending it always is safe for both.
        if !apiKey.isEmpty {
            request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Both OpenAI and Ollama's /v1/embeddings accept this exact body
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
        
        // Parse the OpenAI-compatible JSON response
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
    
    private var projectIndex = ProjectIndex()
    private var currentProjectDir: URL?
    
    private init() {}
    
    // MARK: - Path Configuration
    
    // Define the path to the project's local 'vectorcaches' folder
    private var cacheFolderURL: URL? {
        currentProjectDir?.appendingPathComponent("vectorcaches", isDirectory: true)
    }
    
    // Store the JSON index cache file inside that specific folder
    private var cacheFileURL: URL? {
        cacheFolderURL?.appendingPathComponent("project_index_cache.json")
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
    
    // MARK: - Cache Management
    
    /// Loads the cache from the local project's vectorcaches directory
    private func loadCache() {
        guard let cacheURL = cacheFileURL,
              FileManager.default.fileExists(atPath: cacheURL.path),
              let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(ProjectIndex.self, from: data) else {
            projectIndex = ProjectIndex()
            return
        }
        projectIndex = decoded
    }
    
    /// Saves the cache and ensures the 'vectorcaches' folder exists
    private func saveCache() {
        guard let folderURL = cacheFolderURL, let fileURL = cacheFileURL else { return }
        
        do {
            if !FileManager.default.fileExists(atPath: folderURL.path) {
                try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true, attributes: nil)
            }
            
            let data = try JSONEncoder().encode(projectIndex)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save vector cache locally: \(error.localizedDescription)")
        }
    }
    
    /// Clears the project index memory profile and removes the files from disk
    public func clearIndexCache() {
        projectIndex = ProjectIndex()
        guard let fileURL = cacheFileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
        print("Project vector cache cleared successfully.")
    }
    
    // MARK: - Indexing
    
    /// Indexes the entire project directory intelligently, including subdirectories
    func indexProject(at projectDir: URL, forceReindex: Bool = false) async {
        guard !isIndexing else { return } // Prevent duplicate runs
        isIndexing = true
        indexProgress = 0.0
        indexStatus = "Gathering files..."
        
        defer { 
            isIndexing = false 
            indexStatus = ""
            indexProgress = 0.0
        }
        
        self.currentProjectDir = projectDir
        
        // If the user clicked the manual force button, wipe the cache first
        if forceReindex {
            clearIndexCache()
        }
        
        loadCache() // Reads existing index from project_dir/vectorcaches/
        
        let provider = activeProvider
        let filesToProcess = gatherFiles(in: projectDir)
        var cacheUpdated = false
        
        let totalFiles = filesToProcess.count
        guard totalFiles > 0 else { return }
        
        for (index, fileURL) in filesToProcess.enumerated() {
            // 👉 CANCEL CHECK: If the user hit the stop button, break the loop
            guard isIndexing else { break }
            
            // Update UI Progress
            self.indexProgress = Double(index) / Double(totalFiles)
            self.indexStatus = "Indexing \(fileURL.lastPathComponent)..."
            
            let ext = fileURL.pathExtension.lowercased()
            let attributes = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let lastModified = attributes?.contentModificationDate else { continue }
            
            let fileKey = fileURL.path.replacingOccurrences(of: projectDir.path + "/", with: "")
            
            // Skip if file hasn't changed since last build
            if let existingIndex = projectIndex.files[fileKey], existingIndex.lastModified >= lastModified {
                continue
            }
            
            var extractedTextChunks: [String] = []
            
            if ext == "typ" || ext == "md" {
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
            
            var newChunks: [DocumentChunk] = []
            for textChunk in extractedTextChunks {
                do {
                    let vector = try await provider.getEmbedding(for: textChunk)
                    newChunks.append(DocumentChunk(fileURL: fileURL, text: textChunk, embedding: vector))
                } catch {
                    print("[RAG Error] Failed to embed chunk in \(fileURL.lastPathComponent): \(error)")
                }
            }
            
            projectIndex.files[fileKey] = FileIndex(lastModified: lastModified, chunks: newChunks)
            cacheUpdated = true
            
            // 👉 INCREMENTAL SAVE: Write to disk immediately after finishing this file!
            saveCache()
        }
        
        // Only show completion if it wasn't cancelled
        if isIndexing {
            self.indexProgress = 1.0
            self.indexStatus = "Finishing up..."
            
            if cacheUpdated {
                print("Local project vectorcache updated successfully.")
            } else {
                print("Using cached embeddings from local vectorcaches folder.")
            }
        }
    }
    /// Synchronously crawls the directory to find target files
    private func gatherFiles(in projectDir: URL) -> [URL] {
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: projectDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles] // Automatically skips .git, .DS_Store, etc.
        ) else { return [] }
        
        var validFiles: [URL] = []
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            
            // CRITICAL GUARD: Skip the local vectorcaches folder entirely
            if isDirectory && filename == "vectorcaches" {
                enumerator.skipDescendants() // Stops the enumerator from diving into this folder
                continue
            }
            
            if isDirectory { continue }
            
            let ext = fileURL.pathExtension.lowercased()
            if ext == "typ" || ext == "md" || ext == "json" {
                validFiles.append(fileURL)
            }
        }
        
        return validFiles
    }
    
    // MARK: - Searching
    
    /// Searches for the most relevant chunks using Cosine Similarity
    func search(query: String, topK: Int = 3) async -> [DocumentChunk] {
        // Flatten the dictionary into a single array of chunks to search
        let allChunks = projectIndex.files.values.flatMap { $0.chunks }
        guard !allChunks.isEmpty else { return [] }
        
        do {
            let queryVector = try await activeProvider.getEmbedding(for: query)
            
            // Score all chunks
            let scoredChunks = allChunks.map { chunk -> (DocumentChunk, Float) in
                let score = cosineSimilarity(a: queryVector, b: chunk.embedding)
                return (chunk, score)
            }
            
            // Sort descending and take top K
            let topMatches = scoredChunks
                .sorted { $0.1 > $1.1 }
                .prefix(topK)
                .map { $0.0 }
            
            return Array(topMatches)
        } catch {
            print("Search failed: \(error)")
            return []
        }
    }
    
    // MARK: - Helpers
    
    /// Lightning-fast vector math using Apple's Accelerate framework
    private func cosineSimilarity(a: [Float], b: [Float]) -> Float {
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        guard normA > 0 && normB > 0 else { return 0 }
        return dotProduct / (sqrt(normA) * sqrt(normB))
    }

    /// Generic recursive JSON Flattener 
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
            // Only embed strings that have actual semantic value (ignore empty strings)
            if !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append("\(prefix): \(str)")
            }
        } else {
            // Base case: Number, Boolean
            result.append("\(prefix): \(json)")
        }
        
        return result
    }

// MARK: - Dynamic JSON Parsing
    
    /// Crawls any arbitrary JSON structure, accumulating short metadata to enrich large text blocks.
    private func extractSemanticChunks(from json: Any, path: String = "", parentMetadata: String = "", fileName: String) -> [String] {
        var chunks: [String] = []
        
        if let dict = json as? [String: Any] {
            var localMetadata = parentMetadata
            
            // First pass: Gather local metadata (keys with numbers, bools, or short strings)
            for (key, value) in dict {
                if let str = value as? String, str.count < 50 {
                    localMetadata += "\(key.capitalized): \(str), "
                } else if let num = value as? NSNumber {
                    localMetadata += "\(key.capitalized): \(num), "
                } else if let bool = value as? Bool {
                    localMetadata += "\(key.capitalized): \(bool), "
                }
            }
            
            // Second pass: Process long strings and nested objects
            for (key, value) in dict {
                let currentPath = path.isEmpty ? key : "\(path) > \(key)"
                
                if let str = value as? String, str.count >= 50 {
                    // This is a main content block! Combine it with the gathered metadata.
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
            // Handle arrays by passing the context down to each item
            for (index, value) in array.enumerated() {
                let currentPath = "\(path)[\(index)]"
                chunks.append(contentsOf: extractSemanticChunks(from: value, path: currentPath, parentMetadata: parentMetadata, fileName: fileName))
            }
        } else if let str = json as? String, str.count >= 50 {
            // Handle raw strings sitting in arrays or at the root
            let cleanText = str.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let chunk = "Source: \(fileName) | Path: \(path)\nContext: \(parentMetadata)\nContent: \(cleanText)"
            chunks.append(chunk)
        }
        
        return chunks
    }

    /// Helper to bundle flattened JSON lines into larger semantic chunks
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