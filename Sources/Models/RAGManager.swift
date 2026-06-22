import Foundation
import NaturalLanguage
import Accelerate

// MARK: - Core Data Models
struct DocumentChunk: Codable {
    let fileURL: URL
    let text: String
    let embedding: [Float]
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
    func indexProject(at projectDir: URL) async {
        isIndexing = true
        defer { isIndexing = false }
        
        self.currentProjectDir = projectDir
        loadCache() // Reads existing index from project_dir/vectorcaches/
        
        let provider = activeProvider
        
        // 1. Gather files synchronously to satisfy Swift Concurrency rules
        let filesToProcess = gatherFiles(in: projectDir)
        var cacheUpdated = false
        
        // 2. Process them asynchronously
        for fileURL in filesToProcess {
            let ext = fileURL.pathExtension.lowercased()
            
            // Get the file's current modification date
            let attributes = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let lastModified = attributes?.contentModificationDate else { continue }
            
            // Use the relative path as the cache key
            let fileKey = fileURL.path.replacingOccurrences(of: projectDir.path + "/", with: "")
            
            // Skip if file hasn't changed since last build
            if let existingIndex = projectIndex.files[fileKey], existingIndex.lastModified >= lastModified {
                continue
            }
            
            // --- DATA INGESTION & FLATTENING ---
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
                    let flattenedLines = flattenJSON(json)
                    extractedTextChunks = chunkStrings(flattenedLines, maxChunkSize: 400)
                }
            }
            
           // --- EMBEDDING GENERATION ---
            var newChunks: [DocumentChunk] = []
            for textChunk in extractedTextChunks {
                do {
                    // Try to get the embedding
                    let vector = try await provider.getEmbedding(for: textChunk)
                    newChunks.append(DocumentChunk(fileURL: fileURL, text: textChunk, embedding: vector))
                } catch {
                    // 👉 NEW: Print exactly why Ollama failed
                    print("[RAG Error] Failed to embed chunk in \(fileURL.lastPathComponent): \(error)")
                }
            }
            
            projectIndex.files[fileKey] = FileIndex(lastModified: lastModified, chunks: newChunks)
            cacheUpdated = true
        }
        
        if cacheUpdated {
            saveCache() // Writes index and creates directory structure cleanly
            print("Local project vectorcache updated successfully.")
        } else {
            print("Using cached embeddings from local vectorcaches folder.")
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