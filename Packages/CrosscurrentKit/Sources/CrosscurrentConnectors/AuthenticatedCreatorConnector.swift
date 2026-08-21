import Foundation
import CrosscurrentDomain

public enum AuthenticatedCreatorPlatform: String, Codable, CaseIterable, Sendable {
    case weChatOfficialAccount
    case xiaohongshu
    case x
    case weibo
    case zhihu

    public var connectorKind: ConnectorKind {
        switch self {
        case .weChatOfficialAccount: .weChatOfficialAccount
        case .xiaohongshu: .xiaohongshu
        case .x: .x
        case .weibo: .weibo
        case .zhihu: .zhihu
        }
    }
}

public enum AuthenticatedConnectorQualificationState: String, Codable, Sendable {
    case captureRequired
    case liveContractInstalled
    case platformChanged
}

public struct BrowserCreatorDiscoveryRequest: Codable, Hashable, Sendable {
    public var platform: AuthenticatedCreatorPlatform
    public var inputURL: URL
    public var accountID: ConnectorAccountID?
}

public struct BrowserCreatorRefreshRequest: Codable, Hashable, Sendable {
    public var platform: AuthenticatedCreatorPlatform
    public var endpointExternalID: String
    public var profileURL: URL
    public var accountID: ConnectorAccountID
    public var cursor: ConnectorCursor?
}

public struct BrowserCreatorIdentity: Codable, Hashable, Sendable {
    public var stableCreatorID: String
    public var displayName: String
    public var profileURL: URL
    public var biography: String?
    public var entityKind: EntityKind
    public var recentItems: [ConnectorItemCandidate]
    public var nextCursor: ConnectorCursor?

    public init(stableCreatorID: String, displayName: String, profileURL: URL, biography: String? = nil, entityKind: EntityKind, recentItems: [ConnectorItemCandidate], nextCursor: ConnectorCursor? = nil) {
        self.stableCreatorID = stableCreatorID
        self.displayName = displayName
        self.profileURL = profileURL
        self.biography = biography
        self.entityKind = entityKind
        self.recentItems = recentItems
        self.nextCursor = nextCursor
    }
}

public protocol BrowserCreatorSessionClient: Sendable {
    func authenticate(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID, allowsInteraction: Bool) async throws
    func discover(_ request: BrowserCreatorDiscoveryRequest) async throws -> BrowserCreatorIdentity
    func refresh(_ request: BrowserCreatorRefreshRequest) async throws -> ConnectorRefreshPage
    func health(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID?) async -> ConnectorHealth
    func disconnect(platform: AuthenticatedCreatorPlatform, accountID: ConnectorAccountID) async throws
}

public actor AuthenticatedCreatorConnector: Connector {
    public nonisolated let kind: ConnectorKind
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .authentication, .browserRequired]
    public nonisolated let qualificationState: AuthenticatedConnectorQualificationState = .captureRequired

    private let platform: AuthenticatedCreatorPlatform
    private let browser: any BrowserCreatorSessionClient

    public init(platform: AuthenticatedCreatorPlatform, browser: any BrowserCreatorSessionClient) {
        self.platform = platform
        self.kind = platform.connectorKind
        self.browser = browser
    }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        guard Self.accepts(url: input.url, platform: platform) else { throw ConnectorError.unsupportedInput }
        let identity = try await browser.discover(.init(platform: platform, inputURL: input.url, accountID: input.accountID))
        let revisionID = SourceRevisionID()
        let sourceKind: SourceKind = identity.entityKind == .person ? .person : .organization
        let source = LogicalSource(currentRevisionID: revisionID, kind: sourceKind)
        let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: identity.displayName, summary: identity.biography)
        let entityRevisionID = EntityRevisionID()
        let entity = Entity(currentRevisionID: entityRevisionID, kind: identity.entityKind, displayName: identity.displayName)
        let relationship = SourceEntityRelationship(sourceID: source.id, entityID: entity.id, role: .represents, provenance: .connector, confidence: .certain)
        let endpoint = SourceEndpoint(sourceID: source.id, connector: kind, accountID: input.accountID, externalID: identity.stableCreatorID, canonicalURL: identity.profileURL, accessRequirement: .authenticated, contentPrivacy: .public)
        return ConnectorDiscoveryResult(
            source: source,
            sourceRevision: revision,
            endpoints: [endpoint],
            entityCandidates: [entity],
            sourceEntityRelationships: [relationship],
            aiClassification: SourceAIClassification(sourceID: source.id, accessRequirement: .authenticated, contentPrivacy: .public, provenance: .connector, confidence: .certain),
            coverageCandidate: SourceCoverageAssertion(sourceID: source.id, ecosystem: .unknown, provenance: .connector, confidence: .unknown),
            recentCandidates: identity.recentItems
        )
    }

    public func authenticate(accountID: ConnectorAccountID, context: ConnectorContext) async throws {
        try await browser.authenticate(platform: platform, accountID: accountID, allowsInteraction: context.allowsUserInteraction)
    }

    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context _: ConnectorContext) async throws -> ConnectorRefreshPage {
        guard let accountID = endpoint.accountID else { throw ConnectorError.authenticationRequired }
        guard let profileURL = endpoint.canonicalURL else { throw ConnectorError.unsupportedInput }
        return try await browser.refresh(.init(platform: platform, endpointExternalID: endpoint.externalID, profileURL: profileURL, accountID: accountID, cursor: cursor))
    }

    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID: ConnectorAccountID?) async -> ConnectorHealth { await browser.health(platform: platform, accountID: accountID) }
    public func disconnect(accountID: ConnectorAccountID) async throws { try await browser.disconnect(platform: platform, accountID: accountID) }

    private static func accepts(url: URL, platform: AuthenticatedCreatorPlatform) -> Bool {
        let host = url.host?.lowercased() ?? ""
        switch platform {
        case .weChatOfficialAccount: return host == "mp.weixin.qq.com" || host.hasSuffix(".weixin.qq.com")
        case .xiaohongshu: return host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") || host == "xhslink.com"
        case .x: return host == "x.com" || host == "twitter.com" || host.hasSuffix(".twitter.com")
        case .weibo: return host == "weibo.com" || host.hasSuffix(".weibo.com")
        case .zhihu: return host == "zhihu.com" || host.hasSuffix(".zhihu.com")
        }
    }
}
