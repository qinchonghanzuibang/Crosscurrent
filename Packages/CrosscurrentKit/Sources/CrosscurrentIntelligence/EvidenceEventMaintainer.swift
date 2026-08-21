import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct EvidenceMaintenanceResult: Codable, Hashable, Sendable {
    public var evidenceSegments: Int
    public var eventsCreated: Int
    public var eventRevisionsCreated: Int
    public var unassignedSegments: Int

    public init(evidenceSegments: Int = 0, eventsCreated: Int = 0, eventRevisionsCreated: Int = 0, unassignedSegments: Int = 0) {
        self.evidenceSegments = evidenceSegments
        self.eventsCreated = eventsCreated
        self.eventRevisionsCreated = eventRevisionsCreated
        self.unassignedSegments = unassignedSegments
    }
}

/// Provider-free Event maintenance. Embedding and reasoning candidates can be added to the same
/// scorer, but their absence never prevents conservative deterministic clustering.
public actor EvidenceEventMaintainer {
    private let repository: CrosscurrentRepository
    private let deduplication: EvidenceDeduplicationService

    public init(repository: CrosscurrentRepository) {
        self.repository = repository
        deduplication = EvidenceDeduplicationService(repository: repository)
    }

    public func run(limit: Int = 250) async throws -> EvidenceMaintenanceResult {
        _ = try await deduplication.run(limit: max(500, limit * 4))
        let pending = try await repository.pendingEvidenceSegments(limit: limit)
        guard !pending.isEmpty else { return EvidenceMaintenanceResult() }
        let constraints = try await repository.activeConstraints()
        var aggregates = try await repository.currentEventAggregates(limit: 2_000)
        var signalCache: [EventID: StoredClusteringSignals] = [:]
        for aggregate in aggregates {
            signalCache[aggregate.event.id] = try await repository.clusteringSignals(eventRevisionID: aggregate.revision.id)
        }
        var result = EvidenceMaintenanceResult(evidenceSegments: pending.count)

        for evidence in pending {
            let scores = aggregates.map { candidateScore(evidence: evidence, event: $0, signals: signalCache[$0.event.id] ?? StoredClusteringSignals()) }
            let assignment = DeterministicClusteringEngine.assign(
                segmentLineageID: evidence.segment.lineageID,
                candidates: scores,
                constraints: constraints,
                policy: ClusteringPolicy(acceptanceThreshold: 0.50, secondaryMembershipThreshold: 0.78, ambiguityMargin: 0.025, maximumMembershipsPerSegment: 2)
            )
            if assignment.eventIDs.isEmpty {
                let created = try await createEvent(from: evidence)
                aggregates.append(created)
                signalCache[created.event.id] = StoredClusteringSignals(entityIDs: evidence.entityIDs, topicIDs: evidence.topicIDs)
                result.eventsCreated += 1
                result.eventRevisionsCreated += 1
                continue
            }

            var committed = false
            for eventID in assignment.eventIDs {
                guard let index = aggregates.firstIndex(where: { $0.event.id == eventID }) else { continue }
                let updated = try await append(evidence, to: aggregates[index], forced: assignment.wasForcedByUser)
                aggregates[index] = updated
                signalCache[eventID] = try await repository.clusteringSignals(eventRevisionID: updated.revision.id)
                result.eventRevisionsCreated += 1
                committed = true
            }
            if !committed { result.unassignedSegments += 1 }
        }
        return result
    }

    private func createEvent(from evidence: PendingEvidenceSegment) async throws -> StoredEventAggregate {
        let eventID = EventID()
        let membership = EventMembershipAssertion(
            eventID: eventID,
            itemRevisionID: evidence.itemRevision.id,
            itemSegmentID: evidence.segment.id,
            segmentLineageID: evidence.segment.lineageID,
            decision: .accepted,
            role: .primary,
            confidence: Confidence(0.86),
            identityWeight: 1,
            independenceGroup: evidence.independenceGroup,
            provenance: .deterministic
        )
        let revision = EventRevision(
            eventID: eventID,
            title: evidence.itemRevision.title,
            summary: providerFreeSummary(evidence),
            startedAt: evidence.itemRevision.publishedAt ?? evidence.itemRevision.fetchedAt,
            endedAt: evidence.itemRevision.modifiedAt ?? evidence.itemRevision.publishedAt,
            changeKind: .initial,
            primaryMembershipAssertionID: membership.id
        )
        let event = Event(id: eventID, currentRevisionID: revision.id)
        _ = try await repository.saveEvent(
            event,
            revision: revision,
            memberships: [membership],
            idempotencyKey: "cluster:new:\(evidence.segment.id)"
        )
        return StoredEventAggregate(event: event, revision: revision, memberships: [membership])
    }

    private func append(_ evidence: PendingEvidenceSegment, to aggregate: StoredEventAggregate, forced: Bool) async throws -> StoredEventAggregate {
        let sourceAlreadyPresent = aggregate.memberships.contains { $0.independenceGroup == evidence.independenceGroup }
        let membership = EventMembershipAssertion(
            eventID: aggregate.event.id,
            itemRevisionID: evidence.itemRevision.id,
            itemSegmentID: evidence.segment.id,
            segmentLineageID: evidence.segment.lineageID,
            decision: .accepted,
            role: sourceAlreadyPresent ? .repeated : .independent,
            confidence: forced ? .certain : Confidence(0.78),
            identityWeight: forced ? 1.5 : 1,
            independenceGroup: evidence.independenceGroup,
            provenance: forced ? .user : .deterministic
        )
        let memberships = aggregate.memberships + [membership]
        let changeKind: RevisionChangeKind
        switch evidence.itemRevision.changeKind {
        case .majorUpdate, .correction: changeKind = evidence.itemRevision.changeKind
        default: changeKind = sourceAlreadyPresent ? .contentUpdate : .majorUpdate
        }
        let summary = aggregate.revision.summary.isEmpty ? providerFreeSummary(evidence) : aggregate.revision.summary
        let revision = EventRevision(
            eventID: aggregate.event.id,
            ordinal: aggregate.revision.ordinal + 1,
            title: aggregate.revision.title,
            summary: summary,
            startedAt: minDate(aggregate.revision.startedAt, evidence.itemRevision.publishedAt ?? evidence.itemRevision.fetchedAt),
            endedAt: maxDate(aggregate.revision.endedAt, evidence.itemRevision.modifiedAt ?? evidence.itemRevision.publishedAt ?? evidence.itemRevision.fetchedAt),
            changeKind: changeKind,
            primaryMembershipAssertionID: aggregate.revision.primaryMembershipAssertionID ?? membership.id
        )
        let event = Event(id: aggregate.event.id, currentRevisionID: revision.id, createdAt: aggregate.event.createdAt)
        _ = try await repository.saveEvent(
            event,
            revision: revision,
            memberships: memberships,
            idempotencyKey: "cluster:append:\(aggregate.event.id):\(evidence.segment.id)"
        )
        return StoredEventAggregate(event: event, revision: revision, memberships: memberships)
    }

    private func candidateScore(evidence: PendingEvidenceSegment, event: StoredEventAggregate, signals: StoredClusteringSignals) -> EventCandidateScore {
        let segmentSimilarity = similarity(evidence.segment.text, event.revision.summary + " " + event.revision.title)
        let titleSimilarity = similarity(evidence.itemRevision.title, event.revision.title)
        let referenceDate = evidence.itemRevision.publishedAt ?? evidence.itemRevision.fetchedAt
        let eventDate = event.revision.endedAt ?? event.revision.startedAt ?? event.revision.createdAt
        let days = abs(referenceDate.timeIntervalSince(eventDate)) / 86_400
        let temporal = max(0, 1 - days / 14)
        let sameSource = event.memberships.contains { $0.independenceGroup == evidence.independenceGroup }
        let semanticProxy = max(segmentSimilarity, titleSimilarity)
        let entityOverlap = overlap(evidence.entityIDs, signals.entityIDs)
        let topicOverlap = overlap(evidence.topicIDs, signals.topicIDs)
        return EventCandidateScore(
            eventID: event.event.id,
            semantic: semanticProxy,
            entityOverlap: entityOverlap,
            topicOverlap: topicOverlap,
            temporal: temporal,
            title: titleSimilarity,
            citation: 0,
            independence: sameSource ? 0.2 : 1,
            coherence: segmentSimilarity,
            memberLineages: Set(event.memberships.map(\.segmentLineageID))
        )
    }

    private func overlap<T>(_ lhs: Set<T>, _ rhs: Set<T>) -> Double where T: Hashable {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(min(lhs.count, rhs.count))
    }

    private func providerFreeSummary(_ evidence: PendingEvidenceSegment) -> String {
        let sentences = evidence.itemRevision.text
            .split(whereSeparator: { ".!?。！？\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 20 }
        return sentences.prefix(3).joined(separator: evidence.itemRevision.languageCode?.hasPrefix("zh") == true ? "。" : ". ")
    }

    private func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    private func tokens(_ value: String) -> Set<String> {
        let normalized = value.precomposedStringWithCanonicalMapping.lowercased()
        let words = normalized.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
        let han = normalized.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.map(String.init)
        return Set(words + han)
    }

    private func minDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) { case let (a?, b?): min(a, b); case let (a?, nil): a; case let (nil, b?): b; default: nil }
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) { case let (a?, b?): max(a, b); case let (a?, nil): a; case let (nil, b?): b; default: nil }
    }
}
