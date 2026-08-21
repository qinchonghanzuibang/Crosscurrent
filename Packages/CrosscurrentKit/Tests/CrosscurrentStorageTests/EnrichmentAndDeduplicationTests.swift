import CrosscurrentConnectors
import CrosscurrentDomain
import CrosscurrentIngestion
import CrosscurrentStorage
import Foundation
import GRDB
import Testing

@Test func ingestionPersistsProviderFreeLanguageWhenConnectorOmitsIt() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "CrosscurrentLanguageDetectionTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try CrosscurrentDatabase.open(
        at: DatabaseLocations(container: root),
        role: .mainApp
    )
    let repository = CrosscurrentRepository(database: database, writerInstance: "language-detection-test")
    let sourceRevision = SourceRevision(sourceID: SourceID(), displayName: "中文来源")
    let source = LogicalSource(
        id: sourceRevision.sourceID,
        currentRevisionID: sourceRevision.id,
        kind: .publication
    )
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .rss, externalID: "language-feed")
    _ = try await repository.saveSource(source, revision: sourceRevision, endpoints: [endpoint])

    let pipeline = IngestionPipeline(repository: repository)
    let result = try await pipeline.ingest(
        candidate: ConnectorItemCandidate(
            externalID: "zh-item",
            title: "浏览器工程团队发布新的隐私保护功能",
            contentText: "这项更新改进了网站权限控制，并为用户提供更清晰的安全提示。"
        ),
        sourceID: source.id,
        endpointID: endpoint.id
    )
    #expect(result.revision?.languageCode?.hasPrefix("zh") == true)
}

@Test func providerFreeEnrichmentPersistsOriginalUTF8SpanAfterFolding() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "CrosscurrentUnicodeEnrichmentTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try CrosscurrentDatabase.open(
        at: DatabaseLocations(container: root),
        role: .mainApp
    )
    let repository = CrosscurrentRepository(database: database, writerInstance: "unicode-enrichment-test")
    let sourceRevision = SourceRevision(sourceID: SourceID(), displayName: "Unicode Source")
    let source = LogicalSource(
        id: sourceRevision.sourceID,
        currentRevisionID: sourceRevision.id,
        kind: .publication
    )
    let endpoint = SourceEndpoint(
        sourceID: source.id,
        connector: .rss,
        externalID: "unicode-feed",
        canonicalURL: URL(string: "https://example.com/feed")
    )
    _ = try await repository.saveSource(source, revision: sourceRevision, endpoints: [endpoint])

    let entityRevision = EntityRevision(entityID: EntityID(), displayName: "Cafe")
    let entity = Entity(
        id: entityRevision.entityID,
        currentRevisionID: entityRevision.id,
        kind: .organization,
        displayName: "Cafe"
    )
    let alias = EntityAlias(
        entityID: entity.id,
        value: "Cafe",
        provenance: .connector,
        confidence: Confidence(0.95)
    )
    _ = try await repository.saveEntity(entity, revision: entityRevision, aliases: [alias])

    let text = "消息：CAFÉ 发布了更新。"
    let revisionID = ItemRevisionID()
    let item = Item(
        sourceID: source.id,
        sourceEndpointID: endpoint.id,
        externalID: "unicode-item",
        currentRevisionID: revisionID
    )
    let revision = ItemRevision(
        id: revisionID,
        itemID: item.id,
        title: "Unicode",
        text: text,
        contentHash: "unicode-content"
    )
    let segment = ItemSegment(
        itemRevisionID: revision.id,
        kind: .whole,
        span: TextSpan(utf8Start: 0, utf8Length: text.utf8.count, excerptHash: "whole"),
        text: text,
        contentHash: "segment-content"
    )
    _ = try await repository.saveItem(item, revision: revision, segments: [segment])

    let candidate = ConnectorItemCandidate(
        externalID: item.externalID,
        title: revision.title,
        contentText: text,
        languageCode: "zh-Hans"
    )
    let stage = ProviderFreeEnrichmentStage(repository: repository)
    try await stage.enrich(
        candidate: candidate,
        sourceID: source.id,
        revision: revision,
        segments: [segment]
    )

    let mention = try database.pool.read { db in
        try Row.fetchOne(
            db,
            sql: "SELECT utf8_start, utf8_length, mentioned_text FROM item_entity_mentions WHERE entity_id=?",
            arguments: [entity.id.description]
        )
    }
    let stored = try #require(mention)
    let expectedStart = "消息：".utf8.count
    #expect(stored["utf8_start"] as Int == expectedStart)
    #expect(stored["utf8_length"] as Int == "CAFÉ".utf8.count)
    #expect(stored["mentioned_text"] as String == "CAFÉ")
}

@Test func bridgedDuplicateRelationsCollapseExistingGroups() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "CrosscurrentDuplicateBridgeTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try CrosscurrentDatabase.open(
        at: DatabaseLocations(container: root),
        role: .mainApp
    )
    let repository = CrosscurrentRepository(database: database, writerInstance: "duplicate-bridge-test")
    let sourceRevision = SourceRevision(sourceID: SourceID(), displayName: "Duplicate Source")
    let source = LogicalSource(
        id: sourceRevision.sourceID,
        currentRevisionID: sourceRevision.id,
        kind: .publication
    )
    let endpoint = SourceEndpoint(sourceID: source.id, connector: .rss, externalID: "duplicate-feed")
    _ = try await repository.saveSource(source, revision: sourceRevision, endpoints: [endpoint])

    var items: [Item] = []
    for index in 0..<4 {
        let revisionID = ItemRevisionID()
        let item = Item(
            sourceID: source.id,
            sourceEndpointID: endpoint.id,
            externalID: "item-\(index)",
            currentRevisionID: revisionID
        )
        let revision = ItemRevision(
            id: revisionID,
            itemID: item.id,
            title: "Item \(index)",
            text: "Evidence \(index)",
            contentHash: "hash-\(index)"
        )
        _ = try await repository.saveItem(item, revision: revision, segments: [])
        items.append(item)
    }

    _ = try await repository.saveItemRelation(
        from: items[0].id,
        to: items[1].id,
        relationship: "exactDuplicate",
        confidence: Confidence(1),
        groupsAsDuplicate: true
    )
    _ = try await repository.saveItemRelation(
        from: items[2].id,
        to: items[3].id,
        relationship: "syndication",
        confidence: Confidence(0.95),
        groupsAsDuplicate: true
    )
    _ = try await repository.saveItemRelation(
        from: items[1].id,
        to: items[2].id,
        relationship: "alias",
        confidence: Confidence(0.9),
        groupsAsDuplicate: true
    )

    let state = try await database.pool.read { db in
        let groupCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM duplicate_groups") ?? -1
        let memberCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM duplicate_group_members") ?? -1
        let distinctGroups = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(DISTINCT group_id) FROM duplicate_group_members"
        ) ?? -1
        return (groupCount, memberCount, distinctGroups)
    }
    #expect(state.0 == 1)
    #expect(state.1 == 4)
    #expect(state.2 == 1)
}
