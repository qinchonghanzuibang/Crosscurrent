import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct TodayUpdate: Codable, Hashable, Sendable {
    public var digest: Digest
    public var revision: DigestRevision
    public var created: Bool

    public init(digest: Digest, revision: DigestRevision, created: Bool) {
        self.digest = digest
        self.revision = revision
        self.created = created
    }
}

/// The only writer of Today revisions. Both Crosscurrent and Agent call this actor through the same
/// canonical repository, so scheduled and foreground refreshes obey identical snapshot rules.
public actor TodayCoordinator {
    private let repository: CrosscurrentRepository
    private let calendar: Calendar

    public init(repository: CrosscurrentRepository, calendar: Calendar = .autoupdatingCurrent) {
        self.repository = repository
        self.calendar = calendar
    }

    public func update(trigger: TodayTrigger, schedule: BriefingSchedule = BriefingSchedule(), now: Date = .now) async throws -> TodayUpdate? {
        let day = calendar.startOfDay(for: now)
        let stored = try await repository.digestState(briefingDay: day)
        let state = TodayState(
            briefingDay: day,
            initialRevisionID: stored?.initialRevisionID,
            latestRevisionID: stored?.latestRevision.id,
            completedAdditionalTimes: Set((stored?.completedAdditionalBriefingKeys ?? []).compactMap(Self.parseBriefingTime))
        )
        guard case let .create(reason, parent) = TodayPlanner.decision(trigger: trigger, state: state, schedule: schedule) else {
            guard let stored else { return nil }
            return TodayUpdate(digest: stored.digest, revision: stored.latestRevision, created: false)
        }

        let snapshots = try await repository.currentEventSnapshots(limit: 500)
        let ranked = RankingEngine.rank(snapshots.map { snapshot in
            let ageHours = max(0, now.timeIntervalSince(snapshot.aggregate.revision.endedAt ?? snapshot.aggregate.revision.startedAt ?? snapshot.aggregate.revision.createdAt) / 3_600)
            let coverage = min(1, Double(snapshot.independentSourceCount) / 8)
            return (
                snapshot.aggregate.revision,
                RankingSignals(
                    importance: min(1, 0.45 + coverage * 0.55),
                    personalRelevance: snapshot.followedPeople.isEmpty ? 0.35 : 0.95,
                    novelty: snapshot.aggregate.revision.ordinal == 1 ? 0.9 : 0.65,
                    authority: 0.8,
                    independentCoverage: coverage,
                    velocity: max(0, 1 - ageHours / 48),
                    recency: max(0, 1 - ageHours / 96),
                    diversity: min(1, Double(snapshot.sourceCount) / 10),
                    followedEntity: !snapshot.followedPeople.isEmpty,
                    followedSource: false,
                    followedTopic: false,
                    savedRelationship: false
                )
            )
        })
        let snapshotByRevision = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.aggregate.revision.id, $0) })
        var entries: [DigestEntry] = []
        entries += entriesFor(Array(ranked.prefix(5)), section: .today)
        entries += entriesFor(ranked.filter { value in
            now.timeIntervalSince(value.revision.endedAt ?? value.revision.startedAt ?? value.revision.createdAt) < 21_600
        }.prefix(8), section: .emerging)
        entries += entriesFor(ranked.filter { !(snapshotByRevision[$0.revision.id]?.followedPeople.isEmpty ?? true) }.prefix(12), section: .peopleYouFollow)
        entries += entriesFor(ranked.filter { $0.reasons.contains(.primarySource) }.prefix(12), section: .worthReading)
        entries += entriesFor(ranked.filter { snapshotByRevision[$0.revision.id]?.chinaGlobalCoverageSufficient == true }.prefix(8), section: .chinaGlobal, adding: .chinaGlobalCoverage)
        entries += entriesFor(ranked.dropFirst(5), section: .everythingElse)

        let digestID = stored?.digest.id ?? DigestID()
        let revision = DigestRevision(digestID: digestID, parentRevisionID: parent, reason: reason, createdAt: now, entries: entries)
        let digest = Digest(id: digestID, briefingDay: day, currentRevisionID: revision.id)
        let committed = try await repository.saveDigest(digest, revision: revision, idempotencyKey: "today:\(revision.id)")
        return TodayUpdate(digest: digest, revision: revision, created: committed)
    }

    private func entriesFor<S: Sequence>(_ values: S, section: DigestSection, adding extraReason: RankingReason? = nil) -> [DigestEntry] where S.Element == RankedEvent {
        values.enumerated().map { index, value in
            var reasons = value.reasons
            if let extraReason, !reasons.contains(extraReason) { reasons.append(extraReason) }
            return DigestEntry(eventRevisionID: value.revision.id, section: section, rank: index, score: value.score, explanation: reasons)
        }
    }

    private static func parseBriefingTime(_ key: String) -> BriefingTime? {
        let parts = key.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return BriefingTime(hour: parts[0], minute: parts[1])
    }
}
