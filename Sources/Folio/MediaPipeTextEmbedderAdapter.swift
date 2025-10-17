#if canImport(MediaPipeTasksText)
import Foundation
import MediaPipeTasksText

/// Adapter that bridges MediaPipe's `TextEmbedder` to Folio's `Embedder` protocol.
///
/// This makes it easy to plug on-device Embedding Gemma models (distributed as
/// MediaPipe text embedders) directly into Folio's ingestion and hybrid search
/// pipeline.
public final class MediaPipeTextEmbedderAdapter: Embedder {
    private let embedder: TextEmbedder
    private let queue: DispatchQueue

    /// Creates an adapter around a configured MediaPipe `TextEmbedder` instance.
    /// - Parameter embedder: The underlying MediaPipe text embedder to delegate to.
    /// - Parameter label: Optional label used when serialising calls to the embedder.
    public init(embedder: TextEmbedder, label: String = "Folio.MediaPipeTextEmbedderAdapter") {
        self.embedder = embedder
        self.queue = DispatchQueue(label: label)
    }

    public func embed(_ text: String) throws -> [Float] {
        try queue.sync {
            let result = try embedder.embed(text: text)
            return try Self.vector(from: result)
        }
    }

    public func embedBatch(_ texts: [String]) throws -> [[Float]] {
        try queue.sync {
            try texts.map { text in
                let result = try embedder.embed(text: text)
                return try Self.vector(from: result)
            }
        }
    }

    private static func vector(from result: TextEmbedderResult) throws -> [Float] {
        guard let embedding = result.embeddingResult.embeddings.first else {
            throw NSError(
                domain: "Folio",
                code: 532,
                userInfo: [NSLocalizedDescriptionKey: "TextEmbedder returned no embeddings"]
            )
        }

        if let floats = values(from: embedding, key: "floatEmbedding") {
            return floats
        }

        if let quantized = values(from: embedding, key: "quantizedEmbedding") {
            return quantized
        }

        throw NSError(
            domain: "Folio",
            code: 533,
            userInfo: [NSLocalizedDescriptionKey: "TextEmbedder embedding missing vector payload"]
        )
    }

    private static func values(from embedding: Any, key: String) -> [Float]? {
        guard let object = embedding as AnyObject? else { return nil }

        if let numbers = object.value(forKey: key) as? [NSNumber] {
            return numbers.map { $0.floatValue }
        }

        if let floats = object.value(forKey: key) as? [Float] {
            return floats
        }

        if let doubles = object.value(forKey: key) as? [Double] {
            return doubles.map(Float.init)
        }

        if let bytes = object.value(forKey: key) as? [UInt8] {
            return bytes.map { Float($0) }
        }

        if let data = object.value(forKey: key) as? Data {
            return Array(data).map { Float($0) }
        }

        return nil
    }
}

extension MediaPipeTextEmbedderAdapter: @unchecked Sendable {}
#endif
