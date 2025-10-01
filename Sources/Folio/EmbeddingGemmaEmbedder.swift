import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch

/// Adapter for running EmbeddingGemma through an OpenAI-compatible `/v1/embeddings` endpoint.
///
/// This is designed for on-device runtimes (e.g. Ollama, llama.cpp bridges) that expose
/// Gemma via an OpenAI-style API. Folio uses the adapter to backfill chunk vectors so that
/// BM25 and cosine scorers operate on the same augmented text (`prefix + chunk`).
public struct EmbeddingGemmaEmbedder: Embedder {
    public struct Configuration: Sendable {
        /// Base URL for the embeddings service. Defaults to Ollama on localhost.
        public var baseURL: URL
        /// Model identifier understood by the runtime (e.g. "gemma:2b").
        public var model: String
        /// Optional API key forwarded as a bearer token.
        public var apiKey: String?
        /// Request timeout in seconds.
        public var timeout: TimeInterval
        /// Optionally request a specific encoding format if the runtime supports it.
        public var encodingFormat: EncodingFormat?

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
            model: String = "gemma:2b",
            apiKey: String? = nil,
            timeout: TimeInterval = 60,
            encodingFormat: EncodingFormat? = nil
        ) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
            self.timeout = timeout
            self.encodingFormat = encodingFormat
        }
    }

    public enum EncodingFormat: String, Sendable {
        case float
        case base64
    }

    private let config: Configuration
    private let session: URLSession

    public init(configuration: Configuration = .init(), session: URLSession = .shared) {
        self.config = configuration
        self.session = session
    }

    public func embed(_ text: String) throws -> [Float] {
        try embedBatch([text]).first ?? []
    }

    public func embedBatch(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var request = URLRequest(url: endpointURL())
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(
            model: config.model,
            input: texts,
            encodingFormat: config.encodingFormat?.rawValue
        ))

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(NSError(
                    domain: "Folio",
                    code: 520,
                    userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma empty response"]
                ))
            }
        }

        task.resume()

        if semaphore.wait(timeout: .now() + config.timeout) == .timedOut {
            task.cancel()
            throw NSError(
                domain: "Folio",
                code: 521,
                userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma request timed out"]
            )
        }

        guard let outcome = result else {
            throw NSError(
                domain: "Folio",
                code: 522,
                userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma result missing"]
            )
        }

        let (data, response) = try outcome.get()
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "Folio",
                code: 523,
                userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma invalid response"]
            )
        }

        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw NSError(
                    domain: "Folio",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: apiError.error.message]
                )
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "Folio",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma server error: \(text)"]
            )
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        guard decoded.data.count == texts.count else {
            throw NSError(
                domain: "Folio",
                code: 524,
                userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma count mismatch"]
            )
        }

        let sorted = decoded.data.sorted { $0.index < $1.index }
        return try sorted.map { try $0.vector(using: config.encodingFormat) }
    }

    private func endpointURL() -> URL {
        let components = config.baseURL.pathComponents
        if components.contains("embeddings") {
            return config.baseURL
        }

        if components.contains("v1") {
            return config.baseURL.appendingPathComponent("embeddings")
        }

        return config.baseURL
            .appendingPathComponent("v1", isDirectory: false)
            .appendingPathComponent("embeddings", isDirectory: false)
    }
}

private struct EmbeddingRequest: Encodable {
    let model: String
    let input: [String]
    let encodingFormat: String?

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case encodingFormat = "encoding_format"
    }
}

private struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let object: String?
        let embedding: EmbeddingValue
        let index: Int

        func vector(using format: EmbeddingGemmaEmbedder.EncodingFormat?) throws -> [Float] {
            switch (format, embedding) {
            case (_, .floats(let values)):
                return values.map { Float($0) }
            case (.base64?, .base64(let string)):
                return try decodeBase64Vector(string)
            case (nil, .base64(let string)):
                // Some runtimes default to base64 without advertising it.
                return try decodeBase64Vector(string)
            case (.float?, .base64(let string)):
                // Caller requested floats but runtime returned base64; decode anyway to avoid data loss.
                return try decodeBase64Vector(string)
            case (.base64?, .floats(let values)):
                return values.map { Float($0) }
            }
        }

        private func decodeBase64Vector(_ string: String) throws -> [Float] {
            guard let data = Data(base64Encoded: string) else {
                throw NSError(
                    domain: "Folio",
                    code: 525,
                    userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma invalid base64 vector"]
                )
            }
            let count = data.count / MemoryLayout<Float>.size
            var floats = [Float](repeating: 0, count: count)
            _ = floats.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return floats
        }
    }

    enum EmbeddingValue: Decodable {
        case floats([Double])
        case base64(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let values = try? container.decode([Double].self) {
                self = .floats(values)
            } else if let string = try? container.decode(String.self) {
                self = .base64(string)
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported embedding payload")
            }
        }
    }

    let data: [Item]
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
