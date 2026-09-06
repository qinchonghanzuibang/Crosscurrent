import CrosscurrentDomain
@testable import CrosscurrentStorage
import Foundation
import GRDB
import Testing

@Test func contentReversionMigrationPreservesExistingEvidenceReferences() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentRevisionMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = DatabaseLocations(container: root)
    try locations.prepare()
    let old = try DatabaseQueue(path: locations.canonicalDatabase.path)
    try CanonicalSchema.migrator().migrate(old, upTo: "canonical-v10-wechat-backfill")
    let sourceID = SourceID(), endpointID = SourceEndpointID(), itemID = ItemID()
    let sourceRevisionID = SourceRevisionID(), itemRevisionID = ItemRevisionID(), segmentID = ItemSegmentID()
    let eventID = EventID(), eventRevisionID = EventRevisionID(), membershipID = MembershipAssertionID()
    let lineageID = SegmentLineageID()
    try await old.write { db in
        try db.execute(sql: "INSERT INTO sources VALUES (?, ?, 'publication', 1, 0, 1)", arguments: [sourceID.description, sourceRevisionID.description])
        try db.execute(sql: "INSERT INTO source_revisions VALUES (?, ?, 'Original publisher', NULL, NULL, NULL, 1)", arguments: [sourceRevisionID.description, sourceID.description])
        try db.execute(sql: "INSERT INTO source_endpoints (id, source_id, connector_kind, external_id, access_requirement, content_privacy, health) VALUES (?, ?, 'rss', 'feed', 'anonymous', 'public', 'healthy')", arguments: [endpointID.description, sourceID.description])
        try db.execute(sql: "INSERT INTO items VALUES (?, ?, ?, 'article', 'https://example.com/article', ?, 'available', 'active', 1)", arguments: [itemID.description, sourceID.description, endpointID.description, itemRevisionID.description])
        try db.execute(sql: "INSERT INTO item_revisions (id, item_id, ordinal, title, fetched_at, plain_text, content_hash, extraction_state, revision_reason) VALUES (?, ?, 1, 'Original title', 1, 'Original evidence', 'A', 'normalized', 'initial')", arguments: [itemRevisionID.description, itemID.description])
        try db.execute(sql: "INSERT INTO item_segments VALUES (?, ?, ?, 0, 'whole', 0, 17, '', 'A', 'Original evidence', 'Original evidence')", arguments: [segmentID.description, itemRevisionID.description, lineageID.description])
        try db.execute(sql: "INSERT INTO events VALUES (?, ?, 'active', 1, 0)", arguments: [eventID.description, eventRevisionID.description])
        try db.execute(sql: "INSERT INTO event_membership_assertions VALUES (?, ?, ?, ?, ?, 'accepted', 'primary', 1, 1, NULL, 'deterministic', NULL, 1)", arguments: [membershipID.description, eventID.description, itemRevisionID.description, segmentID.description, lineageID.description])
        try db.execute(sql: "INSERT INTO event_revisions (id, event_id, ordinal, title, summary, change_kind, primary_membership_assertion_id, created_at) VALUES (?, ?, 1, 'Event', 'Original interpretation', 'initial', ?, 1)", arguments: [eventRevisionID.description, eventID.description, membershipID.description])
        try db.execute(sql: "INSERT INTO event_revision_memberships VALUES (?, ?)", arguments: [eventRevisionID.description, membershipID.description])
    }
    let database = try CrosscurrentDatabase.open(at: locations, role: .mainApp)
    let repository = CrosscurrentRepository(database: database)
    for (ordinal, hash) in [(2, "B"), (3, "A")] {
        let revision = ItemRevision(itemID: itemID, ordinal: ordinal, title: "Title \(hash)", text: hash, contentHash: hash, changeKind: .contentUpdate)
        let item = Item(id: itemID, sourceID: sourceID, sourceEndpointID: endpointID, externalID: "article", currentRevisionID: revision.id)
        _ = try await repository.saveItem(item, revision: revision, segments: [])
    }
    let stored = try #require(try await repository.itemState(endpointID: endpointID, externalID: "article"))
    #expect(stored.currentOrdinal == 3 && stored.currentContentHash == "A")
    let original = try #require(try await repository.itemDetail(itemID: itemID, revisionID: itemRevisionID.description))
    #expect(original.text == "Original evidence" && original.isHistorical)
    #expect(try await repository.eventEvidence(eventID: eventID).first?.itemRevisionID == itemRevisionID)
    #expect(try await database.pool.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").isEmpty })
    #expect(try FileManager.default.contentsOfDirectory(atPath: locations.backups.path).contains { $0.hasPrefix("Crosscurrent-v10-") })
}

