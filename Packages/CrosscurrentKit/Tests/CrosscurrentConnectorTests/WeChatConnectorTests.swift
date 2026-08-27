import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation
import Testing

private actor FixtureProviderTransport: WeChatProviderTransport {
    private var responses: [WeChatProviderHTTPResponse]
    private(set) var requests: [WeChatProviderRequest] = []

    init(_ responses: [WeChatProviderHTTPResponse]) { self.responses = responses }

    func send(_ request: WeChatProviderRequest) async throws -> WeChatProviderHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return responses.count == 1 ? responses[0] : responses.removeFirst()
    }

    func requestCount() -> Int { requests.count }
    func lastRequestBody() -> Data? { requests.last?.body }
}

private actor FixtureWeChatProvider: WeChatIndexProvider {
    let account: WeChatAccountIdentity
    let history: [WeChatPostCandidate]
    let daily: [WeChatPostCandidate]
    let article: WeChatProviderArticle?
    private(set) var historyCalls = 0
    private(set) var dailyCalls = 0
    private(set) var articleCalls = 0

    init(account: WeChatAccountIdentity, history: [WeChatPostCandidate] = [], daily: [WeChatPostCandidate] = [], article: WeChatProviderArticle? = nil) {
        self.account = account
        self.history = history
        self.daily = daily
        self.article = article
    }

    func searchAccounts(query _: String) async throws -> [WeChatAccountIdentity] { [account] }
    func resolveAccount(articleURL _: URL) async throws -> WeChatAccountIdentity { account }
    func fetchDailyPosts(account _: WeChatAccountIdentity) async throws -> [WeChatPostCandidate] { dailyCalls += 1; return daily }
    func fetchHistory(account _: WeChatAccountIdentity, cursor _: WeChatHistoryCursor?, limit: Int) async throws -> WeChatHistoryPage {
        historyCalls += 1
        return WeChatHistoryPage(posts: Array(history.prefix(limit)), reachedEnd: true)
    }
    func fetchArticleHTML(articleURL _: URL) async throws -> WeChatProviderArticle? { articleCalls += 1; return article }
    func healthCheck() async -> WeChatProviderHealth { .configured }
    func counts() -> (history: Int, daily: Int, article: Int) { (historyCalls, dailyCalls, articleCalls) }
}

private struct FixtureOfficialLoader: WeChatOfficialArticleLoading {
    var response: WeChatOfficialArticleResponse
    func fetch(_: URL) async throws -> WeChatOfficialArticleResponse { response }
}

private func providerAccount() -> WeChatAccountIdentity {
    WeChatAccountIdentity(
        displayName: "机器之心",
        ghid: "gh_fixture",
        wxid: "almosthuman2014",
        biz: Data("2392014380".utf8).base64EncodedString(),
        avatarURL: URL(string: "https://mmbiz.qpic.cn/avatar/0"),
        description: "关注人工智能",
        owner: "机器之心（北京）科技有限公司",
        provenance: .init(providerID: "fixture")
    )
}

private func providerPost(_ index: Int, url: String? = nil) -> WeChatPostCandidate {
    WeChatPostCandidate(
        title: "Article \(index)",
        digest: "Digest \(index)",
        articleURL: URL(string: url ?? "https://mp.weixin.qq.com/s?__biz=Z2hfZml4dHVyZQ==&mid=100&idx=\(index)&sn=sn\(index)&scene=126&sessionid=volatile")!,
        publishedAt: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 - index * 60)),
        appmsgid: "100",
        position: index,
        sn: "sn\(index)",
        originalFlag: 1,
        itemShowType: 0,
        provenance: .init(providerID: "fixture")
    )
}

