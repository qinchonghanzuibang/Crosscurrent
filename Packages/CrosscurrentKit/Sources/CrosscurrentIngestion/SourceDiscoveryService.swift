import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentStorage
import Foundation

public struct SourceDiscoveryCommit: Sendable {
    public var sourceID: SourceID
    public var endpointIDs: [SourceEndpointID]
    public var importedItems: Int
}

public enum SourceDiscoveryAction: String, Codable, CaseIterable, Sendable {
    case subscribe
    case importOnce
    case monitor
}

/// A non-mutating discovery result. Callers must explicitly commit one of the
/// advertised actions before the Source or any sample Item is persisted.
public struct SourceDiscoveryPreview: Codable, Hashable, Sendable {
    public var inputURL: URL?
    public var inputQuery: String?
    public var connectorKind: ConnectorKind
    public var result: ConnectorDiscoveryResult
    public var availableActions: [SourceDiscoveryAction]

    public init(inputURL: URL? = nil, inputQuery: String? = nil, connectorKind: ConnectorKind, result: ConnectorDiscoveryResult, availableActions: [SourceDiscoveryAction]) {
        self.inputURL = inputURL
        self.inputQuery = inputQuery
        self.connectorKind = connectorKind
        self.result = result
        self.availableActions = availableActions
    }
}

