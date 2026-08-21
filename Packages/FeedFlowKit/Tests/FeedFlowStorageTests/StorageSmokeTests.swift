import Foundation
import FeedFlowDomain
import FeedFlowStorage
import GRDB
import Testing

@Test func redactionHappensBeforePersistenceBoundary() throws {
    let input = try #require(URL(string: "https://example.com/news?token=secret&q=safe#private"))
    let result = HTTPMetadataRedactor.redact(
        url: input,
        headers: ["Authorization": "Bearer secret", "Accept": "text/html", "Set-Cookie": "session=x"]
    )
    #expect(result.headers["Authorization"] == "<redacted>")
    #expect(result.headers["Set-Cookie"] == "<redacted>")
    #expect(result.headers["Accept"] == "text/html")
    #expect(result.safeURL.absoluteString.contains("secret") == false)
    #expect(result.safeURL.fragment == nil)
}

@Test func mainAppMigratesAndAgentSharesCanonicalWrites() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowStorageTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let mainDatabase = try FeedFlowDatabase.open(at: locations, role: .mainApp)
    let main = FeedFlowRepository(database: mainDatabase, writerInstance: "main-test")

    let revisionID = SourceRevisionID()
    let source = LogicalSource(currentRevisionID: revisionID, kind: .publication)
    let revision = SourceRevision(id: revisionID, sourceID: source.id, displayName: "Example Daily")
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .rss, externalID: "https://example.com/feed", canonicalURL: URL(string: "https://example.com/feed"), accessRequirement: .anonymous, contentPrivacy: .public)
    #expect(try await main.saveSource(source, revision: revision, endpoints: [endpoint], idempotencyKey: "source-example"))

    let firstGenerations = try await main.generations()
    #expect(firstGenerations[.sources]?.generation == 1)
    #expect(firstGenerations[.endpoints]?.generation == 1)
    #expect(try await main.saveSource(source, revision: revision, endpoints: [endpoint], idempotencyKey: "source-example") == false)
    #expect(try await main.generations()[.sources]?.generation == 1)

    let agentDatabase = try FeedFlowDatabase.open(at: locations, role: .agent)
    let agent = FeedFlowRepository(database: agentDatabase, writerInstance: "agent-test")
    var updatedEndpoint = endpoint
    updatedEndpoint.health = .syncing
    #expect(try await agent.saveEndpoint(updatedEndpoint))
    let observedByMain = try await main.generations()
    #expect(observedByMain[.endpoints]?.generation == 2)
    #expect(observedByMain[.endpoints]?.writerInstance == "agent-test")
}

@Test func durableLeaseExpiresAndCanBeTakenOver() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowLeaseTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try FeedFlowDatabase.open(at: DatabaseLocations(container: root), role: .mainApp)
    let firstWriter = FeedFlowRepository(database: database, writerInstance: "writer-one")
    let secondWriter = FeedFlowRepository(database: database, writerInstance: "writer-two")
    let epoch = Date(timeIntervalSince1970: 1_000)
    let job = DurableJob(kind: "refresh", inputHash: "input", idempotencyKey: "refresh:one", nextAttemptAt: epoch)
    #expect(try await firstWriter.enqueue(job))

    let firstLease = try #require(try await firstWriter.leaseNextJob(owner: "writer-one", eligibleKinds: ["refresh"], duration: 10, now: epoch))
    #expect(firstLease.0.state == .leased)
    #expect(try await secondWriter.leaseNextJob(owner: "writer-two", eligibleKinds: ["refresh"], now: epoch.addingTimeInterval(5)) == nil)

    let takeover = try #require(try await secondWriter.leaseNextJob(owner: "writer-two", eligibleKinds: ["refresh"], now: epoch.addingTimeInterval(11)))
    #expect(takeover.0.id == job.id)
    #expect(takeover.1.owner == "writer-two")
    #expect(try await secondWriter.completeJob(takeover.1))
}

@Test func foregroundLeaseTargetsTheRequestedJob() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowExactLeaseTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try FeedFlowDatabase.open(at: DatabaseLocations(container: root), role: .mainApp)
    let repository = FeedFlowRepository(database: database, writerInstance: "foreground-test")
    let epoch = Date(timeIntervalSince1970: 1_500)
    let older = DurableJob(kind: "refresh", inputHash: "older", idempotencyKey: "refresh:older", nextAttemptAt: epoch)
    let requested = DurableJob(kind: "refresh", inputHash: "requested", idempotencyKey: "refresh:requested", nextAttemptAt: epoch.addingTimeInterval(1))
    #expect(try await repository.enqueue(older))
    #expect(try await repository.enqueue(requested))

    let lease = try #require(try await repository.leaseJob(id: requested.id, owner: "foreground", now: epoch.addingTimeInterval(2)))
    #expect(lease.0.id == requested.id)
    #expect(lease.1.jobID == requested.id)
    let next = try #require(try await repository.leaseNextJob(owner: "agent", eligibleKinds: ["refresh"], now: epoch.addingTimeInterval(2)))
    #expect(next.0.id == older.id)
}

