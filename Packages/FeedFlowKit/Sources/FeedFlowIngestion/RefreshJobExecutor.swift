import FeedFlowConnectors
import FeedFlowDomain
import FeedFlowStorage
import Foundation

public enum FeedFlowJobKind {
    public static let refresh = "refresh"
    public static let importInbox = "import"
    public static let index = "index"
    public static let rank = "rank"
    public static let today = "today"
    public static let notify = "notify"
}

public struct RefreshJobPayload: Codable, Hashable, Sendable {
    public var endpointID: SourceEndpointID
    public var maximumPages: Int

    public init(endpointID: SourceEndpointID, maximumPages: Int = 10) {
        self.endpointID = endpointID
        self.maximumPages = max(1, min(maximumPages, 100))
    }
}

public struct RefreshJobCheckpoint: Codable, Hashable, Sendable {
    public var pages: Int
    public var candidates: Int
    public var itemRevisions: Int
    public var cursor: StoredSyncCursor?
}

public enum JobExecutionError: LocalizedError {
    case unsupportedKind(String)
    case missingEndpoint(SourceEndpointID)
    case missingConnector(ConnectorKind)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unsupportedKind(kind): "No executor is registered for durable job kind \(kind)."
        case let .missingEndpoint(id): "Source endpoint \(id) no longer exists."
        case let .missingConnector(kind): "Connector \(kind.rawValue) is unavailable in this process."
        case .cancelled: "The durable job was cancelled."
        }
    }
}

public actor RefreshJobExecutor {
    private let repository: FeedFlowRepository
    private let connectors: ConnectorRegistry
    private let ingestion: IngestionPipeline

    public init(repository: FeedFlowRepository, connectors: ConnectorRegistry, blobStore: CanonicalBlobStore? = nil) {
        self.repository = repository
        self.connectors = connectors
        ingestion = IngestionPipeline(repository: repository, blobStore: blobStore)
    }

    public func execute(job: DurableJob, lease initialLease: JobLease) async throws -> RefreshJobCheckpoint {
        guard job.kind == FeedFlowJobKind.refresh else { throw JobExecutionError.unsupportedKind(job.kind) }
        let payload = try JSONDecoder().decode(RefreshJobPayload.self, from: job.payload)
        guard let endpoint = try await repository.sourceEndpoint(id: payload.endpointID) else { throw JobExecutionError.missingEndpoint(payload.endpointID) }
        guard let connector = await connectors.connector(for: endpoint.connector) else { throw JobExecutionError.missingConnector(endpoint.connector) }

        let startedAt = Date.now
        var lease = initialLease
        var cursor = try await repository.syncCursor(endpointID: endpoint.id).map { ConnectorCursor(family: $0.family, encodedValue: $0.data) }
        var pages = 0
        var candidateCount = 0
        var revisionCount = 0

        while pages < payload.maximumPages {
            if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
            if lease.expiresAt.timeIntervalSinceNow < 30 { lease = try await repository.renewLease(lease, duration: 120) }

            let page = try await connector.refresh(endpoint: endpoint, cursor: cursor, context: ConnectorContext())
            for candidate in page.candidates {
                let complete = try await connector.fetchContent(candidate: candidate, context: ConnectorContext())
                let result = try await ingestion.ingest(candidate: complete, sourceID: endpoint.sourceID, endpointID: endpoint.id)
                candidateCount += 1
                if result.createdRevision { revisionCount += 1 }
            }
            _ = try await repository.markRemoteDeleted(endpointID: endpoint.id, externalIDs: page.deletionExternalIDs)
            cursor = page.nextCursor
            pages += 1
            if page.reachedEnd || page.nextCursor == nil { break }
        }

        let stored = cursor.map { StoredSyncCursor(family: $0.family, data: $0.value) }
        _ = try await repository.finishSync(endpointID: endpoint.id, cursor: stored, itemCount: candidateCount, startedAt: startedAt)
        return RefreshJobCheckpoint(pages: pages, candidates: candidateCount, itemRevisions: revisionCount, cursor: stored)
    }
}

public enum JobRetryClassifier {
    public static func classify(_ error: Error, attempt: Int, now: Date = .now) -> (name: String, retryAt: Date) {
        let base: TimeInterval
        let name: String
        switch error {
        case ConnectorError.authenticationRequired, ConnectorError.interactionRequired:
            name = "authentication"; base = 60 * 60
        case let ConnectorError.rateLimited(retryAfter):
            name = "rateLimit"; base = retryAfter ?? 15 * 60
        case ConnectorError.platformChanged:
            name = "platformChanged"; base = 6 * 60 * 60
        case ConnectorError.policyDenied, JobExecutionError.cancelled:
            name = "policyOrCancellation"; base = 24 * 60 * 60
        case JobExecutionError.missingEndpoint, JobExecutionError.missingConnector, JobExecutionError.unsupportedKind:
            name = "permanentConfiguration"; base = 24 * 60 * 60
        default:
            name = "transient"; base = min(6 * 60 * 60, pow(2, Double(min(attempt, 10))) * 15)
        }
        return (name, now.addingTimeInterval(base))
    }
}
