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
