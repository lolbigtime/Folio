import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch

/// Talks to Google’s EmbeddingGemma endpoints described in
/// https://developers.googleblog.com/en/introducing-embeddinggemma/ via the Generative Language API.
/// The adapter batches requests with `batchEmbedContents` so Folio can hydrate vectors quickly.
public struct EmbeddingGemmaEmbedder: Embedder {
    public struct Configuration: Sendable {
        /// API key issued by Google AI Studio / Generative Language API.
        public let apiKey: String
        /// Fully-qualified model identifier (e.g. "models/embedding-gemma-002").
        public let model: String
        /// Base endpoint for the Generative Language API. Defaults to googleapis.com.
        public let baseURL: URL
        /// Optional Matryoshka output dimensionality (768 default, 512/256/128 supported by EmbeddingGemma).
        public let outputDimensionality: Int?
        /// Request timeout.
        public let timeout: TimeInterval

        public init(
            apiKey: String,
            model: String,
            baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/")!,
            outputDimensionality: Int? = nil,
            timeout: TimeInterval = 60
        ) {
            self.apiKey = apiKey
            self.model = model
            self.baseURL = baseURL
            self.outputDimensionality = outputDimensionality
            self.timeout = timeout
        }
    }

    private let config: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession = .shared) {
        self.config = configuration
        self.session = session
    }

    public func embed(_ text: String) throws -> [Float] {
        try embedBatch([text]).first ?? []
    }

    public func embedBatch(_ texts: [String]) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let endpointPath = "v1beta/\(config.model):batchEmbedContents"
        guard let endpoint = URL(string: endpointPath, relativeTo: config.baseURL) else {
            throw NSError(domain: "Folio", code: 430, userInfo: [NSLocalizedDescriptionKey: "Invalid EmbeddingGemma endpoint"])
        }

        let payload = BatchEmbedRequest(
            requests: texts.map { text in
                BatchEmbedRequest.Request(
                    model: config.model,
                    content: .init(parts: [.init(text: text)]),
                    config: config.outputDimensionality.map { .init(outputDimensionality: $0) }
                )
            }
        )

        let data = try performRequest(url: endpoint, body: payload)
        let decoder = JSONDecoder()
        let response = try decoder.decode(BatchEmbedResponse.self, from: data)

        guard response.embeddings.count == texts.count else {
            throw NSError(domain: "Folio", code: 431, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma returned unexpected count"])
        }

        return try response.embeddings.map { embedding in
            guard let values = embedding.values else {
                throw NSError(domain: "Folio", code: 432, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma response missing values"])
            }
            return values.map { Float($0) }
        }
    }

    private func performRequest<Body: Encodable>(url: URL, body: Body) throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = config.timeout
        request.httpBody = try JSONEncoder().encode(body)

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(NSError(domain: "Folio", code: 433, userInfo: [NSLocalizedDescriptionKey: "Empty EmbeddingGemma response"]))
            }
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + config.timeout)
        if waitResult == .timedOut {
            task.cancel()
            throw NSError(domain: "Folio", code: 434, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma request timed out"])
        }

        guard let result else {
            throw NSError(domain: "Folio", code: 435, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma missing result"])
        }

        let (data, response) = try result.get()
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 436, userInfo: [NSLocalizedDescriptionKey: "Invalid EmbeddingGemma HTTP response"])
        }

        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
                let message = apiError.error.message
                throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma error: \(message)"])
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma HTTP \(http.statusCode): \(body)"])
        }

        return data
    }
}

private struct BatchEmbedRequest: Encodable {
    struct Request: Encodable {
        struct Content: Encodable {
            let parts: [Part]
        }

        struct Part: Encodable {
            let text: String
        }

        struct Config: Encodable {
            let outputDimensionality: Int
        }

        let model: String
        let content: Content
        let config: Config?
    }

    let requests: [Request]
}

private struct BatchEmbedResponse: Decodable {
    struct Embedding: Decodable {
        let values: [Double]?
    }

    let embeddings: [Embedding]
}

private struct APIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
