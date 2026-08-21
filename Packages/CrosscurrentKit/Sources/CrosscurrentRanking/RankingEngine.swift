import Foundation
import CrosscurrentDomain

public struct RankingSignals: Codable, Hashable, Sendable {
    public var importance: Double
    public var personalRelevance: Double
    public var novelty: Double
    public var authority: Double
    public var independentCoverage: Double
    public var velocity: Double
    public var recency: Double
    public var diversity: Double
    public var followedEntity: Bool
    public var followedSource: Bool
    public var followedTopic: Bool
    public var savedRelationship: Bool

    public init(importance: Double, personalRelevance: Double, novelty: Double, authority: Double, independentCoverage: Double, velocity: Double, recency: Double, diversity: Double, followedEntity: Bool = false, followedSource: Bool = false, followedTopic: Bool = false, savedRelationship: Bool = false) {
        self.importance = importance
        self.personalRelevance = personalRelevance
        self.novelty = novelty
        self.authority = authority
        self.independentCoverage = independentCoverage
        self.velocity = velocity
        self.recency = recency
        self.diversity = diversity
        self.followedEntity = followedEntity
        self.followedSource = followedSource
        self.followedTopic = followedTopic
        self.savedRelationship = savedRelationship
    }
}

public struct RankedEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: EventRevisionID { revision.id }
    public var revision: EventRevision
    public var score: Double
    public var reasons: [RankingReason]

    public init(revision: EventRevision, score: Double, reasons: [RankingReason]) {
        self.revision = revision
        self.score = score
        self.reasons = reasons
    }
}

public enum RankingEngine {
    public static func rank(_ inputs: [(EventRevision, RankingSignals)]) -> [RankedEvent] {
        inputs.map { revision, signals in
            let score = 0.20 * clamp(signals.importance)
                + 0.17 * clamp(signals.personalRelevance)
                + 0.12 * clamp(signals.novelty)
                + 0.12 * clamp(signals.authority)
                + 0.11 * clamp(signals.independentCoverage)
                + 0.09 * clamp(signals.velocity)
                + 0.09 * clamp(signals.recency)
                + 0.05 * clamp(signals.diversity)
                + (signals.followedEntity ? 0.025 : 0)
                + (signals.followedSource ? 0.015 : 0)
                + (signals.followedTopic ? 0.01 : 0)
                + (signals.savedRelationship ? 0.01 : 0)
            var reasons: [RankingReason] = []
            if signals.followedEntity { reasons.append(.followedPerson) }
            if signals.followedSource { reasons.append(.followedSource) }
            if signals.followedTopic { reasons.append(.followedTopic) }
            if signals.authority >= 0.75 { reasons.append(.primarySource) }
            if signals.independentCoverage >= 0.65 { reasons.append(.independentCoverage) }
            if signals.velocity >= 0.72 { reasons.append(.rapidGrowth) }
            if signals.novelty >= 0.72 { reasons.append(.novelDevelopment) }
            if signals.savedRelationship { reasons.append(.savedRelationship) }
            return RankedEvent(revision: revision, score: score, reasons: reasons)
        }.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.revision.id.description < rhs.revision.id.description : lhs.score > rhs.score
        }
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

public struct MetricVelocitySample: Codable, Hashable, Sendable {
    public var value: Double
    public var date: Date

    public init(value: Double, date: Date) { self.value = value; self.date = date }
}

public enum MetricVelocity {
    public static func perHour(_ samples: [MetricVelocitySample]) -> Double? {
        let ordered = samples.sorted { $0.date < $1.date }
        guard let first = ordered.first, let last = ordered.last, last.date > first.date else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        return max(0, last.value - first.value) / hours
    }
}
