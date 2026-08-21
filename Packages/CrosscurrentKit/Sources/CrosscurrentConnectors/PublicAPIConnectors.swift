import Foundation
import CrosscurrentDomain

public actor ArxivConnector: Connector {
    public nonisolated let kind: ConnectorKind = .arxiv
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .pagination, .fullContent, .backgroundRefresh]
    private let feed: FeedConnector

    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) { feed = FeedConnector(http: http) }

    public func discover(input: ConnectorDiscoveryInput, context: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let request = Self.request(from: input.url)
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = request.queryItems + [
            .init(name: "start", value: "0"),
            .init(name: "max_results", value: "50"),
            .init(name: "sortBy", value: "submittedDate"),
            .init(name: "sortOrder", value: "descending"),
        ]
        guard let api = components.url else { throw ConnectorError.unsupportedInput }
        var result = try await feed.discover(input: .init(url: api), context: context)
        result.source.kind = .query
        result.endpoints = result.endpoints.map { endpoint in var endpoint = endpoint; endpoint.connector = .arxiv; endpoint.externalID = request.identity; endpoint.canonicalURL = api; return endpoint }
        return result
    }
    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}
    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage { try await feed.refresh(endpoint: endpoint, cursor: cursor, context: context) }
    public func fetchContent(candidate: ConnectorItemCandidate, context: ConnectorContext) async throws -> ConnectorItemCandidate { try await feed.fetchContent(candidate: candidate, context: context) }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}
    private struct Request {
        var identity: String
        var queryItems: [URLQueryItem]
    }

    private static func request(from url: URL) -> Request {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let search = components?.queryItems?.first(where: { $0.name == "search_query" })?.value, !search.isEmpty {
            return Request(identity: search, queryItems: [.init(name: "search_query", value: search)])
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.first == "abs", let paperID = parts.dropFirst().first {
            return Request(identity: "paper:\(paperID)", queryItems: [.init(name: "id_list", value: paperID)])
        }
        if parts.first == "list", let category = parts.dropFirst().first {
            return Request(identity: "cat:\(category)", queryItems: [.init(name: "search_query", value: "cat:\(category)")])
        }
        return Request(identity: "all:*", queryItems: [.init(name: "search_query", value: "all:*")])
    }
}

public actor HackerNewsConnector: Connector {
    public nonisolated let kind: ConnectorKind = .hackerNews
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .pagination, .engagementMetrics, .backgroundRefresh]
    private let http: any ConnectorHTTPClient
    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) { self.http = http }

    public func discover(input _: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let revisionID = SourceRevisionID(); let source = LogicalSource(currentRevisionID: revisionID, kind: .community)
        let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: "Hacker News")
        let url = URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!
        let endpoint = SourceEndpoint(sourceID: source.id, connector: .hackerNews, externalID: "topstories", canonicalURL: url, contentPrivacy: .public)
        return ConnectorDiscoveryResult(source: source, sourceRevision: revision, endpoints: [endpoint], aiClassification: SourceAIClassification(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain), coverageCandidate: SourceCoverageAssertion(sourceID: source.id, ecosystem: .globalFocused, provenance: .connector, confidence: Confidence(0.6)))
    }
    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}
    public func refresh(endpoint _: SourceEndpoint, cursor: ConnectorCursor?, context: ConnectorContext) async throws -> ConnectorRefreshPage {
        let list = try await http.get(URL(string: "https://hacker-news.firebaseio.com/v0/topstories.json")!, headers: [:])
        let ids = try JSONDecoder().decode([Int].self, from: list.data)
        let offset = (try? cursor?.decode(Int.self)) ?? 0
        let pageIDs = Array(ids.dropFirst(offset).prefix(50))
        var candidates: [ConnectorItemCandidate] = []
        for id in pageIDs {
            let response = try await http.get(URL(string: "https://hacker-news.firebaseio.com/v0/item/\(id).json")!, headers: [:])
            struct Story: Decodable { var id: Int; var title: String?; var url: String?; var by: String?; var time: TimeInterval?; var score: Int?; var descendants: Int?; var deleted: Bool? }
            let story = try JSONDecoder().decode(Story.self, from: response.data)
            guard let title = story.title else { continue }
            var metrics: [ConnectorMetric] = []
            if let score = story.score { metrics.append(.init(kind: .score, value: Double(score), capturedAt: context.now())) }
            if let comments = story.descendants { metrics.append(.init(kind: .comments, value: Double(comments), capturedAt: context.now())) }
            candidates.append(.init(externalID: String(story.id), canonicalURL: story.url.flatMap(URL.init(string:)) ?? URL(string: "https://news.ycombinator.com/item?id=\(story.id)"), title: title, author: story.by, publishedAt: story.time.map(Date.init(timeIntervalSince1970:)), metricSnapshots: metrics, deletionState: story.deleted == true ? .deleted : .available))
        }
        let nextOffset = offset + pageIDs.count
        return ConnectorRefreshPage(candidates: candidates, nextCursor: try ConnectorCursor(family: "hn-offset-v1", value: nextOffset), reachedEnd: nextOffset >= min(ids.count, 500))
    }
    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}
}
