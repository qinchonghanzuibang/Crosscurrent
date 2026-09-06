import CrosscurrentDomain
@testable import CrosscurrentModels
import Foundation
import Testing

@Test func aiRedirectsKeepPrivateInputAndCredentialsOnTheAuthorizedOrigin() async throws {
    let local = try #require(URL(string: "http://127.0.0.1:11434/api/chat"))
    let cloud = try #require(URL(string: "https://api.example.com/v1/messages"))
    let delegate = AIOriginRedirectDelegate()
    for (origin, destination) in [
        (local, cloud),
        (cloud, try #require(URL(string: "https://other.example.com/v1/messages"))),
        (cloud, try #require(URL(string: "http://api.example.com/v1/messages"))),
        (local, try #require(URL(string: "http://127.0.0.1:8080/api/chat"))),
        (cloud, try #require(URL(string: "https://user:secret@api.example.com/v1/messages"))),
    ] {
        let task = URLSession.shared.dataTask(with: origin)
        defer { task.cancel() }
        let response = try #require(HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: ["Location": destination.absoluteString]))
        let redirected = await delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: destination))
        #expect(redirected == nil)
    }
    #expect(AIOriginRedirectDelegate.allowsRedirect(from: cloud, to: try #require(URL(string: "https://api.example.com:443/v1/messages/"))))
}

@Test func ipv6LoopbackProvidersRemainLocalAndCredentialURLsAreRejected() throws {
    let endpoint = try #require(URL(string: "http://[::1]:11434/api/chat"))
    try AIEndpointSecurity.validate(endpoint)
    #expect(OllamaProvider(endpoint: endpoint).executionLocation == .local)
    #expect(OpenAICompatibleChatProvider(id: "local", apiKey: nil, endpoint: endpoint).executionLocation == .local)
    #expect(throws: AIProviderError.insecureEndpoint) {
        try AIEndpointSecurity.validate(#require(URL(string: "https://user:secret@api.example.com/v1/messages")))
    }
}

@Test func openAIResponsesAcceptsReasoningItemsWithoutContent() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ResponsesFixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = OpenAIResponsesProvider(apiKey: "fixture", endpoint: try #require(URL(string: "https://fixture.invalid/completed")), session: session)
    let request = AIRequest(task: .articleSummary, model: "reasoning-fixture", instructions: "Summarize", input: "Evidence", promptRevisionID: PromptRevisionID())
    let response = try await provider.perform(request)
    #expect(response.text == "A cited answer.")
    #expect(response.inputTokens == 5)
    let incomplete = OpenAIResponsesProvider(apiKey: "fixture", endpoint: try #require(URL(string: "https://fixture.invalid/incomplete")), session: session)
    await #expect(throws: AIProviderError.invalidResponse) { try await incomplete.perform(request) }
}

private final class ResponsesFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { return }
        let status = url.path == "/incomplete" ? "incomplete" : "completed"
        let body = """
        {"id":"resp_fixture","status":"\(status)","output":[{"type":"reasoning","summary":[]},{"type":"message","content":[{"type":"output_text","text":"A cited answer."}]}],"usage":{"input_tokens":5,"output_tokens":4}}
        """
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
