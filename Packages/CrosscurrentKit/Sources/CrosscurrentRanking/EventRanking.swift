import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

/// Flow and Today use the same evidence, recency, and explicit-interest signals.
public enum EventRanking {
    public static func rank(snapshots: [StoredEventSnapshot], now: Date = .now) -> [RankedEvent] {
        RankingEngine.rank(snapshots.map { snapshot in
            let activity = snapshot.meaningfulActivityAt ?? snapshot.aggregate.revision.endedAt ?? snapshot.aggregate.revision.startedAt ?? snapshot.aggregate.revision.createdAt
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
    }
}
