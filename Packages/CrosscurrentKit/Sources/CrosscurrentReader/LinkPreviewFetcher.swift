import Foundation
import CrosscurrentDomain
import SwiftUI

public actor LinkPreviewFetcher {
    private let session: URLSession
    private let delegate: LinkPreviewSessionDelegate

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
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
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ property: String) -> String? {
            let pattern = "<meta[^>]+(?:property|name)=[\\\"']\(NSRegularExpression.escapedPattern(for: property))[\\\"'][^>]+content=[\\\"']([^\\\"']*)"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }
        return LinkPreview(url: url, title: meta("og:title") ?? url.host ?? url.absoluteString, summary: meta("og:description") ?? meta("description"), imageURL: meta("og:image").flatMap(URL.init(string:)))
    }
}

public enum LinkPreviewURLPolicy {
    public static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        if host == "::1" || host == "0.0.0.0" { return false }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 { return false }
            if parts[0] == 169 && parts[1] == 254 { return false }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return false }
            if parts[0] == 192 && parts[1] == 168 { return false }
        }
        return true
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
