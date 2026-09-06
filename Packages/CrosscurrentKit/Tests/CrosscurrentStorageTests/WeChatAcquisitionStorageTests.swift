import CrosscurrentConnectors
import CrosscurrentDomain
@testable import CrosscurrentIngestion
@testable import CrosscurrentStorage
import Foundation
import Testing

private func storedWeChat(_ repository: CrosscurrentRepository, name: String = "机器之心") async throws -> (LogicalSource, SourceRevision, SourceEndpoint) {
    let revision = SourceRevision(sourceID: SourceID(), displayName: name)
    let source = LogicalSource(id: revision.sourceID, currentRevisionID: revision.id, kind: .organization, createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .weChatOfficialAccount,
        externalID: "wechat-account:gh_fixture", canonicalURL: URL(string: "https://mp.weixin.qq.com/mp/profile_ext?action=home&__biz=QQ=="),
        accessRequirement: .anonymous, contentPrivacy: .public)
    _ = try await repository.saveSource(source, revision: revision, endpoints: [endpoint])
    return (source, revision, endpoint)
}

private func publicEndpoint(sourceID: SourceID, secondary: Bool = false, biz: String = "QQ==") -> SourceEndpoint {
    SourceEndpoint(sourceID: sourceID, connector: .weChatOfficialAccount,
        externalID: "wechat-account-biz:\(biz):feed:\(secondary ? "bestblogs" : "xlab")",
        canonicalURL: URL(string: "https://\(secondary ? "wechat2rss.bestblogs.dev" : "wechat2rss.xlab.app")/feed/fixture.xml"),
        contentPrivacy: .public,
        weChatAcquisition: .init(providerID: secondary ? "bestblogs" : "xlab", priority: secondary ? 1 : 0,
            accountAliases: ["wechat-account-biz:\(biz)"], displayName: "机器之心"))
}

@Test func weChatFollowAttachesTwoQualifiedEndpointsToTheExistingPublisher() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatAttach-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CrosscurrentRepository(database: try .open(at: .init(container: root), role: .mainApp))
    let (source, revision, legacy) = try await storedWeChat(repository)
    let newSourceID = SourceID()
    let discoveredRevision = SourceRevision(sourceID: newSourceID, displayName: "Renamed publisher")
    let result = ConnectorDiscoveryResult(
        source: LogicalSource(id: newSourceID, currentRevisionID: discoveredRevision.id, kind: .organization),
        sourceRevision: discoveredRevision,
        endpoints: [publicEndpoint(sourceID: newSourceID), publicEndpoint(sourceID: newSourceID, secondary: true)],
        aiClassification: .init(sourceID: newSourceID, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain),
        coverageCandidate: .init(sourceID: newSourceID, ecosystem: .chinaFocused, provenance: .connector, confidence: .certain))
    let service = SourceDiscoveryService(repository: repository)
    let commit = try await service.commit(result, idempotencyPrefix: "first-free-follow")
    _ = try await service.commit(result, idempotencyPrefix: "repeat-free-follow")
    let snapshots = try await repository.sourceSnapshots()
    #expect(snapshots.count == 1)
    #expect(commit.sourceID == source.id)
    #expect(commit.endpointIDs.count == 3)
    let snapshot = try #require(snapshots.first)
    #expect(snapshot.source == source)
    #expect(snapshot.revision.id == revision.id)
    #expect(snapshot.endpoints.contains { $0.id == legacy.id })
    #expect(snapshot.endpoints.allSatisfy { $0.sourceID == source.id })
    #expect(snapshot.endpoints.count == 3)

    // A same-name public account without stable identity overlap cannot attach.
    let unrelated = publicEndpoint(sourceID: SourceID(), secondary: true, biz: "OTHER==")
    var independent = unrelated
    independent.canonicalURL = URL(string: "https://wechat2rss.bestblogs.dev/feed/unrelated.xml")
    _ = try await repository.attachWeChatEndpoints([independent], to: source.id)
    #expect(try await repository.sourceEndpoints(sourceID: source.id).count == 3)
}

