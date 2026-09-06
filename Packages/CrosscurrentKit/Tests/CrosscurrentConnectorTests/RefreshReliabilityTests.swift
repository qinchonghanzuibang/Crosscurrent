@testable import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation
import Testing

private actor RevisionFeedHTTP: ConnectorHTTPClient {
    var changed = false
    func update() { changed = true }
    func get(_ url: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        let entries = (1...45).map { index in
            let image = changed && index == 42 ? "corrected.png" : "original.png"
            return "<item><guid>entry-\(index)</guid><title>Article \(index)</title><link>https://example.com/\(index)</link><content:encoded><![CDATA[<p>Stable text</p><img src='https://example.com/\(image)'>]]></content:encoded></item>"
        }.joined()
        return .init(data: Data("<rss version='2.0' xmlns:content='http://purl.org/rss/1.0/modules/content/'><channel><title>Revision feed</title>\(entries)</channel></rss>".utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

@Test func feedRefreshFindsEntriesBeyondThirtyAndDetectsHTMLOnlyCorrections() async throws {
    let http = RevisionFeedHTTP()
    let connector = FeedConnector(http: http)
    let endpoint = SourceEndpoint(sourceID: SourceID(), connector: .rss, externalID: "feed", canonicalURL: URL(string: "https://example.com/feed"))
    let legacy = try ConnectorCursor(family: "feed-seen-v1", value: ["entry-1"])
    let initial = try await connector.refresh(endpoint: endpoint, cursor: legacy, context: .init())
    #expect(initial.candidates.count == 45)
    let repeated = try await connector.refresh(endpoint: endpoint, cursor: initial.nextCursor, context: .init())
    #expect(repeated.candidates.isEmpty)
    await http.update()
    let corrected = try await connector.refresh(endpoint: endpoint, cursor: repeated.nextCursor, context: .init())
    #expect(corrected.candidates.map(\.externalID) == ["entry-42"])
    #expect(corrected.candidates.first?.contentHTML?.contains("corrected.png") == true)
}

@Test func cancelledHostWaiterExitsBeforeTheOccupiedRequestFinishes() async throws {
    let gate = HostRequestGate()
    try await gate.acquire("example.com")
    let waiter = Task {
        do { try await gate.acquire("example.com"); return false }
        catch is CancellationError { return true }
        catch { return false }
    }
    await Task.yield()
    waiter.cancel()
    let cancelledPromptly = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await waiter.value }
        group.addTask { try? await Task.sleep(for: .milliseconds(200)); return false }
        let result = await group.next() ?? false
        await gate.release("example.com")
        group.cancelAll()
        return result
    }
    #expect(cancelledPromptly)
    try await gate.acquire("example.com")
    await gate.release("example.com")
}
