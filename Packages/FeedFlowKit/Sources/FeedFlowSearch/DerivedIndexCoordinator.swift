import FeedFlowStorage
import Foundation

public struct DerivedIndexUpdate: Codable, Hashable, Sendable {
    public var documentCount: Int
    public var canonicalGeneration: Int64

    public init(documentCount: Int, canonicalGeneration: Int64) {
        self.documentCount = documentCount
        self.canonicalGeneration = canonicalGeneration
    }
}

public actor DerivedIndexCoordinator {
    private let repository: FeedFlowRepository
    public let store: DerivedSearchStore

    public init(repository: FeedFlowRepository, directory: URL) throws {
        self.repository = repository
        store = try DerivedSearchStore(directory: directory)
    }

    public func synchronize(force: Bool = false) async throws -> DerivedIndexUpdate {
        let generations = try await repository.generations()
        let canonical = generations[.searchInputs]?.generation ?? 0
        if !force, try await store.indexedGeneration() == canonical {
            return DerivedIndexUpdate(documentCount: 0, canonicalGeneration: canonical)
        }
        let stored = try await repository.searchDocuments(includeHistory: true)
        let documents = stored.compactMap { value -> SearchDocument? in
            guard let kind = SearchDocumentKind(rawValue: value.kind) else { return nil }
            return SearchDocument(
                stableID: value.stableID,
                kind: kind,
                revisionID: value.revisionID,
                languageCode: value.languageCode,
                title: value.title,
                body: value.body,
                isHistorical: value.isHistorical
            )
        }
        try await store.synchronize(documents, canonicalGeneration: canonical)
        return DerivedIndexUpdate(documentCount: documents.count, canonicalGeneration: canonical)
    }
}