@Test func weChatProviderIdentityAliasesDeduplicateAcrossFeedsAndRelaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatArticleUnion-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let (source, _, legacy) = try await storedWeChat(repository)
    let primary = publicEndpoint(sourceID: source.id)
    let secondary = publicEndpoint(sourceID: source.id, secondary: true)
    _ = try await repository.attachWeChatEndpoints([primary, secondary], to: source.id)
    let pipeline = IngestionPipeline(repository: repository)
    let original = ConnectorItemCandidate(externalID: "wechat-article:gh_fixture:100:1",
        canonicalURL: URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&mid=100&idx=1&sn=same&scene=126"),
        title: "Same article", publishedAt: Date(timeIntervalSince1970: 1_700_000_000), contentText: "The immutable article evidence has one identity across all acquisition providers.")
    let first = try await pipeline.ingest(candidate: original, sourceID: source.id, endpointID: legacy.id)
    var free = original
    free.externalID = "wechat-article:QQ==:100:1"
    free.canonicalURL = URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&appmsgid=100&position=1&sn=same")
    let viaPrimary = try await pipeline.ingest(candidate: free, sourceID: source.id, endpointID: primary.id)
    let relaunched = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let viaSecondary = try await IngestionPipeline(repository: relaunched).ingest(candidate: free, sourceID: source.id, endpointID: secondary.id)
    #expect(first.item.id == viaPrimary.item.id)
    #expect(viaPrimary.item.id == viaSecondary.item.id)
    #expect(viaPrimary.item.sourceEndpointID == legacy.id)
    #expect(!viaPrimary.createdRevision && !viaSecondary.createdRevision)
    #expect(try await relaunched.qualificationEvidenceRecords().count == 1)

    // A migrated account's explicit different biz can reuse mid/idx safely.
    var migrated = free
    migrated.externalID = "wechat-article:NEW==:100:1"
    migrated.canonicalURL = URL(string: "https://mp.weixin.qq.com/s?__biz=NEW==&mid=100&idx=1&sn=different")
    let distinct = try await pipeline.ingest(candidate: migrated, sourceID: source.id, endpointID: primary.id)
    #expect(distinct.item.id != first.item.id)
}

@Test func weChatAcquisitionStateRoundTripsWithoutConflatingEndpointHealth() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatState-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let (source, _, _) = try await storedWeChat(repository)
    var primary = publicEndpoint(sourceID: source.id)
    var secondary = publicEndpoint(sourceID: source.id, secondary: true)
    _ = try await repository.attachWeChatEndpoints([primary, secondary], to: source.id)
    let started = Date(timeIntervalSince1970: 1_800_000_000)
    primary.health = .temporarilyUnavailable
    primary.weChatAcquisition?.lastAttempt = started
    primary.weChatAcquisition?.retryAfter = started.addingTimeInterval(1800)
    secondary.lastSuccessfulSync = started
    secondary.weChatAcquisition?.lastAttempt = started
    secondary.weChatAcquisition?.etag = "\"revision-2\""
    secondary.weChatAcquisition?.lastModified = "Wed, 02 Sep 2026 00:00:00 GMT"
    secondary.weChatAcquisition?.lastAudit = started
    let generation = try await repository.generations()[.endpoints]?.generation ?? 0
    _ = try await repository.finishWeChatSync(endpoints: [primary, secondary], itemCount: 2, startedAt: started)
    let reopened = CrosscurrentRepository(database: try .open(at: locations, role: .agent))
    #expect(try await reopened.sourceEndpoint(id: primary.id) == primary)
    #expect(try await reopened.sourceEndpoint(id: secondary.id) == secondary)
    #expect((try await reopened.generations()[.endpoints]?.generation ?? 0) > generation)
    let health = try await reopened.sourceEndpointHealth()
    #expect(health.first { $0.endpointID == primary.id }?.health == .temporarilyUnavailable)
    #expect(health.first { $0.endpointID == secondary.id }?.health == .healthy)
}

@Test func weChatRefreshJobsCoalesceAndLeaseAcrossEndpointsAndProcesses() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatLease-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let (source, _, legacy) = try await storedWeChat(repository)
    let free = publicEndpoint(sourceID: source.id)
    _ = try await repository.attachWeChatEndpoints([free], to: source.id)
    let agent = CrosscurrentRepository(database: try .open(at: locations, role: .agent))
    let background = try await agent.scheduleRefreshJob(endpointID: legacy.id, payload: JSONEncoder().encode(RefreshJobPayload(endpointID: legacy.id)), manual: false)
    let manual = try await repository.scheduleRefreshJob(endpointID: free.id, payload: JSONEncoder().encode(RefreshJobPayload(endpointID: free.id, manual: true)), manual: true)
    #expect(manual.id == background.id)
    #expect(manual.inputHash == "wechat-source:\(source.id)")
    #expect(try JSONDecoder().decode(RefreshJobPayload.self, from: manual.payload).manual)
    let (_, lease) = try #require(try await repository.leaseJob(id: manual.id, owner: "foreground"))
    #expect(try await agent.leaseNextJob(owner: "agent", eligibleKinds: ["refresh"]) == nil)
    let concurrent = try await agent.scheduleRefreshJob(endpointID: legacy.id, payload: Data(), manual: false)
    #expect(concurrent.id == manual.id && concurrent.state == .leased)
    // Even a legacy duplicate pending row cannot acquire the source while held.
    let duplicate = DurableJob(kind: "refresh", inputHash: manual.inputHash, idempotencyKey: "legacy-duplicate")
    _ = try await agent.enqueue(duplicate)
    #expect(try await agent.leaseJob(id: duplicate.id, owner: "agent") == nil)
    #expect(try await agent.leaseNextJob(owner: "agent", eligibleKinds: ["refresh"]) == nil)
    _ = try await repository.completeJob(lease)
    #expect(try await agent.leaseJob(id: duplicate.id, owner: "agent") != nil)
}

