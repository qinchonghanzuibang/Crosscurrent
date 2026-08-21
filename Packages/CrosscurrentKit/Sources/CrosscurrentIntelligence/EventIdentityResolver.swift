import CryptoKit
import Foundation
import CrosscurrentDomain

public struct PriorMembershipWeight: Codable, Hashable, Sendable {
    public var assertionID: MembershipAssertionID
    public var segmentLineageID: SegmentLineageID
    public var weight: Double

    public init(assertionID: MembershipAssertionID, segmentLineageID: SegmentLineageID, weight: Double) {
        self.assertionID = assertionID
        self.segmentLineageID = segmentLineageID
        self.weight = weight
    }

    public init(assertion: EventMembershipAssertion) {
        let statusMultiplier: Double
        switch assertion.decision {
        case .accepted where assertion.provenance == .user: statusMultiplier = 1.5
        case .accepted: statusMultiplier = 1.0
        case .provisional: statusMultiplier = 0.5
        case .rejected, .retracted: statusMultiplier = 0
        }
        self.init(assertionID: assertion.id, segmentLineageID: assertion.segmentLineageID, weight: assertion.confidence.value * statusMultiplier)
    }
}

public struct EventSplitPartition: Codable, Hashable, Sendable {
    public var newEventID: EventID
    public var retainedLineages: Set<SegmentLineageID>

    public init(newEventID: EventID, retainedLineages: Set<SegmentLineageID>) {
        self.newEventID = newEventID
        self.retainedLineages = retainedLineages
    }
}

public struct EventSplitResolution: Codable, Hashable, Sendable {
    public var retainingPartitionIndex: Int
    public var eventIDsByPartition: [EventID]
    public var overlapByPartition: [Double]

    public init(retainingPartitionIndex: Int, eventIDsByPartition: [EventID], overlapByPartition: [Double]) {
        self.retainingPartitionIndex = retainingPartitionIndex
        self.eventIDsByPartition = eventIDsByPartition
        self.overlapByPartition = overlapByPartition
    }
}

public enum EventIdentityResolver {
    public static func resolveSplit(oldEventID: EventID, prior: [PriorMembershipWeight], partitions: [EventSplitPartition]) -> EventSplitResolution {
        precondition(!partitions.isEmpty)
        let total = prior.reduce(0) { $0 + max(0, $1.weight) }
        let weighted = partitions.map { partition in
            prior.filter { partition.retainedLineages.contains($0.segmentLineageID) }.reduce(0) { $0 + max(0, $1.weight) }
        }
        let overlap = weighted.map { total > 0 ? $0 / total : 0 }
        let counts = partitions.map { partition in prior.filter { partition.retainedLineages.contains($0.segmentLineageID) }.count }
        let hashes = partitions.map { stablePartitionHash($0.retainedLineages) }
        let winner = partitions.indices.min { lhs, rhs in
            if overlap[lhs] != overlap[rhs] { return overlap[lhs] > overlap[rhs] }
            if counts[lhs] != counts[rhs] { return counts[lhs] > counts[rhs] }
            return hashes[lhs] < hashes[rhs]
        }!
        var eventIDs = partitions.map(\.newEventID)
        eventIDs[winner] = oldEventID
        return EventSplitResolution(retainingPartitionIndex: winner, eventIDsByPartition: eventIDs, overlapByPartition: overlap)
    }

    public static func resolveMerge(weightedStableOverlap: [EventID: Double]) -> EventID? {
        weightedStableOverlap.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.description > rhs.key.description : lhs.value < rhs.value
        }?.key
    }

    private static func stablePartitionHash(_ lineages: Set<SegmentLineageID>) -> String {
        let value = lineages.map(\.description).sorted().joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
