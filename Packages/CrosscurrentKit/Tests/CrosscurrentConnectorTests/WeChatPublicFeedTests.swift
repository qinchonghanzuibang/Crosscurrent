import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation
import Testing

private actor PublicCatalogFixture: WeChatPublicFeedCatalog {
    nonisolated let id: WeChatCatalogID
    nonisolated var priority: Int { id.priority }
    let names: [String]
    init(_ id: WeChatCatalogID, names: [String] = ["机器之心"]) { self.id = id; self.names = names }
    func refreshIfNeeded() async throws {}
    func search(query: String) async -> [WeChatPublicFeedCandidate] {
        names.filter { $0.contains(query.trimmingCharacters(in: .whitespaces)) }.map {
            .init(displayName: $0, feedURL: feedURL(id), catalog: id)
        }
    }
}

private actor PublicHTTPFixture: ConnectorHTTPClient {
    var responses: [String: [ConnectorHTTPResponse]]
    var calls: [(URL, [String: String])] = []
    init(_ responses: [WeChatCatalogID: [ConnectorHTTPResponse]]) {
        self.responses = Dictionary(uniqueKeysWithValues: responses.map { ($0.key.feedHost, $0.value) })
    }
    func get(_ url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        calls.append((url, headers))
        guard var values = responses[url.host ?? ""], !values.isEmpty else { throw URLError(.cannotConnectToHost) }
        let result = values.count == 1 ? values[0] : values.removeFirst()
        responses[url.host ?? ""] = values
        return result
    }
    func requestCount() -> Int { calls.count }
    func lastHeaders() -> [String: String]? { calls.last?.1 }
}

private actor PaidFallbackFixture: WeChatIndexProvider {
    var searches = 0
    var posts = 0
    var articles = 0
    let configured: Bool
    init(configured: Bool = true) { self.configured = configured }
    func searchAccounts(query: String) async throws -> [WeChatAccountIdentity] { searches += 1; return [identity(query)] }
    func resolveAccount(articleURL _: URL) async throws -> WeChatAccountIdentity { identity("机器之心") }
    func fetchDailyPosts(account _: WeChatAccountIdentity) async throws -> [WeChatPostCandidate] { posts += 1; return [post()] }
    func fetchHistory(account _: WeChatAccountIdentity, cursor _: WeChatHistoryCursor?, limit _: Int) async throws -> WeChatHistoryPage {
        posts += 1; return .init(posts: [post()], reachedEnd: true)
    }
    func fetchArticleHTML(articleURL _: URL) async throws -> WeChatProviderArticle? {
        articles += 1; return .init(html: longHTML, provenance: .init(providerID: "jizhila"))
    }
    func healthCheck() async -> WeChatProviderHealth { configured ? .configured : .missingConfiguration }
    func counts() -> [Int] { [searches, posts, articles] }
    private func identity(_ name: String) -> WeChatAccountIdentity {
        .init(displayName: name, ghid: "gh_fixture", biz: "QQ==", provenance: .init(providerID: "jizhila"))
    }
    private func post() -> WeChatPostCandidate {
        .init(title: "真实文章", articleURL: articleURL(1), appmsgid: "1", position: 1, provenance: .init(providerID: "jizhila"))
    }
}

private struct OfflineOfficial: WeChatOfficialArticleLoading {
    func fetch(_ url: URL) async throws -> WeChatOfficialArticleResponse { throw URLError(.notConnectedToInternet) }
}

