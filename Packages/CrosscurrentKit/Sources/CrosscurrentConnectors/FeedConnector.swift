import FeedKit
import Foundation
import CrosscurrentDomain
import SwiftSoup

public actor FeedConnector: Connector {
    public nonisolated let kind: ConnectorKind = .rss
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .fullContent, .backgroundRefresh]

    private let http: any ConnectorHTTPClient

    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.http = http
    }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let candidates = try await discoverFeedURLs(input: input)
        var lastError: Error?
        for url in candidates {
            do {
                let response = try await http.get(url, headers: ["Accept": "application/atom+xml, application/rss+xml, application/feed+json, application/json, text/xml;q=0.9, */*;q=0.5"])
                let parsed = try Feed(data: response.data)
                return makeDiscovery(feed: parsed, feedURL: response.finalURL)
            } catch { lastError = error }
        }
        throw lastError ?? ConnectorError.unsupportedInput
    }

    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}

    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context _: ConnectorContext) async throws -> ConnectorRefreshPage {
        guard let url = endpoint.canonicalURL else { throw ConnectorError.unsupportedInput }
        let response = try await http.get(url, headers: ["Accept": "application/atom+xml, application/rss+xml, application/feed+json, text/xml;q=0.9"])
        let feed = try Feed(data: response.data)
        let candidates = Array(Self.items(from: feed).prefix(30))
        let seen: Set<String> = (try? cursor?.decode([String].self)).map(Set.init) ?? []
        let fresh = candidates.filter { !seen.contains($0.externalID) }
        let next = try ConnectorCursor(family: "feed-seen-v1", value: Array(candidates.prefix(500).map(\.externalID)))
        return ConnectorRefreshPage(candidates: fresh, nextCursor: next, reachedEnd: true)
    }

    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate {
        candidate
    }

    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}

    private func discoverFeedURLs(input: ConnectorDiscoveryInput) async throws -> [URL] {
        if let html = input.suppliedHTML { return try Self.alternateFeedURLs(html: html, baseURL: input.url) + [input.url] }
        let response = try await http.get(input.url, headers: ["Accept": "application/atom+xml, application/rss+xml, application/feed+json, text/html"])
        let contentType = response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value.lowercased() ?? ""
        if contentType.contains("xml") || contentType.contains("json") || contentType.contains("feed") { return [response.finalURL] }
        guard let html = String(data: response.data, encoding: .utf8) else { return [response.finalURL] }
        var urls = try Self.alternateFeedURLs(html: html, baseURL: response.finalURL)
        for path in ["/feed", "/feed.xml", "/rss", "/rss.xml", "/atom.xml", "/index.xml"] {
            if let url = URL(string: path, relativeTo: response.finalURL)?.absoluteURL { urls.append(url) }
        }
        urls.append(response.finalURL)
        return Array(NSOrderedSet(array: urls).array.compactMap { $0 as? URL })
    }

    private static func alternateFeedURLs(html: String, baseURL: URL) throws -> [URL] {
        let document = try SwiftSoup.parse(html, baseURL.absoluteString)
        return try document.select("link[rel~=alternate]").compactMap { element in
            let type = try element.attr("type").lowercased()
            guard type.contains("rss") || type.contains("atom") || type.contains("feed+json") else { return nil }
            return URL(string: try element.absUrl("href"))
        }
    }

    private func makeDiscovery(feed: Feed, feedURL: URL) -> ConnectorDiscoveryResult {
        let metadata = Self.metadata(from: feed)
        let revisionID = SourceRevisionID()
        let source = LogicalSource(currentRevisionID: revisionID, kind: .publication)
        let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: metadata.title, summary: metadata.summary)
        let endpoint = SourceEndpoint(sourceID: source.id, connector: .rss, externalID: feedURL.absoluteString, canonicalURL: feedURL, accessRequirement: .anonymous, contentPrivacy: .public)
        return ConnectorDiscoveryResult(
            source: source,
            sourceRevision: revision,
            endpoints: [endpoint],
            aiClassification: SourceAIClassification(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain),
            coverageCandidate: SourceCoverageAssertion(sourceID: source.id, ecosystem: .unknown, provenance: .connector, confidence: .unknown),
            recentCandidates: Array(Self.items(from: feed).prefix(10))
        )
    }

    private static func metadata(from feed: Feed) -> (title: String, summary: String?) {
        switch feed {
        case let .rss(feed): return (feed.channel?.title ?? "Untitled Feed", feed.channel?.description)
        case let .atom(feed): return (feed.title?.text ?? "Untitled Feed", feed.subtitle?.text)
        case let .json(feed): return (feed.title ?? "Untitled Feed", feed.description)
        }
    }

    public static func items(from feed: Feed) -> [ConnectorItemCandidate] {
        switch feed {
        case let .rss(feed):
            return (feed.channel?.items ?? []).compactMap { item in
                let externalID = item.guid?.text ?? item.link ?? [item.title, item.pubDate?.description].compactMap { $0 }.joined(separator: "|")
                guard !externalID.isEmpty else { return nil }
                return ConnectorItemCandidate(
                    externalID: externalID,
                    canonicalURL: item.link.flatMap(URL.init(string:)),
                    title: item.title ?? "Untitled",
                    author: item.author,
                    publishedAt: item.pubDate,
                    summary: item.description,
                    contentHTML: item.content?.encoded,
                    contentText: item.markdown,
                    topicNames: item.categories?.compactMap(\.text) ?? []
                )
            }
        case let .atom(feed):
            return (feed.entries ?? []).compactMap { entry in
                let link = entry.links?.first { $0.attributes?.rel == nil || $0.attributes?.rel == "alternate" }?.attributes?.href
                let externalID = entry.id ?? link ?? [entry.title, entry.published?.description].compactMap { $0 }.joined(separator: "|")
                guard !externalID.isEmpty else { return nil }
                return ConnectorItemCandidate(
                    externalID: externalID,
                    canonicalURL: link.flatMap(URL.init(string:)),
                    title: entry.title ?? "Untitled",
                    author: entry.authors?.first?.name,
                    publishedAt: entry.published,
                    modifiedAt: entry.updated,
                    summary: entry.summary?.text,
                    contentHTML: entry.content?.text,
                    topicNames: entry.categories?.compactMap { $0.attributes?.label ?? $0.attributes?.term } ?? []
                )
            }
        case let .json(feed):
            return (feed.items ?? []).compactMap { item in
                guard let externalID = item.id ?? item.url else { return nil }
                return ConnectorItemCandidate(
                    externalID: externalID,
                    canonicalURL: item.url.flatMap(URL.init(string:)),
                    title: item.title ?? "Untitled",
                    author: item.author?.name,
                    publishedAt: item.datePublished,
                    modifiedAt: item.dateModified,
                    summary: item.summary,
                    contentHTML: item.contentHtml,
                    contentText: item.contentText,
                    topicNames: item.tags ?? []
                )
            }
        }
    }

    public static func parseItems(data: Data) throws -> [ConnectorItemCandidate] {
        items(from: try Feed(data: data))
    }
}
