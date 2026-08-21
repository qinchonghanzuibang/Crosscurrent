import Foundation

public struct Topic: Identifiable, Codable, Hashable, Sendable {
    public var id: TopicID
    public var currentRevisionID: TopicRevisionID
    public var isFollowed: Bool

    public init(id: TopicID = TopicID(), currentRevisionID: TopicRevisionID = TopicRevisionID(), isFollowed: Bool = false) {
        self.id = id
        self.currentRevisionID = currentRevisionID
        self.isFollowed = isFollowed
    }
}

public struct TopicRevision: Identifiable, Codable, Hashable, Sendable {
    public var id: TopicRevisionID
    public var topicID: TopicID
    public var name: String
    public var summary: String?
    public var createdAt: Date

    public init(id: TopicRevisionID = TopicRevisionID(), topicID: TopicID, name: String, summary: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.topicID = topicID
        self.name = name
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct TopicAlias: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var topicID: TopicID
    public var normalizedName: String
    public var languageCode: String?

    public init(id: UUID = UUID(), topicID: TopicID, normalizedName: String, languageCode: String? = nil) {
        self.id = id
        self.topicID = topicID
        self.normalizedName = normalizedName
        self.languageCode = languageCode
    }
}

public struct ItemTopicAssertion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID?
    public var topicID: TopicID
    public var confidence: Confidence
    public var provenance: AssertionProvenance
    public var supersedesID: UUID?

    public init(id: UUID = UUID(), itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID? = nil, topicID: TopicID, confidence: Confidence, provenance: AssertionProvenance, supersedesID: UUID? = nil) {
        self.id = id
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.topicID = topicID
        self.confidence = confidence
        self.provenance = provenance
        self.supersedesID = supersedesID
    }
}

public struct EventTopicAssertion: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var eventRevisionID: EventRevisionID
    public var topicID: TopicID
    public var confidence: Confidence
    public var provenance: AssertionProvenance
    public var supersedesID: UUID?

    public init(id: UUID = UUID(), eventRevisionID: EventRevisionID, topicID: TopicID, confidence: Confidence, provenance: AssertionProvenance, supersedesID: UUID? = nil) {
        self.id = id
        self.eventRevisionID = eventRevisionID
        self.topicID = topicID
        self.confidence = confidence
        self.provenance = provenance
        self.supersedesID = supersedesID
    }
}
