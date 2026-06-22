import Foundation
import NaturalLanguage
import Accelerate

// MARK: - Core Data Models
struct DocumentChunk {
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
    private var projectChunks: [DocumentChunk] = []
    
    private init() {}
    
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
                // Tip: nomic-embed-text is usually 768, mxbai-embed-large is 1024
                dimensions: settings.customEmbeddingModel.contains("mxbai") ? 1024 : 768, 
                endpointURL: URL(string: settings.customEmbeddingEndpoint)!,
                apiKey: settings.customApiKey,
                modelName: settings.customEmbeddingModel
            )
            
        default:
            return LocalEmbeddingProvider()
        }
    }
        
    /// Indexes the entire project directory
    func indexProject(at projectDir: URL) async {
        isIndexing = true
        defer { isIndexing = false }
        
        var newChunks: [DocumentChunk] = []
        let provider = activeProvider
        
        guard let files = try? FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil) else { return }
        
        for file in files where file.pathExtension == "typ" {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { continue }
            
            // Basic Chunking: Split by double newline (paragraphs)
            let paragraphs = content.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count > 50 } // Ignore tiny fragments
            
            for paragraph in paragraphs {
                do {
                    let vector = try await provider.getEmbedding(for: paragraph)
                    newChunks.append(DocumentChunk(fileURL: file, text: paragraph, embedding: vector))
                } catch {
                    print("Failed to embed chunk in \(file.lastPathComponent): \(error)")
                }
            }
        }
        
        self.projectChunks = newChunks
        print("Indexed \(newChunks.count) chunks for the project.")
    }
    
    /// Searches for the most relevant chunks using Cosine Similarity
    func search(query: String, topK: Int = 3) async -> [DocumentChunk] {
        guard !projectChunks.isEmpty else { return [] }
        
        do {
            let queryVector = try await activeProvider.getEmbedding(for: query)
            
            // Score all chunks
            let scoredChunks = projectChunks.map { chunk -> (DocumentChunk, Float) in
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
}