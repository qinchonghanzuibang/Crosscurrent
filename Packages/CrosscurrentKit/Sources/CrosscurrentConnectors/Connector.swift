import Foundation
import CrosscurrentDomain

public struct ConnectorCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let discovery = Self(rawValue: 1 << 0)
    public static let authentication = Self(rawValue: 1 << 1)
    public static let deltaSync = Self(rawValue: 1 << 2)
    public static let pagination = Self(rawValue: 1 << 3)
    public static let fullContent = Self(rawValue: 1 << 4)
    public static let browserRequired = Self(rawValue: 1 << 5)
    public static let deletionSignals = Self(rawValue: 1 << 6)
    public static let engagementMetrics = Self(rawValue: 1 << 7)
    public static let backgroundRefresh = Self(rawValue: 1 << 8)
    public static let queryDiscovery = Self(rawValue: 1 << 9)
}

public struct ConnectorDiscoveryInput: Codable, Hashable, Sendable {
    public var url: URL
    public var suppliedHTML: String?
    public var accountID: ConnectorAccountID?

    public init(url: URL, suppliedHTML: String? = nil, accountID: ConnectorAccountID? = nil) {
        self.url = url
        self.suppliedHTML = suppliedHTML
        self.accountID = accountID
    }
}

public struct ConnectorDiscoveryResult: Codable, Hashable, Sendable {
    public var source: LogicalSource
    public var sourceRevision: SourceRevision
    public var endpoints: [SourceEndpoint]
    public var entityCandidates: [Entity]
    public var sourceEntityRelationships: [SourceEntityRelationship]
    public var aiClassification: SourceAIClassification
    public var coverageCandidate: SourceCoverageAssertion
    public var recentCandidates: [ConnectorItemCandidate]
    public var display: ConnectorDiscoveryDisplay?

    public init(source: LogicalSource, sourceRevision: SourceRevision, endpoints: [SourceEndpoint], entityCandidates: [Entity] = [], sourceEntityRelationships: [SourceEntityRelationship] = [], aiClassification: SourceAIClassification, coverageCandidate: SourceCoverageAssertion, recentCandidates: [ConnectorItemCandidate] = [], display: ConnectorDiscoveryDisplay? = nil) {
        self.source = source
        self.sourceRevision = sourceRevision
        self.endpoints = endpoints
        self.entityCandidates = entityCandidates
        self.sourceEntityRelationships = sourceEntityRelationships
        self.aiClassification = aiClassification
        self.coverageCandidate = coverageCandidate
        self.recentCandidates = recentCandidates
        self.display = display
    }
}

public struct ConnectorDiscoveryDisplay: Codable, Hashable, Sendable {
    public var category: String
    public var identity: String?
    public var detail: String?

    public init(category: String, identity: String? = nil, detail: String? = nil) {
        self.category = category
        self.identity = identity
        self.detail = detail
    }
}

public struct ConnectorCursor: Codable, Hashable, Sendable {
    public var family: String
    public var value: Data

    public init<T: Encodable>(family: String, value: T) throws {
        self.family = family
        self.value = try JSONEncoder().encode(value)
    }

    public init(family: String, encodedValue: Data) {
        self.family = family
        value = encodedValue
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: value)
    }
}

public struct ConnectorItemCandidate: Codable, Hashable, Sendable {
    public var externalID: String
    public var canonicalURL: URL?
    public var title: String
    public var author: String?
    public var publishedAt: Date?
    public var modifiedAt: Date?
    public var summary: String?
    public var contentHTML: String?
    public var contentText: String?
    public var languageCode: String?
    public var topicNames: [String]
    public var metricSnapshots: [ConnectorMetric]
    public var deletionState: RemoteItemState
    public var acquisitionProvenance: ContentAcquisitionProvenance?
    public var weChatOriginalURL: URL?
    public var isInitialBackfill: Bool?

    public init(externalID: String, canonicalURL: URL? = nil, title: String, author: String? = nil, publishedAt: Date? = nil, modifiedAt: Date? = nil, summary: String? = nil, contentHTML: String? = nil, contentText: String? = nil, languageCode: String? = nil, topicNames: [String] = [], metricSnapshots: [ConnectorMetric] = [], deletionState: RemoteItemState = .available, acquisitionProvenance: ContentAcquisitionProvenance? = nil, weChatOriginalURL: URL? = nil, isInitialBackfill: Bool? = nil) {
        self.externalID = externalID
        self.canonicalURL = canonicalURL
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.modifiedAt = modifiedAt
        self.summary = summary
        self.contentHTML = contentHTML
        self.contentText = contentText
        self.languageCode = languageCode
        self.topicNames = topicNames
        self.metricSnapshots = metricSnapshots
        self.deletionState = deletionState
        self.acquisitionProvenance = acquisitionProvenance
        self.weChatOriginalURL = weChatOriginalURL
        self.isInitialBackfill = isInitialBackfill
    }
}

public struct ConnectorMetric: Codable, Hashable, Sendable {
    public var kind: MetricKind
    public var value: Double
    public var connectorKey: String?
    public var capturedAt: Date

    public init(kind: MetricKind, value: Double, connectorKey: String? = nil, capturedAt: Date = .now) {
        self.kind = kind
        self.value = value
        self.connectorKey = connectorKey
        self.capturedAt = capturedAt
    }
}

public struct ConnectorRefreshPage: Codable, Hashable, Sendable {
    public var candidates: [ConnectorItemCandidate]
    public var nextCursor: ConnectorCursor?
    public var reachedEnd: Bool
    public var deletionExternalIDs: [String]
    public var performedRemoteRequest: Bool

