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
    private let repository: CrosscurrentRepository

    public init(repository: CrosscurrentRepository) {
        self.repository = repository
    }

    public func run(limit: Int = 1_000) async throws -> DeduplicationMaintenanceResult {
        let evidence = try await repository.currentItemDeduplicationEvidence(limit: limit)
        var result = DeduplicationMaintenanceResult(itemsExamined: evidence.count)
        guard evidence.count > 1 else { return result }

        for leftIndex in evidence.indices {
            let left = evidence[leftIndex]
            for rightIndex in evidence.index(after: leftIndex)..<evidence.endIndex {
                let right = evidence[rightIndex]
                guard isPlausiblePair(left, right) else { continue }
                let signals = signals(left, right)
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
        }
        return result
    }

    private func isPlausiblePair(_ lhs: CurrentItemDeduplicationEvidence, _ rhs: CurrentItemDeduplicationEvidence) -> Bool {
        if lhs.contentHash == rhs.contentHash || lhs.canonicalURL == rhs.canonicalURL || lhs.externalID == rhs.externalID { return true }
        if let leftDate = lhs.publishedAt, let rightDate = rhs.publishedAt,
           abs(leftDate.timeIntervalSince(rightDate)) > 45 * 86_400 { return false }
        let title = tokenSimilarity(lhs.title, rhs.title)
        if title >= 0.32 { return true }
        return shingleSimilarity(lhs.text, rhs.text) >= 0.35
    }

    private func signals(_ lhs: CurrentItemDeduplicationEvidence, _ rhs: CurrentItemDeduplicationEvidence) -> DuplicateSignals {
        DuplicateSignals(
            sameExternalID: lhs.sourceID == rhs.sourceID && lhs.externalID == rhs.externalID,
            sameCanonicalURL: lhs.canonicalURL != nil && lhs.canonicalURL == rhs.canonicalURL,
            sameContentHash: lhs.contentHash == rhs.contentHash,
            titleSimilarity: tokenSimilarity(lhs.title, rhs.title),
            shingleSimilarity: shingleSimilarity(lhs.text, rhs.text),
            sameAuthor: normalized(lhs.author) != nil && normalized(lhs.author) == normalized(rhs.author),
            timeDistance: timeDistance(lhs.publishedAt, rhs.publishedAt),
            declaresCitation: declaresCitation(lhs, target: rhs) || declaresCitation(rhs, target: lhs),
            languageMatch: languageFamily(lhs.languageCode) == languageFamily(rhs.languageCode)
        )
    }

    private func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = tokens(lhs)
        let right = tokens(rhs)
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    private func shingleSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = shingles(lhs)
        let right = shingles(rhs)
        let union = left.union(right)
        return union.isEmpty ? 0 : Double(left.intersection(right).count) / Double(union.count)
    }

    private func shingles(_ value: String) -> Set<String> {
        let values = Array(tokens(value).sorted())
        guard values.count >= 3 else { return Set(values) }
        return Set((0...(values.count - 3)).map { values[$0...($0 + 2)].joined(separator: " ") })
    }

    private func tokens(_ value: String) -> Set<String> {
        let normalized = value.precomposedStringWithCanonicalMapping.lowercased()
        let words = normalized.split { $0.isWhitespace || $0.isPunctuation }.map(String.init).filter { $0.count > 1 }
        let han = normalized.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.map(String.init)
        return Set(words + han)
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