private actor WeChatUnionFeedHTTP: ConnectorHTTPClient {
    private(set) var requests: [(String, [String: String])] = []
    private let articleURL: String
    init(articleURL: String = "https://mp.weixin.qq.com/s?__biz=QQ==&mid=100&idx=1&sn=same") { self.articleURL = articleURL }
    func get(_ url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        requests.append((url.host ?? "", headers))
        let prose = String(repeating: "An article with complete evidence, useful paragraphs, and retained semantic markup. ", count: 15)
        let xml = """
        <rss version="2.0"><channel><title>机器之心</title><link>https://mp.weixin.qq.com</link><description>Public articles</description>
        <item><guid>provider-specific-guid</guid><title>Shared real article</title><link>\(articleURL.replacingOccurrences(of: "&", with: "&amp;"))</link><pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate><description><![CDATA[<article><h2>Evidence</h2><p>\(prose)</p></article>]]></description></item>
        </channel></rss>
        """
        // Return 200 even with a validator to exercise existing-article skipping.
        return .init(data: Data(xml.utf8), statusCode: 200, headers: ["ETag": "\"same-feed\""], finalURL: url)
    }
    func observations() -> [(String, [String: String])] { requests }
}

private actor WeChatUnionOfficialHTTP: WeChatOfficialArticleLoading {
    private var requests = 0
    func fetch(_ url: URL) async throws -> WeChatOfficialArticleResponse {
        requests += 1
        return .init(data: Data("temporarily unavailable".utf8), statusCode: 503, finalURL: url)
    }
    func requestCount() -> Int { requests }
}

@Test func weChatSourceRefreshPersistsTheUnionThenSkipsStoredArticleAcquisition() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatRefreshUnion-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let (source, _, _) = try await storedWeChat(repository)
    var primary = publicEndpoint(sourceID: source.id)
    primary.canonicalURL = URL(string: "https://wechat2rss.xlab.app/feed/\(String(repeating: "a", count: 40)).xml")
    primary.weChatAcquisition?.providerID = WeChatCatalogID.wechat2rss.rawValue
    var secondary = publicEndpoint(sourceID: source.id, secondary: true)
    secondary.canonicalURL = URL(string: "https://wechat2rss.bestblogs.dev/feed/\(String(repeating: "b", count: 40)).xml")
    secondary.weChatAcquisition?.providerID = WeChatCatalogID.bestBlogs.rawValue
    _ = try await repository.attachWeChatEndpoints([primary, secondary], to: source.id)
    let feeds = WeChatUnionFeedHTTP()
    let official = WeChatUnionOfficialHTTP()
    let connector = WeChatConnector(provider: JizhilaWeChatIndexProvider(credentials: { nil }), official: official, catalogs: [], publicHTTP: feeds)
    let registry = ConnectorRegistry()
    await registry.register(connector)
    let executor = RefreshJobExecutor(repository: repository, connectors: registry, blobStore: CanonicalBlobStore(locations: locations, repository: repository))
    for index in 0..<2 {
        let payload = try JSONEncoder().encode(RefreshJobPayload(endpointID: primary.id, manual: true))
        let job = try await repository.scheduleRefreshJob(endpointID: primary.id, payload: payload, manual: true)
        let (leased, lease) = try #require(try await repository.leaseJob(id: job.id, owner: "test"))
        let checkpoint = try await executor.execute(job: leased, lease: lease)
        _ = try await repository.completeJob(lease)
        #expect(checkpoint.itemRevisions == (index == 0 ? 1 : 0))
    }
    #expect(try await repository.qualificationEvidenceRecords().count == 1)
    #expect(await official.requestCount() == 1)
    let endpoints = try await repository.sourceEndpoints(sourceID: source.id)
    #expect(endpoints.first { $0.id == primary.id }?.weChatAcquisition?.etag == "\"same-feed\"")
    #expect(endpoints.first { $0.id == secondary.id }?.weChatAcquisition?.etag == "\"same-feed\"")
    let requests = await feeds.observations()
    #expect(requests.count == 3) // Initial primary + secondary audit, then primary only.
    #expect(requests.last?.1["If-None-Match"] == "\"same-feed\"")
}