@Test func syncFailurePreservesLastSuccessfulRefresh() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowSyncFailureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try FeedFlowDatabase.open(at: DatabaseLocations(container: root), role: .mainApp)
    let repository = FeedFlowRepository(database: database, writerInstance: "sync-test")
    let revision = SourceRevision(sourceID: SourceID(), displayName: "Authenticated Public Creator")
    let source = LogicalSource(id: revision.sourceID, currentRevisionID: revision.id, kind: .person)
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .xiaohongshu, externalID: "creator", accessRequirement: .authenticated, contentPrivacy: .public)
    _ = try await repository.saveSource(source, revision: revision, endpoints: [endpoint])
    let success = Date(timeIntervalSince1970: 2_000)
    _ = try await repository.finishSync(endpointID: endpoint.id, cursor: nil, itemCount: 12, startedAt: success.addingTimeInterval(-3), completedAt: success)
    _ = try await repository.recordSyncFailure(endpointID: endpoint.id, health: .authenticationRequired, errorClass: "authentication", message: "Reconnect", startedAt: success.addingTimeInterval(60), completedAt: success.addingTimeInterval(62))

    let stored = try #require(try await repository.sourceEndpoint(id: endpoint.id))
    #expect(stored.health == .authenticationRequired)
    #expect(stored.lastSuccessfulSync == success)
}

@Test func aiCacheAndConsentRemainPromptAndPolicyRevisionAware() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowAICacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try FeedFlowDatabase.open(at: DatabaseLocations(container: root), role: .mainApp)
    let repository = FeedFlowRepository(database: database, writerInstance: "ai-cache-test")
    let promptRevisionID = PromptRevisionID()
    let template = PromptTemplate(task: .eventSynthesis, name: "Event synthesis", bundledDefaultRevisionID: promptRevisionID)
    let prompt = PromptRevision(id: promptRevisionID, templateID: template.id, origin: .bundled, body: "Summarize {{evidence}}", variables: ["evidence"])
    _ = try await repository.savePrompt(template: template, revision: prompt)
    let sourceID = SourceID()
    let sourceRevision = SourceRevision(sourceID: sourceID, displayName: "Public Evidence")
    let source = LogicalSource(id: sourceID, currentRevisionID: sourceRevision.id, kind: .publication)
    _ = try await repository.saveSource(source, revision: sourceRevision)
    let consentID = try #require(try await repository.recordConsent(providerID: "cloud", sourceID: sourceID, privacy: .public, allowedTasks: [.eventSynthesis], allowed: true))
    #expect(try await repository.activeConsentRevision(providerID: "cloud", sourceID: sourceID, privacy: .public, task: .eventSynthesis) == consentID)
    #expect(try await repository.activeConsentRevision(providerID: "cloud", sourceID: sourceID, privacy: .public, task: .translation) == nil)

    let run = GenerationRun(task: .eventSynthesis, providerID: "cloud", modelID: "fixture-model", promptRevisionID: promptRevisionID, inputHash: "evidence-hash", policyDecision: "public-consent", consentRevisionID: consentID)
    let completion = StoredAICompletion(text: "Cited synthesis", providerRequestID: "request-1", inputTokens: 20, outputTokens: 5)
    _ = try await repository.saveAICompletion(completion, run: run, cacheKey: "cache:prompt:\(promptRevisionID)")
    #expect(try await repository.cachedAICompletion(cacheKey: "cache:prompt:\(promptRevisionID)") == completion)

    _ = try await repository.recordConsent(providerID: "cloud", sourceID: sourceID, privacy: .public, allowedTasks: [], allowed: false)
    #expect(try await repository.activeConsentRevision(providerID: "cloud", sourceID: sourceID, privacy: .public, task: .eventSynthesis) == nil)
}

@Test func agentRefusesAnUninitializedSchema() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowAgentSchemaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    try FileManager.default.createDirectory(at: locations.canonicalDatabase.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: locations.canonicalDatabase)
    #expect(throws: FeedFlowStorageError.self) {
        _ = try FeedFlowDatabase.open(at: locations, role: .agent)
    }
}

