import Foundation

public enum ReaderSelectionAction: String, Codable, CaseIterable, Sendable {
    case explain, translate, summarize, askAI
}

public enum ReaderArticleAction: String, Codable, CaseIterable, Sendable {
    case summary, keyPoints, askArticle, relatedEvents, relatedSavedContent, openOriginal
}

public enum ReaderInsightKind: String, Codable, Hashable, Sendable {
    case summary, keyPoints, askArticle, selectionExplain, selectionTranslation, selectionSummary, selectionAnswer, linkPreview
}

public enum ReaderInsightPhase: String, Codable, Hashable, Sendable {
    case loading, ready, unavailable, denied, error
}

public struct ReaderInsightPoint: Codable, Hashable, Sendable {
    public var text: String
    public var citation: String?

    public init(text: String, citation: String? = nil) {
        self.text = text
        self.citation = citation
    }
}

public struct ReaderInsightsState: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ReaderInsightKind
    public var title: String
    public var phase: ReaderInsightPhase
    public var body: String
    public var points: [ReaderInsightPoint]
    public var message: String?
    public var canRetry: Bool

    public init(
        id: UUID = UUID(),
        kind: ReaderInsightKind,
        title: String,
        phase: ReaderInsightPhase = .loading,
        body: String = "",
        points: [ReaderInsightPoint] = [],
        message: String? = nil,
        canRetry: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.phase = phase
        self.body = body
        self.points = points
        self.message = message
        self.canRetry = canRetry
    }
}

public enum ReaderEscapeAction: String, Codable, Hashable, Sendable {
    case closedInsights, exitedFocus, navigateBack
}

public struct ReaderExperienceState: Codable, Hashable, Sendable {
    public var isFocusReading: Bool
    public var insights: ReaderInsightsState?

    public init(isFocusReading: Bool = false, insights: ReaderInsightsState? = nil) {
        self.isFocusReading = isFocusReading
        self.insights = insights
    }

    @discardableResult
    public mutating func handleEscape() -> ReaderEscapeAction {
        if insights != nil {
            insights = nil
            return .closedInsights
        }
        if isFocusReading {
            isFocusReading = false
            return .exitedFocus
        }
        return .navigateBack
    }
}

public struct ReaderEvidenceExcerpt: Codable, Hashable, Sendable {
    public var text: String
    public var citation: String
    public var isPrimary: Bool

    public init(text: String, citation: String, isPrimary: Bool = false) {
        self.text = text
        self.citation = citation
        self.isPrimary = isPrimary
    }
}

public enum ReaderExtractiveInsights {
    public static func summary(from evidence: [ReaderEvidenceExcerpt], fallback: String) -> [ReaderInsightPoint] {
        select(from: evidence, fallback: fallback, maximumCount: 3, maximumCharacters: 720, candidateSentenceLimit: 14)
    }

    public static func keyPoints(from evidence: [ReaderEvidenceExcerpt], fallback: String) -> [ReaderInsightPoint] {
        select(from: evidence, fallback: fallback, maximumCount: 8, maximumCharacters: 1_800)
    }

    public static func validatedSummary(_ text: String) -> String? {
        let values = sentences(in: text).filter { !$0.isEmpty }
        guard (1...4).contains(values.count) else { return nil }
        let result = values.joined(separator: " ")
        return result.count <= 900 ? result : nil
    }

