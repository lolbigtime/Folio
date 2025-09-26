import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch

/// On-device adapter that talks to a local EmbeddingGemma runtime.
///
/// Folio expects embeddings to be available without reaching out to hosted APIs so apps can
/// ship fully offline if desired. Tools like [Ollama](https://ollama.com) expose Gemma
/// embeddings through a lightweight HTTP server on `localhost`. This adapter keeps the
/// networking surface area small and performs one request per chunk, which matches
/// the streaming nature of many on-device runtimes.
public struct EmbeddingGemmaEmbedder: Embedder {
    public struct Configuration: Sendable {
        /// Base URL of the local embedding server. Defaults to Ollama's standard port.
        public var baseURL: URL
        /// Model identifier understood by the runtime (e.g. "gemma:2b" or "gemma:7b" with an embedding template).
        public var model: String
        /// Optional timeout applied to each request.
        public var timeout: TimeInterval

        public init(
            baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
            model: String = "gemma:2b",
            timeout: TimeInterval = 60
        ) {
            self.baseURL = baseURL
            self.model = model
            self.timeout = timeout
        }
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

        return try texts.map { text in
            try embedSingle(text: text)
        }
    }

    private func embedSingle(text: String) throws -> [Float] {
        let endpoint = config.baseURL.appendingPathComponent("api/embeddings")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbeddingRequest(model: config.model, input: text))

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<(Data, URLResponse), Error>?

        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let data, let response {
                result = .success((data, response))
            } else {
                result = .failure(NSError(domain: "Folio", code: 520, userInfo: [NSLocalizedDescriptionKey: "Empty embedding response"]))
            }
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + config.timeout)
        if waitResult == .timedOut {
            task.cancel()
            throw NSError(domain: "Folio", code: 521, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma request timed out"])
        }

        guard let outcome = result else {
            throw NSError(domain: "Folio", code: 522, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma request missing result"])
        }

        let (data, response) = try outcome.get()
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 523, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma invalid response"])
        }

        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "EmbeddingGemma server error: \(text)"])
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return decoded.embedding.map { Float($0) }
    }
}

private struct EmbeddingRequest: Encodable {
    let model: String
    let input: String
}

private struct EmbeddingResponse: Decodable {
    let embedding: [Double]
}

