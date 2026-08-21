import Foundation
import CrosscurrentDomain

public struct AIProviderCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let streaming = Self(rawValue: 1 << 0)
    public static let structuredOutput = Self(rawValue: 1 << 1)
    public static let reasoning = Self(rawValue: 1 << 2)
    public static let local = Self(rawValue: 1 << 3)
}

public enum AIProviderRouteRole: String, Codable, CaseIterable, Sendable {
    case fast, reasoning
}

public struct AIRequest: Codable, Hashable, Sendable {
    public var task: AITask
    public var model: String
    public var instructions: String
    public var input: String
    public var promptRevisionID: PromptRevisionID
    public var temperature: Double?

    public init(task: AITask, model: String, instructions: String, input: String, promptRevisionID: PromptRevisionID, temperature: Double? = nil) {
        self.task = task
        self.model = model
        self.instructions = instructions
        self.input = input
        self.promptRevisionID = promptRevisionID
        self.temperature = temperature
    }
}

public struct AIResponse: Codable, Hashable, Sendable {
    public var text: String
    public var providerRequestID: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(text: String, providerRequestID: String? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.text = text
        self.providerRequestID = providerRequestID
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum AIProviderError: LocalizedError, Equatable {
    case configurationRequired
    case policyDenied
    case invalidResponse
    case httpStatus(Int)
    case insecureEndpoint

    public var errorDescription: String? {
        switch self {
        case .configurationRequired: "Configure an AI provider to use this action."
        case .policyDenied: "The content privacy policy does not permit this provider request."
        case .invalidResponse: "The AI provider returned an invalid response."
        case let .httpStatus(code): "The AI provider returned HTTP \(code)."
        case .insecureEndpoint: "Cloud AI endpoints require HTTPS; HTTP is allowed only for loopback local services."
        }
    }
}

public enum AIEndpointSecurity {
    public static func validate(_ endpoint: URL) throws {
        if endpoint.scheme?.lowercased() == "https" { return }
        let host = endpoint.host?.lowercased()
        if endpoint.scheme?.lowercased() == "http",
           host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return
        }
        throw AIProviderError.insecureEndpoint
    }
}

public protocol AIProvider: Sendable {
    var id: String { get }
    var executionLocation: AIExecutionLocation { get }
    var capabilities: AIProviderCapabilities { get }
    func perform(_ request: AIRequest) async throws -> AIResponse
}

public actor AIProviderRegistry {
    private var providers: [String: any AIProvider] = [:]

    public init() {}
    public func register(_ provider: any AIProvider) { providers[provider.id] = provider }
    public func remove(id: String) { providers[id] = nil }
    public func provider(id: String) -> (any AIProvider)? { providers[id] }

    public func perform(providerID: String?, request: AIRequest, sourceID: SourceID, privacy: ContentPrivacy, policy: AIContentPolicy, connectorAllowsCloud: Bool = true) async throws -> AIResponse {
        guard let providerID, let provider = providers[providerID] else { throw AIProviderError.configurationRequired }
        guard policy.allows(sourceID: sourceID, privacy: privacy, providerID: providerID, location: provider.executionLocation, connectorAllowsCloud: connectorAllowsCloud) else {
            throw AIProviderError.policyDenied
        }
        return try await provider.perform(request)
    }
}
