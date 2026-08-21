import FeedFlowDomain
import FeedFlowStorage
import Foundation

public enum ManualEventCorrectionError: LocalizedError {
    case insufficientEvents
    case eventNotFound
    case cannotSplitSingleMembership
    case lineageNotFound

    public var errorDescription: String? {
        switch self {
        case .insufficientEvents: "Choose at least two Events to merge."
        case .eventNotFound: "The Event changed before the correction could be saved."
        case .cannotSplitSingleMembership: "An Event needs at least two evidence memberships before it can be split."
        case .lineageNotFound: "The selected evidence span is no longer in the current Event revision."
        }
    }
}

public actor ManualEventCorrectionService {
    private let repository: FeedFlowRepository

    public init(repository: FeedFlowRepository) { self.repository = repository }

    @discardableResult
    public func merge(eventIDs: Set<EventID>) async throws -> EventID {
        guard eventIDs.count >= 2 else { throw ManualEventCorrectionError.insufficientEvents }
        let candidates = try await repository.currentEventAggregates(limit: 2_000).filter { eventIDs.contains($0.event.id) }
        guard candidates.count == eventIDs.count else { throw ManualEventCorrectionError.eventNotFound }
        let weights = Dictionary(uniqueKeysWithValues: candidates.map { aggregate in
            (aggregate.event.id, aggregate.memberships.map(PriorMembershipWeight.init).reduce(0) { $0 + $1.weight })
        })
        guard let survivingID = EventIdentityResolver.resolveMerge(weightedStableOverlap: weights),
              let survivor = candidates.first(where: { $0.event.id == survivingID })
        else { throw ManualEventCorrectionError.eventNotFound }
        let losers = candidates.filter { $0.event.id != survivingID }
        var mergedMemberships = survivor.memberships
        for loser in losers {
            mergedMemberships += loser.memberships.map { clone($0, eventID: survivingID) }
        }
        let revision = EventRevision(
            eventID: survivingID,
            ordinal: survivor.revision.ordinal + 1,
            title: survivor.revision.title,
            summary: survivor.revision.summary,
            startedAt: candidates.compactMap(\.revision.startedAt).min(),
            endedAt: candidates.compactMap { $0.revision.endedAt ?? $0.revision.startedAt }.max(),
            changeKind: .merge,
            primaryMembershipAssertionID: survivor.revision.primaryMembershipAssertionID ?? mergedMemberships.first?.id
        )
        let event = Event(id: survivingID, currentRevisionID: revision.id, createdAt: survivor.event.createdAt)
        _ = try await repository.saveEvent(event, revision: revision, memberships: mergedMemberships, idempotencyKey: "manual-merge-revision:\(revision.id)")
        for membership in mergedMemberships {
            _ = try await repository.saveConstraint(
                ClusteringConstraint(kind: .mustLink, leftLineageID: membership.segmentLineageID, eventID: survivingID, reason: "Manual Event merge"),
                idempotencyKey: "manual-merge-constraint:\(survivingID):\(membership.segmentLineageID)"
            )
        }
        _ = try await repository.recordEventMerge(
            survivingEventID: survivingID,
            losingEventIDs: losers.map(\.event.id),
            priorRevisionID: survivor.revision.id,
            weightedOverlap: Dictionary(uniqueKeysWithValues: weights.map { ($0.key.description, $0.value) })
        )
        return survivingID
    }

    @discardableResult
    public func split(eventID: EventID, movingLineageID: SegmentLineageID) async throws -> [EventID] {
        guard let aggregate = try await repository.currentEventAggregates(limit: 2_000).first(where: { $0.event.id == eventID }) else {
            throw ManualEventCorrectionError.eventNotFound
        }
        guard aggregate.memberships.count >= 2 else { throw ManualEventCorrectionError.cannotSplitSingleMembership }
        let moving = aggregate.memberships.filter { $0.segmentLineageID == movingLineageID }
        let retained = aggregate.memberships.filter { $0.segmentLineageID != movingLineageID }
        guard !moving.isEmpty else { throw ManualEventCorrectionError.lineageNotFound }
        let proposedNewIDs = [EventID(), EventID()]
        let resolution = EventIdentityResolver.resolveSplit(
            oldEventID: eventID,
            prior: aggregate.memberships.map(PriorMembershipWeight.init),
            partitions: [
                EventSplitPartition(newEventID: proposedNewIDs[0], retainedLineages: Set(retained.map(\.segmentLineageID))),
                EventSplitPartition(newEventID: proposedNewIDs[1], retainedLineages: Set(moving.map(\.segmentLineageID)))
            ]
        )
        let partitions = [retained, moving]
        for index in partitions.indices {
            let partitionEventID = resolution.eventIDsByPartition[index]
            let keepsIdentity = partitionEventID == eventID
            let memberships = keepsIdentity ? partitions[index] : partitions[index].map { clone($0, eventID: partitionEventID) }
            let ordinal = keepsIdentity ? aggregate.revision.ordinal + 1 : 1
            let revision = EventRevision(
                eventID: partitionEventID,
                ordinal: ordinal,
                title: index == resolution.retainingPartitionIndex ? aggregate.revision.title : "\(aggregate.revision.title) — split",
                summary: aggregate.revision.summary,
                startedAt: aggregate.revision.startedAt,
                endedAt: aggregate.revision.endedAt,
                changeKind: .split,
                primaryMembershipAssertionID: memberships.first?.id
            )
            let event = Event(id: partitionEventID, currentRevisionID: revision.id, createdAt: keepsIdentity ? aggregate.event.createdAt : .now)
            _ = try await repository.saveEvent(event, revision: revision, memberships: memberships, idempotencyKey: "manual-split-revision:\(aggregate.revision.id):\(index)")
            for membership in memberships {
                _ = try await repository.saveConstraint(
                    ClusteringConstraint(kind: .confirmedMembership, leftLineageID: membership.segmentLineageID, eventID: partitionEventID, reason: "Manual Event split"),
                    idempotencyKey: "manual-split-confirm:\(partitionEventID):\(membership.segmentLineageID)"
                )
            }
        }
        for left in retained {
            for right in moving {
                _ = try await repository.saveConstraint(
                    ClusteringConstraint(kind: .cannotLink, leftLineageID: left.segmentLineageID, rightLineageID: right.segmentLineageID, reason: "Manual Event split"),
                    idempotencyKey: "manual-split-cannot:\(left.segmentLineageID):\(right.segmentLineageID)"
                )
            }
        }
        _ = try await repository.recordEventSplit(priorRevisionID: aggregate.revision.id, resultEventIDs: resolution.eventIDsByPartition, weightedOverlap: resolution.overlapByPartition)
        return resolution.eventIDsByPartition
    }

    public func confirm(eventID: EventID, lineageID: SegmentLineageID) async throws {
        _ = try await repository.saveConstraint(
            ClusteringConstraint(kind: .confirmedMembership, leftLineageID: lineageID, eventID: eventID, reason: "User-confirmed membership"),
            idempotencyKey: "confirm-membership:\(eventID):\(lineageID)"
        )
    }

    public func reject(eventID: EventID, lineageID: SegmentLineageID) async throws {
        _ = try await repository.saveConstraint(
            ClusteringConstraint(kind: .rejectedMembership, leftLineageID: lineageID, eventID: eventID, reason: "User-rejected membership"),
            idempotencyKey: "reject-membership:\(eventID):\(lineageID)"
        )
    }

    private func clone(_ membership: EventMembershipAssertion, eventID: EventID) -> EventMembershipAssertion {
        EventMembershipAssertion(
            eventID: eventID,
            itemRevisionID: membership.itemRevisionID,
            itemSegmentID: membership.itemSegmentID,
            segmentLineageID: membership.segmentLineageID,
            decision: .accepted,
            role: membership.role,
            confidence: .certain,
            identityWeight: 1.5,
            independenceGroup: membership.independenceGroup,
            provenance: .user,
            supersedesID: membership.id
        )
    }
}
