import CryptoKit
import Foundation
import FeedFlowDomain

public struct EventCandidateScore: Codable, Hashable, Sendable {
    public var eventID: EventID
    public var semantic: Double
    public var entityOverlap: Double
    public var topicOverlap: Double
    public var temporal: Double
    public var title: Double
    public var citation: Double
    public var independence: Double
    public var coherence: Double
    public var memberLineages: Set<SegmentLineageID>

    public init(eventID: EventID, semantic: Double, entityOverlap: Double, topicOverlap: Double, temporal: Double, title: Double, citation: Double, independence: Double, coherence: Double, memberLineages: Set<SegmentLineageID> = []) {
        self.eventID = eventID
        self.semantic = semantic
        self.entityOverlap = entityOverlap
        self.topicOverlap = topicOverlap
        self.temporal = temporal
        self.title = title
        self.citation = citation
        self.independence = independence
        self.coherence = coherence
        self.memberLineages = memberLineages
    }

    public var combined: Double {
        0.28 * semantic + 0.17 * entityOverlap + 0.14 * topicOverlap + 0.11 * temporal
            + 0.10 * title + 0.07 * citation + 0.06 * independence + 0.07 * coherence
    }
}

public struct SegmentAssignment: Codable, Hashable, Sendable {
    public var segmentLineageID: SegmentLineageID
    public var eventIDs: [EventID]
    public var wasForcedByUser: Bool

    public init(segmentLineageID: SegmentLineageID, eventIDs: [EventID], wasForcedByUser: Bool) {
        self.segmentLineageID = segmentLineageID
        self.eventIDs = eventIDs
        self.wasForcedByUser = wasForcedByUser
    }
}

public struct ClusteringPolicy: Codable, Hashable, Sendable {
    public var acceptanceThreshold: Double
    public var secondaryMembershipThreshold: Double
    public var ambiguityMargin: Double
    public var maximumMembershipsPerSegment: Int

    public init(acceptanceThreshold: Double = 0.72, secondaryMembershipThreshold: Double = 0.79, ambiguityMargin: Double = 0.04, maximumMembershipsPerSegment: Int = 2) {
        self.acceptanceThreshold = acceptanceThreshold
        self.secondaryMembershipThreshold = secondaryMembershipThreshold
        self.ambiguityMargin = ambiguityMargin
        self.maximumMembershipsPerSegment = maximumMembershipsPerSegment
    }
}

public enum DeterministicClusteringEngine {
    public static func assign(
        segmentLineageID: SegmentLineageID,
        candidates: [EventCandidateScore],
        constraints: [ClusteringConstraint],
        policy: ClusteringPolicy = ClusteringPolicy()
    ) -> SegmentAssignment {
        let active = constraints.filter { $0.isActive && $0.leftLineageID == segmentLineageID }
        var rejectedEvents = Set(active.compactMap { constraint -> EventID? in
            switch constraint.kind {
            case .cannotLink, .rejectedMembership: constraint.eventID
            default: nil
            }
        })
        for constraint in active where constraint.kind == .cannotLink {
            guard let right = constraint.rightLineageID else { continue }
            rejectedEvents.formUnion(candidates.filter { $0.memberLineages.contains(right) }.map(\.eventID))
        }
        var forcedEvents = Set(active.compactMap { constraint -> EventID? in
            switch constraint.kind {
            case .mustLink, .confirmedMembership: constraint.eventID
            default: nil
            }
        })
        for constraint in active where constraint.kind == .mustLink {
            guard let right = constraint.rightLineageID else { continue }
            forcedEvents.formUnion(candidates.filter { $0.memberLineages.contains(right) }.map(\.eventID))
        }
        forcedEvents.subtract(rejectedEvents)
        if !forcedEvents.isEmpty {
            return SegmentAssignment(segmentLineageID: segmentLineageID, eventIDs: forcedEvents.sorted(by: idOrder), wasForcedByUser: true)
        }

        let eligible = candidates
            .filter { !rejectedEvents.contains($0.eventID) }
            .sorted { lhs, rhs in lhs.combined == rhs.combined ? idOrder(lhs.eventID, rhs.eventID) : lhs.combined > rhs.combined }
        guard let first = eligible.first, first.combined >= policy.acceptanceThreshold else {
            return SegmentAssignment(segmentLineageID: segmentLineageID, eventIDs: [], wasForcedByUser: false)
        }

        var accepted = [first.eventID]
        for candidate in eligible.dropFirst() where accepted.count < policy.maximumMembershipsPerSegment {
            guard candidate.combined >= policy.secondaryMembershipThreshold else { continue }
            guard first.combined - candidate.combined <= policy.ambiguityMargin else { continue }
            accepted.append(candidate.eventID)
        }
        return SegmentAssignment(segmentLineageID: segmentLineageID, eventIDs: accepted, wasForcedByUser: false)
    }

    private static func idOrder(_ lhs: EventID, _ rhs: EventID) -> Bool { lhs.description < rhs.description }
}
