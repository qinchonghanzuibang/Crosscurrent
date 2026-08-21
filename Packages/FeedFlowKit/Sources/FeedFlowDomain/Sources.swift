import Foundation

public enum SourceKind: String, Codable, CaseIterable, Sendable {
    case person, organization, publication, repository, community, query, website, newsletter
}

public enum ConnectorKind: String, Codable, CaseIterable, Sendable {
    case rss, atom, jsonFeed, website, weChatOfficialAccount, xiaohongshu, weibo, zhihu
    case github, arxiv, hackerNews, reddit, bluesky, x, gmail, imap, importedURL, shareExtension
}

public enum AccessRequirement: String, Codable, CaseIterable, Sendable {
    case anonymous, authenticated
}

public enum ContentPrivacy: String, Codable, CaseIterable, Sendable {
    case `public`, `private`, restricted, unknown
}

public enum CoverageEcosystem: String, Codable, CaseIterable, Sendable {
    case chinaFocused, globalFocused, mixed, unknown
}

public enum ConnectorHealth: String, Codable, CaseIterable, Sendable {
    case healthy, syncing, authenticationRequired, rateLimited, temporarilyUnavailable
    case platformChanged, error, disabled
}

public enum SourceEndpointRelationship: String, Codable, CaseIterable, Sendable {
    case alternate, mirror, canonical, syndication, supplemental
}

public struct LogicalSource: Identifiable, Codable, Hashable, Sendable {
    public var id: SourceID
    public var currentRevisionID: SourceRevisionID
    public var kind: SourceKind
    public var isFollowed: Bool
    public var isArchived: Bool
    public var createdAt: Date

    public init(
        id: SourceID = SourceID(),
        currentRevisionID: SourceRevisionID = SourceRevisionID(),
        kind: SourceKind,
        isFollowed: Bool = true,
        isArchived: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.currentRevisionID = currentRevisionID
        self.kind = kind
        self.isFollowed = isFollowed
        self.isArchived = isArchived
        self.createdAt = createdAt
    }
}

public struct SourceRevision: Identifiable, Codable, Hashable, Sendable {
    public var id: SourceRevisionID
    public var sourceID: SourceID
    public var displayName: String
    public var summary: String?
    public var avatarURL: URL?
    public var createdAt: Date

    public init(id: SourceRevisionID = SourceRevisionID(), sourceID: SourceID, displayName: String, summary: String? = nil, avatarURL: URL? = nil, createdAt: Date = .now) {
        self.id = id
        self.sourceID = sourceID
        self.displayName = displayName
        self.summary = summary
        self.avatarURL = avatarURL
        self.createdAt = createdAt
    }
}

public struct SourceEndpoint: Identifiable, Codable, Hashable, Sendable {
    public var id: SourceEndpointID
    public var sourceID: SourceID
    public var connector: ConnectorKind
    public var accountID: ConnectorAccountID?
    public var externalID: String
    public var canonicalURL: URL?
    public var accessRequirement: AccessRequirement
    public var contentPrivacy: ContentPrivacy
    public var health: ConnectorHealth
    public var lastSuccessfulSync: Date?

    public init(
        id: SourceEndpointID = SourceEndpointID(), sourceID: SourceID, connector: ConnectorKind,
        accountID: ConnectorAccountID? = nil, externalID: String, canonicalURL: URL? = nil,
        accessRequirement: AccessRequirement = .anonymous, contentPrivacy: ContentPrivacy = .unknown,
        health: ConnectorHealth = .healthy, lastSuccessfulSync: Date? = nil
    ) {
        self.id = id
        self.sourceID = sourceID
        self.connector = connector
        self.accountID = accountID
        self.externalID = externalID
        self.canonicalURL = canonicalURL
        self.accessRequirement = accessRequirement
        self.contentPrivacy = contentPrivacy
        self.health = health
        self.lastSuccessfulSync = lastSuccessfulSync
    }
}

public struct SourceCoverageAssertion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: SourceID
    public var ecosystem: CoverageEcosystem
    public var provenance: AssertionProvenance
    public var confidence: Confidence
    public var rationale: String?
    public var effectiveAt: Date
    public var supersedesID: UUID?

    public init(id: UUID = UUID(), sourceID: SourceID, ecosystem: CoverageEcosystem, provenance: AssertionProvenance, confidence: Confidence, rationale: String? = nil, effectiveAt: Date = .now, supersedesID: UUID? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.ecosystem = ecosystem
        self.provenance = provenance
        self.confidence = confidence
        self.rationale = rationale
        self.effectiveAt = effectiveAt
        self.supersedesID = supersedesID
    }
}

public struct SourceAIClassification: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: SourceID
    public var accessRequirement: AccessRequirement
    public var contentPrivacy: ContentPrivacy
    public var provenance: AssertionProvenance
    public var confidence: Confidence
    public var createdAt: Date
    public var supersedesID: UUID?

    public init(id: UUID = UUID(), sourceID: SourceID, accessRequirement: AccessRequirement, contentPrivacy: ContentPrivacy, provenance: AssertionProvenance, confidence: Confidence, createdAt: Date = .now, supersedesID: UUID? = nil) {
        self.id = id
        self.sourceID = sourceID
        self.accessRequirement = accessRequirement
        self.contentPrivacy = contentPrivacy
        self.provenance = provenance
        self.confidence = confidence
        self.createdAt = createdAt
        self.supersedesID = supersedesID
    }
}

public struct SourceEndpointRelation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var fromEndpointID: SourceEndpointID
    public var toEndpointID: SourceEndpointID
    public var relationship: SourceEndpointRelationship

    public init(id: UUID = UUID(), fromEndpointID: SourceEndpointID, toEndpointID: SourceEndpointID, relationship: SourceEndpointRelationship) {
        self.id = id
        self.fromEndpointID = fromEndpointID
        self.toEndpointID = toEndpointID
        self.relationship = relationship
    }
}
