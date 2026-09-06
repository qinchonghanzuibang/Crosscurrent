import Foundation

public enum ConnectorCatalog {
    public static func production(
        browser: any BrowserCreatorSessionClient,
        weChatProvider: any WeChatIndexProvider,
        weChatCatalogs: [any WeChatPublicFeedCatalog] = [],
        weChatPublicHTTP: any ConnectorHTTPClient = AnonymousPublicWeChatHTTPClient(),
        imapTransport: (any IMAPSessionTransport)? = nil,
        gmailTransport: (any IMAPSessionTransport)? = nil,
        http: any ConnectorHTTPClient = URLSessionConnectorHTTPClient()
    ) async -> ConnectorRegistry {
        let registry = ConnectorRegistry()
        await registry.register(FeedConnector(http: http))
        await registry.register(WebConnector(http: http))
        await registry.register(GitHubConnector(http: http))
        await registry.register(ArxivConnector(http: http))
        await registry.register(HackerNewsConnector(http: http))
        await registry.register(RedditConnector(http: http))
        await registry.register(BlueskyConnector(http: http))
        await registry.register(WeChatConnector(provider: weChatProvider, catalogs: weChatCatalogs, publicHTTP: weChatPublicHTTP))
        for platform in AuthenticatedCreatorPlatform.allCases {
            await registry.register(AuthenticatedCreatorConnector(platform: platform, browser: browser))
        }
        if let imapTransport { await registry.register(IMAPConnector(transport: imapTransport)) }
        if let gmailTransport { await registry.register(IMAPConnector(kind: .gmail, transport: gmailTransport)) }
        return registry
    }
}
