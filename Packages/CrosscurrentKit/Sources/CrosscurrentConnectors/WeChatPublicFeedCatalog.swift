import Foundation

public enum WeChatCatalogID: String, Codable, Hashable, CaseIterable, Sendable {
    case wechat2rss
    case bestBlogs

    public var priority: Int { self == .wechat2rss ? 0 : 1 }
    public var feedHost: String { self == .wechat2rss ? "wechat2rss.xlab.app" : "wechat2rss.bestblogs.dev" }
    public var catalogURL: URL {
        switch self {
        case .wechat2rss: URL(string: "https://raw.githubusercontent.com/ttttmr/Wechat2RSS/master/list/all.md")!
        case .bestBlogs: URL(string: "https://raw.githubusercontent.com/ginobefun/BestBlogs/main/opml/bestblogs_wechat2rss_opml_all.opml")!
        }
    }

    public func accepts(feedURL url: URL) -> Bool {
        guard Self.isAnonymousHTTPS(url), url.host?.lowercased() == feedHost else { return false }
        // Public IDs are opaque SHA-1-shaped paths, never account identity or credentials.
        return url.path.range(of: #"^/feed/[0-9a-f]{40}\.xml$"#, options: .regularExpression) != nil
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == url.path
    }

    fileprivate static func isAnonymousHTTPS(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && parts.user == nil && parts.password == nil
            && parts.query == nil && parts.fragment == nil && (parts.port == nil || parts.port == 443)
    }
}

public struct WeChatPublicFeedCandidate: Codable, Hashable, Sendable {
    public var displayName: String
    public var feedURL: URL
    public var catalog: WeChatCatalogID
    public var description: String?

    public init(displayName: String, feedURL: URL, catalog: WeChatCatalogID, description: String? = nil) {
        self.displayName = displayName
        self.feedURL = feedURL
        self.catalog = catalog
        self.description = description
    }
}

public protocol WeChatPublicFeedCatalog: Sendable {
    var id: WeChatCatalogID { get }
    var priority: Int { get }
    func refreshIfNeeded() async throws
    func search(query: String) async -> [WeChatPublicFeedCandidate]
}

public extension WeChatPublicFeedCatalog {
    var priority: Int { id.priority }
}

/// Each service has an independent last-known-good cache; a failed refresh never replaces its entries.
public actor CachedWeChatPublicFeedCatalog: WeChatPublicFeedCatalog {
    public nonisolated let id: WeChatCatalogID
    private let httpClient: any ConnectorHTTPClient
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let cacheURL: URL
    private var state: Cache
    private var refreshTask: Task<Void, Error>?

    private struct Cache: Codable {
        var version = 1
        var entries: [WeChatPublicFeedCandidate] = []
        var refreshedAt: Date?
        var etag: String?
        var lastModified: String?
        var nextAttemptAt: Date?
        var failures = 0
    }

    public init(
        catalog: WeChatCatalogID,
        cacheDirectory: URL,
        httpClient: any ConnectorHTTPClient = AnonymousPublicWeChatHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        ttl: TimeInterval = 24 * 60 * 60
    ) {
        id = catalog
        self.httpClient = httpClient
        self.now = now
        self.ttl = max(60, ttl)
        cacheURL = cacheDirectory.appendingPathComponent("\(catalog.rawValue)-v1.json")
        if let data = try? Data(contentsOf: cacheURL), data.count <= 4 * 1_024 * 1_024,
           let cached = try? JSONDecoder().decode(Cache.self, from: data), cached.version == 1,
           cached.entries.allSatisfy({ $0.catalog == catalog && catalog.accepts(feedURL: $0.feedURL) && !$0.displayName.isEmpty }) {
            state = cached
        } else {
            state = Cache()
        }
    }

    public static func builtIn(cacheDirectory: URL) -> [any WeChatPublicFeedCatalog] {
        WeChatCatalogID.allCases.map { CachedWeChatPublicFeedCatalog(catalog: $0, cacheDirectory: cacheDirectory) }
    }

    public func refreshIfNeeded() async throws {
        if let refreshTask { return try await refreshTask.value }
        let date = now()
        if let refreshedAt = state.refreshedAt, !state.entries.isEmpty,
           date.timeIntervalSince(refreshedAt) < ttl { return }
        if let nextAttempt = state.nextAttemptAt, nextAttempt > date {
            if state.entries.isEmpty { throw ConnectorError.transientHTTP(statusCode: 503, retryAfter: nextAttempt.timeIntervalSince(date)) }
            return
        }
        let task = Task { try await self.refresh(at: date) }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    public func search(query: String) async -> [WeChatPublicFeedCandidate] {
        let query = Self.searchKey(query)
        guard !query.isEmpty else { return [] }
        return state.entries.filter { Self.searchKey($0.displayName).contains(query) }
            .sorted {
                let leftExact = Self.searchKey($0.displayName) == query
                let rightExact = Self.searchKey($1.displayName) == query
                if leftExact != rightExact { return leftExact }
                if $0.displayName != $1.displayName { return $0.displayName < $1.displayName }
                return $0.feedURL.absoluteString < $1.feedURL.absoluteString
            }
    }

    private func refresh(at date: Date) async throws {
        do {
            var headers: [String: String] = ["Accept": "text/plain, application/xml, text/xml"]
            if let etag = Self.safeValidator(state.etag) { headers["If-None-Match"] = etag }
            if let modified = Self.safeValidator(state.lastModified) { headers["If-Modified-Since"] = modified }
            let response = try await httpClient.get(id.catalogURL, headers: headers)
            guard response.finalURL == id.catalogURL else { throw ConnectorError.invalidResponse("Unexpected public catalog redirect") }
            if response.statusCode == 304 {
                guard !state.entries.isEmpty else { throw ConnectorError.invalidResponse("Public catalog was not cached") }
            } else {
                guard response.statusCode == 200 else { throw ConnectorError.invalidResponse("Public catalog HTTP \(response.statusCode)") }
                let entries = try Self.parse(response.data, catalog: id)
                guard !entries.isEmpty else { throw ConnectorError.invalidResponse("Public catalog contained no valid feeds") }
                state.entries = entries
                state.etag = Self.safeValidator(Self.header("etag", in: response.headers))
                state.lastModified = Self.safeValidator(Self.header("last-modified", in: response.headers))
            }
            state.refreshedAt = date
            state.nextAttemptAt = nil
            state.failures = 0
            persist()
        } catch {
            state.failures = min(6, state.failures + 1)
            let delay = min(6 * 60 * 60, 15 * 60 * pow(2, Double(state.failures - 1)))
            let retryAfter: TimeInterval?
            switch error {
            case let ConnectorError.rateLimited(value), let ConnectorError.transientHTTP(_, value): retryAfter = value
            default: retryAfter = nil
            }
            state.nextAttemptAt = date.addingTimeInterval(min(6 * 60 * 60, max(delay, retryAfter ?? 0)))
            persist()
            if state.entries.isEmpty { throw error }
        }
    }

    private func persist() {
        // The catalog is disposable metadata. A disk error must not discard usable in-memory entries.
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    private static func parse(_ data: Data, catalog: WeChatCatalogID) throws -> [WeChatPublicFeedCandidate] {
        guard data.count <= 4 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else { throw ConnectorError.invalidResponse("Invalid public catalog encoding or size") }
        var entries: [WeChatPublicFeedCandidate] = []
        switch catalog {
        case .wechat2rss:
            let pattern = try NSRegularExpression(pattern: #"^\s*(?:[-*+]\s+)?\[([^\]\r\n]{1,512})\]\((https://[^\s)]+)\)\s*$"#)
            var inCodeBlock = false
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inCodeBlock.toggle(); continue }
                guard !inCodeBlock,
                      let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let nameRange = Range(match.range(at: 1), in: line), let urlRange = Range(match.range(at: 2), in: line),
                      let url = URL(string: String(line[urlRange])) else { continue }
                entries.append(.init(displayName: String(line[nameRange]), feedURL: url, catalog: catalog))
            }
        case .bestBlogs:
            // OPML needs no DTD or entity declarations. Reject them before entering the shared parser.
            guard text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
                  text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
                throw ConnectorError.invalidResponse("Public catalog contains XML declarations")
            }
            var outlines = try OPMLParser().parse(data: data)
            while let outline = outlines.popLast() {
                outlines.append(contentsOf: outline.children)
                if let url = outline.feedURL {
                    entries.append(.init(displayName: outline.title, feedURL: url, catalog: catalog, description: outline.attributes["description"]))
                }
            }
        }
        var seen: Set<URL> = []
        return entries.compactMap { candidate in
            var candidate = candidate
            candidate.displayName = candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.displayName.isEmpty, candidate.displayName.count <= 512,
                  catalog.accepts(feedURL: candidate.feedURL), seen.insert(candidate.feedURL).inserted else { return nil }
            candidate.description = candidate.description.map { String($0.prefix(2_000)) }
            return candidate
        }
    }

    private static func searchKey(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .filter { !$0.isWhitespace }
    }

    private static func safeValidator(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 512, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.lowercased() == name }?.value
    }
}

