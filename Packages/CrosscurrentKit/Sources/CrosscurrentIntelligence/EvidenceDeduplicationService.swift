import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct DeduplicationMaintenanceResult: Codable, Hashable, Sendable {
    public var itemsExamined: Int
    public var pairsClassified: Int
    public var duplicateFamiliesUpdated: Int

    public init(itemsExamined: Int = 0, pairsClassified: Int = 0, duplicateFamiliesUpdated: Int = 0) {
        self.itemsExamined = itemsExamined
        self.pairsClassified = pairsClassified
        self.duplicateFamiliesUpdated = duplicateFamiliesUpdated
    }
}

/// Persists bounded, provider-free duplicate/coverage decisions before Event candidate
/// generation. Items remain immutable evidence; relations only affect independence and scoring.
public actor EvidenceDeduplicationService {
    private struct Features {
        var titleTokens: Set<String>
        var shingles: Set<String>
        var normalizedAuthor: String?
        var languageFamily: String
    }

    private struct CandidatePair: Hashable, Comparable {
        var left: Int
        var right: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.left == rhs.left ? lhs.right < rhs.right : lhs.left < rhs.left
        }
    }

    private let repository: CrosscurrentRepository

    public init(repository: CrosscurrentRepository) {
        self.repository = repository
    }

    public func run(limit: Int = 1_000) async throws -> DeduplicationMaintenanceResult {
        let evidence = try await repository.currentItemDeduplicationEvidence(limit: limit)
        var result = DeduplicationMaintenanceResult(itemsExamined: evidence.count)
        guard evidence.count > 1 else { return result }
        let features = evidence.map(makeFeatures)

        for pair in candidatePairs(evidence: evidence, features: features).sorted() {
            let leftIndex = pair.left
            let rightIndex = pair.right
            let left = evidence[leftIndex]
            let right = evidence[rightIndex]
            guard isPlausiblePair(left, right, features[leftIndex], features[rightIndex]) else { continue }
            let signals = signals(left, right, features[leftIndex], features[rightIndex])
            let classification = DeterministicDeduplicator.classify(signals)
            guard classification != .unrelated else { continue }
            let groupsAsDuplicate = Self.groupsAsDuplicate(classification)
            let saved = try await repository.saveItemRelation(
                from: left.itemID,
                to: right.itemID,
                relationship: classification.rawValue,
                confidence: confidence(for: classification, signals: signals),
                groupsAsDuplicate: groupsAsDuplicate
            )
            if saved {
                result.pairsClassified += 1
                if groupsAsDuplicate { result.duplicateFamiliesUpdated += 1 }
            }
        }
        return result
    }

    private func candidatePairs(evidence: [CurrentItemDeduplicationEvidence], features: [Features]) -> Set<CandidatePair> {
        let maximumSignalCandidatesPerItem = 48
        let maximumPostingsPerSignal = 64
        var externalIDs: [String: [Int]] = [:]
        var canonicalURLs: [String: [Int]] = [:]
        var contentHashes: [String: [Int]] = [:]
        var titleTokens: [String: [Int]] = [:]
        var shinglePostings: [String: [Int]] = [:]
        var pairs: Set<CandidatePair> = []

        for index in evidence.indices {
            let item = evidence[index]
            var stableCandidates: Set<Int> = []
            var signalCandidates: Set<Int> = []
            if !item.externalID.isEmpty {
                stableCandidates.formUnion(externalIDs["\(item.sourceID.description):\(item.externalID)"] ?? [])
            }
            if let url = item.canonicalURL?.absoluteString { stableCandidates.formUnion(canonicalURLs[url] ?? []) }
            if !item.contentHash.isEmpty { stableCandidates.formUnion(contentHashes[item.contentHash] ?? []) }
            for token in features[index].titleTokens { signalCandidates.formUnion(titleTokens[token] ?? []) }
            for shingle in features[index].shingles { signalCandidates.formUnion(shinglePostings[shingle] ?? []) }

            for previous in stableCandidates { pairs.insert(CandidatePair(left: previous, right: index)) }
            for previous in signalCandidates.sorted(by: >).prefix(maximumSignalCandidatesPerItem) {
                pairs.insert(CandidatePair(left: previous, right: index))
            }

            if !item.externalID.isEmpty {
                append(index, to: "\(item.sourceID.description):\(item.externalID)", in: &externalIDs, limit: maximumPostingsPerSignal)
            }
            if let url = item.canonicalURL?.absoluteString { append(index, to: url, in: &canonicalURLs, limit: maximumPostingsPerSignal) }
            if !item.contentHash.isEmpty { append(index, to: item.contentHash, in: &contentHashes, limit: maximumPostingsPerSignal) }
            for token in features[index].titleTokens { append(index, to: token, in: &titleTokens, limit: maximumPostingsPerSignal) }
            for shingle in features[index].shingles { append(index, to: shingle, in: &shinglePostings, limit: maximumPostingsPerSignal) }
        }
        return pairs
    }

    private func append(_ index: Int, to key: String, in postings: inout [String: [Int]], limit: Int) {
        var values = postings[key] ?? []
        values.append(index)
        if values.count > limit { values.removeFirst(values.count - limit) }
        postings[key] = values
    }

    private func makeFeatures(_ item: CurrentItemDeduplicationEvidence) -> Features {
        Features(
            titleTokens: tokens(item.title),
            shingles: shingles(item.text),
            normalizedAuthor: normalized(item.author),
            languageFamily: languageFamily(item.languageCode)
        )
    }

    private func isPlausiblePair(
        _ lhs: CurrentItemDeduplicationEvidence,
        _ rhs: CurrentItemDeduplicationEvidence,
        _ left: Features,
        _ right: Features
    ) -> Bool {
        if !lhs.contentHash.isEmpty, lhs.contentHash == rhs.contentHash { return true }
        if let canonicalURL = lhs.canonicalURL, canonicalURL == rhs.canonicalURL { return true }
        if !lhs.externalID.isEmpty, lhs.sourceID == rhs.sourceID, lhs.externalID == rhs.externalID { return true }
        if let leftDate = lhs.publishedAt, let rightDate = rhs.publishedAt,
           abs(leftDate.timeIntervalSince(rightDate)) > 45 * 86_400 { return false }
        let title = similarity(left.titleTokens, right.titleTokens)
        if title >= 0.32 { return true }
        return similarity(left.shingles, right.shingles) >= 0.35
    }

    private func signals(
        _ lhs: CurrentItemDeduplicationEvidence,
        _ rhs: CurrentItemDeduplicationEvidence,
        _ left: Features,
        _ right: Features
    ) -> DuplicateSignals {
        DuplicateSignals(
            sameExternalID: lhs.sourceID == rhs.sourceID && lhs.externalID == rhs.externalID,
            sameCanonicalURL: lhs.canonicalURL != nil && lhs.canonicalURL == rhs.canonicalURL,
            sameContentHash: lhs.contentHash == rhs.contentHash,
            titleSimilarity: similarity(left.titleTokens, right.titleTokens),
            shingleSimilarity: similarity(left.shingles, right.shingles),
            sameAuthor: left.normalizedAuthor != nil && left.normalizedAuthor == right.normalizedAuthor,
            timeDistance: timeDistance(lhs.publishedAt, rhs.publishedAt),
            declaresCitation: declaresCitation(lhs, target: rhs) || declaresCitation(rhs, target: lhs),
            languageMatch: left.languageFamily == right.languageFamily
        )
    }

    private func similarity(_ left: Set<String>, _ right: Set<String>) -> Double {
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    private func shingles(_ value: String) -> Set<String> {
        let values = orderedTokens(value)
        guard values.count >= 3 else { return Set(values) }
        return Set((0...(values.count - 3)).map { values[$0...($0 + 2)].joined(separator: " ") })
    }

    private func tokens(_ value: String) -> Set<String> {
        Set(orderedTokens(value))
    }

    private func orderedTokens(_ value: String) -> [String] {
        let normalized = value.precomposedStringWithCanonicalMapping.lowercased()
        let words = normalized.split { $0.isWhitespace || $0.isPunctuation }.map(String.init).filter { $0.count > 1 }
        let han = normalized.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.map(String.init)
        return words + han
    }

    private func declaresCitation(_ source: CurrentItemDeduplicationEvidence, target: CurrentItemDeduplicationEvidence) -> Bool {
        guard let url = target.canonicalURL?.absoluteString else { return false }
        return source.text.localizedCaseInsensitiveContains(url)
    }

    private func normalized(_ value: String?) -> String? {
        value?.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    private func languageFamily(_ code: String?) -> String {
        guard let code else { return "unknown" }
        return code.lowercased().split(separator: "-").first.map(String.init) ?? "unknown"
    }

    private func timeDistance(_ lhs: Date?, _ rhs: Date?) -> TimeInterval? {
        guard let lhs, let rhs else { return nil }
        return abs(lhs.timeIntervalSince(rhs))
    }

    private func confidence(for classification: DuplicateClassification, signals: DuplicateSignals) -> Confidence {
        switch classification {
        case .exactDuplicate: Confidence(0.99)
        case .alias: Confidence(0.97)
        case .repost, .syndication: Confidence(max(0.82, signals.shingleSimilarity))
        case .translation: Confidence(0.82)
        case .quotation: Confidence(0.8)
        case .independentCoverage: Confidence(0.72)
        case .unrelated: .unknown
        }
    }

    private static func groupsAsDuplicate(_ classification: DuplicateClassification) -> Bool {
        switch classification {
        case .exactDuplicate, .alias, .repost, .syndication, .translation: true
        case .quotation, .independentCoverage, .unrelated: false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
