import CrosscurrentDomain
import CrosscurrentConnectors
import CrosscurrentIngestion
import CrosscurrentIntelligence
import CrosscurrentRanking
import CrosscurrentSearch
import CrosscurrentStorage
import Foundation
import Testing

private struct DiscoveryHTTPClient: ConnectorHTTPClient {
    let feedURL = URL(string: "https://example.com/feed.xml")!

    func get(_ url: URL, headers _: [String: String]) async throws -> ConnectorHTTPResponse {
        let xml = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Real Preview</title><link>https://example.com</link><description>Preview only</description>
        <item><guid>preview-1</guid><title>Preview Item</title><link>https://example.com/item</link><description>Evidence sample</description></item>
        </channel></rss>
        """
        return ConnectorHTTPResponse(data: Data(xml.utf8), statusCode: 200, headers: ["Content-Type": "application/rss+xml"], finalURL: url)
    }
}

private actor ConditionalHTTPClient: ConnectorHTTPClient {
    private var calls = 0
    private(set) var secondRequestHeaders: [String: String] = [:]

    func get(_ url: URL, headers: [String: String]) async throws -> ConnectorHTTPResponse {
        calls += 1
        if calls == 1 {
            return ConnectorHTTPResponse(data: Data("stable-body".utf8), statusCode: 200, headers: ["ETag": "\"revision-1\"", "Content-Type": "text/plain"], finalURL: url)
        }
        secondRequestHeaders = headers
        return ConnectorHTTPResponse(data: Data(), statusCode: 304, headers: [:], finalURL: url)
    }
}

@Test
func sourceDiscoveryPreviewDoesNotPersistUntilExplicitCommit() async throws {
    let (repository, _) = try makeRepository()
    let http = DiscoveryHTTPClient()
    let registry = ConnectorRegistry()
    await registry.register(FeedConnector(http: http))
    let discovery = SourceDiscoveryService(repository: repository, connectors: registry, http: http)

    let preview = try await discovery.preview(.init(url: http.feedURL), context: ConnectorContext())
    #expect(preview.result.sourceRevision.displayName == "Real Preview")
    #expect(try await repository.sourceSnapshots().isEmpty)

    _ = try await discovery.commit(preview, action: .subscribe)
    #expect(try await repository.sourceSnapshots().count == 1)
    #expect(try await repository.qualificationEvidenceRecords().count == 1)
}

@Test
func archivedHTTPUsesPersistentValidatorsAndRehydratesNotModifiedResponses() async throws {
    let (repository, locations) = try makeRepository()
    let upstream = ConditionalHTTPClient()
    let client = ArchivingConnectorHTTPClient(
        upstream: upstream,
        repository: repository,
        blobStore: CanonicalBlobStore(locations: locations, repository: repository)
    )
    let url = URL(string: "https://example.com/conditional")!
    let first = try await client.get(url, headers: [:])
    let second = try await client.get(url, headers: [:])
    #expect(first.data == second.data)
    #expect(second.statusCode == 200)
    #expect(await upstream.secondRequestHeaders["If-None-Match"] == "\"revision-1\"")
}

@Test
func canonicalEvidenceBecomesEventTodayAndCurrentSearchWithoutAProvider() async throws {
    let (repository, locations) = try makeRepository()
    let sourceID = SourceID()
    let endpointID = SourceEndpointID()
    try await seedSource(repository, sourceID: sourceID, endpointID: endpointID, name: "上海开发者观察")
    _ = try await seedItem(
        repository,
        sourceID: sourceID,
        endpointID: endpointID,
        externalID: "local-model",
        title: "上海发布本地模型开发者支持计划",
        text: "新计划支持本地模型、无障碍技术和公共数据工具，并要求申请团队提交可以复现的评估结果。"
    )

    let maintenance = try await EvidenceEventMaintainer(repository: repository).run()
    #expect(maintenance.eventsCreated == 1)
    let snapshots = try await repository.currentEventSnapshots()
    #expect(snapshots.count == 1)
    #expect(snapshots[0].aggregate.revision.primaryMembershipAssertionID != nil)
    #expect(snapshots[0].readStatus == .unread)

    let today = TodayCoordinator(repository: repository)
    let initial = try #require(try await today.update(trigger: .opening, now: Date(timeIntervalSince1970: 1_787_094_000)))
    #expect(initial.revision.reason == .initialDaily)
    #expect(initial.revision.parentRevisionID == nil)
    let openingAgain = try #require(try await today.update(trigger: .opening, now: Date(timeIntervalSince1970: 1_787_094_300)))
    #expect(openingAgain.created == false)
    #expect(openingAgain.revision.id == initial.revision.id)
    let manual = try #require(try await today.update(trigger: .manualRefresh, now: Date(timeIntervalSince1970: 1_787_094_600)))
    #expect(manual.revision.reason == .manualRefresh)
    #expect(manual.revision.parentRevisionID == initial.revision.id)

    let index = try DerivedIndexCoordinator(repository: repository, directory: locations.derivedSearch)
    _ = try await index.synchronize(force: true)
    let results = try await index.store.search(SearchQuery(text: "上海", includeHistory: false))
    #expect(results.contains { $0.kind == .event && !$0.isHistorical })
}

@Test
func manualMergeAndSplitKeepHistoryAndCreateDurableConstraints() async throws {
    let (repository, _) = try makeRepository()
    let sourceID = SourceID()
    let endpointID = SourceEndpointID()
    try await seedSource(repository, sourceID: sourceID, endpointID: endpointID, name: "Independent Desk")
    _ = try await seedItem(repository, sourceID: sourceID, endpointID: endpointID, externalID: "alpha", title: "Orbital telescope publishes infrared atlas", text: "The observatory released a calibrated infrared atlas with reproducible source measurements and archival data products.")
    _ = try await seedItem(repository, sourceID: sourceID, endpointID: endpointID, externalID: "beta", title: "Regional rail authority opens new night service", text: "The transport authority opened a night rail service after completing safety trials and publishing the operating timetable.")
    _ = try await EvidenceEventMaintainer(repository: repository).run()
    let before = try await repository.currentEventAggregates()
    #expect(before.count == 2)

    let corrections = ManualEventCorrectionService(repository: repository)
    let survivor = try await corrections.merge(eventIDs: Set(before.map(\.event.id)))
    let merged = try await repository.currentEventAggregates()
    #expect(merged.count == 1)
    #expect(merged[0].event.id == survivor)
    #expect(merged[0].memberships.count == 2)
    let losingID = try #require(before.map(\.event.id).first { $0 != survivor })
    let explicitHistory = try await repository.searchDocuments(includeHistory: true)
    #expect(explicitHistory.contains { $0.kind == "event" && $0.stableID == losingID.description && $0.isHistorical })

    let splitIDs = try await corrections.split(eventID: survivor, movingLineageID: merged[0].memberships[0].segmentLineageID)
    #expect(Set(splitIDs).count == 2)
    #expect(try await repository.currentEventAggregates().count == 2)
    let constraints = try await repository.activeConstraints()
    #expect(constraints.contains { $0.kind == .mustLink })
    #expect(constraints.contains { $0.kind == .cannotLink })
    #expect(constraints.contains { $0.kind == .confirmedMembership })
}

@Test
func ingestionCreatesStableRevisionsSanitizedEvidenceTopicsAndMetrics() async throws {
    let (repository, locations) = try makeRepository()
    let sourceID = SourceID()
    let endpointID = SourceEndpointID()
    try await seedSource(repository, sourceID: sourceID, endpointID: endpointID, name: "Revision Monitor")
    let blobStore = CanonicalBlobStore(locations: locations, repository: repository)
    let pipeline = IngestionPipeline(repository: repository, blobStore: blobStore)
    let first = ConnectorItemCandidate(
        externalID: "stable-page",
        canonicalURL: URL(string: "https://example.com/stable-page?utm_source=test"),
        title: "稳定页面发布更新",
        contentHTML: "<article><h1>稳定页面发布更新</h1><script>alert('unsafe')</script><p>第一版正文</p></article>",
        contentText: "第一版正文",
        languageCode: "zh-Hans",
        topicNames: ["本地模型"],
        metricSnapshots: [ConnectorMetric(kind: .views, value: 42, capturedAt: Date(timeIntervalSince1970: 3_000))]
    )
    let initial = try await pipeline.ingest(candidate: first, sourceID: sourceID, endpointID: endpointID)
    #expect(initial.createdRevision)
    #expect(initial.revision?.ordinal == 1)
    #expect(initial.metricsWritten == 1)
    #expect(initial.revision?.sanitizedHTML?.contains("<script") == false)
    #expect(try await repository.topicSnapshots().map(\.revision.name).contains("本地模型"))

    let unchanged = try await pipeline.ingest(candidate: first, sourceID: sourceID, endpointID: endpointID)
    #expect(unchanged.item.id == initial.item.id)
    #expect(unchanged.createdRevision == false)
    #expect(unchanged.revision == nil)

    var edited = first
    edited.contentText = "第二版正文，包含可验证的新发展。"
    edited.contentHTML = "<article><h1>稳定页面发布更新</h1><p>第二版正文，包含可验证的新发展。</p></article>"
    edited.modifiedAt = Date(timeIntervalSince1970: 3_600)
    let revision = try await pipeline.ingest(candidate: edited, sourceID: sourceID, endpointID: endpointID)
    #expect(revision.item.id == initial.item.id)
    #expect(revision.createdRevision)
    #expect(revision.revision?.ordinal == 2)
    #expect(revision.revision?.changeKind == .contentUpdate)
}

@Test
func providerFreeEnrichmentAndDeduplicationFeedCanonicalClusteringSignals() async throws {
    let (repository, _) = try makeRepository()
    let firstSource = SourceID()
    let firstEndpoint = SourceEndpointID()
    let secondSource = SourceID()
    let secondEndpoint = SourceEndpointID()
    try await seedSource(repository, sourceID: firstSource, endpointID: firstEndpoint, name: "Official Systems Lab")
    try await seedSource(repository, sourceID: secondSource, endpointID: secondEndpoint, name: "Syndication Mirror")
    let pipeline = IngestionPipeline(repository: repository)
    let candidate = ConnectorItemCandidate(
        externalID: "release-42",
        canonicalURL: URL(string: "https://systems.example/releases/42"),
        title: "Ari Chen releases deterministic index format",
        author: "Ari Chen",
        contentText: "Ari Chen released a deterministic index format with exact revision provenance.",
        languageCode: "en",
        topicNames: ["Search Infrastructure"]
    )
    _ = try await pipeline.ingest(candidate: candidate, sourceID: firstSource, endpointID: firstEndpoint)
    var mirror = candidate
    mirror.externalID = "mirror-release-42"
    _ = try await pipeline.ingest(candidate: mirror, sourceID: secondSource, endpointID: secondEndpoint)

    let entities = try await repository.entitySnapshots()
    #expect(entities.contains { $0.revision.displayName == "Ari Chen" })
    #expect(entities.contains { $0.revision.displayName == "systems.example" })
    let beforeDeduplication = try await repository.pendingEvidenceSegments()
    #expect(beforeDeduplication.allSatisfy { !$0.entityIDs.isEmpty && !$0.topicIDs.isEmpty })

    let result = try await EvidenceDeduplicationService(repository: repository).run()
    #expect(result.pairsClassified == 1)
    #expect(result.duplicateFamiliesUpdated == 1)
    let generationAfterFirstRun = try await repository.generations()[.events]?.generation
    let repeated = try await EvidenceDeduplicationService(repository: repository).run()
    #expect(repeated.pairsClassified == 0)
    #expect(try await repository.generations()[.events]?.generation == generationAfterFirstRun)
    let afterDeduplication = try await repository.pendingEvidenceSegments()
    #expect(Set(afterDeduplication.map(\.independenceGroup)).count == 1)
}

@Test
func opmlExportPreservesFoldersAndRedactsSecretLikeAttributes() async throws {
    let (repository, _) = try makeRepository()
    let sourceID = SourceID()
    let endpointID = SourceEndpointID()
    try await seedSource(repository, sourceID: sourceID, endpointID: endpointID, name: "Exported Source")
    let folderID = try await repository.ensureSourceFolder(
        name: "Engineering",
        pathKey: "Engineering",
        parentID: nil,
        attributes: ["category": "systems", "privateToken": "must-not-export"],
        sortOrder: 0
    )
    _ = try await repository.assignSource(sourceID, toFolder: folderID, sortOrder: 0)

    let data = try await OPMLExportService(repository: repository).exportData(createdAt: Date(timeIntervalSince1970: 1_000))
    let xml = try #require(String(data: data, encoding: .utf8))
    #expect(xml.contains("Engineering"))
    #expect(xml.contains("category=\"systems\""))
    #expect(!xml.contains("must-not-export"))
    let outlines = try OPMLParser().parse(data: data)
    #expect(outlines.first?.children.first?.title == "Exported Source")
}

@Test
func primarySourceScoringPromotesDirectArtifactsAndPersistsReasonTrace() async throws {
    let (repository, _) = try makeRepository()
    let commentarySource = SourceID()
    let commentaryEndpoint = SourceEndpointID()
    let repositorySource = SourceID()
    let repositoryEndpoint = SourceEndpointID()
    try await seedSource(repository, sourceID: commentarySource, endpointID: commentaryEndpoint, name: "Secondary Commentary")
    let repositoryRevision = SourceRevision(sourceID: repositorySource, displayName: "Official Repository")
    _ = try await repository.saveSource(
        LogicalSource(id: repositorySource, currentRevisionID: repositoryRevision.id, kind: .repository),
        revision: repositoryRevision,
        endpoints: [SourceEndpoint(id: repositoryEndpoint, sourceID: repositorySource, connector: .github, externalID: "org/tool", canonicalURL: URL(string: "https://github.com/org/tool"), accessRequirement: .anonymous, contentPrivacy: .public)]
    )
    let pipeline = IngestionPipeline(repository: repository)
    let text = "The project released version 4 with deterministic archives, signed manifests, and migration notes for existing users."
    _ = try await pipeline.ingest(
        candidate: ConnectorItemCandidate(externalID: "commentary", canonicalURL: URL(string: "https://example.com/version-4"), title: "Project releases version 4", publishedAt: Date(timeIntervalSince1970: 100), contentText: text, languageCode: "en"),
        sourceID: commentarySource,
        endpointID: commentaryEndpoint
    )
    _ = try await pipeline.ingest(
        candidate: ConnectorItemCandidate(externalID: "release-4", canonicalURL: URL(string: "https://github.com/org/tool/releases/tag/v4"), title: "Project releases version 4", publishedAt: Date(timeIntervalSince1970: 200), contentText: text, languageCode: "en"),
        sourceID: repositorySource,
        endpointID: repositoryEndpoint
    )

    _ = try await EvidenceEventMaintainer(repository: repository).run()
    let event = try #require(try await repository.currentEventSnapshots().first)
    #expect(event.primarySourceName == "Official Repository")
    #expect(event.aggregate.revision.primaryReasonTrace.contains("official repository artifact"))
}

private func makeRepository() throws -> (CrosscurrentRepository, DatabaseLocations) {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentPipelineTests-\(UUID().uuidString)")
    let locations = DatabaseLocations(container: root)
    let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
    return (CrosscurrentRepository(database: database, writerInstance: "pipeline-tests"), locations)
}

private func seedSource(_ repository: CrosscurrentRepository, sourceID: SourceID, endpointID: SourceEndpointID, name: String) async throws {
    let revision = SourceRevision(sourceID: sourceID, displayName: name)
    let source = LogicalSource(id: sourceID, currentRevisionID: revision.id, kind: .publication)
    let endpoint = SourceEndpoint(id: endpointID, sourceID: sourceID, connector: .website, externalID: name, canonicalURL: URL(string: "https://example.com/\(endpointID)"), accessRequirement: .anonymous, contentPrivacy: .public)
    _ = try await repository.saveSource(
        source,
        revision: revision,
        endpoints: [endpoint],
        aiClassification: SourceAIClassification(sourceID: sourceID, accessRequirement: .anonymous, contentPrivacy: .public, provenance: .user, confidence: .certain),
        coverage: SourceCoverageAssertion(sourceID: sourceID, ecosystem: .unknown, provenance: .user, confidence: .certain)
    )
}

@discardableResult
private func seedItem(_ repository: CrosscurrentRepository, sourceID: SourceID, endpointID: SourceEndpointID, externalID: String, title: String, text: String) async throws -> Item {
    let itemID = ItemID()
    let revisionID = ItemRevisionID()
    let item = Item(id: itemID, sourceID: sourceID, sourceEndpointID: endpointID, externalID: externalID, canonicalURL: URL(string: "https://example.com/\(externalID)"), currentRevisionID: revisionID)
    let revision = ItemRevision(id: revisionID, itemID: itemID, title: title, fetchedAt: .now, languageCode: title.contains("上海") ? "zh-Hans" : "en", text: text, contentHash: "\(externalID)-hash")
    _ = try await repository.saveItem(item, revision: revision, segments: ItemSegmenter.segments(for: revision))
    return item
}
