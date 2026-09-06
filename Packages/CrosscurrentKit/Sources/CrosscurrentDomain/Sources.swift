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
    case healthy, syncing, retrying, authenticationRequired, rateLimited, temporarilyUnavailable
    case platformChanged, configurationRequired, error, disabled
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

/// Local acquisition state. Account aliases identify the publisher; provider/feed
/// locators only identify ways of acquiring that publisher's public articles.
public struct WeChatAcquisitionMetadata: Codable, Hashable, Sendable {
    public var providerID: String
    public var priority: Int
    public var accountAliases: [String]
    public var currentBiz: String?
    public var displayName: String?
    public var lastAttempt: Date?
    public var etag: String?
    public var lastModified: String?
    public var lastAudit: Date?
    public var lastCatalogCheck: Date?
    public var retryAfter: Date?

    public init(providerID: String, priority: Int, accountAliases: [String] = [], currentBiz: String? = nil, displayName: String? = nil, lastAttempt: Date? = nil, etag: String? = nil, lastModified: String? = nil, lastAudit: Date? = nil, lastCatalogCheck: Date? = nil, retryAfter: Date? = nil) {
        self.providerID = providerID
        self.priority = priority
        self.accountAliases = Array(Set(accountAliases)).sorted()
        self.currentBiz = currentBiz
        self.displayName = displayName
        self.lastAttempt = lastAttempt
        self.etag = etag
        self.lastModified = lastModified
        self.lastAudit = lastAudit
        self.lastCatalogCheck = lastCatalogCheck
        self.retryAfter = retryAfter
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
    public var weChatAcquisition: WeChatAcquisitionMetadata?

    public init(
        id: SourceEndpointID = SourceEndpointID(), sourceID: SourceID, connector: ConnectorKind,
        accountID: ConnectorAccountID? = nil, externalID: String, canonicalURL: URL? = nil,
        accessRequirement: AccessRequirement = .anonymous, contentPrivacy: ContentPrivacy = .unknown,
        health: ConnectorHealth = .healthy, lastSuccessfulSync: Date? = nil,
        weChatAcquisition: WeChatAcquisitionMetadata? = nil
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
        self.weChatAcquisition = weChatAcquisition
    }

    /// Also reads PR #6 endpoints, whose biz was retained on the official profile
    /// URL before acquisition metadata existed. Display names never enter identity.
    public var weChatAccountAliases: Set<String> {
        guard connector == .weChatOfficialAccount else { return [] }
        var aliases = Set(weChatAcquisition?.accountAliases ?? [])
        let accountID = externalID.components(separatedBy: ":feed:").first ?? externalID
        if ["wechat-account:", "wechat-account-biz:", "wechat-account-wxid:"].contains(where: accountID.hasPrefix) {
            aliases.insert(accountID)
        }
        if let url = canonicalURL, url.host?.lowercased() == "mp.weixin.qq.com",
           let biz = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { ["__biz", "biz"].contains($0.name) })?.value,
           !biz.isEmpty {
            aliases.insert("wechat-account-biz:\(biz)")
        }
        return aliases
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
