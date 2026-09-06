import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentStorage
import Foundation
import Testing

private func reliabilitySource(_ repository: CrosscurrentRepository, connector: ConnectorKind = .rss) async throws -> SourceEndpoint {
    let revision = SourceRevision(sourceID: SourceID(), displayName: "Reliability fixture")
    let source = LogicalSource(id: revision.sourceID, currentRevisionID: revision.id, kind: .publication)
    let endpoint = SourceEndpoint(sourceID: source.id, connector: connector, externalID: "fixture", canonicalURL: URL(string: "https://example.com/feed"), contentPrivacy: .public)
    _ = try await repository.saveSource(source, revision: revision, endpoints: [endpoint])
    return endpoint
}

@Test func identicalTextHasDistinctEvidenceLineagesAcrossItemsAndRepeatedParagraphs() {
    let body = "This independent paragraph carries evidence and ends with a period."
    let original = ItemRevision(itemID: ItemID(), title: "Original", text: body + "\n\n" + body, contentHash: "same-text")
    let mirror = ItemRevision(itemID: ItemID(), title: "Mirror", text: original.text, contentHash: "same-text")
    let initial = ItemSegmenter.segments(for: original)
    let copied = ItemSegmenter.segments(for: mirror)
    #expect(Set(initial.map(\.lineageID)).count == 2)
    #expect(Set(initial.map(\.lineageID)).isDisjoint(with: copied.map(\.lineageID)))
    let revised = ItemRevision(itemID: original.itemID, title: "Corrected title", text: original.text, contentHash: "title-edit")
    #expect(ItemSegmenter.segments(for: revised, aligningWith: initial).map(\.lineageID) == initial.map(\.lineageID))
}

@Test func shareRecoveryUsesLeaseAcquisitionTimeInsteadOfOldQueuedRecordTime() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentShareLeaseReview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let now = Date.now
    let record = ShareInboxRecord(url: URL(string: "https://example.com/selection")!, title: "Selection", selectedText: "A valid private selection retained while another writer is active.")
    let claimed = locations.shareInbox.appending(path: "\(record.id).json.lease-\(Int(now.timeIntervalSince1970))-other-writer")
    try JSONEncoder().encode(record).write(to: claimed)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: claimed.path)
    let importer = ShareInboxImporter(locations: locations, repository: repository)
    #expect(try await importer.importAvailable(now: now).importedRecords == 0)
    #expect(FileManager.default.fileExists(atPath: claimed.path))
    #expect(try await importer.importAvailable(now: now.addingTimeInterval(601)).importedRecords == 1)
}

@Test func ingestionRevisionsIncludeHTMLChangesAndContentReversions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentRevisionReview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let repository = CrosscurrentRepository(database: try .open(at: locations, role: .mainApp))
    let endpoint = try await reliabilitySource(repository)
    let pipeline = IngestionPipeline(repository: repository, blobStore: .init(locations: locations, repository: repository))
    let original = ConnectorItemCandidate(externalID: "article", title: "Diagram evidence", contentHTML: "<p>Stable prose</p><img src='https://example.com/first.png'>", contentText: "Stable prose")
    let first = try await pipeline.ingest(candidate: original, sourceID: endpoint.sourceID, endpointID: endpoint.id)
    var changed = original
    changed.contentHTML = "<p>Stable prose</p><img src='https://example.com/corrected.png'>"
    let second = try await pipeline.ingest(candidate: changed, sourceID: endpoint.sourceID, endpointID: endpoint.id)
    let restored = try await pipeline.ingest(candidate: original, sourceID: endpoint.sourceID, endpointID: endpoint.id)
    #expect(first.createdRevision && second.createdRevision && restored.createdRevision)
    #expect(restored.revision?.ordinal == 3)
    #expect(restored.revision?.id != first.revision?.id)
    #expect(restored.revision?.contentHash == first.revision?.contentHash)
    #expect(try await repository.itemState(endpointID: endpoint.id, externalID: "article")?.currentRevisionID == restored.revision?.id)
    let prior = try await repository.itemDetail(itemID: first.item.id, revisionID: second.revision?.id.description)
    #expect(prior?.sanitizedHTML?.contains("corrected.png") == true)
    let repeated = try await pipeline.ingest(candidate: original, sourceID: endpoint.sourceID, endpointID: endpoint.id)
    #expect(!repeated.createdRevision)
}

