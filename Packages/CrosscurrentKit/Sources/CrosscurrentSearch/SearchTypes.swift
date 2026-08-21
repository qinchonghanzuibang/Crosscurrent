import Foundation
import CrosscurrentDomain

public enum SearchDocumentKind: String, Codable, CaseIterable, Sendable {
    case item, event, source, person, organization, topic
}

public struct SearchDocument: Codable, Hashable, Sendable {
    public var stableID: String
    public var kind: SearchDocumentKind
    public var revisionID: String?
    public var languageCode: String?
    public var title: String
    public var body: String
    public var isHistorical: Bool

    public init(stableID: String, kind: SearchDocumentKind, revisionID: String? = nil, languageCode: String? = nil, title: String, body: String, isHistorical: Bool = false) {
        self.stableID = stableID
        self.kind = kind
        self.revisionID = revisionID
        self.languageCode = languageCode
        self.title = title
        self.body = body
        self.isHistorical = isHistorical
    }
}

public struct SearchResult: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(kind.rawValue):\(stableID):\(revisionID ?? "current")" }
    public var stableID: String
    public var kind: SearchDocumentKind
    public var revisionID: String?
    public var title: String
    public var snippet: String
    public var score: Double
    public var isHistorical: Bool

    public init(stableID: String, kind: SearchDocumentKind, revisionID: String?, title: String, snippet: String, score: Double, isHistorical: Bool) {
        self.stableID = stableID
        self.kind = kind
        self.revisionID = revisionID
        self.title = title
        self.snippet = snippet
        self.score = score
        self.isHistorical = isHistorical
    }
}

public struct SearchQuery: Codable, Hashable, Sendable {
    public var text: String
    public var kinds: Set<SearchDocumentKind>
    public var includeHistory: Bool
    public var limit: Int

    public init(text: String, kinds: Set<SearchDocumentKind> = Set(SearchDocumentKind.allCases), includeHistory: Bool = false, limit: Int = 50) {
        self.text = text
        self.kinds = kinds
        self.includeHistory = includeHistory
        self.limit = limit
    }
}

public protocol EmbeddingRuntime: Sendable {
    var descriptor: EmbeddingDescriptor { get async }
    func embed(_ texts: [String], kind: EmbeddingInputKind) async throws -> [[Float]]
    func resourceEstimate(batchSize: Int) async -> EmbeddingResourceEstimate
}

public enum EmbeddingInputKind: String, Codable, Sendable { case query, document }

public struct EmbeddingResourceEstimate: Codable, Hashable, Sendable {
    public var peakBytes: Int64
    public var seconds: Double

    public init(peakBytes: Int64, seconds: Double) {
        self.peakBytes = peakBytes
        self.seconds = seconds
    }
}

public protocol VectorIndex: Sendable {
    var descriptor: EmbeddingDescriptor { get async }
    func upsert(ids: [String], vectors: [[Float]]) async throws
    func search(vector: [Float], limit: Int) async throws -> [(id: String, score: Double)]
    func persist() async throws
}