@Test func weChatAcquisitionMigrationPreservesExistingSourceAndRegroupsPendingWork() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatSchemaUpgrade-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
    let repository = CrosscurrentRepository(database: database)
    let (source, revision, endpoint) = try await storedWeChat(repository)
    let oldJob = DurableJob(kind: "refresh", inputHash: endpoint.id.description, idempotencyKey: "pre-v8-job")
    _ = try await repository.enqueue(oldJob)
    // Restore the immediately preceding schema shape and its migration ledger.
    try await database.pool.write { db in
        try db.execute(sql: "ALTER TABLE source_endpoints DROP COLUMN wechat_acquisition_json")
        try db.execute(sql: "DROP INDEX items_source_canonical")
        try db.execute(sql: "DROP TABLE wechat_item_aliases")
        try db.execute(sql: "DROP TABLE wechat_item_backfills")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='canonical-v9-wechat-article-aliases'")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='canonical-v10-wechat-backfill'")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='canonical-v8-wechat-acquisition'")
        try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='canonical-v11-item-content-reversions'")
        try db.execute(sql: "PRAGMA user_version=7")
    }
    #expect(throws: (any Error).self) { try CrosscurrentDatabase.open(at: locations, role: .agent) }
    let migrated = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let snapshot = try #require(try await migrated.sourceSnapshots().first)
    #expect(snapshot.source == source)
    #expect(snapshot.revision.id == revision.id)
    #expect(snapshot.endpoints == [endpoint])
    let coalesced = try await migrated.scheduleRefreshJob(endpointID: endpoint.id, payload: Data(), manual: false)
    #expect(coalesced.id == oldJob.id)
    #expect(coalesced.inputHash == "wechat-source:\(source.id)")
}

private struct WeChatResolvingOfficialHTTP: WeChatOfficialArticleLoading {
    func fetch(_: URL) async throws -> WeChatOfficialArticleResponse {
        .init(data: Data("<div id='js_content'><p>\(String(repeating: "Original official article evidence. ", count: 30))</p></div>".utf8), statusCode: 200,
              finalURL: URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&mid=100&idx=1&sn=same")!)
    }
}

@Test func weChatResolvedShortURLRetainsAliasesWhenCompleteContentSkipsARevision() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatShortURLAliases-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
    let repository = CrosscurrentRepository(database: database)
    let (source, _, legacy) = try await storedWeChat(repository)
    var primary = publicEndpoint(sourceID: source.id)
    primary.canonicalURL = URL(string: "https://wechat2rss.xlab.app/feed/\(String(repeating: "a", count: 40)).xml")
    primary.weChatAcquisition?.providerID = WeChatCatalogID.wechat2rss.rawValue
    _ = try await repository.attachWeChatEndpoints([primary], to: source.id)
    let short = URL(string: "https://mp.weixin.qq.com/s/a-stable-public-short-link")!
    let prose = String(repeating: "A complete article remains useful when official account HTTP is temporarily unavailable. ", count: 20)
    let cached = ConnectorItemCandidate(externalID: "wechat-article:QQ==:url:original-short-hash", canonicalURL: short,
        title: "Shared real article", contentHTML: "<article><p>\(prose)</p></article>", contentText: prose,
        acquisitionProvenance: .wechat2rssPublicFeed, weChatOriginalURL: short)
    let blobs = CanonicalBlobStore(locations: locations, repository: repository)
    let original = try await IngestionPipeline(repository: repository, blobStore: blobs).ingest(candidate: cached, sourceID: source.id, endpointID: primary.id)
    // Simulate the already-written v8 Item: the v9 alias table starts empty.
    try await database.pool.write { db in try db.execute(sql: "DELETE FROM wechat_item_aliases") }
    let connector = WeChatConnector(provider: JizhilaWeChatIndexProvider(credentials: { nil }), official: WeChatResolvingOfficialHTTP(), catalogs: [], publicHTTP: WeChatUnionFeedHTTP(articleURL: short.absoluteString))
    let registry = ConnectorRegistry()
    await registry.register(connector)
    let payload = try JSONEncoder().encode(RefreshJobPayload(endpointID: primary.id, manual: true))
    let job = try await repository.scheduleRefreshJob(endpointID: primary.id, payload: payload, manual: true)
    let (leased, lease) = try #require(try await repository.leaseJob(id: job.id, owner: "short-url-upgrade"))
    let checkpoint = try await RefreshJobExecutor(repository: repository, connectors: registry, blobStore: blobs).execute(job: leased, lease: lease)
    _ = try await repository.completeJob(lease)
    #expect(checkpoint.itemRevisions == 0)