private let longHTML = "<article><h2>模型方法</h2><p>" + String(repeating: "微信公众号正文包含中文 English 与技术介绍。", count: 50) + "</p></article>"
private func feedURL(_ id: WeChatCatalogID) -> URL { URL(string: "https://\(id.feedHost)/feed/" + String(repeating: "a", count: 40) + ".xml")! }
private func articleURL(_ mid: Int, biz: String = "QQ==") -> URL { URL(string: "https://mp.weixin.qq.com/s?__biz=\(biz)&mid=\(mid)&idx=1&sn=sn\(mid)")! }
private func rss(_ id: WeChatCatalogID, mids: [Int] = [1], biz: String = "QQ==", status: Int = 200) -> ConnectorHTTPResponse {
    let entries = mids.map { mid in
        "<item><title>真实文章 \(mid)</title><link>\(articleURL(mid, biz: biz).absoluteString.replacingOccurrences(of: "&", with: "&amp;"))</link><guid>provider-\(id.rawValue)-\(mid)</guid><pubDate>Tue, 14 Nov 2023 12:00:00 GMT</pubDate><content:encoded><![CDATA[\(longHTML)]]></content:encoded></item>"
    }.joined()
    return .init(data: Data("<rss version=\"2.0\" xmlns:content=\"http://purl.org/rss/1.0/modules/content/\"><channel><title>机器之心</title>\(entries)</channel></rss>".utf8), statusCode: status, headers: ["ETag": "fixture-etag"], finalURL: feedURL(id))
}
private func endpoint(_ id: WeChatCatalogID, source: SourceID = SourceID(), success: Date? = nil) -> SourceEndpoint {
    .init(sourceID: source, connector: .weChatOfficialAccount, externalID: "wechat-account-biz:QQ==:feed:\(id.rawValue)", canonicalURL: feedURL(id), contentPrivacy: .public, lastSuccessfulSync: success,
          weChatAcquisition: .init(providerID: id.rawValue, priority: id.priority, accountAliases: ["wechat-account-biz:QQ=="], displayName: "机器之心"))
}

@Test func freeWeChatSearchVerifiesOneAccountWithTwoEndpointsWithoutPaidSearch() async throws {
    let paid = PaidFallbackFixture(configured: false)
    let http = PublicHTTPFixture([.wechat2rss: [rss(.wechat2rss)], .bestBlogs: [rss(.bestBlogs)]])
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), catalogs: [PublicCatalogFixture(.wechat2rss), PublicCatalogFixture(.bestBlogs)], publicHTTP: http)
    let results = try await connector.search(query: "机器之心", context: .init())
    #expect(results.count == 1)
    #expect(results.first?.endpoints.count == 2)
    #expect(Set(results[0].endpoints.map(\.sourceID)) == [results[0].source.id])
    #expect(results[0].endpoints.allSatisfy { $0.weChatAcquisition?.accountAliases == ["wechat-account-biz:QQ=="] })
    #expect(await connector.healthCheck(accountID: nil) == .healthy)
    #expect(await paid.counts() == [0, 0, 0])
}

@Test func sameNameDifferentWeChatAccountsNeverPermanentlyMergeAndLongTailIsExplicit() async throws {
    let paid = PaidFallbackFixture()
    let http = PublicHTTPFixture([.wechat2rss: [rss(.wechat2rss)], .bestBlogs: [rss(.bestBlogs, biz: "Qg==")]])
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), catalogs: [PublicCatalogFixture(.wechat2rss), PublicCatalogFixture(.bestBlogs)], publicHTTP: http)
    #expect(try await connector.search(query: "机器之心", context: .init()).count == 2)
    #expect(try await connector.search(query: "未覆盖账号", context: .init()).isEmpty)
    #expect(await paid.counts() == [0, 0, 0])
    let result = try await connector.searchMore(query: "未覆盖账号", context: .init())
    #expect(result.count == 1)
    #expect(result[0].endpoints.first?.weChatAcquisition?.providerID == "jizhila")
    #expect(await paid.counts() == [1, 0, 0])
}

@Test func freeFeedFailoverAndDailyAuditUnionUseCanonicalArticleIdentity() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let paid = PaidFallbackFixture()
    let primaryFailure = PublicHTTPFixture([.wechat2rss: [rss(.wechat2rss, status: 503)], .bestBlogs: [rss(.bestBlogs)]])
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: primaryFailure)
    let first = endpoint(.wechat2rss)
    let second = endpoint(.bestBlogs, source: first.sourceID)
    let failedOver = await connector.refreshSource(endpoints: [first, second], context: .init(now: { now }), manual: false)
    #expect(failedOver.succeeded)
    #expect(failedOver.candidates.count == 1)
    #expect(failedOver.endpoints[0].health == .temporarilyUnavailable)
    #expect(failedOver.endpoints[1].health == .healthy)
    #expect(await paid.counts() == [0, 0, 0])

    let auditHTTP = PublicHTTPFixture([.wechat2rss: [rss(.wechat2rss, mids: [1])], .bestBlogs: [rss(.bestBlogs, mids: [1, 2])]])
    let auditConnector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: auditHTTP)
    let union = await auditConnector.refreshSource(endpoints: [first, second], context: .init(now: { now }), manual: false)
    #expect(union.candidates.count == 2)
    #expect(union.candidates.first?.externalID == "wechat-article:QQ==:1:1")
    let repeatResult = await auditConnector.refreshSource(endpoints: union.endpoints, context: .init(now: { now.addingTimeInterval(60) }), manual: false)
    #expect(!repeatResult.performedRemoteRequest)
    #expect(await auditHTTP.requestCount() == 2)
}

