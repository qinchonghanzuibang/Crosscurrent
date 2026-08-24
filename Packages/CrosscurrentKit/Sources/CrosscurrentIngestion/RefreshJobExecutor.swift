import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public enum CrosscurrentJobKind {
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
    public var maximumItems: Int?

    public init(endpointID: SourceEndpointID, maximumPages: Int = 10, maximumItems: Int? = nil) {
        self.endpointID = endpointID
        self.maximumPages = max(1, min(maximumPages, 100))
        self.maximumItems = maximumItems.map { max(1, min($0, 10_000)) }
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
    private let repository: CrosscurrentRepository
    private let connectors: ConnectorRegistry
    private let ingestion: IngestionPipeline
    private let articleEnricher: ArticleContentEnricher

    public init(repository: CrosscurrentRepository, connectors: ConnectorRegistry, blobStore: CanonicalBlobStore? = nil, http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.repository = repository
        self.connectors = connectors
        ingestion = IngestionPipeline(repository: repository, blobStore: blobStore)
        articleEnricher = ArticleContentEnricher(http: http)
    }

    public func execute(job: DurableJob, lease initialLease: JobLease) async throws -> RefreshJobCheckpoint {
        guard job.kind == CrosscurrentJobKind.refresh else { throw JobExecutionError.unsupportedKind(job.kind) }
        let payload = try JSONDecoder().decode(RefreshJobPayload.self, from: job.payload)
        guard let endpoint = try await repository.sourceEndpoint(id: payload.endpointID) else { throw JobExecutionError.missingEndpoint(payload.endpointID) }
        guard let connector = await connectors.connector(for: endpoint.connector) else { throw JobExecutionError.missingConnector(endpoint.connector) }

        let startedAt = Date.now
        _ = try await repository.recordSyncStarted(endpointID: endpoint.id, at: startedAt)
        var lease = initialLease
        var cursor = try await repository.syncCursor(endpointID: endpoint.id).map { ConnectorCursor(family: $0.family, encodedValue: $0.data) }
        var pages = 0
        var candidateCount = 0
        var revisionCount = 0

        while pages < payload.maximumPages {
            if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
            if lease.expiresAt.timeIntervalSinceNow < 30 { lease = try await repository.renewLease(lease, duration: 120) }

            let page = try await connector.refresh(endpoint: endpoint, cursor: cursor, context: ConnectorContext())
            let remaining = payload.maximumItems.map { max(0, $0 - candidateCount) } ?? page.candidates.count
            for candidate in page.candidates.prefix(remaining) {
                let fetched = try await connector.fetchContent(candidate: candidate, context: ConnectorContext())
                let complete = try await articleEnricher.enrich(fetched, connector: endpoint.connector)
                let result = try await ingestion.ingest(candidate: complete, sourceID: endpoint.sourceID, endpointID: endpoint.id)
                candidateCount += 1
                if result.createdRevision { revisionCount += 1 }
            }
            _ = try await repository.markRemoteDeleted(endpointID: endpoint.id, externalIDs: page.deletionExternalIDs)
            cursor = page.nextCursor
            pages += 1
            if page.reachedEnd || page.nextCursor == nil || payload.maximumItems.map({ candidateCount >= $0 }) == true { break }
        }

        let stored = cursor.map { StoredSyncCursor(family: $0.family, data: $0.value) }
        _ = try await repository.finishSync(endpointID: endpoint.id, cursor: stored, itemCount: candidateCount, startedAt: startedAt)
        return RefreshJobCheckpoint(pages: pages, candidates: candidateCount, itemRevisions: revisionCount, cursor: stored)
    }
}

public enum JobRetryClassifier {
    public static func classify(_ error: Error, attempt: Int, now: Date = .now, jitter: Double = Double.random(in: -0.2...0.2)) -> (name: String, retryAt: Date, exhausted: Bool) {
        let base: TimeInterval
        let name: String
        var isTransient = false
        var honorsRetryAfter = false
        switch error {
        case ConnectorError.authenticationRequired, ConnectorError.interactionRequired:
            name = "authentication"; base = 60 * 60
        case let ConnectorError.rateLimited(retryAfter):
            name = "rateLimit"; base = retryAfter ?? 15 * 60; isTransient = true; honorsRetryAfter = retryAfter != nil
        case let ConnectorError.transientHTTP(_, retryAfter):
            name = "transientHTTP"; base = retryAfter ?? min(30 * 60, pow(2, Double(max(0, attempt - 1))) * 30); isTransient = true; honorsRetryAfter = retryAfter != nil
        case let urlError as URLError where [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code):
            name = "network"; base = min(30 * 60, pow(2, Double(max(0, attempt - 1))) * 30); isTransient = true
        case ConnectorError.platformChanged:
            name = "platformChanged"; base = 6 * 60 * 60
        case ConnectorError.policyDenied, JobExecutionError.cancelled:
            name = "policyOrCancellation"; base = 24 * 60 * 60
        case JobExecutionError.missingEndpoint, JobExecutionError.missingConnector, JobExecutionError.unsupportedKind:
            name = "permanentConfiguration"; base = 24 * 60 * 60
        default:
            name = "transient"; base = min(6 * 60 * 60, pow(2, Double(min(attempt, 10))) * 15); isTransient = true
        }
        let exhausted = isTransient && attempt >= 6
        let boundedJitter = min(0.2, max(-0.2, jitter))
        let delay = exhausted ? 24 * 60 * 60 : max(1, base * (1 + (honorsRetryAfter ? max(0, boundedJitter) : boundedJitter)))
        return (exhausted ? "\(name)Exhausted" : name, now.addingTimeInterval(delay), exhausted)
    }
}

public enum RefreshFailureHealthClassifier {
    public static func health(for error: Error, attempt: Int, hasCachedSuccess: Bool) -> ConnectorHealth {
        switch error {
        case ConnectorError.authenticationRequired, ConnectorError.interactionRequired: .authenticationRequired
        case ConnectorError.rateLimited: hasCachedSuccess && attempt < 3 ? .retrying : .rateLimited
        case ConnectorError.transientHTTP: hasCachedSuccess && attempt < 3 ? .retrying : .temporarilyUnavailable
        case ConnectorError.platformChanged: .platformChanged
        case ConnectorError.policyDenied: .disabled
        default: isTransient(error) && hasCachedSuccess && attempt < 3 ? .retrying : .temporarilyUnavailable
        }
    }

    public static func isTransient(_ error: Error) -> Bool {
        if case ConnectorError.rateLimited = error { return true }
        if case ConnectorError.transientHTTP = error { return true }
        if let url = error as? URLError { return [.timedOut, .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(url.code) }
        return false
    }
}
