import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentIngestion
import Foundation
import Testing

@Test func weChatReaderExtractionPreservesStructuredChineseContentAndLazyMedia() throws {
    let source = """
    <html><head><meta property="og:title" content="机器之心测试文章"><script>window.evil = true</script></head><body>
      <h1 id="activity-name">机器之心测试文章</h1>
      <section id="js_content" class="rich_media_content">
        <h2>方法与结果</h2>
        <p>这是一段足够长的中文正文，包含 mixed English terminology and useful links，确保阅读器保留真实文章结构而不是把内容压平成纯文本。</p>
        <blockquote>关键结论应当作为引用保留。</blockquote>
        <ol><li>第一步</li><li>第二步</li></ol>
        <pre><code>let model = "Crosscurrent"</code></pre>
        <table><thead><tr><th>模型</th><th>分数</th></tr></thead><tbody><tr><td>A</td><td>95</td></tr></tbody></table>
        <figure><img data-src="https://mmbiz.qpic.cn/sz_mmbiz_jpg/example/640" alt="系统图"><figcaption>系统结构图</figcaption></figure>
        <p><a href="https://example.com/paper">论文链接</a></p>
      </section>
    </body></html>
    """
    let result = try WeChatHTMLPreprocessor.articleContent(from: source, baseURL: URL(string: "https://mp.weixin.qq.com/s/example"))
    #expect(result.title == "机器之心测试文章")
    #expect(result.plainText.contains("mixed English terminology"))
    #expect(result.sanitizedHTML.contains("<h2>"))
    #expect(result.sanitizedHTML.contains("<blockquote>"))
    #expect(result.sanitizedHTML.contains("<ol>"))
    #expect(result.sanitizedHTML.contains("<pre>"))
    #expect(result.sanitizedHTML.contains("<table>"))
    #expect(result.sanitizedHTML.contains("<figure>"))
    #expect(result.sanitizedHTML.contains("src=\"https://mmbiz.qpic.cn/"))
    #expect(result.sanitizedHTML.contains("href=\"https://example.com/paper\""))
    #expect(!result.sanitizedHTML.lowercased().contains("<script"))
    #expect(!result.sanitizedHTML.contains("data-src"))
}

@Test func weChatReaderRejectsVerificationAndEmptyArticlePages() throws {
    #expect(throws: WeChatHTMLPreprocessorError.rejectedResponse) {
        try WeChatHTMLPreprocessor.articleContent(
            from: "<html><body><section id='js_content'>请输入验证码，当前访问环境异常。</section></body></html>",
            baseURL: URL(string: "https://mp.weixin.qq.com/s/example")
        )
    }
    #expect(throws: WeChatHTMLPreprocessorError.missingBody) {
        try WeChatHTMLPreprocessor.articleContent(
            from: "<html><body><section id='js_content'>短</section></body></html>",
            baseURL: URL(string: "https://mp.weixin.qq.com/s/example")
        )
    }
}

@Test(arguments: ["wechat2rss.xlab.app", "wechat2rss.bestblogs.dev"])
func weChatPublicFeedReaderUnwrapsObservedImageProxyAndKeepsArticleStructure(host: String) throws {
    // Both live 机器之心 feeds use /img-proxy/?k=<signature>&u=<percent-encoded official media>.
    let originalImage = "https://mmbiz.qpic.cn/sz_mmbiz_png/reader-fixture/640?wx_fmt=png&from=appmsg"
    var proxy = URLComponents(string: "https://\(host)/img-proxy/")!
    proxy.queryItems = [.init(name: "k", value: "51a51509"), .init(name: "u", value: originalImage)]
    let source = """
    <div>
      <h2>真实三维环境中的模型能力</h2>
      <p>这是一篇来自微信公众号公开 RSS 的技术文章片段，包含 enough mixed English terminology to exercise the Reader. 模型需要理解道路、建筑和空间关系，并将观察到的内容转化为可验证的行动计划。</p>
      <p>方法的比较必须保留原始数据、图片说明、代码以及论文链接，便于读者核对证据。不能将技术结构压平成没有层次的纯文本。</p>
      <figure><img data-src="\(proxy.url!.absoluteString)" alt="三维街景" onerror="stealCookies()"><figcaption>三维场景与路径规划示意图</figcaption></figure>
      <pre><code>if score &lt; threshold { retry() }</code></pre>
      <table><tr><th>模型</th><th>成功率</th></tr><tr><td>模型 A</td><td>82%</td></tr></table>
      <p><a href="https://arxiv.org/abs/2601.12345">论文与方法</a></p>
      <script>stealCookies()</script>
    </div>
    """
    let result = try WeChatHTMLPreprocessor.articleContent(from: source, baseURL: URL(string: "https://mp.weixin.qq.com/s/reader-fixture"))
    let html = result.sanitizedHTML
    #expect(result.plainText.contains("模型需要理解道路"))
    #expect(html.contains("<p>"))
    #expect(html.contains("<pre><code>"))
    #expect(html.contains("<table>"))
    #expect(html.range(of: #"<figcaption>\s*三维场景与路径规划示意图\s*</figcaption>"#, options: .regularExpression) != nil)
    #expect(html.contains("src=\"https://mmbiz.qpic.cn/sz_mmbiz_png/reader-fixture/640?"))
    #expect(html.contains("https://arxiv.org/abs/2601.12345"))
    #expect(!html.contains("img-proxy"))
    #expect(!html.contains("51a51509"))
    #expect(!html.contains("data-src"))
    #expect(!html.contains("onerror"))
    #expect(!html.contains("stealCookies"))
    #expect(!html.lowercased().contains("<script"))
}

