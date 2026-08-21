import FeedFlowConnectors
import FeedFlowDomain
import FeedFlowStorage
import Foundation

public struct SourceDiscoveryCommit: Sendable {
    public var sourceID: SourceID
    public var endpointIDs: [SourceEndpointID]
    public var importedItems: Int
}

public actor SourceDiscoveryService {
    private let repository: FeedFlowRepository
    private let ingestion: IngestionPipeline
    private let connectors: ConnectorRegistry?

    public init(repository: FeedFlowRepository, connectors: ConnectorRegistry? = nil, blobStore: CanonicalBlobStore? = nil) {
        self.repository = repository
        self.connectors = connectors
        ingestion = IngestionPipeline(repository: repository, blobStore: blobStore)
    }

    public func discover(_ input: ConnectorDiscoveryInput, context: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        guard let connectors else { throw ConnectorError.temporarilyUnavailable }
        let ordered = Self.connectorOrder(for: input.url)
        var lastError: Error = ConnectorError.unsupportedInput
        for kind in ordered {
            guard let connector = await connectors.connector(for: kind), connector.capabilities.contains(.discovery) else { continue }
            do {
                let result = try await connector.discover(input: input, context: context)
                _ = try await commit(result, idempotencyPrefix: "discover:\(kind.rawValue):\(input.url.absoluteString)")
                return result
            } catch ConnectorError.unsupportedInput {
                continue
            } catch {
                lastError = error
                if kind != .rss && kind != .website { throw error }
            }
        }
        throw lastError
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
                let value = try await ingestion.ingest(
                    candidate: candidate,
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
        return [.rss, .website]
    }
}
