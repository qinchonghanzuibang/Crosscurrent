import CrosscurrentDomain
import CrosscurrentConnectors
import CrosscurrentIngestion
import CrosscurrentIntelligence
import CrosscurrentRanking
import CrosscurrentSearch
import CrosscurrentStorage
import Foundation
import Testing

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