public actor SourceDiscoveryService {
    private let repository: CrosscurrentRepository
    private let ingestion: IngestionPipeline
    private let connectors: ConnectorRegistry?
    private let articleEnricher: ArticleContentEnricher

    public init(repository: CrosscurrentRepository, connectors: ConnectorRegistry? = nil, blobStore: CanonicalBlobStore? = nil, http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.repository = repository
        self.connectors = connectors
        ingestion = IngestionPipeline(repository: repository, blobStore: blobStore)
        articleEnricher = ArticleContentEnricher(http: http)
    }

    public func preview(_ input: ConnectorDiscoveryInput, context: ConnectorContext) async throws -> SourceDiscoveryPreview {
        guard let connectors else { throw ConnectorError.temporarilyUnavailable }
        let ordered = Self.connectorOrder(for: input.url)
        var lastError: Error = ConnectorError.unsupportedInput
        for kind in ordered {
            guard let connector = await connectors.connector(for: kind), connector.capabilities.contains(.discovery) else { continue }
            do {
                let result = try await connector.discover(input: input, context: context)
                let actions: [SourceDiscoveryAction] = kind == .website ? [.importOnce, .monitor] : [.subscribe]
                return SourceDiscoveryPreview(inputURL: input.url, connectorKind: kind, result: result, availableActions: actions)
            } catch ConnectorError.unsupportedInput {
                continue
            } catch {
                lastError = error
                if kind != .rss && kind != .website { throw error }
            }
        }
        throw lastError
    }

    public func search(_ query: String, context: ConnectorContext) async throws -> [SourceDiscoveryPreview] {
        guard let connectors else { throw ConnectorError.temporarilyUnavailable }
        let normalized = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return try await connectors.search(query: normalized, context: context).map { kind, result in
            SourceDiscoveryPreview(inputQuery: normalized, connectorKind: kind, result: result, availableActions: [.subscribe])
        }
    }

    /// Broader index search is explicitly submitted separately from free catalog
    /// search so normal discovery cannot consume a configured provider's quota.
    public func searchMore(_ query: String, context: ConnectorContext) async throws -> [SourceDiscoveryPreview] {
        guard let connectors,
              let connector = await connectors.connector(for: .weChatOfficialAccount) as? WeChatConnector
        else { throw ConnectorError.temporarilyUnavailable }
        let normalized = query.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        return try await connector.searchMore(query: normalized, context: context).map {
            SourceDiscoveryPreview(inputQuery: normalized, connectorKind: .weChatOfficialAccount, result: $0, availableActions: [.subscribe])
        }
    }

    /// Compatibility entry point for bulk importers. Interactive UI must use
    /// `preview` followed by `commit(_:action:)` so discovery never subscribes
    /// merely because a URL was inspected.
    public func discover(_ input: ConnectorDiscoveryInput, context: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let preview = try await preview(input, context: context)
        _ = try await commit(preview, action: preview.availableActions.first ?? .subscribe)
        return preview.result
    }

    public func commit(_ preview: SourceDiscoveryPreview, action: SourceDiscoveryAction) async throws -> SourceDiscoveryCommit {
        guard preview.availableActions.contains(action) else { throw ConnectorError.unsupportedInput }
        var result = preview.result
        if action == .importOnce {
            result.endpoints = result.endpoints.map { endpoint in
                var endpoint = endpoint
                endpoint.connector = .importedURL
                return endpoint
            }
        }
        // One search may return distinct publishers, including same-name accounts.
        let publisherIdentity = result.endpoints.flatMap(\.weChatAccountAliases).sorted().first ?? result.source.id.description
        let publisherKey = preview.connectorKind == .weChatOfficialAccount ? ":publisher:\(publisherIdentity)" : ""
        return try await commit(
            result,
            idempotencyPrefix: "discover:\(preview.connectorKind.rawValue):\(action.rawValue):\(preview.inputURL?.absoluteString ?? preview.inputQuery ?? result.endpoints.first?.externalID ?? result.source.id.description)\(publisherKey)"
        )
    }

    public func commit(_ result: ConnectorDiscoveryResult, idempotencyPrefix: String) async throws -> SourceDiscoveryCommit {
        if let existing = try await existingSource(matching: result) {
            if result.endpoints.contains(where: { $0.connector == .weChatOfficialAccount }) {
                _ = try await repository.attachWeChatEndpoints(result.endpoints, to: existing.source.id)
            }
            let endpoints = try await repository.sourceEndpoints(sourceID: existing.source.id)
            var imported = 0
            if let endpoint = endpoints.first(where: { Self.endpoint($0, matchesAnyIn: result) }) {
                for candidate in result.recentCandidates {
                    let complete = try await articleEnricher.enrich(candidate, connector: endpoint.connector)
                    let value = try await ingestion.ingest(candidate: complete, sourceID: existing.source.id, endpointID: endpoint.id)
                    if value.createdRevision { imported += 1 }
                }
            }
            return SourceDiscoveryCommit(
                sourceID: existing.source.id,
                endpointIDs: endpoints.map(\.id),
                importedItems: imported
            )
        }
        do {
            _ = try await repository.saveSource(
                result.source,
                revision: result.sourceRevision,
                endpoints: result.endpoints,
                aiClassification: result.aiClassification,
                coverage: result.coverageCandidate,
                idempotencyKey: "\(idempotencyPrefix):source"
            )
        } catch CrosscurrentStorageError.sourceIdentityConflict {
            // Another foreground/import task won after our preview lookup. Its
            // Source is canonical; reread and attach this qualified acquisition.
            return try await commit(result, idempotencyPrefix: idempotencyPrefix)
        }
        for entity in result.entityCandidates {
            let revision = EntityRevision(
                id: entity.currentRevisionID,
                entityID: entity.id,
                displayName: entity.displayName
            )
            _ = try await repository.saveEntity(
                entity,
                revision: revision,
                aliases: [],
                idempotencyKey: "\(idempotencyPrefix):entity:\(entity.id)"
            )
        }
        for relationship in result.sourceEntityRelationships {
            _ = try await repository.saveSourceEntityRelationship(
                relationship,
                idempotencyKey: "\(idempotencyPrefix):source-entity:\(relationship.id.uuidString.lowercased())"
            )
        }
        var imported = 0
        if let endpoint = result.endpoints.first {
            for candidate in result.recentCandidates {
                let complete = try await articleEnricher.enrich(candidate, connector: endpoint.connector)
                let value = try await ingestion.ingest(
                    candidate: complete,
                    sourceID: result.source.id,
                    endpointID: endpoint.id
                )
                if value.createdRevision { imported += 1 }
            }
        }
        return SourceDiscoveryCommit(sourceID: result.source.id, endpointIDs: result.endpoints.map(\.id), importedItems: imported)
    }

    private func existingSource(matching result: ConnectorDiscoveryResult) async throws -> StoredSourceSnapshot? {
        return try await repository.sourceSnapshots().first { snapshot in
            snapshot.endpoints.contains { Self.endpoint($0, matchesAnyIn: result) }
        }
    }

    private static func endpoint(_ endpoint: SourceEndpoint, matchesAnyIn result: ConnectorDiscoveryResult) -> Bool {
        let canonical = endpoint.canonicalURL.map(URLNormalizer.canonicalize)?.absoluteString
        return result.endpoints.contains { discovered in
            guard discovered.connector == endpoint.connector else { return false }
            if endpoint.connector == .weChatOfficialAccount,
               !endpoint.weChatAccountAliases.isDisjoint(with: discovered.weChatAccountAliases) { return true }
            let sameExternalID = !discovered.externalID.isEmpty && discovered.externalID == endpoint.externalID
            let discoveredCanonical = discovered.canonicalURL.map(URLNormalizer.canonicalize)?.absoluteString
            return sameExternalID || (discoveredCanonical != nil && discoveredCanonical == canonical)
        }
    }

    private static func connectorOrder(for url: URL) -> [ConnectorKind] {
        if WeChatCatalogID.allCases.contains(where: { $0.accepts(feedURL: url) }) { return [.weChatOfficialAccount] }
        let host = url.host?.lowercased() ?? ""
        if host == "mp.weixin.qq.com" || host.hasSuffix(".weixin.qq.com") { return [.weChatOfficialAccount] }
        if host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") || host == "xhslink.com" { return [.xiaohongshu] }
        if host == "github.com" { return [.github] }
        if host.hasSuffix("reddit.com") { return [.reddit] }
        if host == "bsky.app" { return [.bluesky] }
        if host == "x.com" || host.hasSuffix("twitter.com") { return [.x] }
        if host == "weibo.com" || host.hasSuffix(".weibo.com") { return [.weibo] }
        if host == "zhihu.com" || host.hasSuffix(".zhihu.com") { return [.zhihu] }
        if host.hasSuffix("arxiv.org") { return [.arxiv] }
        if host == "news.ycombinator.com" { return [.hackerNews] }
        return [.rss, .website]
    }
}
