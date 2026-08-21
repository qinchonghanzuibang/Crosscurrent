import CryptoKit
import Foundation
import FeedFlowDomain
import SwiftSoup

public actor WebConnector: Connector {
    public nonisolated let kind: ConnectorKind = .website
    public nonisolated let capabilities: ConnectorCapabilities = [.discovery, .deltaSync, .fullContent, .deletionSignals, .backgroundRefresh]
    private let http: any ConnectorHTTPClient

    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) { self.http = http }

    public func discover(input: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult {
        let response: ConnectorHTTPResponse
        if let html = input.suppliedHTML {
            response = ConnectorHTTPResponse(data: Data(html.utf8), statusCode: 200, headers: [:], finalURL: input.url)
        } else {
            response = try await http.get(input.url, headers: ["Accept": "text/html"])
        }
        let html = String(decoding: response.data, as: UTF8.self)
        let document = try SwiftSoup.parse(html, response.finalURL.absoluteString)
        let title = try document.select("meta[property=og:title]").first()?.attr("content").nilIfEmpty ?? document.title().nilIfEmpty ?? response.finalURL.host ?? "Website"
        let summary = try document.select("meta[name=description],meta[property=og:description]").first()?.attr("content").nilIfEmpty
        let revisionID = SourceRevisionID()
        let source = LogicalSource(currentRevisionID: revisionID, kind: .website)
        let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: title, summary: summary)
        let endpoint = SourceEndpoint(sourceID: source.id, connector: .website, externalID: response.finalURL.absoluteString, canonicalURL: response.finalURL, accessRequirement: .anonymous, contentPrivacy: .public)
        let candidate = Self.candidate(url: response.finalURL, document: document, html: html, modifiedAt: nil)
        return ConnectorDiscoveryResult(source: source, sourceRevision: revision, endpoints: [endpoint], aiClassification: SourceAIClassification(sourceID: source.id, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain), coverageCandidate: SourceCoverageAssertion(sourceID: source.id, ecosystem: .unknown, provenance: .connector, confidence: .unknown), recentCandidates: [candidate])
    }

    public func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}

    public func refresh(endpoint: SourceEndpoint, cursor: ConnectorCursor?, context _: ConnectorContext) async throws -> ConnectorRefreshPage {
        guard let url = endpoint.canonicalURL else { throw ConnectorError.unsupportedInput }
        let response = try await http.get(url, headers: ["Accept": "text/html"])
        let html = String(decoding: response.data, as: UTF8.self)
        let document = try SwiftSoup.parse(html, response.finalURL.absoluteString)
        let candidate = Self.candidate(url: response.finalURL, document: document, html: html, modifiedAt: nil)
        let previousHash = try? cursor?.decode(String.self)
        let currentHash = stableHash(html)
        let next = try ConnectorCursor(family: "stable-page-content-v1", value: currentHash)
        return ConnectorRefreshPage(candidates: previousHash == currentHash ? [] : [candidate], nextCursor: next, reachedEnd: true)
    }

    public func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    public func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    public func disconnect(accountID _: ConnectorAccountID) async throws {}

    private static func candidate(url: URL, document: Document, html: String, modifiedAt: Date?) -> ConnectorItemCandidate {
        let title = ((try? document.select("meta[property=og:title]").first()?.attr("content")) ?? nil)?.nilIfEmpty ?? (try? document.title()).flatMap(\.nilIfEmpty) ?? url.absoluteString
        let text = try? document.body()?.text()
        return ConnectorItemCandidate(externalID: url.absoluteString, canonicalURL: url, title: title, modifiedAt: modifiedAt, contentHTML: html, contentText: text)
    }

    private func stableHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
