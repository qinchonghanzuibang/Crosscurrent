import Foundation

public enum EntityKind: String, Codable, CaseIterable, Sendable {
    case person, organization
}

public enum SourceEntityRole: String, Codable, CaseIterable, Sendable {
    case represents, authoredBy, publishedBy, ownedBy, officialFor
}

public struct Entity: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityID
    public var currentRevisionID: EntityRevisionID
    public var kind: EntityKind
    public var displayName: String
    public var normalizedName: String
    public var isFollowed: Bool
    public var createdAt: Date

    public init(id: EntityID = EntityID(), currentRevisionID: EntityRevisionID = EntityRevisionID(), kind: EntityKind, displayName: String, normalizedName: String? = nil, isFollowed: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.currentRevisionID = currentRevisionID
        self.kind = kind
        self.displayName = displayName
        self.normalizedName = normalizedName ?? displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        self.isFollowed = isFollowed
        self.createdAt = createdAt
    }
}

public struct EntityRevision: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityRevisionID
    public var entityID: EntityID
    public var displayName: String
    public var summary: String?
    public var createdAt: Date

    public init(id: EntityRevisionID = EntityRevisionID(), entityID: EntityID, displayName: String, summary: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.entityID = entityID
        self.displayName = displayName
        self.summary = summary
        self.createdAt = createdAt
    }
}

public struct EntityAlias: Identifiable, Codable, Hashable, Sendable {
    public var id: EntityAliasID
    public var entityID: EntityID
    public var value: String
    public var normalizedValue: String
    public var languageCode: String?
    public var provenance: AssertionProvenance
    public var confidence: Confidence

    public init(id: EntityAliasID = EntityAliasID(), entityID: EntityID, value: String, normalizedValue: String? = nil, languageCode: String? = nil, provenance: AssertionProvenance, confidence: Confidence) {
        self.id = id
        self.entityID = entityID
        self.value = value
        self.normalizedValue = normalizedValue ?? value.lowercased()
        self.languageCode = languageCode
        self.provenance = provenance
        self.confidence = confidence
    }
}

public struct SourceEntityRelationship: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var sourceID: SourceID
    public var entityID: EntityID
    public var role: SourceEntityRole
    public var provenance: AssertionProvenance
    public var confidence: Confidence

    public init(id: UUID = UUID(), sourceID: SourceID, entityID: EntityID, role: SourceEntityRole, provenance: AssertionProvenance, confidence: Confidence) {
        self.id = id
        self.sourceID = sourceID
        self.entityID = entityID
        self.role = role
        self.provenance = provenance
        self.confidence = confidence
    }
}

public struct ItemEntityMention: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID
    public var entityID: EntityID
    public var span: TextSpan
    public var mentionedText: String
    public var provenance: AssertionProvenance
    public var confidence: Confidence

    public init(id: UUID = UUID(), itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID, entityID: EntityID, span: TextSpan, mentionedText: String, provenance: AssertionProvenance, confidence: Confidence) {
        self.id = id
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.entityID = entityID
        self.span = span
        self.mentionedText = mentionedText
        self.provenance = provenance
        self.confidence = confidence
    }
}
