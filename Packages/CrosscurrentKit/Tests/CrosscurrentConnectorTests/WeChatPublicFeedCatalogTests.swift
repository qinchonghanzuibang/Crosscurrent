import CrosscurrentConnectors
import Foundation
import Testing

private actor CatalogFixtureHTTP: ConnectorHTTPClient {
    private var responses: [Result<ConnectorHTTPResponse, ConnectorError>]
    private var requests: [[String: String]] = []

    init(_ responses: [Result<ConnectorHTTPResponse, ConnectorError>]) { self.responses = responses }

    func get(_: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        requests.append(headers)
        await Task.yield()
        guard !responses.isEmpty else { throw ConnectorError.transientHTTP(statusCode: 503, retryAfter: nil) }
        return try responses.removeFirst().get()
    }

    func count() -> Int { requests.count }
    func lastHeaders() -> [String: String] { requests.last ?? [:] }
}

private final class CatalogFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

private let xlabFeed = "https://wechat2rss.xlab.app/feed/51e92aad2728acdd1fda7314be32b16639353001.xml"
private let bestBlogsFeed = "https://wechat2rss.bestblogs.dev/feed/8d97af31b0de9e48da74558af128a4673d78c9a3.xml"

private func catalogResponse(_ text: String, id: WeChatCatalogID = .wechat2rss, status: Int = 200, headers: [String: String] = [:]) -> Result<ConnectorHTTPResponse, ConnectorError> {
    .success(.init(data: Data(text.utf8), statusCode: status, headers: headers, finalURL: id.catalogURL))
}

@Test func publicCatalogRejectsUnexpectedHostsCredentialsAndRemovedMarkdownEntries() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let markdown = """
    # Catalog
    [机器之心](\(xlabFeed))
    [机器之心](\(xlabFeed))
    [Wrong host](\(bestBlogsFeed))
    [Token](\(xlabFeed)?token=private)
    [Credential](https://secret@wechat2rss.xlab.app/feed/1111111111111111111111111111111111111111.xml)
    [API](https://wechat2rss.xlab.app/login/1111111111111111111111111111111111111111.xml)
    ~~[Removed](https://wechat2rss.xlab.app/feed/2222222222222222222222222222222222222222.xml)~~
    ```
    [Example](https://wechat2rss.xlab.app/feed/3333333333333333333333333333333333333333.xml)
    ```
    """
    let http = CatalogFixtureHTTP([catalogResponse(markdown)])
    let catalog = CachedWeChatPublicFeedCatalog(catalog: .wechat2rss, cacheDirectory: directory, httpClient: http)
    try await catalog.refreshIfNeeded()
    let results = await catalog.search(query: " 机器 之心 ")
    #expect(results.count == 1)
    #expect(results.first?.feedURL.absoluteString == xlabFeed)
    #expect(await catalog.search(query: "Removed").isEmpty)
    #expect(await catalog.search(query: "Example").isEmpty)
    #expect(await catalog.search(query: "").isEmpty)
    for invalid in [
        xlabFeed + "?RSS_TOKEN=secret", xlabFeed + "#fragment", xlabFeed.replacingOccurrences(of: "https:", with: "http:"),
        xlabFeed.replacingOccurrences(of: "/feed/", with: "/feed/%2e%2e/feed/"),
        xlabFeed.replacingOccurrences(of: "xlab.app", with: "xlab.app.attacker.test"),
        xlabFeed.replacingOccurrences(of: "xlab.app", with: "xlab.app:8443"),
        "https://raw.githubusercontent.com/attacker/project/main/catalog.md",
    ] {
        #expect(!AnonymousPublicWeChatHTTPClient.accepts(URL(string: invalid)!))
    }
}

