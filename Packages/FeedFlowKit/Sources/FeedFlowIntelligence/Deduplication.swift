import Foundation

public enum DuplicateClassification: String, Codable, CaseIterable, Sendable {
    case exactDuplicate, alias, repost, syndication, translation, quotation, independentCoverage, unrelated
}

public struct DuplicateSignals: Codable, Hashable, Sendable {
    public var sameExternalID: Bool
    public var sameCanonicalURL: Bool
    public var sameContentHash: Bool
    public var titleSimilarity: Double
    public var shingleSimilarity: Double
    public var sameAuthor: Bool
    public var timeDistance: TimeInterval?
    public var declaresCitation: Bool
    public var languageMatch: Bool

    public init(sameExternalID: Bool = false, sameCanonicalURL: Bool = false, sameContentHash: Bool = false, titleSimilarity: Double = 0, shingleSimilarity: Double = 0, sameAuthor: Bool = false, timeDistance: TimeInterval? = nil, declaresCitation: Bool = false, languageMatch: Bool = true) {
        self.sameExternalID = sameExternalID
        self.sameCanonicalURL = sameCanonicalURL
        self.sameContentHash = sameContentHash
        self.titleSimilarity = titleSimilarity
        self.shingleSimilarity = shingleSimilarity
        self.sameAuthor = sameAuthor
        self.timeDistance = timeDistance
        self.declaresCitation = declaresCitation
        self.languageMatch = languageMatch
    }
}

public enum DeterministicDeduplicator {
    public static func classify(_ signals: DuplicateSignals) -> DuplicateClassification {
        if signals.sameExternalID || signals.sameContentHash { return .exactDuplicate }
        if signals.sameCanonicalURL { return .alias }
        if !signals.languageMatch, signals.titleSimilarity > 0.82 { return .translation }
        if signals.declaresCitation, signals.shingleSimilarity < 0.45 { return .quotation }
        if signals.shingleSimilarity > 0.88, signals.titleSimilarity > 0.75 {
            return signals.sameAuthor ? .repost : .syndication
        }
        if signals.titleSimilarity > 0.65, signals.shingleSimilarity < 0.7 { return .independentCoverage }
        return .unrelated
    }
}
