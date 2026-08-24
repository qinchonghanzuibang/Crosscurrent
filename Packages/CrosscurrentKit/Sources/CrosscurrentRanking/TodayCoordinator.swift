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
        let snapshots = try await repository.currentEventSnapshots(limit: 500)
        let eligibleSnapshots = snapshots.filter { snapshot in
            guard let activity = snapshot.meaningfulActivityAt else { return false }
            return activity <= now.addingTimeInterval(6 * 3_600) && now.timeIntervalSince(activity) <= 7 * 86_400
        }
        let ranked = RankingEngine.rank(eligibleSnapshots.map { snapshot in
            let activity = snapshot.meaningfulActivityAt ?? .distantPast
            let ageHours = max(0, now.timeIntervalSince(activity) / 3_600)
            let coverage = min(1, Double(snapshot.independentSourceCount) / 8)
            let followed = !snapshot.followedPeople.isEmpty || !snapshot.followedTopics.isEmpty || snapshot.hasFollowedSource
            let updateMagnitude: Double = switch snapshot.aggregate.revision.changeKind {
            case .initial, .majorUpdate, .correction: 1
            case .contentUpdate, .merge, .split: 0.72
            case .minorMetadata: 0.25
            }
            return (
                snapshot.aggregate.revision,
                RankingSignals(
                    importance: min(1, updateMagnitude * 0.55 + coverage * 0.45),
                    personalRelevance: followed ? 1 : (snapshot.isSaved ? 0.8 : 0.15),
                    novelty: updateMagnitude,
                    authority: snapshot.primaryAuthority,
                    independentCoverage: coverage,
                    velocity: snapshot.trendVelocity,
                    recency: max(0, 1 - ageHours / 96),
                    diversity: min(1, Double(snapshot.sourceCount) / 10),
                    followedEntity: !snapshot.followedPeople.isEmpty,
                    followedSource: snapshot.hasFollowedSource,
                    followedTopic: !snapshot.followedTopics.isEmpty,
                    savedRelationship: snapshot.isSaved
                )
            )
        })
        let snapshotByRevision = Dictionary(uniqueKeysWithValues: eligibleSnapshots.map { ($0.aggregate.revision.id, $0) })
        var assigned = Set<EventRevisionID>()
        var entries: [DigestEntry] = []
        func append(_ candidates: [RankedEvent], section: DigestSection, limit: Int, adding extraReason: RankingReason? = nil) {
            guard entries.count < 15 else { return }
            let available = min(limit, 15 - entries.count)
            let selected = candidates.filter { !assigned.contains($0.revision.id) }.prefix(available)
            for value in selected { assigned.insert(value.revision.id) }
            entries += entriesFor(selected, section: section, adding: extraReason)
        }

        func age(_ value: RankedEvent) -> TimeInterval {
            guard let date = snapshotByRevision[value.revision.id]?.meaningfulActivityAt else { return .infinity }
            return now.timeIntervalSince(date)
        }

        let hero = ranked.filter { value in
            guard let snapshot = snapshotByRevision[value.revision.id] else { return false }
            let strongEvidence = snapshot.primaryAuthority >= 0.8 || snapshot.independentSourceCount >= 2
            let personallyRelevant = snapshot.hasFollowedSource || !snapshot.followedPeople.isEmpty || !snapshot.followedTopics.isEmpty
            return age(value) <= 72 * 3_600 && value.score >= 0.52 && (strongEvidence || personallyRelevant)
        }
        append(hero, section: .today, limit: 5, adding: .freshPublication)
        append(ranked.filter { value in
            age(value) <= 48 * 3_600 && (snapshotByRevision[value.revision.id]?.trendVelocity ?? 0) >= 0.35
        }, section: .emerging, limit: 3)
        append(ranked.filter {
            guard let snapshot = snapshotByRevision[$0.revision.id] else { return false }
            return age($0) <= 72 * 3_600 && (!snapshot.followedPeople.isEmpty || !snapshot.followedTopics.isEmpty || snapshot.hasFollowedSource)
        }, section: .peopleYouFollow, limit: 3)
        append(ranked.filter {
            guard let snapshot = snapshotByRevision[$0.revision.id], age($0) <= 7 * 86_400 else { return false }
            let structure = snapshot.readerHTML.map { html in
                ["<h2", "<pre", "<table", "<figure", "<math"].contains(where: html.localizedCaseInsensitiveContains)
            } ?? false
            return snapshot.readerText.count >= 1_500 && snapshot.primaryAuthority >= 0.65 && (structure || snapshot.readerText.count >= 4_000)
        }, section: .worthReading, limit: 3, adding: .readingValue)
        append(ranked.filter { age($0) <= 7 * 86_400 && snapshotByRevision[$0.revision.id]?.chinaGlobalCoverageSufficient == true }, section: .chinaGlobal, limit: 2, adding: .chinaGlobalCoverage)
        append(ranked.filter { age($0) <= 72 * 3_600 }, section: .everythingElse, limit: 15)

        let plannedSignature = entries.map { "\($0.eventRevisionID):\($0.section.rawValue):\($0.rank):\($0.explanation.map(\.rawValue).joined(separator: ","))" }
        let existingSignature = stored?.latestRevision.entries.map { "\($0.eventRevisionID):\($0.section.rawValue):\($0.rank):\($0.explanation.map(\.rawValue).joined(separator: ","))" }
        let decision = TodayPlanner.decision(trigger: trigger, state: state, schedule: schedule)
        let reason: DigestRevisionReason
        let parent: DigestRevisionID?
        switch decision {
        case let .create(plannedReason, plannedParent):
            reason = plannedReason
            parent = plannedParent
        case .noRevision:
            guard let stored else { return nil }
            guard plannedSignature != existingSignature else {
                return TodayUpdate(digest: stored.digest, revision: stored.latestRevision, created: false)
            }
            reason = .policyRefresh
            parent = stored.latestRevision.id
        }

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