    public init(candidates: [ConnectorItemCandidate], nextCursor: ConnectorCursor? = nil, reachedEnd: Bool, deletionExternalIDs: [String] = [], performedRemoteRequest: Bool = true) {
        self.candidates = candidates
        self.nextCursor = nextCursor
        self.reachedEnd = reachedEnd
        self.deletionExternalIDs = deletionExternalIDs
        self.performedRemoteRequest = performedRemoteRequest
    }

    private enum CodingKeys: String, CodingKey {
        case candidates, nextCursor, reachedEnd, deletionExternalIDs, performedRemoteRequest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try container.decode([ConnectorItemCandidate].self, forKey: .candidates)
        nextCursor = try container.decodeIfPresent(ConnectorCursor.self, forKey: .nextCursor)
        reachedEnd = try container.decode(Bool.self, forKey: .reachedEnd)
        deletionExternalIDs = try container.decodeIfPresent([String].self, forKey: .deletionExternalIDs) ?? []
        performedRemoteRequest = try container.decodeIfPresent(Bool.self, forKey: .performedRemoteRequest) ?? true
    }
}

public struct ConnectorContext: Sendable {
    public var now: @Sendable () -> Date
    public var locale: Locale
    public var allowsUserInteraction: Bool

    public init(now: @escaping @Sendable () -> Date = { .now }, locale: Locale = .current, allowsUserInteraction: Bool = false) {
        self.now = now
        self.locale = locale
        self.allowsUserInteraction = allowsUserInteraction
    }
}

public enum ConnectorError: LocalizedError, Equatable {
    case unsupportedInput
    case authenticationRequired
    case interactionRequired
    case rateLimited(retryAfter: TimeInterval?)
    case transientHTTP(statusCode: Int, retryAfter: TimeInterval?)
    case platformChanged(String)
    case policyDenied(String)
    case invalidResponse(String)
    case temporarilyUnavailable
    case configurationRequired(String)
    case quotaExhausted
    case accountUnavailable
    case articleUnavailable(definitive: Bool)

    public var errorDescription: String? {
        switch self {
        case .unsupportedInput: String(localized: "This connector cannot discover the supplied source.")
        case .authenticationRequired: String(localized: "Reconnect this account to continue refreshing.")
        case .interactionRequired: String(localized: "Open Crosscurrent to complete this connector action.")
        case let .rateLimited(retryAfter): retryAfter.map { String(localized: "Rate limited; retry in \(Int($0)) seconds.") } ?? String(localized: "Rate limited.")
        case let .transientHTTP(statusCode, _): String(localized: "The source returned HTTP \(statusCode); Crosscurrent will retry.")
        case let .platformChanged(message): String(localized: "The platform changed: \(message)")
        case let .policyDenied(message): String(localized: "Connector policy denied the operation: \(message)")
        case .invalidResponse("HTTP 404"): String(localized: "No page or feed was found at this address (HTTP 404). Check the URL and try again.")
        case let .invalidResponse(message): String(localized: "The connector returned an invalid response: \(message)")
        case .temporarilyUnavailable: String(localized: "The connector is temporarily unavailable.")
        case let .configurationRequired(message): String(localized: "Additional source configuration is required: \(message)")
        case .quotaExhausted: String(localized: "The configured provider balance is exhausted.")
        case .accountUnavailable: String(localized: "This Official Account is unavailable or has migrated.")
        case let .articleUnavailable(definitive): definitive ? String(localized: "This article is no longer available.") : String(localized: "This article is temporarily unavailable.")
        }
    }
}

public protocol QueryDiscoveringConnector: Connector {
    func search(query: String, context: ConnectorContext) async throws -> [ConnectorDiscoveryResult]
}

public enum ConnectorCursorScope: Sendable {
    /// A durable watermark or fingerprint used by the next refresh.
    case incremental
    /// A position in a changing newest-first listing, valid only within this refresh.
    case refreshPagination
}

public protocol Connector: Sendable {
    var kind: ConnectorKind { get }
    var cursorScope: ConnectorCursorScope { get }
    var capabilities: ConnectorCapabilities { get }
    func discover(input: ConnectorDiscoveryInput, context: ConnectorContext) async throws -> ConnectorDiscoveryResult
    func authenticate(accountID: ConnectorAccountID, context: ConnectorContext) async throws
    func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage
    func fetchContent(candidate: ConnectorItemCandidate, context: ConnectorContext) async throws -> ConnectorItemCandidate
    func healthCheck(accountID: ConnectorAccountID?) async -> ConnectorHealth
    func disconnect(accountID: ConnectorAccountID) async throws
}

public extension Connector {
    var cursorScope: ConnectorCursorScope { .incremental }
}

public actor ConnectorRegistry {
    private var connectors: [ConnectorKind: any Connector] = [:]

    public init() {}

    public func register(_ connector: any Connector) {
        connectors[connector.kind] = connector
    }

    public func connector(for kind: ConnectorKind) -> (any Connector)? { connectors[kind] }
    public func availableKinds() -> Set<ConnectorKind> { Set(connectors.keys) }

    public func search(query: String, context: ConnectorContext) async throws -> [(ConnectorKind, ConnectorDiscoveryResult)] {
        var output: [(ConnectorKind, ConnectorDiscoveryResult)] = []
        for kind in connectors.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let connector = connectors[kind], connector.capabilities.contains(.queryDiscovery),
                  let searchable = connector as? any QueryDiscoveringConnector else { continue }
            output += try await searchable.search(query: query, context: context).map { (kind, $0) }
        }
        return output
    }
}
