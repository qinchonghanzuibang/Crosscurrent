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
    public var manual: Bool

    public init(endpointID: SourceEndpointID, maximumPages: Int = 10, maximumItems: Int? = nil, manual: Bool = false) {
        self.endpointID = endpointID
        self.maximumPages = max(1, min(maximumPages, 100))
        self.maximumItems = maximumItems.map { max(1, min($0, 10_000)) }
        self.manual = manual
    }

    private enum CodingKeys: String, CodingKey { case endpointID, maximumPages, maximumItems, manual }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpointID = try values.decode(SourceEndpointID.self, forKey: .endpointID)
        maximumPages = max(1, min(try values.decodeIfPresent(Int.self, forKey: .maximumPages) ?? 10, 100))
        maximumItems = try values.decodeIfPresent(Int.self, forKey: .maximumItems).map { max(1, min($0, 10_000)) }
        manual = try values.decodeIfPresent(Bool.self, forKey: .manual) ?? false
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

/// A source refresh may resolve many official short URLs before article batches
/// start. Keep its durable lease alive throughout those cancellable network calls.
enum WeChatJobLeaseGuard {
    static func run<Value: Sendable>(repository: CrosscurrentRepository, lease: JobLease, renewalInterval: Duration = .seconds(30), operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
        let renewed = try await repository.renewLease(lease, duration: 300)
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                var held = renewed
                while true {
                    try await Task.sleep(for: renewalInterval)
                    if try await repository.cancellationRequested(for: held) { throw JobExecutionError.cancelled }
                    held = try await repository.renewLease(held, duration: 300)
                }
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw JobExecutionError.cancelled }
            try Task.checkCancellation()
            return result
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

        if let weChat = connector as? WeChatConnector {
            return try await refreshWeChat(weChat, endpoint: endpoint, payload: payload, lease: initialLease)
        }