@Test func alreadyRunningAgentRefusesWritesAfterSchemaChanges() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowAgentSchemaPromotionTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let mainDatabase = try FeedFlowDatabase.open(at: locations, role: .mainApp)
    let agentDatabase = try FeedFlowDatabase.open(at: locations, role: .agent)
    let agent = FeedFlowRepository(database: agentDatabase, writerInstance: "old-agent")

    try await mainDatabase.pool.write { db in
        try db.execute(sql: "PRAGMA user_version = \(FeedFlowDatabase.requiredSchemaVersion + 1)")
    }

    await #expect(throws: FeedFlowStorageError.self) {
        _ = try await agent.enqueue(DurableJob(kind: "refresh", inputHash: "old-schema", idempotencyKey: "old-schema", payload: Data()))
    }
}

@Test func contentAddressedBlobUsesQuarantineBeforeDeletion() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowBlobTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    let database = try FeedFlowDatabase.open(at: locations, role: .mainApp)
    let repository = FeedFlowRepository(database: database, writerInstance: "blob-test")
    let store = CanonicalBlobStore(locations: locations, repository: repository)
    let blob = try await store.put(Data("evidence".utf8), mediaType: "text/plain", retentionClass: .durableEvidence)
    #expect(try await store.data(for: blob) == Data("evidence".utf8))

    let collector = BlobGarbageCollector(database: database, quarantineDuration: 60)
    let start = Date(timeIntervalSince1970: 2_000)
    let first = try await collector.run(now: start)
    #expect(first.newlyQuarantined == 1)
    #expect(first.deleted == 0)
    let second = try await collector.run(now: start.addingTimeInterval(61))
    #expect(second.deleted == 1)
}

@Test func policyPurgeRemovesContentWhileRemoteDeletionRetainsEvidence() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "FeedFlowPurgeTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try FeedFlowDatabase.open(at: DatabaseLocations(container: root), role: .mainApp)
    let repository = FeedFlowRepository(database: database, writerInstance: "purge-test")
    let sourceRevision = SourceRevision(sourceID: SourceID(), displayName: "Purge Source")
    let source = LogicalSource(id: sourceRevision.sourceID, currentRevisionID: sourceRevision.id, kind: .publication)
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .website, externalID: "purge", contentPrivacy: .private)
    _ = try await repository.saveSource(source, revision: sourceRevision, endpoints: [endpoint])

    func saveItem(externalID: String, text: String) async throws -> Item {
        let revisionID = ItemRevisionID()
        let item = Item(sourceID: source.id, sourceEndpointID: endpoint.id, externalID: externalID, currentRevisionID: revisionID)
        let revision = ItemRevision(id: revisionID, itemID: item.id, title: externalID, text: text, contentHash: externalID)
        let segment = ItemSegment(itemRevisionID: revisionID, kind: .whole, span: TextSpan(utf8Start: 0, utf8Length: text.utf8.count, excerptHash: externalID), text: text, contentHash: externalID)
        _ = try await repository.saveItem(item, revision: revision, segments: [segment])
        return item
    }

    let remote = try await saveItem(externalID: "remote", text: "durable evidence")
    _ = try await repository.tombstone(targetKind: "item", targetID: remote.id.description, deletionKind: .remoteDeletion)
    let remoteText = try await database.pool.read { db in try String.fetchOne(db, sql: "SELECT plain_text FROM item_revisions WHERE item_id=?", arguments: [remote.id.description]) }
    #expect(remoteText == "durable evidence")

    let purged = try await saveItem(externalID: "purged", text: "secret private evidence")
    _ = try await repository.tombstone(targetKind: "item", targetID: purged.id.description, deletionKind: .legalPolicyPurge)
    let values = try await database.pool.read { db in
        let title = try String.fetchOne(db, sql: "SELECT title FROM item_revisions WHERE item_id=?", arguments: [purged.id.description])
        let text = try String.fetchOne(db, sql: "SELECT plain_text FROM item_revisions WHERE item_id=?", arguments: [purged.id.description])
        let segment = try String.fetchOne(db, sql: "SELECT text FROM item_segments WHERE item_revision_id=(SELECT current_revision_id FROM items WHERE id=?)", arguments: [purged.id.description])
        return (title, text, segment)
    }
    #expect(values.0 == "[Purged]")
    #expect(values.1 == "")
    #expect(values.2 == "")
}