@Test func publicCatalogPersistsConditionalTTLAndStaleFailureBackoffAcrossRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = CatalogFixtureClock()
    let http = CatalogFixtureHTTP([
        catalogResponse("[机器之心](\(xlabFeed))", headers: ["ETag": "\"catalog-v1\"", "Last-Modified": "Wed, 02 Sep 2026 12:00:00 GMT"]),
        catalogResponse("", status: 304),
        .failure(.transientHTTP(statusCode: 503, retryAfter: 1_800)),
    ])
    let catalog = CachedWeChatPublicFeedCatalog(catalog: .wechat2rss, cacheDirectory: directory, httpClient: http, now: clock.now)
    async let first: Void = catalog.refreshIfNeeded()
    async let simultaneous: Void = catalog.refreshIfNeeded()
    _ = try await (first, simultaneous)
    #expect(await http.count() == 1)
    clock.advance(86_399)
    try await catalog.refreshIfNeeded()
    #expect(await http.count() == 1)
    clock.advance(1)
    try await catalog.refreshIfNeeded()
    #expect(await http.lastHeaders()["If-None-Match"] == "\"catalog-v1\"")
    #expect(await http.lastHeaders()["If-Modified-Since"] == "Wed, 02 Sep 2026 12:00:00 GMT")
    #expect(await catalog.search(query: "机器之心").count == 1)
    clock.advance(86_400)
    try await catalog.refreshIfNeeded()
    try await catalog.refreshIfNeeded()
    #expect(await http.count() == 3)
    let offline = CatalogFixtureHTTP([])
    let relaunched = CachedWeChatPublicFeedCatalog(catalog: .wechat2rss, cacheDirectory: directory, httpClient: offline, now: clock.now)
    try await relaunched.refreshIfNeeded()
    #expect(await offline.count() == 0)
    #expect(await relaunched.search(query: "机器之心").count == 1)
    clock.advance(1_801)
    try await relaunched.refreshIfNeeded()
    #expect(await offline.count() == 1)
    #expect(await relaunched.search(query: "机器之心").count == 1)
}

@Test func bestBlogsOPMLRejectsEntityDeclarationsAndPreservesGoodCacheAfterMalformedRefresh() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = CatalogFixtureClock()
    let http = CatalogFixtureHTTP([
        catalogResponse("""
        <?xml version="1.0"?><opml version="2.0"><body><outline text="AI">
        <outline text="机器之心" type="rss" xmlUrl="\(bestBlogsFeed)" description="AI &amp; research"/>
        <outline title="Wrong host" xmlUrl="\(xlabFeed)"/>
        <outline title="Login" xmlUrl="https://wechat2rss.bestblogs.dev/login/secret"/>
        </outline></body></opml>
        """, id: .bestBlogs),
        catalogResponse("""
        <?xml version="1.0"?><!DOCTYPE opml [<!ENTITY local SYSTEM "file:///etc/hosts">]>
        <opml><body><outline text="&local;" xmlUrl="\(bestBlogsFeed)"/></body></opml>
        """, id: .bestBlogs),
        catalogResponse("<opml><body><outline", id: .bestBlogs),
    ])
    let catalog = CachedWeChatPublicFeedCatalog(catalog: .bestBlogs, cacheDirectory: directory, httpClient: http, now: clock.now, ttl: 60)
    try await catalog.refreshIfNeeded()
    #expect(await catalog.search(query: "机器之心").first?.description == "AI & research")
    #expect(await catalog.search(query: "Wrong").isEmpty)
    clock.advance(61)
    try await catalog.refreshIfNeeded()
    clock.advance(901)
    try await catalog.refreshIfNeeded()
    #expect(await http.count() == 3)
    let relaunched = CachedWeChatPublicFeedCatalog(catalog: .bestBlogs, cacheDirectory: directory, httpClient: CatalogFixtureHTTP([]), now: clock.now)
    #expect(await relaunched.search(query: "机器之心").first?.description == "AI & research")
}

@Test func emptyPublicCatalogDoesNotHammerFailedUpstreamOrAcceptInvalidRedirect() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let response = ConnectorHTTPResponse(data: Data("[机器之心](\(xlabFeed))".utf8), statusCode: 200, headers: [:], finalURL: URL(string: "https://attacker.test/list.md")!)
    let http = CatalogFixtureHTTP([.success(response)])
    let catalog = CachedWeChatPublicFeedCatalog(catalog: .wechat2rss, cacheDirectory: directory, httpClient: http)
    await #expect(throws: ConnectorError.self) { try await catalog.refreshIfNeeded() }
    await #expect(throws: ConnectorError.self) { try await catalog.refreshIfNeeded() }
    #expect(await http.count() == 1)
    #expect(await catalog.search(query: "机器之心").isEmpty)
}