    public static func validatedKeyPoints(_ text: String) -> [String]? {
        let lines = text.components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: #"^(?:[-•*]|\d+[.)])\s+"#, with: "", options: .regularExpression)
            }
            .filter { !$0.isEmpty }
        let values = lines.count >= 4 ? lines : sentences(in: text)
        let unique = values.reduce(into: [String]()) { result, value in
            let normalized = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard value.count <= 320, !result.contains(where: { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalized }) else { return }
            result.append(value)
        }
        guard (4...8).contains(unique.count) else { return nil }
        return unique
    }

    private struct Candidate {
        var point: ReaderInsightPoint
        var order: Int
        var score: Double
    }

    private static func select(from evidence: [ReaderEvidenceExcerpt], fallback: String, maximumCount: Int, maximumCharacters: Int, candidateSentenceLimit: Int? = nil) -> [ReaderInsightPoint] {
        let inputs = evidence.isEmpty ? [ReaderEvidenceExcerpt(text: fallback, citation: "", isPrimary: true)] : evidence
        var candidates: [Candidate] = []
        var order = 0
        for excerpt in inputs {
            let availableSentences = sentences(in: excerpt.text)
            for (position, sentence) in availableSentences.prefix(candidateSentenceLimit ?? availableSentences.count).enumerated() {
                defer { order += 1 }
                guard sentence.count >= 28, sentence.count <= 420 else { continue }
                let idealLength = max(0, 1 - abs(Double(sentence.count - 150)) / 250)
                let materialMarkers = ["because", "found", "shows", "released", "result", "however", "therefore", "研究", "结果", "发布", "因此", "但是"]
                    .reduce(0) { $0 + (sentence.localizedCaseInsensitiveContains($1) ? 1 : 0) }
                let score = (excerpt.isPrimary ? 2.0 : 0) + idealLength + Double(materialMarkers) * 0.35 + max(0, 0.8 - Double(position) * 0.12)
                candidates.append(Candidate(point: ReaderInsightPoint(text: sentence, citation: excerpt.citation.isEmpty ? nil : excerpt.citation), order: order, score: score))
            }
        }

        var selected: [Candidate] = []
        var usedCharacters = 0
        for candidate in candidates.sorted(by: { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }) {
            let normalized = candidate.point.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard selected.count < maximumCount,
                  usedCharacters + candidate.point.text.count <= maximumCharacters,
                  !selected.contains(where: { existing in
                      let other = existing.point.text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                      return normalized == other || normalized.contains(other) || other.contains(normalized)
                  })
            else { continue }
            selected.append(candidate)
            usedCharacters += candidate.point.text.count
        }
        return selected.sorted(by: { $0.order < $1.order }).map(\.point)
    }

    private static func sentences(in text: String) -> [String] {
        var rawValues: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let value = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { rawValues.append(value) }
        }
        if rawValues.isEmpty {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { rawValues.append(value) }
        }
        var values: [String] = []
        for value in rawValues {
            if let last = values.last,
               last.range(of: #"(?:^|\s)[\p{Lu}]\.$"#, options: .regularExpression) != nil {
                values[values.count - 1] += " " + value
            } else {
                values.append(value)
            }
        }
        return values
    }
}

public struct ReaderSelectionContext: Codable, Hashable, Sendable {
    public var itemRevisionID: ItemRevisionID
    public var itemSegmentID: ItemSegmentID?
    public var span: TextSpan
    public var selectedText: String

    public init(itemRevisionID: ItemRevisionID, itemSegmentID: ItemSegmentID? = nil, span: TextSpan, selectedText: String) {
        self.itemRevisionID = itemRevisionID
        self.itemSegmentID = itemSegmentID
        self.span = span
        self.selectedText = selectedText
    }
}

public struct LinkPreview: Codable, Hashable, Sendable {
    public var url: URL
    public var title: String
    public var summary: String?
    public var imageURL: URL?
    public var fetchedWithoutAuthentication: Bool

    public init(url: URL, title: String, summary: String? = nil, imageURL: URL? = nil, fetchedWithoutAuthentication: Bool = true) {
        self.url = url
        self.title = title
        self.summary = summary
        self.imageURL = imageURL
        self.fetchedWithoutAuthentication = fetchedWithoutAuthentication
    }
}

public struct ShareInboxRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var url: URL
    public var title: String?
    public var selectedText: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), url: URL, title: String? = nil, selectedText: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.selectedText = selectedText
        self.createdAt = createdAt
    }
}