private struct UnavailableArticleHTTP: ConnectorHTTPClient {
    func get(_: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse { throw URLError(.notConnectedToInternet) }
}

@Test func articleExtractionAcceptsMainTextAfterRemovingLongerNavigation() async throws {
    let main = String(repeating: "The article contains useful original evidence. ", count: 8)
    let enricher = ArticleContentEnricher(extract: { _, _ in
        .init(title: "Article", sanitizedHTML: "<p>\(main)</p>", plainText: main)
    })
    let candidate = ConnectorItemCandidate(externalID: "article", title: "Article", contentHTML: "<nav>Repeated menu</nav><article>\(main)</article>", contentText: String(repeating: "Repeated menu ", count: 100) + main)
    let enriched = try await enricher.enrich(candidate, connector: .website)
    #expect(enriched.contentText == main)
    #expect(enriched.contentHTML?.contains("<nav>") == false)

    let preview = ConnectorItemCandidate(externalID: "excerpt", canonicalURL: URL(string: "https://example.com/excerpt"), title: "Valid feed entry", summary: "The feed remains available offline.")
    #expect(try await ArticleContentEnricher(http: UnavailableArticleHTTP()).enrich(preview, connector: .rss) == preview)
}

@Test func suppliedFeedDigestRetainsHeadingsLinkedListsAndQuotesWithoutPageHeuristics() async throws {
    // Shape observed in Swift.org's August 2026 Atom entry: Readability removed
    // header-with-anchor headings and whole linked lists from this complete body.
    let html = """
    <p>A monthly update from the language community.</p>
    <blockquote><p>The community builds useful tools for developers.</p></blockquote>
    <h2 id="videos" class="header-with-anchor">Videos to watch <a href="#videos"><svg viewBox="0 0 10 10"><path d="M 0 0 L 10 10"/></svg></a></h2>
    <ul><li><a href="https://example.com/video">A technical video</a> explains memory safety and <code>Span</code>.</li></ul>
    <h2 class="header-with-anchor">New package releases</h2>
    <ul><li><a href="https://example.com/package">A new package</a> provides useful APIs.</li></ul>
    <p>Formula <script type="math/tex">x^2</script></p><script>unsafeSourceScript()</script>
    """
    let enricher = ArticleContentEnricher(extract: { _, _ in
        Issue.record("Feed-provided article fragments must not enter page extraction")
        throw ConnectorError.invalidResponse("unexpected extraction")
    })
    let candidate = ConnectorItemCandidate(externalID: "digest", canonicalURL: URL(string: "https://example.com/digest"), title: "Monthly update", contentHTML: html)
    let enriched = try await enricher.enrich(candidate, connector: .rss)
    let output = try #require(enriched.contentHTML)
    #expect(output.components(separatedBy: "<h2").count == 3)
    #expect(output.components(separatedBy: "<li>").count == 3)
    #expect(output.contains("<blockquote>"))
    #expect(output.contains("<code>Span</code>"))
    #expect(output.contains("\\(x^2\\)"))
    #expect(!output.contains("unsafeSourceScript"))
}

private actor PaginatedRefreshFixture: Connector {
    nonisolated let kind: ConnectorKind = .github
    nonisolated let cursorScope: ConnectorCursorScope = .refreshPagination
    nonisolated let capabilities: ConnectorCapabilities = [.backgroundRefresh, .pagination]
    private var starts: [Int] = []
    func discover(input _: ConnectorDiscoveryInput, context _: ConnectorContext) async throws -> ConnectorDiscoveryResult { throw ConnectorError.unsupportedInput }
    func authenticate(accountID _: ConnectorAccountID, context _: ConnectorContext) async throws {}
    func refresh(endpoint _: SourceEndpoint, cursor: ConnectorCursor?, context _: ConnectorContext) async throws -> ConnectorRefreshPage {
        let page = try cursor?.decode(Int.self) ?? 1
        starts.append(page)
        return .init(candidates: [ConnectorItemCandidate(externalID: "page-\(page)", title: "Page \(page)", contentText: "Original evidence on page \(page).")], nextCursor: try ConnectorCursor(family: "page", value: page + 1), reachedEnd: page == 2)
    }
    func fetchContent(candidate: ConnectorItemCandidate, context _: ConnectorContext) async throws -> ConnectorItemCandidate { candidate }
    func healthCheck(accountID _: ConnectorAccountID?) async -> ConnectorHealth { .healthy }
    func disconnect(accountID _: ConnectorAccountID) async throws {}
    func requestedPages() -> [Int] { starts }
}

@Test func paginatedRefreshRestartsAtNewestPageAfterCompletingPriorListing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentPaginationReview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = CrosscurrentRepository(database: try .open(at: .init(container: root), role: .mainApp))
    let endpoint = try await reliabilitySource(repository, connector: .github)
    let connector = PaginatedRefreshFixture()
    let registry = ConnectorRegistry()
    await registry.register(connector)
    let executor = RefreshJobExecutor(repository: repository, connectors: registry)
    for _ in 0..<2 {
        let payload = try JSONEncoder().encode(RefreshJobPayload(endpointID: endpoint.id))
        let job = try await repository.scheduleRefreshJob(endpointID: endpoint.id, payload: payload, manual: true)
        let (_, lease) = try #require(try await repository.leaseJob(id: job.id, owner: "fixture"))
        let result = try await executor.execute(job: job, lease: lease)
        #expect(result.pages == 2 && result.candidates == 2)
        _ = try await repository.completeJob(lease)
    }
    #expect(await connector.requestedPages() == [1, 2, 1, 2])
    #expect(try await repository.syncCursor(endpointID: endpoint.id) == nil)
}