    let reopened = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let long = WeChatArticleIdentity.canonicalize(URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&mid=100&idx=1&sn=same")!)
    let resolved = try #require(try await reopened.weChatItemState(sourceID: source.id, externalID: "wechat-article:QQ==:100:1", canonicalURL: long))
    #expect(resolved.item.itemID == original.item.id)
    #expect(resolved.item.currentRevisionID == original.item.currentRevisionID)
    var providerCandidate = cached
    providerCandidate.externalID = "wechat-article:QQ==:100:1"
    providerCandidate.canonicalURL = long
    providerCandidate.weChatOriginalURL = nil
    let fromDirectProvider = try await IngestionPipeline(repository: reopened).ingest(candidate: providerCandidate, sourceID: source.id, endpointID: legacy.id)
    #expect(fromDirectProvider.item.id == original.item.id)
    #expect(!fromDirectProvider.createdRevision)
    #expect(try await reopened.qualificationEvidenceRecords().count == 1)
}

@Test func itemDetailLoadsTheExactRevisionsSanitizedReaderHTML() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "ItemReaderRevisions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let (source, _, endpoint) = try await storedWeChat(repository)
    let pipeline = IngestionPipeline(repository: repository, blobStore: CanonicalBlobStore(locations: locations, repository: repository))
    var candidate = ConnectorItemCandidate(externalID: "wechat-article:QQ==:100:1", canonicalURL: URL(string: "https://mp.weixin.qq.com/s?__biz=QQ==&mid=100&idx=1"),
        title: "Reader revision", contentHTML: "<article><h2>Original structure</h2><p>The original article contains semantic paragraphs.</p></article>", contentText: "The original article contains semantic paragraphs.")
    let first = try await pipeline.ingest(candidate: candidate, sourceID: source.id, endpointID: endpoint.id)
    candidate.contentHTML = "<article><h2>Revised structure</h2><p>The revised article adds complete evidence.</p><script>bad()</script></article>"
    candidate.contentText = "The revised article adds complete evidence."
    let second = try await pipeline.ingest(candidate: candidate, sourceID: source.id, endpointID: endpoint.id)
    let historical = try #require(try await repository.itemDetail(itemID: first.item.id, revisionID: first.item.currentRevisionID.description))
    let current = try #require(try await repository.itemDetail(itemID: first.item.id))
    #expect(historical.revisionID == first.item.currentRevisionID && historical.isHistorical)
    #expect(current.revisionID == second.item.currentRevisionID && !current.isHistorical)
    #expect(historical.sanitizedHTML?.contains("<h2>Original structure</h2>") == true)
    #expect(current.sanitizedHTML?.contains("<h2>Revised structure</h2>") == true)
    #expect(current.sanitizedHTML?.contains("<script") == false)
}

@Test func concurrentWeChatFollowCommitsOnePublisherAcrossDiscoveryServices() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatFollowRace-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let first = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let second = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    func discovery(secondary: Bool) -> ConnectorDiscoveryResult {
        let revision = SourceRevision(sourceID: SourceID(), displayName: "机器之心")
        return .init(source: .init(id: revision.sourceID, currentRevisionID: revision.id, kind: .organization), sourceRevision: revision,
            endpoints: [publicEndpoint(sourceID: revision.sourceID, secondary: secondary)],
            aiClassification: .init(sourceID: revision.sourceID, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain),
            coverageCandidate: .init(sourceID: revision.sourceID, ecosystem: .chinaFocused, provenance: .connector, confidence: .certain))
    }
    let primaryResult = discovery(secondary: false)
    let secondaryResult = discovery(secondary: true)
    async let a = SourceDiscoveryService(repository: first).commit(primaryResult, idempotencyPrefix: "concurrent-primary")
    async let b = SourceDiscoveryService(repository: second).commit(secondaryResult, idempotencyPrefix: "concurrent-secondary")
    let (primary, secondary) = try await (a, b)
    #expect(primary.sourceID == secondary.sourceID)
    let sources = try await first.sourceSnapshots()
    #expect(sources.count == 1)
    #expect(sources.first?.endpoints.count == 2)
    let conflicting = discovery(secondary: false)
    do {
        _ = try await first.saveSource(conflicting.source, revision: conflicting.sourceRevision, endpoints: conflicting.endpoints)
        Issue.record("Canonical source writer accepted a duplicate WeChat account")
    } catch let CrosscurrentStorageError.sourceIdentityConflict(winner) {
        #expect(winner == primary.sourceID)
    }
}

