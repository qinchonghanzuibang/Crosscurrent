import Foundation
import CrosscurrentDomain

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
        try AIEndpointSecurity.validate(endpoint)
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
        try AIEndpointSecurity.validate(endpoint)
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

public struct OpenAICompatibleChatProvider: AIProvider {
    public let id: String
    public let executionLocation: AIExecutionLocation
    public let capabilities: AIProviderCapabilities

    private let apiKey: String?
    private let endpoint: URL
    private let additionalHeaders: [String: String]
    private let session: URLSession

    public init(id: String, apiKey: String?, endpoint: URL, additionalHeaders: [String: String] = [:], session: URLSession = .shared) {
        self.id = id
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.additionalHeaders = additionalHeaders
        self.session = session
        let local = Self.isLoopback(endpoint)
        executionLocation = local ? .local : .cloud
        capabilities = local ? [.structuredOutput, .reasoning, .local] : [.structuredOutput, .reasoning]
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse {
        struct Message: Codable { var role: String; var content: String }
        struct Body: Encodable { var model: String; var messages: [Message]; var temperature: Double? }
        struct Response: Decodable {
            struct Choice: Decodable { var message: Message }
            struct Usage: Decodable { var prompt_tokens: Int?; var completion_tokens: Int? }
            var id: String?
            var choices: [Choice]
            var usage: Usage?
        }
        try AIEndpointSecurity.validate(endpoint)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        for (name, value) in additionalHeaders { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            model: request.model,
            messages: [.init(role: "system", content: request.instructions), .init(role: "user", content: request.input)],
            temperature: request.temperature
        ))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.httpStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.choices.map(\.message.content).joined(separator: "\n")
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return AIResponse(text: text, providerRequestID: decoded.id, inputTokens: decoded.usage?.prompt_tokens, outputTokens: decoded.usage?.completion_tokens)
    }

    private static func isLoopback(_ endpoint: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(endpoint.host?.lowercased() ?? "")
    }
}

public struct AnthropicMessagesProvider: AIProvider {
    public let id: String
    public let executionLocation: AIExecutionLocation = .cloud
    public let capabilities: AIProviderCapabilities = [.structuredOutput, .reasoning]
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(id: String, apiKey: String, endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages")!, session: URLSession = .shared) {
        self.id = id; self.apiKey = apiKey; self.endpoint = endpoint; self.session = session
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse {
        struct Message: Codable { var role: String; var content: String }
        struct Body: Encodable { var model: String; var max_tokens: Int; var system: String; var messages: [Message]; var temperature: Double? }
        struct Response: Decodable {
            struct Content: Decodable { var type: String; var text: String? }
            struct Usage: Decodable { var input_tokens: Int?; var output_tokens: Int? }
            var id: String?; var content: [Content]; var usage: Usage?
        }
        try AIEndpointSecurity.validate(endpoint)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"; urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(Body(model: request.model, max_tokens: 2048, system: request.instructions, messages: [.init(role: "user", content: request.input)], temperature: request.temperature))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.httpStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return AIResponse(text: text, providerRequestID: decoded.id, inputTokens: decoded.usage?.input_tokens, outputTokens: decoded.usage?.output_tokens)
    }
}

public struct GeminiGenerateContentProvider: AIProvider {
    public let id: String
    public let executionLocation: AIExecutionLocation = .cloud
    public let capabilities: AIProviderCapabilities = [.structuredOutput, .reasoning]
    private let apiKey: String
    private let endpoint: URL
    private let session: URLSession

    public init(id: String, apiKey: String, endpoint: URL, session: URLSession = .shared) {
        self.id = id; self.apiKey = apiKey; self.endpoint = endpoint; self.session = session
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse {
        struct Part: Codable { var text: String }
        struct Content: Codable { var role: String?; var parts: [Part] }
        struct Body: Encodable { var system_instruction: Content; var contents: [Content] }
        struct Response: Decodable {
            struct Candidate: Decodable { var content: Content }
            struct Usage: Decodable { var promptTokenCount: Int?; var candidatesTokenCount: Int? }
            var candidates: [Candidate]; var usageMetadata: Usage?
        }
        try AIEndpointSecurity.validate(endpoint)
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"; urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONEncoder().encode(Body(
            system_instruction: Content(role: nil, parts: [Part(text: request.instructions)]),
            contents: [Content(role: "user", parts: [Part(text: request.input)])]
        ))
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AIProviderError.httpStatus(http.statusCode) }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.candidates.flatMap(\.content.parts).map(\.text).joined()
        guard !text.isEmpty else { throw AIProviderError.invalidResponse }
        return AIResponse(text: text, inputTokens: decoded.usageMetadata?.promptTokenCount, outputTokens: decoded.usageMetadata?.candidatesTokenCount)
    }
}

public struct OpenRouterProvider: AIProvider {
    public let id: String
    public let executionLocation: AIExecutionLocation = .cloud
    public let capabilities: AIProviderCapabilities = [.structuredOutput, .reasoning]
    private let base: OpenAICompatibleChatProvider

    public init(id: String, apiKey: String, endpoint: URL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!, applicationURL: String = "https://crosscurrent.app", applicationName: String = "Crosscurrent", session: URLSession = .shared) {
        self.id = id
        base = OpenAICompatibleChatProvider(id: id, apiKey: apiKey, endpoint: endpoint, additionalHeaders: ["HTTP-Referer": applicationURL, "X-Title": applicationName], session: session)
    }

    public func perform(_ request: AIRequest) async throws -> AIResponse { try await base.perform(request) }
}