@Test func successfulEmptyOrNotModifiedFreeFeedNeverCallsPaidIndex() async throws {
    let paid = PaidFallbackFixture()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let http = PublicHTTPFixture([.wechat2rss: [rss(.wechat2rss, mids: []), rss(.wechat2rss, mids: [], status: 304)]])
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: http)
    let first = endpoint(.wechat2rss)
    let paidEndpoint = SourceEndpoint(sourceID: first.sourceID, connector: .weChatOfficialAccount, externalID: "wechat-account:gh_fixture", canonicalURL: URL(string: "https://mp.weixin.qq.com/mp/profile_ext?__biz=QQ=="))
    let empty = await connector.refreshSource(endpoints: [first, paidEndpoint], context: .init(now: { now }), manual: true)
    #expect(empty.succeeded && empty.candidates.isEmpty)
    let notModified = await connector.refreshSource(endpoints: empty.endpoints, context: .init(now: { now.addingTimeInterval(60) }), manual: true)
    #expect(notModified.succeeded && notModified.candidates.isEmpty)
    #expect(await http.lastHeaders()?["If-None-Match"] == "fixture-etag")
    #expect(await paid.counts() == [0, 0, 0])
}

@Test func allFreeEndpointsFailUsesConfiguredPaidFallbackWithNoRepeatCost() async throws {
    let paid = PaidFallbackFixture()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: PublicHTTPFixture([:]))
    let free = endpoint(.wechat2rss)
    let fallback = SourceEndpoint(sourceID: free.sourceID, connector: .weChatOfficialAccount, externalID: "wechat-account:gh_fixture", canonicalURL: URL(string: "https://mp.weixin.qq.com/mp/profile_ext?__biz=QQ=="))
    let result = await connector.refreshSource(endpoints: [free, fallback], context: .init(now: { now }), manual: true)
    #expect(result.succeeded && result.candidates.count == 1)
    _ = await connector.refreshSource(endpoints: result.endpoints, context: .init(now: { now.addingTimeInterval(60) }), manual: true)
    #expect(await paid.counts() == [0, 1, 0])
}

@Test func qualifiedFeedHTMLPrecedesPaidContentAndProxyIdentityRejectsUntrustedTargets() async throws {
    let paid = PaidFallbackFixture()
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial())
    let candidate = ConnectorItemCandidate(externalID: "wechat-article:QQ==:1:1", canonicalURL: articleURL(1), title: "文章", contentHTML: longHTML, acquisitionProvenance: .bestBlogsWechat2RSS)
    let result = try await connector.fetchContent(candidate: candidate, context: .init())
    #expect(result.contentHTML == longHTML)
    #expect(result.acquisitionProvenance == .bestBlogsWechat2RSS)
    #expect(await paid.counts() == [0, 0, 0])
    var wrapper = URLComponents(string: "https://wechat2rss.xlab.app/link-proxy/")!
    wrapper.queryItems = [.init(name: "u", value: articleURL(1).absoluteString + "&scene=1"), .init(name: "k", value: "public-signature")]
    #expect(WeChatPublicFeedContent.originalArticleURL(wrapper.url!) == WeChatArticleIdentity.canonicalize(articleURL(1)))
    wrapper.queryItems = [.init(name: "u", value: "https://127.0.0.1/private")]
    #expect(WeChatPublicFeedContent.originalArticleURL(wrapper.url!) == nil)
    #expect(!WeChatArticleValidator.isAllowedArticleURL(URL(string: "https://evil.weixin.qq.com/s/x")!))
    #expect(!WeChatArticleValidator.isAllowedArticleURL(URL(string: "https://mp.weixin.qq.com/login")!))
}

private actor FirstPublisherOfficialFixture: WeChatOfficialArticleLoading {
    private var calls = 0
    func fetch(_ url: URL) async throws -> WeChatOfficialArticleResponse {
        calls += 1
        let html = "<script>var user_name = 'gh_fixture'; var biz = 'QQ==';</script><span id='js_name'>机器之心</span><section id='js_content'>\(longHTML)</section>"
        return .init(data: Data(html.utf8), statusCode: 200, finalURL: url)
    }
    func count() -> Int { calls }
}

