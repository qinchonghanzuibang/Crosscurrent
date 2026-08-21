import Foundation

public struct Identifier<Kind>: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID() }
    public init(_ uuid: UUID) { self.rawValue = uuid }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum SourceTag: Sendable {}
public enum SourceRevisionTag: Sendable {}
public enum SourceEndpointTag: Sendable {}
public enum ConnectorAccountTag: Sendable {}
public enum EntityTag: Sendable {}
public enum EntityRevisionTag: Sendable {}
public enum EntityAliasTag: Sendable {}
public enum ItemTag: Sendable {}
public enum ItemRevisionTag: Sendable {}
public enum ItemSegmentTag: Sendable {}
public enum SegmentLineageTag: Sendable {}
public enum EventTag: Sendable {}
public enum EventRevisionTag: Sendable {}
public enum MembershipAssertionTag: Sendable {}
public enum TopicTag: Sendable {}
public enum TopicRevisionTag: Sendable {}
public enum DigestTag: Sendable {}
public enum DigestRevisionTag: Sendable {}
public enum ClaimTag: Sendable {}
public enum EvidenceAssertionTag: Sendable {}
public enum GenerationRunTag: Sendable {}
public enum PromptTemplateTag: Sendable {}
public enum PromptRevisionTag: Sendable {}
public enum JobTag: Sendable {}
public enum ConstraintTag: Sendable {}
public enum BlobTag: Sendable {}

public typealias SourceID = Identifier<SourceTag>
public typealias SourceRevisionID = Identifier<SourceRevisionTag>
public typealias SourceEndpointID = Identifier<SourceEndpointTag>
public typealias ConnectorAccountID = Identifier<ConnectorAccountTag>
public typealias EntityID = Identifier<EntityTag>
public typealias EntityRevisionID = Identifier<EntityRevisionTag>
public typealias EntityAliasID = Identifier<EntityAliasTag>
public typealias ItemID = Identifier<ItemTag>
public typealias ItemRevisionID = Identifier<ItemRevisionTag>
public typealias ItemSegmentID = Identifier<ItemSegmentTag>
public typealias SegmentLineageID = Identifier<SegmentLineageTag>
public typealias EventID = Identifier<EventTag>
public typealias EventRevisionID = Identifier<EventRevisionTag>
public typealias MembershipAssertionID = Identifier<MembershipAssertionTag>
public typealias TopicID = Identifier<TopicTag>
public typealias TopicRevisionID = Identifier<TopicRevisionTag>
public typealias DigestID = Identifier<DigestTag>
public typealias DigestRevisionID = Identifier<DigestRevisionTag>
public typealias ClaimID = Identifier<ClaimTag>
public typealias EvidenceAssertionID = Identifier<EvidenceAssertionTag>
public typealias GenerationRunID = Identifier<GenerationRunTag>
public typealias PromptTemplateID = Identifier<PromptTemplateTag>
public typealias PromptRevisionID = Identifier<PromptRevisionTag>
public typealias JobID = Identifier<JobTag>
public typealias ConstraintID = Identifier<ConstraintTag>
public typealias BlobID = Identifier<BlobTag>

public enum AssertionProvenance: String, Codable, CaseIterable, Sendable {
    case connector
    case deterministic
    case embedding
    case model
    case user
    case imported
}

public struct Confidence: Codable, Hashable, Sendable, Comparable {
    public let value: Double

    public init(_ value: Double) {
        self.value = min(1, max(0, value))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    public static let certain = Confidence(1)
    public static let unknown = Confidence(0)
}

public struct TextSpan: Codable, Hashable, Sendable {
    public var utf8Start: Int
    public var utf8Length: Int
    public var excerptHash: String

    public init(utf8Start: Int, utf8Length: Int, excerptHash: String) {
        self.utf8Start = utf8Start
        self.utf8Length = utf8Length
        self.excerptHash = excerptHash
    }
}
