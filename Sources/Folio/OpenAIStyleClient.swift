import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIStyleClient: Sendable {
    public struct Configuration: Sendable {
        public let baseURL: URL
        public let apiKey: String?
        public let timeout: TimeInterval

        public init(baseURL: URL = URL(string: "http://127.0.0.1:11434/v1")!, apiKey: String? = nil, timeout: TimeInterval = 60) {
            self.baseURL = baseURL
            self.apiKey = apiKey
            self.timeout = timeout
        }
    }

    public struct ChatMessage: Codable, Sendable {
        public enum Role: String, Codable, Sendable {
            case system
            case user
            case assistant
            case tool
        }

        public let role: Role
        public let content: String

        public init(role: Role, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct ChatCompletionResponse: Decodable, Sendable {
        public struct Choice: Decodable, Sendable {
            public let index: Int
            public let message: ChatMessage
            public let finishReason: String?

            enum CodingKeys: String, CodingKey {
                case index
                case message
                case finishReason = "finish_reason"
            }
        }

        public struct Usage: Decodable, Sendable {
            public let promptTokens: Int?
            public let completionTokens: Int?
            public let totalTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
                case totalTokens = "total_tokens"
            }
        }

        public let id: String
        public let choices: [Choice]
        public let usage: Usage?
    }

    private struct ChatCompletionRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
        }
    }

    private let config: Configuration

    public init(configuration: Configuration) {
        self.config = configuration
    }

    public func chatCompletion(model: String, messages: [ChatMessage], temperature: Double? = nil, maxTokens: Int? = nil) async throws -> ChatCompletionResponse {
        let request = ChatCompletionRequest(model: model, messages: messages, temperature: temperature, maxTokens: maxTokens)
        return try await performRequest(path: "v1/chat/completions", body: request)
    }

    private func performRequest<Body: Encodable, Response: Decodable>(path: String, body: Body) async throws -> Response {
        let url = config.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = config.timeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Folio", code: 430, userInfo: [NSLocalizedDescriptionKey: "Invalid chat response"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Folio", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Chat completion failed: \(bodyText)"])
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }
}
