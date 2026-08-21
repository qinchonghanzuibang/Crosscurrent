import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentIntelligence
import CrosscurrentModels
import CrosscurrentRanking
import CrosscurrentSearch
import CrosscurrentStorage
import Foundation
import Testing

@Test func everyAITaskHasABundledVersionedPrompt() {
    #expect(Set(BundledPromptCatalog.all.map(\.template.task)) == Set(AITask.allCases))
    #expect(BundledPromptCatalog.all.allSatisfy { $0.revision.origin == .bundled })
}

@Test func ordinaryPageEditsPreserveSegmentLineageButReplacementDoesNot() {
    let oldRevision = ItemRevision(itemID: ItemID(), title: "Monitored page", text: "A monitored paragraph contains durable evidence for readers.", contentHash: "old")
    let old = ItemSegmenter.segments(for: oldRevision)
    let editedRevision = ItemRevision(itemID: oldRevision.itemID, title: "Monitored page", text: "A monitored paragraph contains durable evidence for careful readers.", contentHash: "edited")
    let edited = ItemSegmenter.segments(for: editedRevision, aligningWith: old)
    #expect(edited.first?.lineageID == old.first?.lineageID)

    let replacementRevision = ItemRevision(itemID: oldRevision.itemID, title: "Monitored page", text: "Completely unrelated replacement about marine biology and coral spawning.", contentHash: "replacement")
    let replacement = ItemSegmenter.segments(for: replacementRevision, aligningWith: old)
    #expect(replacement.first?.lineageID != old.first?.lineageID)
}

@Test func shareInboxUsesAnAtomicLeaseAndTreatsCapturedSelectionAsUnknownPrivacy() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentShareInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
    let repository = CrosscurrentRepository(database: database, writerInstance: "share-test")
    let record = ShareInboxRecord(
        url: try #require(URL(string: "https://example.com/private/article")),
        title: "Captured article",
        selectedText: "A user-selected passage that must stay local until classified."
    )
    let recordURL = locations.shareInbox.appending(path: "\(record.id.uuidString.lowercased()).json")
    try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    let importer = ShareInboxImporter(locations: locations, repository: repository, leaseOwner: "test")
    let batch = try await importer.importAvailable()
    #expect(batch.importedRecords == 1)
    #expect(batch.importedItemRevisions == 1)
    #expect(FileManager.default.fileExists(atPath: recordURL.path) == false)
    #expect(try await repository.generations()[.items]?.generation == 1)
}

@Test func revisionReadStateDistinguishesUpdates() {
    let old = EventRevisionID()
    let current = EventRevisionID()
    let state = EventReadState(lastSeenRevisionID: old, lastSeenOrdinal: 1)
    #expect(state.status(currentRevisionID: current, currentOrdinal: 2) == .updated)
}

@Test func authenticatedPublicIsNotTreatedAsPrivate() {
    let sourceID = SourceID()
    let classification = SourceAIClassification(sourceID: sourceID, accessRequirement: .authenticated, contentPrivacy: .public, provenance: .connector, confidence: .certain)
    let policy = AIContentPolicy(publicCloudProviders: ["allowed"])
    #expect(classification.accessRequirement == .authenticated)
    #expect(classification.contentPrivacy == .public)
    #expect(policy.allows(sourceID: sourceID, privacy: classification.contentPrivacy, providerID: "allowed", location: .cloud))
}

@Test func splitIdentityUsesWeightedOverlapNotPrimaryItem() {
    let oldEvent = EventID()
    let first = SegmentLineageID()
    let second = SegmentLineageID()
    let third = SegmentLineageID()
    let prior = [
        PriorMembershipWeight(assertionID: MembershipAssertionID(), segmentLineageID: first, weight: 0.2),
        PriorMembershipWeight(assertionID: MembershipAssertionID(), segmentLineageID: second, weight: 0.8),
        PriorMembershipWeight(assertionID: MembershipAssertionID(), segmentLineageID: third, weight: 0.7),
    ]
    let resolution = EventIdentityResolver.resolveSplit(
        oldEventID: oldEvent,
        prior: prior,
        partitions: [
            EventSplitPartition(newEventID: EventID(), retainedLineages: [first]),
            EventSplitPartition(newEventID: EventID(), retainedLineages: [second, third]),
        ]
    )
    #expect(resolution.retainingPartitionIndex == 1)
    #expect(resolution.eventIDsByPartition[1] == oldEvent)
}