@Test func mixedPublicFeedWithoutMajorityCannotBorrowFirstArticlePublisher() async throws {
    var mixed = rss(.wechat2rss, mids: [1, 2])
    mixed.data = Data(String(decoding: mixed.data, as: UTF8.self)
        .replacingOccurrences(of: "__biz=QQ==&amp;mid=2", with: "__biz=Qg==&amp;mid=2").utf8)
    let official = FirstPublisherOfficialFixture()
    let paid = PaidFallbackFixture()
    let http = PublicHTTPFixture([.wechat2rss: [mixed], .bestBlogs: [rss(.bestBlogs)]])
    let connector = WeChatConnector(provider: paid, official: official,
        catalogs: [PublicCatalogFixture(.wechat2rss), PublicCatalogFixture(.bestBlogs)], publicHTTP: http)
    let results = try await connector.search(query: "机器之心", context: .init())
    #expect(results.count == 1)
    #expect(results.first?.endpoints.count == 1)
    #expect(results.first?.endpoints.first?.weChatAcquisition?.providerID == "bestBlogs")
    #expect(await official.count() == 0)
    #expect(await paid.counts() == [0, 0, 0])
}

@Test func secondaryAuditRetainsRicherFreeBodyBeforePaidArticleFallback() async throws {
    var primary = rss(.wechat2rss)
    primary.data = Data(String(decoding: primary.data, as: UTF8.self).replacingOccurrences(of: longHTML, with: "<p>摘要</p>").utf8)
    let paid = PaidFallbackFixture()
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(),
        publicHTTP: PublicHTTPFixture([.wechat2rss: [primary], .bestBlogs: [rss(.bestBlogs)]]))
    let first = endpoint(.wechat2rss)
    let result = await connector.refreshSource(endpoints: [first, endpoint(.bestBlogs, source: first.sourceID)], context: .init(), manual: true)
    #expect(result.succeeded)
    #expect(result.candidates.count == 1)
    let candidate = try #require(result.candidates.first)
    #expect(candidate.acquisitionProvenance == .bestBlogsWechat2RSS)
    #expect(candidate.contentHTML?.contains("模型方法") == true)
    let enriched = try await connector.fetchContent(candidate: candidate, context: .init())
    #expect(enriched.acquisitionProvenance == .bestBlogsWechat2RSS)
    #expect(enriched.contentHTML == candidate.contentHTML)
    #expect(await paid.counts() == [0, 0, 0])
}

@Test func newlyFollowedFreeOnlyAccountAddsPaidFallbackOnlyAfterEveryFreeEndpointFails() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let http = PublicHTTPFixture([
        .wechat2rss: [rss(.wechat2rss), rss(.wechat2rss, status: 503)],
        .bestBlogs: [rss(.bestBlogs), rss(.bestBlogs, status: 503)],
    ])
    let paid = PaidFallbackFixture()
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: http)
    let first = endpoint(.wechat2rss)
    let healthy = await connector.refreshSource(endpoints: [first, endpoint(.bestBlogs, source: first.sourceID)], context: .init(now: { now }), manual: true)
    #expect(healthy.succeeded)
    #expect(healthy.endpoints.count == 2)
    #expect(await paid.counts() == [0, 0, 0])
    let later = now.addingTimeInterval(86_401)
    let failedOver = await connector.refreshSource(endpoints: healthy.endpoints, context: .init(now: { later }), manual: true)
    #expect(failedOver.succeeded)
    #expect(failedOver.candidates.count == 1)
    #expect(failedOver.endpoints.count == 3)
    let paidEndpoint = try #require(failedOver.endpoints.first { $0.weChatAcquisition?.providerID == "jizhila" })
    #expect(paidEndpoint.sourceID == first.sourceID)
    #expect(paidEndpoint.weChatAcquisition?.accountAliases == ["wechat-account-biz:QQ=="])
    #expect(await http.requestCount() == 4)
    #expect(await paid.counts() == [0, 1, 0])
    let repeated = await connector.refreshSource(endpoints: failedOver.endpoints, context: .init(now: { later.addingTimeInterval(60) }), manual: true)
    #expect(repeated.succeeded && !repeated.performedRemoteRequest)
    #expect(await paid.counts() == [0, 1, 0])
}

