import CryptoKit
import Foundation
import FeedFlowConnectors
import FeedFlowBrowser
import FeedFlowDomain
import FeedFlowStorage

public struct IngestionResult: Sendable {
    public var item: Item
    public var revision: ItemRevision?
    public var createdRevision: Bool
    public var metricsWritten: Int

    public init(item: Item, revision: ItemRevision?, createdRevision: Bool, metricsWritten: Int) {
        self.item = item
        self.revision = revision
        self.createdRevision = createdRevision
        self.metricsWritten = metricsWritten
    }
}

public actor IngestionPipeline {
    private let repository: FeedFlowRepository
    private let blobStore: CanonicalBlobStore?

    public init(repository: FeedFlowRepository, blobStore: CanonicalBlobStore? = nil) {
        self.repository = repository
        self.blobStore = blobStore
    }

    public func ingest(candidate: ConnectorItemCandidate, sourceID: SourceID, endpointID: SourceEndpointID, fetchedAt: Date = .now) async throws -> IngestionResult {
        let existing = try await repository.itemState(endpointID: endpointID, externalID: candidate.externalID)
        let itemID = existing?.itemID ?? ItemID()
        let canonicalURL = candidate.canonicalURL.map(URLNormalizer.canonicalize)
        let normalizedText = normalizeText(candidate.contentText ?? candidate.summary ?? candidate.title)
        let hashInput = [candidate.title, candidate.author ?? "", normalizedText].joined(separator: "\n")
        let contentHash = SHA256.hash(data: Data(hashInput.utf8)).map { String(format: "%02x", $0) }.joined()
        let revisionID = existing?.currentContentHash == contentHash ? existing!.currentRevisionID : ItemRevisionID()
        let item = Item(
            id: itemID,
            sourceID: sourceID,
            sourceEndpointID: endpointID,
            externalID: candidate.externalID,
            canonicalURL: canonicalURL,
            currentRevisionID: revisionID,
            remoteState: candidate.deletionState
        )

        var revision: ItemRevision?
        var createdRevision = false
        if existing?.currentContentHash != contentHash {
            let sanitizedHTML: String?
            if let contentHTML = candidate.contentHTML {
                sanitizedHTML = try StaticHTMLPreprocessor.conservativeSanitize(contentHTML).sanitizedHTML
            } else {
                sanitizedHTML = nil
            }
            let htmlBlob: StoredBlob?
            if let sanitizedHTML, let blobStore {
                htmlBlob = try await blobStore.put(Data(sanitizedHTML.utf8), mediaType: "text/html; charset=utf-8", retentionClass: .durableEvidence)
            } else {
                htmlBlob = nil
            }
            let value = ItemRevision(
                id: revisionID,
                itemID: itemID,
                ordinal: (existing?.currentOrdinal ?? 0) + 1,
                title: candidate.title,
                author: candidate.author,
                publishedAt: candidate.publishedAt,
                modifiedAt: candidate.modifiedAt,
                fetchedAt: fetchedAt,
                languageCode: candidate.languageCode,
                text: normalizedText,
                sanitizedHTML: sanitizedHTML,
                contentHash: contentHash,
                changeKind: existing == nil ? .initial : .contentUpdate
            )
            let previousSegments: [ItemSegment]
            if let existing {
                previousSegments = try await repository.itemSegments(revisionID: existing.currentRevisionID)
            } else {
                previousSegments = []
            }
            let segments = ItemSegmenter.segments(for: value, aligningWith: previousSegments)
            createdRevision = try await repository.saveItem(
                item,
                revision: value,
                segments: segments,
                topicNames: candidate.topicNames,
                sanitizedHTMLBlobID: htmlBlob?.id,
                idempotencyKey: "item:\(endpointID):\(candidate.externalID):\(contentHash)"
            )
            revision = value
        }

        let metrics = candidate.metricSnapshots.map {
            ItemMetricSnapshot(itemID: itemID, sourceEndpointID: endpointID, kind: $0.kind, value: $0.value, capturedAt: $0.capturedAt, connectorKey: $0.connectorKey)
        }
        if !metrics.isEmpty {
            _ = try await repository.saveMetrics(metrics, idempotencyKey: "metrics:\(endpointID):\(candidate.externalID):\(metrics.map { $0.capturedAt.timeIntervalSince1970 }.max() ?? 0)")
        }
        return IngestionResult(item: item, revision: revision, createdRevision: createdRevision, metricsWritten: metrics.count)
    }

    private func normalizeText(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