        let lease = try await repository.renewLease(initialLease, duration: 300)
        return try await WeChatJobLeaseGuard.run(repository: repository, lease: lease) {
            try await self.refresh(connector, endpoint: endpoint, payload: payload, lease: lease)
        }
    }

    private func refresh(_ connector: any Connector, endpoint: SourceEndpoint, payload: RefreshJobPayload, lease: JobLease) async throws -> RefreshJobCheckpoint {
        let startedAt = Date.now
        _ = try await repository.recordSyncStarted(endpointID: endpoint.id, at: startedAt)
        // A pagination position in a changing newest-first listing is not an
        // incremental watermark: every new refresh must visit its newest page.
        var cursor = connector.cursorScope == .incremental
            ? try await repository.syncCursor(endpointID: endpoint.id).map { ConnectorCursor(family: $0.family, encodedValue: $0.data) }
            : nil
        var pages = 0
        var candidateCount = 0
        var revisionCount = 0
        var performedRemoteRequest = false

        while pages < payload.maximumPages {
            try Task.checkCancellation()
            if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }

            let page = try await connector.refresh(endpoint: endpoint, cursor: cursor, context: ConnectorContext())
            performedRemoteRequest = performedRemoteRequest || page.performedRemoteRequest
            // Apply the item budget between complete pages. Advancing a feed
            // fingerprint after ingesting only its prefix would lose its tail.
            for candidate in page.candidates {
                try Task.checkCancellation()
                if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
                let fetched = try await connector.fetchContent(candidate: candidate, context: ConnectorContext())
                let complete = try await articleEnricher.enrich(fetched, connector: endpoint.connector)
                try Task.checkCancellation()
                let result = try await ingestion.ingest(candidate: complete, sourceID: endpoint.sourceID, endpointID: endpoint.id)
                candidateCount += 1
                if result.createdRevision { revisionCount += 1 }
            }
            _ = try await repository.markRemoteDeleted(endpointID: endpoint.id, externalIDs: page.deletionExternalIDs)
            cursor = page.nextCursor
            pages += 1
            if page.reachedEnd || page.nextCursor == nil || payload.maximumItems.map({ candidateCount >= $0 }) == true { break }
        }

        try Task.checkCancellation()
        if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
        let stored = connector.cursorScope == .incremental ? cursor.map { StoredSyncCursor(family: $0.family, data: $0.value) } : nil
        _ = try await repository.finishSync(
            endpointID: endpoint.id,
            cursor: stored,
            itemCount: candidateCount,
            recordsSuccessfulRefresh: performedRemoteRequest,
            startedAt: startedAt
        )
        return RefreshJobCheckpoint(pages: pages, candidates: candidateCount, itemRevisions: revisionCount, cursor: stored)
    }

    private func refreshWeChat(_ connector: WeChatConnector, endpoint: SourceEndpoint, payload: RefreshJobPayload, lease initialLease: JobLease) async throws -> RefreshJobCheckpoint {
        let startedAt = Date.now
        var lease = try await repository.renewLease(initialLease, duration: 300)
        var endpoints = try await repository.sourceEndpoints(sourceID: endpoint.sourceID).filter { $0.connector == .weChatOfficialAccount }
        if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
        // Retrofit PR #6 subscriptions only after public feeds establish a stable
        // identity overlap. A failed qualification retains all existing endpoints.
        let checkKey = "wechat.catalog-qualification:\(endpoint.sourceID)"
        let checked = try await repository.preferenceData(forKey: checkKey).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
        if checked.map({ startedAt.timeIntervalSince($0) >= 86_400 }) ?? true,
           let source = try await repository.sourceSnapshots().first(where: { $0.source.id == endpoint.sourceID }) {
            let savedEndpoints = endpoints
            let qualified = try await WeChatJobLeaseGuard.run(repository: repository, lease: lease) {
                await connector.qualifyFreeEndpoints(for: savedEndpoints, displayName: source.revision.displayName)
            }
            if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
            _ = try await repository.attachWeChatEndpoints(qualified, to: endpoint.sourceID)
            endpoints = try await repository.sourceEndpoints(sourceID: endpoint.sourceID).filter { $0.connector == .weChatOfficialAccount }
            _ = try await repository.savePreferenceData(try JSONEncoder().encode(startedAt), forKey: checkKey)
        }
        if lease.expiresAt.timeIntervalSinceNow < 60 { lease = try await repository.renewLease(lease, duration: 300) }
        let refreshEndpoints = endpoints
        let refresh = try await WeChatJobLeaseGuard.run(repository: repository, lease: lease) {
            await connector.refreshSource(endpoints: refreshEndpoints, context: ConnectorContext(), manual: payload.manual)
        }
        if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
        guard refresh.succeeded else {
            _ = try await repository.finishWeChatSync(endpoints: refresh.endpoints, itemCount: 0, startedAt: startedAt)
            throw ConnectorError.temporarilyUnavailable
        }
        let destination = refresh.endpoints.sorted { ($0.weChatAcquisition?.priority ?? 100) < ($1.weChatAcquisition?.priority ?? 100) }.first ?? endpoint
        var candidates = 0
        var revisions = 0
        var pending: [ConnectorItemCandidate] = []
        for candidate in refresh.candidates.prefix(payload.maximumItems ?? refresh.candidates.count) {
            if let stored = try await repository.weChatItemState(sourceID: endpoint.sourceID, externalID: candidate.externalID, canonicalURL: candidate.canonicalURL, originalURL: candidate.weChatOriginalURL), stored.hasStoredArticleHTML {
                _ = try await repository.recordWeChatItemAliases(itemID: stored.item.itemID, sourceID: endpoint.sourceID, externalID: candidate.externalID, canonicalURL: candidate.canonicalURL, originalURL: candidate.weChatOriginalURL)
                candidates += 1
            } else { pending.append(candidate) }
        }
        // Keep public article requests bounded, then commit evidence sequentially
        // under the same source lease. No canonical transaction spans a request.
        for offset in stride(from: 0, to: pending.count, by: 3) {
            if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
            lease = try await repository.renewLease(lease, duration: 300)
            let batch = Array(pending[offset..<min(offset + 3, pending.count)])
            let enricher = articleEnricher
            let complete = try await withThrowingTaskGroup(of: (Int, ConnectorItemCandidate).self) { group in
                for (index, candidate) in batch.enumerated() {
                    group.addTask {
                        let fetched = try await connector.fetchContent(candidate: candidate, context: ConnectorContext())
                        return (index, try await enricher.enrich(fetched, connector: .weChatOfficialAccount))
                    }
                }
                var result: [(Int, ConnectorItemCandidate)] = []
                for try await candidate in group { result.append(candidate) }
                return result.sorted { $0.0 < $1.0 }.map(\.1)
            }
            if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
            for candidate in complete {
                let result = try await ingestion.ingest(candidate: candidate, sourceID: endpoint.sourceID, endpointID: destination.id)
                candidates += 1
                if result.createdRevision { revisions += 1 }
            }
        }
        // Validators commit only after ingestion so an interrupted backfill can
        // retry its previous validator and receive the complete feed again.
        if try await repository.cancellationRequested(for: lease) { throw JobExecutionError.cancelled }
        _ = try await repository.finishWeChatSync(endpoints: refresh.endpoints, itemCount: candidates, startedAt: startedAt)
        return RefreshJobCheckpoint(pages: refresh.performedRemoteRequest ? 1 : 0, candidates: candidates, itemRevisions: revisions, cursor: nil)
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
        case ConnectorError.configurationRequired, ConnectorError.quotaExhausted:
            name = "configuration"; base = 24 * 60 * 60
        case ConnectorError.accountUnavailable:
            name = "accountUnavailable"; base = 24 * 60 * 60
        case ConnectorError.articleUnavailable:
            name = "articleUnavailable"; base = 6 * 60 * 60
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
        case ConnectorError.configurationRequired, ConnectorError.quotaExhausted: .configurationRequired
        case ConnectorError.accountUnavailable: .error
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
