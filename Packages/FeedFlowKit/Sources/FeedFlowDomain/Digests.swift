import Foundation

public enum DigestRevisionReason: String, Codable, CaseIterable, Sendable {
    case initialDaily, materialEvent, majorUpdate, manualRefresh, additionalBriefing
}

public enum DigestSection: String, Codable, CaseIterable, Sendable {
    case today, emerging, peopleYouFollow, worthReading, chinaGlobal, everythingElse
}

public struct Digest: Identifiable, Codable, Hashable, Sendable {
    public var id: DigestID
    public var briefingDay: Date
    public var currentRevisionID: DigestRevisionID

    public init(id: DigestID = DigestID(), briefingDay: Date, currentRevisionID: DigestRevisionID = DigestRevisionID()) {
        self.id = id
        self.briefingDay = briefingDay
        self.currentRevisionID = currentRevisionID
    }
}

public struct DigestRevision: Identifiable, Codable, Hashable, Sendable {
    public var id: DigestRevisionID
    public var digestID: DigestID
    public var parentRevisionID: DigestRevisionID?
    public var reason: DigestRevisionReason
    public var createdAt: Date
    public var entries: [DigestEntry]

    public init(id: DigestRevisionID = DigestRevisionID(), digestID: DigestID, parentRevisionID: DigestRevisionID? = nil, reason: DigestRevisionReason, createdAt: Date = .now, entries: [DigestEntry]) {
        self.id = id
        self.digestID = digestID
        self.parentRevisionID = parentRevisionID
        self.reason = reason
        self.createdAt = createdAt
        self.entries = entries
    }
}

public struct DigestEntry: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var eventRevisionID: EventRevisionID
    public var section: DigestSection
    public var rank: Int
    public var score: Double
    public var explanation: [RankingReason]

    public init(id: UUID = UUID(), eventRevisionID: EventRevisionID, section: DigestSection, rank: Int, score: Double, explanation: [RankingReason]) {
        self.id = id
        self.eventRevisionID = eventRevisionID
        self.section = section
        self.rank = rank
        self.score = score
        self.explanation = explanation
    }
}

public enum RankingReason: String, Codable, CaseIterable, Sendable {
    case followedSource, followedPerson, followedTopic, primarySource, independentCoverage
    case rapidGrowth, novelDevelopment, chinaGlobalCoverage, savedRelationship
}

public enum RevisionReadStatus: String, Codable, CaseIterable, Sendable {
    case unread, read, updated
}

public struct RevisionReadState<ID: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var lastSeenRevisionID: ID?
    public var lastSeenOrdinal: Int?
    public var manualUnread: Bool
    public var lastSeenAt: Date?

    public init(lastSeenRevisionID: ID? = nil, lastSeenOrdinal: Int? = nil, manualUnread: Bool = false, lastSeenAt: Date? = nil) {
        self.lastSeenRevisionID = lastSeenRevisionID
        self.lastSeenOrdinal = lastSeenOrdinal
        self.manualUnread = manualUnread
        self.lastSeenAt = lastSeenAt
    }

    public func status(currentRevisionID: ID, currentOrdinal: Int, isReaderVisible: Bool = true) -> RevisionReadStatus {
        if manualUnread || lastSeenRevisionID == nil { return .unread }
        if lastSeenRevisionID == currentRevisionID { return .read }
        if isReaderVisible, let lastSeenOrdinal, currentOrdinal > lastSeenOrdinal { return .updated }
        return .read
    }
}

public typealias EventReadState = RevisionReadState<EventRevisionID>
public typealias ItemReadState = RevisionReadState<ItemRevisionID>
