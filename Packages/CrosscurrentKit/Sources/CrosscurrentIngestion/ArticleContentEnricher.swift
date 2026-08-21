import CrosscurrentBrowser
import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation

/// Converts public feed/page payloads into stable Reader content before Item
/// normalization and segmentation. Connector metadata remains authoritative;
/// extraction only enriches the evidence body and never changes Item identity.
public actor ArticleContentEnricher {
    private let http: any ConnectorHTTPClient

    public init(http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()) {
        self.http = http
    }

    public func enrich(
        _ candidate: ConnectorItemCandidate,
        connector: ConnectorKind,
        context _: ConnectorContext = ConnectorContext()
    ) async throws -> ConnectorItemCandidate {
        guard Self.supportsArticleExtraction(connector) else { return candidate }

        var enriched = candidate
        let existingText = candidate.contentText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var html = candidate.contentHTML

        // Website candidates contain the fetched document. Feed entries commonly
        // contain only a description; fetch the canonical article when the body is
        // absent or clearly excerpt-sized.
        if connector != .website, existingText.count < 1_200,
           let url = candidate.canonicalURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let response = try await http.get(url, headers: ["Accept": "text/html,application/xhtml+xml;q=0.9"])
            let contentType = response.header(named: "Content-Type")?.lowercased() ?? ""
            if contentType.isEmpty || contentType.contains("html") || contentType.contains("xhtml") {
                html = String(decoding: response.data, as: UTF8.self)
            }
        }

        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return candidate }
        do {
            let extractor = await SafeHTMLExtractor()
            let result = try await extractor.extract(untrustedHTML: html, baseURL: candidate.canonicalURL)
            guard result.plainText.count >= max(200, existingText.count) else { return candidate }
            enriched.title = Self.preferredTitle(extracted: result.title, original: candidate.title)
            enriched.contentHTML = result.sanitizedHTML
            enriched.contentText = result.plainText
            if enriched.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched.summary = String(result.plainText.prefix(500))
            }
            return enriched
        } catch {
            // A conservative native sanitizer still improves feed-provided HTML
            // when Readability cannot identify a main article.
            let result = try StaticHTMLPreprocessor.conservativeSanitize(html)
            guard result.plainText.count >= max(200, existingText.count) else { return candidate }
            enriched.contentHTML = result.sanitizedHTML
            enriched.contentText = result.plainText
            return enriched
        }
    }

    private static func supportsArticleExtraction(_ connector: ConnectorKind) -> Bool {
        switch connector {
        case .rss, .atom, .jsonFeed, .website, .importedURL, .shareExtension: true
        default: false
        }
    }

    private static func preferredTitle(extracted: String, original: String) -> String {
        let value = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.count > 300 ? original : value
    }
}

private extension ConnectorHTTPResponse {
    func header(named name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