@Test func weChatLeaseGuardRenewsAndCancelsDuringSlowSourceAcquisition() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatLeaseGuard-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try CrosscurrentDatabase.open(at: .init(container: root), role: .mainApp)
    let repository = CrosscurrentRepository(database: database)
    let job = DurableJob(kind: "refresh", inputHash: "slow-wechat-source", idempotencyKey: "slow-wechat-source")
    _ = try await repository.enqueue(job)
    let (_, lease) = try #require(try await repository.leaseJob(id: job.id, owner: "foreground", duration: 60))
    let (started, signal) = AsyncStream<Void>.makeStream()
    let operation = Task {
        try await WeChatJobLeaseGuard.run(repository: repository, lease: lease, renewalInterval: .milliseconds(10)) {
            signal.yield(())
            signal.finish()
            try await Task.sleep(for: .seconds(3))
            return true
        }
    }
    for await _ in started { break }
    #expect(try await repository.leaseNextJob(owner: "agent", eligibleKinds: ["refresh"], now: lease.expiresAt.addingTimeInterval(1)) == nil)
    try await database.pool.write { db in
        try db.execute(sql: "UPDATE jobs SET cancellation_requested=1 WHERE id=?", arguments: [job.id.description])
    }
    do {
        _ = try await operation.value
        Issue.record("Cancelled acquisition returned success")
    } catch JobExecutionError.cancelled {
        // The renewing guard cancels the in-flight operation before any validators commit.
    }
}

@Test func oneWeChatSearchCanFollowDifferentPublishersAndReuseRepeatedFollows() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "WeChatSearchPublisherKeys-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CrosscurrentRepository(database: try .open(at: .init(container: root), role: .mainApp))
    let service = SourceDiscoveryService(repository: repository)
    func preview(biz: String, feedID: String) -> SourceDiscoveryPreview {
        let revision = SourceRevision(sourceID: SourceID(), displayName: "同名研究所")
        var endpoint = publicEndpoint(sourceID: revision.sourceID, biz: biz)
        endpoint.canonicalURL = URL(string: "https://wechat2rss.xlab.app/feed/\(String(repeating: feedID, count: 40)).xml")
        let result = ConnectorDiscoveryResult(
            source: .init(id: revision.sourceID, currentRevisionID: revision.id, kind: .organization), sourceRevision: revision, endpoints: [endpoint],
            aiClassification: .init(sourceID: revision.sourceID, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .connector, confidence: .certain),
            coverageCandidate: .init(sourceID: revision.sourceID, ecosystem: .chinaFocused, provenance: .connector, confidence: .certain))
        return .init(inputQuery: "同名研究所", connectorKind: .weChatOfficialAccount, result: result, availableActions: [.subscribe])
    }
    let first = try await service.commit(preview(biz: "FIRST==", feedID: "a"), action: .subscribe)
    let second = try await service.commit(preview(biz: "SECOND==", feedID: "b"), action: .subscribe)
    #expect(first.sourceID != second.sourceID)
    // New search previews have new temporary Source IDs, but stable publisher
    // aliases still reuse the existing committed Source on repeated Follow.
    let repeatedFirst = try await service.commit(preview(biz: "FIRST==", feedID: "a"), action: .subscribe)
    let repeatedSecond = try await service.commit(preview(biz: "SECOND==", feedID: "b"), action: .subscribe)
    #expect(repeatedFirst.sourceID == first.sourceID)
    #expect(repeatedSecond.sourceID == second.sourceID)
    let sources = try await repository.sourceSnapshots()
    #expect(sources.count == 2)
    #expect(Set(sources.map { $0.source.id }) == [first.sourceID, second.sourceID])
    #expect(sources.allSatisfy { $0.source.isFollowed && $0.endpoints.count == 1 })
}
