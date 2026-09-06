import Foundation
import CrosscurrentBrowser
import CrosscurrentDomain
import SwiftUI
import SwiftSoup

public actor LinkPreviewFetcher {
    private let session: URLSession
    private let delegate: LinkPreviewSessionDelegate

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1_024 * 1_024, diskCapacity: 0)
        delegate = LinkPreviewSessionDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    public func preview(for url: URL) async throws -> LinkPreview {
        guard LinkPreviewURLPolicy.allows(url) else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url,
              LinkPreviewURLPolicy.allows(finalURL), (200..<300).contains(http.statusCode), data.count <= 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        let html = String(decoding: data, as: UTF8.self)
        let document = try SwiftSoup.parse(html, finalURL.absoluteString)
        func meta(_ property: String) -> String? {
            let value = try? document.select("meta[property=\(property)],meta[name=\(property)]").first()?.attr("content")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let image = meta("og:image").flatMap { URL(string: $0, relativeTo: finalURL)?.absoluteURL }
            .flatMap { ReaderRemoteURLPolicy.allows($0, requiresHTTPS: true) ? $0 : nil }
        return LinkPreview(url: url, title: meta("og:title") ?? url.host ?? url.absoluteString, summary: meta("og:description") ?? meta("description"), imageURL: image)
    }
}

public enum LinkPreviewURLPolicy {
    public static func allows(_ url: URL) -> Bool {
        ReaderRemoteURLPolicy.allows(url)
    }
}

private final class LinkPreviewSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url.flatMap { LinkPreviewURLPolicy.allows($0) ? request : nil })
    }
}