/// Separate from authenticated transports: only the two published catalogs and their public feed paths.
public struct AnonymousPublicWeChatHTTPClient: ConnectorHTTPClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration, delegate: PublicWeChatRedirectDelegate(), delegateQueue: nil)
    }

    public static func accepts(_ url: URL) -> Bool {
        WeChatCatalogID.allCases.contains { $0.catalogURL == url || $0.accepts(feedURL: url) }
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> ConnectorHTTPResponse {
        guard Self.accepts(url) else { throw ConnectorError.unsupportedInput }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        request.setValue("Crosscurrent/1 (+https://github.com/chonghanqin/Crosscurrent)", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers where ["accept", "if-none-match", "if-modified-since"].contains(name.lowercased()) {
            guard !value.contains("\r"), !value.contains("\n") else { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, let finalURL = response.url,
              Self.accepts(finalURL), finalURL.host == url.host, data.count <= 16 * 1_024 * 1_024 else {
            throw ConnectorError.invalidResponse("Invalid public WeChat response")
        }
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        if response.statusCode == 429 { throw ConnectorError.rateLimited(retryAfter: retryAfter) }
        if (500...599).contains(response.statusCode) { throw ConnectorError.transientHTTP(statusCode: response.statusCode, retryAfter: retryAfter) }
        guard (200..<300).contains(response.statusCode) || response.statusCode == 304 else {
            throw ConnectorError.invalidResponse("Public WeChat HTTP \(response.statusCode)")
        }
        let responseHeaders = response.allHeaderFields.reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        return .init(data: data, statusCode: response.statusCode, headers: responseHeaders, finalURL: finalURL)
    }
}

private final class PublicWeChatRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, AnonymousPublicWeChatHTTPClient.accepts(url),
              url.host == task.originalRequest?.url?.host else { completionHandler(nil); return }
        var anonymous = request
        anonymous.httpShouldHandleCookies = false
        anonymous.setValue(nil, forHTTPHeaderField: "Cookie")
        anonymous.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(anonymous)
    }
}
