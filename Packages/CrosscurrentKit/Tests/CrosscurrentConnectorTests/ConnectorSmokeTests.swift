import CrosscurrentConnectors
import CrosscurrentDomain
import Foundation
import Testing

@Test func connectorCapabilitiesRemainExplicit() {
    let capabilities: ConnectorCapabilities = [.discovery, .pagination, .backgroundRefresh]
    #expect(capabilities.contains(.discovery))
    #expect(capabilities.contains(.authentication) == false)
}

@Test func feedParserPreservesStableIdentityAndContent() throws {
    let xml = """
    <?xml version="1.0"?><rss version="2.0"><channel><title>Fixture News</title><link>https://example.com</link><description>Fixture</description>
    <item><guid isPermaLink="false">entry-42</guid><title>Stable entry</title><link>https://example.com/42</link><description>Summary</description><pubDate>Tue, 19 Aug 2025 12:00:00 GMT</pubDate></item>
    </channel></rss>
    """
    let items = try FeedConnector.parseItems(data: Data(xml.utf8))
    #expect(items.count == 1)
    #expect(items[0].externalID == "entry-42")
    #expect(items[0].canonicalURL?.absoluteString == "https://example.com/42")
}

private actor MockBrowserCreatorClient: BrowserCreatorSessionClient {
    let identity: BrowserCreatorIdentity
    init(identity: BrowserCreatorIdentity) { self.identity = identity }
    func authenticate(platform _: AuthenticatedCreatorPlatform, accountID _: ConnectorAccountID, allowsInteraction _: Bool) async throws {}
    func discover(_: BrowserCreatorDiscoveryRequest) async throws -> BrowserCreatorIdentity { identity }
    func refresh(_: BrowserCreatorRefreshRequest) async throws -> ConnectorRefreshPage { ConnectorRefreshPage(candidates: identity.recentItems, reachedEnd: true) }
    func health(platform _: AuthenticatedCreatorPlatform, accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    func disconnect(platform _: AuthenticatedCreatorPlatform, accountID _: ConnectorAccountID) async throws {}
}

@Test func authenticatedCreatorCanStillBePublic() async throws {
    let identity = BrowserCreatorIdentity(stableCreatorID: "creator-1", displayName: "Public Creator", profileURL: URL(string: "https://www.xiaohongshu.com/user/profile/creator-1")!, entityKind: .person, recentItems: [])
    let connector = AuthenticatedCreatorConnector(platform: .xiaohongshu, browser: MockBrowserCreatorClient(identity: identity))
    let result = try await connector.discover(input: ConnectorDiscoveryInput(url: identity.profileURL, accountID: ConnectorAccountID()), context: ConnectorContext())
    #expect(result.endpoints.first?.accessRequirement == .authenticated)
    #expect(result.endpoints.first?.contentPrivacy == .public)
    #expect(result.entityCandidates.first?.kind == .person)
}

@Test func authenticatedCreatorDoesNotClaimAnUncapturedListingContract() {
    let identity = BrowserCreatorIdentity(stableCreatorID: "creator-1", displayName: "Public Creator", profileURL: URL(string: "https://x.com/creator")!, entityKind: .person, recentItems: [])
    let connector = AuthenticatedCreatorConnector(platform: .x, browser: MockBrowserCreatorClient(identity: identity))
    #expect(connector.qualificationState == .captureRequired)
    #expect(connector.capabilities == [.discovery, .authentication, .browserRequired])
    #expect(!connector.capabilities.contains(.pagination))
    #expect(!connector.capabilities.contains(.backgroundRefresh))
    #expect(!connector.capabilities.contains(.deletionSignals))
}
