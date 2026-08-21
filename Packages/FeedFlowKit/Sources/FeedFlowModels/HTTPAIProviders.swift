import Foundation
import FeedFlowDomain

public struct OpenAIResponsesProvider: AIProvider {
    public let id: String
    public let executionLocation: AIExecutionLocation = .cloud
    public let capabilities: AIProviderCapabilities = [.streaming, .structuredOutput, .reasoning]

    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(id: String = "openai", apiKey: String, endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!, session: URLSession = .shared) {
        self.id = id
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.session = session
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse {
        struct Body: Encodable { var model: String; var instructions: String; var input: String; var temperature: Double? }
        struct Response: Decodable {
            struct Output: Decodable { struct Content: Decodable { var type: String; var text: String? }; var content: [Content] }
            struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
            var id: String?
            var output: [Output]
            var usage: Usage?
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 90
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = try JSONEncoder().encode(Body(model: request.model, instructions: request.instructions, input: request.input, temperature: request.temperature))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.httpStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.output.flatMap(\.content).filter { $0.type == "output_text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return AIResponse(text: text, providerRequestID: decoded.id, inputTokens: decoded.usage?.input_tokens, outputTokens: decoded.usage?.output_tokens)
    }
}

public struct OllamaProvider: AIProvider {
    public let id: String
    public let executionLocation: AIExecutionLocation
    public let capabilities: AIProviderCapabilities

    private let endpoint: URL
    private let bearerToken: String?
    private let session: URLSession

    public init(id: String = "ollama-local", endpoint: URL = URL(string: "http://127.0.0.1:11434/api/chat")!, bearerToken: String? = nil, session: URLSession = .shared) {
        self.id = id
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.session = session
        let local = endpoint.host == "127.0.0.1" || endpoint.host == "localhost"
        self.executionLocation = local ? .local : .cloud
        self.capabilities = local ? [.structuredOutput, .reasoning, .local] : [.structuredOutput, .reasoning]
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse {
        struct Message: Codable { var role: String; var content: String }
        struct Body: Encodable { var model: String; var messages: [Message]; var stream: Bool }
        struct Response: Decodable {
            var message: Message
            var prompt_eval_count: Int?
            var eval_count: Int?
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearerToken { urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONEncoder().encode(Body(model: request.model, messages: [.init(role: "system", content: request.instructions), .init(role: "user", content: request.input)], stream: false))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.httpStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard !decoded.message.content.isEmpty else { throw AIProviderError.invalidResponse }
        return AIResponse(text: decoded.message.content, inputTokens: decoded.prompt_eval_count, outputTokens: decoded.eval_count)
    }
}
