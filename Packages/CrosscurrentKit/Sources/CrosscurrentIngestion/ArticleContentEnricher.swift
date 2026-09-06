import CrosscurrentBrowser
import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation

/// Converts public feed/page payloads into stable Reader content before Item
/// normalization and segmentation. Connector metadata remains authoritative;
/// extraction only enriches the evidence body and never changes Item identity.
public actor ArticleContentEnricher {
    private let http: any ConnectorHTTPClient
    private let extract: @Sendable (String, URL?) async throws -> SafeExtractionResult

    public init(
        http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient(),
        extract: @escaping @Sendable (String, URL?) async throws -> SafeExtractionResult = { html, url in
            let extractor = SafeHTMLExtractor()
            return try await extractor.extract(untrustedHTML: html, baseURL: url)
        }
    ) {
        self.http = http
        self.extract = extract
    }

    public func enrich(
        _ candidate: ConnectorItemCandidate,
        connector: ConnectorKind,
        context _: ConnectorContext = ConnectorContext()
    ) async throws -> ConnectorItemCandidate {
        try Task.checkCancellation()
        guard Self.supportsArticleExtraction(connector) else { return candidate }

        var enriched = candidate
        let existingText = candidate.contentText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var html = candidate.contentHTML

        // Feed content is already the publisher's article fragment. Readability's
        // page-navigation heuristics can discard legitimate linked digests, headings
        // and lists (observed in Swift.org's Atom feed). Preserve that authoritative
        // body while crossing both the inert-document and native sanitizer boundary.
        if [.rss, .atom, .jsonFeed].contains(connector), let suppliedHTML = html,
           !suppliedHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let inert = try StaticHTMLPreprocessor.inertDocument(from: suppliedHTML, baseURL: candidate.canonicalURL)
            let result = try StaticHTMLPreprocessor.conservativeSanitize(inert, baseURL: candidate.canonicalURL)
            enriched.contentHTML = result.sanitizedHTML
            enriched.contentText = result.plainText
            if enriched.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched.summary = String(result.plainText.prefix(500))
            }
            return enriched
        }

        // Website candidates contain the fetched document. Feed entries commonly
        // contain only a description; fetch the canonical article when the body is
        // absent or clearly excerpt-sized.
        if connector != .website, connector != .weChatOfficialAccount, html == nil, existingText.count < 1_200,
           let url = candidate.canonicalURL,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            do {
                let response = try await http.get(url, headers: ["Accept": "text/html,application/xhtml+xml;q=0.9"])
                let contentType = response.header(named: "Content-Type")?.lowercased() ?? ""
                if contentType.isEmpty || contentType.contains("html") || contentType.contains("xhtml") {
                    html = String(decoding: response.data, as: UTF8.self)
                }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                // The feed entry remains valid evidence if optional full-article
                // retrieval fails. A single unavailable page must not block all
                // subsequent entries or prevent the source refresh from finishing.
                return candidate
            }
        }

        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return candidate }
        if connector == .weChatOfficialAccount {
            guard let result = try? WeChatHTMLPreprocessor.articleContent(from: html, baseURL: candidate.canonicalURL) else {
                enriched.contentHTML = nil
                return enriched
            }
            guard result.plainText.count >= max(80, existingText.count) || result.sanitizedHTML.contains("<img ") else { return candidate }
            enriched.title = Self.preferredTitle(extracted: result.title, original: candidate.title)
            enriched.contentHTML = result.sanitizedHTML
            enriched.contentText = result.plainText
            if enriched.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched.summary = String(result.plainText.prefix(500))
            }
            return enriched
        }
        do {
            let result = try await extract(html, candidate.canonicalURL)
            try Task.checkCancellation()
            // Website contentText contains the entire page, including navigation.
            // Successful extraction is expected to be shorter than that document.
            let minimumText = connector == .website || connector == .importedURL || connector == .shareExtension
                ? 80 : max(80, existingText.count)
            guard result.plainText.count >= minimumText || result.sanitizedHTML.contains("<img ") else { return candidate }
            enriched.title = Self.preferredTitle(extracted: result.title, original: candidate.title)
            enriched.contentHTML = result.sanitizedHTML
            enriched.contentText = result.plainText
            if enriched.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                enriched.summary = String(result.plainText.prefix(500))
            }
            return enriched
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            // A conservative native sanitizer still improves feed-provided HTML
            // when Readability cannot identify a main article.
            let result = try StaticHTMLPreprocessor.conservativeSanitize(html, baseURL: candidate.canonicalURL)
            guard result.plainText.count >= max(200, existingText.count) else { return candidate }
            enriched.contentHTML = result.sanitizedHTML
            enriched.contentText = result.plainText
            return enriched
        }
    }

    private static func supportsArticleExtraction(_ connector: ConnectorKind) -> Bool {
        switch connector {
        case .rss, .atom, .jsonFeed, .website, .weChatOfficialAccount, .importedURL, .shareExtension: true
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
