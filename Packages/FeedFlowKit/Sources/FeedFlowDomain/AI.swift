import Foundation

public enum AITask: String, Codable, CaseIterable, Sendable {
    case eventTitle, eventSynthesis, ambiguousClustering, keyPoints, translation
    case explainSelection, summarizeSelection, askSelection, askArticle, digestSynthesis, chinaGlobalComparison
}

public enum AIExecutionLocation: String, Codable, CaseIterable, Sendable {
    case local, cloud
}

public struct AIContentPolicy: Codable, Hashable, Sendable {
    public var publicCloudProviders: Set<String>
    public var privateCloudProvidersBySource: [SourceID: Set<String>]
    public var restrictedCloudAllowedSources: Set<SourceID>

    public init(publicCloudProviders: Set<String> = [], privateCloudProvidersBySource: [SourceID: Set<String>] = [:], restrictedCloudAllowedSources: Set<SourceID> = []) {
        self.publicCloudProviders = publicCloudProviders
        self.privateCloudProvidersBySource = privateCloudProvidersBySource
        self.restrictedCloudAllowedSources = restrictedCloudAllowedSources
    }

    public func allows(sourceID: SourceID, privacy: ContentPrivacy, providerID: String, location: AIExecutionLocation, connectorAllowsCloud: Bool = true) -> Bool {
        if location == .local { return true }
        guard connectorAllowsCloud else { return false }
        switch privacy {
        case .public:
            return publicCloudProviders.contains(providerID)
        case .private:
            return privateCloudProvidersBySource[sourceID]?.contains(providerID) == true
        case .restricted:
            return restrictedCloudAllowedSources.contains(sourceID)
                && privateCloudProvidersBySource[sourceID]?.contains(providerID) == true
        case .unknown:
            return false
        }
    }
}

public struct PromptTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: PromptTemplateID
    public var task: AITask
    public var name: String
    public var bundledDefaultRevisionID: PromptRevisionID

    public init(id: PromptTemplateID = PromptTemplateID(), task: AITask, name: String, bundledDefaultRevisionID: PromptRevisionID) {
        self.id = id
        self.task = task
        self.name = name
        self.bundledDefaultRevisionID = bundledDefaultRevisionID
    }
}

public struct PromptRevision: Identifiable, Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case bundled, user }

    public var id: PromptRevisionID
    public var templateID: PromptTemplateID
    public var parentRevisionID: PromptRevisionID?
    public var origin: Origin
    public var body: String
    public var variables: [String]
    public var createdAt: Date

    public init(id: PromptRevisionID = PromptRevisionID(), templateID: PromptTemplateID, parentRevisionID: PromptRevisionID? = nil, origin: Origin, body: String, variables: [String], createdAt: Date = .now) {
        self.id = id
        self.templateID = templateID
        self.parentRevisionID = parentRevisionID
        self.origin = origin
        self.body = body
        self.variables = variables
        self.createdAt = createdAt
    }
}

public struct GenerationRun: Identifiable, Codable, Hashable, Sendable {
    public var id: GenerationRunID
    public var task: AITask
    public var providerID: String
    public var modelID: String
    public var promptRevisionID: PromptRevisionID
    public var inputHash: String
    public var policyDecision: String
    public var consentRevisionID: UUID?
    public var createdAt: Date

    public init(id: GenerationRunID = GenerationRunID(), task: AITask, providerID: String, modelID: String, promptRevisionID: PromptRevisionID, inputHash: String, policyDecision: String, consentRevisionID: UUID? = nil, createdAt: Date = .now) {
        self.id = id
        self.task = task
        self.providerID = providerID
        self.modelID = modelID
        self.promptRevisionID = promptRevisionID
        self.inputHash = inputHash
        self.policyDecision = policyDecision
        self.consentRevisionID = consentRevisionID
        self.createdAt = createdAt
    }
}

public struct EmbeddingDescriptor: Codable, Hashable, Sendable {
    public enum ScalarType: String, Codable, Sendable { case float16, float32 }

    public var runtimeID: String
    public var modelID: String
    public var modelRevision: String
    public var dimension: Int
    public var scalarType: ScalarType
    public var pooling: String
    public var normalization: String
    public var queryPrefix: String?
    public var documentPrefix: String?

    public init(runtimeID: String, modelID: String, modelRevision: String, dimension: Int, scalarType: ScalarType, pooling: String, normalization: String, queryPrefix: String? = nil, documentPrefix: String? = nil) {
        self.runtimeID = runtimeID
        self.modelID = modelID
        self.modelRevision = modelRevision
        self.dimension = dimension
        self.scalarType = scalarType
        self.pooling = pooling
        self.normalization = normalization
        self.queryPrefix = queryPrefix
        self.documentPrefix = documentPrefix
    }
}
