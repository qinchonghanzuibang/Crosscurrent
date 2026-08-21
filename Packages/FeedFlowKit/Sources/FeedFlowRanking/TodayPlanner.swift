import Foundation
import FeedFlowDomain

public struct BriefingTime: Codable, Hashable, Sendable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
    }

    public static func < (lhs: BriefingTime, rhs: BriefingTime) -> Bool { (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute) }
}

public struct BriefingSchedule: Codable, Hashable, Sendable {
    public var dailyTime: BriefingTime
    public var additionalTimes: [BriefingTime]

    public init(dailyTime: BriefingTime = BriefingTime(hour: 8, minute: 0), additionalTimes: [BriefingTime] = []) {
        self.dailyTime = dailyTime
        self.additionalTimes = Array(Set(additionalTimes.filter { $0 != dailyTime })).sorted()
    }
}

public enum TodayTrigger: Codable, Hashable, Sendable {
    case opening
    case scheduled(BriefingTime)
    case eventChanged(EventChangeMateriality)
    case manualRefresh
}

public struct EventChangeMateriality: Codable, Hashable, Sendable {
    public var isNewEvent: Bool
    public var changeKind: RevisionChangeKind
    public var importance: Double
    public var evidenceGrowth: Int
    public var primarySourceArrived: Bool
    public var corrected: Bool
    public var lineageChanged: Bool

    public init(isNewEvent: Bool = false, changeKind: RevisionChangeKind, importance: Double, evidenceGrowth: Int = 0, primarySourceArrived: Bool = false, corrected: Bool = false, lineageChanged: Bool = false) {
        self.isNewEvent = isNewEvent
        self.changeKind = changeKind
        self.importance = importance
        self.evidenceGrowth = evidenceGrowth
        self.primarySourceArrived = primarySourceArrived
        self.corrected = corrected
        self.lineageChanged = lineageChanged
    }

    public var isMaterial: Bool {
        if corrected || lineageChanged || primarySourceArrived { return true }
        if changeKind == .majorUpdate || changeKind == .correction || changeKind == .merge || changeKind == .split { return true }
        if isNewEvent { return importance >= 0.55 }
        return importance >= 0.72 && evidenceGrowth >= 2 && changeKind.isReaderVisible
    }
}

public struct TodayState: Codable, Hashable, Sendable {
    public var briefingDay: Date
    public var initialRevisionID: DigestRevisionID?
    public var latestRevisionID: DigestRevisionID?
    public var completedAdditionalTimes: Set<BriefingTime>

    public init(briefingDay: Date, initialRevisionID: DigestRevisionID? = nil, latestRevisionID: DigestRevisionID? = nil, completedAdditionalTimes: Set<BriefingTime> = []) {
        self.briefingDay = briefingDay
        self.initialRevisionID = initialRevisionID
        self.latestRevisionID = latestRevisionID
        self.completedAdditionalTimes = completedAdditionalTimes
    }
}

public enum TodayDecision: Equatable, Sendable {
    case noRevision
    case create(reason: DigestRevisionReason, parent: DigestRevisionID?)
}

public enum TodayPlanner {
    public static func decision(trigger: TodayTrigger, state: TodayState, schedule: BriefingSchedule) -> TodayDecision {
        guard let initial = state.initialRevisionID else {
            switch trigger {
            case .opening, .manualRefresh:
                return .create(reason: .initialDaily, parent: nil)
            case let .scheduled(time) where time == schedule.dailyTime || schedule.additionalTimes.contains(time):
                return .create(reason: .initialDaily, parent: nil)
            case .eventChanged, .scheduled:
                return .noRevision
            }
        }

        switch trigger {
        case .opening:
            return .noRevision
        case .manualRefresh:
            return .create(reason: .manualRefresh, parent: state.latestRevisionID ?? initial)
        case let .eventChanged(materiality):
            guard materiality.isMaterial else { return .noRevision }
            return .create(reason: materiality.isNewEvent ? .materialEvent : .majorUpdate, parent: state.latestRevisionID ?? initial)
        case let .scheduled(time):
            guard schedule.additionalTimes.contains(time), !state.completedAdditionalTimes.contains(time) else { return .noRevision }
            return .create(reason: .additionalBriefing, parent: state.latestRevisionID ?? initial)
        }
    }
}

public struct CoverageEvidence: Codable, Hashable, Sendable {
    public var ecosystem: CoverageEcosystem
    public var independenceGroup: String

    public init(ecosystem: CoverageEcosystem, independenceGroup: String) {
        self.ecosystem = ecosystem
        self.independenceGroup = independenceGroup
    }
}

public enum ChinaGlobalCoverageGate {
    public static func isSufficient(_ evidence: [CoverageEvidence]) -> Bool {
        let china = Set(evidence.filter { $0.ecosystem == .chinaFocused }.map(\.independenceGroup))
        let global = Set(evidence.filter { $0.ecosystem == .globalFocused }.map(\.independenceGroup))
        return china.count >= 2 && global.count >= 2
    }
}
