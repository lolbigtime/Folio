import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Dispatch

public struct EmbeddingGemmaEmbedder: Embedder {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let apiKey: String
        public let model: String
        public let timeout: TimeInterval

        public init(baseURL: URL, apiKey: String, model: String, timeout: TimeInterval = 60) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.model = model
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

        let requestBody = EmbeddingRequest(model: config.model, input: texts, encodingFormat: "float")
        let data: Data = try performRequest(path: "v1/embeddings", body: requestBody)
        let response = try JSONDecoder().decode(EmbeddingResponse.self, from: data)

        return try response.data.map { item in
            guard let embedding = item.embedding else {
                throw NSError(domain: "Folio", code: 420, userInfo: [NSLocalizedDescriptionKey: "Embedding missing in response"])
            }
            return embedding.map { Float($0) }
        }
    }

    private func performRequest<Body: Encodable>(path: String, body: Body) throws -> Data {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
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
                result = .failure(NSError(domain: "Folio", code: 421, userInfo: [NSLocalizedDescriptionKey: "No response from embedding endpoint"]))
            }
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + config.timeout)
        if waitResult == .timedOut {
            task.cancel()
            throw NSError(domain: "Folio", code: 422, userInfo: [NSLocalizedDescriptionKey: "Embedding request timed out"])
        }

        guard let result else {
            throw NSError(domain: "Folio", code: 424, userInfo: [NSLocalizedDescriptionKey: "Embedding request missing result"])
        }
        let (data, response) = try result.get()
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 423, userInfo: [NSLocalizedDescriptionKey: "Invalid embedding response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Embedding request failed: \(body)"])
        }
        return data
    }
}

private struct EmbeddingRequest: Encodable {
    enum CodingKeys: String, CodingKey {
        case model
        case input
        case encodingFormat = "encoding_format"
    }

    let model: String
    let input: [String]
    let encodingFormat: String?
}

private struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let embedding: [Double]?
    }

    let data: [Item]
}
