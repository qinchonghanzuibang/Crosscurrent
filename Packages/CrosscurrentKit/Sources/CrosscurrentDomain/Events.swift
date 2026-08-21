import Foundation

public enum MembershipDecision: String, Codable, CaseIterable, Sendable {
    case accepted, provisional, rejected, retracted
}

public enum MembershipRole: String, Codable, CaseIterable, Sendable {
    case primary, independent, repeated, context, contradiction
}

public enum ClusteringConstraintKind: String, Codable, CaseIterable, Sendable {
    case mustLink, cannotLink, confirmedMembership, rejectedMembership
}

public struct Event: Identifiable, Codable, Hashable, Sendable {
    public var id: EventID
    public var currentRevisionID: EventRevisionID
    public var createdAt: Date
    public var isTombstoned: Bool

    public init(id: EventID = EventID(), currentRevisionID: EventRevisionID = EventRevisionID(), createdAt: Date = .now, isTombstoned: Bool = false) {
        self.id = id
        self.currentRevisionID = currentRevisionID
        self.createdAt = createdAt
        self.isTombstoned = isTombstoned
    }
}

public struct EventRevision: Identifiable, Codable, Hashable, Sendable {
    public var id: EventRevisionID
    public var eventID: EventID
    public var ordinal: Int
    public var title: String
    public var summary: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var changeKind: RevisionChangeKind
    public var primaryMembershipAssertionID: MembershipAssertionID?
    public var primaryReasonTrace: [String]
    public var createdAt: Date

    public init(id: EventRevisionID = EventRevisionID(), eventID: EventID, ordinal: Int = 1, title: String, summary: String, startedAt: Date? = nil, endedAt: Date? = nil, changeKind: RevisionChangeKind = .initial, primaryMembershipAssertionID: MembershipAssertionID? = nil, primaryReasonTrace: [String] = [], createdAt: Date = .now) {
        self.id = id
        self.eventID = eventID
        self.ordinal = ordinal
        self.title = title
        self.summary = summary
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.changeKind = changeKind
        self.primaryMembershipAssertionID = primaryMembershipAssertionID
        self.primaryReasonTrace = primaryReasonTrace
        self.createdAt = createdAt
    }
}

public struct EventMembershipAssertion: Identifiable, Codable, Hashable, Sendable {
    public var id: MembershipAssertionID
    public var eventID: EventID
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID
    public var segmentLineageID: SegmentLineageID
    public var decision: MembershipDecision
    public var role: MembershipRole
    public var confidence: Confidence
    public var identityWeight: Double
    public var independenceGroup: String?
    public var provenance: AssertionProvenance
    public var supersedesID: MembershipAssertionID?
    public var createdAt: Date

    public init(id: MembershipAssertionID = MembershipAssertionID(), eventID: EventID, itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID, segmentLineageID: SegmentLineageID, decision: MembershipDecision, role: MembershipRole, confidence: Confidence, identityWeight: Double, independenceGroup: String? = nil, provenance: AssertionProvenance, supersedesID: MembershipAssertionID? = nil, createdAt: Date = .now) {
        self.id = id
        self.eventID = eventID
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.segmentLineageID = segmentLineageID
        self.decision = decision
        self.role = role
        self.confidence = confidence
        self.identityWeight = identityWeight
        self.independenceGroup = independenceGroup
        self.provenance = provenance
        self.supersedesID = supersedesID
        self.createdAt = createdAt
    }
}

public struct ClusteringConstraint: Identifiable, Codable, Hashable, Sendable {
    public var id: ConstraintID
    public var kind: ClusteringConstraintKind
    public var leftLineageID: SegmentLineageID
    public var rightLineageID: SegmentLineageID?
    public var eventID: EventID?
    public var reason: String?
    public var isActive: Bool
    public var createdAt: Date

    public init(id: ConstraintID = ConstraintID(), kind: ClusteringConstraintKind, leftLineageID: SegmentLineageID, rightLineageID: SegmentLineageID? = nil, eventID: EventID? = nil, reason: String? = nil, isActive: Bool = true, createdAt: Date = .now) {
        self.id = id
        self.kind = kind
        self.leftLineageID = leftLineageID
        self.rightLineageID = rightLineageID
        self.eventID = eventID
        self.reason = reason
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

public struct Claim: Identifiable, Codable, Hashable, Sendable {
    public var id: ClaimID
    public var eventRevisionID: EventRevisionID?
    public var digestRevisionID: DigestRevisionID?
    public var generationRunID: GenerationRunID?
    public var text: String
    public var confidence: Confidence

    public init(id: ClaimID = ClaimID(), eventRevisionID: EventRevisionID? = nil, digestRevisionID: DigestRevisionID? = nil, generationRunID: GenerationRunID? = nil, text: String, confidence: Confidence) {
        self.id = id
        self.eventRevisionID = eventRevisionID
        self.digestRevisionID = digestRevisionID
        self.generationRunID = generationRunID
        self.text = text
        self.confidence = confidence
    }
}

public enum EvidenceRelationship: String, Codable, CaseIterable, Sendable {
    case supports, contradicts, context
}

public struct EvidenceAssertion: Identifiable, Codable, Hashable, Sendable {
    public var id: EvidenceAssertionID
    public var claimID: ClaimID
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID
    public var span: TextSpan
    public var relationship: EvidenceRelationship
    public var confidence: Confidence

    public init(id: EvidenceAssertionID = EvidenceAssertionID(), claimID: ClaimID, itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID, span: TextSpan, relationship: EvidenceRelationship, confidence: Confidence) {
        self.id = id
        self.claimID = claimID
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.span = span
        self.relationship = relationship
        self.confidence = confidence
    }
}
