import CrosscurrentBrowser
import CrosscurrentReader
import Foundation
import Testing

@Test func linkPreviewPolicyRejectsLocalAndSecretBearingSchemes() throws {
    #expect(LinkPreviewURLPolicy.allows(try #require(URL(string: "https://example.com/article"))))
    #expect(LinkPreviewURLPolicy.allows(try #require(URL(string: "http://127.0.0.1/admin"))) == false)
    #expect(LinkPreviewURLPolicy.allows(try #require(URL(string: "http://192.168.1.3/"))) == false)
    #expect(LinkPreviewURLPolicy.allows(try #require(URL(string: "file:///etc/passwd"))) == false)
}

private func maliciousArticleFixture() -> String {
    let repeated = Array(repeating: "This is evidence-rich article text that should remain readable after extraction.", count: 12).joined(separator: " ")
    return """
    <html><head><title>Safe title</title>
    <script>document.title = 'SOURCE SCRIPT EXECUTED'; window.webkit.messageHandlers.readabilityMessageHandler.postMessage({Type:'ContentParsed',Value:'bad'})</script>
    <meta http-equiv="refresh" content="0;url=https://attacker.invalid/">
    </head><body><nav>Noise</nav><article><h1>Safe title</h1><p>\(repeated)</p>
    <img src="https://attacker.invalid/pixel" onerror="document.title='HANDLER EXECUTED'">
    <a href="javascript:alert(1)">unsafe</a></article></body></html>
    """
}

@Test
func sourceHTMLIsMadeInertBeforeAnyJavaScriptRuntime() throws {
    let inert = try StaticHTMLPreprocessor.inertDocument(from: maliciousArticleFixture(), baseURL: URL(string: "https://example.com/article"))
    #expect(!inert.contains("SOURCE SCRIPT EXECUTED"))
    #expect(!inert.lowercased().contains("http-equiv=\"refresh\""))
    #expect(!inert.lowercased().contains("onerror"))
    let postBoundary = try StaticHTMLPreprocessor.conservativeSanitize(inert)
    #expect(!postBoundary.sanitizedHTML.lowercased().contains("<script"))
    #expect(!postBoundary.sanitizedHTML.lowercased().contains("javascript:"))
}

@Test
func sanitizerPreservesSafeSVGAndMathMLWithoutExecutableSubtrees() throws {
    let source = """
    <article>
      <svg viewBox="0 0 20 20" onload="alert(1)">
        <path d="M 1 1 L 19 19" stroke="currentColor"/>
        <foreignObject><script>alert(2)</script><p>unsafe subtree</p></foreignObject>
        <use href="javascript:alert(3)"/>
      </svg>
      <math display="block"><mfrac><mi>x</mi><mn>2</mn></mfrac></math>
      <img src="https://tracker.invalid/pixel" onerror="alert(4)">
    </article>
    """
    let output = try StaticHTMLPreprocessor.conservativeSanitize(source).sanitizedHTML.lowercased()
    #expect(output.contains("<svg"))
    #expect(output.contains("<path"))
    #expect(output.contains("<math"))
    #expect(output.contains("<mfrac"))
    #expect(!output.contains("onload"))
    #expect(!output.contains("onerror"))
    #expect(!output.contains("foreignobject"))
    #expect(!output.contains("<use"))
    #expect(!output.contains("tracker.invalid"))
    #expect(!output.contains("javascript:"))
}

@Test func authenticatedPlatformCaptureFixturesAreVersionedAndSecretRedacted() throws {
    let fixture = BrowserPlatformCaptureFixture(
        schemaVersion: 1,
        platform: .weChatOfficialAccount,
        kind: .listing,
        finalURLWithoutQuery: try #require(URL(string: "https://mp.weixin.qq.com/profile")),
        title: "Account listing",
        topLevelElementCounts: ["article": 5],
        resourceOrigins: ["https://res.wx.qq.com"]
    )
    let data = try JSONEncoder().encode(BrowserWorkerResponse.captureFixture(fixture))
    let decoded = try JSONDecoder().decode(BrowserWorkerResponse.self, from: data)
    guard case let .captureFixture(value) = decoded else {
        Issue.record("Capture response did not round-trip")
        return
    }
    #expect(value.schemaVersion == 1)
    #expect(value.finalURLWithoutQuery.query == nil)
    #expect(value.finalURLWithoutQuery.fragment == nil)
    #expect(value.resourceOrigins == ["https://res.wx.qq.com"])
}

// WKWebView cannot launch its content process in every command-line/sandbox test host. Release
// qualification runs this explicitly from the signed feasibility harness instead of allowing the
// default unit suite to hang when WebKit is unavailable.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CROSSCURRENT_RUN_WEBKIT_GATE"] == "1")) @MainActor
func bundledReadabilityAndDOMPurifyRunWithoutSourcePageScripts() async throws {
    let html = maliciousArticleFixture()
    let inert = try StaticHTMLPreprocessor.inertDocument(from: html, baseURL: URL(string: "https://example.com/article"))
    #expect(!inert.contains("SOURCE SCRIPT EXECUTED"))
    #expect(!inert.lowercased().contains("http-equiv=\"refresh\""))

    let result = try await SafeHTMLExtractor().extract(untrustedHTML: html, baseURL: URL(string: "https://example.com/article"))
    #expect(result.title != "SOURCE SCRIPT EXECUTED")
    #expect(result.title != "HANDLER EXECUTED")
    #expect(result.plainText.contains("evidence-rich article text"))
    #expect(result.sanitizedHTML.contains("evidence-rich article text"))
    #expect(!result.sanitizedHTML.lowercased().contains("<script"))
    #expect(!result.sanitizedHTML.lowercased().contains("onerror"))
    #expect(!result.sanitizedHTML.lowercased().contains("javascript:"))
}