@Test func historicalEventSnapshotsRemainExactAndReadProgressDoesNotRegress() async throws {
    let fixture = try await RevisionFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let initial = fixture.eventRevision
    var update = initial
    update.id = EventRevisionID()
    update.ordinal = 2
    update.title = "Updated interpretation"
    update.changeKind = .majorUpdate
    var event = fixture.event
    event.currentRevisionID = update.id
    _ = try await repository.saveEvent(event, revision: update, memberships: [fixture.membership])
    _ = try await repository.markEventSeen(eventID: event.id, revisionID: update.id, ordinal: 2)
    _ = try await repository.markEventSeen(eventID: event.id, revisionID: initial.id, ordinal: 1)
    let historical = try #require(try await repository.eventSnapshots(revisionIDs: [initial.id]).first)
    #expect(historical.aggregate.revision.id == initial.id && historical.aggregate.revision.title == initial.title)
    #expect(historical.aggregate.revision.primaryMembershipAssertionID == initial.primaryMembershipAssertionID)
    #expect(abs(historical.aggregate.revision.createdAt.timeIntervalSince(initial.createdAt)) < 0.000_001)
    #expect(historical.aggregate.event.currentRevisionID == update.id)
    #expect(try await repository.currentEventSnapshots(eventIDs: [event.id]).first?.readStatus == .read)
    await #expect(throws: CrosscurrentStorageError.invalidStagedData) {
        try await repository.markEventSeen(eventID: event.id, revisionID: initial.id, ordinal: 9)
    }
    // Reusing a revision ID cannot overwrite interpretation or add historical membership.
    var altered = initial
    altered.title = "Tampered historical title"
    await #expect(throws: (any Error).self) {
        try await repository.saveEvent(fixture.event, revision: altered, memberships: [fixture.membership])
    }
    #expect(try await repository.eventSnapshots(revisionIDs: [initial.id]).first?.aggregate.revision.title == initial.title)
    #expect(try await repository.currentEventSnapshots(eventIDs: [event.id]).first?.aggregate.revision.id == update.id)
}

@Test func canonicalRevisionReplayCannotReplaceEvidenceOrDigestEntries() async throws {
    let fixture = try await RevisionFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var changed = fixture.itemRevision
    changed.text = "Tampered evidence"
    var segment = fixture.segment
    segment.text = changed.text
    await #expect(throws: (any Error).self) {
        try await fixture.repository.saveItem(fixture.item, revision: changed, segments: [segment])
    }
    #expect(try await fixture.repository.itemSegments(revisionID: fixture.itemRevision.id).first?.text == fixture.segment.text)
    var revision = DigestRevision(digestID: DigestID(), reason: .initialDaily, entries: [DigestEntry(eventRevisionID: fixture.eventRevision.id, section: .today, rank: 0, score: 1, explanation: [])])
    let digest = Digest(id: revision.digestID, briefingDay: .now, currentRevisionID: revision.id)
    _ = try await fixture.repository.saveDigest(digest, revision: revision)
    revision.entries[0].score = 100
    await #expect(throws: (any Error).self) { try await fixture.repository.saveDigest(digest, revision: revision) }
    #expect(try await fixture.repository.digestState(briefingDay: digest.briefingDay)?.latestRevision.entries.first?.score == 1)
}

