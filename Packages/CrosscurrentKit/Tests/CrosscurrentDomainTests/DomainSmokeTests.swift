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

@Test func readerEscapeClosesInsightsBeforeLeavingFocusMode() {
    let insight = ReaderInsightsState(kind: .summary, title: "Summary", phase: .ready, body: "Concise result")
    var state = ReaderExperienceState(isFocusReading: true, insights: insight)
    #expect(state.handleEscape() == .closedInsights)
    #expect(state.insights == nil)
    #expect(state.isFocusReading)
    #expect(state.handleEscape() == .exitedFocus)
    #expect(state.isFocusReading == false)
    #expect(state.handleEscape() == .navigateBack)
}

@Test func providerFreeReaderInsightsStayBoundedAndStructured() {
    let article = """
    The research team released a bilingual retrieval model with reproducible evaluation code. Independent tests found that it improved Chinese-to-English recall without increasing the index dimension. The report shows that batching reduced refresh time while preserving ranking quality. However, the authors found that very long inputs still require careful truncation. A follow-up benchmark compared the model with two compact baselines on older Apple silicon. The results show lower memory use during routine indexing. The team published the tokenizer configuration and checksums for independent verification. Therefore, adopters can reproduce the measured tradeoffs before selecting a runtime.
    """
    let evidence = [ReaderEvidenceExcerpt(text: article, citation: "Primary · E1", isPrimary: true)]
    let summary = ReaderExtractiveInsights.summary(from: evidence, fallback: article)
    let points = ReaderExtractiveInsights.keyPoints(from: evidence, fallback: article)
    #expect((1...3).contains(summary.count))
    #expect(summary.map(\.text).joined(separator: " ").count <= 720)
    #expect(points.count == 8)
    #expect(points.allSatisfy { $0.citation == "Primary · E1" })
    #expect(ReaderExtractiveInsights.validatedSummary(article) == nil)
    #expect(ReaderExtractiveInsights.validatedKeyPoints(points.map { "• \($0.text)" }.joined(separator: "\n"))?.count == 8)

    let initials = ReaderExtractiveInsights.summary(
        from: [ReaderEvidenceExcerpt(text: "The concept dates back to I. J. Good (1965), who defined an ultratelligent machine. Modern systems extend that idea with measurable evaluations.", citation: "E1", isPrimary: true)],
        fallback: ""
    )
    #expect(initials.first?.text.contains("I. J. Good (1965)") == true)
    #expect(initials.contains { $0.text.hasSuffix("I.") } == false)
}

