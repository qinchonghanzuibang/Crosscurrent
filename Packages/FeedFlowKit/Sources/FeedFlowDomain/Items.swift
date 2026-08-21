import Foundation

public enum RemoteItemState: String, Codable, CaseIterable, Sendable {
    case available, deleted, unavailable, unknown
}
public enum RevisionChangeKind: String, Codable, CaseIterable, Sendable {
    case initial, minorMetadata, contentUpdate, majorUpdate, correction, merge, split

    public var isReaderVisible: Bool {
        switch self {
        case .minorMetadata: false
        default: true
        }
    }
}

public enum SegmentKind: String, Codable, CaseIterable, Sendable {
    case whole, section, claim, paragraph, quote
}

public enum MetricKind: String, Codable, CaseIterable, Sendable {
    case likes, reposts, replies, comments, saves, views, stars, score
}

public struct Item: Identifiable, Codable, Hashable, Sendable {
    public var id: ItemID
    public var sourceID: SourceID
    public var sourceEndpointID: SourceEndpointID
    public var externalID: String
    public var canonicalURL: URL?
    public var currentRevisionID: ItemRevisionID
    public var remoteState: RemoteItemState
    public var createdAt: Date

    public init(id: ItemID = ItemID(), sourceID: SourceID, sourceEndpointID: SourceEndpointID, externalID: String, canonicalURL: URL? = nil, currentRevisionID: ItemRevisionID = ItemRevisionID(), remoteState: RemoteItemState = .available, createdAt: Date = .now) {
        self.id = id
        self.sourceID = sourceID
        self.sourceEndpointID = sourceEndpointID
        self.externalID = externalID
        self.canonicalURL = canonicalURL
        self.currentRevisionID = currentRevisionID
        self.remoteState = remoteState
        self.createdAt = createdAt
    }
}

public struct ItemRevision: Identifiable, Codable, Hashable, Sendable {
    public var id: ItemRevisionID
    public var itemID: ItemID
    public var ordinal: Int
    public var title: String
    public var author: String?
    public var publishedAt: Date?
    public var modifiedAt: Date?
    public var fetchedAt: Date
    public var languageCode: String?
    public var text: String
    public var sanitizedHTML: String?
    public var contentHash: String
    public var changeKind: RevisionChangeKind

    public init(id: ItemRevisionID = ItemRevisionID(), itemID: ItemID, ordinal: Int = 1, title: String, author: String? = nil, publishedAt: Date? = nil, modifiedAt: Date? = nil, fetchedAt: Date = .now, languageCode: String? = nil, text: String, sanitizedHTML: String? = nil, contentHash: String, changeKind: RevisionChangeKind = .initial) {
        self.id = id
        self.itemID = itemID
        self.ordinal = ordinal
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
        self.modifiedAt = modifiedAt
        self.fetchedAt = fetchedAt
        self.languageCode = languageCode
        self.text = text
        self.sanitizedHTML = sanitizedHTML
        self.contentHash = contentHash
        self.changeKind = changeKind
    }
}

public struct ItemSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: ItemSegmentID
    public var lineageID: SegmentLineageID
    public var itemRevisionID: ItemRevisionID
    public var kind: SegmentKind
    public var headingPath: [String]
    public var span: TextSpan
    public var text: String
    public var contentHash: String

    public init(id: ItemSegmentID = ItemSegmentID(), lineageID: SegmentLineageID = SegmentLineageID(), itemRevisionID: ItemRevisionID, kind: SegmentKind, headingPath: [String] = [], span: TextSpan, text: String, contentHash: String) {
        self.id = id
        self.lineageID = lineageID
        self.itemRevisionID = itemRevisionID
        self.kind = kind
        self.headingPath = headingPath
        self.span = span
        self.text = text
        self.contentHash = contentHash
    }
}

public struct ItemMetricSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var itemID: ItemID
    public var sourceEndpointID: SourceEndpointID
    public var kind: MetricKind
    public var value: Double
    public var capturedAt: Date
    public var connectorKey: String?

    public init(id: UUID = UUID(), itemID: ItemID, sourceEndpointID: SourceEndpointID, kind: MetricKind, value: Double, capturedAt: Date = .now, connectorKey: String? = nil) {
        self.id = id
        self.itemID = itemID
        self.sourceEndpointID = sourceEndpointID
        self.kind = kind
        self.value = value
        self.capturedAt = capturedAt
        self.connectorKey = connectorKey
    }
}

public struct TopicAssertion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var topicID: TopicID
    public var itemRevisionID: ItemRevisionID?
    public var itemSegmentID: ItemSegmentID?
    public var eventRevisionID: EventRevisionID?
    public var provenance: AssertionProvenance
    public var confidence: Confidence
    public var createdAt: Date

    public init(id: UUID = UUID(), topicID: TopicID, itemRevisionID: ItemRevisionID? = nil, itemSegmentID: ItemSegmentID? = nil, eventRevisionID: EventRevisionID? = nil, provenance: AssertionProvenance, confidence: Confidence, createdAt: Date = .now) {
        self.id = id
        self.topicID = topicID
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.eventRevisionID = eventRevisionID
        self.provenance = provenance
        self.confidence = confidence
        self.createdAt = createdAt
    }
}