@Test func userConstraintCannotBeUndoneByHigherModelScore() {
    let segment = SegmentLineageID()
    let rejectedEvent = EventID()
    let acceptedEvent = EventID()
    let scores = [
        EventCandidateScore(eventID: rejectedEvent, semantic: 1, entityOverlap: 1, topicOverlap: 1, temporal: 1, title: 1, citation: 1, independence: 1, coherence: 1),
        EventCandidateScore(eventID: acceptedEvent, semantic: 0.9, entityOverlap: 0.9, topicOverlap: 0.9, temporal: 0.9, title: 0.9, citation: 0.9, independence: 0.9, coherence: 0.9),
    ]
    let constraint = ClusteringConstraint(kind: .rejectedMembership, leftLineageID: segment, eventID: rejectedEvent)
    let assignment = DeterministicClusteringEngine.assign(segmentLineageID: segment, candidates: scores, constraints: [constraint])
    #expect(assignment.eventIDs == [acceptedEvent])
}

@Test func todayHasOneInitialAndMaterialChildrenOnly() {
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let schedule = BriefingSchedule(dailyTime: BriefingTime(hour: 9, minute: 30))
    let empty = TodayState(briefingDay: day)
    #expect(TodayPlanner.decision(trigger: .opening, state: empty, schedule: schedule) == .create(reason: .initialDaily, parent: nil))

    let initial = DigestRevisionID()
    let current = TodayState(briefingDay: day, initialRevisionID: initial, latestRevisionID: initial)
    let minor = EventChangeMateriality(changeKind: .minorMetadata, importance: 1, evidenceGrowth: 10)
    #expect(TodayPlanner.decision(trigger: .eventChanged(minor), state: current, schedule: schedule) == .noRevision)
    #expect(TodayPlanner.decision(trigger: .scheduled(BriefingTime(hour: 12, minute: 0)), state: current, schedule: schedule) == .noRevision)
    #expect(TodayPlanner.decision(trigger: .manualRefresh, state: current, schedule: schedule) == .create(reason: .manualRefresh, parent: initial))
}

@Test func chinaGlobalRequiresTwoIndependentGroupsOnEachSide() {
    let evidence = [
        CoverageEvidence(ecosystem: .chinaFocused, independenceGroup: "cn-1"),
        CoverageEvidence(ecosystem: .chinaFocused, independenceGroup: "cn-2"),
        CoverageEvidence(ecosystem: .globalFocused, independenceGroup: "global-1"),
        CoverageEvidence(ecosystem: .globalFocused, independenceGroup: "global-2"),
        CoverageEvidence(ecosystem: .mixed, independenceGroup: "mixed"),
    ]
    #expect(ChinaGlobalCoverageGate.isSufficient(evidence))
    #expect(ChinaGlobalCoverageGate.isSufficient(Array(evidence.dropLast(2))) == false)
}

@Test func shortChineseQueriesUseExplicitIndexesAndHistoryIsOptIn() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentSearchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DerivedSearchStore(directory: root)
    try await store.index(SearchDocument(stableID: "event-1", kind: .event, revisionID: "r2", languageCode: "zh-Hans", title: "人工智能产业更新", body: "北京发布人工智能产业政策。"))
    try await store.index(SearchDocument(stableID: "event-1", kind: .event, revisionID: "r1", languageCode: "zh-Hans", title: "旧人工智能标题", body: "历史内容。", isHistorical: true))
    #expect(try await store.search(SearchQuery(text: "智")).first?.stableID == "event-1")
    #expect(try await store.search(SearchQuery(text: "智能")).first?.revisionID == "r2")
    #expect(try await store.search(SearchQuery(text: "旧", includeHistory: false)).isEmpty)
    #expect(try await store.search(SearchQuery(text: "旧", includeHistory: true)).contains(where: \.isHistorical))
}

@Test func vectorNamespacesUseDynamicDescriptorsAndPersistOutsideCanonicalStorage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentVectorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let descriptor = EmbeddingDescriptor(runtimeID: "fixture", modelID: "bilingual-test", modelRevision: "1", dimension: 3, scalarType: .float32, pooling: "mean", normalization: "l2")
    let index = try USearchVectorIndex(rootDirectory: root, descriptor: descriptor)
    try await index.upsert(ids: ["alpha", "beta"], vectors: [[1, 0, 0], [0, 1, 0]])
    #expect(try await index.search(vector: [0.99, 0.01, 0], limit: 2).first?.id == "alpha")
    try await index.persist()

    let reopened = try USearchVectorIndex(rootDirectory: root, descriptor: descriptor)
    #expect(try await reopened.search(vector: [0, 1, 0], limit: 1).first?.id == "beta")
}
