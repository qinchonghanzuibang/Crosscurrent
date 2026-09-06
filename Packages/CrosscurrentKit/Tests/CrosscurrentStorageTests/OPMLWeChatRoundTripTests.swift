import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentStorage
import Foundation
import Testing

private func opmlWeChatURL(_ catalog: WeChatCatalogID) -> URL {
    URL(string: "https://\(catalog.feedHost)/feed/\(String(repeating: catalog == .wechat2rss ? "a" : "b", count: 40)).xml")!
}

private struct OPMLWeChatCatalog: WeChatPublicFeedCatalog {
    let id = WeChatCatalogID.wechat2rss
    func refreshIfNeeded() async throws {}
    func search(query _: String) async -> [WeChatPublicFeedCandidate] {
        [.init(displayName: "机器之心", feedURL: opmlWeChatURL(id), catalog: id)]
    }
}

private struct OPMLPublicFeedHTTP: ConnectorHTTPClient {
    func get(_ url: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        guard WeChatCatalogID.allCases.contains(where: { $0.accepts(feedURL: url) }) else { throw ConnectorError.unsupportedInput }
        let xml = """
        <rss version="2.0"><channel><title>机器之心</title><description>人工智能研究</description>
        <item><title>一篇公开文章</title><link>https://mp.weixin.qq.com/s?__biz=QQ==&amp;mid=100&amp;idx=1&amp;sn=same</link></item>
        </channel></rss>
        """
        return .init(data: Data(xml.utf8), statusCode: 200, headers: [:], finalURL: url)
    }
}

private actor OPMLUnexpectedGenericHTTP: ConnectorHTTPClient {
    private var requests = 0
    func get(_: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        requests += 1
        throw ConnectorError.unsupportedInput
    }
    func count() -> Int { requests }
}

private struct OPMLNoPaidProvider: WeChatIndexProvider {
    func searchAccounts(query _: String) async throws -> [WeChatAccountIdentity] { throw ConnectorError.unsupportedInput }
    func resolveAccount(articleURL _: URL) async throws -> WeChatAccountIdentity { throw ConnectorError.unsupportedInput }
    func fetchDailyPosts(account _: WeChatAccountIdentity) async throws -> [WeChatPostCandidate] { throw ConnectorError.unsupportedInput }
    func fetchHistory(account _: WeChatAccountIdentity, cursor _: WeChatHistoryCursor?, limit _: Int) async throws -> WeChatHistoryPage { throw ConnectorError.unsupportedInput }
    func fetchArticleHTML(articleURL _: URL) async throws -> WeChatProviderArticle? { throw ConnectorError.unsupportedInput }
    func healthCheck() async -> WeChatProviderHealth { .missingConfiguration }
}

private struct OPMLOfflineOfficial: WeChatOfficialArticleLoading {
    func fetch(_: URL) async throws -> WeChatOfficialArticleResponse { throw URLError(.notConnectedToInternet) }
}

@Test func publicWeChatOPMLRoundTripReusesCatalogPublisherAndExportsOnePrimaryFeed() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WeChatOPML-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = CrosscurrentRepository(database: try .open(at: .init(container: directory.appendingPathComponent("original")), role: .mainApp))
    let sourceID = SourceID()
    let revision = SourceRevision(sourceID: sourceID, displayName: "机器之心")
    let source = LogicalSource(id: sourceID, currentRevisionID: revision.id, kind: .organization)
    let legacy = SourceEndpoint(sourceID: sourceID, connector: .weChatOfficialAccount,
        externalID: "wechat-account:gh_fixture", canonicalURL: URL(string: "https://mp.weixin.qq.com/mp/profile_ext?__biz=QQ=="),
        contentPrivacy: .public, weChatAcquisition: .init(providerID: "jizhila", priority: 2,
            accountAliases: ["wechat-account:gh_fixture", "wechat-account-biz:QQ=="], displayName: "机器之心"))
    _ = try await repository.saveSource(source, revision: revision, endpoints: [legacy])
    let registry = ConnectorRegistry()
    let genericHTTP = OPMLUnexpectedGenericHTTP()
    await registry.register(FeedConnector(http: genericHTTP))
    await registry.register(WeChatConnector(provider: OPMLNoPaidProvider(), official: OPMLOfflineOfficial(),
        catalogs: [OPMLWeChatCatalog()], publicHTTP: OPMLPublicFeedHTTP()))
    let discovery = SourceDiscoveryService(repository: repository, connectors: registry)
    let matches = try await discovery.search("机器之心", context: .init())
    let catalogResult = try #require(matches.first)
    let followed = try await discovery.commit(catalogResult, action: .subscribe)
    #expect(followed.sourceID == sourceID)
    let opml = """
    <opml version="2.0"><body>
    <outline title="机器之心" type="rss" xmlUrl="\(opmlWeChatURL(.wechat2rss))"/>
    <outline title="机器之心" type="rss" xmlUrl="\(opmlWeChatURL(.bestBlogs))"/>
    </body></opml>
    """
    let importer = OPMLImportService(repository: repository, discovery: discovery)
    let imported = try await importer.importData(Data(opml.utf8))
    let repeated = try await importer.importData(Data(opml.utf8))
    #expect(imported.sourceCount == 2 && imported.failures.isEmpty)
    #expect(repeated.sourceCount == 2 && repeated.failures.isEmpty)
    let snapshots = try await repository.sourceSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots.first?.source.id == sourceID)
    #expect(snapshots.first?.revision.id == revision.id)
    #expect(snapshots.first?.endpoints.count == 3)
    #expect(snapshots.first?.endpoints.allSatisfy { $0.connector == .weChatOfficialAccount } == true)
    #expect(await genericHTTP.count() == 0)

    let exported = try await OPMLExportService(repository: repository).exportData()
    let outlines = try OPMLParser().parse(data: exported)
    #expect(outlines.count == 1)
    #expect(outlines.first?.title == "机器之心")
    #expect(outlines.first?.feedURL == opmlWeChatURL(.wechat2rss))
    #expect(outlines.first?.attributes["crosscurrentConnector"] == "weChatOfficialAccount")
    let restoredRepository = CrosscurrentRepository(database: try .open(at: .init(container: directory.appendingPathComponent("restored")), role: .mainApp))
    let restoredDiscovery = SourceDiscoveryService(repository: restoredRepository, connectors: registry)
    let restored = try await OPMLImportService(repository: restoredRepository, discovery: restoredDiscovery).importData(exported)
    #expect(restored.sourceCount == 1 && restored.failures.isEmpty)
    let restoredSources = try await restoredRepository.sourceSnapshots()
    #expect(restoredSources.count == 1)
    #expect(restoredSources.first?.endpoints.first?.connector == .weChatOfficialAccount)
    #expect(restoredSources.first?.endpoints.first?.weChatAcquisition?.accountAliases == ["wechat-account-biz:QQ=="])
    #expect(await genericHTTP.count() == 0)
}