@Test func exhaustedRefreshCooldownSurvivesSchedulingAndManualRefreshOverridesIt() async throws {
    let fixture = try await RevisionFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let now = Date.now
    let job = try await fixture.repository.scheduleRefreshJob(endpointID: fixture.endpoint.id, payload: Data(), manual: false, now: now)
    let (_, lease) = try #require(try await fixture.repository.leaseJob(id: job.id, owner: "test", now: now))
    _ = try await fixture.repository.suspendJob(lease, failureClass: "transientHTTPExhausted", retryAt: now.addingTimeInterval(86_400))
    let held = try await fixture.repository.scheduleRefreshJob(endpointID: fixture.endpoint.id, payload: Data(), manual: false, now: now.addingTimeInterval(60))
    #expect(held.id == job.id && held.state == .cancelled)
    #expect(try await fixture.repository.leaseJob(id: held.id, owner: "agent", now: now.addingTimeInterval(60)) == nil)
    let manual = try await fixture.repository.scheduleRefreshJob(endpointID: fixture.endpoint.id, payload: Data(), manual: true, now: now.addingTimeInterval(61))
    #expect(manual.id != job.id && manual.state == .pending && manual.attemptCount == 0)
    let rescheduled = try await fixture.repository.scheduleRefreshJob(endpointID: fixture.endpoint.id, payload: Data(), manual: false, now: now.addingTimeInterval(62))
    #expect(rescheduled.id == manual.id && rescheduled.state == .pending)
}

@Test func aiEvidenceClassificationRequiresEveryRevisionAndKeepsPrivateEndpointsPrivate() async throws {
    let fixture = try await RevisionFixture.make()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var endpoint = fixture.endpoint
    endpoint.contentPrivacy = .private
    _ = try await fixture.repository.saveEndpoint(endpoint)
    let classifications = try await fixture.repository.aiClassifications(itemRevisionIDs: [fixture.itemRevision.id])
    #expect(classifications.count == 1 && classifications.first?.sourceID == fixture.item.sourceID)
    #expect(classifications.first?.contentPrivacy == .private)
    await #expect(throws: CrosscurrentStorageError.invalidStagedData) {
        try await fixture.repository.aiClassifications(itemRevisionIDs: [fixture.itemRevision.id, ItemRevisionID()])
    }
}

private struct RevisionFixture {
    var root: URL
    var repository: CrosscurrentRepository
    var endpoint: SourceEndpoint
    var item: Item
    var itemRevision: ItemRevision
    var segment: ItemSegment
    var event: Event
    var eventRevision: EventRevision
    var membership: EventMembershipAssertion

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "CrosscurrentRevisionIntegrity-\(UUID())")
        let repository = CrosscurrentRepository(database: try .open(at: .init(container: root), role: .mainApp))
        let sourceRevision = SourceRevision(sourceID: SourceID(), displayName: "Publisher")
        let source = LogicalSource(id: sourceRevision.sourceID, currentRevisionID: sourceRevision.id, kind: .publication)
        let endpoint = SourceEndpoint(sourceID: source.id, connector: .rss, externalID: "feed", contentPrivacy: .public)
        _ = try await repository.saveSource(source, revision: sourceRevision, endpoints: [endpoint])
        let revision = ItemRevision(itemID: ItemID(), title: "Original title", publishedAt: .now, text: "Original evidence", contentHash: "A")
        let item = Item(id: revision.itemID, sourceID: source.id, sourceEndpointID: endpoint.id, externalID: "article", currentRevisionID: revision.id)
        let segment = ItemSegment(itemRevisionID: revision.id, kind: .whole, span: .init(utf8Start: 0, utf8Length: revision.text.utf8.count, excerptHash: "A"), text: revision.text, contentHash: "A")
        _ = try await repository.saveItem(item, revision: revision, segments: [segment])
        let eventID = EventID()
        let membership = EventMembershipAssertion(eventID: eventID, itemRevisionID: revision.id, itemSegmentID: segment.id, segmentLineageID: segment.lineageID, decision: .accepted, role: .primary, confidence: .certain, identityWeight: 1, provenance: .deterministic)
        let eventRevision = EventRevision(eventID: eventID, title: "Original interpretation", summary: revision.text, primaryMembershipAssertionID: membership.id)
        let event = Event(id: eventID, currentRevisionID: eventRevision.id)
        _ = try await repository.saveEvent(event, revision: eventRevision, memberships: [membership])
        return Self(root: root, repository: repository, endpoint: endpoint, item: item, itemRevision: revision, segment: segment, event: event, eventRevision: eventRevision, membership: membership)
    }
}
