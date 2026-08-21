import Foundation
import CrosscurrentDomain
import GRDB

public actor CrosscurrentRepository {
    public let role: RepositoryRole
    public let writerInstance: String

    private let database: CrosscurrentDatabase
    private let observations: CrossProcessObservationHub
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(database: CrosscurrentDatabase, writerInstance: String = UUID().uuidString.lowercased(), observations: CrossProcessObservationHub = CrossProcessObservationHub()) {
        self.database = database
        self.role = database.role
        self.writerInstance = writerInstance
        self.observations = observations
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func generations() throws -> [ChangeDomain: ChangeGeneration] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT domain, generation, committed_at, writer_instance FROM database_change_generations")
            return rows.reduce(into: [:]) { result, row in
                guard let domain = ChangeDomain(rawValue: row["domain"]) else { return }
                result[domain] = ChangeGeneration(
                    domain: domain,
                    generation: row["generation"],
                    committedAt: Date(timeIntervalSince1970: row["committed_at"]),
                    writerInstance: row["writer_instance"]
                )
            }
        }
    }

    public func wakeHints() -> AsyncStream<Void> {
        observations.wakeHints()
    }

    @discardableResult
    public func saveSource(
        _ source: LogicalSource,
        revision: SourceRevision,
        endpoints: [SourceEndpoint] = [],
        aiClassification: SourceAIClassification? = nil,
        coverage: SourceCoverageAssertion? = nil,
        idempotencyKey: String? = nil
    ) throws -> Bool {
        try mutate(domains: [.sources, .endpoints, .searchInputs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT INTO sources (id, current_revision_id, kind, is_followed, is_archived, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET current_revision_id=excluded.current_revision_id,
                  kind=excluded.kind, is_followed=excluded.is_followed, is_archived=excluded.is_archived
                """,
                arguments: [source.id.description, revision.id.description, source.kind.rawValue, source.isFollowed, source.isArchived, source.createdAt.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO source_revisions
                  (id, source_id, display_name, summary, avatar_url, configuration_json, created_at)
                VALUES (?, ?, ?, ?, ?, NULL, ?)
                """,
                arguments: [revision.id.description, source.id.description, revision.displayName, revision.summary, revision.avatarURL?.absoluteString, revision.createdAt.timeIntervalSince1970]
            )
            for endpoint in endpoints {
                try Self.persist(endpoint: endpoint, in: db)
            }
            if let classification = aiClassification {
                try db.execute(sql: "UPDATE source_ai_classifications SET is_current=0 WHERE source_id=? AND is_current=1", arguments: [source.id.description])
                try db.execute(
                    sql: "INSERT OR IGNORE INTO source_ai_classifications (id, source_id, access_requirement, content_privacy, provenance, confidence, created_at, supersedes_id, is_current) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)",
                    arguments: [classification.id.uuidString.lowercased(), source.id.description, classification.accessRequirement.rawValue, classification.contentPrivacy.rawValue, classification.provenance.rawValue, classification.confidence.value, classification.createdAt.timeIntervalSince1970, classification.supersedesID?.uuidString.lowercased()]
                )
            }
            if let coverage {
                try db.execute(sql: "UPDATE source_coverage_assertions SET is_current=0 WHERE source_id=? AND is_current=1", arguments: [source.id.description])
                try db.execute(
                    sql: "INSERT OR IGNORE INTO source_coverage_assertions (id, source_id, ecosystem, provenance, confidence, rationale, effective_at, supersedes_id, is_current) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)",
                    arguments: [coverage.id.uuidString.lowercased(), source.id.description, coverage.ecosystem.rawValue, coverage.provenance.rawValue, coverage.confidence.value, coverage.rationale, coverage.effectiveAt.timeIntervalSince1970, coverage.supersedesID?.uuidString.lowercased()]
                )
            }
            try Self.upsertSearchInput(
                stableID: source.id.description,
                kind: "source",
                revisionID: revision.id.description,
                languageCode: nil,
                title: revision.displayName,
                body: revision.summary ?? "",
                inputHash: HTTPMetadataRedactor.digest(Data((revision.displayName + (revision.summary ?? "")).utf8)),
                db: db
            )
        }
    }

    @discardableResult
    public func saveSourceEntityRelationship(_ relationship: SourceEntityRelationship, idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.sources, .entities], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO source_entities (id, source_id, entity_id, role, provenance, confidence) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [relationship.id.uuidString.lowercased(), relationship.sourceID.description, relationship.entityID.description, relationship.role.rawValue, relationship.provenance.rawValue, relationship.confidence.value]
            )
        }
    }

    @discardableResult
    public func saveEndpoint(_ endpoint: SourceEndpoint, idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.endpoints], idempotencyKey: idempotencyKey) { db in
            try Self.persist(endpoint: endpoint, in: db)
        }
    }

    public func ensureSourceFolder(name: String, pathKey: String, parentID: UUID?, attributes: [String: String], sortOrder: Int, at date: Date = .now) throws -> UUID {
        var result: UUID?
        _ = try mutate(domains: [.sources]) { db in
            let id = UUID()
            let metadata = try encoder.encode(attributes)
            try db.execute(
                sql: "INSERT OR IGNORE INTO source_folders (id, parent_id, path_key, name, attributes_json, sort_order, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                arguments: [id.uuidString.lowercased(), parentID?.uuidString.lowercased(), pathKey, name, metadata, sortOrder, date.timeIntervalSince1970]
            )
            guard let stored = try String.fetchOne(db, sql: "SELECT id FROM source_folders WHERE path_key=?", arguments: [pathKey]),
                  let uuid = UUID(uuidString: stored)
            else { throw CrosscurrentStorageError.corruptRecord("SourceFolder") }
            result = uuid
        }
        guard let result else { throw CrosscurrentStorageError.corruptRecord("SourceFolder") }
        return result
    }

    @discardableResult
    public func assignSource(_ sourceID: SourceID, toFolder folderID: UUID, sortOrder: Int) throws -> Bool {
        try mutate(domains: [.sources]) { db in
            try db.execute(
                sql: "INSERT INTO source_folder_memberships (folder_id, source_id, sort_order) VALUES (?, ?, ?) ON CONFLICT(folder_id, source_id) DO UPDATE SET sort_order=excluded.sort_order",
                arguments: [folderID.uuidString.lowercased(), sourceID.description, sortOrder]
            )
        }
    }

    @discardableResult
    public func saveConnectorAccount(id: ConnectorAccountID, kind: ConnectorKind, externalIdentity: String? = nil, browserProfileID: UUID? = nil, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.accounts]) { db in
            try db.execute(
                sql: "INSERT INTO connector_accounts (id, connector_kind, external_identity, browser_profile_uuid, keychain_reference, consent_state_json, created_at) VALUES (?, ?, ?, ?, NULL, NULL, ?) ON CONFLICT(id) DO UPDATE SET connector_kind=excluded.connector_kind, external_identity=COALESCE(excluded.external_identity, connector_accounts.external_identity), browser_profile_uuid=COALESCE(excluded.browser_profile_uuid, connector_accounts.browser_profile_uuid)",
                arguments: [id.description, kind.rawValue, externalIdentity, browserProfileID?.uuidString.lowercased(), date.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func saveEntity(_ entity: Entity, revision: EntityRevision, aliases: [EntityAlias] = [], idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.entities, .searchInputs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT INTO entities (id, current_revision_id, kind, normalized_name, is_followed, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET current_revision_id=excluded.current_revision_id,
                  kind=excluded.kind, normalized_name=excluded.normalized_name, is_followed=excluded.is_followed
                """,
                arguments: [entity.id.description, revision.id.description, entity.kind.rawValue, entity.normalizedName, entity.isFollowed, entity.createdAt.timeIntervalSince1970]
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO entity_revisions (id, entity_id, display_name, summary, external_identifiers_json, created_at) VALUES (?, ?, ?, ?, NULL, ?)",
                arguments: [revision.id.description, entity.id.description, revision.displayName, revision.summary, revision.createdAt.timeIntervalSince1970]
            )
            for alias in aliases {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO entity_aliases
                      (id, entity_id, value, normalized_value, language_code, script_code, provenance, confidence, valid_from, valid_until)
                    VALUES (?, ?, ?, ?, ?, NULL, ?, ?, NULL, NULL)
                    """,
                    arguments: [alias.id.description, entity.id.description, alias.value, alias.normalizedValue, alias.languageCode, alias.provenance.rawValue, alias.confidence.value]
                )
            }
            let aliasText = aliases.map(\.value).joined(separator: " ")
            try Self.upsertSearchInput(
                stableID: entity.id.description,
                kind: entity.kind.rawValue,
                revisionID: revision.id.description,
                languageCode: nil,
                title: revision.displayName,
                body: [revision.summary, aliasText].compactMap { $0 }.joined(separator: " "),
                inputHash: HTTPMetadataRedactor.digest(Data((revision.displayName + aliasText).utf8)),
                db: db
            )
        }
    }

    /// Resolves a high-confidence structured identity without requiring an AI provider. The
    /// alias lookup and creation happen in one canonical write transaction so concurrent
    /// refresh paths cannot create a second identity inside this writer.
    public func resolveOrCreateEntity(
        displayName: String,
        kind: EntityKind,
        languageCode: String?,
        sourceID: SourceID? = nil,
        sourceRole: SourceEntityRole? = nil,
        provenance: AssertionProvenance = .connector,
        confidence: Confidence = Confidence(0.9),
        at date: Date = .now
    ) throws -> EntityID? {
        let display = displayName.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = Self.normalizedAssertionName(display)
        guard normalized.count >= 2 else { return nil }
        var resolved: EntityID?
        _ = try mutate(domains: [.entities, .sources, .searchInputs]) { db in
            if let stored: String = try String.fetchOne(
                db,
                sql: "SELECT entity_id FROM entity_aliases WHERE normalized_value=? ORDER BY confidence DESC LIMIT 1",
                arguments: [normalized]
            ) {
                resolved = Self.identifier(EntityID.self, stored)
            } else {
                let entityID = EntityID()
                let revisionID = EntityRevisionID()
                try db.execute(
                    sql: "INSERT INTO entities (id, current_revision_id, kind, normalized_name, is_followed, created_at) VALUES (?, ?, ?, ?, 0, ?)",
                    arguments: [entityID.description, revisionID.description, kind.rawValue, normalized, date.timeIntervalSince1970]
                )
                try db.execute(
                    sql: "INSERT INTO entity_revisions (id, entity_id, display_name, summary, external_identifiers_json, created_at) VALUES (?, ?, ?, NULL, NULL, ?)",
                    arguments: [revisionID.description, entityID.description, display, date.timeIntervalSince1970]
                )
                try db.execute(
                    sql: "INSERT INTO entity_aliases (id, entity_id, value, normalized_value, language_code, script_code, provenance, confidence, valid_from, valid_until) VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, NULL)",
                    arguments: [EntityAliasID().description, entityID.description, display, normalized, languageCode, provenance.rawValue, confidence.value, date.timeIntervalSince1970]
                )
                try Self.upsertSearchInput(
                    stableID: entityID.description,
                    kind: kind.rawValue,
                    revisionID: revisionID.description,
                    languageCode: languageCode,
                    title: display,
                    body: "",
                    inputHash: HTTPMetadataRedactor.digest(Data(normalized.utf8)),
                    db: db
                )
                resolved = entityID
            }
            if let resolved, let sourceID, let sourceRole {
                let relationshipKey = "structured:\(sourceID.description):\(resolved.description):\(sourceRole.rawValue)"
                try db.execute(
                    sql: "INSERT OR IGNORE INTO source_entities (id, source_id, entity_id, role, provenance, confidence) VALUES (?, ?, ?, ?, ?, ?)",
                    arguments: [relationshipKey, sourceID.description, resolved.description, sourceRole.rawValue, provenance.rawValue, confidence.value]
                )
            }
        }
        return resolved
    }

    public func entityAliasesForEnrichment(sourceID: SourceID, limit: Int = 2_000) throws -> [StoredEntityAlias] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT ea.entity_id, e.kind, ea.value, ea.normalized_value, ea.confidence,
                       CASE WHEN se.source_id IS NULL THEN 1 ELSE 0 END AS unlinked
                FROM entity_aliases ea
                JOIN entities e ON e.id=ea.entity_id
                LEFT JOIN source_entities se ON se.entity_id=ea.entity_id AND se.source_id=?
                WHERE ea.valid_until IS NULL
                ORDER BY unlinked ASC, ea.confidence DESC, LENGTH(ea.normalized_value) DESC
                LIMIT ?
                """,
                arguments: [sourceID.description, max(1, min(limit, 10_000))]
            )
            return try rows.map { row in
                guard let entityID = Self.identifier(EntityID.self, row["entity_id"]),
                      let kind = EntityKind(rawValue: row["kind"])
                else { throw CrosscurrentStorageError.corruptRecord("StoredEntityAlias") }
                return StoredEntityAlias(
                    entityID: entityID,
                    kind: kind,
                    value: row["value"],
                    normalizedValue: row["normalized_value"],
                    confidence: Confidence(row["confidence"])
                )
            }
        }
    }

    @discardableResult
    public func saveItemEntityMentions(_ mentions: [ItemEntityMention], idempotencyKey: String? = nil) throws -> Bool {
        guard !mentions.isEmpty else { return false }
        return try mutate(domains: [.entities, .items], idempotencyKey: idempotencyKey) { db in
            for mention in mentions {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO item_entity_mentions
                      (id, item_revision_id, item_segment_id, entity_id, utf8_start, utf8_length,
                       excerpt_hash, mentioned_text, provenance, confidence)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [mention.id.uuidString.lowercased(), mention.itemRevisionID.description, mention.itemSegmentID.description, mention.entityID.description, mention.span.utf8Start, mention.span.utf8Length, mention.span.excerptHash, mention.mentionedText, mention.provenance.rawValue, mention.confidence.value]
                )
            }
        }
    }

    @discardableResult
    public func saveTopic(_ topic: Topic, revision: TopicRevision, aliases: [TopicAlias] = [], idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.topics, .searchInputs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: "INSERT INTO topics (id, current_revision_id, is_followed) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET current_revision_id=excluded.current_revision_id, is_followed=excluded.is_followed",
                arguments: [topic.id.description, revision.id.description, topic.isFollowed]
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO topic_revisions (id, topic_id, name, summary, created_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [revision.id.description, topic.id.description, revision.name, revision.summary, revision.createdAt.timeIntervalSince1970]
            )
            let provided = aliases.isEmpty
                ? [TopicAlias(topicID: topic.id, normalizedName: revision.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased())]
                : aliases
            for alias in provided {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO topic_aliases (id, topic_id, normalized_name, language_code) VALUES (?, ?, ?, ?)",
                    arguments: [alias.id.uuidString.lowercased(), topic.id.description, alias.normalizedName, alias.languageCode]
                )
            }
            try Self.upsertSearchInput(
                stableID: topic.id.description,
                kind: "topic",
                revisionID: revision.id.description,
                languageCode: nil,
                title: revision.name,
                body: revision.summary ?? "",
                inputHash: HTTPMetadataRedactor.digest(Data((revision.name + (revision.summary ?? "")).utf8)),
                db: db
            )
        }
    }

    @discardableResult
    public func saveItem(
        _ item: Item,
        revision: ItemRevision,
        segments: [ItemSegment],
        topicNames: [String] = [],
        sanitizedHTMLBlobID: BlobID? = nil,
        evidenceBlobID: BlobID? = nil,
        idempotencyKey: String? = nil
    ) throws -> Bool {
        try mutate(domains: [.items, .searchInputs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT INTO items
                  (id, source_id, endpoint_id, connector_external_id, canonical_key, current_revision_id, remote_state, user_deletion_state, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?)
                ON CONFLICT(id) DO UPDATE SET current_revision_id=excluded.current_revision_id,
                  remote_state=excluded.remote_state, canonical_key=excluded.canonical_key
                """,
                arguments: [item.id.description, item.sourceID.description, item.sourceEndpointID.description, item.externalID, item.canonicalURL?.absoluteString ?? item.externalID, revision.id.description, item.remoteState.rawValue, item.createdAt.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO item_revisions
                  (id, item_id, ordinal, title, author, published_at, modified_at, fetched_at, language_code,
                   plain_text, sanitized_html_blob_id, evidence_blob_id, content_hash, extraction_state, revision_reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'normalized', ?)
                """,
                arguments: [revision.id.description, item.id.description, revision.ordinal, revision.title, revision.author, revision.publishedAt?.timeIntervalSince1970, revision.modifiedAt?.timeIntervalSince1970, revision.fetchedAt.timeIntervalSince1970, revision.languageCode, revision.text, sanitizedHTMLBlobID?.description, evidenceBlobID?.description, revision.contentHash, revision.changeKind.rawValue]
            )
            for (ordinal, segment) in segments.enumerated() {
                try db.execute(
                    sql: """
                    INSERT OR REPLACE INTO item_segments
                      (id, item_revision_id, lineage_id, ordinal, kind, utf8_start, utf8_length, heading_path,
                       segment_hash, text, embedding_input)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [segment.id.description, revision.id.description, segment.lineageID.description, ordinal, segment.kind.rawValue, segment.span.utf8Start, segment.span.utf8Length, segment.headingPath.joined(separator: " / "), segment.contentHash, segment.text, segment.text]
                )
            }
            for name in topicNames {
                let displayName = name.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
                guard !normalized.isEmpty else { continue }
                var topicID = try String.fetchOne(db, sql: "SELECT topic_id FROM topic_aliases WHERE normalized_name=?", arguments: [normalized])
                if topicID == nil {
                    let typedTopicID = TopicID()
                    let revisionID = TopicRevisionID()
                    topicID = typedTopicID.description
                    try db.execute(sql: "INSERT INTO topics (id, current_revision_id, is_followed) VALUES (?, ?, 0)", arguments: [typedTopicID.description, revisionID.description])
                    try db.execute(sql: "INSERT INTO topic_revisions (id, topic_id, name, summary, created_at) VALUES (?, ?, ?, NULL, ?)", arguments: [revisionID.description, typedTopicID.description, displayName, revision.fetchedAt.timeIntervalSince1970])
                    try db.execute(sql: "INSERT INTO topic_aliases (id, topic_id, normalized_name, language_code) VALUES (?, ?, ?, ?)", arguments: [UUID().uuidString.lowercased(), typedTopicID.description, normalized, revision.languageCode])
                    try Self.upsertSearchInput(stableID: typedTopicID.description, kind: "topic", revisionID: revisionID.description, languageCode: revision.languageCode, title: displayName, body: "", inputHash: HTTPMetadataRedactor.digest(Data(normalized.utf8)), db: db)
                }
                if let topicID {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO item_topic_assertions (id, item_revision_id, item_segment_id, topic_id, confidence, provenance, supersedes_id) VALUES (?, ?, ?, ?, ?, ?, NULL)",
                        arguments: [UUID().uuidString.lowercased(), revision.id.description, segments.first?.id.description, topicID, Confidence(0.8).value, AssertionProvenance.connector.rawValue]
                    )
                }
            }
            try Self.upsertSearchInput(
                stableID: item.id.description,
                kind: "item",
                revisionID: revision.id.description,
                languageCode: revision.languageCode,
                title: revision.title,
                body: revision.text,
                inputHash: revision.contentHash,
                db: db
            )
        }
    }

    @discardableResult
    public func saveEvent(
        _ event: Event,
        revision: EventRevision,
        memberships: [EventMembershipAssertion],
        includedMembershipIDs: Set<MembershipAssertionID>? = nil,
        idempotencyKey: String? = nil
    ) throws -> Bool {
        try mutate(domains: [.events, .searchInputs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT INTO events (id, current_revision_id, lifecycle_state, created_at, is_tombstoned)
                VALUES (?, ?, 'active', ?, ?)
                ON CONFLICT(id) DO UPDATE SET current_revision_id=excluded.current_revision_id,
                  lifecycle_state=excluded.lifecycle_state, is_tombstoned=excluded.is_tombstoned
                """,
                arguments: [event.id.description, revision.id.description, event.createdAt.timeIntervalSince1970, event.isTombstoned]
            )
            for membership in memberships {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO event_membership_assertions
                      (id, event_id, item_revision_id, item_segment_id, segment_lineage_id, decision, role,
                       confidence, identity_weight, independence_group, provenance, supersedes_id, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [membership.id.description, event.id.description, membership.itemRevisionID.description, membership.itemSegmentID.description, membership.segmentLineageID.description, membership.decision.rawValue, membership.role.rawValue, membership.confidence.value, membership.identityWeight, membership.independenceGroup, membership.provenance.rawValue, membership.supersedesID?.description, membership.createdAt.timeIntervalSince1970]
                )
            }
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO event_revisions
                  (id, event_id, ordinal, title, summary, started_at, ended_at, change_kind,
                   primary_membership_assertion_id, score_snapshot_json, generation_metadata_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                arguments: [revision.id.description, event.id.description, revision.ordinal, revision.title, revision.summary, revision.startedAt?.timeIntervalSince1970, revision.endedAt?.timeIntervalSince1970, revision.changeKind.rawValue, revision.primaryMembershipAssertionID?.description, try encoder.encode(revision.primaryReasonTrace), revision.createdAt.timeIntervalSince1970]
            )
            let included = includedMembershipIDs ?? Set(memberships.map(\.id))
            for membershipID in included {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO event_revision_memberships (event_revision_id, membership_assertion_id) VALUES (?, ?)",
                    arguments: [revision.id.description, membershipID.description]
                )
            }
            let topicRows = try Row.fetchAll(
                db,
                sql: "SELECT ita.topic_id, MAX(ita.confidence) AS confidence FROM event_revision_memberships rm JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id JOIN item_topic_assertions ita ON ita.item_revision_id=m.item_revision_id WHERE rm.event_revision_id=? GROUP BY ita.topic_id",
                arguments: [revision.id.description]
            )
            for topic in topicRows {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO event_topic_assertions (id, event_revision_id, topic_id, confidence, provenance, supersedes_id) VALUES (?, ?, ?, ?, ?, NULL)",
                    arguments: [UUID().uuidString.lowercased(), revision.id.description, topic["topic_id"] as String, topic["confidence"] as Double, AssertionProvenance.deterministic.rawValue]
                )
            }
            try Self.upsertSearchInput(
                stableID: event.id.description,
                kind: "event",
                revisionID: revision.id.description,
                languageCode: nil,
                title: revision.title,
                body: revision.summary,
                inputHash: HTTPMetadataRedactor.digest(Data((revision.title + revision.summary).utf8)),
                db: db
            )
        }
    }

    @discardableResult
    public func saveConstraint(_ constraint: ClusteringConstraint, idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.constraints], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT OR REPLACE INTO clustering_constraints
                  (id, kind, left_lineage_id, right_lineage_id, event_id, scope_json, provenance, reason, is_active, created_at, revoked_at)
                VALUES (?, ?, ?, ?, ?, NULL, 'user', ?, ?, ?, NULL)
                """,
                arguments: [constraint.id.description, constraint.kind.rawValue, constraint.leftLineageID.description, constraint.rightLineageID?.description, constraint.eventID?.description, constraint.reason, constraint.isActive, constraint.createdAt.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func recordEventMerge(survivingEventID: EventID, losingEventIDs: [EventID], priorRevisionID: EventRevisionID, weightedOverlap: [String: Double], at date: Date = .now) throws -> Bool {
        guard !losingEventIDs.isEmpty else { return false }
        let operationID = UUID().uuidString.lowercased()
        let resultData = try encoder.encode([survivingEventID.description])
        let overlapData = try encoder.encode(weightedOverlap)
        return try mutate(domains: [.events, .constraints, .searchInputs], idempotencyKey: "event-merge:\(priorRevisionID):\(losingEventIDs.map(\.description).sorted().joined(separator: ":"))") { db in
            try db.execute(
                sql: "INSERT INTO event_lineage_operations (id, operation, prior_event_revision_id, result_event_ids_json, weighted_overlap_json, created_at) VALUES (?, 'merge', ?, ?, ?, ?)",
                arguments: [operationID, priorRevisionID.description, resultData, overlapData, date.timeIntervalSince1970]
            )
            for losing in losingEventIDs {
                try db.execute(sql: "UPDATE events SET lifecycle_state='merged' WHERE id=?", arguments: [losing.description])
                try db.execute(sql: "INSERT OR REPLACE INTO event_aliases (losing_event_id, surviving_event_id, operation_id) VALUES (?, ?, ?)", arguments: [losing.description, survivingEventID.description, operationID])
                try db.execute(sql: "DELETE FROM search_inputs WHERE kind='event' AND stable_id=?", arguments: [losing.description])
            }
        }
    }

    @discardableResult
    public func recordEventSplit(priorRevisionID: EventRevisionID, resultEventIDs: [EventID], weightedOverlap: [Double], at date: Date = .now) throws -> Bool {
        let operationID = UUID().uuidString.lowercased()
        return try mutate(domains: [.events, .constraints], idempotencyKey: "event-split:\(priorRevisionID):\(resultEventIDs.map(\.description).joined(separator: ":"))") { db in
            try db.execute(
                sql: "INSERT INTO event_lineage_operations (id, operation, prior_event_revision_id, result_event_ids_json, weighted_overlap_json, created_at) VALUES (?, 'split', ?, ?, ?, ?)",
                arguments: [operationID, priorRevisionID.description, try encoder.encode(resultEventIDs.map(\.description)), try encoder.encode(weightedOverlap), date.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func savePrompt(template: PromptTemplate, revision: PromptRevision, makeActive: Bool = true, idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.prompts], idempotencyKey: idempotencyKey) { db in
            let variables = try encoder.encode(revision.variables)
            try db.execute(
                sql: "INSERT OR IGNORE INTO prompt_templates (id, task, name, bundled_default_revision_id) VALUES (?, ?, ?, ?)",
                arguments: [template.id.description, template.task.rawValue, template.name, template.bundledDefaultRevisionID.description]
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO prompt_revisions (id, template_id, parent_revision_id, origin, body, variables_json, compatibility_json, created_at) VALUES (?, ?, ?, ?, ?, ?, NULL, ?)",
                arguments: [revision.id.description, template.id.description, revision.parentRevisionID?.description, revision.origin.rawValue, revision.body, variables, revision.createdAt.timeIntervalSince1970]
            )
            if makeActive {
                try db.execute(
                    sql: """
                    INSERT INTO prompt_bindings (template_id, active_revision_id, provider_route_json, updated_at)
                    VALUES (?, ?, NULL, ?)
                    ON CONFLICT(template_id) DO UPDATE SET active_revision_id=excluded.active_revision_id, updated_at=excluded.updated_at
                    """,
                    arguments: [template.id.description, revision.id.description, Date.now.timeIntervalSince1970]
                )
            }
        }
    }

    @discardableResult
    public func saveDigest(_ digest: Digest, revision: DigestRevision, idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.digests], idempotencyKey: idempotencyKey) { db in
            let day = Self.dayFormatter.string(from: digest.briefingDay)
            try db.execute(
                sql: """
                INSERT INTO digests (id, briefing_day, current_revision_id) VALUES (?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET current_revision_id=excluded.current_revision_id
                """,
                arguments: [digest.id.description, day, revision.id.description]
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO digest_revisions (id, digest_id, parent_revision_id, reason, ranking_snapshot_json, created_at) VALUES (?, ?, ?, ?, NULL, ?)",
                arguments: [revision.id.description, digest.id.description, revision.parentRevisionID?.description, revision.reason.rawValue, revision.createdAt.timeIntervalSince1970]
            )
            for entry in revision.entries {
                let explanation = try encoder.encode(entry.explanation)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO digest_entries (id, digest_revision_id, event_revision_id, section, rank, score, explanation_json) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    arguments: [entry.id.uuidString.lowercased(), revision.id.description, entry.eventRevisionID.description, entry.section.rawValue, entry.rank, entry.score, explanation]
                )
            }
        }
    }

    @discardableResult
    public func registerBlob(_ blob: StoredBlob, idempotencyKey: String? = nil) throws -> Bool {
        try mutate(domains: [.blobs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO blobs
                  (id, sha256, relative_path, byte_count, media_type, retention_class, created_at, quarantined_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [blob.id.description, blob.sha256, blob.relativePath, blob.byteCount, blob.mediaType, blob.retentionClass.rawValue, blob.createdAt.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func saveRawFetch(
        receipt: RawFetchReceipt,
        requestURL: URL,
        requestHeaders: [String: String],
        responseHeaders: [String: String],
        connectorSecretNames: Set<String> = [],
        idempotencyKey: String? = nil
    ) throws -> Bool {
        let safeRequest = HTTPMetadataRedactor.redact(url: requestURL, headers: requestHeaders, connectorSecretNames: connectorSecretNames)
        let safeResponse = HTTPMetadataRedactor.redact(url: receipt.safeURL, headers: responseHeaders, connectorSecretNames: connectorSecretNames)
        let requestMetadata = try encoder.encode(safeRequest.headers)
        let responseMetadata = try encoder.encode(safeResponse.headers)
        return try mutate(domains: [.blobs], idempotencyKey: idempotencyKey) { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO raw_fetches
                  (id, endpoint_id, safe_url, redacted_request_metadata, redacted_response_metadata, status_code,
                   response_sha256, blob_id, fetched_at, retention_class, extraction_outcome)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [receipt.id.uuidString.lowercased(), receipt.endpointID?.description, safeRequest.safeURL.absoluteString, requestMetadata, responseMetadata, receipt.statusCode, receipt.responseSHA256, receipt.blobID?.description, receipt.fetchedAt.timeIntervalSince1970, receipt.retentionClass.rawValue, receipt.extractionOutcome]
            )
        }
    }

    public func latestRawFetchCache(for url: URL) throws -> StoredRawFetchCache? {
        let safeURL = HTTPMetadataRedactor.redact(url: url, headers: [:]).safeURL.absoluteString
        return try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT r.safe_url, r.redacted_response_metadata, b.*
                FROM raw_fetches r JOIN blobs b ON b.id=r.blob_id
                WHERE r.safe_url=? AND r.status_code BETWEEN 200 AND 299
                ORDER BY r.fetched_at DESC LIMIT 1
                """,
                arguments: [safeURL]
            ), let blobID = Self.identifier(BlobID.self, row["id"]),
               let retention = BlobRetentionClass(rawValue: row["retention_class"]),
               let finalURL = URL(string: row["safe_url"])
            else { return nil }
            let metadata: Data? = row["redacted_response_metadata"]
            let headers = try metadata.map { try decoder.decode([String: String].self, from: $0) } ?? [:]
            return StoredRawFetchCache(
                responseHeaders: headers,
                blob: StoredBlob(
                    id: blobID,
                    sha256: row["sha256"],
                    relativePath: row["relative_path"],
                    byteCount: row["byte_count"],
                    mediaType: row["media_type"],
                    retentionClass: retention,
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                ),
                finalURL: finalURL
            )
        }
    }

    @discardableResult
    public func tombstone(targetKind: String, targetID: String, deletionKind: DeletionKind, permittedMetadata: Data? = nil, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.items, .events, .blobs, .searchInputs]) { db in
            try db.execute(
                sql: """
                INSERT INTO tombstones (id, target_kind, target_id, deletion_kind, permitted_metadata_json, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(target_kind, target_id) DO UPDATE SET deletion_kind=excluded.deletion_kind,
                  permitted_metadata_json=excluded.permitted_metadata_json, created_at=excluded.created_at
                """,
                arguments: [UUID().uuidString.lowercased(), targetKind, targetID, deletionKind.rawValue, permittedMetadata, date.timeIntervalSince1970]
            )
            if targetKind == "item" {
                let state = deletionKind == .remoteDeletion ? "remoteDeletedRetained" : "tombstoned"
                try db.execute(sql: "UPDATE items SET user_deletion_state=? WHERE id=?", arguments: [state, targetID])
            } else if targetKind == "event" {
                try db.execute(sql: "UPDATE events SET is_tombstoned=1 WHERE id=?", arguments: [targetID])
            }
            if deletionKind != .remoteDeletion {
                try db.execute(sql: "DELETE FROM search_inputs WHERE stable_id=? AND kind=?", arguments: [targetID, targetKind])
            }
            let requiresContentPurge = deletionKind == .userPurge || deletionKind == .legalPolicyPurge || deletionKind == .connectorMandatedPurge
            if requiresContentPurge, targetKind == "item" {
                let endpointID = try String.fetchOne(db, sql: "SELECT endpoint_id FROM items WHERE id=?", arguments: [targetID])
                try db.execute(sql: "DELETE FROM item_assets WHERE item_revision_id IN (SELECT id FROM item_revisions WHERE item_id=?)", arguments: [targetID])
                try db.execute(sql: "UPDATE item_segments SET text='', embedding_input='' WHERE item_revision_id IN (SELECT id FROM item_revisions WHERE item_id=?)", arguments: [targetID])
                try db.execute(sql: "UPDATE item_revisions SET title='[Purged]', author=NULL, plain_text='', sanitized_html_blob_id=NULL, evidence_blob_id=NULL WHERE item_id=?", arguments: [targetID])
                if let endpointID { try db.execute(sql: "DELETE FROM raw_fetches WHERE endpoint_id=?", arguments: [endpointID]) }
                // Cache rows intentionally carry only input hashes. Clearing the cache is the only
                // safe targeted-purge behavior until no cache entry can be linked back to purged text.
                try db.execute(sql: "DELETE FROM ai_cache")
            } else if requiresContentPurge, targetKind == "event" {
                try db.execute(sql: "UPDATE event_revisions SET title='[Purged]', summary='' WHERE event_id=?", arguments: [targetID])
                try db.execute(sql: "UPDATE claims SET text='' WHERE event_revision_id IN (SELECT id FROM event_revisions WHERE event_id=?)", arguments: [targetID])
                try db.execute(sql: "DELETE FROM ai_cache")
            }
        }
    }

    @discardableResult
    public func expireRawFetches(now: Date = .now, policy: RawRetentionPolicy = RawRetentionPolicy()) throws -> Int {
        let cutoffs: [BlobRetentionClass: TimeInterval] = [
            .publicRaw30Days: Double(policy.publicDays) * 86_400,
            .privateRaw7Days: Double(policy.privateDays) * 86_400,
            .failedExtraction30Days: Double(policy.failedExtractionDays) * 86_400,
            .publicDiagnostic30Days: Double(policy.diagnosticDays) * 86_400,
            .privateDiagnostic7Days: Double(policy.privateDays) * 86_400,
            .cache30Days: 30 * 86_400,
        ]
        var deleted = 0
        _ = try mutate(domains: [.blobs]) { db in
            for (retention, age) in cutoffs {
                try db.execute(sql: "DELETE FROM raw_fetches WHERE retention_class=? AND fetched_at < ?", arguments: [retention.rawValue, now.addingTimeInterval(-age).timeIntervalSince1970])
                deleted += db.changesCount
            }
        }
        return deleted
    }

    @discardableResult
    public func markEventSeen(eventID: EventID, revisionID: EventRevisionID, ordinal: Int, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.readState]) { db in
            try db.execute(
                sql: """
                INSERT INTO event_read_states (event_id, last_seen_event_revision_id, last_seen_ordinal, last_seen_at, manual_unread)
                VALUES (?, ?, ?, ?, 0)
                ON CONFLICT(event_id) DO UPDATE SET last_seen_event_revision_id=excluded.last_seen_event_revision_id,
                  last_seen_ordinal=excluded.last_seen_ordinal, last_seen_at=excluded.last_seen_at, manual_unread=0
                """,
                arguments: [eventID.description, revisionID.description, ordinal, date.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func setEventManualUnread(eventID: EventID, unread: Bool, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.readState]) { db in
            try db.execute(
                sql: """
                INSERT INTO event_read_states (event_id, last_seen_event_revision_id, last_seen_ordinal, last_seen_at, manual_unread)
                VALUES (?, NULL, NULL, ?, ?)
                ON CONFLICT(event_id) DO UPDATE SET manual_unread=excluded.manual_unread,
                  last_seen_at=CASE WHEN excluded.manual_unread=1 THEN event_read_states.last_seen_at ELSE excluded.last_seen_at END
                """,
                arguments: [eventID.description, date.timeIntervalSince1970, unread]
            )
        }
    }

    @discardableResult
    public func setSourceFollowed(_ sourceID: SourceID, followed: Bool, at date: Date = .now) throws -> Bool {
        try setFollowState(table: "sources", id: sourceID.description, followed: followed, targetKind: "source", at: date, domains: [.sources, .library])
    }

    @discardableResult
    public func setEntityFollowed(_ entityID: EntityID, followed: Bool, at date: Date = .now) throws -> Bool {
        try setFollowState(table: "entities", id: entityID.description, followed: followed, targetKind: "entity", at: date, domains: [.entities, .library])
    }

    @discardableResult
    public func setTopicFollowed(_ topicID: TopicID, followed: Bool, at date: Date = .now) throws -> Bool {
        try setFollowState(table: "topics", id: topicID.description, followed: followed, targetKind: "topic", at: date, domains: [.topics, .library])
    }

    @discardableResult
    public func saveSourceCoverage(_ assertion: SourceCoverageAssertion) throws -> Bool {
        try mutate(domains: [.sources, .events, .digests]) { db in
            let supersedes = try String.fetchOne(
                db,
                sql: "SELECT id FROM source_coverage_assertions WHERE source_id=? AND is_current=1 ORDER BY effective_at DESC LIMIT 1",
                arguments: [assertion.sourceID.description]
            )
            try db.execute(sql: "UPDATE source_coverage_assertions SET is_current=0 WHERE source_id=? AND is_current=1", arguments: [assertion.sourceID.description])
            try db.execute(
                sql: "INSERT INTO source_coverage_assertions (id, source_id, ecosystem, provenance, confidence, rationale, effective_at, supersedes_id, is_current) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)",
                arguments: [assertion.id.uuidString.lowercased(), assertion.sourceID.description, assertion.ecosystem.rawValue, assertion.provenance.rawValue, assertion.confidence.value, assertion.rationale, assertion.effectiveAt.timeIntervalSince1970, supersedes]
            )
        }
    }

    @discardableResult
    public func setEventSaved(_ eventID: EventID, saved: Bool, folderID: UUID? = nil, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.library]) { db in
            if saved {
                try db.execute(
                    sql: "INSERT INTO saved_entries (id, target_kind, target_id, folder_id, tags_json, saved_at) VALUES (?, 'event', ?, ?, NULL, ?) ON CONFLICT(target_kind, target_id) DO UPDATE SET folder_id=excluded.folder_id, saved_at=excluded.saved_at",
                    arguments: [UUID().uuidString.lowercased(), eventID.description, folderID?.uuidString.lowercased(), date.timeIntervalSince1970]
                )
            } else {
                try db.execute(sql: "DELETE FROM saved_entries WHERE target_kind='event' AND target_id=?", arguments: [eventID.description])
            }
            try db.execute(
                sql: "INSERT INTO interactions (id, action, target_kind, target_id, created_at, metadata_json) VALUES (?, ?, 'event', ?, ?, NULL)",
                arguments: [UUID().uuidString.lowercased(), saved ? "save" : "unsave", eventID.description, date.timeIntervalSince1970]
            )
        }
    }

    public func savedEventIDs() throws -> Set<EventID> {
        try database.pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT target_id FROM saved_entries WHERE target_kind='event' ORDER BY saved_at DESC").compactMap { Self.identifier(EventID.self, $0) })
        }
    }

    @discardableResult
    public func recordHistory(targetKind: String, targetID: String, revisionID: String?, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.library]) { db in
            try db.execute(
                sql: "INSERT INTO history_entries (id, target_kind, target_id, revision_id, visited_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString.lowercased(), targetKind, targetID, revisionID, date.timeIntervalSince1970]
            )
        }
    }

    public func eventEvidence(eventID: EventID) throws -> [StoredEventEvidence] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT m.id, m.item_revision_id, m.item_segment_id, m.role, m.decision, m.confidence,
                       er.primary_membership_assertion_id, ir.title, ir.published_at,
                       seg.utf8_start, seg.utf8_length, seg.segment_hash, seg.text,
                       sr.display_name AS source_name
                FROM events e
                JOIN event_revisions er ON er.id=e.current_revision_id
                JOIN event_revision_memberships rm ON rm.event_revision_id=er.id
                JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
                JOIN item_revisions ir ON ir.id=m.item_revision_id
                JOIN item_segments seg ON seg.id=m.item_segment_id
                JOIN items i ON i.id=ir.item_id
                JOIN sources s ON s.id=i.source_id
                JOIN source_revisions sr ON sr.id=s.current_revision_id
                WHERE e.id=?
                ORDER BY CASE WHEN m.id=er.primary_membership_assertion_id THEN 0 ELSE 1 END,
                         COALESCE(ir.published_at, ir.fetched_at), m.created_at
                """,
                arguments: [eventID.description]
            ).map { row in
                guard
                    let id = Self.identifier(MembershipAssertionID.self, row["id"]),
                    let revisionID = Self.identifier(ItemRevisionID.self, row["item_revision_id"]),
                    let segmentID = Self.identifier(ItemSegmentID.self, row["item_segment_id"]),
                    let role = MembershipRole(rawValue: row["role"]),
                    let decision = MembershipDecision(rawValue: row["decision"])
                else { throw CrosscurrentStorageError.corruptRecord("Event evidence") }
                let hash: String = row["segment_hash"]
                return StoredEventEvidence(
                    id: id,
                    itemRevisionID: revisionID,
                    itemSegmentID: segmentID,
                    sourceName: row["source_name"],
                    title: row["title"],
                    excerpt: row["text"],
                    span: TextSpan(utf8Start: row["utf8_start"], utf8Length: row["utf8_length"], excerptHash: hash),
                    role: role,
                    decision: decision,
                    confidence: Confidence(row["confidence"]),
                    publishedAt: (row["published_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    isPrimary: (row["primary_membership_assertion_id"] as String?) == id.description
                )
            }
        }
    }

    public func eventRevisionHistory(eventID: EventID) throws -> [StoredEventRevisionSummary] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT r.id, r.ordinal, r.title, r.change_kind, r.created_at,
                       COUNT(rm.membership_assertion_id) AS evidence_count
                FROM event_revisions r
                LEFT JOIN event_revision_memberships rm ON rm.event_revision_id=r.id
                WHERE r.event_id=?
                GROUP BY r.id
                ORDER BY r.ordinal DESC
                """,
                arguments: [eventID.description]
            ).map { row in
                guard let id = Self.identifier(EventRevisionID.self, row["id"]), let kind = RevisionChangeKind(rawValue: row["change_kind"]) else {
                    throw CrosscurrentStorageError.corruptRecord("Event revision history")
                }
                return StoredEventRevisionSummary(id: id, ordinal: row["ordinal"], title: row["title"], changeKind: kind, createdAt: Date(timeIntervalSince1970: row["created_at"]), evidenceCount: row["evidence_count"])
            }
        }
    }

    @discardableResult
    public func enqueue(_ job: DurableJob) throws -> Bool {
        try mutate(domains: [.jobs], idempotencyKey: "enqueue:\(job.idempotencyKey)") { db in
            let now = Date.now.timeIntervalSince1970
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO jobs
                  (id, kind, input_hash, idempotency_key, payload, state, attempt_count, cancellation_requested,
                   retry_class, checkpoint, next_attempt_at, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, ?, ?)
                """,
                arguments: [job.id.description, job.kind, job.inputHash, job.idempotencyKey, job.payload, job.state.rawValue, job.attemptCount, job.checkpoint, job.nextAttemptAt.timeIntervalSince1970, now, now]
            )
        }
    }

    public func leaseNextJob(owner: String, eligibleKinds: Set<String>, duration: TimeInterval = 60, now: Date = .now) throws -> (DurableJob, JobLease)? {
        guard !eligibleKinds.isEmpty else { return nil }
        return try mutateValue(domains: [.jobs]) { db in
            let timestamp = now.timeIntervalSince1970
            try db.execute(
                sql: "UPDATE jobs SET state='pending', updated_at=? WHERE state='leased' AND id IN (SELECT job_id FROM job_leases WHERE expires_at <= ?)",
                arguments: [timestamp, timestamp]
            )
            try db.execute(sql: "DELETE FROM job_leases WHERE expires_at <= ?", arguments: [timestamp])
            let placeholders = Array(repeating: "?", count: eligibleKinds.count).joined(separator: ",")
            var arguments: StatementArguments = [timestamp]
            arguments += StatementArguments(eligibleKinds.sorted())
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE state IN ('pending','failed') AND next_attempt_at <= ? AND kind IN (\(placeholders)) ORDER BY next_attempt_at, created_at LIMIT 1",
                arguments: arguments
            ) else { return nil }

            let job = try Self.decodeJob(row: row)
            let lease = JobLease(jobID: job.id, owner: owner, expiresAt: now.addingTimeInterval(duration))
            try db.execute(
                sql: "INSERT INTO job_leases (job_id, owner, token, acquired_at, expires_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [job.id.description, owner, lease.token.uuidString.lowercased(), lease.acquiredAt.timeIntervalSince1970, lease.expiresAt.timeIntervalSince1970]
            )
            try db.execute(
                sql: "UPDATE jobs SET state='leased', attempt_count=attempt_count+1, updated_at=? WHERE id=?",
                arguments: [timestamp, job.id.description]
            )
            var leasedJob = job
            leasedJob.state = .leased
            leasedJob.attemptCount += 1
            return (leasedJob, lease)
        } ?? nil
    }

    /// Leases a specific durable job. Foreground commands use this so a user-initiated
    /// refresh cannot accidentally execute an older background refresh first.
    public func leaseJob(id: JobID, owner: String, duration: TimeInterval = 60, now: Date = .now) throws -> (DurableJob, JobLease)? {
        try mutateValue(domains: [.jobs]) { db in
            let timestamp = now.timeIntervalSince1970
            try db.execute(
                sql: "UPDATE jobs SET state='pending', updated_at=? WHERE id=? AND state='leased' AND EXISTS (SELECT 1 FROM job_leases WHERE job_id=jobs.id AND expires_at <= ?)",
                arguments: [timestamp, id.description, timestamp]
            )
            try db.execute(sql: "DELETE FROM job_leases WHERE job_id=? AND expires_at <= ?", arguments: [id.description, timestamp])
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM jobs WHERE id=? AND state IN ('pending','failed') AND next_attempt_at <= ?",
                arguments: [id.description, timestamp]
            ) else { return nil }

            let job = try Self.decodeJob(row: row)
            let lease = JobLease(jobID: job.id, owner: owner, expiresAt: now.addingTimeInterval(duration))
            try db.execute(
                sql: "INSERT INTO job_leases (job_id, owner, token, acquired_at, expires_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [job.id.description, owner, lease.token.uuidString.lowercased(), lease.acquiredAt.timeIntervalSince1970, lease.expiresAt.timeIntervalSince1970]
            )
            try db.execute(
                sql: "UPDATE jobs SET state='leased', attempt_count=attempt_count+1, updated_at=? WHERE id=?",
                arguments: [timestamp, job.id.description]
            )
            var leasedJob = job
            leasedJob.state = .leased
            leasedJob.attemptCount += 1
            return (leasedJob, lease)
        } ?? nil
    }

    @discardableResult
    public func completeJob(_ lease: JobLease, checkpoint: Data? = nil, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.jobs], idempotencyKey: "complete:\(lease.token.uuidString.lowercased())") { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM job_leases WHERE job_id=? AND owner=? AND token=?",
                arguments: [lease.jobID.description, lease.owner, lease.token.uuidString.lowercased()]
            ) ?? 0
            guard count == 1 else { throw CrosscurrentStorageError.jobLeaseUnavailable }
            try db.execute(
                sql: "UPDATE jobs SET state='completed', checkpoint=?, updated_at=? WHERE id=?",
                arguments: [checkpoint, date.timeIntervalSince1970, lease.jobID.description]
            )
            try db.execute(sql: "DELETE FROM job_leases WHERE job_id=?", arguments: [lease.jobID.description])
        }
    }

    @discardableResult
    public func renewLease(_ lease: JobLease, duration: TimeInterval = 60, at date: Date = .now) throws -> JobLease {
        try mutateValue(domains: [.jobs]) { db in
            let expiry = date.addingTimeInterval(duration)
            try db.execute(
                sql: "UPDATE job_leases SET expires_at=? WHERE job_id=? AND owner=? AND token=?",
                arguments: [expiry.timeIntervalSince1970, lease.jobID.description, lease.owner, lease.token.uuidString.lowercased()]
            )
            guard db.changesCount == 1 else { throw CrosscurrentStorageError.jobLeaseUnavailable }
            var renewed = lease
            renewed.expiresAt = expiry
            return renewed
        }!
    }

    public func cancellationRequested(for lease: JobLease) throws -> Bool {
        try database.pool.read { db in
            let valid = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_leases WHERE job_id=? AND owner=? AND token=?", arguments: [lease.jobID.description, lease.owner, lease.token.uuidString.lowercased()]) ?? 0
            guard valid == 1 else { throw CrosscurrentStorageError.jobLeaseUnavailable }
            return try Bool.fetchOne(db, sql: "SELECT cancellation_requested FROM jobs WHERE id=?", arguments: [lease.jobID.description]) ?? false
        }
    }

    @discardableResult
    public func failJob(_ lease: JobLease, retryClass: String, retryAt: Date, checkpoint: Data? = nil) throws -> Bool {
        try mutate(domains: [.jobs]) { db in
            let valid = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM job_leases WHERE job_id=? AND owner=? AND token=?", arguments: [lease.jobID.description, lease.owner, lease.token.uuidString.lowercased()]) ?? 0
            guard valid == 1 else { throw CrosscurrentStorageError.jobLeaseUnavailable }
            try db.execute(sql: "UPDATE jobs SET state='failed', retry_class=?, checkpoint=?, next_attempt_at=?, updated_at=? WHERE id=?", arguments: [retryClass, checkpoint, retryAt.timeIntervalSince1970, Date.now.timeIntervalSince1970, lease.jobID.description])
            try db.execute(sql: "DELETE FROM job_leases WHERE job_id=?", arguments: [lease.jobID.description])
        }
    }

    public func recentEventRevisions(limit: Int = 100) throws -> [EventRevision] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT r.* FROM event_revisions r
                JOIN events e ON e.current_revision_id = r.id
                WHERE e.is_tombstoned = 0 AND e.lifecycle_state='active'
                ORDER BY COALESCE(r.ended_at, r.started_at, r.created_at) DESC
                LIMIT ?
                """,
                arguments: [max(1, min(limit, 500))]
            )
            return try rows.map(Self.decodeEventRevision)
        }
    }

    public func currentItemDeduplicationEvidence(limit: Int = 1_000) throws -> [CurrentItemDeduplicationEvidence] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT i.id AS item_id, i.source_id, i.connector_external_id, i.canonical_key,
                       ir.id AS revision_id, ir.title, ir.author, ir.plain_text, ir.content_hash,
                       ir.language_code, ir.published_at
                FROM items i JOIN item_revisions ir ON ir.id=i.current_revision_id
                WHERE i.remote_state != 'deleted' AND i.user_deletion_state='active'
                ORDER BY COALESCE(ir.published_at, ir.fetched_at) DESC
                LIMIT ?
                """,
                arguments: [max(1, min(limit, 10_000))]
            )
            return try rows.map { row in
                guard let itemID = Self.identifier(ItemID.self, row["item_id"]),
                      let revisionID = Self.identifier(ItemRevisionID.self, row["revision_id"]),
                      let sourceID = Self.identifier(SourceID.self, row["source_id"])
                else { throw CrosscurrentStorageError.corruptRecord("CurrentItemDeduplicationEvidence") }
                let canonical: String = row["canonical_key"]
                return CurrentItemDeduplicationEvidence(
                    itemID: itemID,
                    revisionID: revisionID,
                    sourceID: sourceID,
                    externalID: row["connector_external_id"],
                    canonicalURL: URL(string: canonical).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    title: row["title"],
                    author: row["author"],
                    text: row["plain_text"],
                    contentHash: row["content_hash"],
                    languageCode: row["language_code"],
                    publishedAt: (row["published_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    @discardableResult
    public func saveItemRelation(
        from fromItemID: ItemID,
        to toItemID: ItemID,
        relationship: String,
        confidence: Confidence,
        groupsAsDuplicate: Bool,
        at date: Date = .now
    ) throws -> Bool {
        guard fromItemID != toItemID else { return false }
        let ordered = [fromItemID.description, toItemID.description].sorted()
        let relationID = "relation:\(ordered[0]):\(ordered[1]):\(relationship)"
        return try mutate(domains: [.items, .events]) { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO item_relations (id, from_item_id, to_item_id, relationship, confidence) VALUES (?, ?, ?, ?, ?)",
                arguments: [relationID, ordered[0], ordered[1], relationship, confidence.value]
            )
            guard groupsAsDuplicate else { return }
            let existingGroup: String? = try String.fetchOne(
                db,
                sql: "SELECT group_id FROM duplicate_group_members WHERE item_id IN (?, ?) ORDER BY group_id LIMIT 1",
                arguments: [ordered[0], ordered[1]]
            )
            let groupID = existingGroup ?? "duplicate:\(ordered[0]):\(ordered[1])"
            if existingGroup == nil {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO duplicate_groups (id, canonical_item_id, created_at) VALUES (?, ?, ?)",
                    arguments: [groupID, ordered[0], date.timeIntervalSince1970]
                )
            }
            for itemID in ordered {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO duplicate_group_members (group_id, item_id, classification) VALUES (?, ?, ?)",
                    arguments: [groupID, itemID, relationship]
                )
            }
        }
    }

    public func pendingEvidenceSegments(limit: Int = 250) throws -> [PendingEvidenceSegment] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT i.id AS item_id, i.source_id, i.canonical_key, ep.account_id, ep.connector_kind,
                       EXISTS(
                         SELECT 1 FROM source_entities se
                         WHERE se.source_id=i.source_id
                           AND se.role IN ('represents','publishedBy','officialFor')
                           AND se.confidence >= 0.8
                       ) AS source_is_official,
                       ir.id AS revision_id, ir.ordinal AS revision_ordinal, ir.title, ir.author,
                       ir.published_at, ir.modified_at, ir.fetched_at, ir.language_code,
                       ir.plain_text, ir.content_hash AS revision_hash, ir.revision_reason,
                       seg.id AS segment_id, seg.lineage_id, seg.kind AS segment_kind,
                       seg.utf8_start, seg.utf8_length, seg.heading_path, seg.segment_hash,
                       seg.text AS segment_text, sr.display_name AS source_name
                FROM items i
                JOIN item_revisions ir ON ir.id=i.current_revision_id
                JOIN item_segments seg ON seg.item_revision_id=ir.id
                JOIN sources src ON src.id=i.source_id
                JOIN source_revisions sr ON sr.id=src.current_revision_id
                JOIN source_endpoints ep ON ep.id=i.endpoint_id
                WHERE i.remote_state != 'deleted' AND i.user_deletion_state='active'
                  AND NOT EXISTS (
                    SELECT 1 FROM event_membership_assertions m
                    WHERE m.item_revision_id=ir.id AND m.item_segment_id=seg.id
                      AND m.decision IN ('accepted','provisional')
                  )
                ORDER BY COALESCE(ir.published_at, ir.fetched_at) ASC, seg.ordinal ASC
                LIMIT ?
                """,
                arguments: [max(1, min(limit, 2_000))]
            )
            return try rows.map { row in
                guard
                    let itemID = Self.identifier(ItemID.self, row["item_id"]),
                    let sourceID = Self.identifier(SourceID.self, row["source_id"]),
                    let revisionID = Self.identifier(ItemRevisionID.self, row["revision_id"]),
                    let segmentID = Self.identifier(ItemSegmentID.self, row["segment_id"]),
                    let lineageID = Self.identifier(SegmentLineageID.self, row["lineage_id"]),
                    let segmentKind = SegmentKind(rawValue: row["segment_kind"]),
                    let changeKind = RevisionChangeKind(rawValue: row["revision_reason"])
                else { throw CrosscurrentStorageError.corruptRecord("PendingEvidenceSegment") }
                let revision = ItemRevision(
                    id: revisionID,
                    itemID: itemID,
                    ordinal: row["revision_ordinal"],
                    title: row["title"],
                    author: row["author"],
                    publishedAt: (row["published_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    modifiedAt: (row["modified_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    fetchedAt: Date(timeIntervalSince1970: row["fetched_at"]),
                    languageCode: row["language_code"],
                    text: row["plain_text"],
                    sanitizedHTML: nil,
                    contentHash: row["revision_hash"],
                    changeKind: changeKind
                )
                let segmentHash: String = row["segment_hash"]
                let segment = ItemSegment(
                    id: segmentID,
                    lineageID: lineageID,
                    itemRevisionID: revisionID,
                    kind: segmentKind,
                    headingPath: (row["heading_path"] as String?).map { $0.components(separatedBy: " / ") } ?? [],
                    span: TextSpan(utf8Start: row["utf8_start"], utf8Length: row["utf8_length"], excerptHash: segmentHash),
                    text: row["segment_text"],
                    contentHash: segmentHash
                )
                let canonical: String = row["canonical_key"]
                return PendingEvidenceSegment(
                    itemID: itemID,
                    itemRevision: revision,
                    segment: segment,
                    sourceID: sourceID,
                    sourceName: row["source_name"],
                    canonicalURL: URL(string: canonical).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    accountID: Self.identifier(ConnectorAccountID.self, row["account_id"] as String?),
                    connector: ConnectorKind(rawValue: row["connector_kind"]) ?? .website,
                    isOfficialSource: row["source_is_official"],
                    entityIDs: Set(try String.fetchAll(db, sql: "SELECT DISTINCT entity_id FROM item_entity_mentions WHERE item_revision_id=? AND item_segment_id=?", arguments: [revisionID.description, segmentID.description]).compactMap { Self.identifier(EntityID.self, $0) }),
                    topicIDs: Set(try String.fetchAll(db, sql: "SELECT DISTINCT topic_id FROM item_topic_assertions WHERE item_revision_id=? AND (item_segment_id IS NULL OR item_segment_id=?)", arguments: [revisionID.description, segmentID.description]).compactMap { Self.identifier(TopicID.self, $0) }),
                    independenceGroup: try String.fetchOne(db, sql: "SELECT group_id FROM duplicate_group_members WHERE item_id=? LIMIT 1", arguments: [itemID.description]) ?? sourceID.description
                )
            }
        }
    }

    public func currentEventAggregates(limit: Int = 500) throws -> [StoredEventAggregate] {
        try database.pool.read { db in
            let eventRows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.id AS stable_event_id, e.created_at AS event_created_at, e.is_tombstoned, r.*
                FROM events e JOIN event_revisions r ON r.id=e.current_revision_id
                WHERE e.is_tombstoned=0 AND e.lifecycle_state='active'
                ORDER BY COALESCE(r.ended_at, r.started_at, r.created_at) DESC LIMIT ?
                """,
                arguments: [max(1, min(limit, 2_000))]
            )
            return try eventRows.map { row in
                guard let eventID = Self.identifier(EventID.self, row["stable_event_id"]) else {
                    throw CrosscurrentStorageError.corruptRecord("Event")
                }
                let revision = try Self.decodeEventRevision(row: row)
                let memberships = try Self.memberships(eventRevisionID: revision.id, db: db)
                return StoredEventAggregate(
                    event: Event(id: eventID, currentRevisionID: revision.id, createdAt: Date(timeIntervalSince1970: row["event_created_at"]), isTombstoned: row["is_tombstoned"]),
                    revision: revision,
                    memberships: memberships
                )
            }
        }
    }

    public func clusteringSignals(eventRevisionID: EventRevisionID) throws -> StoredClusteringSignals {
        try database.pool.read { db in
            let entityValues = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT iem.entity_id
                FROM event_revision_memberships erm
                JOIN event_membership_assertions ema ON ema.id=erm.membership_assertion_id
                JOIN item_entity_mentions iem ON iem.item_revision_id=ema.item_revision_id
                  AND iem.item_segment_id=ema.item_segment_id
                WHERE erm.event_revision_id=?
                """,
                arguments: [eventRevisionID.description]
            )
            let topicValues = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT topic_id FROM event_topic_assertions WHERE event_revision_id=?",
                arguments: [eventRevisionID.description]
            )
            return StoredClusteringSignals(
                entityIDs: Set(entityValues.compactMap { Self.identifier(EntityID.self, $0) }),
                topicIDs: Set(topicValues.compactMap { Self.identifier(TopicID.self, $0) })
            )
        }
    }

    public func primarySourceSignals(membershipID: MembershipAssertionID) throws -> StoredPrimarySourceSignals? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT ep.connector_kind, i.canonical_key, ir.published_at, LENGTH(ir.plain_text) AS text_length,
                       ema.provenance,
                       EXISTS(
                         SELECT 1 FROM source_entities se
                         WHERE se.source_id=i.source_id
                           AND se.role IN ('represents','publishedBy','officialFor')
                           AND se.confidence >= 0.8
                       ) AS is_official
                FROM event_membership_assertions ema
                JOIN item_revisions ir ON ir.id=ema.item_revision_id
                JOIN items i ON i.id=ir.item_id
                JOIN source_endpoints ep ON ep.id=i.endpoint_id
                WHERE ema.id=?
                """,
                arguments: [membershipID.description]
            ), let connector = ConnectorKind(rawValue: row["connector_kind"]),
               let provenance = AssertionProvenance(rawValue: row["provenance"])
            else { return nil }
            let canonical: String = row["canonical_key"]
            return StoredPrimarySourceSignals(
                connector: connector,
                isOfficialRelationship: row["is_official"],
                canonicalURL: URL(string: canonical),
                publishedAt: (row["published_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                textLength: row["text_length"],
                provenance: provenance
            )
        }
    }

    public func coverageComparison(eventID: EventID) throws -> StoredCoverageComparison {
        try database.pool.read { db in
            guard let currentRevision: String = try String.fetchOne(db, sql: "SELECT current_revision_id FROM events WHERE id=?", arguments: [eventID.description]) else {
                return StoredCoverageComparison()
            }
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT ema.id, ema.independence_group, ca.ecosystem, sr.display_name,
                       ir.title, ir.published_at, seg.text,
                       CASE WHEN er.primary_membership_assertion_id=ema.id THEN 1 ELSE 0 END AS is_primary
                FROM event_revision_memberships erm
                JOIN event_revisions er ON er.id=erm.event_revision_id
                JOIN event_membership_assertions ema ON ema.id=erm.membership_assertion_id
                JOIN item_revisions ir ON ir.id=ema.item_revision_id
                JOIN item_segments seg ON seg.id=ema.item_segment_id
                JOIN items i ON i.id=ir.item_id
                JOIN sources s ON s.id=i.source_id
                JOIN source_revisions sr ON sr.id=s.current_revision_id
                JOIN source_coverage_assertions ca ON ca.source_id=i.source_id AND ca.is_current=1
                WHERE erm.event_revision_id=? AND ca.ecosystem IN ('chinaFocused','globalFocused')
                ORDER BY ca.ecosystem, COALESCE(ir.published_at, ir.fetched_at), sr.display_name
                """,
                arguments: [currentRevision]
            )
            let evidence = try rows.map { row -> StoredCoverageEvidence in
                guard let id = Self.identifier(MembershipAssertionID.self, row["id"]),
                      let ecosystem = CoverageEcosystem(rawValue: row["ecosystem"])
                else { throw CrosscurrentStorageError.corruptRecord("CoverageComparison") }
                let excerpt: String = row["text"]
                return StoredCoverageEvidence(
                    id: id,
                    ecosystem: ecosystem,
                    independenceGroup: (row["independence_group"] as String?) ?? row["display_name"],
                    sourceName: row["display_name"],
                    title: row["title"],
                    excerpt: String(excerpt.prefix(360)),
                    publishedAt: (row["published_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
                    isPrimary: row["is_primary"]
                )
            }
            return StoredCoverageComparison(
                chinaFocused: evidence.filter { $0.ecosystem == .chinaFocused },
                globalFocused: evidence.filter { $0.ecosystem == .globalFocused }
            )
        }
    }

    public func currentEventSnapshots(limit: Int = 500) throws -> [StoredEventSnapshot] {
        try database.pool.read { db in
            let eventRows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.id AS stable_event_id, e.created_at AS event_created_at, e.is_tombstoned, r.*
                FROM events e JOIN event_revisions r ON r.id=e.current_revision_id
                WHERE e.is_tombstoned=0 AND e.lifecycle_state='active'
                ORDER BY COALESCE(r.ended_at, r.started_at, r.created_at) DESC LIMIT ?
                """,
                arguments: [max(1, min(limit, 2_000))]
            )
            return try eventRows.map { row in
                guard let eventID = Self.identifier(EventID.self, row["stable_event_id"]) else { throw CrosscurrentStorageError.corruptRecord("Event") }
                let revision = try Self.decodeEventRevision(row: row)
                let memberships = try Self.memberships(eventRevisionID: revision.id, db: db)
                guard let primaryID = revision.primaryMembershipAssertionID ?? memberships.first?.id,
                      let primary = try Row.fetchOne(
                        db,
                        sql: """
                        SELECT m.item_revision_id, ir.plain_text, ir.sanitized_html_blob_id,
                               b.sha256 AS html_sha256, b.relative_path AS html_relative_path,
                               b.byte_count AS html_byte_count, i.source_id, i.canonical_key,
                               ep.account_id, ep.content_privacy,
                               sr.display_name AS source_name
                        FROM event_membership_assertions m
                        JOIN item_revisions ir ON ir.id=m.item_revision_id
                        JOIN items i ON i.id=ir.item_id
                        JOIN source_endpoints ep ON ep.id=i.endpoint_id
                        JOIN sources src ON src.id=i.source_id
                        JOIN source_revisions sr ON sr.id=src.current_revision_id
                        LEFT JOIN blobs b ON b.id=ir.sanitized_html_blob_id
                        WHERE m.id=?
                        """,
                        arguments: [primaryID.description]
                      ),
                      let primaryRevisionID = Self.identifier(ItemRevisionID.self, primary["item_revision_id"]),
                      let primarySourceID = Self.identifier(SourceID.self, primary["source_id"]),
                      let contentPrivacy = ContentPrivacy(rawValue: primary["content_privacy"])
                else { throw CrosscurrentStorageError.corruptRecord("Event primary membership") }

                let counts = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(DISTINCT i.source_id) AS source_count,
                           COUNT(DISTINCT COALESCE(m.independence_group, i.source_id)) AS independent_count
                    FROM event_revision_memberships rm
                    JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
                    JOIN item_revisions ir ON ir.id=m.item_revision_id
                    JOIN items i ON i.id=ir.item_id
                    WHERE rm.event_revision_id=? AND m.decision IN ('accepted','provisional')
                    """,
                    arguments: [revision.id.description]
                )
                let topicNames = try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT tr.name FROM event_topic_assertions a
                    JOIN topics t ON t.id=a.topic_id JOIN topic_revisions tr ON tr.id=t.current_revision_id
                    WHERE a.event_revision_id=? ORDER BY tr.name
                    """,
                    arguments: [revision.id.description]
                )
                let followedTopics = try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT tr.name FROM event_topic_assertions a
                    JOIN topics t ON t.id=a.topic_id AND t.is_followed=1
                    JOIN topic_revisions tr ON tr.id=t.current_revision_id
                    WHERE a.event_revision_id=? ORDER BY tr.name
                    """,
                    arguments: [revision.id.description]
                )
                let people = try String.fetchAll(
                    db,
                    sql: """
                    SELECT DISTINCT er.display_name FROM event_revision_memberships rm
                    JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
                    JOIN item_revisions ir ON ir.id=m.item_revision_id JOIN items i ON i.id=ir.item_id
                    JOIN source_entities se ON se.source_id=i.source_id
                    JOIN entities en ON en.id=se.entity_id AND en.kind='person' AND en.is_followed=1
                    JOIN entity_revisions er ON er.id=en.current_revision_id
                    WHERE rm.event_revision_id=? ORDER BY er.display_name
                    """,
                    arguments: [revision.id.description]
                )
                let coverageRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT ca.ecosystem, COUNT(DISTINCT COALESCE(m.independence_group, i.source_id)) AS group_count
                    FROM event_revision_memberships rm
                    JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
                    JOIN item_revisions ir ON ir.id=m.item_revision_id JOIN items i ON i.id=ir.item_id
                    JOIN source_coverage_assertions ca ON ca.source_id=i.source_id AND ca.is_current=1
                    WHERE rm.event_revision_id=? AND ca.ecosystem IN ('chinaFocused','globalFocused')
                    GROUP BY ca.ecosystem
                    """,
                    arguments: [revision.id.description]
                )
                let coverageCounts = Dictionary(uniqueKeysWithValues: coverageRows.map { ($0["ecosystem"] as String, $0["group_count"] as Int) })
                let hasFollowedSource = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM event_revision_memberships rm
                      JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
                      JOIN item_revisions ir ON ir.id=m.item_revision_id
                      JOIN items i ON i.id=ir.item_id JOIN sources s ON s.id=i.source_id
                      WHERE rm.event_revision_id=? AND s.is_followed=1
                    )
                    """,
                    arguments: [revision.id.description]
                ) ?? false
                let isSaved = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM saved_entries WHERE target_kind='event' AND target_id=?)", arguments: [eventID.description]) ?? false
                let velocityRow = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(DISTINCT CASE WHEN COALESCE(ir.published_at, ir.fetched_at) >= ? THEN COALESCE(m.independence_group, i.source_id) END) AS recent_groups,
                           COUNT(DISTINCT CASE WHEN COALESCE(ir.published_at, ir.fetched_at) < ? THEN COALESCE(m.independence_group, i.source_id) END) AS prior_groups
                    FROM event_revision_memberships rm
                    JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
                    JOIN item_revisions ir ON ir.id=m.item_revision_id JOIN items i ON i.id=ir.item_id
                    WHERE rm.event_revision_id=?
                    """,
                    arguments: [Date.now.addingTimeInterval(-86_400).timeIntervalSince1970, Date.now.addingTimeInterval(-86_400).timeIntervalSince1970, revision.id.description]
                )
                let recentGroups: Int = velocityRow?["recent_groups"] ?? 0
                let priorGroups: Int = velocityRow?["prior_groups"] ?? 0
                let trendVelocity = recentGroups >= 2 ? min(1, Double(recentGroups) / max(2, Double(priorGroups) / 7)) : 0
                let readRow = try Row.fetchOne(db, sql: "SELECT * FROM event_read_states WHERE event_id=?", arguments: [eventID.description])
                let readState = EventReadState(
                    lastSeenRevisionID: Self.identifier(EventRevisionID.self, readRow?["last_seen_event_revision_id"] as String?),
                    lastSeenOrdinal: readRow?["last_seen_ordinal"] as Int?,
                    manualUnread: (readRow?["manual_unread"] as Bool?) ?? false,
                    lastSeenAt: (readRow?["last_seen_at"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
                let canonical: String = primary["canonical_key"]
                let readerHTML: String? = {
                    guard let relativePath = primary["html_relative_path"] as String?,
                          let expectedHash = primary["html_sha256"] as String?,
                          let expectedCount = primary["html_byte_count"] as Int?
                    else { return nil }
                    let url = database.locations.blobs.appending(path: relativePath)
                    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                          data.count == expectedCount,
                          HTTPMetadataRedactor.digest(data) == expectedHash
                    else { return nil }
                    return String(data: data, encoding: .utf8)
                }()
                let aggregate = StoredEventAggregate(
                    event: Event(id: eventID, currentRevisionID: revision.id, createdAt: Date(timeIntervalSince1970: row["event_created_at"]), isTombstoned: false),
                    revision: revision,
                    memberships: memberships
                )
                return StoredEventSnapshot(
                    aggregate: aggregate,
                    primaryItemRevisionID: primaryRevisionID,
                    primarySourceID: primarySourceID,
                    contentPrivacy: contentPrivacy,
                    primarySourceName: primary["source_name"],
                    sourceCount: counts?["source_count"] ?? 0,
                    independentSourceCount: counts?["independent_count"] ?? 0,
                    topics: topicNames,
                    followedTopics: followedTopics,
                    followedPeople: people,
                    hasFollowedSource: hasFollowedSource,
                    isSaved: isSaved,
                    primaryAuthority: revision.primaryReasonTrace.contains(where: { $0.contains("first-party") || $0.contains("official repository") || $0.contains("paper record") }) ? 1 : 0.65,
                    trendVelocity: trendVelocity,
                    readerText: primary["plain_text"],
                    readerHTML: readerHTML,
                    originalURL: URL(string: canonical).flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil },
                    originalAccountID: Self.identifier(ConnectorAccountID.self, primary["account_id"] as String?),
                    chinaGlobalCoverageSufficient: coverageCounts[CoverageEcosystem.chinaFocused.rawValue, default: 0] >= 2 && coverageCounts[CoverageEcosystem.globalFocused.rawValue, default: 0] >= 2,
                    readStatus: readState.status(currentRevisionID: revision.id, currentOrdinal: revision.ordinal, isReaderVisible: revision.changeKind.isReaderVisible)
                )
            }
        }
    }

    public func digestState(briefingDay: Date) throws -> StoredDigestState? {
        try database.pool.read { db in
            let day = Self.dayFormatter.string(from: briefingDay)
            guard let digestRow = try Row.fetchOne(db, sql: "SELECT * FROM digests WHERE briefing_day=?", arguments: [day]),
                  let digestID = Self.identifier(DigestID.self, digestRow["id"]),
                  let currentRevisionID = Self.identifier(DigestRevisionID.self, digestRow["current_revision_id"])
            else { return nil }
            let revisions = try Row.fetchAll(db, sql: "SELECT * FROM digest_revisions WHERE digest_id=? ORDER BY created_at", arguments: [digestID.description])
            guard let first = revisions.first,
                  let initialID = Self.identifier(DigestRevisionID.self, first["id"]),
                  let latestRow = revisions.first(where: { ($0["id"] as String) == currentRevisionID.description })
            else { throw CrosscurrentStorageError.corruptRecord("Digest") }
            let latest = try Self.decodeDigestRevision(row: latestRow, db: db)
            let completed = Set(revisions.compactMap { row -> String? in
                guard (row["reason"] as String) == DigestRevisionReason.additionalBriefing.rawValue else { return nil }
                let date = Date(timeIntervalSince1970: row["created_at"] as Double)
                return Self.briefingTimeFormatter.string(from: date)
            })
            return StoredDigestState(
                digest: Digest(id: digestID, briefingDay: briefingDay, currentRevisionID: currentRevisionID),
                initialRevisionID: initialID,
                latestRevision: latest,
                completedAdditionalBriefingKeys: completed
            )
        }
    }

    public func preferenceData(forKey key: String) throws -> Data? {
        try database.pool.read { db in
            try Data.fetchOne(db, sql: "SELECT value_json FROM app_preferences WHERE key=?", arguments: [key])
        }
    }

    @discardableResult
    public func savePreferenceData(_ value: Data, forKey key: String, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.digests], idempotencyKey: nil) { db in
            try db.execute(
                sql: "INSERT INTO app_preferences (key, value_json, updated_at) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET value_json=excluded.value_json, updated_at=excluded.updated_at",
                arguments: [key, value, date.timeIntervalSince1970]
            )
        }
    }

    public func searchDocuments(includeHistory: Bool = true) throws -> [StoredSearchDocument] {
        try database.pool.read { db in
            var output = try Row.fetchAll(db, sql: "SELECT * FROM search_inputs ORDER BY kind, stable_id").map { row in
                StoredSearchDocument(stableID: row["stable_id"], kind: row["kind"], revisionID: row["current_revision_id"], languageCode: row["language_code"], title: row["title"], body: row["body"], isHistorical: false)
            }
            guard includeHistory else { return output }
            output += try Row.fetchAll(
                db,
                sql: """
                SELECT ir.item_id AS stable_id, 'item' AS kind, ir.id AS revision_id,
                       ir.language_code, ir.title, ir.plain_text AS body
                FROM item_revisions ir JOIN items i ON i.id=ir.item_id
                WHERE ir.id != i.current_revision_id
                UNION ALL
                SELECT er.event_id, 'event', er.id, NULL, er.title, er.summary
                FROM event_revisions er JOIN events e ON e.id=er.event_id
                WHERE er.id != e.current_revision_id OR e.lifecycle_state != 'active'
                UNION ALL
                SELECT sr.source_id, 'source', sr.id, NULL, sr.display_name, COALESCE(sr.summary, '')
                FROM source_revisions sr JOIN sources s ON s.id=sr.source_id
                WHERE sr.id != s.current_revision_id
                UNION ALL
                SELECT er.entity_id, en.kind, er.id, NULL, er.display_name, COALESCE(er.summary, '')
                FROM entity_revisions er JOIN entities en ON en.id=er.entity_id
                WHERE er.id != en.current_revision_id
                UNION ALL
                SELECT tr.topic_id, 'topic', tr.id, NULL, tr.name, COALESCE(tr.summary, '')
                FROM topic_revisions tr JOIN topics t ON t.id=tr.topic_id
                WHERE tr.id != t.current_revision_id
                """
            ).map { row in
                StoredSearchDocument(stableID: row["stable_id"], kind: row["kind"], revisionID: row["revision_id"], languageCode: row["language_code"], title: row["title"], body: row["body"], isHistorical: true)
            }
            return output
        }
    }

    public func providerConfigurations() throws -> [ProviderConfigurationRecord] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM provider_configs ORDER BY display_name").map { row in
                ProviderConfigurationRecord(
                    id: row["id"],
                    kind: row["provider_kind"],
                    displayName: row["display_name"],
                    keychainReference: row["keychain_reference"],
                    enabled: row["enabled"],
                    configuration: row["configuration_json"]
                )
            }
        }
    }

    public func cachedAICompletion(cacheKey: String, now: Date = .now) throws -> StoredAICompletion? {
        try database.pool.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT response FROM ai_cache WHERE cache_key=? AND (expires_at IS NULL OR expires_at > ?)",
                arguments: [cacheKey, now.timeIntervalSince1970]
            ) else { return nil }
            return try decoder.decode(StoredAICompletion.self, from: data)
        }
    }

    @discardableResult
    public func saveAICompletion(_ completion: StoredAICompletion, run: GenerationRun, cacheKey: String, expiresAt: Date? = nil) throws -> Bool {
        let response = try encoder.encode(completion)
        let usage = try encoder.encode(["inputTokens": completion.inputTokens, "outputTokens": completion.outputTokens])
        return try mutate(domains: [.prompts]) { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO generation_runs (id, task, provider_id, model_id, prompt_revision_id, input_hash, policy_decision, consent_revision_id, usage_json, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                arguments: [run.id.description, run.task.rawValue, run.providerID, run.modelID, run.promptRevisionID.description, run.inputHash, run.policyDecision, run.consentRevisionID?.uuidString.lowercased(), usage, run.createdAt.timeIntervalSince1970]
            )
            try db.execute(
                sql: "INSERT INTO ai_cache (cache_key, provider_id, model_id, prompt_revision_id, policy_decision, response, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(cache_key) DO UPDATE SET response=excluded.response, created_at=excluded.created_at, expires_at=excluded.expires_at",
                arguments: [cacheKey, run.providerID, run.modelID, run.promptRevisionID.description, run.policyDecision, response, run.createdAt.timeIntervalSince1970, expiresAt?.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func recordConsent(providerID: String, sourceID: SourceID? = nil, privacy: ContentPrivacy, allowedTasks: Set<AITask>, allowed: Bool, at date: Date = .now) throws -> UUID? {
        var revisionID: UUID?
        _ = try mutate(domains: [.accounts]) { db in
            try db.execute(
                sql: "UPDATE consent_revisions SET revoked_at=? WHERE provider_id=? AND source_id IS ? AND content_privacy=? AND revoked_at IS NULL",
                arguments: [date.timeIntervalSince1970, providerID, sourceID?.description, privacy.rawValue]
            )
            guard allowed else { return }
            let id = UUID()
            revisionID = id
            let tasks = try encoder.encode(allowedTasks.map(\.rawValue).sorted())
            try db.execute(
                sql: "INSERT INTO consent_revisions (id, source_id, provider_id, content_privacy, allowed_tasks_json, granted_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, NULL)",
                arguments: [id.uuidString.lowercased(), sourceID?.description, providerID, privacy.rawValue, tasks, date.timeIntervalSince1970]
            )
        }
        return revisionID
    }

    public func activeConsentRevision(providerID: String, sourceID: SourceID?, privacy: ContentPrivacy, task: AITask) throws -> UUID? {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, allowed_tasks_json FROM consent_revisions WHERE provider_id=? AND source_id IS ? AND content_privacy=? AND revoked_at IS NULL ORDER BY granted_at DESC",
                arguments: [providerID, sourceID?.description, privacy.rawValue]
            )
            for row in rows {
                let data: Data = row["allowed_tasks_json"]
                let tasks = try decoder.decode([String].self, from: data)
                if tasks.contains(task.rawValue), let id = UUID(uuidString: row["id"]) { return id }
            }
            return nil
        }
    }

    public func sourceSnapshots() throws -> [StoredSourceSnapshot] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT s.*, r.id AS revision_id, r.display_name, r.summary, r.avatar_url, r.created_at AS revision_created_at FROM sources s JOIN source_revisions r ON r.id=s.current_revision_id WHERE s.is_archived=0 ORDER BY r.display_name"
            ).map { row in
                guard let sourceID = Self.identifier(SourceID.self, row["id"]),
                      let revisionID = Self.identifier(SourceRevisionID.self, row["revision_id"]),
                      let kind = SourceKind(rawValue: row["kind"])
                else { throw CrosscurrentStorageError.corruptRecord("Source") }
                let source = LogicalSource(id: sourceID, currentRevisionID: revisionID, kind: kind, isFollowed: row["is_followed"], isArchived: row["is_archived"], createdAt: Date(timeIntervalSince1970: row["created_at"]))
                let revision = SourceRevision(id: revisionID, sourceID: sourceID, displayName: row["display_name"], summary: row["summary"], avatarURL: (row["avatar_url"] as String?).flatMap(URL.init(string:)), createdAt: Date(timeIntervalSince1970: row["revision_created_at"]))
                let endpointRows = try Row.fetchAll(db, sql: "SELECT * FROM source_endpoints WHERE source_id=? ORDER BY connector_kind, external_id", arguments: [sourceID.description])
                let endpoints = try endpointRows.map(Self.decodeEndpoint)
                let aiRow = try Row.fetchOne(db, sql: "SELECT * FROM source_ai_classifications WHERE source_id=? AND is_current=1 ORDER BY created_at DESC LIMIT 1", arguments: [sourceID.description])
                let classification: SourceAIClassification? = try aiRow.map { value in
                    guard let id = UUID(uuidString: value["id"]), let access = AccessRequirement(rawValue: value["access_requirement"]), let privacy = ContentPrivacy(rawValue: value["content_privacy"]), let provenance = AssertionProvenance(rawValue: value["provenance"]) else { throw CrosscurrentStorageError.corruptRecord("SourceAIClassification") }
                    return SourceAIClassification(id: id, sourceID: sourceID, accessRequirement: access, contentPrivacy: privacy, provenance: provenance, confidence: Confidence(value["confidence"]), createdAt: Date(timeIntervalSince1970: value["created_at"]), supersedesID: (value["supersedes_id"] as String?).flatMap(UUID.init(uuidString:)))
                }
                let coverageRow = try Row.fetchOne(db, sql: "SELECT * FROM source_coverage_assertions WHERE source_id=? AND is_current=1 ORDER BY effective_at DESC LIMIT 1", arguments: [sourceID.description])
                let coverage: SourceCoverageAssertion? = try coverageRow.map { value in
                    guard let id = UUID(uuidString: value["id"]), let ecosystem = CoverageEcosystem(rawValue: value["ecosystem"]), let provenance = AssertionProvenance(rawValue: value["provenance"]) else { throw CrosscurrentStorageError.corruptRecord("SourceCoverageAssertion") }
                    return SourceCoverageAssertion(id: id, sourceID: sourceID, ecosystem: ecosystem, provenance: provenance, confidence: Confidence(value["confidence"]), rationale: value["rationale"], effectiveAt: Date(timeIntervalSince1970: value["effective_at"]), supersedesID: (value["supersedes_id"] as String?).flatMap(UUID.init(uuidString:)))
                }
                return StoredSourceSnapshot(source: source, revision: revision, endpoints: endpoints, aiClassification: classification, coverage: coverage)
            }
        }
    }

    public func sourceFolderSnapshots() throws -> [StoredSourceFolderSnapshot] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM source_folders ORDER BY sort_order, name").map { row in
                guard let id = UUID(uuidString: row["id"]) else {
                    throw CrosscurrentStorageError.corruptRecord("SourceFolder")
                }
                let data: Data? = row["attributes_json"]
                let attributes = try data.map { try decoder.decode([String: String].self, from: $0) } ?? [:]
                let sourceValues = try String.fetchAll(
                    db,
                    sql: "SELECT source_id FROM source_folder_memberships WHERE folder_id=? ORDER BY sort_order, source_id",
                    arguments: [id.uuidString.lowercased()]
                )
                return StoredSourceFolderSnapshot(
                    id: id,
                    parentID: (row["parent_id"] as String?).flatMap(UUID.init(uuidString:)),
                    name: row["name"],
                    attributes: attributes,
                    sortOrder: row["sort_order"],
                    sourceIDs: sourceValues.compactMap { Self.identifier(SourceID.self, $0) }
                )
            }
        }
    }

    public func entitySnapshots() throws -> [StoredEntitySnapshot] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT e.*, r.id AS revision_id, r.display_name, r.summary, r.created_at AS revision_created_at FROM entities e JOIN entity_revisions r ON r.id=e.current_revision_id ORDER BY r.display_name").map { row in
                guard let id = Self.identifier(EntityID.self, row["id"]), let revisionID = Self.identifier(EntityRevisionID.self, row["revision_id"]), let kind = EntityKind(rawValue: row["kind"]) else { throw CrosscurrentStorageError.corruptRecord("Entity") }
                let aliases = try Row.fetchAll(db, sql: "SELECT * FROM entity_aliases WHERE entity_id=? ORDER BY value", arguments: [id.description]).map { alias -> EntityAlias in
                    guard let aliasID = Self.identifier(EntityAliasID.self, alias["id"]), let provenance = AssertionProvenance(rawValue: alias["provenance"]) else { throw CrosscurrentStorageError.corruptRecord("EntityAlias") }
                    return EntityAlias(id: aliasID, entityID: id, value: alias["value"], normalizedValue: alias["normalized_value"], languageCode: alias["language_code"], provenance: provenance, confidence: Confidence(alias["confidence"]))
                }
                let sources = try String.fetchAll(db, sql: "SELECT DISTINCT sr.display_name FROM source_entities se JOIN sources s ON s.id=se.source_id JOIN source_revisions sr ON sr.id=s.current_revision_id WHERE se.entity_id=? ORDER BY sr.display_name", arguments: [id.description])
                return StoredEntitySnapshot(
                    entity: Entity(id: id, currentRevisionID: revisionID, kind: kind, displayName: row["display_name"], normalizedName: row["normalized_name"], isFollowed: row["is_followed"], createdAt: Date(timeIntervalSince1970: row["created_at"])),
                    revision: EntityRevision(id: revisionID, entityID: id, displayName: row["display_name"], summary: row["summary"], createdAt: Date(timeIntervalSince1970: row["revision_created_at"])),
                    aliases: aliases,
                    sourceNames: sources
                )
            }
        }
    }

    public func topicSnapshots() throws -> [StoredTopicSnapshot] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT t.*, r.id AS revision_id, r.name, r.summary, r.created_at, (SELECT COUNT(DISTINCT a.event_revision_id) FROM event_topic_assertions a WHERE a.topic_id=t.id) AS event_count FROM topics t JOIN topic_revisions r ON r.id=t.current_revision_id ORDER BY r.name").map { row in
                guard let id = Self.identifier(TopicID.self, row["id"]), let revisionID = Self.identifier(TopicRevisionID.self, row["revision_id"]) else { throw CrosscurrentStorageError.corruptRecord("Topic") }
                return StoredTopicSnapshot(topic: Topic(id: id, currentRevisionID: revisionID, isFollowed: row["is_followed"]), revision: TopicRevision(id: revisionID, topicID: id, name: row["name"], summary: row["summary"], createdAt: Date(timeIntervalSince1970: row["created_at"])), eventCount: row["event_count"])
            }
        }
    }

    @discardableResult
    public func saveProviderConfiguration(_ configuration: ProviderConfigurationRecord) throws -> Bool {
        try mutate(domains: [.accounts]) { db in
            try db.execute(
                sql: "INSERT INTO provider_configs (id, provider_kind, display_name, keychain_reference, enabled, configuration_json) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET provider_kind=excluded.provider_kind, display_name=excluded.display_name, keychain_reference=excluded.keychain_reference, enabled=excluded.enabled, configuration_json=excluded.configuration_json",
                arguments: [configuration.id, configuration.kind, configuration.displayName, configuration.keychainReference, configuration.enabled, configuration.configuration]
            )
        }
    }

    public func activeConstraints() throws -> [ClusteringConstraint] {
        try database.pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM clustering_constraints WHERE is_active=1 ORDER BY created_at").compactMap { row in
                guard
                    let id = Self.identifier(ConstraintID.self, row["id"]),
                    let kind = ClusteringConstraintKind(rawValue: row["kind"]),
                    let left = Self.identifier(SegmentLineageID.self, row["left_lineage_id"])
                else { return nil }
                return ClusteringConstraint(
                    id: id,
                    kind: kind,
                    leftLineageID: left,
                    rightLineageID: Self.identifier(SegmentLineageID.self, row["right_lineage_id"] as String?),
                    eventID: Self.identifier(EventID.self, row["event_id"] as String?),
                    reason: row["reason"],
                    isActive: true,
                    createdAt: Date(timeIntervalSince1970: row["created_at"])
                )
            }
        }
    }

    public func itemState(endpointID: SourceEndpointID, externalID: String) throws -> StoredItemState? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT i.id AS item_id, i.current_revision_id, r.ordinal, r.content_hash
                FROM items i JOIN item_revisions r ON r.id=i.current_revision_id
                WHERE i.endpoint_id=? AND i.connector_external_id=?
                """,
                arguments: [endpointID.description, externalID]
            ) else { return nil }
            guard
                let itemID = Self.identifier(ItemID.self, row["item_id"]),
                let revisionID = Self.identifier(ItemRevisionID.self, row["current_revision_id"])
            else { throw CrosscurrentStorageError.corruptRecord("Item") }
            return StoredItemState(itemID: itemID, currentRevisionID: revisionID, currentOrdinal: row["ordinal"], currentContentHash: row["content_hash"])
        }
    }

    public func itemSegments(revisionID: ItemRevisionID) throws -> [ItemSegment] {
        try database.pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM item_segments WHERE item_revision_id=? ORDER BY ordinal",
                arguments: [revisionID.description]
            ).map { row in
                guard
                    let id = Self.identifier(ItemSegmentID.self, row["id"]),
                    let lineageID = Self.identifier(SegmentLineageID.self, row["lineage_id"]),
                    let kind = SegmentKind(rawValue: row["kind"])
                else { throw CrosscurrentStorageError.corruptRecord("ItemSegment") }
                let hash: String = row["segment_hash"]
                return ItemSegment(
                    id: id,
                    lineageID: lineageID,
                    itemRevisionID: revisionID,
                    kind: kind,
                    headingPath: (row["heading_path"] as String?).map { $0.components(separatedBy: " / ") } ?? [],
                    span: TextSpan(
                        utf8Start: row["utf8_start"],
                        utf8Length: row["utf8_length"],
                        excerptHash: hash
                    ),
                    text: row["text"],
                    contentHash: hash
                )
            }
        }
    }

    public func qualificationEvidenceRecords() throws -> [QualificationEvidenceRecord] {
        try database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT i.id AS item_id, i.canonical_key, i.current_revision_id,
                       r.ordinal, r.title, r.content_hash, sr.display_name, e.connector_kind
                FROM items i
                JOIN item_revisions r ON r.id=i.current_revision_id
                JOIN source_revisions sr ON sr.id=(SELECT current_revision_id FROM sources WHERE id=i.source_id)
                JOIN source_endpoints e ON e.id=i.endpoint_id
                ORDER BY sr.display_name, r.published_at DESC, i.id
                """
            )
            return try rows.map { row in
                guard
                    let itemID = Self.identifier(ItemID.self, row["item_id"]),
                    let revisionID = Self.identifier(ItemRevisionID.self, row["current_revision_id"]),
                    let connector = ConnectorKind(rawValue: row["connector_kind"])
                else { throw CrosscurrentStorageError.corruptRecord("QualificationEvidence") }
                let segmentHashes = try String.fetchAll(
                    db,
                    sql: "SELECT segment_hash FROM item_segments WHERE item_revision_id=? ORDER BY ordinal",
                    arguments: [revisionID.description]
                )
                let canonical: String = row["canonical_key"]
                return QualificationEvidenceRecord(
                    sourceName: row["display_name"],
                    connector: connector,
                    canonicalURL: URL(string: canonical),
                    title: row["title"],
                    itemID: itemID,
                    itemRevisionID: revisionID,
                    revisionOrdinal: row["ordinal"],
                    contentHash: row["content_hash"],
                    segmentHashes: segmentHashes
                )
            }
        }
    }

    public func sourceEndpoint(id: SourceEndpointID) throws -> SourceEndpoint? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_endpoints WHERE id=?", arguments: [id.description]) else { return nil }
            guard
                let sourceID = Self.identifier(SourceID.self, row["source_id"]),
                let connector = ConnectorKind(rawValue: row["connector_kind"]),
                let access = AccessRequirement(rawValue: row["access_requirement"]),
                let privacy = ContentPrivacy(rawValue: row["content_privacy"]),
                let health = ConnectorHealth(rawValue: row["health"])
            else { throw CrosscurrentStorageError.corruptRecord("SourceEndpoint") }
            return SourceEndpoint(
                id: id,
                sourceID: sourceID,
                connector: connector,
                accountID: Self.identifier(ConnectorAccountID.self, row["account_id"] as String?),
                externalID: row["external_id"],
                canonicalURL: (row["canonical_url"] as String?).flatMap(URL.init(string:)),
                accessRequirement: access,
                contentPrivacy: privacy,
                health: health,
                lastSuccessfulSync: (row["last_successful_sync"] as Double?).map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    public func syncCursor(endpointID: SourceEndpointID) throws -> StoredSyncCursor? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT cursor_family, cursor_data FROM sync_cursors WHERE endpoint_id=?", arguments: [endpointID.description]) else { return nil }
            return StoredSyncCursor(family: row["cursor_family"], data: row["cursor_data"])
        }
    }

    @discardableResult
    public func finishSync(endpointID: SourceEndpointID, cursor: StoredSyncCursor?, itemCount: Int, health: ConnectorHealth = .healthy, message: String? = nil, startedAt: Date, completedAt: Date = .now) throws -> Bool {
        try mutate(domains: [.endpoints, .jobs]) { db in
            if let cursor {
                try db.execute(sql: "INSERT INTO sync_cursors (endpoint_id, cursor_family, cursor_data, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(endpoint_id) DO UPDATE SET cursor_family=excluded.cursor_family, cursor_data=excluded.cursor_data, updated_at=excluded.updated_at", arguments: [endpointID.description, cursor.family, cursor.data, completedAt.timeIntervalSince1970])
            }
            try db.execute(sql: "UPDATE source_endpoints SET health=?, last_successful_sync=? WHERE id=?", arguments: [health.rawValue, completedAt.timeIntervalSince1970, endpointID.description])
            try db.execute(sql: "INSERT INTO sync_runs (id, endpoint_id, started_at, completed_at, result, item_count, error_class, checkpoint) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL)", arguments: [UUID().uuidString.lowercased(), endpointID.description, startedAt.timeIntervalSince1970, completedAt.timeIntervalSince1970, health.rawValue, itemCount])
            try db.execute(sql: "INSERT INTO connector_health_events (id, endpoint_id, health, message, observed_at) VALUES (?, ?, ?, ?, ?)", arguments: [UUID().uuidString.lowercased(), endpointID.description, health.rawValue, message, completedAt.timeIntervalSince1970])
        }
    }

    @discardableResult
    public func recordSyncFailure(endpointID: SourceEndpointID, health: ConnectorHealth, errorClass: String, message: String?, startedAt: Date, completedAt: Date = .now) throws -> Bool {
        try mutate(domains: [.endpoints, .jobs]) { db in
            try db.execute(sql: "UPDATE source_endpoints SET health=? WHERE id=?", arguments: [health.rawValue, endpointID.description])
            try db.execute(
                sql: "INSERT INTO sync_runs (id, endpoint_id, started_at, completed_at, result, item_count, error_class, checkpoint) VALUES (?, ?, ?, ?, ?, 0, ?, NULL)",
                arguments: [UUID().uuidString.lowercased(), endpointID.description, startedAt.timeIntervalSince1970, completedAt.timeIntervalSince1970, health.rawValue, errorClass]
            )
            try db.execute(
                sql: "INSERT INTO connector_health_events (id, endpoint_id, health, message, observed_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [UUID().uuidString.lowercased(), endpointID.description, health.rawValue, message, completedAt.timeIntervalSince1970]
            )
        }
    }

    @discardableResult
    public func markRemoteDeleted(endpointID: SourceEndpointID, externalIDs: [String]) throws -> Bool {
        guard !externalIDs.isEmpty else { return false }
        return try mutate(domains: [.items, .searchInputs]) { db in
            for externalID in externalIDs {
                try db.execute(sql: "UPDATE items SET remote_state=? WHERE endpoint_id=? AND connector_external_id=?", arguments: [RemoteItemState.deleted.rawValue, endpointID.description, externalID])
            }
        }
    }

    public func activePrompt(for task: AITask) throws -> ActivePrompt? {
        try database.pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT t.id AS template_id, t.name, t.bundled_default_revision_id,
                       r.id AS revision_id, r.parent_revision_id, r.origin, r.body, r.variables_json, r.created_at
                FROM prompt_templates t
                JOIN prompt_bindings b ON b.template_id=t.id
                JOIN prompt_revisions r ON r.id=b.active_revision_id
                WHERE t.task=?
                """,
                arguments: [task.rawValue]
            ) else { return nil }
            guard
                let templateID = Self.identifier(PromptTemplateID.self, row["template_id"]),
                let defaultID = Self.identifier(PromptRevisionID.self, row["bundled_default_revision_id"]),
                let revisionID = Self.identifier(PromptRevisionID.self, row["revision_id"]),
                let origin = PromptRevision.Origin(rawValue: row["origin"])
            else { throw CrosscurrentStorageError.corruptRecord("PromptRevision") }
            let variablesData: Data = row["variables_json"]
            let variables = try decoder.decode([String].self, from: variablesData)
            return ActivePrompt(
                template: PromptTemplate(id: templateID, task: task, name: row["name"], bundledDefaultRevisionID: defaultID),
                revision: PromptRevision(id: revisionID, templateID: templateID, parentRevisionID: Self.identifier(PromptRevisionID.self, row["parent_revision_id"] as String?), origin: origin, body: row["body"], variables: variables, createdAt: Date(timeIntervalSince1970: row["created_at"]))
            )
        }
    }

    @discardableResult
    public func restoreBundledPrompt(for task: AITask, at date: Date = .now) throws -> Bool {
        try mutate(domains: [.prompts]) { db in
            try db.execute(
                sql: """
                UPDATE prompt_bindings SET active_revision_id=(
                  SELECT bundled_default_revision_id FROM prompt_templates WHERE task=?
                ), updated_at=? WHERE template_id=(SELECT id FROM prompt_templates WHERE task=?)
                """,
                arguments: [task.rawValue, date.timeIntervalSince1970, task.rawValue]
            )
        }
    }

    @discardableResult
    public func saveMetrics(_ metrics: [ItemMetricSnapshot], idempotencyKey: String? = nil) throws -> Bool {
        guard !metrics.isEmpty else { return false }
        return try mutate(domains: [.metrics], idempotencyKey: idempotencyKey) { db in
            for metric in metrics {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO item_metric_snapshots
                      (id, item_id, endpoint_id, metric_type, connector_metric_key, value, captured_at, provenance)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 'connector')
                    """,
                    arguments: [metric.id.uuidString.lowercased(), metric.itemID.description, metric.sourceEndpointID.description, metric.kind.rawValue, metric.connectorKey, metric.value, metric.capturedAt.timeIntervalSince1970]
                )
            }
        }
    }

    private func setFollowState(table: String, id: String, followed: Bool, targetKind: String, at date: Date, domains: Set<ChangeDomain>) throws -> Bool {
        precondition(["sources", "entities", "topics"].contains(table))
        return try mutate(domains: domains) { db in
            try db.execute(sql: "UPDATE \(table) SET is_followed=? WHERE id=?", arguments: [followed, id])
            try db.execute(
                sql: "INSERT INTO interactions (id, action, target_kind, target_id, created_at, metadata_json) VALUES (?, ?, ?, ?, ?, NULL)",
                arguments: [UUID().uuidString.lowercased(), followed ? "follow" : "unfollow", targetKind, id, date.timeIntervalSince1970]
            )
        }
    }

    private func mutate(domains: Set<ChangeDomain>, idempotencyKey: String? = nil, body: (Database) throws -> Void) throws -> Bool {
        try mutateValue(domains: domains, idempotencyKey: idempotencyKey) { db in
            try body(db)
            return true
        } != nil
    }

    private func mutateValue<T>(domains: Set<ChangeDomain>, idempotencyKey: String? = nil, body: (Database) throws -> T) throws -> T? {
        let committedAt = Date.now
        let result: T? = try database.withCanonicalWriteAccess {
            try database.pool.write { db in
                if let idempotencyKey {
                    let alreadyCommitted = try Bool.fetchOne(
                        db,
                        sql: "SELECT EXISTS(SELECT 1 FROM idempotency_commits WHERE idempotency_key=?)",
                        arguments: [idempotencyKey]
                    ) ?? false
                    if alreadyCommitted { return nil }
                }

                let value = try body(db)
                for domain in domains.sorted(by: { $0.rawValue < $1.rawValue }) {
                    try db.execute(
                        sql: """
                        INSERT INTO database_change_generations (domain, generation, committed_at, writer_instance)
                        VALUES (?, 1, ?, ?)
                        ON CONFLICT(domain) DO UPDATE SET generation=generation+1,
                          committed_at=excluded.committed_at, writer_instance=excluded.writer_instance
                        """,
                        arguments: [domain.rawValue, committedAt.timeIntervalSince1970, writerInstance]
                    )
                }
                if let idempotencyKey {
                    try db.execute(
                        sql: "INSERT INTO idempotency_commits (idempotency_key, committed_at, writer_instance) VALUES (?, ?, ?)",
                        arguments: [idempotencyKey, committedAt.timeIntervalSince1970, writerInstance]
                    )
                }
                return value
            }
        }
        if result != nil { observations.postWakeHint() }
        return result
    }

    private static func persist(endpoint: SourceEndpoint, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO source_endpoints
              (id, source_id, connector_kind, account_id, external_id, canonical_url, access_requirement,
               content_privacy, health, capabilities_json, refresh_policy_json, last_successful_sync)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, ?)
            ON CONFLICT(id) DO UPDATE SET source_id=excluded.source_id, account_id=excluded.account_id,
              canonical_url=excluded.canonical_url, access_requirement=excluded.access_requirement,
              content_privacy=excluded.content_privacy, health=excluded.health,
              last_successful_sync=excluded.last_successful_sync
            """,
            arguments: [endpoint.id.description, endpoint.sourceID.description, endpoint.connector.rawValue, endpoint.accountID?.description, endpoint.externalID, endpoint.canonicalURL?.absoluteString, endpoint.accessRequirement.rawValue, endpoint.contentPrivacy.rawValue, endpoint.health.rawValue, endpoint.lastSuccessfulSync?.timeIntervalSince1970]
        )
    }

    private static func decodeEndpoint(row: Row) throws -> SourceEndpoint {
        guard
            let id = identifier(SourceEndpointID.self, row["id"]),
            let sourceID = identifier(SourceID.self, row["source_id"]),
            let connector = ConnectorKind(rawValue: row["connector_kind"]),
            let access = AccessRequirement(rawValue: row["access_requirement"]),
            let privacy = ContentPrivacy(rawValue: row["content_privacy"]),
            let health = ConnectorHealth(rawValue: row["health"])
        else { throw CrosscurrentStorageError.corruptRecord("SourceEndpoint") }
        return SourceEndpoint(id: id, sourceID: sourceID, connector: connector, accountID: identifier(ConnectorAccountID.self, row["account_id"] as String?), externalID: row["external_id"], canonicalURL: (row["canonical_url"] as String?).flatMap(URL.init(string:)), accessRequirement: access, contentPrivacy: privacy, health: health, lastSuccessfulSync: (row["last_successful_sync"] as Double?).map(Date.init(timeIntervalSince1970:)))
    }

    private static func upsertSearchInput(stableID: String, kind: String, revisionID: String?, languageCode: String?, title: String, body: String, inputHash: String, db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO search_inputs
              (stable_id, kind, current_revision_id, language_code, title, body, normalized_fields_json, input_hash, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?)
            ON CONFLICT(kind, stable_id) DO UPDATE SET current_revision_id=excluded.current_revision_id,
              language_code=excluded.language_code, title=excluded.title, body=excluded.body,
              input_hash=excluded.input_hash, updated_at=excluded.updated_at
            """,
            arguments: [stableID, kind, revisionID, languageCode, title, body, inputHash, Date.now.timeIntervalSince1970]
        )
    }

    private static func decodeEventRevision(row: Row) throws -> EventRevision {
        guard
            let id = identifier(EventRevisionID.self, row["id"]),
            let eventID = identifier(EventID.self, row["event_id"]),
            let changeKind = RevisionChangeKind(rawValue: row["change_kind"])
        else { throw CrosscurrentStorageError.corruptRecord("EventRevision") }
        let metadata: Data? = row["generation_metadata_json"]
        let primaryReasonTrace: [String] = metadata.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return EventRevision(
            id: id,
            eventID: eventID,
            ordinal: row["ordinal"],
            title: row["title"],
            summary: row["summary"],
            startedAt: (row["started_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            endedAt: (row["ended_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            changeKind: changeKind,
            primaryMembershipAssertionID: identifier(MembershipAssertionID.self, row["primary_membership_assertion_id"] as String?),
            primaryReasonTrace: primaryReasonTrace,
            createdAt: Date(timeIntervalSince1970: row["created_at"])
        )
    }

    private static func memberships(eventRevisionID: EventRevisionID, db: Database) throws -> [EventMembershipAssertion] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT m.* FROM event_revision_memberships rm
            JOIN event_membership_assertions m ON m.id=rm.membership_assertion_id
            WHERE rm.event_revision_id=? ORDER BY m.created_at, m.id
            """,
            arguments: [eventRevisionID.description]
        ).map { row in
            guard
                let id = identifier(MembershipAssertionID.self, row["id"]),
                let eventID = identifier(EventID.self, row["event_id"]),
                let itemRevisionID = identifier(ItemRevisionID.self, row["item_revision_id"]),
                let itemSegmentID = identifier(ItemSegmentID.self, row["item_segment_id"]),
                let lineageID = identifier(SegmentLineageID.self, row["segment_lineage_id"]),
                let decision = MembershipDecision(rawValue: row["decision"]),
                let role = MembershipRole(rawValue: row["role"]),
                let provenance = AssertionProvenance(rawValue: row["provenance"])
            else { throw CrosscurrentStorageError.corruptRecord("EventMembershipAssertion") }
            return EventMembershipAssertion(
                id: id,
                eventID: eventID,
                itemRevisionID: itemRevisionID,
                itemSegmentID: itemSegmentID,
                segmentLineageID: lineageID,
                decision: decision,
                role: role,
                confidence: Confidence(row["confidence"]),
                identityWeight: row["identity_weight"],
                independenceGroup: row["independence_group"],
                provenance: provenance,
                supersedesID: identifier(MembershipAssertionID.self, row["supersedes_id"] as String?),
                createdAt: Date(timeIntervalSince1970: row["created_at"])
            )
        }
    }

    private static func decodeDigestRevision(row: Row, db: Database) throws -> DigestRevision {
        guard
            let id = identifier(DigestRevisionID.self, row["id"]),
            let digestID = identifier(DigestID.self, row["digest_id"]),
            let reason = DigestRevisionReason(rawValue: row["reason"])
        else { throw CrosscurrentStorageError.corruptRecord("DigestRevision") }
        let entryRows = try Row.fetchAll(db, sql: "SELECT * FROM digest_entries WHERE digest_revision_id=? ORDER BY section, rank", arguments: [id.description])
        let entries = try entryRows.map { entry -> DigestEntry in
            guard let eventRevisionID = identifier(EventRevisionID.self, entry["event_revision_id"]),
                  let section = DigestSection(rawValue: entry["section"]),
                  let entryID = UUID(uuidString: entry["id"])
            else { throw CrosscurrentStorageError.corruptRecord("DigestEntry") }
            let explanationData: Data = entry["explanation_json"]
            return DigestEntry(
                id: entryID,
                eventRevisionID: eventRevisionID,
                section: section,
                rank: entry["rank"],
                score: entry["score"],
                explanation: try JSONDecoder().decode([RankingReason].self, from: explanationData)
            )
        }
        return DigestRevision(
            id: id,
            digestID: digestID,
            parentRevisionID: identifier(DigestRevisionID.self, row["parent_revision_id"] as String?),
            reason: reason,
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            entries: entries
        )
    }

    private static func decodeJob(row: Row) throws -> DurableJob {
        guard
            let id = identifier(JobID.self, row["id"]),
            let state = JobState(rawValue: row["state"])
        else { throw CrosscurrentStorageError.corruptRecord("DurableJob") }
        return DurableJob(
            id: id,
            kind: row["kind"],
            inputHash: row["input_hash"],
            idempotencyKey: row["idempotency_key"],
            payload: row["payload"],
            state: state,
            attemptCount: row["attempt_count"],
            checkpoint: row["checkpoint"],
            nextAttemptAt: Date(timeIntervalSince1970: row["next_attempt_at"])
        )
    }

    private static func identifier<Kind>(_ type: Identifier<Kind>.Type, _ string: String?) -> Identifier<Kind>? {
        guard let string, let uuid = UUID(uuidString: string) else { return nil }
        return Identifier<Kind>(uuid)
    }

    private static func normalizedAssertionName(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let briefingTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