private actor ImageArticlePaidGuard: WeChatIndexProvider {
    private var articleCalls = 0
    func searchAccounts(query _: String) async throws -> [WeChatAccountIdentity] { throw ConnectorError.unsupportedInput }
    func resolveAccount(articleURL _: URL) async throws -> WeChatAccountIdentity { throw ConnectorError.unsupportedInput }
    func fetchDailyPosts(account _: WeChatAccountIdentity) async throws -> [WeChatPostCandidate] { throw ConnectorError.unsupportedInput }
    func fetchHistory(account _: WeChatAccountIdentity, cursor _: WeChatHistoryCursor?, limit _: Int) async throws -> WeChatHistoryPage { throw ConnectorError.unsupportedInput }
    func fetchArticleHTML(articleURL _: URL) async throws -> WeChatProviderArticle? { articleCalls += 1; return nil }
    func healthCheck() async -> WeChatProviderHealth { .configured }
    func count() -> Int { articleCalls }
}

private struct ImageArticleOfflineOfficial: WeChatOfficialArticleLoading {
    func fetch(_: URL) async throws -> WeChatOfficialArticleResponse { throw URLError(.notConnectedToInternet) }
}

@Test(arguments: ["", "<p>所有部门人才扩招，大量岗位急招中。</p>"])
func imageLedPublicFeedArticlesRemainReadableWithoutPaidEnrichment(paragraph: String) async throws {
    // Matches the complete image-led posts observed in the BestBlogs DeepSeek feed.
    var proxy = URLComponents(string: "https://wechat2rss.bestblogs.dev/img-proxy/")!
    proxy.queryItems = [
        .init(name: "k", value: "7aa72f1c"),
        .init(name: "u", value: "https://mmbiz.qpic.cn/mmbiz_jpg/image-article-fixture/640?wx_fmt=jpeg"),
    ]
    let html = "<article>\(paragraph)<img data-src='\(proxy.url!.absoluteString)' onerror='unsafeAction()'><img src='https://mmbiz.qpic.cn/mmbiz_png/image-article-poster/640'><script>unsafeAction()</script></article>"
    let paid = ImageArticlePaidGuard()
    let connector = WeChatConnector(provider: paid, official: ImageArticleOfflineOfficial())
    let original = ConnectorItemCandidate(externalID: "wechat-article:QQ==:1:1",
        canonicalURL: URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&mid=1&idx=1&sn=image"),
        title: "完整海报文章", contentHTML: html, acquisitionProvenance: .bestBlogsWechat2RSS)
    #expect(WeChatPublicFeedContent.isComplete(html))
    let fetched = try await connector.fetchContent(candidate: original, context: .init())
    let reader = try await ArticleContentEnricher().enrich(fetched, connector: .weChatOfficialAccount)
    #expect(await paid.count() == 0)
    #expect(reader.acquisitionProvenance == .bestBlogsWechat2RSS)
    #expect((reader.contentText?.count ?? 0) < 80)
    #expect(reader.contentHTML?.contains("https://mmbiz.qpic.cn/mmbiz_jpg/image-article-fixture/640") == true)
    #expect(reader.contentHTML?.contains("https://mmbiz.qpic.cn/mmbiz_png/image-article-poster/640") == true)
    #expect(reader.contentHTML?.contains("img-proxy") == false)
    #expect(reader.contentHTML?.contains("7aa72f1c") == false)
    #expect(reader.contentHTML?.contains("onerror") == false)
    #expect(reader.contentHTML?.contains("unsafeAction") == false)
}