@Test func refreshPageDecodesOlderBrowserWorkerPayloadsAsRealRequests() throws {
    let legacy = Data(#"{"candidates":[],"reachedEnd":true,"deletionExternalIDs":[]}"#.utf8)
    let page = try JSONDecoder().decode(ConnectorRefreshPage.self, from: legacy)
    #expect(page.performedRemoteRequest)
}

@Test func jizhilaDecodingPreservesAccountAndPostIdentityFields() throws {
    let search = Data(#"""
    {"data":[{"subBoxes":[{"items":[{"desc":"关注人工智能","source":{"title":"机器之心主体"},"jumpInfo":{"nickName":"机器之心","userName":"gh_fixture","aliasName":"almosthuman2014","bizuin":2392014380,"headHDImgUrl":"http://mmbiz.qpic.cn/avatar/0","externalInfo":"已认证"}}]}]}]}
    """#.utf8)
    let accounts = try JizhilaWeChatResponseDecoder.searchAccounts(from: search)
    #expect(accounts.count == 1)
    #expect(accounts[0].ghid == "gh_fixture")
    #expect(accounts[0].wxid == "almosthuman2014")
    #expect(accounts[0].biz == Data("2392014380".utf8).base64EncodedString())
    #expect(accounts[0].stableExternalID == "wechat-account:gh_fixture")

    let history = Data(#"""
    {"code":0,"data":[{"position":2,"url":"http://mp.weixin.qq.com/s?__biz=QQ==&amp;mid=42&amp;idx=2&amp;sn=abc","sn":"abc","post_time":1700000000,"cover_url":"https://mmbiz.qpic.cn/cover/0","original":1,"item_show_type":0,"digest":"摘要","title":"标题","appmsgid":42}],"offset":"next","is_end":0}
    """#.utf8)
    let page = try JizhilaWeChatResponseDecoder.historyPage(from: history, limit: 25)
    #expect(page.posts.first?.appmsgid == "42")
    #expect(page.posts.first?.position == 2)
    #expect(page.posts.first?.sn == "abc")
    #expect(page.posts.first?.articleURL.absoluteString.contains("&amp;") == false)
    #expect(page.nextCursor?.offset == "next")
}

@Test func stableArticleIdentityIgnoresURLAndTrackingVariation() {
    let account = providerAccount()
    let long = providerPost(1)
    let short = providerPost(1, url: "https://mp.weixin.qq.com/s/short-token")
    #expect(WeChatArticleIdentity.externalID(account: account, post: long) == WeChatArticleIdentity.externalID(account: account, post: short))
    let canonical = WeChatArticleIdentity.canonicalize(long.articleURL)
    #expect(canonical.absoluteString.contains("scene=") == false)
    #expect(canonical.absoluteString.contains("sessionid=") == false)
    #expect(canonical.absoluteString.contains("__biz=") == true)
    #expect(canonical.absoluteString.contains("mid=100") == true)
    #expect(canonical.absoluteString.contains("idx=1") == true)
    #expect(canonical.absoluteString.contains("sn=sn1") == true)
}

@Test func paidAccountSearchIsCachedAfterExplicitSubmission() async throws {
    let fixture = Data(#"{"data":[{"subBoxes":[{"items":[{"jumpInfo":{"nickName":"机器之心","userName":"gh_fixture","aliasName":"almosthuman2014","bizuin":"2392014380"}}]}]}]}"#.utf8)
    let transport = FixtureProviderTransport([.init(data: fixture, statusCode: 200)])
    let provider = JizhilaWeChatIndexProvider(
        credentials: { WeChatProviderCredentials(apiKey: "secret") },
        transport: transport,
        searchCacheTTL: 600,
        minimumRequestInterval: 0
    )
    #expect(try await provider.searchAccounts(query: "机器之心").count == 1)
    #expect(try await provider.searchAccounts(query: " 机器之心 ").count == 1)
    #expect(await transport.requestCount() == 1)
}

@Test func transientProviderFailureRetriesAndConfigurationErrorsStayDistinct() async throws {
    let success = Data(#"{"data":[]}"#.utf8)
    let transport = FixtureProviderTransport([
        .init(data: Data(#"{"message":"Internal Server Error"}"#.utf8), statusCode: 500),
        .init(data: success, statusCode: 200),
    ])
    let provider = JizhilaWeChatIndexProvider(
        credentials: { WeChatProviderCredentials(apiKey: "secret") },
        transport: transport,
        minimumRequestInterval: 0,
        sleep: { _ in },
        jitter: { 0 }
    )
    #expect(try await provider.searchAccounts(query: "量子位").isEmpty)
    #expect(await transport.requestCount() == 2)

    do {
        try JizhilaWeChatResponseDecoder.validate(
            response: .init(data: Data(#"{"code":10002,"msg":"bad key"}"#.utf8), statusCode: 200),
            operation: .search
        )
        Issue.record("Expected configuration error")
    } catch ConnectorError.configurationRequired {
        // Expected: never map provider configuration to WeChat authentication.
    }

    #expect(throws: ConnectorError.quotaExhausted) {
        try JizhilaWeChatResponseDecoder.validate(
            response: .init(data: Data(#"{"code":20001}"#.utf8), statusCode: 200),
            operation: .history
        )
    }
    #expect(throws: ConnectorError.rateLimited(retryAfter: 5)) {
        try JizhilaWeChatResponseDecoder.validate(
            response: .init(data: Data(#"{"code":-1}"#.utf8), statusCode: 200),
            operation: .history
        )
    }
    #expect(throws: ConnectorError.temporarilyUnavailable) {
        try JizhilaWeChatResponseDecoder.validate(
            response: .init(data: Data(#"{"code":50000}"#.utf8), statusCode: 200),
            operation: .history
        )
    }
}

@Test func legacyArticleEndpointsUseTheDocumentedHistoryURLFallback() async throws {
    let transport = FixtureProviderTransport([
        .init(data: Data(#"{"code":0,"data":[],"is_end":1}"#.utf8), statusCode: 200),
    ])
    let provider = JizhilaWeChatIndexProvider(
        credentials: { WeChatProviderCredentials(apiKey: "secret") },
        transport: transport,
        minimumRequestInterval: 0
    )
    let historyURL = URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&mid=42&idx=1&sn=legacy")!
    let account = WeChatAccountIdentity(
        displayName: "Legacy account",
        wxid: "legacy-stable-id",
        historyURL: historyURL,
        provenance: .init(providerID: "persisted")
    )
    _ = try await provider.fetchHistory(account: account, cursor: nil, limit: 25)
    let bodyData = try #require(await transport.lastRequestBody())
    let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
    #expect(body["ghid"] as? String == "")
    #expect(body["url"] as? String == historyURL.absoluteString)
}

@Test func initialBackfillIsBoundedAndIncrementalRefreshHonorsFreshnessTTL() async throws {
    let account = providerAccount()
    let provider = FixtureWeChatProvider(
        account: account,
        history: (1...40).map { providerPost($0) },
        daily: [providerPost(41)]
    )
    let connector = WeChatConnector(provider: provider, refreshTTL: 4 * 60 * 60, initialBackfillLimit: 25)
    let endpoint = SourceEndpoint(
        sourceID: SourceID(),
        connector: .weChatOfficialAccount,
        externalID: "wechat-account:gh_fixture",
        canonicalURL: URL(string: "https://mp.weixin.qq.com/mp/profile_ext?__biz=MjM5MjAxNDM4MA=="),
        accessRequirement: .anonymous,
        contentPrivacy: .public
    )
    let initial = try await connector.refresh(endpoint: endpoint, cursor: Optional<ConnectorCursor>.none, context: ConnectorContext(now: { Date(timeIntervalSince1970: 2_000_000_000) }))
    #expect(initial.candidates.count == 25)
    #expect(initial.reachedEnd)

    var fresh = endpoint
    fresh.lastSuccessfulSync = Date(timeIntervalSince1970: 2_000_000_000 - 60)
    let skipped = try await connector.refresh(endpoint: fresh, cursor: Optional<ConnectorCursor>.none, context: ConnectorContext(now: { Date(timeIntervalSince1970: 2_000_000_000) }))
    #expect(skipped.candidates.isEmpty)
    #expect(skipped.performedRemoteRequest == false)

    var stale = endpoint
    stale.lastSuccessfulSync = Date(timeIntervalSince1970: 2_000_000_000 - 5 * 60 * 60)
    #expect(try await connector.refresh(endpoint: stale, cursor: Optional<ConnectorCursor>.none, context: ConnectorContext(now: { Date(timeIntervalSince1970: 2_000_000_000) })).candidates.count == 1)
    let counts = await provider.counts()
    #expect(counts.history == 1)
    #expect(counts.daily == 1)
}

@Test func abnormalOfficialPageFallsBackToProviderWithoutBrowserSemantics() async throws {
    let captcha = String(repeating: "请输入验证码，访问环境异常。", count: 20)
    let official = FixtureOfficialLoader(response: .init(data: Data(captcha.utf8), statusCode: 200, finalURL: URL(string: "https://mp.weixin.qq.com/s/example")!))
    let providerHTML = "<section id=\"js_content\"><h2>标题</h2><p>" + String(repeating: "完整的微信公众号正文与中英文 mixed content。", count: 20) + "</p></section>"
    let provider = FixtureWeChatProvider(account: providerAccount(), article: .init(html: providerHTML, provenance: .init(providerID: "fixture")))
    let connector = WeChatConnector(provider: provider, official: official)
    let candidate = ConnectorItemCandidate(
        externalID: "wechat-article:gh_fixture:100:1",
        canonicalURL: URL(string: "https://mp.weixin.qq.com/s/example"),
        title: "标题",
        summary: "摘要"
    )
    let enriched = try await connector.fetchContent(candidate: candidate, context: ConnectorContext())
    #expect(enriched.contentHTML == providerHTML)
    #expect(enriched.acquisitionProvenance == .providerFallback)
    #expect(enriched.deletionState == .available)
    #expect(!connector.capabilities.contains(.authentication))
    #expect(!connector.capabilities.contains(.browserRequired))
    #expect(!AuthenticatedCreatorPlatform.allCases.map(\.connectorKind).contains(.weChatOfficialAccount))
}

@Test func onlyDefinitiveArticleFailureMarksEvidenceUnavailable() async throws {
    let url = URL(string: "https://mp.weixin.qq.com/s/example")!
    let provider = FixtureWeChatProvider(account: providerAccount())
    let candidate = ConnectorItemCandidate(externalID: "wechat-article:gh_fixture:100:1", canonicalURL: url, title: "标题")
    let missing = WeChatConnector(
        provider: provider,
        official: FixtureOfficialLoader(response: .init(data: Data(), statusCode: 404, finalURL: url))
    )
    #expect(try await missing.fetchContent(candidate: candidate, context: ConnectorContext()).deletionState == .unavailable)

    let transient = WeChatConnector(
        provider: provider,
        official: FixtureOfficialLoader(response: .init(data: Data(), statusCode: 503, finalURL: url))
    )
    #expect(try await transient.fetchContent(candidate: candidate, context: ConnectorContext()).deletionState == .available)
}
