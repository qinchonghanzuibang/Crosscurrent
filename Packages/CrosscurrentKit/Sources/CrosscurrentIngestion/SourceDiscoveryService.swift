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
    public var inputURL: URL
    public var connectorKind: ConnectorKind
    public var result: ConnectorDiscoveryResult
    public var availableActions: [SourceDiscoveryAction]

    public init(inputURL: URL, connectorKind: ConnectorKind, result: ConnectorDiscoveryResult, availableActions: [SourceDiscoveryAction]) {
        self.inputURL = inputURL
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
        return try await commit(
            result,
            idempotencyPrefix: "discover:\(preview.connectorKind.rawValue):\(action.rawValue):\(preview.inputURL.absoluteString)"
        )
    }

    public func commit(_ result: ConnectorDiscoveryResult, idempotencyPrefix: String) async throws -> SourceDiscoveryCommit {
        _ = try await repository.saveSource(
            result.source,
            revision: result.sourceRevision,
            endpoints: result.endpoints,
            aiClassification: result.aiClassification,
            coverage: result.coverageCandidate,
            idempotencyKey: "\(idempotencyPrefix):source"
        )
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

    private static func connectorOrder(for url: URL) -> [ConnectorKind] {
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