@Test func aiEndpointsRequireHTTPSExceptForLoopbackServices() throws {
    try AIEndpointSecurity.validate(#require(URL(string: "https://api.example.com/v1/messages")))
    try AIEndpointSecurity.validate(#require(URL(string: "http://127.0.0.1:11434/api/chat")))
    try AIEndpointSecurity.validate(#require(URL(string: "http://localhost:8080/v1/chat/completions")))
    #expect(throws: AIProviderError.insecureEndpoint) {
        try AIEndpointSecurity.validate(#require(URL(string: "http://api.example.com/v1/messages")))
    }
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

private actor FixtureEmbeddingRuntime: EmbeddingRuntime {
    let descriptor = EmbeddingDescriptor(runtimeID: "fixture-runtime", modelID: "fixture-model", modelRevision: "1", dimension: 3, scalarType: .float32, pooling: "fixture", normalization: "l2")
    private var fails = false
    private var maximumBatchSize = 0
    private var onNextEmbedding: (@Sendable () async throws -> Void)?

    func setFails(_ value: Bool) { fails = value }
    func beforeNextEmbedding(_ operation: @escaping @Sendable () async throws -> Void) { onNextEmbedding = operation }
    func observedMaximumBatchSize() -> Int { maximumBatchSize }
    func embed(_ texts: [String], kind _: EmbeddingInputKind) async throws -> [[Float]] {
        if fails { throw CocoaError(.fileReadCorruptFile) }
        if let operation = onNextEmbedding {
            onNextEmbedding = nil
            try await operation()
        }
        maximumBatchSize = max(maximumBatchSize, texts.count)
        return texts.map { text in
            let value = text.lowercased()
            if value.contains("beta") { return [0, 1, 0] }
            if value.contains("alpha") { return [1, 0, 0] }
            return [0, 0, 1]
        }
    }
    func resourceEstimate(batchSize: Int) -> EmbeddingResourceEstimate {
        EmbeddingResourceEstimate(peakBytes: Int64(batchSize * 12), seconds: 0)
    }
}

@Test func semanticRebuildSwitchesOnlyAfterTheCompleteNamespacePersists() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentSemanticCoordinatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
    let repository = CrosscurrentRepository(database: database, writerInstance: "semantic-test")
    let sourceRevision = SourceRevision(sourceID: SourceID(), displayName: "Fixture Source")
    let source = LogicalSource(id: sourceRevision.sourceID, currentRevisionID: sourceRevision.id, kind: .publication)
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .rss, externalID: "fixture")
    _ = try await repository.saveSource(source, revision: sourceRevision, endpoints: [endpoint])

    let itemRevision = ItemRevision(itemID: ItemID(), title: "Beta release", text: "Beta runtime evidence", contentHash: "beta")
    let item = Item(id: itemRevision.itemID, sourceID: source.id, sourceEndpointID: endpoint.id, externalID: "beta", currentRevisionID: itemRevision.id)
    let segment = ItemSegment(itemRevisionID: itemRevision.id, kind: .whole, span: TextSpan(utf8Start: 0, utf8Length: itemRevision.text.utf8.count, excerptHash: "beta"), text: itemRevision.text, contentHash: "beta")
    _ = try await repository.saveItem(item, revision: itemRevision, segments: [segment])

    let runtime = FixtureEmbeddingRuntime()
    let coordinator = SemanticIndexCoordinator(repository: repository, runtime: runtime, rootDirectory: locations.derivedSearch.appending(path: "Semantic"))
    let update = try await coordinator.rebuild(batchSize: 1)
    #expect(update.documentCount >= 2)
    #expect(await runtime.observedMaximumBatchSize() == 1)
    #expect(try await coordinator.search("beta", limit: 1).first?.id == "item:\(item.id.description)")
    let manifestURL = locations.derivedSearch.appending(path: "Semantic/active-vector-namespace.json")
    let activeBeforeFailure = try Data(contentsOf: manifestURL)

    await runtime.setFails(true)
    let reused = try await coordinator.activateOrRebuild(batchSize: 1)
    #expect(reused.documentCount == update.documentCount)
    await #expect(throws: (any Error).self) { try await coordinator.rebuild() }
    #expect(try Data(contentsOf: manifestURL) == activeBeforeFailure)

    await runtime.setFails(false)
    await runtime.beforeNextEmbedding {
        let revision = SourceRevision(sourceID: SourceID(), displayName: "New during embedding")
        _ = try await repository.saveSource(LogicalSource(id: revision.sourceID, currentRevisionID: revision.id, kind: .publication), revision: revision)
    }
    let stale = try await coordinator.rebuild()
    #expect(stale.canonicalGeneration < (try await repository.generations()[.searchInputs]?.generation ?? 0))
    let refreshed = try await coordinator.activateOrRebuild()
    #expect(refreshed.documentCount == stale.documentCount + 1)
    #expect(refreshed.canonicalGeneration == (try await repository.generations()[.searchInputs]?.generation ?? 0))
}

@Test func searchRanksTitleMatchesAndFiltersKindsBeforeLimiting() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentSearchRelevance-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try DerivedSearchStore(directory: root)
    var documents = (0..<80).map { index in
        SearchDocument(stableID: "filler-\(index)", kind: .event, title: "Other material \(index)", body: "Unrelated background")
    }
    documents += [
        SearchDocument(stableID: "title", kind: .event, title: "Needle", body: "Other background material"),
        SearchDocument(stableID: "body", kind: .event, title: "A background", body: "Other material needle"),
    ]
    try await store.synchronize(documents, canonicalGeneration: 1)
    #expect(try await store.search(SearchQuery(text: "needle")).first?.stableID == "title")
    documents = (0..<220).map { index in
        SearchDocument(stableID: "event-\(index)", kind: .event, title: "Needle 智能", body: "matching evidence")
    }
    documents.append(SearchDocument(stableID: "source", kind: .source, title: "Needle 智能", body: "matching evidence"))
    try await store.synchronize(documents, canonicalGeneration: 2)
    for query in ["needle", "智能"] {
        #expect(try await store.search(SearchQuery(text: query, kinds: [.source], limit: 1)).map(\.stableID) == ["source"])
    }
}

@Test func pairwiseClusteringConstraintsApplyFromEitherSide() {
    let left = SegmentLineageID(), right = SegmentLineageID(), eventID = EventID()
    let candidate = EventCandidateScore(eventID: eventID, semantic: 1, entityOverlap: 1, topicOverlap: 1, temporal: 1, title: 1, citation: 1, independence: 1, coherence: 1, memberLineages: [left])
    let forbidden = ClusteringConstraint(kind: .cannotLink, leftLineageID: left, rightLineageID: right)
    #expect(DeterministicClusteringEngine.assign(segmentLineageID: right, candidates: [candidate], constraints: [forbidden]).eventIDs.isEmpty)
    var lowScore = candidate
    lowScore.semantic = 0
    let required = ClusteringConstraint(kind: .mustLink, leftLineageID: left, rightLineageID: right)
    let assignment = DeterministicClusteringEngine.assign(segmentLineageID: right, candidates: [lowScore], constraints: [required])
    #expect(assignment.eventIDs == [eventID] && assignment.wasForcedByUser)
}

@Test func hybridSearchUsesRankAndKeepsKindsAndRevisionsDistinct() {
    func result(_ stableID: String, kind: SearchDocumentKind = .event, revision: String = "current", score: Double, semantic: Bool = false) -> SearchResult {
        SearchResult(stableID: stableID, kind: kind, revisionID: revision, title: stableID, snippet: "Evidence", score: score, isHistorical: revision == "older", matchReasons: semantic ? [.semantic] : [.lexical])
    }
    let lexical = [result("title", score: 100), result("both", score: 0.0001), result("both", kind: .item, score: 0.00001)]
    let semantic = [result("both", score: 0.99, semantic: true), result("related", score: 0.98, semantic: true), result("both", revision: "older", score: 0.97, semantic: true)]
    let fused = ReciprocalRankFusion.fuse(lexical: lexical, semantic: semantic)
    #expect(fused.first?.id == lexical[1].id)
    #expect(fused.first?.matchReasons == [.lexical, .semantic])
    #expect(fused.allSatisfy { $0.score > 0 && $0.score <= 1 })
    #expect(fused.count == 5)
    #expect(fused.first { $0.kind == .item }?.matchReasons == [.lexical])
    #expect(fused.first { $0.revisionID == "older" }?.matchReasons == [.semantic])
    #expect(ReciprocalRankFusion.fuse(lexical: lexical, semantic: []).map(\.id) == lexical.map(\.id))
    #expect(ReciprocalRankFusion.fuse(lexical: lexical + [lexical[1]], semantic: semantic) == fused)
}