private actor PaginatedPaidHistoryFixture: WeChatIndexProvider {
    private var limits: [Int] = []
    private var offsets: [String?] = []
    func searchAccounts(query _: String) async throws -> [WeChatAccountIdentity] { throw ConnectorError.unsupportedInput }
    func resolveAccount(articleURL _: URL) async throws -> WeChatAccountIdentity { throw ConnectorError.unsupportedInput }
    func fetchDailyPosts(account _: WeChatAccountIdentity) async throws -> [WeChatPostCandidate] { throw ConnectorError.unsupportedInput }
    func fetchHistory(account _: WeChatAccountIdentity, cursor: WeChatHistoryCursor?, limit: Int) async throws -> WeChatHistoryPage {
        limits.append(limit)
        offsets.append(cursor?.offset)
        let offset = Int(cursor?.offset ?? "0") ?? 0
        let size = min(10, limit)
        let posts = (offset..<(offset + size)).map { index in
            WeChatPostCandidate(title: "历史文章 \(index)", articleURL: articleURL(index + 1),
                appmsgid: String(index + 1), position: 1, provenance: .init(providerID: "jizhila"))
        }
        return .init(posts: posts, nextCursor: .init(offset: String(offset + size)), reachedEnd: false)
    }
    func fetchArticleHTML(articleURL _: URL) async throws -> WeChatProviderArticle? { nil }
    func healthCheck() async -> WeChatProviderHealth { .configured }
    func requestedLimits() -> [Int] { limits }
    func requestedOffsets() -> [String?] { offsets }
}

@Test func paidInitialBackfillFollowsPagesUntilTwentyFiveWithoutRepeatingOnRefresh() async throws {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let paid = PaginatedPaidHistoryFixture()
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: PublicHTTPFixture([:]))
    let paidEndpoint = SourceEndpoint(sourceID: SourceID(), connector: .weChatOfficialAccount,
        externalID: "wechat-account:gh_fixture", contentPrivacy: .public,
        weChatAcquisition: .init(providerID: "jizhila", priority: 2,
            accountAliases: ["wechat-account:gh_fixture", "wechat-account-biz:QQ=="], displayName: "机器之心"))
    let result = await connector.refreshSource(endpoints: [paidEndpoint], context: .init(now: { now }), manual: false)
    #expect(result.succeeded && result.performedRemoteRequest)
    #expect(result.candidates.count == 25)
    #expect(Set(result.candidates.map(\.externalID)).count == 25)
    #expect(await paid.requestedLimits() == [25, 15, 5])
    #expect(await paid.requestedOffsets() == [nil, "10", "20"])
    #expect(result.endpoints.first?.lastSuccessfulSync == now)
    let repeated = await connector.refreshSource(endpoints: result.endpoints, context: .init(now: { now.addingTimeInterval(60) }), manual: false)
    #expect(repeated.succeeded && !repeated.performedRemoteRequest)
    #expect(await paid.requestedLimits() == [25, 15, 5])
}

@Test func pastedPublicFeedURLDiscoversThePublisherWithOneAnonymousFetch() async throws {
    let paid = PaidFallbackFixture(configured: false)
    let http = PublicHTTPFixture([.bestBlogs: [rss(.bestBlogs)]])
    let connector = WeChatConnector(provider: paid, official: OfflineOfficial(), publicHTTP: http)
    let result = try await connector.discover(input: .init(url: feedURL(.bestBlogs)), context: .init())
    #expect(result.sourceRevision.displayName == "机器之心")
    #expect(result.source.kind == .organization)
    #expect(result.endpoints.count == 1)
    #expect(result.endpoints.first?.connector == .weChatOfficialAccount)
    #expect(result.endpoints.first?.weChatAcquisition?.accountAliases == ["wechat-account-biz:QQ=="])
    #expect(result.endpoints.first?.externalID == "wechat-account-biz:QQ==:feed:bestBlogs")
    #expect(await http.requestCount() == 1)
    #expect(await paid.counts() == [0, 0, 0])
    let privateURL = URL(string: feedURL(.bestBlogs).absoluteString + "?token=not-public")!
    await #expect(throws: ConnectorError.unsupportedInput) {
        try await connector.discover(input: .init(url: privateURL), context: .init())
    }
    #expect(await http.requestCount() == 1)
}
